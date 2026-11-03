# ADB over LAN — forwarding `adbd` to `0.0.0.0:5555` (ZTE G5TS)

Firmware `BD_MEDGEG5TSV1.0.0B07` · aarch64 · Linux 5.4.154 · OpenWrt-based.
Procedure to expose the on-device `adbd` (normally bound to loopback
`127.0.0.1:5037`) to the LAN on `0.0.0.0:5555`, plus a bypass of the
`/bin/adb_shell` RSA gate so `adb shell` yields a root shell directly.

Tested live against an owned device (2026-11-03). Credentials and identifiers
redacted. All steps are reversible (see §5).

## 1. Summary

`adbd` ships on the device but is only reachable on `127.0.0.1:5037`. Because the
device ships a minimal BusyBox (no `nc`, `socat`, `netcat`, `python`), a classic
TCP relay is **not** possible with on-device tools. The correct approach is to
change the port `adbd` itself listens on, via the NV property
`persist.adb.tcp.port`. Once `adbd` binds `0.0.0.0:5555`, `adb` from any LAN host
connects to it. The remaining `adb shell` authentication (`/bin/adb_shell`
running `zte_encrypt_serial`) is bypassed with a bind-mount of a patched copy.

| Aspect | Finding |
|---|---|
| Daemon | `/usr/bin/adbd` (statically linked), managed by procd (`/etc/init.d/adbd`) |
| Default bind | `127.0.0.1:5037` (loopback only) |
| Port source | NV property `persist.adb.tcp.port` (empty → compiled default `5037`) |
| `tcp:<port>` argv | **ignored** by this ZTE build (always falls back to default) |
| Gate | `/bin/adb_shell` → `ubus call zwrt_mc.device.manager adb_switch_no_login` |
| Locked? | `adb_switch_no_login` returns empty → **locked** (RSA challenge) |
| Unlock (clean) | `ubus call zwrt_mc.device.manager adb_switch '{"adbSwitchPwd":"…"}'` |
| Unlock (used here) | bind-mount patched `/bin/adb_shell` from `/etc_rw` |

## 2. Device observations (live)

### 2.1 No relay tools

BusyBox applets (`busybox --list`) include `tcpsvd`, `ftpd`, `udhcpc`, etc., but
**not** `nc` / `netcat` / `telnet`. `socat`, `python`, `inetd` are absent. A
`tcpsvd … nc` relay is therefore not viable. Options are: (a) change `adbd`'s
listen port (chosen), or (b) upload a static relay binary.

### 2.2 `adbd` port selection

`adbd` is statically linked and does not honour the AOSP `tcp:<port>` argument:

```
/ # /usr/bin/adbd tcp:5555
cannot bind 'tcp:5037'
```

It reads the NV property `persist.adb.tcp.port` (also `service.adb.tcp.port`);
both are empty on this unit, so it falls back to the compiled default `5037`.
The NV CLI is available:

```
/ # nv
usage: nv [get name] [getro name] [set name=value] [show] [erase] [save] [restore]
```

Relevant NV items (from `/etc_rw/nv/main/cfg`):

```
persist.adb.tcp.port=          # empty → default port 5037
service.adb.usb.hotplug=1
usb_devices_debug=adb,acm,diag
```

### 2.3 `adbd` is procd-managed

`/etc/init.d/adbd`:

```sh
#!/bin/sh /etc/rc.common
START=17
STOP=83
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/adbd
	procd_set_param respawn
	procd_close_instance
}

stop_service() {
	echo "add clean code"
}
```

Restarting via `/etc/init.d/adbd restart` re-runs the include with the new NV
value.

### 2.4 Mount layout

```
/dev/ubi1_1 on /overlay  type ubifs    (rw) upperdir for /
overlayfs:/overlay on / type overlay  (rw) lowerdir=/, upperdir=/overlay/upper
/dev/mapper/root on /bin type squashfs (ro)   ← /bin/adb_shell lives here
ubi1_0 on /etc_rw     type ubifs      (rw)
```

`/bin` is read-only squashfs; `/etc_rw` is rw ubifs. A file bind-mount over a
squashfs file works (`mount --bind /etc_rw/adb_shell /bin/adb_shell`).

## 3. Procedure

Prerequisite: a root shell (see `docs/WRITEUP.md`, `exploit.py shell` →
`nc <router> 31337`).

### 3.0 Automated (`adb_lan.py`)

