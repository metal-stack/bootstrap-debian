#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVMF_CANDIDATES=(/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd
                 /usr/share/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd)
DISK_SIZE="${SMOKE_DISK_SIZE:-64G}"
SMOKE_DISKS="${SMOKE_DISKS:-2}"
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
DISK_ARGS=()
SERIAL_UNIT=""
ISO_LAYOUT=""
ISO_SWAP=""
MARK=1
FAILED=0

cleanup() {
    [ -n "$QEMU" ] && kill "$QEMU" 2>/dev/null
    [ -n "$WORK" ] && rm -rf "$WORK"
    return 0
}

ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1"; [ $# -gt 1 ] && echo "         $2"; FAILED=1; }
skip() { echo "  skip - $1 ($2)"; }
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

extract_iso_config() {
    local icfg="$WORK/iso-isolinux.cfg" gcfg="$WORK/iso-grub.cfg" pcfg="$WORK/iso-preseed.cfg"
    xorriso -report_about FAILURE -osirrox on -indev "$ISO" \
        -extract /isolinux/isolinux.cfg "$icfg" \
        -extract /boot/grub/grub.cfg    "$gcfg" \
        -extract /preseed.cfg           "$pcfg" -- 2>/dev/null
    chmod -R u+w "$WORK" 2>/dev/null
    case "$MODE" in
        bios) SERIAL_UNIT=$(sed -n 's/^serial \([0-9][0-9]*\).*/\1/p' "$icfg" 2>/dev/null | head -1) ;;
        uefi) SERIAL_UNIT=$(sed -n 's/^serial .*--unit=\([0-9][0-9]*\).*/\1/p' "$gcfg" 2>/dev/null | head -1) ;;
    esac
    ISO_LAYOUT=$(sed -n 's|^d-i partman/early_command string .*/disk-setup\.sh \([^ ]*\) .*|\1|p' "$pcfg" 2>/dev/null | head -1)
    ISO_SWAP=$(sed -n 's|^d-i partman/early_command string .*/disk-setup\.sh [^ ]* \([^ ]*\)|\1|p' "$pcfg" 2>/dev/null | head -1)
    case "$ISO_LAYOUT:$ISO_SWAP" in
        raid1:yes|raid1:no|single:yes|single:no) return 0 ;;
    esac
    die "${ISO##*/} does not say which layout it installs: got '$ISO_LAYOUT:$ISO_SWAP'"
}

require_serial_console() {
    local where
    extract_iso_config
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

require_disk_count() {
    case "$SMOKE_DISKS" in
        ''|*[!0-9]*|0) die "SMOKE_DISKS must be a positive whole number, got '$SMOKE_DISKS'" ;;
    esac
}

create_disks() {
    local d=1
    while [ "$d" -le "$SMOKE_DISKS" ]; do
        qemu-img create -f qcow2 "$WORK/d$d.qcow2" "$DISK_SIZE" >/dev/null
        d=$((d + 1))
    done
}

disk_args() {
    local d=1
    DISK_ARGS=()
    while [ "$d" -le "$SMOKE_DISKS" ]; do
        DISK_ARGS+=(-drive "file=$WORK/d$d.qcow2,if=virtio,format=qcow2")
        d=$((d + 1))
    done
}

disk_args_only() {
    DISK_ARGS=(-drive "file=$WORK/d$1.qcow2,if=virtio,format=qcow2")
}

start_qemu() {
    local boot=("$@")
    : > "$LOG"
    : > "$SEEN"
    MARK=1
    qemu-system-x86_64 -accel "$ACCEL" -m 2048 -smp 2 "${FW[@]}" "${boot[@]}" \
        "${DISK_ARGS[@]}" \
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
    reach "partitions built, base system runs"   'Installing the base system' "$DEADLINE" &&
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

stop_qemu() {
    [ -n "$QEMU" ] || return 0
    kill "$QEMU" 2>/dev/null
    wait "$QEMU" 2>/dev/null || true
    QEMU=""
}

run_installed_system_from() {
    stop_qemu
    disk_args_only "$1"
    start_qemu -boot c
    reach "the installed system boots from disk $1 alone" "$LOGIN_PROMPT" "$BOOT_DEADLINE"
    disk_args
}

install_actions() {
    grep -aE '(Creating|Formatting|Running )' "$INSTALL_SEEN" 2>/dev/null
}

require_action() {
    local name="$1" pattern="$2" hit
    hit=$(install_actions | grep -aF -m1 -- "$pattern")
    if [ -n "$hit" ]; then
        ok "$name"
    else
        bad "$name" "the installer transcript never showed: $pattern"
    fi
}

forbid_action() {
    local name="$1" pattern="$2" hit
    hit=$(install_actions | grep -aF -m1 -- "$pattern")
    if [ -z "$hit" ]; then
        ok "$name"
    else
        bad "$name" "the installer transcript showed: $hit"
    fi
}

check_install_layout() {
    case "$ISO_LAYOUT" in
        raid1)
            require_action "raid1: /boot is a mirrored array" \
                "/boot in partition #1 of RAID1 device#0"
            require_action "raid1: the ESP is written on the second disk too" \
                "partition #2 of Virtual disk 2(vdb)"
            require_action "raid1: /var is a logical volume in vg0" \
                "for /var in partition #1 of LVM VG vg0, LVlv_var"
            require_action "raid1: grub goes to both disks" 'grub-install /dev/vda /dev/vdb' ;;
        single)
            require_action "single: /boot is the third plain partition" \
                "/boot in partition #3 of Virtual disk 1(vda)"
            require_action "single: /var is a logical volume in vg0" \
                "for /var in partition #1 of LVM VG vg0, LVlv_var"
            require_action "single: grub goes to the one disk" 'grub-install /dev/vda"'
            forbid_action "single: no array is built" "RAID1 device"
            if [ "$SMOKE_DISKS" -ge 2 ]; then
                forbid_action "single: the other disk is not touched" "Virtual disk 2"
            else
                skip "single: the other disk is not touched" "no second disk; run with SMOKE_DISKS=2"
            fi ;;
    esac
    if [ "$ISO_SWAP" = yes ]; then
        case "$ISO_LAYOUT" in
            raid1) require_action "raid1: swap is a third array" \
                       "swap space in partition #1 of RAID1 device #2" ;;
            single) require_action "single: swap is a logical volume" \
                       "swap space in partition #1 of LVM VG vg0, LV lv_swap" ;;
        esac
    else
        forbid_action "$ISO_LAYOUT: nothing formats swap" "swap space"
        forbid_action "$ISO_LAYOUT: no swap volume exists" "lv_swap"
    fi
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
    require_disk_count
    serial_args
    firmware_args
    disk_args
    create_disks

    echo "[$MODE] ${ISO##*/} on $SMOKE_DISKS disk(s) of $DISK_SIZE ($ACCEL, $ISO_LAYOUT swap=$ISO_SWAP, install deadline ${DEADLINE}s)"
    if run_install; then
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.install" && cp "$INSTALL_SEEN" "$SMOKE_LOG.install.text"
        run_installed_system
        check_nothing_unanswered
        check_install_layout
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.boot"
        if [ "$ISO_LAYOUT" = raid1 ] && [ "$SMOKE_DISKS" -ge 2 ]; then
            run_installed_system_from 2
            [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.boot.d2"
        fi
    else
        [ -n "${SMOKE_LOG:-}" ] && cp "$LOG" "$SMOKE_LOG.install"
    fi

    return "$FAILED"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
