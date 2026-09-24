#!/usr/bin/env bash
set -euo pipefail

source ./build-iso.sh >/dev/null

CHECK=""

die() { echo "$1"; exit 1; }

check_checksum() {
    [ -s "$OUTPUT_ISO.sha256" ] || die "no ${OUTPUT_ISO##*/}.sha256 next to the ISO"
    ( cd "$OUT_DIR" && sha256sum -c --quiet "${OUTPUT_ISO##*/}.sha256" ) \
      || die "ISO does not match its own checksum file"
}

extract_iso() {
    xorriso -report_about FAILURE -osirrox on -indev "$OUTPUT_ISO" \
      -extract /preseed.cfg          "$CHECK/preseed.cfg" \
      -extract /boot/grub/grub.cfg   "$CHECK/grub.cfg" \
      -extract /isolinux/txt.cfg     "$CHECK/txt.cfg" \
      -extract /isolinux/isolinux.cfg "$CHECK/isolinux.cfg" \
      -extract /custom               "$CHECK/custom" --
    chmod -R u+w "$CHECK"
}

check_preseed() {
    ! grep -qE '@[A-Z_]+@' "$CHECK/preseed.cfg" || die "unsubstituted placeholders in preseed"
    grep -q "^d-i mirror/suite string ${DEBIAN_SUITE}$" "$CHECK/preseed.cfg"
}

check_boot_entries() {
    grep -q 'preseed/file=/preseed.cfg' "$CHECK/grub.cfg"
    grep -q 'preseed/file=/preseed.cfg' "$CHECK/txt.cfg"
    grep -q "^set timeout=1$" "$CHECK/grub.cfg"
    grep -q "^set default='Install'$" "$CHECK/grub.cfg"
    grep -q "^menuentry --hotkey=i 'Install' {$" "$CHECK/grub.cfg"
    grep -q '^ontimeout install$' "$CHECK/isolinux.cfg"
    grep -q '^label install$' "$CHECK/txt.cfg"
}

check_initrd() {
    local marker markers
    xorriso -report_about FAILURE -osirrox on -indev "$OUTPUT_ISO" \
      -extract /install.amd/initrd.gz "$CHECK/initrd.gz" -- 2>/dev/null
    chmod u+w "$CHECK/initrd.gz"
    gzip -dc "$CHECK/initrd.gz" > "$CHECK/initrd.cpio" 2>/dev/null || true
    grep -qa 'preseed\.cfg' "$CHECK/initrd.cpio" || die "no preseed.cfg in the initrd"

    markers=("d-i passwd/username string $ADMIN_USER"
             "d-i mirror/suite string $DEBIAN_SUITE")
    if [ -n "$SERIAL_CONSOLE" ]; then
        markers+=("d-i debian-installer/add-kernel-opts string $CONSOLE_ARGS")
    fi
    for marker in "${markers[@]}"; do
        grep -qaF "$marker" "$CHECK/initrd.cpio" \
          || die "initrd preseed is stale: no '$marker'"
    done
}

check_serial_console() {
    local f line
    for f in "$CHECK/txt.cfg" "$CHECK/grub.cfg"; do
        line=$(grep -m1 -- '---' "$f") || die "no --- marker in ${f##*/}"
        case "${line%%---*}" in
            *"console=$SERIAL_CONSOLE"*) ;;
            *) die "${f##*/}: no console=$SERIAL_CONSOLE before the --- marker" ;;
        esac
    done
    grep -qx "serial $SERIAL_UNIT $SERIAL_SPEED" "$CHECK/isolinux.cfg" \
      || die "isolinux.cfg has no SERIAL directive"
    grep -qx "serial --unit=$SERIAL_UNIT --speed=$SERIAL_SPEED" "$CHECK/grub.cfg" \
      || die "grub.cfg has no serial command"
    test -s "$CHECK/custom/serial-console.sh"
}

check_no_serial_console() {
    ! grep -q 'console=' "$CHECK/txt.cfg" \
      || die "console= in txt.cfg although SERIAL_CONSOLE is unset"
    ! grep -q '^d-i debian-installer/add-kernel-opts' "$CHECK/preseed.cfg" \
      || die "add-kernel-opts set although SERIAL_CONSOLE is unset"
}

check_custom_files() {
    test -s "$CHECK/custom/authorized_keys"
    test -s "$CHECK/custom/disk-setup.sh"
}

check_early_command() {
    grep -q "disk-setup.sh $DISK_LAYOUT $HAS_SWAP\$" "$CHECK/preseed.cfg" \
      || die "preseed does not hand '$DISK_LAYOUT $HAS_SWAP' to disk-setup.sh"
}

