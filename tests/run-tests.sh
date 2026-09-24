#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build-iso.sh"
TMP=""
STUB=""
PASSED=0
FAILED=0

pass() { echo "  ok   - $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL - $1"; [ $# -gt 1 ] && echo "         $2"; FAILED=$((FAILED + 1)); }

run() {
    local code="$1"; shift
    BUILD="$BUILD" bash -c "source \"\$BUILD\"
$code" _ "$@" 2>&1
}

smoke() {
    local code="$1"; shift
    SMOKE="$REPO/tests/boot-smoke.sh" bash -c "source \"\$SMOKE\"
$code" _ "$@" 2>&1
}

equals() {
    [ "$3" = "$2" ] && pass "$1" || fail "$1" "want '$2', got '$3'"
}

succeeds() {
    local name="$1" out; shift
    if out=$(run "$@"); then pass "$name"; else fail "$name" "$out"; fi
}

rejects() {
    local name="$1" out; shift
    if out=$(run "$@"); then fail "$name" "did not fail: $out"; else pass "$name"; fi
}

aborts() {
    local name="$1" want="$2" out; shift 2
    if out=$(run "$@");             then fail "$name" "did not abort: $out"
    elif [[ "$out" != *"$want"* ]]; then fail "$name" "aborted with: $out"
    else pass "$name"; fi
}

has() {
    grep -qE -- "$3" "$2" && pass "$1" || fail "$1" "no match for '$3' in $2"
}

lacks() {
    [ -f "$2" ] || { fail "$1" "no such file: $2"; return; }
    grep -qE -- "$3" "$2" \
        && fail "$1" "found: $(grep -m1 -E -- "$3" "$2")" \
        || pass "$1"
}

make_tool_stubs() {
    local tool
    mkdir -p "$STUB"
    for tool in xorriso wget dd sed mkpasswd sha256sum cpio gzip xz; do
        printf '#!/bin/sh\nexit 0\n' > "$STUB/$tool"
        chmod +x "$STUB/$tool"
    done
}
deps_ok()    { PATH="$STUB:$PATH" succeeds "$1" 'check_deps'; }
deps_abort() { PATH="$STUB:$PATH" aborts "$1" "$2" 'check_deps'; }

render() {
    run 'WORK_DIR="$1" USER_HASH="$2" render_preseed' "$TMP" '$6$test$hash' \
        && mv "$TMP/preseed.cfg" "$TMP/preseed.$1"
}

test_suite_lookup() {
    local pair major want
    for pair in 11:bullseye 12:bookworm 13:trixie 14:forky; do
        major="${pair%%:*}"; want="${pair#*:}"
        equals "suite $major -> $want" "$want" \
            "$(DEBIAN_RELEASE="$major.0.0" DEBIAN_SUITE="" run 'echo "$DEBIAN_SUITE"')"
    done
    DEBIAN_RELEASE=99.0.0 DEBIAN_SUITE="" \
        deps_abort "unknown major aborts" "No codename known"
}

test_config_validation() {
    LV_VAR_MIN=50000 LV_VAR_MAX=10000 \
        deps_abort "LV_VAR_MIN > LV_VAR_MAX aborts" "is larger than LV_VAR_MAX"
    LV_VAR_MIN=10G \
        deps_abort "non-integer LV_VAR_MIN aborts" "must be plain integers in MB"
    ISO_VARIANT=dvd aborts "unknown ISO_VARIANT aborts" "Unknown ISO_VARIANT" ':'
}

test_iso_variants() {
    local pair variant want url
    for pair in netinst:iso-cd/debian-13.6.0-amd64-netinst.iso \
                offline:iso-dvd/debian-13.6.0-amd64-DVD-1.iso; do
        variant="${pair%%:*}"; want="${pair#*:}"
        url=$(ISO_VARIANT="$variant" run 'echo "${DEBIAN_ISO_URLS[0]}"')
        equals "$variant downloads $want" "$want" "${url#*/amd64/}"
    done
}

test_checksums() {
    local blob="$TMP/blob" good
    head -c 4096 /dev/urandom > "$blob"
    good=$(sha256sum "$blob" | cut -d' ' -f1)

    succeeds "matching checksum accepted"      'validate_iso "$1" "$2"' "$blob" "$good"
    rejects  "wrong checksum rejected"         'validate_iso "$1" "$2"' "$blob" "$(printf '%064d' 0)"
    rejects  "missing file does not validate"  'validate_iso "$1" "$2"' /nonexistent/iso "$good"
}

test_signature_policy() {
    local check='check_sums_signature /dev/null /nonexistent/sig'
    CHECK_SIGNATURE=no   succeeds "CHECK_SIGNATURE=no skips the check" "$check"
    CHECK_SIGNATURE=auto succeeds "CHECK_SIGNATURE=auto warns and continues" "$check"
    CHECK_SIGNATURE=yes  aborts "CHECK_SIGNATURE=yes aborts without a signature" \
        "Cannot verify the SHA256SUMS signature" "$check"
}

test_download_abort() {
    local build='
        WORK_DIR=$(mktemp -d); OUT_DIR="$WORK_DIR"; SRC_ISO="$WORK_DIR/iso"
        echo payload > "$SRC_ISO"
        sha256sum "$SRC_ISO" | cut -d" " -f1 > "$SRC_ISO.sha256"
        fetch_sums() { : > "$WORK_DIR/SHA256SUMS"; return 0; }
        check_sums_signature() { VERDICT; }
        download_iso'
    succeeds "a valid signature lets the build continue" "${build/VERDICT/return 0}"
    rejects  "a signature abort stops the build"         "${build/VERDICT/exit 1}"
}

test_cd_keys() {
    run 'printf "%s\n" "$DEBIAN_CD_KEYS"' > "$TMP/cd-keys"
    has   "trixie CD signing key is trusted" "$TMP/cd-keys" \
        '^DF9B9C49EAA9298432589D76DA87E80D6294BE9B$'
    lacks "allowlist rejects an unknown key" "$TMP/cd-keys" '^DEADBEEF$'
}

test_package_index() {
    cat > "$TMP/Packages" <<'INDEX'
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
    local table
    table=$(run 'index_to_table "$1"' "$TMP/Packages")

    equals "index: empty Depends keeps Provides in its own field" \
        'nodeps|pool/main/n/nodeps/nodeps_1.0_all.deb|aaaa|| virtual-thing' \
        "$(grep '^nodeps|' <<< "$table")"
    equals "index: versions stripped, first alternative taken" \
        'withdeps|pool/main/w/withdeps/withdeps_2.0_all.deb|bbbb| nodeps third fourth|' \
        "$(grep '^withdeps|' <<< "$table")"
}

test_preseed_rendering() {
    local variant
    SERIAL_CONSOLE="" ISO_VARIANT=netinst render netinst
    SERIAL_CONSOLE="" ISO_VARIANT=offline render offline
    SERIAL_CONSOLE="" DISK_LAYOUT=single render single

    for variant in netinst offline single; do
        lacks "$variant: no unsubstituted placeholders" "$TMP/preseed.$variant" '@[A-Z_]+@'
    done
    has "mirror/suite rendered" "$TMP/preseed.netinst" '^d-i mirror/suite string trixie$'
}

test_offline_variant() {
    cat > "$TMP/expected-keys" <<'KEYS'
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
    diff "$TMP/preseed.netinst" "$TMP/preseed.offline" \
        | sed -n 's/^[<>] *//p' | sed 's/^# //' \
        | awk '{ print $1, $2 }' | sort -u > "$TMP/actual-keys"
    equals "offline variant differs in exactly the expected keys" \
        "$(< "$TMP/expected-keys")" "$(< "$TMP/actual-keys")"

    has "offline: mirror disabled" "$TMP/preseed.offline" \
        '^d-i apt-setup/use_mirror boolean false$'
    has "netinst: mirror still used" "$TMP/preseed.netinst" \
        '^# d-i apt-setup/use_mirror boolean false$'
    has "offline: late_command calls offline-post.sh" "$TMP/preseed.offline" \
        'sh /cdrom/custom/offline-post\.sh trixie;'
}

lvmok_mountpoints() {
    awk '
        $1 == "." { if (lvmok && mp) printf "%s ", mp; lvmok = 0; mp = ""; next }
        /\$lvmok\{/ { lvmok = 1 }
        match($0, /mountpoint\{ *[^ }]+ *\}/) {
            mp = substr($0, RSTART, RLENGTH)
            gsub(/mountpoint\{ *| *\}/, "", mp)
        }
        END { if (lvmok && mp) printf "%s ", mp }
    ' "$1"
}

recipe_end() {
    awk '/^d-i partman-auto\/expert_recipe string/ { inside = 1 }
         inside { line = $0; sub(/\\$/, "", line); joined = joined line
                  if ($0 !~ /\\$/) { print joined; exit } }' "$1" \
        | tr -s ' ' | grep -oE 'mountpoint\{ [^ ]+ \} \.$'
}

test_disk_layout() {
    cat > "$TMP/expected-layout-keys" <<'KEYS'
d-i mdadm/boot_degraded
d-i partman-auto/choose_recipe
d-i partman-auto/method
d-i partman/early_command
d-i pkgsel/include
KEYS
    diff "$TMP/preseed.netinst" "$TMP/preseed.single" \
        | sed -n 's/^[<>] *//p' | sed 's/^# //' \
        | grep '^d-i ' | awk '{ print $1, $2 }' | sort -u > "$TMP/actual-layout-keys"
    equals "single layout differs in exactly the expected d-i keys" \
        "$(< "$TMP/expected-layout-keys")" "$(< "$TMP/actual-layout-keys")"

    has "raid1: partman drives RAID"  "$TMP/preseed.netinst" \
        '^d-i partman-auto/method string raid$'
    has "single: partman drives LVM"  "$TMP/preseed.single" \
        '^d-i partman-auto/method string lvm$'
    has "raid1: multiraid recipe selected" "$TMP/preseed.netinst" \
        '^d-i partman-auto/choose_recipe select multiraid$'
    has "single: singledisk recipe selected" "$TMP/preseed.single" \
        '^d-i partman-auto/choose_recipe select singledisk$'
    has "raid1: early_command asks for the raid1 layout" "$TMP/preseed.netinst" \
        'disk-setup\.sh raid1 yes$'
    has "single: early_command asks for the single layout" "$TMP/preseed.single" \
        'disk-setup\.sh single yes$'
    has "raid1: mdadm installed for the arrays" "$TMP/preseed.netinst" \
        '^d-i pkgsel/include string openssh-server python3 mdadm$'
    has "single: no mdadm, there is no array" "$TMP/preseed.single" \
        '^d-i pkgsel/include string openssh-server python3$'
    has "raid1: boot_degraded set" "$TMP/preseed.netinst" \
        '^d-i mdadm/boot_degraded boolean true$'
    lacks "single: no boot_degraded, there is no array" "$TMP/preseed.single" \
        '^d-i mdadm/boot_degraded'

    has "single: the recipe declares an LVM physical volume" "$TMP/preseed.single" \
        'method\{ lvm \}'
    has "single: recipe body is the singledisk one" "$TMP/preseed.single" '^ singledisk ::'
    has "raid1: recipe body is the multiraid one"  "$TMP/preseed.netinst" '^ multiraid ::'

    has   "raid1: lvmignore is what keeps partitions out of the LVM pass" \
        "$TMP/preseed.netinst" '\$lvmignore\{'
    lacks "single: no lvmignore, under method lvm it would drop the partition" \
        "$TMP/preseed.single" '\$lvmignore\{'

    equals "single: only / and /var are logical volumes, never /boot" \
        "/ /var " "$(lvmok_mountpoints "$REPO/partman/single.tpl")"
    equals "raid1: only / and /var are logical volumes, never /boot" \
        "/ /var " "$(lvmok_mountpoints "$REPO/partman/raid1.tpl")"

    local variant
    for variant in netinst single; do
        equals "$variant: the recipe ends on its last stanza, not cut short" \
            "mountpoint{ /var } ." "$(recipe_end "$TMP/preseed.$variant")"
        has "$variant: the recipe reaches lv_var" "$TMP/preseed.$variant" \
            'lv_name\{ lv_var \}'
    done

    DISK_LAYOUT=btrfs aborts "unknown DISK_LAYOUT aborts" "Unknown DISK_LAYOUT" ':'
    DISK_LAYOUT=single PARTMAN_TPL=/nonexistent/layout.tpl \
        deps_abort "a missing partman fragment aborts" "No partman recipe for"
}

disk_setup() {
    local bin="$TMP/disk-setup-bin" disks="$1"; shift
    mkdir -p "$bin"
    printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$disks" > "$bin/list-devices"
    printf '#!/bin/sh\necho "debconf-set $*"\n' > "$bin/debconf-set"
    chmod +x "$bin/list-devices" "$bin/debconf-set"
    PATH="$bin:$PATH" sh "$REPO/custom/disk-setup.sh" "$@" 2>&1
}

test_disk_setup() {
    local out
    equals "disk-setup raid1: three arrays across both disks" \
        "debconf-set partman-auto-raid/recipe 1 2 0 ext4 /boot /dev/vda3#/dev/vdb3 . 1 2 0 lvm - /dev/vda4#/dev/vdb4 . 1 2 0 swap - /dev/vda5#/dev/vdb5 ." \
        "$(disk_setup "/dev/vda /dev/vdb" raid1 yes | grep 'partman-auto-raid/recipe')"

    if out=$(disk_setup "/dev/vda" raid1 yes); then
        fail "disk-setup raid1: one disk aborts" "did not abort: $out"
    elif [[ "$out" != *"DISK_LAYOUT=single"* ]]; then
        fail "disk-setup raid1: one disk aborts" "abort does not name DISK_LAYOUT=single: $out"
    else
        pass "disk-setup raid1: one disk aborts and names DISK_LAYOUT=single"
    fi

    out=$(disk_setup "/dev/vda" single yes)
    equals "disk-setup single: the one disk becomes the install target" \
        "debconf-set partman-auto/disk /dev/vda" "$(grep 'partman-auto/disk' <<< "$out")"
    equals "disk-setup single: grub goes to that disk" \
        "debconf-set grub-installer/bootdev /dev/vda" "$(grep 'grub-installer/bootdev' <<< "$out")"
    lacks_text "disk-setup single: no RAID recipe is set" "$out" 'partman-auto-raid'

    out=$(disk_setup "/dev/vdb /dev/vda" single yes)
    equals "disk-setup single: equal sizes pick by device name, only one disk" \
        "debconf-set partman-auto/disk /dev/vda" "$(grep 'partman-auto/disk' <<< "$out")"

    if out=$(disk_setup "" single yes); then
        fail "disk-setup single: no disk aborts" "did not abort: $out"
    else
        pass "disk-setup single: no disk aborts"
    fi
}

lacks_text() {
    [[ "$2" == *"$3"* ]] && fail "$1" "found '$3' in: $2" || pass "$1"
}

test_swap() {
    SERIAL_CONSOLE="" SWAP_SIZE=0    DISK_LAYOUT=single render single-noswap
    SERIAL_CONSOLE="" SWAP_SIZE=0    DISK_LAYOUT=raid1  render raid1-noswap
    SERIAL_CONSOLE="" SWAP_SIZE=4096 DISK_LAYOUT=single render single-4096
    SERIAL_CONSOLE="" SWAP_SIZE=4096 DISK_LAYOUT=raid1  render raid1-4096

    has   "default single: swap LV fixed at 200% of RAM, so lv_var takes the rest of vg0" \
        "$TMP/preseed.single" '^ +200% 200% 200% linux-swap'
    has   "default raid1: swap array at 200% of RAM" "$TMP/preseed.netinst" \
        '^ +2048 102400000 200% raid'
    has   "SWAP_SIZE=4096 single: fixed 4096 MB swap LV" "$TMP/preseed.single-4096" \
        '^ +4096 4096 4096 linux-swap'
    has   "SWAP_SIZE=4096 raid1: fixed 4096 MB swap array" "$TMP/preseed.raid1-4096" \
        '^ +4096 4096 4096 raid'
    lacks "SWAP_SIZE=4096: no 200% stanza left" "$TMP/preseed.raid1-4096" '200%'

    has   "SWAP_SIZE=0 single: the recipe still has a root LV" "$TMP/preseed.single-noswap" \
        'lv_name\{ lv_root \}'
    lacks "SWAP_SIZE=0 single: no swap LV" "$TMP/preseed.single-noswap" \
        'lv_swap|method\{ swap \}'
    equals "SWAP_SIZE=0 raid1: only the /boot and PV partitions are RAID" "2" \
        "$(grep -c 'method{ raid }' "$TMP/preseed.raid1-noswap")"
    equals "default raid1: /boot, PV and swap partitions are RAID" "3" \
        "$(grep -c 'method{ raid }' "$TMP/preseed.netinst")"
    has "SWAP_SIZE=0: early_command tells disk-setup.sh there is no swap" \
        "$TMP/preseed.single-noswap" 'disk-setup\.sh single no$'
    has "SWAP_SIZE=0 raid1: early_command tells disk-setup.sh there is no swap" \
        "$TMP/preseed.raid1-noswap" 'disk-setup\.sh raid1 no$'
    has "partman does not stop to ask about a missing swap" \
        "$TMP/preseed.single-noswap" '^d-i partman-basicfilesystems/no_swap boolean false$'

    local variant
    for variant in single-noswap raid1-noswap single-4096 raid1-4096; do
        lacks "$variant: no unsubstituted placeholders" "$TMP/preseed.$variant" '@[A-Z_]+@'
        equals "$variant: the recipe ends on its last stanza, not cut short" \
            "mountpoint{ /var } ." "$(recipe_end "$TMP/preseed.$variant")"
    done

    equals "disk-setup raid1 without swap: no third array" \
        "debconf-set partman-auto-raid/recipe 1 2 0 ext4 /boot /dev/vda3#/dev/vdb3 . 1 2 0 lvm - /dev/vda4#/dev/vdb4 ." \
        "$(disk_setup "/dev/vda /dev/vdb" raid1 no | grep 'partman-auto-raid/recipe')"

    equals "SWAP_SIZE=0 renames the image" \
        "debian-13.6.0-unattended-single-noswap.iso" \
        "$(DISK_LAYOUT=single SWAP_SIZE=0 run 'echo "$OUTPUT_NAME"')"
    equals "a fixed SWAP_SIZE keeps the image name" \
        "debian-13.6.0-unattended.iso" \
        "$(SWAP_SIZE=4096 run 'echo "$OUTPUT_NAME"')"
    SWAP_SIZE=4G deps_abort "SWAP_SIZE=4G aborts" "SWAP_SIZE must be a plain integer in MB"
    SWAP_SIZE=-1 deps_abort "SWAP_SIZE=-1 aborts" "SWAP_SIZE must be a plain integer in MB"
    SWAP_SIZE=4096 deps_ok "SWAP_SIZE=4096 accepted"
}

test_layout_image_names() {
    local name
    for name in "raid1 netinst debian-13.6.0-unattended.iso" \
                "single netinst debian-13.6.0-unattended-single.iso" \
                "raid1 offline debian-13.6.0-unattended-offline.iso" \
                "single offline debian-13.6.0-unattended-offline-single.iso"; do
        set -- $name
        equals "$1/$2 builds $3" "$3" \
            "$(DISK_LAYOUT="$1" ISO_VARIANT="$2" run 'echo "$OUTPUT_NAME"')"
    done

    equals "single: volume id stays inside the 32 byte ISO9660 field" "20" \
        "$(DISK_LAYOUT=single ISO_VARIANT=netinst run 'echo -n "$VOLUME_ID" | wc -c')"
    equals "single offline: volume id stays inside the 32 byte field" "28" \
        "$(DISK_LAYOUT=single ISO_VARIANT=offline run 'echo -n "$VOLUME_ID" | wc -c')"
}

test_serial_validation() {
    local value
    for value in ttyS1,115200n8 ttyS0,57600 ttyS3,9600n8; do
        SERIAL_CONSOLE="$value" deps_ok "SERIAL_CONSOLE=$value accepted"
    done
    for value in ttyS1 sol,115200 ttyS1,fast ttyS1,57600e7 ttyS4,115200; do
        SERIAL_CONSOLE="$value" deps_abort "SERIAL_CONSOLE=$value aborts" \
            "SERIAL_CONSOLE must be"
    done
}

test_serial_preseed() {
    SERIAL_CONSOLE=ttyS1,115200n8 render serial
    SERIAL_CONSOLE=ttyS1,115200n8 run 'echo "$PRESEED_ARGS"' > "$TMP/args.serial"
    SERIAL_CONSOLE="" run 'echo "$PRESEED_ARGS"' > "$TMP/args.plain"

    has "serial: add-kernel-opts carries console= to the installed system" \
        "$TMP/preseed.serial" \
        '^d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS1,115200n8$'
    has "serial: late_command calls serial-console.sh" \
        "$TMP/preseed.serial" 'serial-console\.sh'
    has   "no serial: add-kernel-opts stays commented" \
        "$TMP/preseed.netinst" '^# d-i debian-installer/add-kernel-opts'
    lacks "no serial: late_command untouched" \
        "$TMP/preseed.netinst" 'serial-console\.sh'

    has   "serial: installer boots on the serial console" \
        "$TMP/args.serial" 'console=tty0 console=ttyS1,115200n8$'
    lacks "no serial: no console= in PRESEED_ARGS" "$TMP/args.plain" 'console='
}

boot_fixture() {
    rm -rf "$TMP/work"
    mkdir -p "$TMP/work/isolinux" "$TMP/work/boot/grub"
    cat > "$TMP/work/isolinux/isolinux.cfg" <<'CFG'
include menu.cfg
default vesamenu.c32
prompt 0
timeout 0
CFG
    printf 'label install\n\tkernel /install.amd/vmlinuz\n\tappend vga=788 initrd=/install.amd/initrd.gz --- quiet\n' \
        > "$TMP/work/isolinux/txt.cfg"
    cat > "$TMP/work/boot/grub/grub.cfg" <<'CFG'
if loadfont $font ; then
  terminal_output gfxterm
fi
menuentry --hotkey=i 'Install' {
    linux    /install.amd/vmlinuz vga=788 --- quiet
    initrd   /install.amd/initrd.gz
}
CFG
    run 'WORK_DIR="$1"; patch_isolinux; patch_grub' "$TMP/work" >/dev/null
}

console_before_marker() {
    local line before after
    line=$(grep -m1 -- '---' "$2")
    before="${line%%---*}"; after="${line#*---}"
    case "$before" in *console=ttyS1,115200n8*) ;;
        *) fail "$1" "no console= before the marker: $line"; return ;;
    esac
    case "$after" in *console=*) fail "$1" "console= after the marker: $line"; return ;; esac
    pass "$1"
}

