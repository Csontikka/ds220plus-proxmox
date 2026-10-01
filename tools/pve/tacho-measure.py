#!/usr/bin/env python3
"""Fan tach on GPIO 39 (gpiochip0): rising edges vs PIC duty. Run with synofand STOPPED.
Prints edge rate and the median period (not thrown off by glitch edges). Always ends at V50."""
import os, statistics, subprocess, termios, time

def port():
    fd = os.open("/dev/ttyMICROP", os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[4] = a[5] = termios.B9600
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[0] = a[1] = a[3] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd

def edges(sec=4):
    r = subprocess.run(["timeout", str(sec), "gpiomon", "-c", "gpiochip0", "-e", "rising",
                        "--format", "%S", "39"], capture_output=True, text=True)
    return [float(x) for x in r.stdout.split()]

fd = port()
try:
    for duty in ("V00", "V10", "V20", "V35", "V50", "V70", "V99"):
        os.write(fd, duty.encode())
        time.sleep(8)
        t = edges()
        if len(t) < 3:
            print(f"{duty}: {len(t)} edges (fan stopped?)", flush=True)
            continue
        d = [b - a for a, b in zip(t, t[1:])]
        med = statistics.median(d)
        short = sum(1 for x in d if x < med / 2)
        print(f"{duty}: edges/s={len(t)/(t[-1]-t[0]):.1f} median_period={med*1000:.2f}ms "
              f"f_med={1/med:.1f}Hz rpm(2ppr)={60/(2*med):.0f} glitches={short}", flush=True)
finally:
    os.write(fd, b"V50")
    os.close(fd)
