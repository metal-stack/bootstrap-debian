#!/bin/sh

set -eu

TARGET_ROOT="${TARGET_ROOT:-/target}"
INSTALLER_INTERFACES="${INSTALLER_INTERFACES:-/etc/network/interfaces}"
SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"
NETWORK_FILE="$TARGET_ROOT/etc/systemd/network/99-installer-dhcp.network"

detect_dhcp_interface() {
    awk '$1 == "iface" && $3 == "inet" && $4 == "dhcp" { print $2; exit }' "$INSTALLER_INTERFACES"
}

render_network_file() {
    mkdir -p "${NETWORK_FILE%/*}"
    cat > "$NETWORK_FILE" <<CONF
[Match]
MACAddress=$1

[Network]
DHCP=yes
CONF
    echo "networkd-handover: $NETWORK_FILE matches $1" >&2
}

main() {
    iface=$(detect_dhcp_interface)
    if [ -z "$iface" ]; then
        echo "networkd-handover: the installer configured no DHCP interface, ifupdown stays" >&2
        exit 0
    fi
    render_network_file "$(cat "$SYS_CLASS_NET/$iface/address")"
    in-target systemctl enable systemd-networkd
    in-target apt-get purge -y ifupdown
}

if [ "${0##*/}" = "networkd-handover.sh" ]; then
    main "$@"
fi
