# Final hardware readiness: reverse-engineering and adversarial-review phase

Date 2026-11-21. **No physical AX23 was used, flashed or connected.** Evidence labels:
**PHYS** verified on our physical AX23 (none) · **ID** identical hardware ·
**REL** related hardware · **OEM/SRC** OEM/source analysis · **BUILD** build or static
analysis · **SIM** simulation only · **UNV** unverified. HW-3P (AX21 v5 running AX23 v2
firmware) is reported as REL, since it is not proven electrically identical to the EU AX23.

## Deliverable
`artifacts/ram-only/dev/openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`
sha256 `f9aeb6987e5181d191c32b271de9faa890af137b5d01efe740b0f433b0d7c8c4` (`13,329,084` bytes): patches 0001–0027 plus EU board data
generated from TP-Link's signed 1.2.1 image (local only, not committed). **RAM boot
only.** Validator: 80 checks PASS, 0 FAIL. `tools/fit-verify.py` confirms the FIT
hashes and `config@mp02.1`. Board data repacked with 2 explicit variant-qualified keys
(no unqualified fallback); `board2.py scoped --eu` PASS both radios. Rebuild:
`tools/bdf/board-data-from-tplink-firmware.sh` then `tools/build-dev.sh --variant dev`.

## What this phase changed (each is a commit)
| Change | Why | Evidence |
|---|---|---|
| board-2.bin packed with **two explicit variant-qualified keys** (255 and 36/96); no unqualified fallback | an unqualified `bus=ahb,qmi-chip-id=0` fallback could silently serve wrong board data to any radio with an unmapped OTP id | SRC, BUILD (`board2.py scoped --eu` PASS both radios) |
| ~~board-2.bin resolves for any OTP board id~~ **superseded:** board-2.bin carries exactly two variant-qualified keys (OTP 255 and the stock selector 36/96) and no fallback | the earlier chip-id fallback served any OTP silently; stock CNSS loads the DT selector whatever the OTP says (OEM binary), so an unknown OTP is now reported (selfdiag S3.20) and fixed by adding that exact id | OEM binary + SRC + BUILD (`board2.py scoped --eu`); see `final-rf-compatibility-audit.md` |
| **0016** wcss-sec: no inline coredump | Q6 crash held both radios down 5 min | SRC + REL (IPQ6018 HW), main `b97760cbc9` |
| **0017** `ax23_radios=` bring-up profiles | isolate each radio and the simultaneous start-up memory peak on the first boot | BUILD, 10/10 logic tests |
| **0018** RX rings aligned with the reference profiles | 0002 had two unreferenced values | SRC review |
| **0019** ath11k: unwind descriptor banks owned by the caller | partial allocation freed the global WBM array instead of the per-radio arrays | SRC (Codex) |
| **0020** skip implicit UBI data attach on AX23 RAM target | prevents unintended probe of a non-essential partition | SRC (Codex) |
| **0021** report incomplete radio holds; keep 5 GHz held on 2.4 GHz start failure | a failed 2.4 GHz start previously released the 5 GHz hold silently | BUILD, 13/13 logic tests (Codex) |
| **0022** release WBM idle ring and earlier TX FIFOs on DP setup failure | pre-allocated rings leaked on partial startup | SRC (Codex) |
| **0023** preserve per-unit factory regulatory calibration in both ART segments | 0001 caldata fix must not clear factory regulatory words from the RAM copy | SRC + BUILD caldata test (Codex) |
| **0024** hold IPQ5018 CMN PLL bus clocks past initial probe | premature clock disable on the AHB path | SRC (Codex) |
| **0025** wait for RTL8367S-VB chip and SerDes reset to settle | correct chip/PCS settling intervals for the family-D switch | SRC + REL (Codex) |
| **0026** Q6 MPD recovers user PDs with the root PD; failed start/load unwind | a root-PD restart left both radios down until reboot; leaked MSA lock and root reference | SRC + SIM 8/8 (`q6-mpd-recovery-audit.md`) |
| **0027** ath11k DP rings at exact size | 7-byte alignment slack doubled every power-of-two ring: ~0.9 MiB contiguous per radio, idle ring order 7, REO dst order 6 | SRC + SIM (`high-order-dma-audit.md`); order-9 link banks unchanged, hardware measurement defined there |
| Self-diagnostic: UBI-ro, remoteproc/coredump, driver binding, firmware/board lines, slab, `--bundle` | first boot must yield a complete, redacted evidence bundle | BUILD lint + SIM (twin S06, earlier version) |
| NAND write-path audit | every kernel write path ends at `-EROFS` or does not run in initramfs | SRC/BUILD |
| Memory budget corrected | link-descriptor banks (2 × order-9 per radio, 8.6 MiB) had been omitted | SRC |

