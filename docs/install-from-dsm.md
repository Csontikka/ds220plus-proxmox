# Install from a running DSM (no serial console)

This path turns a DS220+ that runs DSM into a Proxmox VE host over SSH only. Nobody has
to open the box. It was used on a second unit after the method had been developed with a
serial console ([install-serial-console.md](install-serial-console.md)).

What you need:

- SSH access to DSM with an administrator account (`sudo -i`).
- A Linux build host (Debian 12/13 or Proxmox, real root) for the images: see
  [building.md](building.md).
- Strongly recommended: a way to cut the power remotely (a smart plug). It is the rescue
  for the one case where ZFSBootMenu hangs before it removes its one-shot flag.
- A copy of every piece of data on the NAS. **Phase 3 wipes both disks.**

## The idea: every step can be undone until the disks are wiped

| Phase | Runs on | What happens | If it goes wrong |
|---|---|---|---|
| 0. Survey | DSM, SSH | DOM image (`dd`, read only), UUIDs, MACs, disks, the menu | nothing has changed |
| 1. Prepare | DSM, SSH | ZFSBootMenu slot A on the DOM, the **transitional menu**: DSM stays the default | `syno-dom-zbm.sh undo`, or write back the DOM image |
| 2. One ZFSBootMenu boot | DSM, reboot | one-shot flag on the DOM, ZFSBootMenu waits in its menu with SSH | power cycle: the flag is already gone, DSM boots |
| 3. **Point of no return** | ZFSBootMenu, SSH | wipe the DSM disks, pools, unpack the Proxmox root filesystem | DSM only comes back with the factory recovery (`SYNOLOGY_1`, `.pat`) |
| 4. Final menu | ZFSBootMenu, SSH | final menu and slot A's `ok` marker: ZFSBootMenu boots by default | A/B slots, boot guard, watchdog ([rescue.md](rescue.md)) |
| 5. Live system | Proxmox | `proxmox-ve`, post-install, slot B | ZFSBootMenu: roll back to a snapshot |

## 0. Survey (read only, under DSM)

Copy `tools/syno-dom-zbm.sh` to the NAS, then as root:

```sh
sh syno-dom-zbm.sh check
```

It checks that the DOM has 245760 sectors, that the partition UUIDs are the factory ones
(`10EE-589C` and `45e5b07d-4783-4867-a369-f99c0cd1e610`, the same on every DS220+, see
[boot-chain.md](boot-chain.md)), that the menu references them, and prints the checksums
of the `.efi` and the menu, the free space and the files on p2.

**Take a full image of the DOM** and store it off the box:

```sh
cd /dev && dd if=./synoboot bs=1M > /volume1/somewhere/dom.img && sha256sum /volume1/somewhere/dom.img
```

Write down:

- the factory MACs: `cat /proc/cmdline` (`macs=`), or the label on the back;
- the disk serial numbers: `ls -l /dev/disk/by-id/` (the part after the last `_` of the
  `ata-<model>_<serial>` link);
- the SMART state of both disks.

**Why the relative path:** DSM refuses `mount /dev/synoboot1 ...` with "wrong fs type",
because its kernel only lets its own processes use the `/dev/synoboot*` paths. The
relative path works for `mount`, `blkid`, `blockdev` and `dd`:
`cd /dev && mount ./synoboot1 /tmp/sbdom1`. All DOM tools here do it this way.

## 1. Prepare (under DSM, the disks are not touched)

On the build host, build ZFSBootMenu and the root filesystem ([building.md](building.md)):

```sh
sudo SYNO_HOSTID=$(openssl rand -hex 4) SYNO_ZBM_NAME=nas1-zbm sh tools/zbm/build-zbm.sh /srv/zbm-out
sudo SYNO_HOSTNAME=nas1 SYNO_NET=dhcp SYNO_TZ=Europe/Berlin sh tools/pve/build-rootfs.sh /srv/rootfs-out
```

Put together a directory for the DOM:

