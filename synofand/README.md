# synofand

Fan and button daemon for a Synology DS220+ running plain Debian instead of DSM.

On the DS220+ the case fan is not a hwmon PWM device. It is driven by a PIC
microcontroller on the Gemini Lake LPSS UART at PCI `00:18.0` (9600 8N1) that
takes short ASCII commands. DSM calls this port `ttyS1`; mainline Linux usually
names it `ttyS4` or later, so the daemon finds it by PCI address. DSM
sets it through `scemd`. Without DSM nothing sets it, and `fancontrol` cannot
reach it. This daemon does the job instead:

- reads CPU (`coretemp`) and disk (`drivetemp`) temperatures from hwmon,
- applies the same step curve DSM uses on this model (from its `scemd.xml`),
  with hysteresis, and sends `V00`..`V99` to the microcontroller,
- powers the box off cleanly when a disk reaches 61 °C or the CPU 90 °C
  (two consecutive readings),
- logs button and fan-failure events coming from the microcontroller (the power
  button can shut the box down cleanly),
- measures the fan speed on GPIO 39 and drives the front LEDs.

Status: runs on real DS220+ units (fan curve, tachometer on GPIO 39, front LEDs,
power button). Unit tests and a pseudo-terminal test pass. Details and measurements:
[../docs/fan-and-leds.md](../docs/fan-and-leds.md).

## Safety

- Only allowlisted commands reach the serial port. `1` (immediate power off) and
  `C` (reset) are refused unconditionally, also from the config file and from
  `--send`.
- At start, on exit, on SIGTERM, on any exception and when a sensor is missing
  the fan goes to 99%. The systemd unit sends `V99` again in `ExecStopPost`.
- The daemon must be the only process that opens the microcontroller UART. Make sure there
  is no getty or `console=` on it.

## Install

```sh
apt install python3            # 3.11+ for the TOML config
install -m 755 synofand.py /usr/local/sbin/synofand.py
install -m 644 synofand.toml.example /etc/synofand.toml
install -m 644 synofand.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now synofand
```

Try it first without starting the service:

```sh
modprobe -a drivetemp coretemp
python3 synofand.py --once          # print the command it would send
python3 synofand.py --send V50      # send one command and exit
```

## Tests

```sh
python3 -m unittest discover -s tests -v
```

## Open questions (measure on the unit)

- What does the fan do at power on and after the daemon stops, with no command?
- Is the `-` prefix DSM uses needed, or do plain commands work?
- Does `U` (fan RPS report in the Synology SDK header) return a speed? (Nothing came
  back on the DS220+; the speed comes from GPIO 39 instead.)
- Encoding of the `W` (PWM frequency) command. DSM uses 10 Hz on this model.
- Meaning of `threshold="6"` in `scemd.xml` (hysteresis?).