## Executive answers (15)
1. **What did reverse engineering the TP-Link firmware teach us?** The OEM runs both
   radios in FW memory mode 2 with caldb off, selects board data by **DT** board_id
   (0x24/0x60, TP-Link edits of the reference DT), and auto-restarts the Q6 on crashes.
   Its stock SSH grants no shell (root locked, tunnel-only accounts), and its web flasher
   RSA-verifies with the same keys as U-Boot. Its `ess-switch1` reset GPIO describes a
   QCA8337 the board does not have. **OEM/SRC.**
2. **Which OEM differences mattered?** (a) board_id from DT vs OTP (fixed); (b) Q6 auto-restart vs our
   inline-coredump hold (fixed, 0016); (c) switch reset GPIO 26 vs our 39 (measure
   first); (d) second boot-args tuple for an absent UPD3 radio (deliberately omitted).
   **OEM/SRC.**
3. **Most useful other router?** OpenWrt main's qualcommax/mac80211 work since our base
   (coredump fix, ath11k/mac80211 fixes), then **EX511 v2** (the only other 256 MiB
   IPQ5018+QCN6122+RTL8367S-VB board with both radios on: mode 2 both radios, 2.5 G
   trunk failure with our exact family-D code), then **MR80X v2** (GPIO-26 switch reset,
   ECC-context fix, HSGMII race). **REL.**
4. **Upstream commits incorporated:** `b97760cbc9` (0016); `5062c68dfd` (0013); patch
   files from `fe0aacd956` and `24c13d794c` (0014); #26597 `ee6860ee0f`, `59f295f58f`,
   `62792fff96`, `5e086c964e` (0006–0009). Rejected with reasons: `cb0ed8006f`,
   `b7afc4baab`, `83c58ae10f`, `f9c89becc3`, kuncy7 0828 (`cross-device-fix-inventory.md`). **BUILD.**
5. **Serious bugs found in our own work:** R1 board-2.bin single OTP entry (high), R2
   5-minute Q6 recovery hold (high), R3/R4 unreferenced RX ring values, R6 likely wrong
   switch reset line, R7 a wrong claim in an earlier report, R10 omitted link-descriptor
   memory (`independent-patch-review.md`). **OEM/SRC.**
6. **Which were fixed?** R1, R2, R3, R4, R5, R7, R9, R10 (budget/claim). Not changed on
   purpose: R6 (needs a hardware measurement; HW-3P works with 39) and R8 (cosmetic).
   **BUILD.**
7. **Are the Qualcomm radios as prepared as possible?** Yes, for offline methods. Every
   step up to "board data loaded" is backed by HW-3P logs or exact source and address
   arithmetic, and the board-id failure mode is closed. DP allocation, regd, beaconing
   and clients remain **UNV** on hardware (`ath11k-final-hardware-readiness.md`).
8. **Low-memory implementation fully audited?** At source level, yes: TX ring
   (order-9 → order-5), RX rings aligned with the references, and the remaining
   order-9 link-descriptor banks now in the budget (host DMA ≈ 19 MiB both radios;
   idle projection 75–90 MiB, **HYP**). Physical fragmentation is **UNV** until
   M.3/M.4/M.10 run on the device.
9. **Both radios concurrently feasible?** Supported, not proven: EX511 v2 runs both
   radios on 256 MiB with mode 2 and the same link-descriptor banks (**REL**); RE700X's
   author tested the same low-memory approach (**REL**); our host DMA is lower than
   either baseline (**SRC**). `ax23_radios=seq` exists if simultaneous start-up is the
   problem. **UNV on our unit.**
