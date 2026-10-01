# Rescue: so you never have to go to the box

Every part below was tested on a running unit.

## The layers

| Failure | What catches it | How |
|---|---|---|
| ZFSBootMenu damaged or missing on the DOM | **A/B ZFSBootMenu** | GRUB boots A while `/zbm/ok` exists. If A does not load, it falls back to B, and in the end to the factory recovery (`SYNOLOGY_1`). |
| A bad ZFSBootMenu update | **A/B and the markers** | Only one slot is written at a time. The slot's marker is removed first and comes back only after the checksums match (`tools/zbm/syno-zbm-slot.sh`). Update A, test it, then copy the same build to B. |
| Proxmox does not come up (kernel, update, network, service) | **Boot guard** | ZFSBootMenu writes `pending` before every automatic boot. Proxmox writes `ok` when the web UI answers and the default gateway replies (`syno-bootguard-ok.service`, up to 5 minutes). If ZFSBootMenu finds anything but `ok`, it does **not** boot, stays in its menu, SSH open. |
| Proxmox hangs | **Hardware watchdog** | ACPI WDAT (`wdat_wdt`), armed by systemd (`RuntimeWatchdogSec=60s`, `syno-watchdog.conf`). A hang resets the box after about 55 to 60 s more. Proxmox blacklists `wdat_wdt`, so `syno-wdat.service` loads it by name. |
| Anything else (ZFSBootMenu hangs, nothing answers) | **Remote power cut** | A smart plug: off, at least 15 s, on. The box starts by itself, whether it was running or shut down. |

The boot guard state is one 512-byte sector at LBA 244000 of the DOM (245760 sectors),
outside every partition and the GPT backup. One sector, no file system, so a power cut
cannot damage the DOM partitions. `syno-bootguard` only writes when the disk has exactly
245760 sectors, carries the p2 UUID and its model string contains "diskstation" (any case).

```sh
syno-bootguard status                  # ok, pending, failed, unknown
syno-bootguard set ok|pending|failed
```

## When Proxmox does not come up

1. **Wait 5 to 6 minutes.** A hang is reset by the watchdog, and the boot guard stops the
   next boot in ZFSBootMenu.
2. If nothing answers: **cut the power** (15 to 30 s). The boot guard stops the next boot.
3. **SSH into ZFSBootMenu.** It uses the address in `/zbm-net.conf` on DOM p2 (the same
   fixed address as Proxmox when `syno-net-switch.sh` wrote it), on a bond with the LAN1
   factory MAC, but its host key differs from the one of Proxmox. Without the file, or with
   a broken one, it uses DHCP. If the fixed gateway does not answer within about 60 s
   (a typo, a wrong subnet), DHCP starts as well and adds its address next to the fixed
   one. Find that address by MAC (`tools/syno-find.ps1`). The login message lists the
   options:
   - `zfsbootmenu`: the menu (snapshots, older kernels, recovery shell, chroot);
   - `syno-bootguard set ok; busybox reboot -f`: try a normal boot once more;
   - boot directly from ZFSBootMenu without a reboot (the kernel list must be built in
     the same command, or it fails with "kernel list missing"):
     `bash -c 'source /etc/zfsbootmenu.conf; source /lib/kmsg-log-lib.sh; source /lib/zfsbootmenu-core.sh; find_be_kernels rpool/ROOT/pve-1 >/dev/null && kexec_kernel "$(select_kernel rpool/ROOT/pve-1)"'`
4. To get into the ZFSBootMenu menu from a **working** system: create an empty file
   `zbm-menu` in the root of DOM p2 (one-shot), or run `syno-bootguard set failed`, then
   reboot.

## ZFSBootMenu update

1. Build on the build host: `sudo SYNO_HOSTID=<hostid of the box> sh tools/zbm/build-zbm.sh <outdir>`
   ([building.md](building.md)). Test it in QEMU (`tools/zbm/qemu-test.sh`).
2. Keep the build with its `SHA256SUMS`.
3. On Proxmox: `sh tools/zbm/syno-zbm-slot.sh a <outdir>`, reboot, check that the boot guard
   went `pending`, then `ok`.
4. If good: `sh tools/zbm/syno-zbm-slot.sh b <outdir>`. If not: B boots (GRUB menu entry, or
   remove A's marker), and A can be written again.

`syno-zbm-slot.sh` refuses to touch a slot while the other one is not marked ok.

## What can only be fixed on site

- Hardware: a disk, the power supply, the board.
- The DOM itself (with the factory GRUB). Restoring the DOM image needs the box opened
  and the DOM taken out, or a DSM reinstall from the factory recovery and starting over.

## Disk replacement (ZFSBootMenu needs no change)

ZFSBootMenu has no disk IDs: it powers both bays, waits up to 40 s for two SATA disks (by
count), then imports what it finds. The disks carry no boot loader.

1. Take out the failed disk and put in the new one (hot swap; the system keeps running
   degraded).
2. Copy the partition table from the healthy disk and give it new GUIDs:
   `sgdisk -R /dev/disk/by-id/<new> /dev/disk/by-id/<healthy>` and
   `sgdisk -G /dev/disk/by-id/<new>`.
3. `zpool replace rpool <old>-part1 <new>-part1` and
   `zpool replace data <old>-part2 <new>-part2`, then `zpool status` until the resilver ends.

## Hostid

The hostid of the installed system is built into ZFSBootMenu (`build-zbm.sh`,
`SYNO_HOSTID`). ZFSBootMenu 3.1 only adopts the pool owner's hostid for `ONLINE` pools.
With one disk missing (`DEGRADED`) it does not, and the import fails ("last accessed by
another system"). This happened on a real unit.

The hostid belongs to the box and does not change with a disk. **If Proxmox is
reinstalled from scratch, give it the same hostid** (`zgenhostid -f <hostid>`), or rebuild
ZFSBootMenu with the new one. `syno-install.sh finish` writes the hostid the pools were
created with into the new system.
