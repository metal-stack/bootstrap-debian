#!/bin/sh

INSTALL_DISK=""
DISKS=""
COUNT=0

part() {
    case "$1" in
        *nvme*|*mmcblk*) echo "$1p$2" ;;
        *) echo "$1$2" ;;
    esac
}

find_install_disk() {
    dev=$(awk '$2 == "/cdrom" { print $1 }' /proc/mounts | head -1)
    INSTALL_DISK=""
    if [ -n "$dev" ]; then
        INSTALL_DISK=$(echo "$dev" | sed -e 's/[0-9]*$//' -e 's/p$//')
    fi
}

collect_disks() {
    DISKS=""
    COUNT=0
    for dev in $(list-devices disk); do
        [ "$dev" = "$INSTALL_DISK" ] && continue
        SIZE=$(cat "/sys/block/${dev##*/}/size" 2>/dev/null || echo 0)
        DISKS="$DISKS$SIZE $dev
"
        COUNT=$((COUNT + 1))
    done
}

preseed_raid() {
    debconf-set partman-auto/disk "$D1 $D2"
    debconf-set grub-installer/bootdev "$D1 $D2"
    debconf-set partman-auto-raid/recipe \
        "1 2 0 ext4 /boot $(part "$D1" 3)#$(part "$D2" 3) . 1 2 0 lvm - $(part "$D1" 4)#$(part "$D2" 4) . 1 2 0 swap - $(part "$D1" 5)#$(part "$D2" 5) ."
}

main() {
    find_install_disk
    collect_disks

    if [ "$COUNT" -lt 2 ]; then
        echo "raid-setup: RAID1 needs two disks, found $COUNT ($(echo "$DISKS" | cut -d' ' -f2))" >&2
        exit 1
    fi

    PAIR=$(printf '%s' "$DISKS" | sort -k1,1rn -k2,2 | head -2 | cut -d' ' -f2)
    D1=$(echo "$PAIR" | sed -n 1p)
    D2=$(echo "$PAIR" | sed -n 2p)
    echo "raid-setup: using $D1 and $D2" >&2

    preseed_raid
    part "$D2" 2 > /tmp/esp2
}

main "$@"
