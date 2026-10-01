#!/usr/bin/env python3
"""synofand: fan, button and LED daemon for the Synology DS220+ running plain Debian.

On the DS220+ the fan is driven by a PIC microcontroller on the Gemini Lake LPSS
UART at PCI 00:18.0 (DSM calls it ttyS1; mainline Linux usually names it ttyS4 or
later), 9600 8N1.
DSM talks to it through scemd; without DSM nobody sets the fan, so this daemon
reads the CPU and disk temperatures from hwmon and sends the duty cycle itself,
following the curve DSM uses on this model.

Safety rules:
  * Only allowlisted commands ever reach the microcontroller. '1' powers the box
    off immediately and 'C' resets it, so both are refused unconditionally.
  * On any fault (no temperature, exception, SIGTERM, exit) the fan goes to the
    failsafe duty (99% by default).
"""

import argparse
import errno
import glob
import json
import logging
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None

try:
    import termios
except ImportError:  # not on Linux; unit tests still run
    termios = None

try:
    import fcntl
except ImportError:  # not on Linux; unit tests still run
    fcntl = None

log = logging.getLogger("synofand")

# --------------------------------------------------------------------------
# Microcontroller commands
# --------------------------------------------------------------------------

FORBIDDEN = {"1", "C"}  # immediate power off, reset

# Single-byte commands known from the Synology SDK header (hwctl/external.h)
# and from tests on the DS220+.
SINGLE_ALLOWED = {
    "2", "3",                      # buzzer short / long
    "4", "5", "6",                 # power LED on / blink / off
    "7", "8", "9", ":", ";",       # status LED states
    "=",                           # status LED breathing
    "@", "A", "B",                 # USB copy LED on / blink / off
    "U",                           # toggle fan RPS report (untested)
    "u", "t",                      # fan check on / off
}
_MULTI_ALLOWED = re.compile(r"^(V[0-9]{2}|W[0-9]{2}|EC[01])$")


class ForbiddenCommand(ValueError):
    pass


def check_command(cmd):
    """Return cmd if it is safe to send, raise ForbiddenCommand otherwise."""
    if not isinstance(cmd, str) or not cmd:
        raise ForbiddenCommand(f"empty or non-string command: {cmd!r}")
    if cmd in FORBIDDEN:
        raise ForbiddenCommand(f"command {cmd!r} is on the forbidden list")
    if cmd in SINGLE_ALLOWED or _MULTI_ALLOWED.match(cmd):
        return cmd
    raise ForbiddenCommand(f"command {cmd!r} is not allowlisted")


def duty_command(duty):
    duty = max(0, min(99, int(round(duty))))
    return f"V{duty:02d}"


def duty_of(cmd):
    """Duty in percent from a "Vnn" command, or None."""
    if cmd and len(cmd) == 3 and cmd[0] == "V" and cmd[1:].isdigit():
        return int(cmd[1:])
    return None


class Microp:
    """The microcontroller on the serial port. Owns the port exclusively."""

    def __init__(self, port, prefix="", dry_run=False):
        self.port = port
        self.prefix = prefix
        self.dry_run = dry_run
        self.fd = None
        self.last_sent = None

    def open(self):
        if self.dry_run:
            return
        if termios is None:
            raise RuntimeError("termios is not available on this platform")
        self.fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(self.fd)
        iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = attrs
        iflag = 0
        oflag = 0
        lflag = 0
        cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 0
        speed = termios.B9600
        termios.tcsetattr(self.fd, termios.TCSANOW,
                          [iflag, oflag, cflag, lflag, speed, speed, cc])
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def send(self, cmd):
        check_command(cmd)
        data = (self.prefix + cmd).encode("ascii")
        if self.dry_run:
            log.info("dry-run: would send %r", data)
        else:
            os.write(self.fd, data)
        self.last_sent = cmd

    def read_events(self, timeout):
        """Wait up to timeout seconds and return the bytes that came in."""
        if self.dry_run or self.fd is None:
            time.sleep(max(0.0, timeout))
            return b""
        ready, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
        if not ready:
            return b""
        try:
            return os.read(self.fd, 256)
        except OSError as exc:
            if exc.errno == errno.EAGAIN:
                return b""
            raise


# --------------------------------------------------------------------------
# Temperatures
# --------------------------------------------------------------------------

