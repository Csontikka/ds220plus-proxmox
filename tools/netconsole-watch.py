#!/usr/bin/env python3
"""Receives the NAS netconsole messages (UDP 6666), prints and logs them.

Usage: python netconsole-watch.py [logfile]
Incoming UDP 6666 must be allowed in the local firewall.
"""
import datetime
import socket
import sys

log = open(sys.argv[1] if len(sys.argv) > 1 else "netconsole.log", "a", encoding="utf-8")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 6666))
print("listening: UDP 6666", flush=True)
while True:
    data, (ip, _port) = s.recvfrom(65535)
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    for line in data.decode("utf-8", "replace").splitlines():
        out = f"{ts} {ip} {line}"
        print(out, flush=True)
        log.write(out + "\n")
    log.flush()
