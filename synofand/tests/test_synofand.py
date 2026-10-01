import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import synofand as s  # noqa: E402


class FakeMicrop:
    def __init__(self):
        self.sent = []
        self.last_sent = None

    def send(self, cmd):
        s.check_command(cmd)
        self.sent.append(cmd)
        self.last_sent = cmd


def make_hwmon(root, name, temps_c):
    d = tempfile.mkdtemp(prefix="hwmon", dir=root)
    with open(os.path.join(d, "name"), "w") as f:
        f.write(name + "\n")
    for i, t in enumerate(temps_c, 1):
        with open(os.path.join(d, f"temp{i}_input"), "w") as f:
            f.write(f"{int(t * 1000)}\n")
    return d


def set_temp(dev, t, idx=1):
    with open(os.path.join(dev, f"temp{idx}_input"), "w") as f:
        f.write(f"{int(t * 1000)}\n")


class CommandTests(unittest.TestCase):
    def test_forbidden_never_passes(self):
        for cmd in ["1", "C", "", "V100", "V5", "v50", "X", "1V50", "V50C", None, "-1"]:
            with self.assertRaises(s.ForbiddenCommand, msg=repr(cmd)):
                s.check_command(cmd)

    def test_allowed(self):
        for cmd in ["V00", "V99", "V50", "W10", "4", "6", "@", "u", "EC1"]:
            self.assertEqual(s.check_command(cmd), cmd)

    def test_duty_command_clamps(self):
        self.assertEqual(s.duty_command(-5), "V00")
        self.assertEqual(s.duty_command(20), "V20")
        self.assertEqual(s.duty_command(150), "V99")

    def test_every_duty_is_allowed(self):
        for d in range(0, 120):
            s.check_command(s.duty_command(d))

    def test_microp_refuses_before_writing(self):
        m = s.Microp("/nonexistent", dry_run=True)
        with self.assertRaises(s.ForbiddenCommand):
            m.send("1")
        self.assertIsNone(m.last_sent)


class CurveTests(unittest.TestCase):
    def disk(self):
        c = s.DEFAULTS["disk"]
        return s.Curve(c["points"], c["shutdown"], hysteresis=3)

    def test_dsm_steps(self):
        for temp, duty in [(30, 20), (41, 30), (45.9, 30), (46, 50), (50, 70), (53, 99), (60, 99)]:
            self.assertEqual(self.disk().update(temp), duty, temp)

    def test_hysteresis(self):
        c = self.disk()
        self.assertEqual(c.update(46), 50)
        self.assertEqual(c.update(44), 50)   # within 3 °C of the 46 step
        self.assertEqual(c.update(42.9), 30)  # fell below 46 - 3
        self.assertEqual(c.update(20), 20)

    def test_drops_several_levels(self):
        c = self.disk()
        self.assertEqual(c.update(55), 99)
        self.assertEqual(c.update(30), 20)

    def test_curve_must_start_at_zero(self):
        with self.assertRaises(ValueError):
            s.Curve([[10, 20]], 60, 3)


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.cpu = make_hwmon(self.root, "coretemp", [45, 47])
        self.d1 = make_hwmon(self.root, "drivetemp", [35])
        self.d2 = make_hwmon(self.root, "drivetemp", [38])
        self.cfg = s.load_config(None)
        self.m = FakeMicrop()
        self.poweroffs = []
        self.daemon = s.Daemon(self.cfg, self.m, hwmon_root=self.root,
                               poweroff_cmd=["true"])
        self.daemon.poweroff = lambda: self.poweroffs.append(1)

    def test_normal(self):
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V20")

    def test_hotter_disk_wins(self):
        set_temp(self.d2, 47)
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V50")

    def test_cpu_can_raise(self):
        set_temp(self.cpu, 71, 2)
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V99")

    def test_missing_sensor_is_failsafe(self):
        for f in os.listdir(self.d1):
            os.remove(os.path.join(self.d1, f))
        for f in os.listdir(self.d2):
            os.remove(os.path.join(self.d2, f))
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V99")

    def test_garbage_sensor_value_is_ignored(self):
        with open(os.path.join(self.d1, "temp1_input"), "w") as f:
            f.write("garbage")
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V20")  # d2 still readable

    def test_shutdown_needs_confirmation(self):
        set_temp(self.d1, 62)
        self.daemon.step()
        self.assertEqual(self.poweroffs, [])
        self.daemon.step()
        self.assertEqual(self.poweroffs, [1])

    def test_single_spike_does_not_shut_down(self):
        set_temp(self.d1, 62)
        self.daemon.step()
        set_temp(self.d1, 40)
        self.daemon.step()
        set_temp(self.d1, 62)
        self.daemon.step()
        self.assertEqual(self.poweroffs, [])

    def test_exception_in_compute_is_failsafe(self):
        def boom():
            raise RuntimeError("x")
        self.daemon.compute = boom
        self.daemon.step()
        self.assertEqual(self.m.sent[-1], "V99")

    def test_power_button_default_only_logs(self):
        self.daemon.handle_bytes(b"-0\r\n")
        self.assertEqual(self.poweroffs, [])

    def test_power_button_poweroff(self):
        self.cfg["buttons"]["power_action"] = "poweroff"
        self.daemon.handle_bytes(b"0")
        self.assertEqual(self.poweroffs, [1])

    def test_unknown_bytes_do_nothing(self):
        self.cfg["buttons"]["power_action"] = "poweroff"
        self.daemon.handle_bytes(b"xyz\x00\xff")
        self.assertEqual(self.poweroffs, [])