def _read_millideg(path):
    try:
        with open(path) as f:
            return int(f.read().strip()) / 1000.0
    except (OSError, ValueError):
        return None


def hwmon_temps(name, root="/sys/class/hwmon"):
    """All temp*_input values (°C) of every hwmon device called `name`."""
    temps = []
    for dev in sorted(glob.glob(os.path.join(root, "hwmon*"))):
        try:
            with open(os.path.join(dev, "name")) as f:
                if f.read().strip() != name:
                    continue
        except OSError:
            continue
        for inp in sorted(glob.glob(os.path.join(dev, "temp*_input"))):
            t = _read_millideg(inp)
            if t is not None:
                temps.append(t)
    return temps


def max_temp(name, root="/sys/class/hwmon"):
    temps = hwmon_temps(name, root)
    return max(temps) if temps else None


# --------------------------------------------------------------------------
# Fan curve
# --------------------------------------------------------------------------

class Curve:
    """Step curve like DSM's scemd.xml: [(temp_from, duty), ...], with hysteresis.

    The level goes up as soon as the temperature reaches a step. It only goes
    down when the temperature has fallen `hysteresis` degrees below the step
    that raised it, so the fan does not flap around a threshold.
    """

    def __init__(self, points, shutdown, hysteresis):
        self.points = sorted((float(t), int(d)) for t, d in points)
        if not self.points or self.points[0][0] > 0:
            raise ValueError("curve must start at 0 °C")
        self.shutdown = float(shutdown)
        self.hysteresis = float(hysteresis)
        self.level = 0

    def _raw_level(self, temp):
        level = 0
        for i, (t, _d) in enumerate(self.points):
            if temp >= t:
                level = i
        return level

    def update(self, temp):
        raw = self._raw_level(temp)
        if raw > self.level:
            self.level = raw
        else:
            while self.level > raw and temp < self.points[self.level][0] - self.hysteresis:
                self.level -= 1
        return self.points[self.level][1]


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

DEFAULTS = {
    # port wins if set; otherwise the tty of the PCI UART is looked up.
    "serial": {"port": "", "pci": "0000:00:18.0", "prefix": ""},
    "fan": {
        "period": 20,
        "hysteresis": 3,
        "failsafe_duty": 99,
        "frequency_cmd": "",
        "shutdown_confirmations": 2,
    },
    # DSM "DUAL_MODE_HIGH" (cool) profile of the DS220+, from its scemd.xml.
    "disk": {"points": [[0, 20], [41, 30], [46, 50], [50, 70], [53, 99]], "shutdown": 61},
    "cpu": {"points": [[0, 20], [60, 70], [70, 99]], "shutdown": 90},
    "buttons": {"power_byte": "0", "power_action": "log",
                # front "C" (USB copy) button: a GPIO line, not the microcontroller
                "copy_enabled": False, "copy_chip_label": "INT3453:00", "copy_offset": 22,
                "copy_min_press": 0.1, "copy_command": ""},
    "gpio": {"fan_fail_enabled": False, "chip_label": "INT3453:00", "fan_fail_offset": 39,
             "pulses_per_rev": 2, "window": 2.0, "min_duty": 50,
             "status_file": "/run/synofand/status.json"},
    # Front LEDs (DS220+, measured 2026-09-25). Power, status and copy are microcontroller
    # bytes; the disk LEDs are an LP3943 on SMBus; the LAN LEDs are the NIC LEDs behind a
    # CPLD gate. DSM leaves two gate lines high: without them the disk and LAN LEDs stay dark.
    "leds": {"enabled": False,
             "disk_gate_chip": "INT3453:00", "disk_gate_offset": 17,
             "lan_gate_chip": "INT3453:01", "lan_gate_offset": 70,
             # the I2C bus numbers change between boots: "auto" finds the bus of the
             # LP3943 by its ACPI device (LED3943:00); a number forces a bus
             "lp3943_bus": "auto", "lp3943_acpi": "LED3943:00", "lp3943_addr": 0x60,
             # one entry per bay: ATA port, LP3943 output of the green and the orange LED
             # DISK1 (left bay) is on ata2, DISK2 (right bay) on ata1 (measured)
             "bays": [{"ata": "ata2", "green": 0, "orange": 1},
                      {"ata": "ata1", "green": 2, "orange": 3}],
             "disk_activity": False, "activity_interval": 0.15,
             "lan": ["enp1s0", "enp2s0"],
             "copy_led": "off",          # "off" or "on"
             "brightness": -1,           # TPL0401A wiper (0x40 brightest, 0x7d off); -1 = leave
             "brightness_bus": "auto", "brightness_addr": 0x2E,   # auto: the LP3943's bus
             "warn_disk_temp": 53, "warn_cpu_temp": 75},
}


