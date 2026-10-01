# Fan, LEDs and buttons (synofand)

Under DSM the `scemd` daemon runs the fan, the front LEDs and the buttons. Without DSM
nothing does: the fan is not a hwmon PWM device, so `fancontrol`, `fan2go` and similar
tools cannot reach it. `synofand/synofand.py` does this job. It is installed and enabled
by `tools/pve/build-rootfs.sh` (config `/etc/synofand.toml`, from
`synofand/synofand.toml.example`).

## Existing projects

None of them runs the DS220+ fan without DSM:

| Project | Why not |
|---|---|
| `synology-microp` Rust kernel driver (v18, 2026-07, not merged) | LEDs only; fan, buttons and power off are only planned; no DS220+ |
| Substratec/Syno_fan_control | needs DSM (web API) |
| NyaMisty/scemd_fanspeed_hook | XPEnology, IT87xx Super I/O |
| RedPill `pmu_shim.c`, `dsm-research` | the best command reference, no fan control |
| fan2go (`cmd` fan type) | cannot handle the incoming events, and only one process may open the port |
| hddfancontrol | sysfs PWM only |

So: one small daemon that is the only process with the microcontroller port open, and
handles fan, buttons, LEDs and failures.

## Microcontroller protocol

LPSS UART at PCI 00:18.0 (MMIO 0xA1215000), 9600 8N1, raw, no flow control. udev names it
`/dev/ttyMICROP`; synofand can also find it by PCI address. No prefix needed (DSM sends a
leading `-`, plain commands work too). Always use `printf`, never `echo`: the line end
would be sent as a command.

```
stty -F /dev/ttyMICROP 9600 cs8 -cstopb -parenb -crtscts -ixon raw -echo
printf V50 > /dev/ttyMICROP
```

Outgoing (from the Synology SDK header `hwctl/external.h`, the RedPill shim and tests on
the DS220+):

| Command | Meaning |
|---|---|
| `V00` .. `V99` | fan duty (`V00` stops the fan) |
| `W..` | PWM frequency (DSM uses 10 Hz here; encoding not verified) |
| `4` `5` `6` | power LED on / blink / off |
| `7` `8` `9` `:` `;` | status LED off / green / green blink / orange / orange blink |
| `=` | status LED breathing |
| `@` `A` `B` | copy ("C") LED on / blink / off |
| `2` `3` | short / long beep |
| `u` `t` | fan check on / off (then `f` comes on a fan failure) |
| `U` | fan speed report toggle (returned nothing on the DS220+) |

**Forbidden:** `1` immediate hard power off, `C` reset, `p` remote power off. Avoid `0`,
`O`, `q`, `r`, `s`, `W`, `t` unless you know what they do. synofand refuses `1` and `C`
unconditionally and only sends allowlisted commands; `syno-microp` (in ZFSBootMenu) allows
only LED commands and `Vnn`.

