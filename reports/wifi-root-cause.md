# Wi-Fi root cause: ath11k `-12` on the Archer AX23 v2 (IPQ5018 + QCN6122)

Status: **root cause identified and fixed in the image; NOT VERIFIED ON REAL HARDWARE.**
Supersedes the analysis part of `wifi-investigation.md` (which remains valid; this
report adds the vendor-source and official-firmware evidence obtained on 2026-11-21).

Evidence labels: **HW** verified on real hardware · **STATIC** verified by static analysis ·
**QEMU** verified only in QEMU · **3P** reported by a third party · **HYP** hypothesis ·
**UNV** unverified. All "3P" hardware logs are Veraxis' AX21 v5 (US) running AX23 v2
firmware (forum t/254876); no EU AX23 v2 has been tested by anyone.

## 1. Fault tree

```
"failed to load board data file: -12" (both radios)            [3P log]
├── A. Q6/remoteproc or userPD failed ............................ RULED OUT
│     userpd 2 spawned, QMI host-cap + target-mem negotiated for both  [3P log]
├── B. Firmware API/version mismatch ............................ RULED OUT for reaching BDF stage
│     FW answers QMI and requests BDF                                   [3P log]
├── C. Genuine memory allocation failure (ENOMEM) ............... RULED OUT for this log
│     the four "failed to fetch board…/board.bin" lines are printed only after
│     every lookup incl. board.bin failed; kzalloc failures return before them [STATIC: core.c:1891-1985]
├── D. Board-data parse error (bad magic/length) ................ RULED OUT
│     would print "found invalid board magic"/"invalid length…" (-EINVAL)  [STATIC]
├── E. Board name mismatch inside an existing board-2.bin ....... RULED OUT as the cause
│     no AX23 board-2.bin is installed at all                           [STATIC: image contents]
└── F. Missing board file → user-helper fallback returns -ENOMEM  CONFIRMED
      F1 DEVICE_PACKAGES had no ipq-wifi package ..................... [STATIC]
      F2 no public board-2.bin contains variant=TP-Link-Archer-AX23-v2  [STATIC]
      F3 procd answers a missing file with loading=1/0, no data;
         firmware_loader/fallback.c: is_paged_buf && !data → -ENOMEM    [STATIC: procd 2026.10.07 plug/hotplug.c; linux 6.18.55]
```

## 2. Exact path of `-12` (file by file)

| Step | File / function | Behaviour |
|---|---|---|
| 1 | `ath11k/qmi.c: ath11k_qmi_event_load_bdf()` → `ath11k_qmi_load_bdf_qmi()` | runs after the FW reported chip_id/board_id over QMI |
| 2 | `ath11k/core.c: ath11k_core_fetch_bdf()` | tries board-2.bin with `…,variant=TP-Link-Archer-AX23-v2`, then without variant, then `bus=ahb,qmi-chip-id=0`, then `board.bin` |
| 3 | `core.c: ath11k_core_firmware_request()` → `firmware_request_nowarn()` | file not on disk → sysfs user-helper fallback (`CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y`, `FW_LOADER_PAGED_BUF=y` in `target/linux/generic|qualcommax/config-6.18`) |
| 4 | procd `plug/hotplug.c: handle_firmware()` | `stat()` fails → writes `loading=1`, nothing, `loading=0` |
| 5 | `drivers/base/firmware_loader/fallback.c:127-131` (6.18.55) | `else if (fw_priv->is_paged_buf && !fw_priv->data) retval = -ENOMEM;` |
| 6 | `core.c` prints the 4 "failed to fetch…" lines; `qmi.c` prints `qmi failed to fetch board file: -12` and `failed to load board data file: -12` | matches the 3P log exactly |

## 3. Board identity, now fixed by vendor evidence

| Item | Value | Source |
|---|---|---|
| Name ath11k requests (both radios) | `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2` | 3P log (board-id 255 = OTP unprogrammed) + STATIC |
| Stock board selection | QSDK DT `qcom,board_id`: IPQ5018 `0x24`, QCN6122 `0x60` → `bdwlan.b24`, `qcn6122/bdwlan.b60` | STATIC: TP-Link firmware 1.2.1 FIT `fdt@mp02.1` (the config U-Boot boots, 3P log) |
| Region overlay | stock preinit copies `/EU/default/*` then `/EU/$HW_VER/*` over `/` for special_id 45550000 | STATIC: stock rootfs `/lib/preinit/91_init_for_tp_qca` |
| EU board data | `EU/{default,00000001}/…/bdwlan.b24` sha256 `35b9f902…`; `…/qcn6122/bdwlan.b60` sha256 `722e3aee…` | STATIC: identical in all four official releases 1.0.1, 1.0.2(EU), 1.1.2(EU), 1.2.1 |
| Region differences | 2.4 GHz file identical for EU/EG/TW/CA-default; **5 GHz differs per region** (EU `722e…`, CA `88d0…`, TW `a474…`) | STATIC |
| Related public board | AX53 v2 public 2.4 GHz file == AX23 `CA/00000001/bdwlan.b24` (`8d1f4551…`) | STATIC; AX53 v2 working: 3P (kuncy7 tree) |

Official firmware integrity: all four images verify against TP-Link's public keys taken
from TP-Link's GPL U-Boot (`lib/nvrammanager/nm_fwup.c`): RSA-1024 PKCS#1/SHA-1(MD5)
for 1.0.x, RSA-2048-PSS/SHA-256 for 1.1.2/1.2.1; a 1-bit change is rejected
(`tools/bdf/tplink-fw-unpack.py`).

## 4. Radio configuration vs TP-Link's own DTB (STATIC)