def find_pci_tty(pci, root="/sys/bus/pci/devices"):
    """Return /dev/ttySx of the serial port on PCI device `pci`, or None."""
    base = os.path.join(root, pci)
    hits = sorted(glob.glob(os.path.join(base, "**", "tty", "tty*"), recursive=True))
    return "/dev/" + os.path.basename(hits[0]) if hits else None


def resolve_port(serial_cfg, pci_root="/sys/bus/pci/devices"):
    if serial_cfg.get("port"):
        return serial_cfg["port"]
    pci = serial_cfg.get("pci")
    port = find_pci_tty(pci, pci_root) if pci else None
    if not port:
        raise RuntimeError(f"no serial port configured and no tty found on PCI {pci!r}")
    return port


def load_config(path):
    cfg = {k: dict(v) for k, v in DEFAULTS.items()}
    if path:
        if tomllib is None:
            raise RuntimeError("reading a config file needs Python 3.11+ (tomllib)")
        with open(path, "rb") as f:
            user = tomllib.load(f)
        for section, values in user.items():
            cfg.setdefault(section, {}).update(values)
    check_command(duty_command(cfg["fan"]["failsafe_duty"]))
    if cfg["fan"]["frequency_cmd"]:
        check_command(cfg["fan"]["frequency_cmd"])
    return cfg


# --------------------------------------------------------------------------
# Fan-fail GPIO (optional, needs python3-libgpiod 2.x)
# --------------------------------------------------------------------------

class FanFailGpio:
    """Fan tachometer on a GPIO line (DS220+: gpiochip0 / INT3453:00 line 39).

    The line toggles while the fan turns and sits still when it stops. At low
    duty the low-frequency PWM chops the fan supply and adds glitch edges, so
    the rpm is only reported from ``min_duty`` up (clean from V50 on the tested DS220+).
    """

    def __init__(self, chip_label, offset, pulses_per_rev=2):
        import gpiod  # noqa: F401  (optional dependency)
        self.gpiod = gpiod
        self.offset = offset
        self.ppr = pulses_per_rev
        self.request = None
        for path in sorted(glob.glob("/dev/gpiochip*")):
            with gpiod.Chip(path) as chip:
                if chip.get_info().label == chip_label:
                    self.request = gpiod.request_lines(
                        path, consumer="synofand",
                        config={offset: gpiod.LineSettings(
                            direction=gpiod.line.Direction.INPUT,
                            edge_detection=gpiod.line.Edge.RISING)})
                    break
        if self.request is None:
            raise RuntimeError(f"gpio chip {chip_label!r} not found")

    def value(self):
        return int(self.request.get_value(self.offset) == self.gpiod.line.Value.ACTIVE)

    def edges(self, window):
        """Timestamps (s) of the rising edges seen during ``window`` seconds."""
        while self.request.wait_edge_events(0):      # drop what queued up before
            self.request.read_edge_events()
        stamps = []
        end = time.monotonic() + window
        while (left := end - time.monotonic()) > 0:
            if self.request.wait_edge_events(left):
                stamps.extend(e.timestamp_ns / 1e9 for e in self.request.read_edge_events())
        return stamps