Incoming: `0` = power button held about 3 s, `a` = RESET held until the first beep,
`` ` `` = USB copy (per the SDK), `f` / `g` = fan failures. Short presses send nothing.
Holding Power about 10 s makes the microcontroller cut the power in hardware.

## Fan curve

DSM's DS220+ `scemd.xml` uses the DUAL_MODE_HIGH ("cool") profile, measured every 20 s:

| Disk (°C) | 0 | 41 | 46 | 50 | 53 | 61 |
|---|---|---|---|---|---|---|
| Duty | 20% | 30% | 50% | 70% | 99% | 99% + **power off** |

| CPU (°C) | 0 | 60 | 70 | 90 |
|---|---|---|---|---|
| Duty | 20% | 70% | 99% | 99% + **power off** |

The quieter DUAL_MODE_LOW profile: disk 0/46/52/55/58 °C to 20/30/50/70/99%, CPU
0/65/75 °C to 20/70/99%, same power off limits. Both are in the example config.

What synofand does:

1. At start, on exit, on SIGTERM, on any exception and when a sensor is missing: the
   failsafe duty (`V99`). The systemd unit sends `V99` again in `ExecStopPost`.
2. Every 20 s: CPU (`coretemp`) and disk (`drivetemp`) temperatures from hwmon, the step
   curve with 3 °C hysteresis; the higher of the two curves wins.
3. **Thermal power off:** when a disk reaches 61 °C or the CPU 90 °C in two consecutive
   readings (`shutdown_confirmations`), it logs a critical message, sets the failsafe duty
   and runs `systemctl poweroff`.
4. Power button (`0`): `power_action = "poweroff"` in the example config shuts down
   cleanly (guests included); `"log"` only logs it (the built-in default). RESET is only
   logged.
5. Copy ("C") button: gpiochip0 line 22, active low; a press is logged with its length,
   `copy_command` is optional.

Try it by hand first: `python3 synofand.py --once` prints the command it would send,
`--send V50` sends one command. Unit tests: `python3 -m unittest discover -s tests -v`.

## Fan tachometer (GPIO 39)

Line 39 of gpiochip0 (`INT3453:00`) toggles while the fan turns and stays high when it
stops. The tach signal reaches it through the CPLD (Solder Hazard). DSM only uses it as
"fan fail", but counting edges gives the speed. Measured with
`tools/pve/tacho-measure.py` (rising edges with `gpiomon`, 4 s window, median period,
2 pulses per revolution assumed):

| Duty | median frequency | rpm | glitches (period under half the median) |
|---|---|---|---|
| V00 | 0 edges | stopped | |
| V10 | 55.5 Hz | (1665) | 120 |
| V20 | 67.1 Hz | (2014) | 73 |
| V35 | 38.4 Hz | (1152) | 28 |
| V50 | 44.4 Hz | **1333** | 0 |
| V70 | 50.9 Hz | **1526** | 0 |
| V99 | 56.1 Hz | **1684** | 0 |

Below V50 the low-frequency PWM chops the supply of the 3-wire fan, which adds glitches
to the tach signal. From V50 up the value is clean and monotonic. The 2 pulses per
revolution were not checked with a strobe. `tools/pve/gpio39-probe.py` is the simpler
first probe (samples the line at a few duties). Run both with synofand stopped.

synofand (`[gpio]`): collects edges for 2 s every period, computes the rpm above
`min_duty` (50), and logs "fan stopped or unplugged" when the duty is above 0 and no edge
comes. It writes `duty`, `rpm`, `fan_stopped` and `edges` to `/run/synofand/status.json`.
Needs `python3-libgpiod`.

## LEDs: what drives what

| LED | Driven by | Control |
|---|---|---|
| Power (blue) | microcontroller | `4` on, `5` blink, `6` off. It blinks by itself from power on until `4` comes. |
| STATUS (green/orange) | microcontroller | `7` off, `8` green, `9` green blink, `:` orange, `;` orange blink, `=` breathing |
| C (copy, green) | microcontroller | `@` on, `A` blink, `B` off |
| DISK1 green / orange | **LP3943** LED dimmer at I2C 0x60 on the SMBus I801, outputs LED0 / LED1 = LS0 (reg 0x06) bits 1:0 / 3:2 | gate: gpiochip0 line 17 = 1 |
| DISK2 green / orange | LP3943 LED2 / LED3 = LS0 bits 5:4 / 7:6 | same gate. LS values: 00 off, 01 on, 10 PWM0, 11 PWM1. LED4 to LED15 are unused. |
| LAN1 / LAN2 (front) | the RTL8168h PHY through the CPLD | r8169 LED class (`enp1s0-*::lan`, `enp2s0-*::lan`), `netdev` trigger with hardware offload. **Gate: gpiochip1 (`INT3453:01`) line 70 = 1** (DSM pin 150, `phy_led_ctrl`); without it the LAN LEDs stay dark. |
| Brightness (all front LEDs) | **TPL0401A** digital potentiometer, I2C 0x2E reg 0, on the LP3943's bus | 0x40 brightest .. 0x7D off (DSM `led_brightness.xml`) |

- The I2C bus number of the SMBus changes between boots (`i2c-0` or `i2c-1`). synofand
  finds it from the ACPI device `LED3943:00`.
- The disk LEDs have no hardware activity path: the CPLD has no SATA activity signal and
  DSM blinks them in software. synofand can do the same from `/proc/diskstats`
  (`disk_activity = true`, about 1.5% CPU); off by default.
- **DISK1 is the left bay = `ata2`, DISK2 the right bay = `ata1`** (measured by pulling
  disks).
- Do not write unknown I2C addresses. On the LP3943 only touch the LS and PWM registers.
  Do not switch GPIO 20/21 (disk power) or 29/30 (USB power) while running.

## What synofand shows (`[leds]`)

| LED | Behaviour |
|---|---|
| Power | steady blue while the daemon runs (the microcontroller blinks it until then), blinks on shutdown |
| STATUS | green blink: booting; **green**: `systemctl is-system-running` is running or degraded and all is well; **orange**: degraded pool, hot disk (53 °C or more) or CPU (75 °C or more); **orange blink**: fan stopped or faulted pool. Updated every 20 s. |
| DISK1 / DISK2 | green: disk present and ONLINE (or not in a pool); orange: disk not ONLINE; dark: empty bay |
| LAN1 / LAN2 | driven by the NIC (link and traffic); synofand sets the gate |
| C | off (`B` at start) |
| Brightness | left alone (`brightness = -1`) |

In ZFSBootMenu `syno-microp` sets the LEDs: C steady and status green blink while the
hook runs; C blinking while the menu waits (status orange blink when the boot guard
stopped there or no pool was found); power blink, status green blink and C steady right
before kexec. The fan runs at a fixed `V50` there.

What you see (measured):

| Stage | Power | STATUS | DISK1/2 | Fan |
|---|---|---|---|---|
| Power button 3 s, shutdown (about 25 s) | blink | green | off | 99% |
| off | off | off | off | stopped |
| power on, BIOS, GRUB, ZFSBootMenu (about 65 s) | blink | off or last state | off | 50% in ZFSBootMenu |
| synofand starts | blue | green blink | green | per curve |
| system ready (15 to 40 s later) | blue | green | green | per curve |
| Power held about 10 s | the microcontroller cuts the power | | | |

Test: pulling the left disk turned DISK1 off and STATUS orange within 20 s; after putting
it back and the resilver, both went green again.

## Open questions

- What the microcontroller does at power on and after the daemon stops, with no command.
- The encoding of `W`, and the replies to `R` (0x52) and `O` (0x4F).
- The meaning of `threshold="6"` in `scemd.xml` (hysteresis?).

## Sources

- https://www.solderhazard.com/synology-ds220-repair/
- https://github.com/slowfranklin/synology-ds (`hwctl/external.h`)
- https://github.com/RedPill-TTG/redpill-lkm/blob/master/shim/pmu_shim.c
- https://github.com/RedPill-TTG/dsm-research/blob/master/quirks/pmu.md
- https://ratatoskr.run/platform-driver-x86/2026/07/17316258/t (synology-microp v18)
- https://smallhacks.wordpress.com/2012/04/17/working-with-synology-hardware-devsynobios-and-devttys1/
- https://kb.synology.com/en-us/DSM/tutorial/Overview_of_LED_indicator_statuses_during_bootup
- https://docs.kernel.org/hwmon/drivetemp.html