| Property | TP-Link stock (`fdt@mp02.1`) | Our DTS | Verdict |
|---|---|---|---|
| 2.4 GHz rproc / userpd | `q6v5_wcss_userpd1` | `q6_wcss_pd1` | match |
| 5 GHz userpd | `q6v5_wcss_userpd2` | `q6_wcss_pd2`, `q6v5_wcss_userpd2` | **match** (AX55 v1 uses pd3 — not applicable here) |
| FW memory mode | `tgt-mem-mode = 2` both | `qcom,ath11k-fw-memory-mode = <2>` both | match |
| boot-args | `<1 4 3 0x0f 0 0>, <2 4 2 0x1b 0 0>` | `<2 4 2 0x1b 0 0>` | subset; the 5 GHz tuple (PCIE1/UPD2/GPIO27) is present and 3P logs show userpd2 up. Second tuple kept as a fallback **only** if UPD2 fails on HW |
| BDF/M3 addresses | QSDK layout (0x4c000000/0x4cc00000) | OpenWrt layout inside `q6_region` 0x4b000000+48 MiB | different driver, self-consistent; reached BDF stage on HW (3P) |
| Firmware | stock WLAN.HK.2.5.r4-00622 | ath11k-firmware WLAN.HK.2.7.0.1-01744 | newer; BDFs from 2.5-era stock work with 2.7 on sibling boards (3P: AX53 v2, AX55 v1 upstream) — **HYP for AX23** |
| Calibration (per unit) | `/lib/read_caldata_to_fs.sh` from ART | `11-ath11k-caldata`: ART+0x1000 / +0x26800, 0x20000 each, read-only | offsets same as stock script per Sply (STATIC by Sply, not re-run here); ART never written |

## 5. Fixes in the image

| Patch / change | What | Evidence |
|---|---|---|
| `0003` (earlier) | `ipq-wifi-tplink_archer-ax23-v2` package, locally supplied data | STATIC |
| **new** `tools/bdf/board-data-from-tplink-firmware.sh` + `tplink-fw-unpack.py` | reproducibly builds the EU board-2.bin from the official TP-Link download (signature-verified), region-selected exactly as stock does | STATIC; data stays in git-ignored `board-data/` |
| **new image** | dev image now contains both board-2.bin files; validator: `PASS IPQ5018/QCN6122 board-2.bin contains the AX23 v2 variant` | STATIC (`reports/artifacts-dev.txt`) |
| `0001` | caldata regdomain fix | STATIC unit test |
| `0002` | FW-mode-2 host RX rings (~42 MiB less, source estimate) | STATIC (built), HYP (effect) |
| `0010` | hostapd `00` country fix | QEMU (twin) |

No board data from another board or region is used; per-unit calibration is not invented
(it comes from the unit's ART at runtime).

## 6. Expected boot log after the fix (derived from the exact ath11k source in the image)

```
ath11k c000000.wifi: ipq5018 hw1.0
ath11k c000000.wifi: FW memory mode: 2
ath11k b00a040.wifi: Multipd architecture - userpd: 2
ath11k b00a040.wifi: qcn6122 hw1.0
ath11k b00a040.wifi: FW memory mode: 2
ath11k b00a040.wifi: qmi ignore invalid mem req type 10          (benign, seen on 3P HW)
ath11k c000000.wifi: chip_id 0x0 chip_family 0x… board_id 0xff soc_id 0x…   (board_id 0xff seen on 3P HW)
ath11k c000000.wifi: fw_version 0x… fw_build_timestamp … fw_build_id WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1
ath11k b00a040.wifi: chip_id 0x0 … board_id 0xff …
ath11k b00a040.wifi: fw_version 0x… fw_build_id WLAN.HK.2.7.0.1-01744-…
```
and **no** `failed to fetch board data` / `failed to load board data file` lines. Values
marked `…` and chip_family/soc_id are not predictable offline. Then `iw phy` lists phy0
(2.4 GHz) and phy1 (5 GHz) and `/lib/firmware/ath11k/AX23-V2-BOARD-DATA-MISSING` is absent.

Failure signatures to look for next (each with meaning):
- `qmi failed to load CAL data file:cal-ahb-*.wifi.bin` → ART caldata extraction failed (check `/tmp/tp_data` mount and `0:ART` read).
- `failed to fetch board data … ` again → wrong image / package not installed.
- `qmi failed memory request` / `-ENOMEM` *without* the four fetch lines → genuine RAM shortage → see `stability-risks.md`.
- `remoteproc … crash` / `fatal error received` → FW crash; collect `dmesg`, try the second boot-args tuple only then.

## 7. Read-only hardware diagnostics that resolve what is left

One RAM boot of the dev image (UART + TFTP), then over SSH:
```
dmesg | grep -iE 'ath11k|qmi|remoteproc|q6v5'      # compare with §6
iw phy | grep -E 'Wiphy|MHz \['                     # both bands present?
cat /sys/kernel/debug/ath11k/*/fw_stats 2>/dev/null  # optional
free -m; grep -E 'MemAvailable|Slab' /proc/meminfo   # before/after enabling radios
fw_printenv tp_boot_idx                              # read-only (patch 0011)
ssh … sh -s < tests/hardware/router-collect.sh       # H11-H18
```
**The single observation that unblocks Wi-Fi:** whether the two `fw_build_id` lines appear
without any `failed to …board…` line in that first dmesg.

## 8. Acceptance (unchanged — hardware only)

Both radios initialise; 2.4/5 GHz SSIDs broadcast; WPA2 and WPA3 authenticate; DHCP;
LAN/WAN traffic; simultaneous operation; recovery after disconnect/reboot; no recurring
FW crashes — **all NOT VERIFIED ON REAL HARDWARE.** The software path above the driver
for all of these is QEMU-verified (`digital-twin.md`, 48/48 ×3).