def tach_rpm(stamps, pulses_per_rev=2):
    """rpm from rising-edge timestamps: the median period ignores glitch edges."""
    if len(stamps) < 3:
        return None
    periods = sorted(b - a for a, b in zip(stamps, stamps[1:]) if b > a)
    if not periods:
        return None
    med = periods[len(periods) // 2]
    return round(60.0 / (pulses_per_rev * med))


class CopyButtonGpio:
    """The front "C" (USB copy) button of the DS220+: gpiochip0 line 22, active low.

    It is not wired to the microcontroller. Edges are read without blocking; a
    press is reported on release with its length, bounces shorter than
    ``min_press`` seconds are dropped.
    """

    def __init__(self, chip_label, offset, min_press=0.1):
        import gpiod  # noqa: F401  (optional dependency)
        self.gpiod = gpiod
        self.offset = offset
        self.min_press = min_press
        self.pressed_at = None
        self.request = None
        for path in sorted(glob.glob("/dev/gpiochip*")):
            with gpiod.Chip(path) as chip:
                if chip.get_info().label == chip_label:
                    self.request = gpiod.request_lines(
                        path, consumer="synofand-copy",
                        config={offset: gpiod.LineSettings(
                            direction=gpiod.line.Direction.INPUT,
                            edge_detection=gpiod.line.Edge.BOTH)})
                    break
        if self.request is None:
            raise RuntimeError(f"gpio chip {chip_label!r} not found")

    def presses(self):
        """Lengths (s) of the presses completed since the last call."""
        done = []
        while self.request.wait_edge_events(0):
            for e in self.request.read_edge_events():
                t = e.timestamp_ns / 1e9
                if e.event_type == e.Type.FALLING_EDGE:
                    self.pressed_at = t
                elif self.pressed_at is not None:
                    length = t - self.pressed_at
                    self.pressed_at = None
                    if length >= self.min_press:
                        done.append(length)
        return done


# --------------------------------------------------------------------------
# Front LEDs
# --------------------------------------------------------------------------

I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720           # the I801 SMBus adapter only speaks SMBus, not raw I2C
I2C_SMBUS_READ, I2C_SMBUS_WRITE = 1, 0
I2C_SMBUS_BYTE_DATA = 2

# LP3943 LED selector registers: 4 LEDs each, 2 bits per LED (00 off, 01 on, 10 DIM0, 11 DIM1)
LP3943_LS0 = 0x06


def lp3943_selectors(states):
    """{output: 'on'|'off'} -> {register: value} for the four LED selector registers."""
    regs = {LP3943_LS0 + i: 0 for i in range(4)}
    for out, state in states.items():
        if state == "on":
            regs[LP3943_LS0 + out // 4] |= 0b01 << (2 * (out % 4))
    return regs


class I2CDevice:
    """One SMBus slave through /dev/i2c-N: byte-data writes and reads (like i2cset/i2cget)."""

    def __init__(self, bus, addr):
        import ctypes

        class Data(ctypes.Union):
            _fields_ = [("byte", ctypes.c_uint8), ("word", ctypes.c_uint16),
                        ("block", ctypes.c_uint8 * 34)]

        class Args(ctypes.Structure):
            _fields_ = [("read_write", ctypes.c_uint8), ("command", ctypes.c_uint8),
                        ("size", ctypes.c_uint32), ("data", ctypes.POINTER(Data))]

        self._ctypes, self._data_t, self._args_t = ctypes, Data, Args
        self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
        fcntl.ioctl(self.fd, I2C_SLAVE, addr)

    def _smbus(self, rw, reg, value=0):
        data = self._data_t()
        data.byte = value
        args = self._args_t(rw, reg, I2C_SMBUS_BYTE_DATA, self._ctypes.pointer(data))
        fcntl.ioctl(self.fd, I2C_SMBUS, args)
        return data.byte

    def write(self, reg, value):
        self._smbus(I2C_SMBUS_WRITE, reg, value)

    def read(self, reg):
        return self._smbus(I2C_SMBUS_READ, reg)

    def close(self):
        os.close(self.fd)


def i2c_bus_of(acpi_name, root="/sys/bus/i2c/devices"):
    """Bus number of an ACPI-enumerated I2C device (i2c-LED3943:00 -> .../i2c-N/...)."""
    path = os.path.realpath(os.path.join(root, f"i2c-{acpi_name}"))
    m = re.search(r"/i2c-(\d+)/i2c-", path)
    if not m:
        raise RuntimeError(f"I2C device {acpi_name!r} not found")
    return int(m.group(1))


def resolve_bus(value, acpi_name, root="/sys/bus/i2c/devices"):
    if str(value).lower() == "auto":
        return i2c_bus_of(acpi_name, root)
    return int(value)


def hold_gpio_high(chip_label, offset):
    """Drive one GPIO line high and keep it (the request lives as long as the object)."""
    import gpiod  # noqa: F401  (optional dependency)
    for path in sorted(glob.glob("/dev/gpiochip*")):
        with gpiod.Chip(path) as chip:
            if chip.get_info().label == chip_label:
                return gpiod.request_lines(
                    path, consumer="synofand-led",
                    config={offset: gpiod.LineSettings(
                        direction=gpiod.line.Direction.OUTPUT,
                        output_value=gpiod.line.Value.ACTIVE)})
    raise RuntimeError(f"gpio chip {chip_label!r} not found")


def setup_lan_leds(devices, root="/sys/class/leds"):
    """Link and activity on every LED of the given NICs, driven by the NIC itself."""
    subprocess.run(["modprobe", "ledtrig-netdev"], check=False)
    done = []
    for dev in devices:
        for led in sorted(glob.glob(os.path.join(root, f"{dev}-*::lan"))):
            try:
                with open(os.path.join(led, "trigger"), "w") as f:
                    f.write("netdev")
                with open(os.path.join(led, "device_name"), "w") as f:
                    f.write(dev)
            except OSError:
                log.exception("lan led %s: netdev trigger failed", led)
                continue
            for attr in ("link_10", "link_100", "link_1000", "rx", "tx"):
                try:  # the hardware mode of some LEDs refuses single modes
                    with open(os.path.join(led, attr), "w") as f:
                        f.write("1")
                except OSError:
                    pass
            done.append(os.path.basename(led))
    return done


def disk_of_ata(port, root="/sys/block"):
    """sdX of the disk on ATA port `port` (e.g. ata1), or None when the bay is empty."""
    for b in sorted(glob.glob(os.path.join(root, "sd*"))):
        if f"/{port}/" in os.path.realpath(b):
            return os.path.basename(b)
    return None


def zpool_disk_states(text):
    """`zpool status -LP` output -> {sdX: worst leaf state} for disk partitions."""
    rank = {"ONLINE": 0, "DEGRADED": 1, "OFFLINE": 2, "REMOVED": 2,
            "FAULTED": 3, "UNAVAIL": 3}
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].startswith("/dev/"):
            continue
        m = re.match(r"^/dev/(sd[a-z]+)\d*$", parts[0])
        if not m:
            continue
        disk, state = m.group(1), parts[1]
        if disk not in out or rank.get(state, 3) > rank.get(out[disk], 3):
            out[disk] = state
    return out


def pool_health(text):
    """`zpool list -H -o health` output -> worst pool health."""
    order = ["ONLINE", "DEGRADED", "FAULTED", "UNAVAIL", "SUSPENDED"]
    worst = "ONLINE"
    for h in text.split():
        if h in order and order.index(h) > order.index(worst):
            worst = h
    return worst


def disk_led(present, state):
    """LED of one bay: off (empty bay), green (ONLINE, or not in a pool), orange."""
    if not present:
        return "off"
    if state is None or state == "ONLINE":
        return "green"
    return "orange"


def status_led(booted, pools, fan_stopped, disk_t, cpu_t, warn_disk, warn_cpu):
    """Status LED byte: 9 green blink (booting), 8 green, ':' orange, ';' orange blink."""
    if fan_stopped or pools in ("FAULTED", "UNAVAIL", "SUSPENDED"):
        return ";"
    if pools == "DEGRADED" or (disk_t is not None and disk_t >= warn_disk) \
            or (cpu_t is not None and cpu_t >= warn_cpu):
        return ":"
    return "8" if booted else "9"


def disk_io(name, path="/proc/diskstats"):
    """Reads + writes completed by `name` so far, or None."""
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) > 7 and p[2] == name:
                    return int(p[3]) + int(p[7])
    except OSError:
        pass
    return None