test_boot_config() {
    SERIAL_CONSOLE=ttyS1,115200n8 boot_fixture
    has "serial: isolinux talks to the serial port" \
        "$TMP/work/isolinux/isolinux.cfg" '^serial 1 115200$'
    has "serial: grub talks to the serial port" \
        "$TMP/work/boot/grub/grub.cfg" '^serial --unit=1 --speed=115200$'
    has "serial: gfxterm no longer drops the serial terminal" \
        "$TMP/work/boot/grub/grub.cfg" '^  terminal_output gfxterm serial$'
    console_before_marker "serial: txt.cfg console= before the --- marker" \
        "$TMP/work/isolinux/txt.cfg"
    console_before_marker "serial: grub.cfg console= before the --- marker" \
        "$TMP/work/boot/grub/grub.cfg"

    SERIAL_CONSOLE="" boot_fixture
    lacks "no serial: no console= in txt.cfg" \
        "$TMP/work/isolinux/txt.cfg" 'console='
    lacks "no serial: isolinux.cfg has no SERIAL directive" \
        "$TMP/work/isolinux/isolinux.cfg" '^serial '
    lacks "no serial: grub.cfg has no serial command" \
        "$TMP/work/boot/grub/grub.cfg" '--unit='
    has   "no serial: terminal_output left alone" \
        "$TMP/work/boot/grub/grub.cfg" '^  terminal_output gfxterm$'
    has   "no serial: preseed still patched in" \
        "$TMP/work/isolinux/txt.cfg" 'preseed/file=/preseed\.cfg'
}