check_swap() {
    case "$HAS_SWAP:$SWAP_SIZE" in
        no:*)
            ! grep -qE 'lv_swap|method\{ swap \}' "$CHECK/preseed.cfg" \
              || die "SWAP_SIZE=0 but the recipe still carries a swap LV"
            [ "$(grep -c 'method{ raid }' "$CHECK/preseed.cfg")" -le 2 ] \
              || die "SWAP_SIZE=0 but the recipe still carries a third RAID partition for swap"
            grep -q "disk-setup.sh $DISK_LAYOUT no\$" "$CHECK/preseed.cfg" \
              || die "SWAP_SIZE=0 but disk-setup.sh is not told so, raid1 would build a swap array" ;;
        yes:)
            grep -qE "^ +$DEFAULT_SWAP_MIN $DEFAULT_SWAP_PRIO 200% (raid|linux-swap) " "$CHECK/preseed.cfg" \
              || die "SWAP_SIZE is empty but the $DISK_LAYOUT recipe has no '$DEFAULT_SWAP_MIN $DEFAULT_SWAP_PRIO 200%' swap stanza" ;;
        yes:*)
            grep -qE "^ +$SWAP_SIZE $SWAP_SIZE $SWAP_SIZE (raid|linux-swap) " "$CHECK/preseed.cfg" \
              || die "SWAP_SIZE=$SWAP_SIZE but the recipe has no swap stanza of that size" ;;
    esac
}

check_raid1_layout() {
    grep -q '^d-i partman-auto/method string raid$' "$CHECK/preseed.cfg" \
      || die "raid1 ISO does not drive partman with method raid"
    grep -q '^d-i partman-auto/choose_recipe select multiraid$' "$CHECK/preseed.cfg" \
      || die "raid1 ISO does not select the multiraid recipe"
    grep -q '^d-i pkgsel/include string .*mdadm' "$CHECK/preseed.cfg" \
      || die "raid1 ISO does not install mdadm"
}

check_single_layout() {
    grep -q '^d-i partman-auto/method string lvm$' "$CHECK/preseed.cfg" \
      || die "single ISO does not drive partman with method lvm"
    grep -q '^d-i partman-auto/choose_recipe select singledisk$' "$CHECK/preseed.cfg" \
      || die "single ISO does not select the singledisk recipe"
    grep -q 'method{ lvm }' "$CHECK/preseed.cfg" \
      || die "single recipe declares no LVM physical volume"
    ! grep -q 'lvmignore' "$CHECK/preseed.cfg" \
      || die "single recipe carries \$lvmignore, which method lvm drops: the ESP and /boot would vanish"
}

check_netinst() {
    grep -q '^# d-i apt-setup/use_mirror boolean false$' "$CHECK/preseed.cfg"
    grep -q '^d-i pkgsel/update-policy select unattended-upgrades$' "$CHECK/preseed.cfg"
}

check_offline() {
    local pkg
    grep -q '^d-i apt-setup/use_mirror boolean false$' "$CHECK/preseed.cfg"
    grep -qaF 'd-i apt-setup/use_mirror boolean false' "$CHECK/initrd.cpio" \
      || die "the initrd carries a netinst preseed"
    grep -q '^d-i netcfg/dhcp_failed note$' "$CHECK/preseed.cfg"
    grep -q 'offline-post.sh' "$CHECK/preseed.cfg"
    test -s "$CHECK/custom/offline-post.sh"
    for pkg in $EXTRA_DEBS; do
        compgen -G "$CHECK/custom/debs/${pkg}_*.deb" >/dev/null \
          || die "missing $pkg deb on the ISO"
    done
}

check_shipped_deb_deps() {
    local have d dep
    command -v dpkg-deb >/dev/null || die "dpkg-deb is needed to check the shipped debs"
    have=" $(for d in "$CHECK"/custom/debs/*.deb; do
                 dpkg-deb -f "$d" Package Provides |
                     sed 's/^[^:]*: //; s/([^)]*)//g; s/,/ /g'
             done | tr -s ' \n' '  ') "
    for d in "$CHECK"/custom/debs/*.deb; do
        for dep in $(dpkg-deb -f "$d" Depends Pre-Depends |
                         sed 's/^[^:]*: //; s/([^)]*)//g; s/:any//g' |
                         tr ',' '\n' | cut -d'|' -f1 | tr -d ' '); do
            case "$have" in
                *" $dep "*) ;;
                *) die "$(basename "$d"): dependency $dep is not on the ISO" ;;
            esac
        done
    done
}

main() {
    CHECK=$(mktemp -d)
    trap 'rm -rf "$CHECK"' EXIT

    check_checksum
    extract_iso
    check_preseed
    check_boot_entries
    check_initrd
    if [ -n "$SERIAL_CONSOLE" ]; then
        check_serial_console
    else
        check_no_serial_console
    fi
    check_custom_files
    check_early_command
    case "$DISK_LAYOUT" in
        raid1)  check_raid1_layout ;;
        single) check_single_layout ;;
    esac
    check_swap
    case "$ISO_VARIANT" in
        netinst) check_netinst ;;
        offline) check_offline; check_shipped_deb_deps ;;
    esac

    echo "ISO verified ($ISO_VARIANT, $DISK_LAYOUT, swap=${SWAP_SIZE:-default})"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
