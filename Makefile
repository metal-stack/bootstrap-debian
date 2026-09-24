DEBIAN_RELEASE      ?= 13.6.0
DEBIAN_SUITE        ?=
ISO_VARIANT         ?= netinst
DISK_LAYOUT         ?= raid1
SWAP_SIZE           ?=
SERIAL_CONSOLE      ?= ttyS1,115200n8
CHECK_SIGNATURE     ?= auto
DEBIAN_MIRROR       ?= https://deb.debian.org/debian
ADMIN_USER          ?= sysadmin
ADMIN_FULLNAME      ?= Administrator
TARGET_HOSTNAME     ?= debian
TARGET_DOMAIN       ?= localdomain
LOCALE              ?= en_US.UTF-8
KEYMAP              ?= de
TIMEZONE            ?= Europe/Berlin
LV_VAR_MIN          ?= 10240
LV_VAR_MAX          ?= 200000
SSH_PUBKEY          ?=
AUTHORIZED_KEYS_FILE ?=
USERHASH            ?=

export DEBIAN_RELEASE DEBIAN_SUITE ISO_VARIANT DISK_LAYOUT SWAP_SIZE SERIAL_CONSOLE CHECK_SIGNATURE
export DEBIAN_MIRROR ADMIN_USER ADMIN_FULLNAME TARGET_HOSTNAME TARGET_DOMAIN
export LOCALE KEYMAP TIMEZONE LV_VAR_MIN LV_VAR_MAX SSH_PUBKEY
export AUTHORIZED_KEYS_FILE USERHASH

SMOKE_DEADLINE      ?= 1800
SMOKE_BOOT_DEADLINE ?= 420
SMOKE_DISKS         ?= $(if $(filter single,$(DISK_LAYOUT)),1,2)
SHELLCHECK_OPTS ?= -e SC2086,SC2016,SC2015
export SHELLCHECK_OPTS SMOKE_BOOT_DEADLINE SMOKE_DISKS

ISO_SUFFIX = $(if $(filter offline,$(ISO_VARIANT)),-offline,)$(if $(filter single,$(DISK_LAYOUT)),-single,)$(if $(filter 0,$(SWAP_SIZE)),-noswap,)
ISO_PATH  ?= out/debian-$(DEBIAN_RELEASE)-unattended$(ISO_SUFFIX).iso
ISO_DEP    = $(if $(wildcard $(ISO_PATH)),,$(ISO_PATH))
SCRIPTS    = $(wildcard *.sh tests/*.sh custom/*.sh)

.DEFAULT_GOAL := help
.PHONY: help iso offline single verify test smoke smoke-uefi lint check clean distclean

help:
	@echo 'Targets:'
	@echo '  iso            build the ISO (ISO_VARIANT=$(ISO_VARIANT), SERIAL_CONSOLE=$(SERIAL_CONSOLE))'
	@echo '  offline        like iso, but ISO_VARIANT=offline (DVD-1, installs without network)'
	@echo '  single         like iso, but DISK_LAYOUT=single (one disk, LVM, no RAID)'
	@echo '  verify         unpack the built ISO and check it (verify-iso.sh)'
	@echo '  test           unit tests, no network and no root (tests/run-tests.sh)'
	@echo '  smoke          full install in QEMU until the machine powers off, then'
	@echo '                 boot from disk and wait for a login prompt, BIOS path'
	@echo '                 attaches SMOKE_DISKS disks, which follows DISK_LAYOUT'
	@echo '  smoke-uefi     the same over OVMF, EFI path'
	@echo '                 both need SERIAL_CONSOLE set at build time to be observable'
	@echo '  lint           shellcheck with the CI flags'
	@echo '  check          lint + test'
	@echo '  clean          remove built ISOs, keep the downloaded source ISO'
	@echo '  distclean      remove out/ entirely'
	@echo
	@echo 'Variables (current value):'
	@echo '  DEBIAN_RELEASE=$(DEBIAN_RELEASE)   DEBIAN_SUITE=$(DEBIAN_SUITE)   ISO_VARIANT=$(ISO_VARIANT)'
	@echo '  DISK_LAYOUT=$(DISK_LAYOUT) (raid1: two disks mirrored, single: one disk)'
	@echo '  SWAP_SIZE=$(SWAP_SIZE) (MB; empty: 200% of RAM up to 8 GB, 0: no swap at all)'
	@echo '  SERIAL_CONSOLE=$(SERIAL_CONSOLE)   CHECK_SIGNATURE=$(CHECK_SIGNATURE)'
	@echo '  ADMIN_USER=$(ADMIN_USER)   TARGET_HOSTNAME=$(TARGET_HOSTNAME)   TARGET_DOMAIN=$(TARGET_DOMAIN)'
	@echo '  LOCALE=$(LOCALE)   KEYMAP=$(KEYMAP)   TIMEZONE=$(TIMEZONE)'
	@echo '  LV_VAR_MIN=$(LV_VAR_MIN)   LV_VAR_MAX=$(LV_VAR_MAX)'
	@echo '  DEBIAN_MIRROR=$(DEBIAN_MIRROR)'
	@echo '  SSH_PUBKEY, AUTHORIZED_KEYS_FILE, USERHASH: empty means interactive or the build-iso.sh default'
	@echo '  ISO_PATH=$(ISO_PATH)'
	@echo '  SMOKE_DEADLINE=$(SMOKE_DEADLINE) (install)   SMOKE_BOOT_DEADLINE=$(SMOKE_BOOT_DEADLINE) (per stage)   SMOKE_DISKS=$(SMOKE_DISKS)'
	@echo
	@echo 'Examples:'
	@echo '  make iso SSH_PUBKEY="ssh-ed25519 AAAA... admin@host"'
	@echo '  make iso SERIAL_CONSOLE=ttyS0,57600      other port'
	@echo '  make iso SERIAL_CONSOLE=                 no serial console'
	@echo '  make iso ISO_VARIANT=offline TARGET_HOSTNAME=node01 LV_VAR_MAX=400000'
	@echo '  make single                              one-disk machine, no RAID'
	@echo '  make smoke DISK_LAYOUT=single            install it on a one-disk VM'
	@echo '  make iso DISK_LAYOUT=single SWAP_SIZE=0  k8s node: one disk, no swap'
	@echo '  make iso SWAP_SIZE=4096                  fixed 4 GB swap'
	@echo '  make smoke ISO_PATH=out/debian-$(DEBIAN_RELEASE)-unattended.iso'

$(ISO_PATH): build-iso.sh preseed.cfg.tpl $(wildcard partman/*) $(wildcard custom/*)
	./build-iso.sh

iso: $(ISO_PATH)

offline:
	@$(MAKE) --no-print-directory iso ISO_VARIANT=offline

single:
	@$(MAKE) --no-print-directory iso DISK_LAYOUT=single

verify: iso
	./verify-iso.sh

test:
	./tests/run-tests.sh

smoke: $(ISO_DEP)
	./tests/boot-smoke.sh $(ISO_PATH) bios $(SMOKE_DEADLINE)

smoke-uefi: $(ISO_DEP)
	./tests/boot-smoke.sh $(ISO_PATH) uefi $(SMOKE_DEADLINE)

lint:
	shellcheck $(SCRIPTS)

check: lint test

clean:
	rm -f out/*-unattended*.iso out/*-unattended*.iso.sha256
	rm -rf out/smoke-*

distclean:
	rm -rf out
