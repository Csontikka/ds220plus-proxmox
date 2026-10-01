# Boot chain: DOM, Synology GRUB, ZFSBootMenu, Proxmox

```
firmware -> Synology GRUB (DOM p1, signed .efi) -> menu SynoBootLoader.conf
         -> ZFSBootMenu A or B (kernel + initramfs on the DOM)
              early hook: disk and USB power (GPIO), factory MACs, bond, network, SSH, boot guard
         -> kexec -> Proxmox VE (Debian 13, Proxmox kernel) on rpool/ROOT/pve-1 (ZFS mirror)
```

## The DOM

`/dev/synoboot` under DSM: 120 MiB (245760 sectors of 512 bytes), GPT.

| Partition | Size | Type | Free (as shipped) | Content |
|---|---|---|---|---|
| p1 `synoboot1` | 32 MB | EFI System (FAT) | about 22 MB | `EFI/boot/SynoBootLoader.efi` (signed GRUB), `EFI/boot/SynoBootLoader.conf` (the menu), `GRUB_VER`, the factory recovery `zImage`, `rd.gz`, `model.dtb` |
| p2 `synoboot2` | 84 MB | ext2 | about 66 MB | the current DSM `zImage` and `rd.gz`, `model.dtb`, `grub_cksum.syno`, `checksum.syno`, `vender` (serial number, MACs), `machine.key` |

p2 spans sectors 67584 to 239615. The boot guard state lives in one sector at LBA 244000,
outside every partition and outside the GPT backup.

**The partition UUIDs are the same on every DS220+.** p1 is `10EE-589C`, p2 is
`45e5b07d-4783-4867-a369-f99c0cd1e610`. They come from the factory DOM image, not from the
individual box. Synology's own menu finds the partitions by these UUIDs, and so do the
menus, hooks and scripts here. `tools/syno-dom-zbm.sh` checks them before it writes
anything and stops if they differ.

What goes where:

| Path | Partition | Written by |
|---|---|---|
| `EFI/boot/SynoBootLoader.conf` | p1 | the menu (`tools/menu/`) |
| `EFI/boot/SynoBootLoader.conf.factory` | p1 | saved factory menu (`syno-dom-zbm.sh write`) |
| `/zbm/vmlinuz-bootmenu`, `/zbm/initramfs-bootmenu.img` | p2 | ZFSBootMenu slot A |
| `/zbmb/vmlinuz-bootmenu` | p1 | ZFSBootMenu slot B kernel |
| `/zbmb/initramfs-bootmenu.img` | p2 | ZFSBootMenu slot B initramfs (p2 is too small for both copies) |
| `/zbm/ok`, `/zbmb/ok` | p2 | slot markers: a slot is bootable only while its marker exists |
| `/zbm-menu` | p2 | one-shot flag: ZFSBootMenu waits in its menu |
| `/zbm-net.conf` | p2 | fixed address for ZFSBootMenu (`address=192.0.2.10/24`, `gateway=192.0.2.1`) |

The DOM content is tied to the model and the boot loader is not part of the DSM `.pat`.
**Keep a full `dd` image of your DOM** before you change anything.

## The Synology GRUB

There is no `grub.cfg`. GRUB reads `EFI/boot/SynoBootLoader.conf`. The factory menu:

```
syno_serial --pci=0,24,2 --speed=115200 --uppci=0,24,0 --upspeed=115200
terminal_input serial
terminal_output serial
set default='1'
set timeout='3'
set fallback='0'

menuentry "SYNOLOGY_1" {          # factory recovery kernel from p1
	search --fs-uuid --no-floppy --set=root 10EE-589C
	...
}
menuentry "SYNOLOGY_2" {          # the DSM from p2 (default)
	search --fs-uuid --no-floppy --set=root 45E5B07D-4783-4867-A369-F99C0CD1E610
	cksum /grub_cksum.syno
	vender /vender -s
	...
}
```

- The console is the UART at 00:18.2 (`--pci=0,24,2`), the microcontroller ("up") is at
  00:18.0.
- `cksum` and `vender` are Synology commands. `vender /vender -s` adds `sn=`, `macs=` and
  `syno_ttyS0/1=` to the kernel command line. Every entry here uses it, so Linux gets the
  factory MACs.
- `fallback` only helps when an entry fails inside GRUB (a missing file). It does not
  help when Linux hangs later.

### What this GRUB cannot do

The GRUB is an old build (the module list identifies it as 2.02~beta3). Measured on the box:

- No `test` / `[`, no `source`, no `configfile`, no `load_env` / `save_env`, no `regexp`,
  no `chainloader`. The string "source" found in the `.efi` is an internal function name.
- `ls (dev)/file` fails on files ("not a directory").
- So the usual one-shot boot with `next_entry` in grubenv is not possible. The only
  condition that works is the exit code of a command in `if`:
  `if search --no-floppy --file --set=x /zbm-menu; then set default='4'; fi`.
- The serial menu editor drops characters (it redraws on every key). The GRUB command
  line (`c`) works when you type slowly.
- `earlycon` with `keep_bootcon` on 0xA1217000 hangs the kernel when the `dw-apb-uart`
  driver takes over the port. Use a plain `console=`.

### The final menu (`tools/menu/SynoBootLoader.conf`)