class DiskLeds(threading.Thread):
    """Owns the LP3943: green/orange per bay, green blinks off for one tick on disk I/O."""

    def __init__(self, cfg, dev=None):
        super().__init__(name="disk-leds", daemon=True)
        self.cfg = cfg
        if dev is None:
            bus = resolve_bus(cfg["lp3943_bus"], cfg["lp3943_acpi"])
            log.info("disk leds: LP3943 on i2c-%d", bus)
            dev = I2CDevice(bus, int(cfg["lp3943_addr"]))
        self.dev = dev
        self.lock = threading.Lock()
        self.pool_states = {}
        self.running = True
        self.last_io = {}
        self.written = None
        self.bay_disks = {}         # ATA port -> sdX, refreshed every 2 s (glob + realpath)
        self.bays_at = 0.0

    def set_pool_states(self, states):
        with self.lock:
            self.pool_states = dict(states)

    def disks(self):
        now = time.monotonic()
        if now - self.bays_at >= 2.0:
            self.bay_disks = {b["ata"]: disk_of_ata(b["ata"]) for b in self.cfg["bays"]}
            self.bays_at = now
        return self.bay_disks

    def outputs(self, blink_off=()):
        with self.lock:
            pool_states = dict(self.pool_states)
        disks = self.disks()
        want = {}
        for bay in self.cfg["bays"]:
            disk = disks.get(bay["ata"])
            led = disk_led(disk is not None, pool_states.get(disk))
            want[int(bay["green"])] = "on" if led == "green" and disk not in blink_off else "off"
            want[int(bay["orange"])] = "on" if led == "orange" else "off"
        return want

    def apply(self, want):
        regs = lp3943_selectors(want)
        if regs != self.written:
            for reg, value in regs.items():
                self.dev.write(reg, value)
            self.written = regs

    def run(self):
        while self.running:
            busy = set()
            if self.cfg["disk_activity"]:
                disks = self.disks()
                for bay in self.cfg["bays"]:
                    disk = disks.get(bay["ata"])
                    io = disk_io(disk) if disk else None
                    if disk and io is not None and self.last_io.get(disk) not in (None, io):
                        busy.add(disk)
                    if disk:
                        self.last_io[disk] = io
            try:
                self.apply(self.outputs(busy))
            except Exception:
                log.exception("disk leds: LP3943 write failed")
                time.sleep(5)
            # without activity blinking only presence and pool state matter: once a second is enough
            time.sleep(float(self.cfg["activity_interval"]) if self.cfg["disk_activity"] else 1.0)

    def stop(self):
        self.running = False
        try:
            self.apply({int(b[k]): "off" for b in self.cfg["bays"] for k in ("green", "orange")})
        except Exception:
            pass