class ConfigTests(unittest.TestCase):
    def write(self, text):
        fd, path = tempfile.mkstemp(suffix=".toml")
        with os.fdopen(fd, "w") as f:
            f.write(text)
        return path

    def test_example_config_loads(self):
        path = os.path.join(os.path.dirname(__file__), "..", "synofand.toml.example")
        cfg = s.load_config(path)
        self.assertEqual(cfg["serial"]["pci"], "0000:00:18.0")

    def test_forbidden_frequency_cmd_rejected(self):
        path = self.write('[fan]\nfrequency_cmd = "C"\n')
        with self.assertRaises(s.ForbiddenCommand):
            s.load_config(path)


class PortTests(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "sysfs names contain ':' (Linux only)")
    def test_pci_lookup(self):
        root = tempfile.mkdtemp()
        os.makedirs(os.path.join(root, "0000:00:18.0", "0000:00:18.0:0",
                                 "0000:00:18.0:0.0", "tty", "ttyS4"))
        os.makedirs(os.path.join(root, "0000:00:18.2", "tty", "ttyS5"))
        self.assertEqual(s.find_pci_tty("0000:00:18.0", root), "/dev/ttyS4")
        self.assertEqual(s.resolve_port({"port": "", "pci": "0000:00:18.2"}, root), "/dev/ttyS5")

    def test_explicit_port_wins(self):
        self.assertEqual(s.resolve_port({"port": "/dev/ttyS9", "pci": "x"}), "/dev/ttyS9")

    def test_missing_port_fails(self):
        with self.assertRaises(RuntimeError):
            s.resolve_port({"port": "", "pci": "0000:99:99.9"}, tempfile.mkdtemp())


@unittest.skipUnless(hasattr(os, "openpty") and s.termios, "needs a pty (Linux)")
class PtyTests(unittest.TestCase):
    def test_real_serial_roundtrip(self):
        master, slave = os.openpty()
        port = os.ttyname(slave)
        m = s.Microp(port, prefix="-")
        m.open()
        try:
            m.send("V42")
            self.assertEqual(os.read(master, 16), b"-V42")
            with self.assertRaises(s.ForbiddenCommand):
                m.send("1")
            os.write(master, b"0")
            self.assertEqual(m.read_events(1.0), b"0")
        finally:
            m.close()
            os.close(master)
            os.close(slave)

class TachTest(unittest.TestCase):
    def test_duty_of(self):
        self.assertEqual(s.duty_of("V50"), 50)
        self.assertEqual(s.duty_of("V00"), 0)
        self.assertIsNone(s.duty_of("4"))
        self.assertIsNone(s.duty_of(None))

    def test_tach_rpm(self):
        # 44.4 Hz rising edges = 1333 rpm at 2 pulses per revolution (measured at V50)
        clean = [i / 44.4 for i in range(90)]
        self.assertLessEqual(abs(s.tach_rpm(clean) - 1333), 2)
        # a few glitch edges must not move the median much
        glitchy = sorted(clean + [clean[i] + 0.001 for i in range(0, 90, 15)])
        self.assertLessEqual(abs(s.tach_rpm(glitchy) - 1333), 40)
        self.assertIsNone(s.tach_rpm([]))
        self.assertIsNone(s.tach_rpm([1.0, 1.02]))

