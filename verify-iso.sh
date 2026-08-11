#!/usr/bin/env bash
set -euo pipefail

iso="out/debian-$DEBIAN_RELEASE-unattended.iso"
check=$(mktemp -d)

xorriso -report_about FAILURE -osirrox on -indev "$iso" \
  -extract /preseed.cfg          "$check/preseed.cfg" \
  -extract /boot/grub/grub.cfg   "$check/grub.cfg" \
  -extract /isolinux/txt.cfg     "$check/txt.cfg" \
  -extract /custom               "$check/custom" --

! grep -qE '@[A-Z_]+@' "$check/preseed.cfg" \
  || { echo "unsubstituted placeholders in preseed"; exit 1; }

suite=$(bash -c 'source "$1" >/dev/null; echo "$DEBIAN_SUITE"' _ ./build-iso.sh)
grep -q "^d-i mirror/suite string ${suite}$" "$check/preseed.cfg"

grep -q 'preseed/file=/cdrom/preseed.cfg' "$check/grub.cfg"
grep -q 'preseed/file=/cdrom/preseed.cfg' "$check/txt.cfg"
grep -q "^set timeout=1$" "$check/grub.cfg"

test -s "$check/custom/authorized_keys"
test -s "$check/custom/raid-setup.sh"
echo "ISO verified"