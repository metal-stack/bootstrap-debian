#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVMF_CANDIDATES=(/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd
                 /usr/share/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd)
DISK_SIZE=64G
BOOT_DEADLINE="${SMOKE_BOOT_DEADLINE:-420}"
LOGIN_PROMPT="${SMOKE_LOGIN_PROMPT:-login:}"

ISO=""
MODE=""
DEADLINE=""
ACCEL=""
OVMF_CODE=""
WORK=""
LOG=""
SEEN=""
INSTALL_SEEN=""
QEMU=""
FW=()
SERIAL_ARGS=()
SERIAL_UNIT=""
MARK=1
FAILED=0

cleanup() {
    [ -n "$QEMU" ] && kill "$QEMU" 2>/dev/null
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}

ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1"; [ $# -gt 1 ] && echo "         $2"; FAILED=1; }
die() { echo "[x] $1"; exit 1; }

default_iso() {
    ( cd "$REPO" && bash -c 'source ./build-iso.sh >/dev/null; echo "$OUTPUT_ISO"' _ )
}

pick_accel() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL=kvm
    else
        ACCEL=tcg
        DEADLINE=$((DEADLINE * 4))
        BOOT_DEADLINE=$((BOOT_DEADLINE * 4))
    fi
}

find_ovmf() {
    local f
    for f in "${OVMF_CANDIDATES[@]}"; do
        [ -f "$f" ] && { OVMF_CODE="$f"; return 0; }
    done
    return 1
}

detect_serial_unit() {
    local icfg="$WORK/iso-isolinux.cfg" gcfg="$WORK/iso-grub.cfg"
    xorriso -report_about FAILURE -osirrox on -indev "$ISO" \
        -extract /isolinux/isolinux.cfg "$icfg" \
        -extract /boot/grub/grub.cfg    "$gcfg" -- 2>/dev/null
    chmod -R u+w "$WORK" 2>/dev/null
    case "$MODE" in
        bios) SERIAL_UNIT=$(sed -n 's/^serial \([0-9][0-9]*\).*/\1/p' "$icfg" 2>/dev/null | head -1) ;;
        uefi) SERIAL_UNIT=$(sed -n 's/^serial .*--unit=\([0-9][0-9]*\).*/\1/p' "$gcfg" 2>/dev/null | head -1) ;;
    esac
}

require_serial_console() {
    local where
    detect_serial_unit
    [ -n "$SERIAL_UNIT" ] && return 0
    case "$MODE" in
        bios) where="a 'serial <unit> <baud>' directive in isolinux/isolinux.cfg" ;;
        uefi) where="a 'serial --unit=<unit>' command in boot/grub/grub.cfg" ;;
    esac
    echo "[x] ${ISO##*/} has no serial console: expected $where."
    echo "    This test reads the install through the serial port, so an ISO built"
    echo "    with SERIAL_CONSOLE= stays silent and every stage below would time out."
    echo "    Rebuild with the default:  make iso"
    exit 1
}

serial_args() {
    local i=0
    SERIAL_ARGS=()
    while [ "$i" -lt "$SERIAL_UNIT" ]; do
        SERIAL_ARGS+=(-serial null)
        i=$((i + 1))
    done
    SERIAL_ARGS+=(-serial file:"$LOG")
}

firmware_args() {
    FW=()
    [ "$MODE" = uefi ] || return 0
    find_ovmf || die "no OVMF firmware found, install ovmf"
    cp "${OVMF_CODE/CODE/VARS}" "$WORK/vars.fd"
    FW=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$WORK/vars.fd")
}

create_disks() {
    local d
    for d in 1 2; do
        qemu-img create -f qcow2 "$WORK/d$d.qcow2" "$DISK_SIZE" >/dev/null
    done
}

start_qemu() {
    local boot=("$@")
    : > "$LOG"
    : > "$SEEN"
    MARK=1
    qemu-system-x86_64 -accel "$ACCEL" -m 2048 -smp 2 "${FW[@]}" "${boot[@]}" \
        -drive file="$WORK/d1.qcow2",if=virtio,format=qcow2 \
        -drive file="$WORK/d2.qcow2",if=virtio,format=qcow2 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none "${SERIAL_ARGS[@]}" -no-reboot 2>"$WORK/qemu.err" &
    QEMU=$!
}

snapshot() {
    sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][B0]//g' -e 's/\r/\n/g' \
        "$LOG" > "$SEEN" 2>/dev/null
}

qemu_running() { kill -0 "$QEMU" 2>/dev/null; }

