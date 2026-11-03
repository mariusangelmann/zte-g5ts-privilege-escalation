# ZTE G5TS — authenticated admin → root (firmware `BD_MEDGEG5TSV1.0.0B07`)

Post-auth privilege escalation to **`uid=0(root)`** on the ZTE G5TS 5G CPE.
No reboot, no flashing, no kernel exploit.

**Keywords:** ZTE G5TS, `BD_MEDGEG5TSV1.0.0B07`, cgi-io, cgi-exec, cgi-upload,
ubus, zwrt_router, OpenWrt, firewall3, fw3, miniupnpd/firewall.include, /etc_rw,
overlayfs, UBIFS, router root, authenticated privilege escalation, RCE.

## Vulnerability

An authenticated admin web session reaches root through three flaws:

1. **`cgi-io` gives the CGI user (`nobody`) write + exec.** `POST /cgi-bin%2fcgi-upload`
   writes `/tmp/back_parameter`; `cgi-exec` `execv()`s an arbitrary program as
   `nobody` (uid 65534).
2. **`nobody` can unlink/recreate files** under `/etc`, `/etc/config`,
   `/etc/init.d`, `/etc/hotplug.d`, `/usr/share`, `/etc_rw`, `/var`, `/cache`
   (overlayfs/UBIFS with over-permissive modes/ACLs).
3. **fw3 (root) executes a script from a writable path.** `/etc/config/firewall`
   includes `/usr/share/miniupnpd/firewall.include` with `type 'script'` +
   `reload '1'`; fw3 runs it as root on firewall reload.

Replace that include with `original rules + payload`, then fire a benign RPC that
reloads the firewall (`zwrt_router.api router_set_remote_acl`) → payload runs as
root.

```
admin web session ──ubus_rpc_session──▶ cgi-io (cgi-upload + cgi-exec)
        │
        ▼  shell as nobody (uid 65534)
   unlink + recreate /usr/share/miniupnpd/firewall.include
        │
        ▼  firewall reload (benign RPC)
   fw3 runs the include as root ──▶ uid=0(root)
```

## Affected

| Field | Value |
|---|---|
| Vendor / product | ZTE G5TS (5G CPE) |
| Firmware tested | `BD_MEDGEG5TSV1.0.0B07` (aarch64, Linux 5.4.154, OpenWrt-based) |
| Privilege required | authenticated **admin** web session |
| Impact | code execution as `root` |
| CVE | not assigned |
| Reboot / flash | not required |

Derivatives shipping the same `cgi-io`, the same over-permissive overlay/UBIFS
layout, and the same fw3 `miniupnpd` include are **likely affected** — verify per
version.

## Files

| Path | Purpose |
|---|---|
| `exploit.py` | driver: `check` / `shell` / `status` / `restore` |
| `adb_lan.py` | expose `adbd` to LAN on `0.0.0.0:5555` (`enable` / `disable` / `status`) |
| `rl.py` | ubus JSON-RPC transport + login (`rl.SESS` = live session) |
| `h.py` | helpers: `u` ubus call, `ex` cgi-exec, `dl` download, `up` upload, `shrun` |
| `revert.sh` | on-device: restore both files + remove all artifacts |
| `verify.sh` | on-device: enumerate leftovers |
| `restore/` | pristine `miniupnpd.include.orig`, `firewall.user.orig` |
| `atcmd.sh` | send AT commands to the modem via root shell (`atcmd.sh "ATI"`, `-f` batch) |
| `docs/WRITEUP.md` | full technical write-up (root cause, chain, evidence, revert) |
| `docs/AT_COMMAND_ACCESS.md` | modem AT-command access: transport, usage, observed responses |
| `docs/NV_ACCESS.md` | modem NV (non-volatile) store: `nv` CLI, `AT+ZSET`, observed items |
| `docs/USB_DIAG_ADB.md` | USB factory/debug modes, Qualcomm DIAG & ADB access paths |
| `docs/ADB_LAN_FORWARD.md` | expose `adbd` on `0.0.0.0:5555` + bypass `/bin/adb_shell` gate (script: `adb_lan.py`) |

## Reproduce

```bash
export G5TS_HOST=192.168.0.1
export G5TS_PW='<admin password>'

python3 exploit.py check     # prove root via the firewall-include primitive
python3 exploit.py shell     # root shell on :31337  (nc "$G5TS_HOST" 31337)
python3 exploit.py restore   # restore original include + clean up
```

Exact HTTP bodies, the patched include, and the trigger RPC: `docs/WRITEUP.md` §4.

## Mitigation

| Weakness | Fix |
|---|---|
| `cgi-exec` runs arbitrary programs as the CGI user | remove it, or gate behind explicit non-remote authorisation |
| `cgi-upload` writes an attacker-chosen path | constrain to a private, non-executed directory |
| `nobody` can write under `/etc`, `/usr/share`, `/etc_rw`, `/var`, `/cache` | fix directory modes and overlay/UBIFS ACLs (root-only) |
| fw3 executes a `type script` include from a writable dir | keep root-executed includes on a read-only mount |
| unprivileged callers can trigger root daemons via RPC | enforce privilege boundaries between CGI/web and root daemons |

Owners (interim): rotate the admin password, disable WAN/remote management,
restrict management to a trusted LAN.

## Legal / AI

Authorised testing and defensive research only; no warranty — `DISCLAIMER.md`.
Built with AI assistance, device-verified — `AI_DISCLOSURE.md`. License:
`LICENSE`. No credentials, keys, serials, or network identifiers are included.

---
*Research and PoC by Marius Angelmann ([@mariusangelmann](https://github.com/mariusangelmann)).*