test_smoke_serial_wiring() {
    equals "smoke: unit 0 keeps the log on the first port" \
        "-serial file:/l" \
        "$(smoke 'LOG=/l; SERIAL_UNIT=0; serial_args; echo "${SERIAL_ARGS[*]}"')"
    equals "smoke: unit 1 pads so the log lands on ttyS1" \
        "-serial null -serial file:/l" \
        "$(smoke 'LOG=/l; SERIAL_UNIT=1; serial_args; echo "${SERIAL_ARGS[*]}"')"
    equals "smoke: unit 2 pads twice" \
        "-serial null -serial null -serial file:/l" \
        "$(smoke 'LOG=/l; SERIAL_UNIT=2; serial_args; echo "${SERIAL_ARGS[*]}"')"
}

test_smoke_stage_order() {
    local out
    printf 'finish-install\nInstalling the base system\n' > "$TMP/seen.txt"
    out=$(smoke '
        SEEN="$1"
        snapshot() { :; }
        qemu_running() { return 0; }
        MARK=1
        reach "late marker" "Installing the base system" 1
        reach "earlier text" "finish-install" 1
    ' "$TMP/seen.txt")
    case "$out" in
        *"ok   - late marker"*) pass "smoke: a stage matches its own marker" ;;
        *) fail "smoke: a stage matches its own marker" "$out" ;;
    esac
    case "$out" in
        *"FAIL - earlier text"*) pass "smoke: a stage cannot match output from before it" ;;
        *) fail "smoke: a stage cannot match output from before it" "$out" ;;
    esac
}

