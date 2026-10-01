# ds220plus-proxmox

Turn a Synology DS220+ into a Proxmox VE host that boots from a ZFS mirror and can be
rescued remotely, without opening the box.

The DS220+ boots from a small internal USB flash module (the DOM, 120 MiB) that holds
Synology's own GRUB. This project keeps that GRUB and the factory recovery entry, adds
ZFSBootMenu to the DOM, and puts Debian 13 with the Proxmox kernel on a ZFS mirror of the
two disks.

## What you get

- **DOM boot, factory parts kept.** The Synology GRUB, its signed `.efi` and the factory
  recovery kernel stay untouched. Only the menu file and a few new files are added.
- **A/B ZFSBootMenu.** Two copies of ZFSBootMenu on the DOM. GRUB boots slot A while its
  `ok` marker exists, falls back to slot B, and in the end to the factory recovery.
- **Boot guard.** ZFSBootMenu writes `pending` before every automatic boot, Proxmox writes
  `ok` once the web UI and the gateway answer. If the last boot never reported healthy,
  ZFSBootMenu stays in its menu with SSH open instead of booting the broken system again.
- **Hardware watchdog.** The ACPI WDAT watchdog (`wdat_wdt`) resets a hung system.
- **Remote rescue.** ZFSBootMenu brings up the network (the same fixed address as the
  installed system, or DHCP) and a dropbear SSH server.
- **synofand.** A small daemon for the front microcontroller: fan curve (the one DSM uses
  on this model), fan tachometer, front LEDs, buttons, and a clean power off when a disk or
  the CPU gets too hot.
- Factory MAC addresses for both ports, disk bay power by GPIO, an active-backup bond.

## Hardware

Tested on the DS220+ only (two units, BIOS and DOM as shipped). Other Gemini Lake models
(DS420+, DS720+, DS920+) are similar, but pins, LEDs and the DOM layout differ. Do not use
this on another model without checking every value in [docs/hardware.md](docs/hardware.md).

## Warnings

- This voids any warranty and is not supported by Synology or Proxmox.
- **The install wipes both disks.** All DSM data is gone. Back it up first.
- A mistake in the DOM menu can stop the box from booting. Take a full image of the DOM
  (`dd`) before you write anything to it, and keep it off the box.
- There is no guarantee of any kind (see the license). Read the whole install guide before
  you start.

## Install paths

1. **From a running DSM, no serial console:** [docs/install-from-dsm.md](docs/install-from-dsm.md).
   Everything goes over SSH. Until the disks are wiped, every step can be undone and a
   power cycle brings DSM back.
2. **With a serial console** (3.3 V TTL adapter on the board header):
   [docs/install-serial-console.md](docs/install-serial-console.md). This is how the method
   was developed. It uses a small rescue Debian on a USB stick.

Both paths end with the same system. After the install:
[docs/rescue.md](docs/rescue.md) (what to do when Proxmox does not come up, ZFSBootMenu
updates, disk replacement).

## Documentation

| File | Content |
|---|---|
| [docs/hardware.md](docs/hardware.md) | GPIO pins, microcontroller, UARTs, serial header, BIOS backup |
| [docs/boot-chain.md](docs/boot-chain.md) | DOM layout, the Synology GRUB and its limits, ZFS layout, ZFSBootMenu |
| [docs/install-from-dsm.md](docs/install-from-dsm.md) | install over SSH from DSM |
| [docs/install-serial-console.md](docs/install-serial-console.md) | install with a serial console |
| [docs/rescue.md](docs/rescue.md) | rescue path, A/B updates, disk replacement, hostid |
| [docs/fan-and-leds.md](docs/fan-and-leds.md) | fan control, tachometer, LEDs, buttons |
| [docs/building.md](docs/building.md) | building ZFSBootMenu, the root filesystem and the rescue image |
| [docs/lessons.md](docs/lessons.md) | pitfalls found the hard way |

## Repository layout

```
synofand/                 fan, LED and button daemon (Python, with unit tests)
tools/
  check-kritikus.sh       checks the boot-critical files (LF, ASCII, no BOM, sh -n)
  syno-dom-zbm.sh         puts ZFSBootMenu and the transitional menu on the DOM from DSM
  syno-dom-install.py     puts the rescue Debian boot files on the DOM from DSM (over SSH)
  syno-usb-write.py       writes an image to a USB stick in the NAS from DSM (over SSH)
  syno-find.ps1           finds the box on the LAN by its MAC addresses (Windows)
  serial-watch.py         serial console logger with a command file
  netconsole-watch.py     netconsole receiver
  menu/                   DOM GRUB menus: final and transitional
  zbm/                    ZFSBootMenu build, hooks, installer, slot writer, QEMU test
  bootguard/              boot guard and its systemd unit
  pve/                    root filesystem build, overlay, post-install scripts, probes
  synodeb/                rescue Debian image for a USB stick
```

## Before you build

- Put your SSH public keys into `tools/zbm/overlay/root/.ssh/authorized_keys` and
  `tools/pve/overlay/root/.ssh/authorized_keys` (and `tools/synodeb/...` for the rescue
  image). The builds stop without them.
- Set your address in `tools/pve/overlay/etc/network/interfaces` and
  `tools/pve/overlay/etc/hosts`, or build with `SYNO_NET=dhcp`.
- See [docs/building.md](docs/building.md).

## License

GPL-3.0, see [LICENSE](LICENSE). `tools/pve/post-install/pve-remove-nag.sh` follows the
community-scripts ProxmoxVE post-install helper (MIT).