```sh
mkdir dom-a
cp /srv/zbm-out/vmlinuz-bootmenu /srv/zbm-out/initramfs-bootmenu.img /srv/zbm-out/SHA256SUMS dom-a/
cp tools/menu/SynoBootLoader.dsm-transition.conf dom-a/SynoBootLoader.conf
# optional: a fixed address for ZFSBootMenu (without it: DHCP)
printf 'address=192.0.2.10/24\ngateway=192.0.2.1\n' > dom-a/zbm-net.conf
```

The file on the DOM must be called `SynoBootLoader.conf`. `write` refuses a menu that is
not the transitional one (it must contain `zbm-menu` and `set default='1'`), and any file
with a CR. Copy `dom-a/` and `syno-dom-zbm.sh` to the NAS, then as root under DSM:

```sh
sh syno-dom-zbm.sh write dom-a
sh syno-dom-zbm.sh verify dom-a
```

`write` checks the build checksums and the free space, writes ZFSBootMenu slot A to p2
first, saves the factory menu once as `SynoBootLoader.conf.factory`, and writes the menu to
p1 last. Every file is written under a temporary name, compared, then renamed. The `.efi`
is never touched. No `ok` marker is written: in the final menu that marker would make
ZFSBootMenu the default.

The transitional menu:

- boots **DSM** (`SYNOLOGY_2`) by default, not the factory recovery;
- boots `ZBM_MENU` once when `/zbm-menu` exists in the root of DOM p2, with DSM as the
  fallback.

**Test it:** reboot DSM without the flag. DSM must come back (about 2 minutes). If not,
the DSM entry still boots through `fallback` on a GRUB error; `sh syno-dom-zbm.sh undo`
puts the factory menu back and removes the ZFSBootMenu files.

## 2. One ZFSBootMenu boot

```sh
sh syno-dom-zbm.sh flag      # under DSM, then reboot DSM
```

ZFSBootMenu starts. The first thing its early hook (`10-ds220.sh`) does is remove the
flag, before disks, network or SSH. Then it arms the WDAT watchdog (the `syno.wd`
option of the transitional menu), powers the disks, sets the factory MACs, builds the
bond, brings up the network and starts dropbear.

Log in and disarm the watchdog at once:

```sh
ssh root@192.0.2.10
/usr/local/sbin/syno-wd-stop
```

If you do not, the WDAT resets the box after about half a minute plus the firmware delay,
and DSM boots again (the flag is gone).

Finding the box:

- with `zbm-net.conf`: the fixed address. If its gateway does not answer within about
  60 s, DHCP starts as well and adds a second address;
- without it: DHCP. ZFSBootMenu asks for its address with the name set by `SYNO_ZBM_NAME`
  (default `syno-zbm`), so it may resolve by that name through your DHCP server's DNS.
  Or search the LAN by MAC: `.\tools\syno-find.ps1 -Mac 00-11-32-xx-xx-xx,00-11-32-yy-yy-yy`
  on Windows.

**If there is no SSH within 5 minutes:** cut the power for at least 15 s. The flag is
already gone, so the box boots DSM. Only a hang before the flag was removed (a kernel
failure right at the start) would boot ZFSBootMenu again. That is the one case that
needs a console. The same ZFSBootMenu image had booted many times on another unit
before, and the flag removal is the hook's first step.

## 3. Install from ZFSBootMenu (the point of no return)

Only go on when the data is safe elsewhere. Work step by step, one command at a time, and
read each output before the next step. Do not chain the steps in a pipeline: `finish | tail`
returns the exit code of `tail`, and a failed `finish` would not stop `finalize`.

```sh
# partitions, pools, datasets (DESTROYS both disks); serials as in /dev/disk/by-id
ssh root@192.0.2.10 'sh -s wipe WD-SERIAL1 WD-SERIAL2' < tools/zbm/syno-install.sh

# the next steps read stdin themselves, so they run from a copy on the box
ssh root@192.0.2.10 'cat > /tmp/syno-install.sh' < tools/zbm/syno-install.sh
ssh root@192.0.2.10 'sh /tmp/syno-install.sh unpack' < /srv/rootfs-out/syno-rootfs.tar.zst
ssh root@192.0.2.10 'sh /tmp/syno-install.sh finish'
```

