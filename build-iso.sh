#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEBIAN_RELEASE="${DEBIAN_RELEASE:-13.6.0}"
DEBIAN_MAJOR="${DEBIAN_RELEASE%%.*}"
ADMIN_USER="${ADMIN_USER:-sysadmin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-Administrator}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian}"
TARGET_DOMAIN="${TARGET_DOMAIN:-localdomain}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-de}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
LV_VAR_MIN="${LV_VAR_MIN:-10240}"
LV_VAR_MAX="${LV_VAR_MAX:-200000}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-$SCRIPT_DIR/custom/authorized_keys}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

case "$DEBIAN_MAJOR" in
    11) DEFAULT_SUITE="bullseye" ;;
    12) DEFAULT_SUITE="bookworm" ;;
    13) DEFAULT_SUITE="trixie" ;;
    14) DEFAULT_SUITE="forky" ;;
    *)  DEFAULT_SUITE="" ;;
esac
DEBIAN_SUITE="${DEBIAN_SUITE:-$DEFAULT_SUITE}"

DEBIAN_ISO_URLS=(
    "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-$DEBIAN_RELEASE-amd64-netinst.iso"
    "https://cdimage.debian.org/cdimage/archive/$DEBIAN_RELEASE/amd64/iso-cd/debian-$DEBIAN_RELEASE-amd64-netinst.iso"
)
OUT_DIR="${SCRIPT_DIR}/out"
SRC_ISO="${OUT_DIR}/debian-$DEBIAN_RELEASE-amd64-netinst.iso"
OUTPUT_ISO="${OUT_DIR}/debian-$DEBIAN_RELEASE-unattended.iso"
WORK_DIR=""
USER_HASH=""

PRESEED_ARGS="auto=true priority=critical locale=$LOCALE keymap=$KEYMAP hostname=$TARGET_HOSTNAME domain=$TARGET_DOMAIN preseed/file=/cdrom/preseed.cfg"

MIN_ISO_BYTES=104857600

check_deps() {
    local missing=()
    for cmd in xorriso wget dd sed mkpasswd; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing tools: ${missing[*]}"
        echo "  sudo apt-get install -y xorriso wget whois"
        exit 1
    fi
    if [ -z "$DEBIAN_SUITE" ]; then
        echo "[x] No codename known for Debian $DEBIAN_MAJOR."
        echo "    Add it to the case in this script, or pass it explicitly:"
        echo "      DEBIAN_SUITE=<codename> DEBIAN_RELEASE=$DEBIAN_RELEASE ./build-iso.sh"
        exit 1
    fi
    case "$LV_VAR_MIN$LV_VAR_MAX" in
        ''|*[!0-9]*)
            echo "[x] LV_VAR_MIN and LV_VAR_MAX must be plain integers in MB."
            echo "    got: LV_VAR_MIN='$LV_VAR_MIN' LV_VAR_MAX='$LV_VAR_MAX'"
            exit 1 ;;
    esac
    if [ "$LV_VAR_MIN" -gt "$LV_VAR_MAX" ]; then
        echo "[x] LV_VAR_MIN ($LV_VAR_MIN) is larger than LV_VAR_MAX ($LV_VAR_MAX)."
        exit 1
    fi
}

prepare_user_hash() {
    USER_HASH="${USERHASH:-}"
    if [ -z "$USER_HASH" ]; then
        echo "[*] Choose a password for user '$ADMIN_USER' (stored sha-512-hashed in the ISO):"
        USER_HASH=$(mkpasswd -m sha-512)
    fi
}

validate_iso() {
    local path="$1"
    [ -f "$path" ] || return 1
    local size
    size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    [ "$size" -ge "$MIN_ISO_BYTES" ]
}

download_iso() {
    if validate_iso "$SRC_ISO"; then
        echo "[*] Using existing ISO: $SRC_ISO"
        return
    fi
    [ -f "$SRC_ISO" ] && { echo "[!] Removing incomplete ISO: $SRC_ISO"; rm -f "$SRC_ISO"; }
    local url
    for url in "${DEBIAN_ISO_URLS[@]}"; do
        echo "[*] Downloading Debian $DEBIAN_RELEASE netinst ISO from $url"
        wget --show-progress -O "$SRC_ISO" "$url" && validate_iso "$SRC_ISO" && return
        rm -f "$SRC_ISO"
        echo "[!] Not available there, trying the next location"
    done
    echo "[x] Could not download Debian $DEBIAN_RELEASE from any known location."
    echo "    Check https://cdimage.debian.org/ for the point releases that exist."
    exit 1
}

extract_iso() {
    echo "[*] Extracting ISO to $WORK_DIR"
    xorriso -osirrox on \
        -indev "$SRC_ISO" \
        -extract / "$WORK_DIR" \
        -- 2>/dev/null
    chmod -R u+w "$WORK_DIR"
}

