#!/usr/bin/env bash
# Tests that need neither network nor root. Sources build-iso.sh and calls
# its functions directly - main() is guarded by the BASH_SOURCE check.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

ok()   { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; FAILED=1; }

# --- suite lookup ---------------------------------------------------------

for pair in 11:bullseye 12:bookworm 13:trixie 14:forky; do
    major="${pair%%:*}"; want="${pair##*:}"
    got=$(DEBIAN_RELEASE="$major.0.0" DEBIAN_SUITE="" bash -c \
        'source "$1" >/dev/null; echo "$DEBIAN_SUITE"' _ "$SCRIPT_DIR/build-iso.sh")
    [ "$got" = "$want" ] && ok "suite $major -> $want" || fail "suite $major: want $want, got '$got'"
done

if DEBIAN_RELEASE=99.0.0 DEBIAN_SUITE="" bash -c \
    'source "$1" >/dev/null; check_deps' _ "$SCRIPT_DIR/build-iso.sh" &>/dev/null; then
    fail "unknown major should abort"
else
    ok "unknown major aborts"
fi

# --- LV bounds validation -------------------------------------------------

if LV_VAR_MIN=50000 LV_VAR_MAX=10000 bash -c \
    'source "$1" >/dev/null; check_deps' _ "$SCRIPT_DIR/build-iso.sh" &>/dev/null; then
    fail "LV_VAR_MIN > LV_VAR_MAX should abort"
else
    ok "LV_VAR_MIN > LV_VAR_MAX aborts"
fi

if LV_VAR_MIN=10G bash -c \
    'source "$1" >/dev/null; check_deps' _ "$SCRIPT_DIR/build-iso.sh" &>/dev/null; then
    fail "non-integer LV_VAR_MIN should abort"
else
    ok "non-integer LV_VAR_MIN aborts"
fi

# --- preseed rendering ----------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(
    source "$SCRIPT_DIR/build-iso.sh" >/dev/null
    WORK_DIR="$tmp"
    USER_HASH='$6$test$hash'
    render_preseed
)
if grep -qE '@[A-Z_]+@' "$tmp/preseed.cfg"; then
    fail "unsubstituted placeholders: $(grep -oE '@[A-Z_]+@' "$tmp/preseed.cfg" | sort -u | tr '\n' ' ')"
else
    ok "no unsubstituted placeholders"
fi

grep -q '^d-i mirror/suite string trixie$' "$tmp/preseed.cfg" \
    && ok "mirror/suite rendered" || fail "mirror/suite not rendered"

exit "$FAILED"
