#!/bin/sh

FSTAB=/target/etc/fstab

if [ -f "$FSTAB" ] && grep -q '^[^#]*[[:space:]]/boot/efi' "$FSTAB"; then
    awk 'BEGIN { OFS = "\t" }
         $1 !~ /^#/ && $2 == "/boot/efi" && $0 !~ /nofail/ { $4 = $4 ",nofail,x-systemd.device-timeout=5" }
         { print }' "$FSTAB" > "$FSTAB.new" &&
        mv "$FSTAB.new" "$FSTAB" &&
        echo "sync-esp: made /boot/efi non-fatal in fstab" >&2
fi

ESP2=$(cat /tmp/esp2 2>/dev/null) || { echo "sync-esp: no second ESP recorded, skipping copy" >&2; exit 0; }
[ -d /target/boot/efi/EFI ] || { echo "sync-esp: no EFI install, skipping copy" >&2; exit 0; }

mkdir -p /tmp/esp2-mnt
mount "$ESP2" /tmp/esp2-mnt 2>/dev/null || { echo "sync-esp: cannot mount $ESP2, skipping copy" >&2; exit 0; }

cp -a /target/boot/efi/. /tmp/esp2-mnt/ && echo "sync-esp: mirrored ESP to $ESP2" >&2
umount /tmp/esp2-mnt
