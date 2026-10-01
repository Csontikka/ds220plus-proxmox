# DS220+ hardware: GPIO, microcontroller, UARTs, boot

Everything here applies to the DS220+ (Intel Celeron J4025, Gemini Lake). Values marked
"measured" were checked on real units under DSM and under Debian 13 / Proxmox. The rest
comes from the sources listed at the end.

## GPIO numbering

- In the Synology GPL kernel (4.4, `drivers/gpio/gpiolib.c`) Synology pin N is sysfs GPIO
  `432+N`. That is the `INT3453:00` controller (432 to 511, 80 pads), so **N is the
  offset on `INT3453:00`**. Synology pins 80 to 159 are on the second chip.
- The numbers 964/965/973/974 seen in forums come from a kernel with a 1024 base:
  944+20/21/29/30.
- **Under Debian the base is dynamic.** Use libgpiod with the chip label and the offset,
  and check the label with `gpioinfo` first.

## Pins

Source: Solder Hazard (DSM 7.2 `model.dtb` and the synobios table). The last column is
the pad configuration on `INT3453:00` measured under DSM.

| Function | Pin (offset) | Direction | Measured under DSM |
|---|---|---|---|
| Disk power, bay 1 | 20 | output | 0x44000201, high |
| Disk power, bay 2 | 21 | output | 0x44000201, high |
| Disk present, bay 1 / 2 | 35 / 36 | input, 0 = disk present | |
| USB VBUS | 29 / 30 | output | 0x44000201, high |
| Disk LED gate | 17 | output | 0x44000201, high |
| Copy ("C") button | 22 | input, active low | 0x40000102 |
| Fan fail / tachometer | 39 | input | |
| PHY LED gate | 150 (second chip `INT3453:01`, offset 70) | output | |

- DSM powers the disks one after the other (`syno_hdd_powerup_seq` in the DS920+ DTS).
  With two disks this matters less, but the scripts here do the same: bay 1, 5 s, bay 2.

## Measured under Debian (Debian 13 kernel 6.12 and the Proxmox kernel)