| # | Entry | What |
|---|---|---|
| 0 | SYNOLOGY_1 | factory recovery kernel (p1), never touched |
| 1 | SYNOLOGY_2 | DSM kernel (p2), kept as it came |
| 2 | ZBM | ZFSBootMenu A, boots Proxmox after a 10 s timeout |
| 3 | ZBM_B | ZFSBootMenu B, the previous known-good copy |
| 4 | ZBM_MENU | ZFSBootMenu A, waits in its menu (SSH rescue) |
| 5 | ZBM_B_MENU | the same with B |

Default: ZBM if `/zbm/ok` exists (fallback ZBM_B, then SYNOLOGY_1), else ZBM_B if
`/zbmb/ok` exists, else SYNOLOGY_1. If `/zbm-menu` exists: ZBM_MENU (fallback ZBM_B_MENU,
then SYNOLOGY_1). The ZFSBootMenu hook deletes `/zbm-menu`.

The ZBM entries pass `efi=noruntime`. The firmware runs Secure Boot, and with EFI runtime
services the kernel IMA policy refuses to kexec the Proxmox-signed kernel.

### The transitional menu (`tools/menu/SynoBootLoader.dsm-transition.conf`)

Used while installing from DSM. Same entries and numbering, but the default is
SYNOLOGY_2 (DSM, fallback SYNOLOGY_1), no `ok` markers are used, and only `/zbm-menu`
switches to ZBM_MENU for one boot. Its ZBM_MENU entries add `panic=30` and `syno.wd`
(the hook arms the WDAT watchdog). See [install-from-dsm.md](install-from-dsm.md).

## ZFS layout

Why ZFS: the Proxmox installer uses a ZFS mirror for the root, a mirror with one missing
disk still imports (DEGRADED) and boots, and checksums plus scrub repair silent
corruption. A btrfs RAID1 needs a manual `degraded` mount option to boot with one disk.
DSM itself uses mdadm RAID1 (md0 system, md1 swap, md2 data) with ext4 or btrfs on top.

`tools/zbm/syno-install.sh wipe` creates on both disks (selected by serial number):

- GPT, partition 1: 128 GiB, `rpool` (mirror); partition 2: the rest minus 1 GiB, `data`
  (mirror).
- `rpool`: `ashift=12`, `compatibility=openzfs-2.3-linux` (ZFSBootMenu must read it, so
  never run `zpool upgrade` on it), `compression=lz4`, `acltype=posixacl`, `xattr=sa`,
  `relatime=on`, `dnodesize=auto`, `normalization=formD`.
- `rpool/ROOT/pve-1` is the root (with `/boot`), `bootfs` of the pool. Its
  `org.zfsbootmenu:commandline` is
  `ro quiet console=tty0 console=ttyS5,115200n8 panic=30 oops=panic softlockup_panic=1`.
- `rpool/var-lib-vz` for `/var/lib/vz`.
- `data` mounted at `/data`, free to upgrade (ZFSBootMenu does not read it), with
  `data/reserve` (`refreservation=200G`) so the pool never fills up completely.
- No swap on a zvol (known deadlock risk). `first-boot.sh` limits the ARC to 1 GiB.

The disks carry no boot loader. Everything that boots is on the DOM.

## ZFSBootMenu

ZFSBootMenu is a small Linux kernel plus initramfs that imports the pool, finds the
kernels in `/boot` and starts the chosen one with kexec. Kernel updates of Proxmox go to
the ZFS `/boot`; the DOM only changes when ZFSBootMenu itself is updated.

The build (`tools/zbm/build-zbm.sh`) uses the Proxmox kernel (ZFS built in) and a
trimmed dracut config (`overlay/etc/zfsbootmenu/dracut.conf.d/ds220.conf`) so it fits on
the DOM. Hooks:

- `hooks/early-setup.d/10-ds220.sh` (after udev, before any pool import):
  0. with `zbm.show`: removes the `/zbm-menu` flag first (waits up to 30 s for the DOM);
  0b. with `syno.wd`: arms the WDAT watchdog, disarm with `/usr/local/sbin/syno-wd-stop`;
  1. fan at `V50` on the microcontroller UART, front LEDs;
  2. USB power (29/30), disk bay 1 (20), 5 s, bay 2 (21), SATA rescan until two disks are
     there (up to 40 s);
  3. factory MACs from `macs=`;
  4. an active-backup bond over both ports with the LAN1 factory MAC; address from
     `/zbm-net.conf` on the DOM, otherwise DHCP (host name from `SYNO_ZBM_NAME`, no
     client-id). If the fixed gateway does not answer within about 60 s, DHCP starts as
     well. Then dropbear SSH on port 22.
- `hooks/early-setup.d/20-bootguard.sh`: the boot guard (see [rescue.md](rescue.md)).
- `hooks/setup.d/10-syno-leds.sh`, `hooks/teardown.d/90-syno-leds.sh`: front LEDs while
  the menu waits and right before kexec.

## Hardware ZFSBootMenu and the installed system handle

| What | Device | Driver |
|---|---|---|
| Network | 2x RTL8168H | `r8169` + `rtl_nic/rtl8168h-2.fw` |
| GPIO (disk and USB power) | Gemini Lake INT3453 | `pinctrl_geminilake` + `gpioset` (libgpiod) |
| SATA | AHCI | `ahci`, rescan after power on |
| USB | xHCI | `xhci_pci`, `usb_storage`, `uas` |
| Microcontroller UART | LPSS 00:18.0 (8086:31bc) | `8250_dw`, `intel_lpss_pci` |
| Watchdog | ACPI WDAT | `wdat_wdt` |
| Temperatures | CPU, disks | `coretemp`, `drivetemp` |
