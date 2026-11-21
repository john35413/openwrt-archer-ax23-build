# ath11k: final readiness for the first hardware initialisation

Labels as in `wifi-root-cause.md`. HW-3P = AX21 v5 running AX23 v2 firmware
(the only hardware logs that exist). No AX23 EU unit has booted this image.

## 1. Start-up chain, step by step
| Step | What must happen | Our image | Evidence |
|---|---|---|---|
| 1 Q6 root PD boot | `wcss-sec` loads `IPQ5018/hw1.0/q6_fw.mdt` (TZ-authenticated) | ath11k-firmware-ipq5018-qcn6122 (WLAN.HK.2.7.0.1-01744) | HW-3P "Booting fw image … q6_fw.mdt" |
| 2 user PDs | pd-1 (IPQ5018, MSA-locked) and pd-2 (QCN6122) power up; boot-args tell the FW pd-2 = PCIE1/gpio27 | DTS boot-args `<2 4 2 0x1b 0 0>` (OEM tuple 2) | HW-3P "pd-2 is now up"; pd-1 reaches QMI |
| 3 QMI | host-cap, target-mem negotiated for both radios | mode 2 both radios (= OEM) | HW-3P |
| 4 chip/board id | FW reports chip_id 0, OTP board_id | **any OTP value now resolves** | HW-3P board_id 0xff; BUILD `board2.py robust` |
| 5 BDF download | board-2.bin found under the AX23 variant (or fallbacks) | EU b24/b60 from the signed OEM image | BUILD validator (built rootfs) |
| 6 BDF / M3 addresses | inside `q6_region` 0x4b000000–0x4e000000 | 0x4c400000, 0x4d100000 (+128 KiB), m3-dump 0x4df00000 (+1 MiB): all inside | arithmetic (this report); the DR5018S "ioremap error for bdf_addr" mode cannot occur |
| 7 Calibration | caldata hotplug reads ART+0x1000 and ART+0x26800 (0x20000 each, no overlap, within the 1 MiB ART), read-only | `11-ath11k-caldata`, ART read-only (0015) | arithmetic + SRC |
| 8 DP alloc | host rings in mode 2: TX ring now order-5 (0012); **WBM link-descriptor banks still 2 × order-9 per radio** (upstream) | 0002 + 0012 + 0018 | BUILD + model; REL (EX511 runs with the same banks) |
| 9 regdb / country | EU board data, country GR or DE; `00` never passed | 0010, `configs/uci/40-regulatory-gr.uci` | SIM (twin) |
| 10 interfaces | phy0 2.4 GHz, phy1 5 GHz, hostapd up | — | SIM only |

## 2. Re-verifying the `-12` diagnosis independently
The claim: `-12` came from a missing board file (firmware user-helper fallback
returns `-ENOMEM` for a missing paged-buffer file), not from an allocation failure.
- **Ordering proof (HW-3P log + SRC):** `ath11k_core_fetch_bdf()` prints the four
  "failed to fetch board data…/board.bin" lines only after **every** lookup failed.
  A `kzalloc` failure inside it returns *before* those lines, so a log containing
  them cannot come from that allocation. The 3P log has all four lines, 24×.
- **What changed for our build:** the lookups now succeed for any OTP board id
  (BUILD, on the built rootfs). The original missing-file cause is therefore gone,
  *and* the latent variant of it (OTP ≠ 255) is closed.
- **What could still yield an error at this stage:** a different data problem,
  not a missing file. Bad magic gives `-EINVAL` with "invalid board magic"; a regd
  rejection gives "failed to perform regd update : -22" (seen on EX511 with a stock
  5 GHz BDF); a real allocation failure gives `-ENOMEM` **without** the four fetch
  lines. `ax23-selfdiag.sh` S3.4, S3.7, S3.8 and S3.18 separate these on the first boot.

## 3. Isolating failures on the first boot: radio profiles (0017)
Kernel command-line switch, set once at the U-Boot prompt (no `saveenv`):
`ax23_radios=none | 2g | 5g | both | seq`. It holds back the chosen radio(s) from
ath11k via `driver_override` before the module loads (RAM only). Suggested order if
`both` fails: `none` (Ethernet + memory baseline) → `2g` → `5g` → `seq`. Comparing
`ax23-selfdiag.sh` M.* between `seq` and `both` shows whether the simultaneous
start-up peak matters. Logic-tested 10/10 against a fake sysfs (BUILD/test); the
effect on real firmware is UNVERIFIED.

## 4. Things deliberately not changed
- MSA lock on pd-1 (`cb0ed8006f` not taken): HW-3P shows pd-1 running with it.
- Second OEM boot-args tuple (UPD3/gpio15): that radio does not exist; HW-3P runs without it.
- Firmware version: upstream 2.7.0.1 instead of OEM 2.5; HW-3P reaches QMI/BDF with 2.7.

## 5. Verdict
The radios are **as prepared as offline methods allow**. Every step up to "board
data loaded" is backed by HW-3P logs or exact source/arithmetic. The steps after it
(DP allocation on real firmware, regd, beaconing, clients, concurrency) are
VERIFIED BY SOURCE/BUILD or SIMULATION ONLY. The deciding observation is one RAM boot
showing two `fw_build_id` lines, no `failed to … board` line, no regd failure, and
both phys registered (S3.4/S3.7/S3.9/S3.18).
