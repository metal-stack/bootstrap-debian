# Bootstrap Debian

Debian netinst ISO with an embedded preseed. Boots, wipes two disks, installs onto RAID1 with LVM, powers off. No interaction.

```sh
sudo apt-get install -y xorriso wget whois gnupg cpio xz-utils
echo "ssh-ed25519 AAAA... user@host" > custom/authorized_keys
./build-iso.sh
sudo dd if=out/debian-13.6.0-unattended.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

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

## Offline variant

`ISO_VARIANT=offline ./build-iso.sh` builds the same installation from Debian's
DVD-1 image instead of the netinst, so the target needs no network at all:

```sh
ISO_VARIANT=offline ./build-iso.sh
sudo dd if=out/debian-13.6.0-unattended-offline.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Same preseed, same partitioning, same user, same SSH hardening. The build host
still needs internet — it downloads a ~4 GB ISO — and the two variants have
separate source and output names, so they do not collide in `out/`.

Ten preseed keys differ, and `tests/run-tests.sh` fails if an eleventh appears:

| Key                          | netinst               | offline                            |
| ---------------------------- | --------------------- | ---------------------------------- |
| `apt-setup/use_mirror`       | (unset, mirror used)  | `false`                            |
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
incomplete, so one ISO covers "LAN without egress", "LAN without DNS" and "no
network at all".

## Target requirements

- **Exactly two disks, both wiped without confirmation.** `raid-setup.sh` takes the two largest that are not the install medium — a smaller third disk is left alone. Equal sizes are ordered by device name, so the pair stays the same across boots. Fewer than two aborts the install rather than falling back to one disk.
- **~53 GB per disk minimum** (tested on 64 GB): 512 MB ESP + 1 GB `/boot` + up to 8 GB swap + 30 GB `lv_root` + 10 GB minimum `lv_var`, and only 99% of the VG is offered to the recipe. Below that partman cannot satisfy the recipe.
- DHCP with internet access — netinst pulls from `deb.debian.org`. The
  [offline variant](#offline-variant) drops this requirement.
- BIOS or UEFI; the installed system follows the mode the ISO was booted in. Any existing ESP is reformatted.

## Resulting layout

Identical GPT on both disks: `bios_boot` (1 MB), ESP (512 MB), then three RAID1 arrays.

| Device          | Members                  | Size             | Mount           |
| --------------- | ------------------------ | ---------------- | --------------- |
| `md0`         | partition 3 of each disk | 1 GB             | `/boot`, ext4 |
| `md1`         | partition 4 of each disk | rest of the disk | PV of VG`vg0` |
| `md2`         | partition 5 of each disk | 200% of RAM      | swap            |
| `vg0/lv_root` | —                       | 30 GB            | `/`, ext4     |
| `vg0/lv_var`  | —                       | 10 GB–200 GB    | `/var`, ext4  |

`/var` is separate so container images, volumes and logs cannot fill `/`. It is **capped, not greedy**: `LV_VAR_MIN` (default `10240`) and `LV_VAR_MAX` (default `200000`), both in MB, bound the LV, and whatever `vg0` has left stays free for snapshots or a later `lvextend`. `md1` still claims the whole disk.

```sh
LV_VAR_MAX=51200 ./build-iso.sh    # /var stops at 50 GB
```
