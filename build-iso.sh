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
SERIAL_CONSOLE="${SERIAL_CONSOLE-ttyS1,115200n8}"

case "$DEBIAN_MAJOR" in
    11) DEFAULT_SUITE="bullseye" ;;
    12) DEFAULT_SUITE="bookworm" ;;
    13) DEFAULT_SUITE="trixie" ;;
    14) DEFAULT_SUITE="forky" ;;
    *)  DEFAULT_SUITE="" ;;
esac
DEBIAN_SUITE="${DEBIAN_SUITE:-$DEFAULT_SUITE}"

ISO_VARIANT="${ISO_VARIANT:-netinst}"
# shellcheck disable=SC2034
case "$ISO_VARIANT" in
    netinst)
        SRC_SUBDIR="iso-cd"
        SRC_NAME="debian-$DEBIAN_RELEASE-amd64-netinst.iso"
        OUTPUT_NAME="debian-$DEBIAN_RELEASE-unattended.iso"
        VOLUME_ID="Debian $DEBIAN_RELEASE Unattended"
        EXTRA_DEBS=""
        OFFLINE_ONLY="# "
        APT_SERVICES="security, updates"
        PKGSEL_UPGRADE="full-upgrade"
        UPDATE_POLICY="unattended-upgrades"
        LATE_OFFLINE=""
        ;;
    offline)
        SRC_SUBDIR="iso-dvd"
        SRC_NAME="debian-$DEBIAN_RELEASE-amd64-DVD-1.iso"
        OUTPUT_NAME="debian-$DEBIAN_RELEASE-unattended-offline.iso"
        VOLUME_ID="Debian $DEBIAN_RELEASE Unattended Offline"
        EXTRA_DEBS="unattended-upgrades"
        OFFLINE_ONLY=""
        APT_SERVICES=""
        PKGSEL_UPGRADE="none"
        UPDATE_POLICY="none"
        LATE_OFFLINE="sh /cdrom/custom/offline-post.sh $DEBIAN_SUITE; "
        ;;
    *)  echo "[x] Unknown ISO_VARIANT '$ISO_VARIANT'. Use 'netinst' or 'offline'."
        exit 1 ;;
esac

# shellcheck disable=SC2034
if [ -n "$SERIAL_CONSOLE" ]; then
    SERIAL_ONLY=""
    CONSOLE_ARGS="console=tty0 console=$SERIAL_CONSOLE"
    LATE_SERIAL="sh /cdrom/custom/serial-console.sh; "
    SERIAL_UNIT="${SERIAL_CONSOLE%%,*}"
    SERIAL_UNIT="${SERIAL_UNIT#ttyS}"
    SERIAL_SPEED="${SERIAL_CONSOLE#*,}"
    SERIAL_SPEED="${SERIAL_SPEED%%[!0-9]*}"
else
    SERIAL_ONLY="# "
    CONSOLE_ARGS=""
    LATE_SERIAL=""
    SERIAL_UNIT=""
    SERIAL_SPEED=""
fi

DEBIAN_ISO_URLS=(
    "https://cdimage.debian.org/debian-cd/current/amd64/$SRC_SUBDIR/$SRC_NAME"
    "https://cdimage.debian.org/cdimage/archive/$DEBIAN_RELEASE/amd64/$SRC_SUBDIR/$SRC_NAME"
)
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
CHECK_SIGNATURE="${CHECK_SIGNATURE:-auto}"
DEBIAN_CD_KEYS="10460DAD76165AD81FBC0CE9988021A964E6EA7D
DF9B9C49EAA9298432589D76DA87E80D6294BE9B"
OUT_DIR="${SCRIPT_DIR}/out"
SRC_ISO="${OUT_DIR}/${SRC_NAME}"
OUTPUT_ISO="${OUT_DIR}/${OUTPUT_NAME}"
WORK_DIR=""
USER_HASH=""

PRESEED_ARGS="auto=true priority=critical locale=$LOCALE keymap=$KEYMAP hostname=$TARGET_HOSTNAME domain=$TARGET_DOMAIN preseed/file=/preseed.cfg${CONSOLE_ARGS:+ $CONSOLE_ARGS}"

