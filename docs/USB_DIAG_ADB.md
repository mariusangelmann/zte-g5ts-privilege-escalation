# USB factory/debug, DIAG & ADB access — ZTE G5TS

Firmware `BD_MEDGEG5TSV1.0.0B06` (modem) · Qualcomm ZX29 SoC. Documented from a
root shell on the device (see `README.md`). All operations below were
**read-only** (reading NV, sysfs, process lists, and binary strings). No USB mode
was switched, no `nv set`/`nv erase` was run, no `adb_switch`/`fac_open` was
invoked.

## 1. Summary

The device stores several USB *personality* profiles in NV. Switching between
them (user / factory / debug / amt / cdrom) exposes different USB gadget
functions, including the Qualcomm **DIAG** diagnostic channel and an **ADB**
debug bridge. Both are currently **inactive but configured**:

* USB gadget is not enumerated (`/sys/kernel/config/usb_gadget` empty,
  `enMods=0`, `usbPlug=0`); the modem is normally reached over internal rpmsg /
  SBUS, not USB.
* ADB daemon (`adbd`) is running but **locked** behind an RSA serial check.

## 2. USB modes (NV-driven)

NV items define the USB device composition per mode:

| NV item | Value | Meaning |
|---|---|---|
| `usb_devices_user` | *(empty)* | normal/user mode |
| `usb_devices_factory` | `acm,diag` | AT (ACM) + Qualcomm DIAG |
| `usb_devices_debug` | `adb,acm,diag` | ADB + AT (ACM) + DIAG |
| `usb_devices_amt` | `acm,diag` | AMT mode |
| `usb_acm_num_factory` | `1` | ACM port count (factory) |
| `usb_acm_num_debug` | `2` | ACM port count (debug) |
| `cc_at_debug` | `yes` | AT debug enabled |
| `zcat_mode` | `USB` | modem transport mode |
| `usb_modetype` | `debug` | (in NV `ro`, read-only) |

Mode switching is driven by `zxic_usbCfgMng` (PID 3437) on USB events
(`USBEVENT=usb_user / usb_debug / usb_factory / usb_amt / usb_rfc / usb_yt`) and
exposed over ubus by `zte_bsp_usb_ubus` (PID 6747):

```
ubus call zwrt_bsp.usb set '{"mode":"factory"}'    # or "debug" / "amt" / "user"
```

Gadget functions supported by `zxic_usbCfgMng` (from strings):

```
serial      (CDC-ACM serial / AT)
diag_ser    (Qualcomm DIAG serial)
diag        (Qualcomm DIAG)
phone       (phone / RNDIS)
uac2        (USB Audio Class 2)
```

Related processes:

| Process | PID | Role |
|---|---|---|
| `zxic_drvcommng` | 2604 | bridges `/dev/ttyGS0`, `/dev/ttyGS1` ↔ `at_ctl` (AT over USB) |
| `zxic_usbCfgMng` | 3437 | USB mode / gadget composition manager |
| `zte_bsp_usb_ubus` | 6747 | ubus bridge for `zwrt_bsp.usb` |
| `usb_plug_detect`, `CommUsbLogMonit` | — | kernel threads |

## 3. ADB

| Aspect | Finding |
|---|---|
| Daemon | `/usr/bin/adbd` (PID 5837), `127.0.0.1:5037` (localhost only) |
| Features | `shell:`, `tcpip:`, `root:`, `tcp:`, `/bin/adb_shell` |
| Gate | `/bin/adb_shell` checks `ubus call zwrt_mc.device.manager adb_switch_no_login` |
| Locked? | `adb_switch_no_login` returns empty → **locked** |
| Lock mechanism | locked → run `/usr/bin/zte_encrypt_serial` (RSA / PEM public-key check) |
| Unlock path | `ubus call zwrt_mc.device.manager adb_switch '{"adbSwitchPwd":"…"}'` |

`/bin/adb_shell`:

```sh
#!/bin/sh
export ENV='/etc/adb_profile'
if ubus call zwrt_mc.device.manager adb_switch_no_login 2>/dev/null | grep -q "ok"; then
  verify_flag=0
else
  verify_flag=1
fi
if [ "$verify_flag" = '0' ] && [ "$1" = '-c' ];then
    /bin/sh -c "$2"
elif [ "$verify_flag" = '0' ];then
    /bin/sh
else
    /usr/bin/zte_encrypt_serial
fi
```

`zte_encrypt_serial` links `libssl`/`libcrypto` (`PEM_read_PUBKEY`,
`EVP_PKEY_encrypt`, RSA padding, SHA256) — an RSA-based serial challenge.

## 4. DIAG

| Aspect | Finding |
|---|---|
| `/dev/diag` / `/dev/smd*` / QDSS | **not present** (modem over rpmsg, not USB diag) |
| DIAG gadget funcs | `diag_ser`, `diag` (in `zxic_usbCfgMng`) |
| Transport | `ttyGS0`/`ttyGS1` → `zxic_drvcommng` → `at_ctl` |
| Active? | no (gadget not enumerated) |

When `factory`/`debug` mode is activated, the `diag`/`diag_ser` function would
expose the Qualcomm diagnostic channel over USB — a route to modem NV / EFS.

## 5. NV architecture (supporting findings)

| Component | Detail |
|---|---|
| NV daemon | `nvserver` (PID 2276) — SysV message-queue IPC |
| Library | `libnvram.so`: `nv_get_item`, `nv_set_item`, `nv_delete_item`, `nv_clear`, `nv_reset`, `nv_show`, `nv_commit` |
| NV files | `/etc_rw/nv/main/{cfg,ro}` + `/etc_rw/nv/backup/{cfg,ro}` + `cfg.count` / `ro.count` / `nvshow` |
| Default map | `/etc_ro/nvconfig`: `default_parameter_sys=cfg`, `default_parameter_user=cfg`, `default_parameter_ro=ro` |
| Read-only items | `/etc_rw/nv/main/ro`: e.g. `forcenetcard_type=force_invalid`, `usb_modetype=debug` |
| MTD NV partitions | `nvro` (mtd8), `nvfac`/`nvfac2` (mtd9/10), `nvrw`/`nvrw2` (mtd11/12) |
| Secure boot | `pubkeyhash=cfaadb8c…` (kernel cmdline) |

Kernel cmdline also reveals the full MTD partition table and A/B scheme
(`rootfs`/`rootfs2`, `imagefs`/`imagefs2`, dual `nvrw`/`nvrw2`).

## 6. Security notes

* **`usb_modetype=debug`** is stored in NV read-only (`/etc_rw/nv/main/ro`) —
  the debug USB personality is pre-configured on this unit.
* **DIAG** (factory/debug USB) is a route to modem NV / EFS — physical USB
  access (or a root-triggered mode switch) can open full baseband diagnostics.
* **ADB** is locked behind an RSA serial check; unlock requires `adb_switch`
  with `adbSwitchPwd` or factory-mode access.
* No write, erase, mode-switch, or unlock operation was performed; see
  `docs/NV_ACCESS.md` and `docs/AT_COMMAND_ACCESS.md` for the read-only evidence.

## 7. Related

* `docs/NV_ACCESS.md` — `nv` CLI, `AT+ZSET`, observed NV items.
* `docs/AT_COMMAND_ACCESS.md` — AT command transport and usage.

---
*Documented from a device with root access established via `docs/WRITEUP.md`.*
