# AT command access — ZTE G5TS modem

Firmware `BD_MEDGEG5TSV1.0.0B06` (modem) · Qualcomm ZX29 SoC · Linux 5.4.154
host. Documented from a root shell on the device (see `README.md`). All AT
commands below were exercised as **read-only**; no modem configuration was
changed.

## 1. Summary

The modem is not exposed over `ttyUSB*` / `ttyACM*` like a USB-dongle. It is a
Qualcomm (ZX29) baseband on the same SoC, reached from Linux through **rpmsg**
(`/dev/armps_rpmsgch0…49`) and the **SBUS** daemon. AT commands are relayed by a
ZTE userspace stack — the supported entry point is:

```
/usr/bin/zte_topsw_mc atcmd "<AT_COMMAND>"
```

Internal function: `zte_mc_tsp_send_atcmd()`. The command travels
`zte_topsw_mc` → `at_ctl` daemon → `sbusd`/`zte_topsw_sbusd` → modem, and the
response is printed on stdout (prefixed by a `[net]` log line).

```
root shell (31337)
      │  /usr/bin/zte_topsw_mc atcmd "ATI"
      ▼
  zte_topsw_mc (PID 7481)   ──IPC──▶  at_ctl (PID 2947, single instance)
      │  zte_mc_tsp_send_atcmd           │
      ▼                                  ▼
  sbusd / zte_topsw_sbusd (PID 10479) ──SBUS/rpmsg──▶ Qualcomm ZX29 modem
```

## 2. Discovery

No USB-serial modem devices exist:

```
/dev/ttyS0 /dev/ttyS2 /dev/ttyS4        (zx29_uart console/aux UARTs)
/dev/armps_rpmsgch0 … armps_rpmsgch49   (rpmsg channels to baseband)
```

No `lsusb`, no `/dev/cndiag*`, no `/dev/smd*`, no `ttyUSB*`. The modem stack is:

| Process | PID (observed) | Role |
|---|---|---|
| `at_ctl` | 2947 | AT-command daemon (single instance; refuses a second copy) |
| `atserver` | 3522 | AT server (`at_main_thread`) |
| `zte_topsw_mc` | 7481 | modem control — **`atcmd` entry point** |
| `zte_topsw_mdm` | 5203 | modem manager |
| `sbusd` / `zte_topsw_sbusd` | 7718 / 10479 | SBUS transport to baseband |
| `zte_topsw_data` | 7425 | data-path manager (topsw/QMI) |

Relevant Unix sockets in `/tmp`:

```
AT_SERVER_MSG                    # atserver message socket
AT_SERVER_MSG_REPORT             # atserver report socket
ZTE_MC_SOCKET_PATH               # zte_topsw_mc
ZTE_MDM_SOCKET_PATH              # zte_topsw_mdm
ZTE_PRODUCTION_SOCKET_PATH       # zte_production_server_at
sbus_unix_socket                 # SBUS transport
```

Other AT-related binaries: `at_ctl`, `atserver`, `zte_production_server_at`
(registers ATI/CGMI/CGMM/CGMR/GSN/… for production), `zte_cli` (JSON-RPC test
CLI), `zte_topsw_mc`, `zte_topsw_mdm`.

## 3. Usage

Send a single AT command and read the response:

```sh
/usr/bin/zte_topsw_mc atcmd "ATI"
# [net][pid]: recv MSG_CMD_SEND_AT_MSG_RSP, buf:
# ZTE
# G5TS
# BD_IOHIDG5TSV1.0.0B06
# OK
```

To filter the `[net]` log prefix:

```sh
/usr/bin/zte_topsw_mc atcmd "AT+CSQ" 2>&1 | grep -v '^\[net\]'
```

`zte_topsw_mc` has no useful `--help`; the `atcmd` subcommand is discovered from
the strings `zte_topsw_mc atcmd "at^ramdump"` / `zte_topsw_mc atcmd
AT+ZSET=\"EXCEPT_RESET\"` and verified live.

A helper script wraps this — see `atcmd.sh`:

```sh
./atcmd.sh "ATI"          # single command
./atcmd.sh                # interactive prompt
./atcmd.sh -f cmds.txt    # batch (one AT command per line, # comments ignored)
```

## 4. Observed results (read-only)

### 4.1 Identity & SIM

| AT command | Response | Meaning |
|---|---|---|
| `ATI` | `ZTE / G5TS / BD_IOHIDG5TSV1.0.0B06` | manufacturer / model / firmware |
| `AT+CGMI` | `ZTE` | manufacturer |
| `AT+CGMM` | `G5TS` | model |
| `AT+CGMR` | `BD_IOHIDG5TSV1.0.0B06` | firmware revision |
| `AT+CGSN` | `869338073556874` | IMEI |
| `AT+CIMI` | `510019420081428` | IMSI |
| `AT+CNUM` | `+6285894010079`,145 | MSISDN (own number) |
| `AT+CPIN?` | `READY` | PIN status |

### 4.2 Network / operator