check_deps() {
    local deps=(xorriso wget dd sed mkpasswd sha256sum cpio gzip)
    [ -n "$EXTRA_DEBS" ] && deps+=(xz)
    local missing=()
    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing tools: ${missing[*]}"
        echo "  sudo apt-get install -y xorriso wget whois xz-utils cpio coreutils"
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
    if [ -n "$SERIAL_CONSOLE" ]; then
        case "$SERIAL_CONSOLE" in
            ttyS[0-3],"$SERIAL_SPEED"|ttyS[0-3],"$SERIAL_SPEED"n8) ;;
            *)  echo "[x] SERIAL_CONSOLE must be ttyS0-3,<baud>[n8], e.g. ttyS1,115200n8."
                echo "    got: '$SERIAL_CONSOLE'"
                exit 1 ;;
        esac
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
    local path="$1" expected="$2"
    [ -f "$path" ] || return 1
    printf '%s  %s\n' "$expected" "$path" | sha256sum -c --quiet
}

check_sums_signature() {
    local sums="$1" sig="$2" status fpr
    [ "$CHECK_SIGNATURE" = "no" ] && return 0

    local why=""
    if [ ! -s "$sig" ]; then
        why="SHA256SUMS.sign was not available"
    elif ! command -v gpg &>/dev/null; then
        why="gpg is not installed"
    else
        status=$(gpg --status-fd 1 --verify "$sig" "$sums" 2>/dev/null || true)
        fpr=$(awk '$2 == "VALIDSIG" { print $3; exit }' <<< "$status")
        if [ -z "$fpr" ]; then
            why="no valid signature (gpg has no Debian CD signing key?)"
        elif ! grep -qxF "$fpr" <<< "$DEBIAN_CD_KEYS"; then
            echo "[x] SHA256SUMS is signed by $fpr, which is not a Debian CD signing key."
            exit 1
        else
            echo "[*] SHA256SUMS signature verified ($fpr)"
            return 0
        fi
    fi

    if [ "$CHECK_SIGNATURE" = "yes" ]; then
        echo "[x] Cannot verify the SHA256SUMS signature: $why"
        exit 1
    fi
    echo "[!] Checksum not signature-checked: $why"
    echo "    The image is still verified against SHA256SUMS, which only rules out"
    echo "    a corrupted download. For the full check import the key and rerun:"
    echo "      gpg --keyserver keyring.debian.org --recv-keys ${DEBIAN_CD_KEYS##*$'\n'}"
    echo "      CHECK_SIGNATURE=yes ./build-iso.sh"
}

fetch_sums() {
    local base="$1" sums="$WORK_DIR/SHA256SUMS" sig="$WORK_DIR/SHA256SUMS.sign"
    rm -f "$sums" "$sig"
    wget -q -O "$sums" "$base/SHA256SUMS" || return 1
    wget -q -O "$sig" "$base/SHA256SUMS.sign" || rm -f "$sig"
    [ -n "$(expected_sum)" ]
}

expected_sum() {
    awk -v n="$SRC_NAME" '$2 == n || $2 == "*" n { print $1; exit }' \
        "$WORK_DIR/SHA256SUMS" 2>/dev/null
}

