#!/usr/bin/env python3
"""Does GPIO 39 (gpiochip0) follow the fan? Samples it at V50 and V00.
Run on the box with synofand STOPPED. Always leaves the fan at V50."""
import os, subprocess, sys, termios, time

PORT = "/dev/ttyMICROP"

def send(fd, cmd):
    os.write(fd, cmd.encode())
    time.sleep(0.3)

def sample(n=400, gap=0.002):
    vals = []
    for _ in range(n):
        r = subprocess.run(["gpioget", "-c", "gpiochip0", "--numeric", "39"],
                           capture_output=True, text=True)
        vals.append(r.stdout.strip())
        time.sleep(gap)
    edges = sum(1 for a, b in zip(vals, vals[1:]) if a != b)
    return {v: vals.count(v) for v in set(vals)}, edges

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY)
a = termios.tcgetattr(fd)
a[4] = a[5] = termios.B9600
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[0] = a[1] = a[3] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
try:
    for duty, wait in (("V50", 6), ("V99", 6), ("V00", 12), ("V50", 8)):
        send(fd, duty)
        time.sleep(wait)
        t0 = time.time()
        counts, edges = sample()
        print(f"{duty}: {counts} edges={edges} in {time.time()-t0:.1f}s", flush=True)
finally:
    send(fd, "V50")
    os.close(fd)
