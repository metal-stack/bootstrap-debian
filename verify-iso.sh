#!/usr/bin/env bash
set -euo pipefail

source ./build-iso.sh >/dev/null

check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT

[ -s "$OUTPUT_ISO.sha256" ] || { echo "no ${OUTPUT_ISO##*/}.sha256 next to the ISO"; exit 1; }
( cd "$OUT_DIR" && sha256sum -c --quiet "${OUTPUT_ISO##*/}.sha256" ) \
  || { echo "ISO does not match its own checksum file"; exit 1; }

xorriso -report_about FAILURE -osirrox on -indev "$OUTPUT_ISO" \
  -extract /preseed.cfg          "$check/preseed.cfg" \
  -extract /boot/grub/grub.cfg   "$check/grub.cfg" \
  -extract /isolinux/txt.cfg     "$check/txt.cfg" \
  -extract /isolinux/isolinux.cfg "$check/isolinux.cfg" \
  -extract /custom               "$check/custom" --
chmod -R u+w "$check"

! grep -qE '@[A-Z_]+@' "$check/preseed.cfg" \
  || { echo "unsubstituted placeholders in preseed"; exit 1; }

grep -q "^d-i mirror/suite string ${DEBIAN_SUITE}$" "$check/preseed.cfg"

grep -q 'preseed/file=/preseed.cfg' "$check/grub.cfg"
grep -q 'preseed/file=/preseed.cfg' "$check/txt.cfg"
grep -q "^set timeout=1$" "$check/grub.cfg"

grep -q "^set default='Install'$" "$check/grub.cfg"
grep -q "^menuentry --hotkey=i 'Install' {$" "$check/grub.cfg"
grep -q '^ontimeout install$' "$check/isolinux.cfg"
grep -q '^label install$' "$check/txt.cfg"

# The initrd copy is what answers the network questions; without it the install
# stops at "Configure the network" on any machine where DHCP does not answer.
xorriso -report_about FAILURE -osirrox on -indev "$OUTPUT_ISO" \
  -extract /install.amd/initrd.gz "$check/initrd.gz" -- 2>/dev/null
chmod u+w "$check/initrd.gz"
gzip -dc "$check/initrd.gz" > "$check/initrd.cpio" 2>/dev/null || true
grep -qa 'preseed\.cfg' "$check/initrd.cpio" \
  || { echo "no preseed.cfg in the initrd"; exit 1; }

for marker in "d-i passwd/username string $ADMIN_USER" \
              "d-i mirror/suite string $DEBIAN_SUITE"; do
    grep -qaF "$marker" "$check/initrd.cpio" \
      || { echo "initrd preseed is stale: no '$marker'"; exit 1; }
done

test -s "$check/custom/authorized_keys"
test -s "$check/custom/raid-setup.sh"

case "$ISO_VARIANT" in
    netinst)
        grep -q '^# d-i apt-setup/use_mirror boolean false$' "$check/preseed.cfg"
        grep -q '^d-i pkgsel/update-policy select unattended-upgrades$' "$check/preseed.cfg"
        ;;
    offline)
        grep -q '^d-i apt-setup/use_mirror boolean false$' "$check/preseed.cfg"
        grep -qaF 'd-i apt-setup/use_mirror boolean false' "$check/initrd.cpio" \
          || { echo "the initrd carries a netinst preseed"; exit 1; }
        grep -q '^d-i netcfg/dhcp_failed note$' "$check/preseed.cfg"
        grep -q 'offline-post.sh' "$check/preseed.cfg"
        test -s "$check/custom/offline-post.sh"
        for pkg in $EXTRA_DEBS; do
            compgen -G "$check/custom/debs/${pkg}_*.deb" >/dev/null \
              || { echo "missing $pkg deb on the ISO"; exit 1; }
        done

        command -v dpkg-deb >/dev/null \
          || { echo "dpkg-deb is needed to check the shipped debs"; exit 1; }
        have=" $(for d in "$check"/custom/debs/*.deb; do
                     dpkg-deb -f "$d" Package Provides |
                         sed 's/^[^:]*: //; s/([^)]*)//g; s/,/ /g'
                 done | tr -s ' \n' '  ') "
        for d in "$check"/custom/debs/*.deb; do
            for dep in $(dpkg-deb -f "$d" Depends Pre-Depends |
                             sed 's/^[^:]*: //; s/([^)]*)//g; s/:any//g' |
                             tr ',' '\n' | cut -d'|' -f1 | tr -d ' '); do
                case "$have" in
                    *" $dep "*) ;;
                    *) echo "$(basename "$d"): dependency $dep is not on the ISO"; exit 1 ;;
                esac
            done
        done
        ;;
esac

echo "ISO verified ($ISO_VARIANT)"