download_iso() {
    local url base expected=""

    for url in "${DEBIAN_ISO_URLS[@]}"; do
        base="${url%/*}"
        if fetch_sums "$base"; then
            check_sums_signature "$WORK_DIR/SHA256SUMS" "$WORK_DIR/SHA256SUMS.sign"
            expected=$(expected_sum)
            break
        fi
    done

    if [ -n "$expected" ]; then
        printf '%s\n' "$expected" > "$SRC_ISO.sha256"
    elif [ -s "$SRC_ISO.sha256" ]; then
        expected=$(< "$SRC_ISO.sha256")
        echo "[!] No SHA256SUMS reachable; using the checksum cached in ${SRC_NAME}.sha256"
    else
        echo "[x] No SHA256SUMS for $SRC_NAME at any known location."
        echo "    Check https://cdimage.debian.org/ for the point releases that exist."
        exit 1
    fi

    if [ -f "$SRC_ISO" ]; then
        if validate_iso "$SRC_ISO" "$expected"; then
            echo "[*] Using existing ISO: $SRC_ISO (sha256 ok)"
            return
        fi
        echo "[!] $SRC_NAME does not match its checksum, discarding it"
        rm -f "$SRC_ISO"
    fi

    for url in "${DEBIAN_ISO_URLS[@]}"; do
        echo "[*] Downloading Debian $DEBIAN_RELEASE $ISO_VARIANT image from $url"
        if wget --show-progress -O "$SRC_ISO" "$url"; then
            if validate_iso "$SRC_ISO" "$expected"; then
                echo "[*] sha256 ok: $SRC_NAME"
                return
            fi
            echo "[x] $url downloaded but does not match SHA256SUMS."
            rm -f "$SRC_ISO"
            exit 1
        fi
        rm -f "$SRC_ISO"
        echo "[!] Not available there, trying the next location"
    done
    echo "[x] Could not download Debian $DEBIAN_RELEASE from any known location."
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

        if [ -n "$SERIAL_CONSOLE" ]; then
            sed -i "1i serial $SERIAL_UNIT $SERIAL_SPEED" "$icfg"
            echo "[*] isolinux output on ttyS$SERIAL_UNIT at $SERIAL_SPEED baud"
        fi
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

    if [ -n "$SERIAL_CONSOLE" ]; then
        sed -i "1i serial --unit=$SERIAL_UNIT --speed=$SERIAL_SPEED\nterminal_input console serial\nterminal_output console serial" "$cfg"
        sed -i 's|^\([[:space:]]*terminal_output[[:space:]]\+gfxterm\)$|\1 serial|' "$cfg"
        echo "[*] grub output on ttyS$SERIAL_UNIT at $SERIAL_SPEED baud"
    fi
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
                LV_VAR_MAX:LV_VAR_MAX \
                OFFLINE_ONLY:OFFLINE_ONLY \
                APT_SERVICES:APT_SERVICES \
                PKGSEL_UPGRADE:PKGSEL_UPGRADE \
                UPDATE_POLICY:UPDATE_POLICY \
                LATE_OFFLINE:LATE_OFFLINE \
                SERIAL_ONLY:SERIAL_ONLY \
                CONSOLE_ARGS:CONSOLE_ARGS \
                LATE_SERIAL:LATE_SERIAL; do
        placeholder="${pair%%:*}"
        varname="${pair##*:}"
        value="${!varname}"
        content="${content//"@$placeholder@"/$value}"
    done
    printf '%s\n' "$content" > "$WORK_DIR/preseed.cfg"
}

fetch_index() {
    local index="$OUT_DIR/Packages-$DEBIAN_RELEASE-amd64"
    if [ ! -s "$index" ]; then
        echo "[*] Fetching package index for $DEBIAN_SUITE" >&2
        wget -q -O "$index.xz" \
            "$DEBIAN_MIRROR/dists/$DEBIAN_SUITE/main/binary-amd64/Packages.xz" \
            || { echo "[x] Cannot fetch the $DEBIAN_SUITE package index." >&2; exit 1; }
        xz -df "$index.xz"
    fi
    printf '%s\n' "$index"
}

index_to_table() {
    awk 'BEGIN { RS = ""; FS = "\n"; OFS = "|" }
    {
        name = fn = sha = deps = prov = ""
        for (i = 1; i <= NF; i++) {
            if      ($i ~ /^Package: /)     name = substr($i, 10)
            else if ($i ~ /^Filename: /)    fn   = substr($i, 11)
            else if ($i ~ /^SHA256: /)      sha  = substr($i, 9)
            else if ($i ~ /^Depends: /)     deps = deps ", " substr($i, 10)
            else if ($i ~ /^Pre-Depends: /) deps = deps ", " substr($i, 14)
            else if ($i ~ /^Provides: /)    prov = substr($i, 11)
        }
        if (name == "" || seen[name]++) next
        gsub(/\([^)]*\)|\[[^]]*\]|<[^>]*>|:any|:native/, "", deps)
        gsub(/\([^)]*\)/, "", prov)
        out = ""
        n = split(deps, clause, ",")
        for (i = 1; i <= n; i++) {
            split(clause[i], alt, "|")
            gsub(/^[ \t]+|[ \t]+$/, "", alt[1])
            if (alt[1] != "") out = out " " alt[1]
        }
        p = ""
        n = split(prov, pv, ",")
        for (i = 1; i <= n; i++) {
            gsub(/^[ \t]+|[ \t]+$/, "", pv[i])
            if (pv[i] != "") p = p " " pv[i]
        }
        print name, fn, sha, out, p
    }' "$1"
}

