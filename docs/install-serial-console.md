# Install with a serial console

This is the path the method was developed on. A serial console lets you pick GRUB
entries by hand and watch the early boot. If you do not want to open the box, use
[install-from-dsm.md](install-from-dsm.md) instead: it needs no console.

The steps use a small rescue Debian ("synodeb") on a USB stick in the NAS. It is booted
once from the DOM and is useful as a second rescue system later.

## What you need

- A 3.3 V TTL USB serial adapter on header **J5** (next to the buttons): pin 2 = GND,
  pin 4 = TX of the NAS, pin 6 = RX of the NAS; cross RX and TX; do not connect VCC.
  115200 8N1. See [hardware.md](hardware.md).
- A USB stick (at least 4 GB) for the rescue image.
- A Linux build host ([building.md](building.md)) and a PC with Python and `paramiko`
  (for the DSM helper scripts) or `pyserial` (for the console logger).
- A full backup of the NAS data. **The install wipes both disks.**

## Serial console logging

```sh
python tools/serial-watch.py COM15 115200 serial.log
```

It writes a timestamped `serial.log` (and `serial.log.raw`). Every line you append to
`serial.log.in` is sent to the port: `^C`, `^M`, `^[`, `<UP>`, `<DOWN>` are keys, and a
line starting with `~` is typed slowly (the GRUB editor drops characters on a serial
line). With `AUTO_CTRLC=1` it sends Ctrl-C when GRUB shows its countdown.

Without a cable, the rescue Debian can send its kernel log over the network with
netconsole: add `synodeb.nc=<pc-ip>[/<pc-mac>] synodeb.ncsrc=<nas-ip>` to its kernel
command line and run `python tools/netconsole-watch.py` on the PC (UDP 6666).

## 1. Take a DOM image (under DSM)

As in [install-from-dsm.md](install-from-dsm.md), phase 0: `sh syno-dom-zbm.sh check`
and a full `dd` image of `/dev/synoboot`, stored off the box.

## 2. The rescue Debian on a USB stick

Build it on the build host (`sudo sh tools/synodeb/build.sh /srv/synodeb-out`). It gives
`vmlinuz`, `initrd.img` and `synodeb.img.gz`.

Put the stick into the NAS and write the image from the PC, over SSH to DSM:

```sh
python tools/syno-usb-write.py synodeb.img.gz 192.0.2.10 usb1 7864320
```

The last argument is the exact size of the stick in 512-byte sectors (see
`/sys/block/usb1/size` under DSM). The script only writes to a removable `usbN` device of
exactly that size that is not the DOM, and reads the image back to compare the SHA256.
`DSM_USER` and `DSM_SSH_PORT` set the login; the password is asked for.

## 3. Boot the rescue Debian once

```sh
python tools/syno-dom-install.py 192.0.2.10 vmlinuz initrd.img tools/synodeb/SynoBootLoader.synodeb.conf --once
```

This saves the factory menu as `SynoBootLoader.conf.orig` (only once), copies the kernel
and initramfs to `/synodeb/` on DOM p2, installs the menu, creates the one-shot flag
`/linux-once` on p2, and verifies everything read-only.

The menu keeps DSM as the default and adds a third entry, `DEBIAN_USB`. While
`/linux-once` exists, GRUB boots `DEBIAN_USB` with DSM as the fallback. The first thing
the rescue initramfs does (`init-top/synodeb-flag`) is delete the flag, so the next boot
is DSM again, whatever happens after that. The kernel runs with `panic=30`,
`oops=panic` and `softlockup_panic=1`.

Reboot DSM. The rescue Debian comes up with DHCP and SSH (your key from
`tools/synodeb/overlay/root/.ssh/authorized_keys`). It powers the USB ports in its
initramfs, sets the factory MACs, and `synodeb-disks` powers the disk bays. Its boot
logs are copied to the stick's `SYNOLOG` partition, which DSM can read after a fallback.

To remove it again: `python tools/syno-dom-install.py 192.0.2.10 --restore`.

## 4. Start ZFSBootMenu

Build ZFSBootMenu ([building.md](building.md)). From the rescue Debian, copy it to DOM p2:

```sh
mkdir -p /mnt/dom2
mount "$(blkid -U 45e5b07d-4783-4867-a369-f99c0cd1e610)" /mnt/dom2
mkdir -p /mnt/dom2/zbm
cp vmlinuz-bootmenu initramfs-bootmenu.img /mnt/dom2/zbm/
(cd /mnt/dom2/zbm && sha256sum vmlinuz-bootmenu initramfs-bootmenu.img)   # compare with SHA256SUMS
umount /mnt/dom2
```

Reboot. Press Ctrl-C within 3 seconds when GRUB counts down, press `c` for the command
line, and type slowly:

```
search --fs-uuid --no-floppy --set=root 45E5B07D-4783-4867-A369-F99C0CD1E610
vender /vender -s
linux /zbm/vmlinuz-bootmenu ro loglevel=4 console=tty0 console=ttyS5,115200n8 efi=noruntime zbm.show
initrd /zbm/initramfs-bootmenu.img
boot
```

ZFSBootMenu comes up with SSH (on DHCP, or on the address in `/zbm-net.conf` on DOM p2).
You can also use the transitional menu and the `/zbm-menu` flag instead, as in
[install-from-dsm.md](install-from-dsm.md); then no typing at the GRUB prompt is needed.

## 5. Install, final menu, live system

The same as phases 3 to 5 of [install-from-dsm.md](install-from-dsm.md):

1. `wipe <serial1> <serial2>`, `unpack`, `finish` with `tools/zbm/syno-install.sh`
   (irreversible from `wipe` on);
2. `finalize` with `tools/menu/SynoBootLoader.conf` (it replaces the rescue menu, so the
   `DEBIAN_USB` entry is gone; the files under `/synodeb/` stay);
3. `first-boot.sh`, `post-install.sh`, boot guard `ok` before the first reboot, then slot B
   with `syno-zbm-slot.sh b`.

## Going back

- Before `wipe`: DSM is untouched on the disks. Restore the menu (`--restore`, or
  `syno-dom-zbm.sh undo` when the transitional menu was used) or write back the DOM image.
- After `wipe`: DSM only comes back through the factory recovery (`SYNOLOGY_1`) and a
  `.pat` file. The DOM image stays your last resort.
- The rescue Debian on the stick and the ZFSBootMenu SSH remain rescue systems.
