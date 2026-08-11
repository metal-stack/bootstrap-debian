# Bootstrap Debian

Debian netinst ISO with an embedded preseed. Boots, wipes two disks, installs onto RAID1 with LVM, powers off. No interaction.

```sh
sudo apt-get install -y xorriso wget whois
echo "ssh-ed25519 AAAA... user@host" > custom/authorized_keys
./build-iso.sh
sudo dd if=out/debian-13.6.0-unattended.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Settings are the variables at the top of `build-iso.sh`, all overridable via environment. `USERHASH="$(mkpasswd -m sha-512)"` skips the password prompt; the hash lands only in the ISO.

## Changing release

`DEBIAN_RELEASE` (default `13.6.0`) drives everything else:

- **Mirror suite.** The codename cannot be computed from a version number, so `build-iso.sh` looks it up in a [`case`](https://github.com/muhi/debian-unattended-raid1/blob/main/build-iso.sh) (11→bullseye … 14→forky) and renders it into `preseed.cfg`. An unknown major **aborts the build** instead of installing from the wrong suite. Override with `DEBIAN_SUITE=<codename>`, or add the release to the `case`.
- **Download URL.** `cdimage.debian.org/debian-cd/current/` only carries the newest point release; older ones move to `cdimage/archive/<version>/`. The build tries current first, then the archive.

So a point release is `DEBIAN_RELEASE=13.7.0 ./build-iso.sh`, and a major release is that plus one line in the `case` if the codename is not listed yet. Neither touches the preseed.

Only the 13 row has been installed from. The bullseye/bookworm/forky rows are lookups that were checked as strings, not exercised against a real ISO — and a preseed that works on 13 is not guaranteed to work on another major (see below).
,

## Target requirements

- **Exactly two disks, both wiped without confirmation.** `raid-setup.sh` takes the two largest that are not the install medium — a smaller third disk is left alone. Equal sizes are ordered by device name, so the pair stays the same across boots. Fewer than two aborts the install rather than falling back to one disk.
- **~53 GB per disk minimum** (tested on 64 GB): 512 MB ESP + 1 GB `/boot` + up to 8 GB swap + 30 GB `lv_root` + 10 GB minimum `lv_var`, and only 99% of the VG is offered to the recipe. Below that partman cannot satisfy the recipe.
- DHCP with internet access — netinst pulls from `deb.debian.org`.
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