| What | Result |
|---|---|
| Serial header | **J5** (bent 2x3 pins, next to the buttons): 1 = 3.3 V, **2 = GND, 4 = TX (the NAS sends), 6 = RX**, 3.3 V TTL, 115200 8N1. Do not connect VCC. The screw is not a good ground. Photos and wiring: [install-serial-console.md](install-serial-console.md#connecting-the-serial-console). |
| LPSS UARTs, Debian kernel | `ttyS0` = 0xA1215000 (PCI 00:18.0, **microcontroller**), `ttyS1` = 0xA1217000 (00:18.2, **console**). DSM numbers them the other way round. |
| LPSS UARTs, Proxmox kernel | `ttyS4` = 0xA1215000 (microcontroller), `ttyS5` = 0xA1217000 (console). So `console=ttyS5,115200n8` there. The udev rule in the overlay creates `/dev/ttyMICROP` and `/dev/ttyCONSOLE` by MMIO address on both kernels. |
| GPIO controllers | `INT3453:00` = gpiochip0 (80 lines), `:01` (80), `:02` (20), `:03` (35); `pinctrl_geminilake` |
| USB power (29/30) | `gpioset -c gpiochip0 29=1 30=1`. Without it the external USB ports get no power. |
| Disk power (20/21) | `gpioset` 20=1, a few seconds later 21=1, then a SCSI host rescan: both disks appear (SATA 6 Gb/s). |
| Disk present (35/36) | `inactive` when a disk is in the bay. |
| GPIO 39 | toggles while the fan turns, stays high when it stops (fan tachometer, see [fan-and-leds.md](fan-and-leds.md)). |
| Network | 2x RTL8168h (10ec:8168 rev 15). Mainline `r8169` with `rtl_nic/rtl8168h-2.fw` works. DSM uses Realtek's own `r8168`. |
| MAC addresses | Under Linux the NICs show the Realtek default (00:e0:4c:68:00:0x). The factory MACs are in the DOM `vender` file; the Synology GRUB command `vender /vender -s` passes them as `macs=` on the kernel command line. |
| Watchdog | No iTCO. The ACPI WDAT (`wdat_wdt`) is the real one; the reset comes some time after the set timeout (about 25 s later with a 60 s timeout). |
| Temperatures | `coretemp` (CPU) and `drivetemp` (disks) both work. |
| Boot time | about 37 s to a Debian login (firmware 4, GRUB 4, kernel 8, userspace 21). With ZFSBootMenu about 65 s to the kexec. |
| USB ports | front `usb 1-1`, rear `usb 1-2`, internal DOM `usb 1-4` (xHCI). A USB stick left in does not stop the boot. |

## Front microcontroller (PIC16F18345), 9600 8N1

It sits on the LPSS UART at PCI 00:18.0 (DSM: `ttyS1`, kernel option
`syno_ttyS1=pciserial,0x0:0x18.0x0`). It is not the legacy 0x2F8 port some older posts
mention. No getty and no `console=` may use it.

- **Fan:** `V00` to `V99`. Measured duty: V10 about 8%, V50 about 46%, V90 about 84%.
  `V00` stops the fan completely. `W` plus two digits sets the PWM frequency (DSM uses
  10 Hz on this model; the encoding is not verified).
- DSM's own table (`gDS220pSpeedMapping`) maps levels 1 to 9 to 0/15/20/25/35/45/55/65/99%.
- **LEDs and other commands:** see [fan-and-leds.md](fan-and-leds.md).
- **Dangerous:** `1` (0x31) = **immediate power off**, `C` (0x43) = **reset**, `p` = remote
  power off. Never send them by accident. `synofand` and `syno-microp` refuse them.
- Under Debian the microcontroller sends nothing on its own while idle. Button events
  come when a button is held (see [fan-and-leds.md](fan-and-leds.md)).
- **Power button held about 10 s:** the microcontroller cuts the power in hardware,
  independent of the OS. This is the emergency off.
- The `synology-microp` kernel driver (Rust, v18, 2026-07) is not merged, handles LEDs
  only, and does not list the DS220+.

## Boot

- The Synology GRUB is on the internal USB DOM. See [boot-chain.md](boot-chain.md).
- Serial console: 115200 8N1 on the J5 header. In GRUB, Ctrl-C within 3 seconds stops
  the countdown.
- Reported for the DS718+ (not tried on the DS220+): the firmware boots
  `/EFI/BOOT/SynoBootLoader.efi` from a USB stick (a renamed `grubx64.efi`), and ESC on
  the serial console shows the Insyde boot manager. The DOM route used here does not
  depend on it.
- Avoid modifying the BIOS with H2OUVE (it bricked a DS216+II), and coreboot does not
  support Gemini Lake.

## BIOS backup

- flashrom supports Gemini Lake since v1.3. From Debian:
  `flashrom -p internal --ifd -i bios -r bios.bin`. The BIOS region is usually readable,
  the TXE region is not.
- For a full backup: the flash is a 16 MB Winbond W25Q128 at **1.8 V**. Use a clip
  programmer with a 1.8 V adapter. Most CH341A programmers put 5 V on the data lines and
  can destroy a 1.8 V chip.
- On a DS420+ the chip (`W25Q128JWSIQ`, SOIC-8) was read in circuit with the box
  unplugged, WP (3) and HOLD (7) not connected, and at least two reads compared. Check
  the package on your DS220+ board before you try.
- The DSM `.pat` only contains the BIOS region (`bios.ROM` and H2OFFT).

## Other notes

- Disk spin-down under Debian is set with `hdparm`.
- `drivetemp` can reset the spin-down timer on some disks.

## Sources

- https://www.solderhazard.com/synology-ds220-repair/
- https://github.com/teasiu/linux-4.4.x (`drivers/gpio/gpiolib.c`, `kernel/syno_gpio.c`, `include/linux/syno_gpio.h`)
- https://github.com/mybbsky2012/pocopico-tinycore-redpill/blob/main/ds920p.dts
- https://github.com/torvalds/linux/blob/master/drivers/pinctrl/intel/pinctrl-geminilake.c
- https://ratatoskr.run/platform-driver-x86/2026/07/17316258/t (synology-microp)
- https://www.synoforum.com/threads/linux-on-ds220.8285/
- https://forum.doozan.com/read.php?2,123734 (DS718+ Debian)
