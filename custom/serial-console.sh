#!/bin/sh

set -e

DEFAULTS=/target/etc/default/grub

set_grub_terminal() {
    if grep -q '^GRUB_TERMINAL=' "$DEFAULTS"; then
        sed -i 's|^GRUB_TERMINAL=.*|GRUB_TERMINAL="console serial"|' "$DEFAULTS"
    else
        echo 'GRUB_TERMINAL="console serial"' >> "$DEFAULTS"
    fi
    echo 'serial-console: GRUB_TERMINAL="console serial"' >&2
}

main() {
    [ -f "$DEFAULTS" ] || { echo "serial-console: no $DEFAULTS, skipping" >&2; exit 0; }
    set_grub_terminal
    in-target update-grub
}

main "$@"