The whole procedure is scripted in `adb_lan.py` (reuses `rl.py` / `h.py`):

```bash
export G5TS_HOST=192.168.0.1
export G5TS_PW='<admin password>'

python3 adb_lan.py enable     # set port 5555 + restart adbd + bypass gate
python3 adb_lan.py status     # show port binding + gate state
python3 adb_lan.py disable    # revert everything
```

The script first ensures a root shell is listening on `:31337` (reusing
`exploit.py`'s `tcpsvd` trick) and then runs every command over that shell, since
the firewall-reload primitive (`router_set_remote_acl`) is debounced and not a
reliable repeat trigger on some units.

### 3.1 Manual: expose adbd on `0.0.0.0:5555`

```sh
nv set persist.adb.tcp.port=5555
/etc/init.d/adbd restart
```

Verify:

```
# netstat -ltnp | grep -E '5037|5555'
tcp  0  0  127.0.0.1:5037  0.0.0.0:*  LISTEN  <pid>/adbd
tcp  0  0  0.0.0.0:5555    0.0.0.0:*  LISTEN  <pid>/adbd
```

`0.0.0.0:5555` is now reachable from the LAN. (The loopback `5037` listener
remains; the `5555` listener is the LAN-facing one.)

### 3.2 Manual: bypass the `/bin/adb_shell` gate

```sh
cat > /etc_rw/adb_shell <<'EOF'
#!/bin/sh
export ENV='/etc/adb_profile'
if [ "$1" = '-c' ]; then
  /bin/sh -c "$2"
else
  /bin/sh
fi
EOF
chmod 755 /etc_rw/adb_shell
mount --bind /etc_rw/adb_shell /bin/adb_shell
```

Verify the bind-mount is active:

```
# mount | grep adb_shell
ubi1_0 on /bin/adb_shell type ubifs (rw,relatime,assert=read-only,ubi=1,vol=0)
```

### 3.3 Manual: connect from the LAN

```sh
adb connect <router>:5555
adb devices          # -> <router>:5555  device
adb shell id         # -> uid=0(root) gid=0(root)
```

## 4. Evidence (live)

```
$ adb connect 192.168.0.1:5555
connected to 192.168.0.1:5555

$ adb devices
List of devices attached
192.168.0.1:5555	device

$ adb shell id
uid=0(root) gid=0(root)

$ adb shell 'uname -a; netstat -ltnp | grep -E "5555|5037"'
Linux OpenWrt 5.4.154 #1 SMP PREEMPT ... aarch64 GNU/Linux
tcp  0  0  127.0.0.1:5037  0.0.0.0:*  LISTEN  <pid>/adbd
tcp  0  0  0.0.0.0:5555    0.0.0.0:*  LISTEN  <pid>/adbd
```

Before the gate bypass, `adb shell` returned a `login: ` prompt (the
`zte_encrypt_serial` RSA challenge); after the bind-mount it returns a root shell
directly.

## 5. Revert

```sh
# root shell on the device
nv set persist.adb.tcp.port=          # empty → back to default 5037
/etc/init.d/adbd restart
umount /bin/adb_shell 2>/dev/null
rm -f /etc_rw/adb_shell
```

Then on the client: `adb disconnect <router>:5555`.

> `nv set` writes to non-volatile storage. Revert (or `nv erase` the item) before
> finishing, otherwise `5555` + the gate bypass persist across reboot.

## 6. Security notes

* Exposing `adbd` on `0.0.0.0` **and** bypassing `/bin/adb_shell` is equivalent to
  an unauthenticated root shell on the whole LAN segment — anyone who can reach
  `<router>:5555` gets `uid=0`. Only do this on an isolated research network, and
  revert immediately afterwards.
* The admin password hash is present in `/etc_rw/nv/main/cfg` (`admin_Password=…`)
  and was already readable as root; treat the router as compromised once root was
  obtained via `docs/WRITEUP.md`.
* The clean unlock path (`adb_switch` with `adbSwitchPwd`) was **not** used; the
  bind-mount bypass avoids needing that password but is a filesystem-level change
  rather than an in-band unlock.

## 7. Related

* `docs/USB_DIAG_ADB.md` — USB personalities, ADB gate, DIAG channel (read-only).
* `docs/NV_ACCESS.md` — `nv` CLI and NV items.
* `docs/WRITEUP.md` — root escalation chain and revert tooling.

---
*Documented from a device with root access established via `docs/WRITEUP.md`.*