10. **All RAM-boot NAND write paths protected?** Yes, by the kernel (MTD
    `-EROFS` on erase/write/OOB/markbad; UBI read-only mode; no partitioned master; no
    `mtdparts=`), and the overlay/upgrade paths don't run in initramfs. **OEM/SRC +
    BUILD**; the UBI behaviour is also **SIM**. On-device confirmation: selfdiag S1.8/S1.15.
11. **Legitimate UART-free installation?** **No.** Web flasher and U-Boot both
    RSA-enforce; stock SSH gives no shell; telnet is disabled; the TDDP factory
    interface is excluded. RE700X/MR80X methods rely on keyless loaders the AX23 doesn't
    have. **OEM/SRC.** UART-free **stock recovery** exists by design (**UNV** on HW).
12. **Physical risks that remain:** 2.5 G trunk passing no frames (seen on EX511/MR80X);
    order-9 link-descriptor allocations failing at start-up; regd rejection of the
    EU 5 GHz BDF; Q6 FW 2.7 behaviour over time; switch reset determinism; 1.8 V UART
    wiring mistakes (the only risk to the hardware itself, and avoidable).
13. **Observation that resolves each:** S2.4 frames on eth0 both ways; S3.8/M.4/M.10
    under `seq` vs `both`; S3.7 no "regd update : -22"; 24 h with S3.13 = 0 crashes;
    20× cold/warm boot + GPIO-26 variant; a multimeter reading of the router TX idle
    at ~1.8 V before connecting.
14. **Safest next practical step:** Stage 0 (`physical-hardware-test-plan.md`):
    hold reset at power-on and confirm the U-Boot recovery page **without uploading**.
    It needs no UART and no tools, writes nothing, and proves the way back to stock.
    Then Stage 1–3 with a 1.8 V-safe UART (a 1.8 V-capable USB-UART on the Pi, or a
    level shifter) and the read-only self-diagnostic bundle.
15. **Keep the router as a development device?** **Yes, if** the owner accepts opening
    the case for a 1.8 V-safe UART for the first boot. Every offline question that could
    be closed is closed, and the remaining ones each have a single, read-only
    observation on the bench. **If UART is unacceptable, no** (there is no UART-free
    install), so return it unopened.

## Source-tree changes after this image
- Wi-Fi compatibility audit: `final-rf-compatibility-audit.md` (stock CNSS ignores OTP when the DT selector is set; the stock EU BDFs show the zeroed target-power pattern that capped AX55 v1 at 13 dBm). Selfdiag S3.20 (OTP board id per radio), S3.21 (AP TX power) and the S3.7 extension are streamed at test time, so no rebuild is needed.
- `ax23-selfdiag.sh` S2.8 (GPIO 26/39 claim and mux, read-only) and the 1 G SGMII trunk variant (`patches/variants/trunk-1g-sgmii.patch`, BUILD-checked, not in `series`) were added after the image above. The self-diagnostic is streamed from the checkout at test time, so S2.8 works with this image without a rebuild, but it was not part of the validated test set. Neither changes executable firmware code, so the image and its SHA256 stay as stated.

## Stage status
| Stage | Status |
|---|---|
| **A** offline engineering readiness | **COMPLETE**: image integrity (FIT hashes, config), correct firmware/board files (OTP 255 + stock selectors 36/96; unknown OTP reported by S3.20), valid DTB (51 checks incl. 16 read-only partitions), source-level memory audit, upstream fixes, build, focused tests (7 unit suites + static + NAND lab + twin), RAM-boot safety audit, remaining uncertainty documented |
| **B** physical functionality | **NOT STARTED**: needs the unit + UART |
| **C** physical stability | **NOT STARTED** |
| **D** persistent installation | **BLOCKED** by design until B/C pass and the owner separately authorizes |

## Final verdict: **CONDITIONAL GO**
Condition: the owner accepts a **1.8 V-safe UART** for the first RAM boot. With it, the
next step is a bench session whose success criteria, profiles and diagnostics are fully
prepared. Without it: **NO-GO** for this owner (no legitimate UART-free route exists).
No physical stage is claimed complete.
