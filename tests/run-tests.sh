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

# --- ISO variants ---------------------------------------------------------

if ISO_VARIANT=dvd bash -c \
    'source "$1" >/dev/null; check_deps' _ "$SCRIPT_DIR/build-iso.sh" &>/dev/null; then
    fail "unknown ISO_VARIANT should abort"
else
    ok "unknown ISO_VARIANT aborts"
fi

for pair in netinst:iso-cd/debian-13.6.0-amd64-netinst.iso \
            offline:iso-dvd/debian-13.6.0-amd64-DVD-1.iso; do
    variant="${pair%%:*}"; want="${pair##*:}"
    got=$(ISO_VARIANT="$variant" bash -c \
        'source "$1" >/dev/null; echo "${DEBIAN_ISO_URLS[0]}"' _ "$SCRIPT_DIR/build-iso.sh")
    case "$got" in
        *"$want") ok "$variant downloads $want" ;;
        *)        fail "$variant: want *$want, got '$got'" ;;
    esac
done

# --- checksum verification ------------------------------------------------

blob=$(mktemp)
head -c 4096 /dev/urandom > "$blob"
good=$(sha256sum "$blob" | cut -d' ' -f1)

validate() {
    bash -c 'source "$1" >/dev/null; validate_iso "$2" "$3"' \
        _ "$SCRIPT_DIR/build-iso.sh" "$1" "$2" &>/dev/null
}
validate "$blob" "$good" \
    && ok "matching checksum accepted" || fail "matching checksum rejected"
validate "$blob" "$(printf '%064d' 0)" \
    && fail "wrong checksum accepted" || ok "wrong checksum rejected"
validate /nonexistent/iso "$good" \
    && fail "missing file validates" || ok "missing file does not validate"
rm -f "$blob"

# --- SHA256SUMS signature policy ------------------------------------------

sig() {
    CHECK_SIGNATURE="$1" bash -c \
        'source "$1" >/dev/null; check_sums_signature "$2" "$3"' \
        _ "$SCRIPT_DIR/build-iso.sh" /dev/null /nonexistent/sig &>/dev/null
}
sig no   && ok "CHECK_SIGNATURE=no skips the check" || fail "CHECK_SIGNATURE=no aborted"
sig auto && ok "CHECK_SIGNATURE=auto warns and continues" || fail "auto aborted"
sig yes  && fail "CHECK_SIGNATURE=yes accepted a missing signature" \
         || ok "CHECK_SIGNATURE=yes aborts without a signature"

if bash -c '
        source "$1" >/dev/null
        WORK_DIR=$(mktemp -d); OUT_DIR="$WORK_DIR"; SRC_ISO="$WORK_DIR/iso"
        echo payload > "$SRC_ISO"
        sha256sum "$SRC_ISO" | cut -d" " -f1 > "$SRC_ISO.sha256"
        fetch_sums() { : > "$WORK_DIR/SHA256SUMS"; return 0; }
        check_sums_signature() { exit 1; }
        download_iso
    ' _ "$SCRIPT_DIR/build-iso.sh" &>/dev/null; then
    fail "a signature abort does not stop the build"
else
    ok "a signature abort stops the build"
fi

keys=$(bash -c 'source "$1" >/dev/null; echo "$DEBIAN_CD_KEYS"' _ "$SCRIPT_DIR/build-iso.sh")
grep -qxF 'DF9B9C49EAA9298432589D76DA87E80D6294BE9B' <<< "$keys" \
    && ok "trixie CD signing key is trusted" || fail "trixie CD signing key missing"
grep -qxF 'DEADBEEF' <<< "$keys" \
    && fail "allowlist matches a bogus key" || ok "allowlist rejects an unknown key"

# --- package index parsing ------------------------------------------------

fixture=$(mktemp)
cat > "$fixture" <<'INDEX'
Package: nodeps
Version: 1.0
Filename: pool/main/n/nodeps/nodeps_1.0_all.deb
SHA256: aaaa
Provides: virtual-thing

Package: withdeps
Version: 2.0
Filename: pool/main/w/withdeps/withdeps_2.0_all.deb
SHA256: bbbb
Depends: nodeps (>= 1.0) | other, third:any
Pre-Depends: fourth
INDEX
table=$(bash -c 'source "$1" >/dev/null; index_to_table "$2"' _ "$SCRIPT_DIR/build-iso.sh" "$fixture")
rm -f "$fixture"

want='nodeps|pool/main/n/nodeps/nodeps_1.0_all.deb|aaaa|| virtual-thing'
grep -qxF "$want" <<< "$table" \
    && ok "index: empty Depends keeps Provides in its own field" \
    || fail "index: got '$(grep '^nodeps|' <<< "$table")'"

want='withdeps|pool/main/w/withdeps/withdeps_2.0_all.deb|bbbb| nodeps third fourth|'
grep -qxF "$want" <<< "$table" \
    && ok "index: versions stripped, first alternative taken" \
    || fail "index: got '$(grep '^withdeps|' <<< "$table")'"

# --- preseed rendering ----------------------------------------------------

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() {
    ISO_VARIANT="$1" bash -c '
        source "$1" >/dev/null
        WORK_DIR="$2"
        USER_HASH="$3"
        render_preseed
    ' _ "$SCRIPT_DIR/build-iso.sh" "$tmp" '$6$test$hash'
    mv "$tmp/preseed.cfg" "$tmp/preseed.$1" ||
        { fail "$1: render_preseed produced no preseed.cfg"; exit 1; }
}
render netinst
render offline

for variant in netinst offline; do
    if grep -qE '@[A-Z_]+@' "$tmp/preseed.$variant"; then
        fail "$variant: unsubstituted placeholders: $(grep -oE '@[A-Z_]+@' "$tmp/preseed.$variant" | sort -u | tr '\n' ' ')"
    else
        ok "$variant: no unsubstituted placeholders"
    fi
done

grep -q '^d-i mirror/suite string trixie$' "$tmp/preseed.netinst" \
    && ok "mirror/suite rendered" || fail "mirror/suite not rendered"

cat > "$tmp/expected-keys" <<'KEYS'
d-i apt-setup/services-select
d-i apt-setup/use_mirror
d-i netcfg/confirm_static
d-i netcfg/dhcp_failed
d-i netcfg/dhcp_options
d-i netcfg/get_nameservers
d-i netcfg/no_default_route
d-i pkgsel/update-policy
d-i pkgsel/upgrade
sh /cdrom/custom/sync-esp.sh;
KEYS
diff "$tmp/preseed.netinst" "$tmp/preseed.offline" \
    | sed -n 's/^[<>] *//p' | sed 's/^# //' \
    | awk '{ print $1, $2 }' | sort -u > "$tmp/actual-keys"
if diff -q "$tmp/expected-keys" "$tmp/actual-keys" >/dev/null; then
    ok "offline variant differs in exactly the expected keys"
else
    fail "offline delta drifted:$(diff "$tmp/expected-keys" "$tmp/actual-keys" | tr '\n' ' ')"
fi

grep -q '^d-i apt-setup/use_mirror boolean false$' "$tmp/preseed.offline" \
    && ok "offline: mirror disabled" || fail "offline: mirror not disabled"
grep -q '^# d-i apt-setup/use_mirror boolean false$' "$tmp/preseed.netinst" \
    && ok "netinst: mirror still used" || fail "netinst: use_mirror leaked in"
grep -q 'sh /cdrom/custom/offline-post.sh trixie;' "$tmp/preseed.offline" \
    && ok "offline: late_command calls offline-post.sh" \
    || fail "offline: offline-post.sh not called"

exit "$FAILED"
