# Final Qualcomm Wi-Fi hardware compatibility audit (IPQ5018 + QCN6122)

Scope: the Wi-Fi start-up chain of the Archer AX23 EU V2.0, the stock TP-Link 1.2.1
implementation (signed image, statically analysed) against the image we built from
patches 0001–0027. No router was touched. Nothing extracted was executed, and no
proprietary data or code is in the project.

**Evidence labels**
- **OEM-BIN**: VERIFIED BY OEM BINARY ANALYSIS. This means static disassembly of the stock kernel (CNSS, base `0x81208000`) or the stock modules, and the stock rootfs scripts and data.
- **SRC**: VERIFIED BY SOURCE ANALYSIS of the compiled kernel 6.18.55 / backports 7.2.
- **BUILD**: VERIFIED BY BUILD.
- **SIM**: VERIFIED IN SIMULATION ONLY.
- **REL**: VERIFIED ON RELATED HARDWARE.
- **UNV**: UNVERIFIED ON OUR AX23.

HW-3P is an AX21 v5 running AX23 v2 firmware, the only real logs of this firmware on hardware. It counts as REL.

## 1. Stage-by-stage comparison
| Stage | OEM implementation | Ours | Difference | Risk | Correction | Evidence | Hardware measurement |
|---|---|---|---|---|---|---|---|
| Root Q6 + user PDs | QSDK PIL `qcom,ipq5018-wcss-pil`, boot-args via SMEM 0x1fb, `qca,auto-restart` on all PDs | MPD driver `qcom,ipq5018-q6-mpd`, boot-args tuple 2 (pd-2 PCIE1/gpio27), 0026 respawns user PDs after a root restart | different loader, same ABI path | low | 0026 (earlier) | OEM-BIN + SRC + REL (HW-3P: pd-2 up, QMI reached) | S3.15, S3.19 |
| Firmware | `WLAN.HK.2.5.r4-00622` (q6 multi-PD image + `qcn6122/m3_fw`) | `WLAN.HK.2.7.0.1-01744` (`ath11k-firmware-ipq5018-qcn6122`), same split | newer FW, same layout | low | none: not replaced by OEM FW (rule) | OEM-BIN (version strings) + BUILD + REL: the same package ships on 16 OpenWrt IPQ5018 boards incl. TP-Link Archer AX55 v1 and RE700X (IPQ5018+QCN6122), and HW-3P reached QMI/target-cap with it | S3.5 |
| QMI / target capability | CNSS logs `chip_id, board_id, otp_version, fw_version` | ath11k logs `chip_id … board_id …` + `fw_build_id` | equivalent | low | — | OEM-BIN + SRC + REL (HW-3P: `board_id 0xff` both radios) | S3.18, **S3.20 (new)** |
| **Board identification** | **DT `qcom,board_id` overrides OTP** whenever it is not 0xFF: on mismatch CNSS only logs `Boardid from dts:%02x,FW:%02x` and loads `bdwlan.b<dt>`. OTP is used only without a DT entry. AX23 DT = 0x24 / 0x60 → `bdwlan.b24`, `qcn6122/bdwlan.b60`. | ath11k has no DT board-id override. It looks up `qmi-board-id=<OTP>` + variant `TP-Link-Archer-AX23-v2`. Our board-2.bin holds exactly OTP 255 and the stock selector (36/96), with no unqualified fallback. | stock is OTP-independent; ours needs the OTP to be 255 or the selector | **medium until the OTP is read** | kept restricted (no arbitrary ids). New **S3.20** reports an unpackaged OTP with the exact fix: add that id for the same EU payload, which is what stock effectively does. | OEM-BIN (disassembly at `0x81561cd8`); REL: every related board in OpenWrt (AX55 v1, RE700X, GL-B3000) keys both radios at `qmi-board-id=255`, and so does HW-3P | S3.20 on the first boot |
| Board data content | `bdwlan.b24` / `qcn6122/bdwlan.b60` from `EU/00000001` (preinit selects the region) | the same EU payloads (sha `35b9f902…` / `722e3aee…`), checked by `board2.py scoped --eu` | none in selection | — | — | OEM-BIN + BUILD | S3.4 |
| **Target-power tables in that board data** | stock firmware 2.5 on stock QSDK; its output power is not observable offline | same EU files | the AX23 EU b24 has **36 zero runs (1,038 B)** and b60 **41 runs (1,376 B)**, in the offset range where AX55 v1's corrected files carry data | **TX power may be capped**. On AX55 v1 (same selectors b24/b60) kuncy7 measured a **13 dBm** cap instead of 20/23 dBm from such zeroed regions under OpenWrt (`firmware_qca-wireless` `fdccd1e`, `f2c37a6`). Not a start-up blocker. | **not changed.** The AX55 fix used Qualcomm reference values (byte-identical in most regions). TP-Link zeroes the same sub-blocks in every regional variant, deliberately. ath11k passes board data verbatim, so no driver issue is possible. **S3.21** warns at ≤ 13 dBm; **S3.22** counts whether the unit's own ART fills these regions (`tx-power-investigation.md`). | OEM data analysis + SRC + REL (AX55 hardware measurement) | S3.21, S3.22 + the stock-vs-OpenWrt RSSI comparison (`tx-power-investigation.md` §4) |
| Calibration (ART) | preinit copies **raw** ART+0x1000 (131,072 B) → `IPQ5018/caldata.bin` and ART+0x26800 (157,696; 131,072 B) → `qcn6122/caldata_1.bin`. No `compressed_art` in the AX23 DT. Stock keeps an MD5-checked ART backup in tp_data and can rewrite ART. | hotplug `caldata_extract 0:ART 0x1000 0x20000` / `0x26800 0x20000`, read-only MTD, factory regdomain words kept (0023). ART is never written. | identical offsets/sizes; we never write ART | low | — | OEM-BIN (`/lib/read_caldata_to_fs.sh`) + BUILD (built hotplug) + unit-caldata | S3.3 |
| Calibration load order / placement | CNSS: BDF at the DT `bdf-addr`, CALDATA at +131,072 per instance | ath11k: BDF then `cal-ahb-<dev>.bin`; `board_size` 256 KiB, `cal_offset` 128 KiB, `fixed_bdf_addr` | same layout and order | low | — | OEM-BIN + SRC | S3.4 |
| MAC in caldata | stock assigns interface MACs from UCI at runtime | `ath11k_patch_mac` (0xe+6·id, checksum 0xa) + MAC flag 0x3e, label−1 / label−2 | not a calibration difference | low | — | SRC + unit-mac | iw dev addresses |
| Regulatory | TP-Link BDFs carry **no country** (regdomain words 0 in every region variant); the country comes from the unit's ART word, passed raw | ART words preserved (0023); OpenWrt patch 905 drops host intersection ("FW protects the BDF/caldata country"); hostapd country GR (0010) | equivalent | medium (the -22 seen on EX511) | **S3.7** now also catches cfg80211 `Invalid regulatory domain detected` | OEM-BIN data + SRC (weather-radar split is guarded: no zero-width rules) | S3.7, S3.11 |
| Memory mode | `tgt-mem-mode 2` both radios, caldb off | DT `fw-memory-mode 2` both (QCN6122 driver default 1 overridden) | none | low | — | OEM-BIN DT + BUILD validator | S3.6 |
| Chain masks | set only if UCI sets `txchainmask`/`rxchainmask`; stock config sets none → firmware/BDF defaults | ath11k uses firmware-reported chains | none | low | — | OEM-BIN scripts + SRC | `iw phy` antenna info |
| Data path | QSDK wifi_3_0 (2 MiB link-desc chunks, 64 clients) | ath11k mode-2 rings (0002/0012/0018), exact ring sizes (0027) | see `high-order-dma-audit.md` | medium (order-9) | — | OEM-BIN + SRC + SIM | M.3/M.4/M.10 |
| PHY registration / AP | stock wlan ini | two separate `ath11k_base` instances (QCN6122 QMI instance offset by userpd id); first-boot 5 GHz channel = iwinfo default **36 / HE80 (non-DFS)** | none for start-up | low | — | SRC | S3.9, S3.10, S3.12 |

