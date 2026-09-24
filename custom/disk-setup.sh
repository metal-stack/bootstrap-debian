#!/bin/sh

set -eu

INSTALL_DISK=""
DISKS=""
COUNT=0
SWAP="yes"

part() {
    case "$1" in
        *nvme*|*mmcblk*) echo "$1p$2" ;;
        *) echo "$1$2" ;;
    esac
}

parent_disk() {
    base=$(printf '%s' "$1" | sed -e 's/[0-9]*$//' -e 's/p$//')
    if [ -e "${SYS_BLOCK_DIR:-/sys/block}/${base##*/}" ]; then
        printf '%s\n' "$base"
    else
        printf '%s\n' "$1"
    fi
}

find_install_disk() {
    dev=$(awk '$2 == "/cdrom" { print $1 }' /proc/mounts | head -1)
    INSTALL_DISK=""
    if [ -n "$dev" ]; then
        INSTALL_DISK=$(parent_disk "$dev")
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

largest_disks() {
    printf '%s' "$DISKS" | sort -k1,1rn -k2,2 | head -"$1" | cut -d' ' -f2
}

found_disks() {
    printf '%s' "$DISKS" | cut -d' ' -f2 | tr '\n' ' '
}

setup_raid1() {
    if [ "$COUNT" -lt 2 ]; then
        echo "disk-setup: RAID1 needs two disks, found $COUNT ($(found_disks))" >&2
        echo "disk-setup: rebuild the ISO with DISK_LAYOUT=single to install on one disk" >&2
        exit 1
    fi
    PAIR=$(largest_disks 2)
    D1=$(echo "$PAIR" | sed -n 1p)
    D2=$(echo "$PAIR" | sed -n 2p)
    echo "disk-setup: RAID1 across $D1 and $D2" >&2

    debconf-set partman-auto/disk "$D1 $D2"
    debconf-set grub-installer/bootdev "$D1 $D2"

    RECIPE="1 2 0 ext4 /boot $(part "$D1" 3)#$(part "$D2" 3) ."
    RECIPE="$RECIPE 1 2 0 lvm - $(part "$D1" 4)#$(part "$D2" 4) ."
    if [ "$SWAP" = yes ]; then
        RECIPE="$RECIPE 1 2 0 swap - $(part "$D1" 5)#$(part "$D2" 5) ."
    fi
    debconf-set partman-auto-raid/recipe "$RECIPE"
    part "$D2" 2 > /tmp/esp2
}

setup_single() {
    if [ "$COUNT" -lt 1 ]; then
        echo "disk-setup: no disk found besides the install medium" >&2
        echo "disk-setup: check that the controller is in AHCI mode and the disk is seen by the BIOS" >&2
        exit 1
    fi
    D1=$(largest_disks 1)
    echo "disk-setup: single disk on $D1 ($COUNT found: $(found_disks))" >&2

    debconf-set partman-auto/disk "$D1"
    debconf-set grub-installer/bootdev "$D1"
}

main() {
    SWAP="${2:-yes}"
    find_install_disk
    collect_disks

    case "${1:-raid1}" in
        raid1)  setup_raid1 ;;
        single) setup_single ;;
        *)
            echo "disk-setup: unknown layout '$1', expected raid1 or single" >&2
            exit 1 ;;
    esac
}

if [ "${0##*/}" = "disk-setup.sh" ]; then
    main "$@"
fi