patch_isolinux() {
    local cfg
    for cfg in \
        "$WORK_DIR/isolinux/txt.cfg" \
        "$WORK_DIR/isolinux/gtk.cfg" \
        "$WORK_DIR/isolinux/menu.cfg" \
        "$WORK_DIR/isolinux/isolinux.cfg"; do
        [ -f "$cfg" ] || continue
        sed -i "s|\(append.*initrd=[^ ]*\)|\1 ${PRESEED_ARGS}|g" "$cfg"
        echo "[*] Patched: $cfg"
    done

    local icfg="$WORK_DIR/isolinux/isolinux.cfg"
    if [ -f "$icfg" ]; then
        sed -i '/^timeout /d' "$icfg"
        sed -i 's|^include menu\.cfg$|include menu.cfg\ntimeout 1\nontimeout install|' "$icfg"
        echo "[*] Fixed boot timeout in isolinux.cfg"
    fi
}

patch_grub() {
    local cfg="$WORK_DIR/boot/grub/grub.cfg"
    if [ ! -f "$cfg" ]; then
        echo "[!] grub.cfg not found, skipping EFI patch"
        return
    fi
    sed -i "s|^\([[:space:]]*linux[[:space:]]\+/[^ ]*\)|\1 ${PRESEED_ARGS}|" "$cfg"

    sed -i '/^[[:space:]]*set timeout=/d; /^[[:space:]]*set timeout_style=/d; /^[[:space:]]*set default=/d' "$cfg"
    sed -i "1i set timeout=1\nset timeout_style=hidden\nset default='Install'" "$cfg"
    echo "[*] Patched: boot/grub/grub.cfg"
}

render_preseed() {
    local content pair placeholder varname value
    shopt -u patsub_replacement 2>/dev/null || true
    content=$(<"$SCRIPT_DIR/preseed.cfg.tpl")
    for pair in USERHASH:USER_HASH \
                USERNAME:ADMIN_USER \
                USER_FULLNAME:ADMIN_FULLNAME \
                HOSTNAME:TARGET_HOSTNAME \
                DOMAIN:TARGET_DOMAIN \
                LOCALE:LOCALE \
                KEYMAP:KEYMAP \
                TIMEZONE:TIMEZONE \
                SUITE:DEBIAN_SUITE \
                LV_VAR_MIN:LV_VAR_MIN \
                LV_VAR_MAX:LV_VAR_MAX; do
        placeholder="${pair%%:*}"
        varname="${pair##*:}"
        value="${!varname}"
        content="${content//"@$placeholder@"/$value}"
    done
    printf '%s\n' "$content" > "$WORK_DIR/preseed.cfg"
}

add_custom_files() {
    echo "[*] Rendering preseed.cfg and custom/ directory"
    render_preseed

    mkdir -p "$WORK_DIR/custom"
    cp "$SCRIPT_DIR/custom/ssh-host-keygen.service" \
       "$SCRIPT_DIR/custom/raid-setup.sh" \
       "$SCRIPT_DIR/custom/sync-esp.sh" \
       "$WORK_DIR/custom/"

    if [ -n "$SSH_PUBKEY" ]; then
        echo "$SSH_PUBKEY" > "$WORK_DIR/custom/authorized_keys"
    elif [ -f "$AUTHORIZED_KEYS_FILE" ]; then
        cp "$AUTHORIZED_KEYS_FILE" "$WORK_DIR/custom/authorized_keys"
    else
        : > "$WORK_DIR/custom/authorized_keys"
    fi

    local keys
    keys=$(grep -cvE "^\s*(#|$)" "$WORK_DIR/custom/authorized_keys" || true)
    if [ "${keys:-0}" -eq 0 ]; then
        echo "[!] No SSH key configured - set SSH_PUBKEY or fill $AUTHORIZED_KEYS_FILE"
    fi
}

build_iso() {
    echo "[*] Extracting MBR from source ISO"
    dd if="$SRC_ISO" bs=1 count=432 of="${WORK_DIR}/isohdpfx.bin" 2>/dev/null

    echo "[*] Building ISO: $OUTPUT_ISO"
    xorriso -as mkisofs \
        -quiet \
        -r \
        -V "Debian $DEBIAN_RELEASE Unattended" \
        -isohybrid-mbr "${WORK_DIR}/isohdpfx.bin" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$OUTPUT_ISO" \
        "$WORK_DIR" 2>/dev/null
}

cleanup() {
    [ -n "$WORK_DIR" ] || return 0
    echo "[*] Cleaning up"
    rm -rf "$WORK_DIR"
}

main() {
    trap cleanup EXIT
    check_deps
    prepare_user_hash
    mkdir -p "$OUT_DIR"
    WORK_DIR="$(mktemp -d /tmp/debian-$DEBIAN_RELEASE-iso-XXXXXXXX)"
    download_iso
    extract_iso
    patch_isolinux
    patch_grub
    add_custom_files
    build_iso

    echo ""
    echo "  Done: $OUTPUT_ISO ($(du -sh "$OUTPUT_ISO" | cut -f1))"
    echo ""
    echo "  Write to USB stick:"
    echo "    sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