## 2. Radio isolation in the MPD architecture (SRC)
- The two radios share only the root Q6 PD. In the host they are independent `ath11k_base` instances; the QCN6122 path (hybrid bus, its own CE window, QMI instance + userpd id) does not touch the IPQ5018 instance.
- `ax23_radios=2g/5g` holds one platform device before ath11k binds. The held radio's user PD is never spawned; the other PD boots the root. Whether pd-2 runs **without pd-1** has never been observed (**UNV**), which is exactly what `5g` tests.
- A QMI/board-data failure on one radio leaves that radio unregistered and its PD running; the other radio is unaffected. DP allocation failures unwind (0019/0022). A root-PD crash affects both radios and both are respawned (0026).
- `seq` starts 5 GHz only after the 2.4 GHz phy exists, which separates the two firmware-ready DMA bursts. Partial registration is caught by S3.9 (registered phys vs the requested profile).

## 3. Upstream / related-hardware record
| Item | Source | Hardware | Firmware | Problem | Physical evidence | AX23 applicability |
|---|---|---|---|---|---|---|
| BDF identity at `qmi-board-id=255` | `firmware_qca-wireless` `6a0f508` (RE700X), `fdccd1e`/`f2c37a6` (AX55 v1), GL-B3000 files | TP-Link RE700X, Archer AX55 v1, GL.iNet GL-B3000 (IPQ5018 + QCN6122) | ath11k FW 2.7.0.1-01744 | identity / lookup | in use on those boards; AX55 RSSI measurements | supports our 255 key; stock-selector key 36/96 is extra safety |
| Zeroed target-power regions | `fdccd1e`, `f2c37a6` (kuncy7) | Archer AX55 v1 | same | 13 dBm cap | RSSI medians, 30 samples (−48 vs −56 dBm at 2.4 GHz; −61 vs −69 dBm at 5 GHz) | same pattern found in our EU files; **not adopted** (needs AX23-specific evidence; no data substitution) |
| ath11k fixes since base | OpenWrt `fe0aacd956`, `24c13d794c`, `5062c68dfd` | various | — | NULL deref, leaks, stride overflow | upstream | already in 0013/0014 |
| Regdomain intersection removed | OpenWrt ath11k 905 (QSDK) | all ath11k | — | — | upstream | in base; consistent with stock |