# --------------------------------------------------------------------------
# Daemon
# --------------------------------------------------------------------------

EVENT_NAMES = {
    ord("0"): "power button",      # held ~3 s (verified on the DS220+)
    ord("`"): "usb copy button",   # SDK: UART2_CMD_BUTTON_USB (0x60); no such button on a DS220+
    ord("a"): "reset button",      # held until the first beep (verified on the DS220+)
    ord("f"): "fan failure",
    ord("g"): "cpu fan failure",
}


class Daemon:
    def __init__(self, cfg, microp, hwmon_root="/sys/class/hwmon", poweroff_cmd=None):
        self.cfg = cfg
        self.microp = microp
        self.hwmon_root = hwmon_root
        fan = cfg["fan"]
        self.period = float(fan["period"])
        self.failsafe = duty_command(fan["failsafe_duty"])
        self.disk = Curve(cfg["disk"]["points"], cfg["disk"]["shutdown"], fan["hysteresis"])
        self.cpu = Curve(cfg["cpu"]["points"], cfg["cpu"]["shutdown"], fan["hysteresis"])
        self.over_limit = 0
        self.running = True
        self.poweroff_cmd = poweroff_cmd or ["systemctl", "poweroff"]
        self.gpio = None
        self.copy = None
        self.leds = None
        self.led_gates = []
        self.status_sent = None
        self.gpio_last = None
        self.last_rpm_logged = None
        self.missing_logged = set()

    # -- temperatures -> duty --------------------------------------------
    def _temp(self, name):
        t = max_temp(name, self.hwmon_root)
        if t is None:
            if name not in self.missing_logged:
                log.warning("no %s temperature, using failsafe duty", name)
                self.missing_logged.add(name)
        else:
            self.missing_logged.discard(name)
        return t

    def compute(self):
        """Return (command, disk_temp, cpu_temp, over_limit)."""
        disk_t = self._temp("drivetemp")
        cpu_t = self._temp("coretemp")
        if disk_t is None or cpu_t is None:
            return self.failsafe, disk_t, cpu_t, False
        duty = max(self.disk.update(disk_t), self.cpu.update(cpu_t))
        over = disk_t >= self.disk.shutdown or cpu_t >= self.cpu.shutdown
        return duty_command(duty), disk_t, cpu_t, over

    def step(self):
        try:
            cmd, disk_t, cpu_t, over = self.compute()
        except Exception:
            log.exception("reading temperatures failed, using failsafe duty")
            cmd, disk_t, cpu_t, over = self.failsafe, None, None, False
        if cmd != self.microp.last_sent:
            log.info("fan %s (disk %s °C, cpu %s °C)", cmd, disk_t, cpu_t)
        self.microp.send(cmd)
        self.last_temps = (disk_t, cpu_t)
        self.over_limit = self.over_limit + 1 if over else 0
        if self.over_limit >= int(self.cfg["fan"]["shutdown_confirmations"]):
            log.critical("temperature limit reached (disk %s °C, cpu %s °C), powering off",
                         disk_t, cpu_t)
            self.poweroff()

    # -- LEDs ----------------------------------------------------------------
    def start_leds(self):
        c = self.cfg["leds"]
        for chip, off in ((c["disk_gate_chip"], c["disk_gate_offset"]),
                          (c["lan_gate_chip"], c["lan_gate_offset"])):
            try:
                self.led_gates.append(hold_gpio_high(chip, int(off)))
            except Exception:
                log.exception("led gate %s/%s", chip, off)
        log.info("lan leds: %s", ", ".join(setup_lan_leds(c["lan"])) or "none")
        if int(c["brightness"]) >= 0:
            try:
                d = I2CDevice(resolve_bus(c["brightness_bus"], c["lp3943_acpi"]),
                              int(c["brightness_addr"]))
                d.write(0, int(c["brightness"]) & 0x7F)
                d.close()
            except Exception:
                log.exception("led brightness")
        self.microp.send("4")                                   # power LED steady
        self.microp.send("@" if c["copy_led"] == "on" else "B")
        self.microp.send("9")                                   # status: booting
        self.status_sent = "9"
        try:
            self.leds = DiskLeds(c)
            self.leds.start()
        except Exception:
            log.exception("disk leds disabled")

    def update_leds(self, disk_t, cpu_t):
        if self.cfg["leds"]["enabled"] is not True:
            return
        c = self.cfg["leds"]
        try:
            st = subprocess.run(["zpool", "status", "-LP"], capture_output=True,
                                text=True, timeout=20).stdout
            hl = subprocess.run(["zpool", "list", "-H", "-o", "health"], capture_output=True,
                                text=True, timeout=20).stdout
            sysstate = subprocess.run(["systemctl", "is-system-running"], capture_output=True,
                                      text=True, timeout=20).stdout.strip()
        except Exception:
            log.exception("led state query failed")
            return
        if self.leds is not None:
            self.leds.set_pool_states(zpool_disk_states(st))
        byte = status_led(sysstate in ("running", "degraded"), pool_health(hl),
                          bool(self.gpio_last), disk_t, cpu_t,
                          float(c["warn_disk_temp"]), float(c["warn_cpu_temp"]))
        if byte != self.status_sent:
            log.info("status led %r (system %s, pools %s)", byte, sysstate, pool_health(hl))
            self.microp.send(byte)
            self.status_sent = byte

    def stop_leds(self):
        if self.leds is not None:
            self.leds.stop()
        try:  # power LED blinks while the box shuts down, like DSM
            state = subprocess.run(["systemctl", "is-system-running"], capture_output=True,
                                   text=True, timeout=5).stdout.strip()
            if state == "stopping":
                self.microp.send("5")
        except Exception:
            pass

    # -- events ------------------------------------------------------------
    def handle_bytes(self, data):
        power = self.cfg["buttons"]["power_byte"]
        for b in data:
            if b in (0x0D, 0x0A, 0x2D):  # CR, LF, '-' framing
                continue
            name = EVENT_NAMES.get(b, f"unknown byte 0x{b:02x}")
            if b in (ord("f"), ord("g")):
                log.error("microcontroller reports %s", name)
                continue
            log.info("microcontroller event: %s", name)
            if power and b == ord(power) and self.cfg["buttons"]["power_action"] == "poweroff":
                log.warning("power button pressed, powering off")
                self.poweroff()

    def check_gpio(self):
        """Measure the fan tach: rpm (from min_duty up) and stopped-fan detection."""
        if self.gpio is None:
            return
        g = self.cfg["gpio"]
        duty = duty_of(self.microp.last_sent)
        try:
            stamps = self.gpio.edges(float(g["window"]))
        except Exception:
            log.exception("fan tach read failed")
            return
        stopped = duty is not None and duty > 0 and len(stamps) == 0
        rpm = None
        if duty is not None and duty >= int(g["min_duty"]):
            rpm = tach_rpm(stamps, int(g["pulses_per_rev"]))
        if stopped != self.gpio_last:
            if stopped:
                log.error("fan tach: no pulses at %s, fan stopped or unplugged",
                          self.microp.last_sent)
            elif self.gpio_last is not None:
                log.warning("fan tach: pulses back (%s)", self.microp.last_sent)
            self.gpio_last = stopped
        if rpm is not None and rpm != self.last_rpm_logged:
            log.debug("fan %s: %d rpm", self.microp.last_sent, rpm)
        self.last_rpm_logged = rpm
        self.write_status(duty, rpm, stopped, len(stamps))

    def write_status(self, duty, rpm, stopped, edges):
        path = self.cfg["gpio"]["status_file"]
        if not path:
            return
        data = {"time": int(time.time()), "duty": duty, "rpm": rpm,
                "fan_stopped": stopped, "edges": edges,
                "window": float(self.cfg["gpio"]["window"])}
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, path)
        except OSError:
            log.exception("could not write %s", path)

    def check_copy_button(self):
        if self.copy is None:
            return
        try:
            presses = self.copy.presses()
        except Exception:
            log.exception("copy button gpio read failed")
            return
        cmd = self.cfg["buttons"]["copy_command"]
        for length in presses:
            log.info("copy button pressed (%.1f s)", length)
            if cmd:
                subprocess.run(["/bin/sh", "-c", cmd], check=False)

    def poweroff(self):
        self.running = False
        try:
            self.microp.send(self.failsafe)
        except Exception:
            log.exception("could not set failsafe duty before power off")
        subprocess.run(self.poweroff_cmd, check=False)

    # -- main loop ---------------------------------------------------------
    def run(self):
        self.microp.send(self.failsafe)
        freq = self.cfg["fan"]["frequency_cmd"]
        if freq:
            self.microp.send(freq)
        if self.cfg["gpio"]["fan_fail_enabled"]:
            try:
                self.gpio = FanFailGpio(self.cfg["gpio"]["chip_label"],
                                        int(self.cfg["gpio"]["fan_fail_offset"]),
                                        int(self.cfg["gpio"]["pulses_per_rev"]))
            except Exception:
                log.exception("fan-fail gpio disabled")
        b = self.cfg["buttons"]
        if b["copy_enabled"]:
            try:
                self.copy = CopyButtonGpio(b["copy_chip_label"], int(b["copy_offset"]),
                                           float(b["copy_min_press"]))
            except Exception:
                log.exception("copy button gpio disabled")
        if self.cfg["leds"]["enabled"] is True:
            self.start_leds()
        next_at = time.monotonic()
        while self.running:
            now = time.monotonic()
            if now >= next_at:
                self.step()
                self.check_gpio()
                self.update_leds(*getattr(self, "last_temps", (None, None)))
                next_at = now + self.period
            data = self.microp.read_events(min(1.0, max(0.0, next_at - time.monotonic())))
            if data:
                self.handle_bytes(data)
            self.check_copy_button()

    def stop(self, *_):
        self.running = False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-c", "--config", help="TOML config file")
    ap.add_argument("--port", help="override serial port")
    ap.add_argument("--dry-run", action="store_true", help="do not touch the serial port")
    ap.add_argument("--once", action="store_true", help="print the fan command and exit")
    ap.add_argument("--send", metavar="CMD", help="send one allowlisted command and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(message)s")
    cfg = load_config(args.config)
    if args.port:
        cfg["serial"]["port"] = args.port

    port = cfg["serial"]["port"] if args.dry_run else resolve_port(cfg["serial"])
    log.debug("serial port: %s", port)
    microp = Microp(port, cfg["serial"]["prefix"], dry_run=args.dry_run)
    daemon = Daemon(cfg, microp)

    if args.once:
        cmd, disk_t, cpu_t, over = daemon.compute()
        print(f"{cmd} disk={disk_t} cpu={cpu_t} over_limit={over}")
        return 0

    if args.send:
        check_command(args.send)
        microp.open()
        try:
            microp.send(args.send)
        finally:
            microp.close()
        return 0

    microp.open()
    try:
        signal.signal(signal.SIGTERM, daemon.stop)
        signal.signal(signal.SIGINT, daemon.stop)
        daemon.run()
    finally:
        daemon.stop_leds()
        try:
            microp.send(daemon.failsafe)
        except Exception:
            log.exception("could not set failsafe duty on exit")
        microp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
