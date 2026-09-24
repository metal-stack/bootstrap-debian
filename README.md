# Bootstrap Debian

Debian netinst ISO with an embedded preseed. Boots, wipes the disks, installs onto LVM, powers off. No interaction.

Two disks mirrored with RAID1 is the default; a one-disk machine needs `DISK_LAYOUT=single`.
Swap is 200% of RAM up to 8 GB unless `SWAP_SIZE` says otherwise; `SWAP_SIZE=0` means none.
Tested in QEMU only, not on hardware, and `single` has no redundancy; see [Known limits](#known-limits).

```sh
sudo apt-get install -y xorriso wget whois gnupg cpio xz-utils
echo "ssh-ed25519 AAAA... user@host" > custom/authorized_keys
./build-iso.sh
sudo dd if=out/debian-13.6.0-unattended.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

For a machine with one disk, see [Disk layout](#disk-layout); for swap, [Swap](#swap).
For a target without internet access, see [Offline variant](#offline-variant).

Settings are the variables at the top of `build-iso.sh`, all overridable via environment. `USERHASH="$(mkpasswd -m sha-512)"` skips the password prompt; the hash lands only in the ISO.

## Checksum verification

Both the image that goes in and the image that comes out are checksummed.

**Incoming.** Before anything is extracted, `build-iso.sh` fetches `SHA256SUMS`
from the same cdimage directory as the ISO and verifies the download against it.
A mismatch aborts the build; an ISO already in `out/` is re-verified rather than
trusted, so a half-finished download from a previous run cannot be reused. The
expected sum is cached next to the ISO as `<name>.sha256`, which lets a rebuild
verify without reaching cdimage at all.

`SHA256SUMS` comes off the same mirror as the image, so on its own it only rules
out a corrupted download. The signature is what rules out a mirror that lies, and
it is checked against the two *Debian CD signing key* fingerprints published on
[debian.org/CD/verify](https://www.debian.org/CD/verify):

```sh
gpg --keyserver keyring.debian.org --recv-keys DF9B9C49EAA9298432589D76DA87E80D6294BE9B
CHECK_SIGNATURE=yes ./build-iso.sh
```

`CHECK_SIGNATURE` is `auto` by default: it verifies when the key is available and
prints what it could not check when it is not. `yes` makes a build fail unless
the signature verifies, `no` skips it. A *good* signature by a key that is not on
the list always aborts, in every mode.

**Outgoing.** The build writes `out/<name>.iso.sha256` and prints the sum.
`verify-iso.sh` checks the ISO against it, and the same file checks the USB stick
after `dd`:

```sh
( cd out && sha256sum -c debian-13.6.0-unattended.iso.sha256 )
sudo blockdev --flushbufs /dev/sdX    # or the read comes back out of page cache
sudo head -c "$(stat -c%s out/debian-13.6.0-unattended.iso)" /dev/sdX | sha256sum
```

## Changing release

`DEBIAN_RELEASE` (default `13.6.0`) drives everything else:

- **Mirror suite.** The codename cannot be computed from a version number, so `build-iso.sh` looks it up in a [`case`](https://github.com/metal-stack/bootstrap-debian/blob/main/build-iso.sh) (11→bullseye … 14→forky) and renders it into `preseed.cfg`. An unknown major **aborts the build** instead of installing from the wrong suite. Override with `DEBIAN_SUITE=<codename>`, or add the release to the `case`.
- **Download URL.** `cdimage.debian.org/debian-cd/current/` only carries the newest point release; older ones move to `cdimage/archive/<version>/`. The build tries current first, then the archive.

So a point release is `DEBIAN_RELEASE=13.7.0 ./build-iso.sh`, and a major release is that plus one line in the `case` if the codename is not listed yet. Neither touches the preseed.

Only the 13 row has been installed from. The bullseye/bookworm/forky rows are lookups that were checked as strings, not exercised against a real ISO — and a preseed that works on 13 is not guaranteed to work on another major.

## Disk layout

`DISK_LAYOUT` picks how the disks are carved up. It is independent of
`ISO_VARIANT`, so all four combinations build, each under its own name.

| `DISK_LAYOUT`     | Disks needed | Image                                 |
| ----------------- | ------------ | ------------------------------------- |
| `raid1` (default) | two          | `debian-13.6.0-unattended.iso`        |
| `single`          | one or more  | `debian-13.6.0-unattended-single.iso` |

```sh
make single                     # or: DISK_LAYOUT=single ./build-iso.sh
make smoke DISK_LAYOUT=single   # installs it on a one-disk VM
```

**`raid1`** takes the two largest disks and mirrors them: three RAID1 arrays,
`vg0` on the second, as in [Resulting layout](#resulting-layout). Fewer than two
disks **aborts the install** rather than silently installing onto one, and the
message says to rebuild with `DISK_LAYOUT=single`.

**`single`** installs onto the largest disk alone. No arrays and no `mdadm`: the
ESP and `/boot` are plain partitions, the rest of the disk is one LVM physical
volume carrying `vg0`, and swap is a logical volume instead of an array. A second
disk, if present, is **left untouched**: not wiped, not added to `vg0`.

Everything else is shared: same user, same SSH hardening, same `/var` caps, same
serial console. Apart from the recipe body, five preseed keys differ between the
layouts, and `tests/run-tests.sh` fails if a sixth appears.

The two layouts reach partman by different routes, which is where the recipe
tokens matter. `raid1` is decoded as `partman-auto/method raid`, so its physical
partitions carry `$lvmignore{ }`. `single` is decoded as `method lvm`, where every
stanza carrying `lvmignore` is **dropped** (`decode_recipe` in
[partman-auto 177 `lib/recipes.sh`](https://sources.debian.org/src/partman-auto/177/lib/recipes.sh/#L156),
the trixie version), so the single recipe must not carry that token at all, or the
ESP and `/boot` silently disappear. `tests/run-tests.sh`
asserts both, and that `/boot` is never a logical volume.

## Swap

`SWAP_SIZE`, in MB, sizes swap in either layout: the third array in `raid1`,
`vg0/lv_swap` in `single`. partman counts a MB as 10^6 bytes, so `SWAP_SIZE=1024`
is 976 MiB (244 extents of 4 MiB, read back off an installed disk).

| `SWAP_SIZE`     | Swap                                          | Image name        |
| --------------- | --------------------------------------------- | ----------------- |
| empty (default) | 200% of RAM, at most 8 GB, as before          | unchanged         |
| `4096`          | fixed 4096 MB                                 | unchanged         |
| `0`             | none: no swap array, no swap LV               | `...-noswap.iso`  |

```sh
make iso SWAP_SIZE=4096                  # fixed 4 GB
make iso DISK_LAYOUT=single SWAP_SIZE=0  # one disk, no swap
```

The default differs in one detail between the layouts. `raid1` keeps its old
stanza, `2048 102400000 200%`: at least 2 GB, growing to 200% of RAM. `single` uses
`200% 200% 200%`, exactly 200% of RAM, because there swap is a logical volume that
competes with `lv_var` for `vg0`. partman's `expand_scheme` weights each volume by
`(priority - min) * 100 / sum` in integer arithmetic, so with raid1's stanza the
weight of `lv_var` would round to 0 and `/var` would never grow past its minimum.
The two defaults only give different sizes below 1 GB of RAM.

By default a kubelet
[will not start](https://kubernetes.io/docs/concepts/cluster-administration/swap-memory-management/)
on a Linux node that has swap enabled, unless `failSwapOn: false` is set; with the
default `NoSwap` behaviour pods then still use no swap. `SWAP_SIZE=0` removes the
need to set it, for example under kubeadm. k3s already sets `FailSwapOn` to `false`
in its default kubelet configuration (`defaultKubeletConfig` in
[`pkg/daemons/agent/agent.go`](https://github.com/k3s-io/k3s/blob/master/pkg/daemons/agent/agent.go),
read on `master`), so there swap does not stop the kubelet.

A fixed size does not rename the image, just as `LV_VAR_MAX` does not, so a
`SWAP_SIZE=4096` build overwrites the default one in `out/`, and `make iso` does
not rebuild an existing image just because a variable changed.

## Offline variant

`ISO_VARIANT=offline ./build-iso.sh` builds the same installation for a target
without internet access:

```sh
ISO_VARIANT=offline ./build-iso.sh
sudo dd if=out/debian-13.6.0-unattended-offline.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

It starts from the same netinst image as the default build. Everything the
installation pulls in (openssh-server, python3, mdadm, lvm2, the kernel, grub
and shim) is already in the netinst pool, so the offline image differs only in
its preseed and in the debs it carries for `unattended-upgrades`, which is on
neither the netinst nor DVD-1. The build host still needs internet for those
debs and the package index. Output names differ, so both variants coexist in
`out/`.

Eleven preseed keys differ, and `tests/run-tests.sh` fails if a twelfth appears:

| Key                          | netinst               | offline                            |
| ---------------------------- | --------------------- | ---------------------------------- |
| `apt-setup/use_mirror`       | (unset, mirror used)  | `false`                            |
| `apt-setup/no_mirror`        | (unset)               | `true`, continue without a mirror  |
| `apt-setup/services-select`  | `security, updates`   | empty                              |
| `pkgsel/upgrade`             | `full-upgrade`        | `none`                             |
| `pkgsel/update-policy`       | `unattended-upgrades` | `none`, see below                  |
| `netcfg/dhcp_failed`         | prompts               | continues without network          |
| `netcfg/dhcp_options`        | prompts               | *Do not configure the network*     |
| `netcfg/get_nameservers`     | prompts               | empty                              |
| `netcfg/no_default_route`    | prompts               | `true`                             |
| `netcfg/confirm_static`      | prompts               | `true`                             |
| `preseed/late_command`       | —                     | also runs `custom/offline-post.sh` |

DHCP is still attempted, and still configures the installed system when a server
answers. The `netcfg` keys only remove the prompts when the network is
incomplete. One image covers a LAN without egress, a link without a DHCP
server, and a network card whose cable is unplugged.

It does **not** cover a machine where the installer finds no network card at
all, for example because the driver is missing. d-i then stops at
`netcfg/no_interfaces`, and no preseed can answer that: the question is of type
`error`, and cdebconf 0.280 always shows error questions, before it looks at
priority or at a preseeded value (`question_db_is_visible` in
[cdebconf 0.280 `src/database.c`](https://sources.debian.org/src/cdebconf/0.280/src/database.c/#L349)).
The install waits at that dialog; whether it finishes after someone answers
it at the console has not been tried.

## Target requirements

- **Disks are wiped without confirmation.** `disk-setup.sh` ranks the disks that are not the install medium by size; equal sizes are ordered by device name, so the choice stays the same across boots.
  - `DISK_LAYOUT=raid1` takes **the two largest** (a smaller third disk is left alone) and aborts if it finds fewer than two.
  - `DISK_LAYOUT=single` takes **the largest one only** and leaves every other disk untouched.
- **Minimum disk size**, below which partman cannot satisfy the recipe (tested on 64 GB only):
  - `raid1`: **~53 GB per disk**: 512 MB ESP + 1 GB `/boot` + up to 8 GB swap + 30 GB `lv_root` + 10 GB minimum `lv_var`.
  - `single`: **~45 GB** for the same parts on one disk, computed rather than measured.
  - A different `SWAP_SIZE` moves both figures by the difference to 8 GB. Only 99% of the VG is offered to the recipe in either case.
- DHCP with internet access — netinst pulls from `deb.debian.org`. The
  [offline variant](#offline-variant) drops this requirement.
- BIOS or UEFI; the installed system follows the mode the ISO was booted in. Any existing ESP is reformatted.

## Resulting layout

### `DISK_LAYOUT=raid1`

Identical GPT on both disks: `bios_boot` (1 MB), ESP (512 MB), then three RAID1 arrays.

| Device          | Members                  | Size             | Mount           |
| --------------- | ------------------------ | ---------------- | --------------- |
| `md0`         | partition 3 of each disk | 1 GB             | `/boot`, ext4 |
| `md1`         | partition 4 of each disk | rest of the disk | PV of VG`vg0` |
| `md2`         | partition 5 of each disk | `SWAP_SIZE`, default 200% of RAM | swap, absent with `SWAP_SIZE=0` |
| `vg0/lv_root` | —                       | 30 GB            | `/`, ext4     |
| `vg0/lv_var`  | —                       | 10 GB–200 GB    | `/var`, ext4  |

`/var` is separate so container images, volumes and logs cannot fill `/`. It is **capped, not greedy**: `LV_VAR_MIN` (default `10240`) and `LV_VAR_MAX` (default `200000`), both in MB, bound the LV, and whatever `vg0` has left stays free for snapshots or a later `lvextend`. `md1` still claims the whole disk.

```sh
LV_VAR_MAX=51200 ./build-iso.sh    # /var stops at 50 GB
```

Losing a disk does not stop the boot. mdadm's initramfs script assembles
what it can: it runs `mdadm --assemble --scan --no-degraded` first and
retries with `--run` after two thirds of `ROOTDELAY`, which starts the array
degraded (`usr/share/initramfs-tools/scripts/local-block/mdadm` in mdadm
4.4-11, the version on this image). That is the case the smoke test reaches
when it boots the installed system from the second disk alone, on BIOS and
on UEFI, in a VM. Nothing here pulls a disk out of a running machine.

### `DISK_LAYOUT=single`

One GPT on the one disk, no arrays:

| Device          | Size                             | Mount                           |
| --------------- | -------------------------------- | ------------------------------- |
| partition 1     | 1 MB                             | `bios_boot`                     |
| partition 2     | 512 MB                           | `/boot/efi`                     |
| partition 3     | 1 GB                             | `/boot`, ext4                   |
| partition 4     | rest of the disk                 | PV of VG `vg0`                  |
| `vg0/lv_root`   | 30 GB                            | `/`, ext4                       |
| `vg0/lv_swap`   | `SWAP_SIZE`, default 200% of RAM | swap, absent with `SWAP_SIZE=0` |
| `vg0/lv_var`    | 10 GB-200 GB                     | `/var`, ext4                    |

The `bios_boot` partition is there in both layouts, so the same image boots a BIOS
and a UEFI machine. `LV_VAR_MIN`/`LV_VAR_MAX` and the free space left in `vg0`
behave exactly as above.

## Known limits

What the tests do not reach, and which figures are single data points.
Unit tests and building and verifying every layout run on each push;
installing them runs on tags and weekly, in QEMU.

- **Only 13.x has been installed from.** The other rows of the release
  table are codename lookups checked as strings; a preseed that installs 13
  is no evidence for 14.
- **QEMU only, never hardware.** `make smoke` and `make smoke-uefi` install
  into a VM with 64 GB disks and 2 GB of RAM and wait for a login prompt.
  Nothing here has run on a real machine, on another disk size, or with
  more RAM than that.
- **The 8 GB swap ceiling is read, not measured.** It follows from
  `partman-auto/cap-ram` set to 4096, whose own template in partman-auto 177
  caps the swap partition at 200% of that. With 2 GB of guest RAM the cap
  never binds, so nothing here exercises it.
- **`single`'s ~45 GB minimum is computed** from the recipe's parts;
  `raid1`'s ~53 GB was measured, and only at 64 GB.
- **Fixed swap sizes are never installed.** No swap and the 200% default go
  through the install matrix; `SWAP_SIZE=4096` is covered by rendering
  tests alone.
- **The offline image is installed by hand, not in CI.** `make smoke` gives
  the guest a working network, so it cannot show an offline install. The
  offline images were installed in QEMU with modified copies of
  `boot-smoke.sh` for three cases: no egress, no DHCP server, and the link
  set down. That was a one-off run, and no workflow repeats it.
- **Whether `offline-post.sh` installs `unattended-upgrades` is not
  observed.** The script writes nothing the transcript shows; only the
  install finishing is.
- **`sync-esp.sh` leaves no message in the transcript.** The mirrored ESP
  only shows up as a second disk that does or does not boot, which is what
  the disk-2 boot checks; a mirror that fails has no message of its own.
- **The layout assertions read partman's messages** (`RAID1 device#0`,
  `Formatting swap space ...`). A point release that rewords them fails the
  test for a reason that is not a regression.
