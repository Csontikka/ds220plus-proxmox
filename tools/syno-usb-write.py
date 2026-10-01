#!/usr/bin/env python3
"""Writes a raw image to a USB stick plugged into the NAS (DS220+, still on DSM), over SSH.

Usage:  python syno-usb-write.py <image.img.gz> <nas-ip> <device> <sectors>
  e.g.  python syno-usb-write.py synodeb.img.gz 192.0.2.10 usb1 7864320

Safety: writes only if the device is named usbN, is removable (removable=1), its size is
exactly the given sector count, and it is not the DOM (synoboot). Unmounts DSM's
automatic mounts first. Reads the stick back afterwards and compares the SHA256.
DSM login: an administrator account with sudo. Port and user from the environment
(DSM_SSH_PORT, DSM_USER), the password is asked for (never on the command line).
"""
import getpass
import gzip
import hashlib
import os
import sys
import time

import paramiko

img_gz, host, dev, sectors = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
if not dev.startswith("usb") or not dev[3:].isdigit():
    sys.exit(f"only writes to a usbN device, this is: {dev}")

port = int(os.environ.get("DSM_SSH_PORT", "22"))
user = os.environ.get("DSM_USER", "admin")
pw = getpass.getpass(f"password for {user}@{host}: ")
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(host, port, user, pw, look_for_keys=False, allow_agent=False, timeout=15)


def run(cmd, data=None, check=True):
    full = "sudo -S -p '' sh -c " + "'" + cmd.replace("'", "'\\''") + "'"
    i, o, e = cli.exec_command(full)
    i.write(pw + "\n")
    if data is not None:
        for chunk in data:
            i.write(chunk)
    i.channel.shutdown_write()
    # After a large upload the channel sometimes does not close by itself (the remote
    # command has already exited): wait for the exit status, not for EOF.
    ch = o.channel
    deadline = time.time() + 900
    while not ch.exit_status_ready():
        if time.time() > deadline:
            sys.exit(f"timeout: {cmd}")
        time.sleep(1)
    rc = ch.recv_exit_status()
    out = ch.recv(1 << 20).decode(errors="replace") if ch.recv_ready() else ""
    err = ch.recv_stderr(1 << 20).decode(errors="replace") if ch.recv_stderr_ready() else ""
    if check and rc:
        sys.exit(f"error ({rc}): {cmd}\n{out}\n{err}")
    return out.strip()


b = f"/sys/block/{dev}"
size = int(run(f"cat {b}/size"))
removable = run(f"cat {b}/removable")
model = run(f"cat {b}/device/vendor {b}/device/model | tr -s ' \\n' ' '")
print(f"target: /dev/{dev} {size} sectors, removable={removable}, {model}")
if size != sectors or removable != "1":
    sys.exit("the target does not match the given one, not writing")
if run(f"readlink -f /dev/{dev}") == run("readlink -f /dev/synoboot"):
    sys.exit("the target is the DOM, not writing")

for mp in run(f"grep '^/dev/{dev}' /proc/mounts | cut -d' ' -f2", check=False).split():
    print("unmount:", mp)
    run(f"umount {mp} || umount -l {mp}")

raw_size = 0
h = hashlib.sha256()
with gzip.open(img_gz, "rb") as f:
    while True:
        c = f.read(4 << 20)
        if not c:
            break
        h.update(c)
        raw_size += len(c)
want = h.hexdigest()
print(f"image: {raw_size} bytes, sha256 {want}")
if raw_size > size * 512:
    sys.exit("the image is larger than the stick")


def chunks():
    sent = 0
    with open(img_gz, "rb") as f:
        while True:
            c = f.read(1 << 20)
            if not c:
                break
            sent += len(c)
            print(f"\rsent {sent >> 20} MB", end="", flush=True)
            yield c
    print()


run(f"gzip -dc | dd of=/dev/{dev} bs=4M conv=fsync 2>&1 | tail -1", data=chunks())
got = run(f"head -c {raw_size} /dev/{dev} | sha256sum | cut -d' ' -f1")
print("read back:", got)
run(f"blockdev --rereadpt /dev/{dev}", check=False)
for mp in run(f"grep '^/dev/{dev}' /proc/mounts | cut -d' ' -f2", check=False).split():
    run(f"umount {mp}", check=False)
cli.close()
sys.exit(0 if got == want else "SHA256 MISMATCH")
