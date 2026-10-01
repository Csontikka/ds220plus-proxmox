# Lessons learned

Pitfalls found while building and installing this on real DS220+ units. Most of them
cost a boot, a lockout or an evening.

## The Synology GRUB

- **Only `if search --file` works as a condition.** The factory GRUB (2.02~beta3) has no
  `test` / `[`, no `source`, no `configfile`, no `load_env` / `save_env`. `ls` fails on
  files. The usual grubenv one-shot boot is impossible; flag files found with
  `search --no-floppy --file` are the only switch. See [boot-chain.md](boot-chain.md).
- **The serial menu editor drops characters.** Use the GRUB command line (`c`) and type
  slowly (`serial-watch.py` has a slow typing mode: lines starting with `~`).
- **No `earlycon` with `keep_bootcon` on the console UART.** The kernel hangs when the
  `dw-apb-uart` driver takes the port over, and the WDAT resets the box minutes later.

## DSM

- **DSM will not mount `/dev/synoboot1`.** `mount /dev/synoboot1 ...` fails with "wrong fs
  type": the DSM kernel reserves the `/dev/synoboot*` paths for its own processes. The
  relative path works: `cd /dev && mount ./synoboot1 /mnt` (also for `blkid`,
  `blockdev` and `dd`).
- **The DOM model string differs between units:** "DiskStation" on one, "Diskstation" on
  another. An exact match silently disabled the boot guard on the second box. Match it
  case-insensitively.

## ZFSBootMenu

- **No coreutils.** `sha256sum`, `sync`, `cut`, `du` and more are missing. Use
  `busybox <applet>`; the hooks and scripts define shell functions that call busybox.
- **No `zgenhostid`.** `syno-install.sh finish` writes the hostid file bytes itself (or
  copies ZFSBootMenu's `/etc/hostid`).
- **No VLAN support** in the hook. The management network ZFSBootMenu uses must be
  untagged (native VLAN) on the switch port, or the rescue system is unreachable.
- **The hostid must be built in.** ZFSBootMenu 3.1 only adopts the pool owner's hostid
  for ONLINE pools. With a disk missing (DEGRADED) the import failed. See
  [rescue.md](rescue.md).
- **The hardware clock can be years off** after DSM. `tar` warns but works; time sync
  fixes it after the first boot.
- **One-shot flags must be removed first.** The hook removes `zbm-menu` before disks,
  network or SSH, so a later hang plus a power cycle leads back to DSM.
- **Secure Boot and kexec:** without `efi=noruntime` the kernel IMA policy refuses to
  kexec the Proxmox-signed kernel.

## Line endings and shells

- **A single CR breaks the boot.** One CRLF in a GRUB menu or an initramfs script is
  enough, and without a console you see nothing. Keep LF everywhere, run
  `sh tools/check-kritikus.sh` after every change.
- **`pkill -f` / `pgrep -f` match your own shell.** A pattern given in an
  `ssh host '...'` or `pct exec` command line also matches that shell's command line,
  so it kills the session that runs it. Stop helpers by PID or systemd unit.
- **Backslashes get lost in heredocs through ssh.** Several quoting layers eat them. Write
  the script to a file, copy it over, run it there.
- **Do not chain irreversible steps in a pipeline.** `finish | tail` returns the exit code
  of `tail`, so a failed `finish` did not stop the next step. Run one step per command
  and read its output.
- **Long jobs over ssh:** run them with `nohup` and watch the log for an end marker.

## Networking

- **The bond gets a random MAC.** With `vmbr0` on DHCP, the bond and the bridge came up
  with a generated MAC, so a DHCP reservation for the factory MAC never matched.
  `first-boot.sh` pins `hwaddress` (the LAN1 factory MAC) on `bond0` and `vmbr0`.
- **Send no DHCP client-id** from ZFSBootMenu (`udhcpc -C`), like the installed system's
  dhclient, so the DHCP server sees one client (the MAC).
- **Switch ports may block for 30 to 50 s after link up.** The fixed address fallback in
  ZFSBootMenu waits about 60 s for the gateway before it also starts DHCP.
- **When you look a box up by name,** read the answer line of the lookup output, not the
  line that names the DNS server.

## Building

- **`mmdebstrap` tarball output loses owners.** It writes every entry as 0/0, even as
  real root, and in an unprivileged container it loses all non-root owners anyway. Build
  into a directory as real root and pack with GNU tar; check a few owners
  (`/etc/shadow` must be `root:shadow`).
- **Resolve owner names in the new system's passwd and group,** not the build host's: the
  same gid can have another name there.

## Hardware

- **The microcontroller port is not `ttyS1` under Linux.** It is the LPSS UART at
  0xA1215000 (`ttyS0` on the Debian kernel, `ttyS4` on the Proxmox kernel). Go by MMIO
  address (the udev rule creates `/dev/ttyMICROP`), never by `ttySn`.
- **Never send `1` or `C` to the microcontroller** (power off, reset). Use `printf`, not
  `echo`: the line end is a command byte too.
- **The LAN LEDs need a gate** (gpiochip1 line 70) and the disk LEDs another one
  (gpiochip0 line 17). DSM sets both high.
