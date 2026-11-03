# NV (Non-Volatile memory) access — ZTE G5TS

Firmware `BD_MEDGEG5TSV1.0.0B06` (modem) · Qualcomm ZX29 SoC. Documented from a
root shell on the device (see `README.md`). All reads below are **read-only**;
no NV item was written, erased, or restored.

## 1. Summary

The device stores configuration in an NV store backed by `libnvram.so`
(`/usr/lib/libnvram.so`, also `/rom/usr/lib/libnvram.so`). Two access paths
exist:

1. **`/usr/bin/nv`** — direct CLI to `libnvram` (`nv_get_item` / `nv_set_item`).
   This is the primary, ergonomic way to read (and, if desired, write) NV.
2. **`AT+ZSET="<PARAM>",<value>`** — modem-side ZTE parameter setter, several of
   which map to NV (e.g. `NV_DELAY_WRITE`).

```
root shell (31337)
      │  /usr/bin/nv get imei          (read-only)
      ▼
  libnvram.so  →  nv_get_item / nv_set_item  →  NV store (876 items)
```

## 2. `nv` CLI

```
usage: nv [get name] [getro name] [set name=value] [show] [erase] [save] [restore]
```

| Subcommand | Effect | Risk |
|---|---|---|
| `nv show` | list all NV items (`name=value`) | read-only |
| `nv get <name>` | read one item | read-only |
| `nv getro <name>` | read one item (read-only variant) | read-only |
| `nv set name=value` | write one item | **write** |
| `nv erase` | clear NV | **write / destructive** |
| `nv save` | persist NV | **write** |
| `nv restore` | restore NV | **write** |

`nv show` returned **876 items**.

## 3. Observed NV items (read-only)

### 3.1 Identity / hardware

| Item | Value |
|---|---|
| `imei` | `869338073556874` |
| `sim_imsi` | `510019420081428` |
| `serialnumber` | `See-IMEI` (placeholder) |
| `SERIAL_TSP` | `1234567890ABCDEF` (demo serial) |
| `hardware_version` / `hw_version` | `ej3B` |
| `product_model` | `MF910W` |
| `fota_models` | `ZTE7520V3` |
| `PID_FACTORY` | `0534` |
| `PRODUCT_TSP` | `DEMO Mobile Boardband` |
| `cr_inner_version` / `cr_version` / `wa_version` | `ZX298501-SDK-V1.01.01.02B36P15U13_7` |
| `zversion` | `K318V1.0.0B03` |

### 3.2 Network / operator

| Item | Value |
|---|---|
| `network_provider` | `INDOSAT` |
| `network_num_oper` | `51001` |
| `network_type` | `LTE` |
| `sub_network_type` | `FDD_LTE` |
| `simcard_roam` | `Home` |
| `sim_zpbic_status` | `no_card` |
| `modem_main_state` | `modem_sim_undetected` |
| `BandLockState` | `UnLocked` |
| `BandLockSet` | *(empty)* |

### 3.3 AT / debug / diagnostic

| Item | Value | Notes |
|---|---|---|
| `cc_at_debug` | `yes` | AT debug enabled |
| `unlock_at_wait` | `0` | AT unlock wait |
| `at_snap_flag` | `3` | |
| `at_select_timeout` | `1000` | |
| `cpIndCmdList` | `+ZMMI+ZURDY+ZUSLOT+ZICCID^MODE+ZPBIC+ZMSRI+CREG+CEREG+CGREG+CGEV` | unsolicited AT indications |
| `usb_devices_factory` | `acm,diag` | factory USB: ACM (AT) + DIAG |
| `usb_devices_debug` | `adb,acm,diag` | debug USB: ADB + ACM + DIAG |
| `usb_devices_amt` | `acm,diag` | AMT USB |
| `usb_acm_num_factory` | `1` | factory ACM count |
| `zcat_mode` | `USB` | modem transport mode |

### 3.4 Credentials exposed (see §5)

| Item | Value |
|---|---|
| `Login` | `admin` |
| `admin_user` | `root` |
| `Password` | `admin` |
| `admin_Password` | `<redacted>` (hash) |

### 3.5 Configuration / misc

`check_roam`, `csq`, `AuthMode_5g`, `wan_apn` (`internet`), `APN_config0…9`,
`ipv6_APN_config1…9`, `blc_wan_mode`, `dhcpEnabled`, `sntp_timezone_index`,
`sntp_default_ip`, `dial_mode` (`auto_dial`), `sms_nv_*` (SMS capacity counters),
`fota_*` (FOTA state/token), `DDNSAccount`, `DDNSPassword`, `MMI_*`, `*_signalbar*`
(signal-bar thresholds), `*_wan_*` (WAN config), `wifi*`, `usb_*`.

## 4. `AT+ZSET` NV-related parameters

Extracted from `zte_topsw_mc` / `zte_topsw_nwinfo` / `zte_topsw_data` strings:

| Parameter | Example |
|---|---|
| `NV_DELAY_WRITE` | `AT+ZSET="NV_DELAY_WRITE",24` |
| `SOFT_VERSION` | `AT+ZSET="SOFT_VERSION",%s` |
| `CA_LEVEL` | `AT+ZSET="CA_LEVEL",%d` |
| `EXCEPT_RESET` | `AT+ZSET="EXCEPT_RESET",0/1` |
| `RPI_SET` | `AT+ZSET="RPI_SET",0/1` |
| `ZCARDSWITCH` | `AT+ZSET="ZCARDSWITCH",0/1` |
| `MTNET_TEST`, `CMCC_TEST`, `LTE_INFO`, `VOICE_SUPPORT`, `FDD_RELEASE`, `LTE_RELEASE`, `UE_PS_RELEASE`, `QOS_RELEASE`, `TEBS_THRESHOLD`, `ISIM_SUPPORT`, `MANUAL_SEARCH`, … | (see `atcmd_stream5/6` NV items) |

Two NV items — `atcmd_stream5` and `atcmd_stream6` — hold **scripted `AT+ZSET`
sequences** applied to the modem at init (e.g. `AT+ZSET="MTNET_TEST",1;
AT+ZGAAT=0; AT+ZSET="LTE_INFO",6348; …`). These are the modem-side
initialization blobs.

## 5. Security notes

* **Plaintext/weak credentials in NV.** `Login=admin`, `Password=admin`,
  `admin_user=root`, and a non-encrypted `admin_Password` hash are readable from
  NV by any local root. See `docs/WRITEUP.md` for the broader exposure model.
* **Factory/debug USB modes** (`usb_devices_factory=acm,diag`,
  `usb_devices_debug=adb,acm,diag`) expose ACM (AT) and DIAG interfaces — these
  are the physical/USB routes to the modem AT and diagnostic channels.
* **Band lock is off** (`BandLockState=UnLocked`) — band configuration is not
  locked on this unit.
* `nv set`, `nv erase`, `nv save`, `nv restore`, and `AT+ZSET="…"` **mutate
  state** and were **not** executed. `nv erase` is destructive.
* Values above are from an owned test device; identifiers are the operator's own
  (see project `DISCLAIMER.md`).

## 6. Related

* `docs/AT_COMMAND_ACCESS.md` — AT command transport and usage.
* `atcmd.sh` — AT command helper (single / interactive / batch).

---
*Documented from a device with root access established via `docs/WRITEUP.md`.*
