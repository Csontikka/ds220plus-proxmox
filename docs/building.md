# Building

All images are built on a Linux build host: Debian 12/13 or Proxmox VE, as **real root**.
Not in an unprivileged container: there `mmdebstrap` silently loses every non-root owner
and group. Packages: `mmdebstrap`, `curl`, `zstd`, `dropbear-bin` (for `dropbearkey`),
plus `e2fsprogs`, `dosfstools`, `mtools` for the rescue image and `qemu-system-x86` for
the QEMU test.

Before the first build, put your SSH public keys into the `authorized_keys` file next to
each `authorized_keys.example`:

- `tools/zbm/overlay/root/.ssh/authorized_keys` (ZFSBootMenu),
- `tools/pve/overlay/root/.ssh/authorized_keys` (Proxmox),
- `tools/synodeb/overlay/root/.ssh/authorized_keys` (rescue Debian).

The builds stop without them. They are ignored by git.

## ZFSBootMenu: `tools/zbm/build-zbm.sh`

```sh
sudo SYNO_HOSTID=1a2b3c4d SYNO_ZBM_NAME=nas1-zbm sh tools/zbm/build-zbm.sh /srv/zbm-out
```

| Variable | Meaning |
|---|---|
| `SYNO_HOSTID` | **required**, 8 lower-case hex digits: the hostid of the installed system, built into ZFSBootMenu (see [rescue.md](rescue.md), "Hostid"). For a new install pick any, e.g. `openssl rand -hex 4`; `syno-install.sh finish` gives the new system the same one. For an existing system use what `hostid` prints there. |
| `SYNO_ZBM_NAME` | host name ZFSBootMenu sends with its DHCP request (default `syno-zbm`; lower-case letters, digits and `-`). Give each box its own. |

It builds a Debian 13 chroot with the Proxmox kernel (ZFS built in) and ZFSBootMenu
v3.1.0 from source, adds the overlay (hooks, dracut config, `syno-microp`) and
`tools/bootguard/syno-bootguard`, and runs `generate-zbm`. The dropbear host key is
created once in `tools/zbm/keys/` (ignored by git) and reused, so the SSH host key stays
the same across builds. The build checks that the initramfs contains `wdat_wdt`, the
early hook and `syno-bootguard`, and that vfat is available.

Output: `vmlinuz-bootmenu`, `initramfs-bootmenu.img`, `SHA256SUMS` (of those two) and
`VERSIONS.txt` (versions, hostid, name, date). The pair is about 38 MB and must fit on
DOM p2.

## Root filesystem: `tools/pve/build-rootfs.sh`

```sh
sudo SYNO_HOSTNAME=nas1 SYNO_NET=dhcp SYNO_TZ=Europe/Berlin SYNO_LOCALE=de_DE.UTF-8 sh tools/pve/build-rootfs.sh /srv/rootfs-out
```

| Variable | Default | Meaning |
|---|---|---|
| `SYNO_HOSTNAME` | `syno-pve` | host name (written to `/etc/hostname`, replaced in `/etc/hosts`) |
| `SYNO_NET` | `static` | `static`: `vmbr0` as in `overlay/etc/network/interfaces` (set your address there and in `overlay/etc/hosts`); `dhcp`: `vmbr0` by DHCP, and a dhclient hook keeps the node name on the leased address in `/etc/hosts` (pmxcfs needs a non-loopback address) |
| `SYNO_TZ` | `UTC` | time zone (a zoneinfo name) |
| `SYNO_LOCALE` | none | an extra locale; `en_US.UTF-8` is always generated |

Debian 13 (trixie) with the Proxmox kernel, `zfsutils-linux`, `zfs-zed`,
`zfs-initramfs`, the DS220+ services (`syno-disks`, `syno-macs`, udev names for the
UARTs, the network config with the bond) and `synofand`. The overlay also carries
optional config for sanoid, snmpd and a borg backup unit (`syno-borg`); those packages
are not installed and the units are not enabled by the build.
The root password is locked; login is by SSH key. `proxmox-ve` itself is installed on
the running box (`first-boot.sh`), the way Proxmox documents "install on Debian".

`mmdebstrap`'s own tarball output writes every entry as 0/0, even as real root. So the
system is built into a directory, the owners of a few files are checked, and GNU tar
packs it. Output: `syno-rootfs.tar.zst`, `SHA256SUMS`, `SETTINGS.txt`.

## Rescue Debian: `tools/synodeb/build.sh`

```sh
sudo sh tools/synodeb/build.sh /srv/synodeb-out
```

Debian 13 with the Debian kernel, networkd (DHCP), SSH, GPIO tools, `synofand`, and an
initramfs that powers the USB ports, removes the one-shot flag `/linux-once` from the DOM,
sets the factory MACs and can start netconsole. Output: `vmlinuz`, `initrd.img`,
`kernel.config` and `synodeb.img.gz` (MBR: 3000 MB ext4 root `SYNODEB`, 64 MB vfat log
partition `SYNOLOG`), plus `SHA256SUMS`. See [install-serial-console.md](install-serial-console.md).

## QEMU test: `tools/zbm/qemu-test.sh`

```sh
sh tools/zbm/qemu-test.sh /srv/zbm-out dom.img [seconds]
```

Boots a ZFSBootMenu build in QEMU (TCG, no KVM needed) against a copy of your DOM image,
with the transitional menu's command line and the `zbm-menu` flag set in the copy. It
prints the hook's log lines and checks that the flag was removed ("FLAG REMOVED") and
that p2 is still clean (`e2fsck`). The console log goes to `qemu-console.log` in the
build directory. The DS220+ hardware (GPIO, WDAT, Realtek) is not emulated. Do this
before any new build goes to a box.

## Line endings and `tools/check-kritikus.sh`

A single CR in a GRUB menu, a ZFSBootMenu hook or an initramfs script can stop the box
from booting, and without a console you do not see why. Rules:

- Every file in this repository uses LF line endings, no BOM, a final newline. Files
  that run on the box are plain ASCII. `.gitattributes` enforces LF on checkout
  (`* text=auto eol=lf`), also on Windows.
- Write shell scripts with an editor set to LF. When you generate files from Python, open
  them with `newline='\n'`.
- Run the check after every change, from the repository root:

```sh
sh tools/check-kritikus.sh
```

It checks the boot-critical files (menus, ZFSBootMenu, installer, DOM writers, boot
guard, overlays, post-install scripts) for CR, BOM, non-ASCII or control bytes, a
missing final newline, and `sh -n` syntax errors. It runs `grub-script-check` on the
menus when that tool is installed. It prints `OK: ...` or lists every problem and exits 1.

`syno-dom-zbm.sh write` and `syno-install.sh finalize` refuse a menu with a CR as well.