reach() {
    local name="$1" pattern="$2" limit="$3" start=$SECONDS hit
    while [ $((SECONDS - start)) -lt "$limit" ]; do
        snapshot
        hit=$(tail -n +"$MARK" "$SEEN" | grep -nE -m1 "$pattern" | cut -d: -f1)
        if [ -n "$hit" ]; then
            MARK=$((MARK + hit - 1))
            ok "$name ($((SECONDS - start))s)"
            return 0
        fi
        if grep -q '\[!!\]' "$SEEN"; then
            bad "$name" "d-i is asking: $(grep -m1 -A3 '\[!!\]' "$SEEN" | tr -s ' \n' ' ')"
            return 1
        fi
        if ! qemu_running; then
            bad "$name" "qemu exited early: $(tr '\n' ' ' < "$WORK/qemu.err" | tail -c 200)"
            return 1
        fi
        sleep 2
    done
    bad "$name" "'$pattern' not seen within ${limit}s"
    return 1
}

wait_for_power_off() {
    local start=$SECONDS
    while [ $((SECONDS - start)) -lt "$DEADLINE" ]; do
        if ! qemu_running; then
            ok "installer powered the machine off ($((SECONDS - start))s)"
            return 0
        fi
        snapshot
        if grep -q '\[!!\]' "$SEEN"; then
            bad "installer powered the machine off" \
                "d-i is asking: $(grep -m1 -A3 '\[!!\]' "$SEEN" | tr -s ' \n' ' ')"
            return 1
        fi
        sleep 5
    done
    bad "installer powered the machine off" "still running after ${DEADLINE}s"
    return 1
}

reach_boot_loader() {
    case "$MODE" in
        bios) reach "boot loader talks to the serial port" 'ISOLINUX' "$BOOT_DEADLINE" ;;
        uefi) reach "firmware hands over to the loader"    'Loading bootloader' "$BOOT_DEADLINE" ;;
    esac
}

run_install() {
    start_qemu -cdrom "$ISO" -boot d
    reach_boot_loader &&
    reach "d-i starts, network needs no answer"  'Configuring the network with DHCP' "$BOOT_DEADLINE" &&
    reach "hardware detected, nothing asked"     'Detecting disks and all other hardware' "$BOOT_DEADLINE" &&
    reach "partitioner starts"                   'Starting up the partitioner' "$BOOT_DEADLINE" &&
    reach "RAID and LVM built, base system runs" 'Installing the base system' "$DEADLINE" &&
    reach "installation finishes"                'Finishing the installation' "$DEADLINE" &&
    wait_for_power_off
    local status=$?
    snapshot
    cp "$SEEN" "$INSTALL_SEEN"
    return "$status"
}

run_installed_system() {
    QEMU=""
    start_qemu -boot c
    reach "installed system reaches a login prompt" "$LOGIN_PROMPT" "$BOOT_DEADLINE"
}

check_nothing_unanswered() {
    if [ ! -s "$INSTALL_SEEN" ]; then
        bad "nothing left unanswered" "no install transcript, the claim would be vacuous"
    elif ! grep -q 'Starting up the partitioner' "$INSTALL_SEEN"; then
        bad "nothing left unanswered" "the installer never reached the partitioner"
    elif grep -q '\[!!\]' "$INSTALL_SEEN"; then
        bad "nothing left unanswered" "$(grep -m1 -A2 '\[!!\]' "$INSTALL_SEEN" | tr -s ' \n' ' ')"
    else
        ok "nothing left unanswered"
    fi
}

main() {
    ISO="${1:-}"
    MODE="${2:-bios}"
    DEADLINE="${3:-1800}"

    case "$MODE" in
        bios|uefi) ;;
        *) echo "usage: ${0##*/} [iso] [bios|uefi] [install-deadline-seconds]"; exit 2 ;;
    esac
    [ -n "$ISO" ] || ISO=$(default_iso)
    [ -f "$ISO" ] || die "no such ISO: $ISO"

    pick_accel

    WORK=$(mktemp -d "${SMOKE_WORKDIR:-$(dirname "$ISO")}/smoke-XXXXXX") || exit 1
    trap cleanup EXIT
    LOG="$WORK/serial.log"
    SEEN="$WORK/seen.txt"
    INSTALL_SEEN="$WORK/install-seen.txt"
    : > "$INSTALL_SEEN"

    require_serial_console
    serial_args
    firmware_args
    create_disks

    echo "[$MODE] ${ISO##*/} ($ACCEL, install deadline ${DEADLINE}s)"
    if run_install; then
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.install"
        run_installed_system
        check_nothing_unanswered
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.boot"
    else
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.install"
    fi

    return "$FAILED"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
