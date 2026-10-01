#!/usr/bin/env python3
"""Puts the test Debian boot files on the NAS DOM (DS220+, from DSM), over SSH.

Steps: mount both DOM partitions, save the original SynoBootLoader.conf (as .orig, only
if there is no saved copy yet), copy vmlinuz and initrd.img to /synodeb/ on p2, write the
new menu, create the /linux-once flag file (only with --once), unmount, then mount again
read-only and verify everything (SHA256).

Usage:   python syno-dom-install.py <nas-ip> <vmlinuz> <initrd.img> <SynoBootLoader.conf> [--once] [--cmdline <file>]
Restore: python syno-dom-install.py <nas-ip> --restore   (puts the .orig menu back, removes the flag file)
"""
import hashlib
import sys

import getpass  # noqa: E402
import os  # noqa: E402
import paramiko  # noqa: E402

# DSM login: an administrator account with sudo. Port and user from the environment
# (DSM_SSH_PORT, DSM_USER), the password is asked for (never on the command line).
host = sys.argv[1]
port = int(os.environ.get("DSM_SSH_PORT", "22"))
user = os.environ.get("DSM_USER", "admin")
pw = getpass.getpass(f"password for {user}@{host}: ")
cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(host, port, user, pw, look_for_keys=False, allow_agent=False, timeout=15)

P1, P2 = "/tmp/sbdom1", "/tmp/sbdom2"
CONF = f"{P1}/EFI/boot/SynoBootLoader.conf"
FLAG = f"{P2}/linux-once"


def run(cmd, data=None, check=True):
    full = "sudo -S -p '' sh -c " + "'" + cmd.replace("'", "'\\''") + "'"
    i, o, e = cli.exec_command(full)
    i.write(pw + "\n")
    if data is not None:
        i.write(data)
    i.channel.shutdown_write()
    out, err = o.read().decode(), e.read().decode()
    rc = o.channel.recv_exit_status()
    if check and rc:
        raise SystemExit(f"error ({rc}): {cmd}\n{out}\n{err}")
    return out.strip()


def sha(path):
    return run(f"sha256sum {path} | cut -d' ' -f1")


def mount(rw):
    o = "rw" if rw else "ro"
    run(f"mkdir -p {P1} {P2}; cd /dev && mount -o {o} ./synoboot1 {P1} && mount -o {o} ./synoboot2 {P2}")


def umount():
    run(f"sync; umount {P1}; umount {P2}; rmdir {P1} {P2}")


if run("grep -c sbdom /proc/mounts", check=False) != "0":
    raise SystemExit("the DOM is already mounted somewhere, check that first")

if sys.argv[2] == "--restore":
    mount(True)
    try:
        run(f"test -f {CONF}.orig && cp {CONF}.orig {CONF}; rm -f {FLAG}")
        print("original menu restored, flag file removed")
    finally:
        umount()
    sys.exit(0)

vmlinuz, initrd, conf = sys.argv[2:5]
once = "--once" in sys.argv
files = {
    f"{P2}/synodeb/vmlinuz": open(vmlinuz, "rb").read(),
    f"{P2}/synodeb/initrd.img": open(initrd, "rb").read(),
}
# --cmdline <file>: an optional kernel parameter file, copied to /synodeb/cmdline.cfg
# (the shipped menu does not read it: this GRUB has no source command)
if "--cmdline" in sys.argv:
    cmdline = open(sys.argv[sys.argv.index("--cmdline") + 1], "rb").read()
    if b"\r" in cmdline:
        raise SystemExit("cmdline.cfg contains CRLF, not uploading it")
    files[f"{P2}/synodeb/cmdline.cfg"] = cmdline
new_conf = open(conf, "rb").read()
if b"\r" in new_conf:
    raise SystemExit("the menu file contains CRLF, not uploading it")

mount(True)
try:
    print("DOM free space before:\n" + run(f"df -k {P1} {P2}"))
    run(f"test -f {CONF}.orig || cp -p {CONF} {CONF}.orig")
    print("original menu saved:", sha(f"{CONF}.orig"))
    run(f"mkdir -p {P2}/synodeb")
    for path, data in files.items():
        run(f"cat > {path}.tmp", data=data)
        if sha(f"{path}.tmp") != hashlib.sha256(data).hexdigest():
            raise SystemExit(f"upload error: {path}")
        run(f"mv {path}.tmp {path}")
        print("uploaded:", path, len(data))
    run(f"cat > {CONF}.new", data=new_conf)
    if sha(f"{CONF}.new") != hashlib.sha256(new_conf).hexdigest():
        raise SystemExit("upload error: menu")
    run(f"mv {CONF}.new {CONF}")
    print("new menu in place")
    if once:
        # the menu only checks that the file exists (search --file); the content is a note
        run(f"cat > {FLAG}", data=b"set default='2'\nset fallback='1'\n")
        print("flag file created:", FLAG)
    print("difference to the original:\n" + run(f"diff {CONF}.orig {CONF}", check=False))
    print("DOM free space after:\n" + run(f"df -k {P1} {P2}"))
finally:
    umount()

# Verify with a read-only mount
mount(False)
try:
    for path, data in files.items():
        assert sha(path) == hashlib.sha256(data).hexdigest(), path
    assert sha(CONF) == hashlib.sha256(new_conf).hexdigest(), CONF
    print("verified (ro):", ", ".join(list(files) + [CONF]))
    print("flag file:", run(f"ls -l {FLAG}", check=False) or "none")
finally:
    umount()
cli.close()