No newer OpenWrt ath11k, firmware or IPQ5018 Wi-Fi fix exists since our base; the only remaining one, `83c58ae10f`, is log-level only.

## 4. Changes in this phase
1. **Corrected claims**: the "board data resolves for any OTP board id" statements in `final-hardware-readiness.md`, `oem-openwrt-differential-analysis.md` and `independent-patch-review.md` (superseded since Codex `dd3b5be`; now backed by the OEM CNSS analysis).
2. **Self-diagnostic** (source tree; streamed at test time, not part of the image):
   - S3.20: OTP board id per radio vs the packaged identities.
   - S3.21: AP TX power, warning at ≤ 13 dBm.
   - S3.7: also catches `Invalid regulatory domain detected`.
3. **Defect found and fixed during this work:** the first S3.20 draft used `set --`, which clobbers `$1` and would have silently disabled `--bundle` (read later in the script). It was fixed before commit, and `tests/unit/test_selfdiag_boardid.sh` (`unit-selfdiag-boardid`) now guards against it. The test also runs the real `board_id_check` against ath11k's log format in 7 cases; a reintroduced `set --` is caught.
4. **No firmware, driver or board-data change.** Image `f9aeb698…` (0001–0027) is unchanged and was not rebuilt.

## 5. Final assessment
1. **Correct firmware for both radios?** Yes. `WLAN.HK.2.7.0.1-01744` for the multi-PD Q6 (both user PDs) and `QCN6122/m3_fw`, the same split as stock. Stock's 2.5 is not used, deliberately. Evidence: OEM-BIN + BUILD + REL (16 boards, HW-3P QMI).
2. **Board-data identities correctly scoped?** Yes for the expected case. OTP 255 is what every related board and HW-3P report, plus the stock selector 36/96, with no fallback. Stock ignores OTP when the DT selector is set (OEM-BIN). So if the AX23 reports another value, the correct action is to add exactly that id for the same EU payload. S3.20 detects this on the first boot.
3. **Both ART segments correct?** Yes. Offsets 0x1000 / 0x26800, 0x20000 bytes each, raw (no compressed ART), factory regulatory words kept, read-only. Identical to stock (OEM-BIN + BUILD).
4. **Does the OEM reveal a missing initialisation step?** No missing start-up step. One RF-level gap: the stock BDFs carry zeroed target-power regions which, by the AX55 precedent, cap TX power under OpenWrt's firmware. TP-Link leaves 7–8 % of the target-power tables zero on purpose, in every region; the AX55 fix filled them with Qualcomm reference values. The only acceptable source would be the unit's own ART (S3.22), so this is not fixable without measurement (**UNV**; procedure in `tx-power-investigation.md` §4).
5. **Remaining firmware ABI incompatibilities?** None identified: same board/cal layout (256 KiB / 128 KiB), same memory mode, QMI reached on HW-3P with 2.7. Beyond QMI on this exact unit: **UNV**.
6. **Unresolved 5 GHz regulatory risks?** Partly. The country comes from the unit's ART word, which is kept as stock does. The -22 path can only come from an invalid firmware rule and is now detected (S3.7). DFS/CAC behaviour, 80 MHz on DFS channels and the weather-radar 10-minute CAC are **UNV**. The first boot uses channel 36 HE80, which is non-DFS.
7. **Can either radio fail without disabling the other?** Yes for host-side failures (QMI, board data, DP allocation, registration). No for a root-PD crash, which takes both down; 0026 respawns both.
8. **Defects found and fixed?** The S3.20 `set --` regression (caught before commit, guarded by a test). The outdated "any OTP" claims were corrected. No firmware-code defect was found in this phase.
9. **What cannot be resolved without hardware?**
   - the AX23's actual OTP values;
   - whether FW 2.7 accepts this BDF + ART pair and yields valid ETSI rules;
   - the real TX power (zeroed tables);
   - pd-2 without pd-1;
   - order-9 allocations;
   - DFS/80 MHz behaviour;
   - long-run firmware stability;
   - client association on both bands.
10. **Observations that decide whether both radios work:** in one RAM boot with `ax23_radios=both` (then `seq`, `2g`, `5g` if needed):
   - S3.20 PASS for both devices;
   - two `fw_build_id … 2.7.0.1-01744` lines (S3.5);
   - no `failed to fetch board` / `failed to load board data` (S3.4);
   - no `regd update : -22` / `Invalid regulatory domain detected` (S3.7);
   - no allocation failure (S3.8);
   - S3.9 PASS (both phys registered per profile);
   - `iw reg get` shows the expected ETSI country (S3.11);
   - S3.21 TX power above 13 dBm (or the cap confirmed by comparing RSSI against stock at the same channel);
   - a client associating and passing traffic on 2.4 GHz and on channel 36;
   - S3.13 = 0 crashes over the soak.
