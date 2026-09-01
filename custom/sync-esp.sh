#!/bin/sh

FSTAB=/target/etc/fstab
MNT=/tmp/esp2-mnt

make_esp_nonfatal() {
    [ -f "$FSTAB" ] || return 0
    grep -q '^[^#]*[[:space:]]/boot/efi' "$FSTAB" || return 0
    awk 'BEGIN { OFS = "\t" }
         $1 !~ /^#/ && $2 == "/boot/efi" && $0 !~ /nofail/ { $4 = $4 ",nofail,x-systemd.device-timeout=5" }
         { print }' "$FSTAB" > "$FSTAB.new" &&
        mv "$FSTAB.new" "$FSTAB" &&
        echo "sync-esp: made /boot/efi non-fatal in fstab" >&2
}

mirror_esp() {
    esp2=$(cat /tmp/esp2 2>/dev/null) ||
        { echo "sync-esp: no second ESP recorded, skipping copy" >&2; return 0; }
    [ -d /target/boot/efi/EFI ] ||
        { echo "sync-esp: no EFI install, skipping copy" >&2; return 0; }

    mkdir -p "$MNT"
    mount "$esp2" "$MNT" 2>/dev/null ||
        { echo "sync-esp: cannot mount $esp2, skipping copy" >&2; return 0; }

    cp -a /target/boot/efi/. "$MNT"/ && echo "sync-esp: mirrored ESP to $esp2" >&2
    umount "$MNT"
}

main() {
    make_esp_nonfatal
    mirror_esp
}

main "$@"
