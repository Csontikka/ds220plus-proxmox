#!/usr/bin/env python3
"""Watches and logs a serial console (read only, except what you write to the command file).

Usage: python serial-watch.py COM15 [115200] [logfile]
Next to the log file a <logfile>.in file is created: every line written to it is sent
to the port (one line = one send). Special lines: ^C (Ctrl-C), ^M (Enter), ^[ (ESC),
^E, ^X, ^A, <UP>/<DOWN> (arrow keys). A line starting with ~ is typed slowly.
"""
import os
import sys
import time

import serial

port = sys.argv[1]
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
logpath = sys.argv[3] if len(sys.argv) > 3 else "serial.log"
inpath = logpath + ".in"
open(inpath, "w").close()
KEYS = {"^C": b"\x03", "^M": b"\r", "^[": b"\x1b", "^E": b"\x05", "^X": b"\x18", "^A": b"\x01",
        "<UP>": b"\x1b[A", "<DOWN>": b"\x1b[B"}

s = serial.Serial(port, baud, timeout=0.2)
log = open(logpath, "ab")
raw = open(logpath + ".raw", "ab")
log.write(f"\n=== opened {time.strftime('%H:%M:%S')} {port} {baud} ===\n".encode())
log.flush()
inpos = 0
line_start = True
while True:
    data = s.read(4096)
    if data:
        # AUTO_CTRLC=1: sends Ctrl-C by itself at the GRUB countdown (a limited number of times)
        if os.environ.get("AUTO_CTRLC") and (b"CTRL-C" in data or b"boots automatically" in data) \
                and globals().get("_sent", 0) < 20:
            for _ in range(5):
                s.write(b"\x03")
                time.sleep(0.05)
            globals()["_sent"] = globals().get("_sent", 0) + 1
            log.write(f"\n>>> automatic Ctrl-C x5 {time.strftime('%H:%M:%S')}\n".encode())
        raw.write(data)
        raw.flush()
        out = bytearray()
        for b in data:
            if line_start:
                out += time.strftime("%H:%M:%S ").encode()
                line_start = False
            out.append(b)
            if b == 0x0A:
                line_start = True
        log.write(bytes(out))
        log.flush()
    if os.path.getsize(inpath) > inpos:
        with open(inpath, "rb") as f:
            f.seek(inpos)
            new = f.read()
            inpos = f.tell()
        for ln in new.decode("utf-8", "replace").splitlines():
            if ln.startswith("~"):  # slow typing: the GRUB editor drops characters on a serial line
                for ch in ln[1:].encode():
                    s.write(bytes([ch]))
                    time.sleep(0.25)
                log.write(f"\n>>> typed: {ln[1:]!r} {time.strftime('%H:%M:%S')}\n".encode())
                continue
            payload = KEYS.get(ln.strip(), ln.encode())
            s.write(payload)
            log.write(f"\n>>> sent: {ln!r} {time.strftime('%H:%M:%S')}\n".encode())
            log.flush()