- `wipe` selects each disk by serial number (it must match exactly one whole disk, never
  `sdX`), clears old labels, partitions both disks and creates `rpool` and `data` (layout
  in [boot-chain.md](boot-chain.md)).
- `unpack` extracts the root filesystem into `/mnt`.
- `finish` writes the hostid the pools were created with into the new system, sets the
  pool cache files, sets the boot guard state to `ok` (so the first boot goes through),
  prints the owners of a few files, unmounts and exports both pools. It ends with
  `FINISHED`.

The hardware clock can be years off in ZFSBootMenu (DSM uses NTP and may not set it).
`tar` then only warns; time sync fixes it after the first boot.

## 4. Final menu and first boot

Still in ZFSBootMenu:

```sh
ssh root@192.0.2.10 'sh /tmp/syno-install.sh finalize' < tools/menu/SynoBootLoader.conf
```

`finalize` checks that slot A is on the DOM and that stdin is the final menu (it contains
`/zbm/ok`, no CR), writes it to p1, creates `/zbm/ok`, removes `/zbm-menu`, and ends with
`FINALIZED`. From now on GRUB boots ZFSBootMenu A by default.

Reboot (`busybox reboot -f`). GRUB, ZFSBootMenu (10 s), kexec, Proxmox. The boot guard
protects every boot from now on.

## 5. The live system

Copy the `tools/` directory of this repository to the box (for example to `/root/tools`),
then as root:

```sh
sh /root/tools/pve/post-install/first-boot.sh nas1.example.lan
tail -f /root/first-boot.log      # until FIRST-BOOT DONE (or FIRST-BOOT FAILED)
sh /root/tools/pve/post-install/post-install.sh
systemctl start syno-bootguard-ok.service
```

- `first-boot.sh <mailname>`: pins GRUB and os-prober out, pins the LAN1 factory MAC on
  `bond0` and `vmbr0` when `vmbr0` uses DHCP, installs `proxmox-ve`, `postfix` (local
  only), `open-iscsi`, `chrony` and the microcode, limits the ZFS ARC to 1 GiB, and adds
  the `data` pool as Proxmox storage.
- `post-install.sh`: apt sources (no-subscription), the nag removal, HA services off, and
  the boot guard and watchdog units.
- **Before the first reboot** the boot guard state must be `ok`: the boot you are in
  started as `pending`, and the root filesystem does not ship the boot guard until
  `post-install.sh` installs it. `systemctl start syno-bootguard-ok.service` (or
  `/usr/local/sbin/syno-bootguard set ok`) does that. Otherwise the next boot stops in
  ZFSBootMenu; then run `syno-bootguard set ok; busybox reboot -f` there.

Then reboot once (the MAC pin and the watchdog take effect) and write slot B from the
same build:

```sh
sh /root/tools/zbm/syno-zbm-slot.sh b /root/zbm-out     # vmlinuz-bootmenu, initramfs-bootmenu.img, SHA256SUMS
```

To move the box to another network later, use `tools/pve/syno-net-switch.sh`: it changes
the address of Proxmox and `zbm-net.conf` on the DOM together.

## Going back

- Before phase 3: `sh syno-dom-zbm.sh undo` under DSM, or write back the full DOM image.
- After phase 3: the factory recovery entry (`SYNOLOGY_1`) is untouched on the DOM. DSM
  can be reinstalled from it with a `.pat` file. This needs the GRUB menu (serial
  console) or a menu that defaults to entry 0.

## Notes from the first run

- The menu test worked: without the flag DSM came back, with it ZFSBootMenu started. The
  hook removed the flag within 4 s, the watchdog armed, `syno-wd-stop` disarmed it.
- ZFSBootMenu has no coreutils. See [lessons.md](lessons.md).
- The DOM model string differs between units ("DiskStation" and "Diskstation"). The
  boot guard now matches it case-insensitively.