| AT command | Response | Meaning |
|---|---|---|
| `AT+COPS?` | `0,2,"51001",7,1` | operator 51001 (Telkomsel), LTE |
| `AT+CREG?` | `2,1,"09CE","01FD7E20",7,1` | registered, home network |
| `AT+CEREG?` | `2,1,"4F7E","01FD7E20",7,1` | EPS registered, home |
| `AT+CGPADDR` | `1,"100.5.131.128"` | PDP IP address |
| `AT+CGCONTRDP` | `1,5,"hifiair.MNC001.MCC510.GPRS","100.5.131.128…"` | active PDP context |
| `AT+CGACT?` | `1,1` | PDP context 1 active |
| `AT+CGATT?` | `1` | PS attached |
| `AT+CGDCONT?` | `1,"IPV4V6","hifiair",…` | APN profile (`hifiair`) |

### 4.3 Signal / RF

| AT command | Response | Meaning |
|---|---|---|
| `AT+CSQ` | `156,99,17` | RSRP / SINR (very good) |
| `AT+ZRSSI` | `-63,4,-61,8` | RSSI -63 dBm primary / -61 diversity |
| `AT+ZRFSQ` | `51,13,6,56,17,14,63,87,…` | RSRP/RSRQ/SINR per antenna |
| `AT+ZSINR` | `6,9,6,0,14,2,8,0` | SINR per stream |
| `AT+CESQ` | `99,99,255,255,25,55,…` | RSRP=25, RSRQ=55 |

### 4.4 Band configuration

| AT command | Response | Meaning |
|---|---|---|
| `AT+ZBAND?` | `3,1` | band mode |
| `AT+ZLTEBAND?` | `133,0,0,8,0,0,0,0,0` | LTE band bitmap |
| `AT+ZNRBAND?` | `1,28,41,78` | 5G NR bands |
| `AT+ZGSMBAND?` | `0` | GSM band |
| `AT+ZFDDBAND?` | `0,0,0` | FDD band |
| `AT+ZMODE?` | `0` | network mode |

### 4.5 Misc

| AT command | Response |
|---|---|
| `AT+ZMMI?` | `1` |
| `AT+ZGAAT?` | `0` |
| `AT+ZNCELLINFO?` | `(empty)` |
| `AT+CEER` | `OK` (no pending error) |

## 5. Supported AT command set (ZTE proprietary)

Extracted from `zte_topsw_mc`, `zte_topsw_nwinfo`, `zte_topsw_data` strings —
this modem speaks the **ZTE `AT+Z…` set**, not the Qualcomm `AT+Q…` set
(`AT+QENG`/`AT+QRSRP`/`AT+QSINR` all return `+CME ERROR: invalid command`).

Standard: `CEER`, `CEREG`, `CESQ`, `CFUN`, `CGACT`, `CGATT`, `CGCONTRDP`,
`CGDCONT`, `CGREG`, `COPS`, `CREG`, `CRSM`, `CPIN`, `CNUM`, `CGPADDR`.

ZTE `Z…`: `ZBAND`, `ZDUALCONN`, `ZEACT`, `ZEMSCIQ`, `ZFDDBAND`, `ZGAAT`,
`ZGACT`, `ZGPCOAUTH`, `ZGPCOAUTHCHK`, `ZGSMBAND`, `ZLOCKCELL`, `ZLTEBAND`,
`ZMMI`, `ZNCELLINFO`, `ZNEBCSCH`, `ZNRBAND`, `ZNRLC`, `ZPLMNINFO`, `ZRFSQ`,
`ZRSSI`, `ZSET`, `ZSINR`, `ZUEINFO`.

## 6. Alternative paths (not exercised)

1. **`zwrt_sbusd.manager` (ubus)** — `msg_parse` accepts a raw `msg_buf` to the
   modem over SBUS (`ubus call zwrt_sbusd.manager msg_parse …`). Lowest-level
   injection point.
2. **`zte_cli`** — `zte_cli [-u] moduleName testName [param]`; valid modules
   include `zwrt_mc`, `zwrt_data`, `zwrt_sbusd`, `zwrt_nwinfo`, `zwrt_apn`,
   `zwrt_router`.
3. **`zwrt_mc.device.manager` (ubus)** — `fac_open` (`facPwd`), `fac_query`,
   `fac_close` factory-mode access; `device_mesh_proc` carries an opaque `data`
   field.
4. **`adbd`** on `127.0.0.1:5037` — ADB daemon is listening (alternate channel
   to the device/module).

## 7. Safety notes

* Write-class AT commands (`AT+CFUN=…`, `AT+ZBAND=…`, `AT+ZSET=…`,
  `AT^RESET`, `AT+CRSM=…`, band unlock, factory reset) **mutate modem state**
  and can drop the connection, change bands, or reset the device. They were not
  run.
* `at_ctl` is a single-instance daemon; don't kill it (a live data session may
  depend on it).
* All observations in §4 were made on an owned test device; identifiers are the
  operator's own (see project `DISCLAIMER.md`).

---
*Documented from a device with root access established via
`docs/WRITEUP.md`.*
