#!/bin/sh
set -e

SUITE=""

write_sources() {
    echo "offline-post: pointing apt at the network mirror" >&2
    rm -f /target/etc/apt/sources.list.d/*.list /target/etc/apt/sources.list.d/*.sources
    mkdir -p /target/etc/apt

    cat > /target/etc/apt/sources.list <<CONF
deb http://deb.debian.org/debian $SUITE main non-free-firmware
deb-src http://deb.debian.org/debian $SUITE main non-free-firmware

deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware
deb-src http://security.debian.org/debian-security $SUITE-security main non-free-firmware

deb http://deb.debian.org/debian $SUITE-updates main non-free-firmware
deb-src http://deb.debian.org/debian $SUITE-updates main non-free-firmware
CONF
}

install_shipped_debs() {
    [ -d /target/custom/debs ] || return 0
    echo "offline-post: installing extra packages from the ISO" >&2

    in-target sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts=/dev/null \
        /custom/debs/*.deb'

    cat > /target/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
}

main() {
    SUITE="${1:-}"
    [ -n "$SUITE" ] || { echo "offline-post: no suite given" >&2; exit 1; }
    write_sources
    install_shipped_debs
}

main "$@"