test_smoke_disk_count() {
    equals "smoke: two disks by default" \
        "-drive file=/w/d1.qcow2,if=virtio,format=qcow2 -drive file=/w/d2.qcow2,if=virtio,format=qcow2" \
        "$(smoke 'WORK=/w; disk_args; echo "${DISK_ARGS[*]}"')"
    equals "smoke: SMOKE_DISKS=1 attaches a single disk" \
        "-drive file=/w/d1.qcow2,if=virtio,format=qcow2" \
        "$(smoke 'WORK=/w; SMOKE_DISKS=1; disk_args; echo "${DISK_ARGS[*]}"')"
    case "$(SMOKE_DISKS=0 smoke 'require_disk_count')" in
        *"SMOKE_DISKS must be"*) pass "smoke: SMOKE_DISKS=0 aborts" ;;
        *) fail "smoke: SMOKE_DISKS=0 aborts" "no abort message" ;;
    esac
}

main() {
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    STUB="$TMP/stub"
    make_tool_stubs

    test_suite_lookup
    test_config_validation
    test_iso_variants
    test_checksums
    test_signature_policy
    test_download_abort
    test_cd_keys
    test_package_index
    test_preseed_rendering
    test_offline_variant
    test_disk_layout
    test_disk_setup
    test_layout_image_names
    test_swap
    test_serial_validation
    test_serial_preseed
    test_boot_config
    test_smoke_serial_wiring
    test_smoke_stage_order
    test_smoke_disk_count

    echo
    echo "  $PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ] || exit 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