ZPOOL_STATUS_DEGRADED = """  pool: data
 state: DEGRADED
config:

	NAME           STATE     READ WRITE CKSUM
	data           DEGRADED     0     0     0
	  mirror-0     DEGRADED     0     0     0
	    /dev/sda2  ONLINE       0     0     0
	    /dev/sdb2  REMOVED      0     0     0

  pool: rpool
 state: DEGRADED
config:

	NAME           STATE     READ WRITE CKSUM
	rpool          DEGRADED     0     0     0
	  mirror-0     DEGRADED     0     0     0
	    /dev/sda1  ONLINE       0     0     0
	    /dev/sdb1  REMOVED      0     0     0
"""


class LedTest(unittest.TestCase):
    def test_lp3943_selectors(self):
        # measured map: 0 disk1 green, 1 disk1 orange, 2 disk2 green, 3 disk2 orange
        self.assertEqual(s.lp3943_selectors({0: "on"})[0x06], 0x01)
        self.assertEqual(s.lp3943_selectors({1: "on"})[0x06], 0x04)
        self.assertEqual(s.lp3943_selectors({2: "on"})[0x06], 0x10)
        self.assertEqual(s.lp3943_selectors({3: "on"})[0x06], 0x40)
        regs = s.lp3943_selectors({0: "on", 3: "on", 1: "off"})
        self.assertEqual(regs, {0x06: 0x41, 0x07: 0, 0x08: 0, 0x09: 0})

    def test_zpool_disk_states(self):
        st = s.zpool_disk_states(ZPOOL_STATUS_DEGRADED)
        self.assertEqual(st, {"sda": "ONLINE", "sdb": "REMOVED"})

    def test_pool_health(self):
        self.assertEqual(s.pool_health("ONLINE\nONLINE\n"), "ONLINE")
        self.assertEqual(s.pool_health("ONLINE\nDEGRADED\n"), "DEGRADED")
        self.assertEqual(s.pool_health("DEGRADED\nFAULTED\n"), "FAULTED")

    def test_disk_led(self):
        self.assertEqual(s.disk_led(False, None), "off")
        self.assertEqual(s.disk_led(True, "ONLINE"), "green")
        self.assertEqual(s.disk_led(True, None), "green")      # not in a pool
        self.assertEqual(s.disk_led(True, "FAULTED"), "orange")

    def test_status_led(self):
        self.assertEqual(s.status_led(False, "ONLINE", False, 30, 40, 53, 75), "9")
        self.assertEqual(s.status_led(True, "ONLINE", False, 30, 40, 53, 75), "8")
        self.assertEqual(s.status_led(True, "DEGRADED", False, 30, 40, 53, 75), ":")
        self.assertEqual(s.status_led(True, "ONLINE", False, 55, 40, 53, 75), ":")
        self.assertEqual(s.status_led(True, "ONLINE", True, 30, 40, 53, 75), ";")
        self.assertEqual(s.status_led(True, "FAULTED", False, 30, 40, 53, 75), ";")

    def test_disk_io(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("   8       0 sda 100 0 800 10 50 0 400 5 0 20 15 0 0 0 0\n"
                    "   8      16 sdb 7 0 56 1 3 0 24 1 0 2 2 0 0 0 0\n")
        try:
            self.assertEqual(s.disk_io("sda", f.name), 150)
            self.assertEqual(s.disk_io("sdb", f.name), 10)
            self.assertIsNone(s.disk_io("sdc", f.name))
        finally:
            os.unlink(f.name)

    def test_leds_default_off(self):
        self.assertIs(s.DEFAULTS["leds"]["enabled"], False)

class I2CBusTest(unittest.TestCase):
    def test_i2c_bus_of_follows_the_acpi_device(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "devices", "pci0000:00", "0000:00:1f.1", "i2c-1",
                                "i2c-LED3943:00")
            root = os.path.join(d, "bus")
            try:  # needs ':' in file names and symlinks (Linux), not Windows
                os.makedirs(real)
                os.makedirs(root)
                os.symlink(real, os.path.join(root, "i2c-LED3943:00"))
            except (OSError, NotImplementedError):
                self.skipTest("no ':' file names or symlinks here")
            self.assertEqual(s.i2c_bus_of("LED3943:00", root), 1)
            self.assertEqual(s.resolve_bus("auto", "LED3943:00", root), 1)
            self.assertEqual(s.resolve_bus(3, "LED3943:00", root), 3)
            with self.assertRaises(RuntimeError):
                s.i2c_bus_of("NOPE:00", root)

    def test_default_is_auto(self):
        self.assertEqual(s.DEFAULTS["leds"]["lp3943_bus"], "auto")


if __name__ == "__main__":
    unittest.main()