fetch_extra_debs() {
    [ -n "$EXTRA_DEBS" ] || return 0

    local tsv name fn sha deps prov dep
    declare -A FILE SHA DEPS PROVIDED_BY
    tsv=$(index_to_table "$(fetch_index)")
    while IFS='|' read -r name fn sha deps prov; do
        FILE["$name"]="$fn"; SHA["$name"]="$sha"; DEPS["$name"]="$deps"
        for dep in $prov; do
            [ -n "${PROVIDED_BY[$dep]:-}" ] || PROVIDED_BY["$dep"]="$name"
        done
    done <<< "$tsv"

    local -a queue
    read -r -a queue <<< "$EXTRA_DEBS"
    declare -A resolved
    while [ ${#queue[@]} -gt 0 ]; do
        name="${queue[0]}"; queue=("${queue[@]:1}")
        [ -n "${resolved[$name]:-}" ] && continue
        if [ -z "${FILE[$name]:-}" ]; then
            name="${PROVIDED_BY[$name]:-}"
            [ -n "$name" ] || continue
            [ -n "${resolved[$name]:-}" ] && continue
        fi
        resolved["$name"]=1
        for dep in ${DEPS[$name]}; do queue+=("$dep"); done
    done

    for name in $EXTRA_DEBS; do
        [ -n "${resolved[$name]:-}" ] ||
            { echo "[x] Package '$name' is not in $DEBIAN_SUITE/main/binary-amd64."; exit 1; }
    done

    mkdir -p "$WORK_DIR/custom/debs"
    local target from downloaded=0
    for name in "${!resolved[@]}"; do
        from=$(compgen -G "$WORK_DIR/pool/*/*/*/${name}_*.deb" | head -1) || from=""
        if [ -n "$from" ]; then
            cp "$from" "$WORK_DIR/custom/debs/"
            continue
        fi
        fn="${FILE[$name]}"
        target="$WORK_DIR/custom/debs/${fn##*/}"
        wget -q -O "$target" "$DEBIAN_MIRROR/$fn" \
            || { echo "[x] Download of $name failed."; exit 1; }
        echo "${SHA[$name]}  $target" | sha256sum -c --quiet \
            || { echo "[x] Checksum mismatch for $name."; exit 1; }
        downloaded=$((downloaded + 1))
    done
    echo "[*] Shipping ${#resolved[@]} packages, $downloaded of them not on the DVD"
}

patch_initrd() {
    local stage initrd
    stage=$(mktemp -d)
    cp "$WORK_DIR/preseed.cfg" "$stage/preseed.cfg"
    for initrd in "$WORK_DIR/install.amd/initrd.gz" "$WORK_DIR/install.amd/gtk/initrd.gz"; do
        [ -f "$initrd" ] || continue
        chmod u+w "$initrd"
        ( cd "$stage" && echo preseed.cfg | cpio -o -H newc --quiet ) | gzip -9 >> "$initrd"
        echo "[*] Preseed appended to ${initrd#"$WORK_DIR/"}"
    done
    rm -rf "$stage"
}

add_custom_files() {
    echo "[*] Rendering preseed.cfg and custom/ directory"
    render_preseed

    mkdir -p "$WORK_DIR/custom"
    cp "$SCRIPT_DIR/custom/ssh-host-keygen.service" \
       "$SCRIPT_DIR/custom/raid-setup.sh" \
       "$SCRIPT_DIR/custom/sync-esp.sh" \
       "$WORK_DIR/custom/"
    if [ "$ISO_VARIANT" = "offline" ]; then
        cp "$SCRIPT_DIR/custom/offline-post.sh" "$WORK_DIR/custom/"
    fi
    if [ -n "$SERIAL_CONSOLE" ]; then
        cp "$SCRIPT_DIR/custom/serial-console.sh" "$WORK_DIR/custom/"
    fi

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
        -V "$VOLUME_ID" \
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

    ( cd "$OUT_DIR" && sha256sum "${OUTPUT_ISO##*/}" > "${OUTPUT_ISO##*/}.sha256" )
    echo "[*] Wrote ${OUTPUT_ISO##*/}.sha256"
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
    patch_initrd
    fetch_extra_debs
    build_iso

    echo ""
    echo "  Done: $OUTPUT_ISO ($(du -sh "$OUTPUT_ISO" | cut -f1))"
    echo ""
    echo "  Write to USB stick:"
    echo "    sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    echo "  Verify the image, or the stick it was written to:"
    echo "    ( cd $OUT_DIR && sha256sum -c ${OUTPUT_ISO##*/}.sha256 )"
    echo "    sudo blockdev --flushbufs /dev/sdX"
    echo "    sudo head -c $(stat -c%s "$OUTPUT_ISO") /dev/sdX | sha256sum"
    echo "    $(cut -d' ' -f1 "$OUTPUT_ISO.sha256")  <- expected"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
