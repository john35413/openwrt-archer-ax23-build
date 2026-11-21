# Final hardware readiness: reverse-engineering and adversarial-review phase

Date 2026-11-21. **No physical AX23 was used, flashed or connected.** Evidence labels:
**PHYS** verified on our physical AX23 (none) · **ID** identical hardware ·
**REL** related hardware · **OEM/SRC** OEM/source analysis · **BUILD** build or static
analysis · **SIM** simulation only · **UNV** unverified. HW-3P (AX21 v5 running AX23 v2
firmware) is reported as REL, since it is not proven electrically identical to the EU AX23.

## Deliverable
`artifacts/ram-only/dev/openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`
sha256 `82bc7083ed7fb6eb275aadabccdb7a5c81a88e394bd42b646911963a068023cf` (`13,334,464` bytes): patches 0001–0018 plus EU board data
generated from TP-Link's signed 1.2.1 image (local only, not committed). **RAM boot
only.** Validator: 69 checks PASS, 0 FAIL. `tools/fit-verify.py` confirms the FIT
hashes and `config@mp02.1`. Rebuild: `tools/bdf/board-data-from-tplink-firmware.sh` then
`tools/build-dev.sh --variant dev`.

## What this phase changed (each is a commit)
| Change | Why | Evidence |
|---|---|---|
| board-2.bin resolves for **any OTP board id** (255, OEM 36/96, chip-id fallback) | a programmed OTP would have brought back "failed to fetch board data" | SRC (`ath11k_core_fetch_bdf`), OEM (DT board_id), BUILD gate on the built rootfs |
| **0016** wcss-sec: no inline coredump | Q6 crash held both radios down 5 min | SRC + REL (IPQ6018 HW), main `b97760cbc9` |
| **0017** `ax23_radios=` bring-up profiles | isolate each radio and the simultaneous start-up memory peak on the first boot | BUILD, 10/10 logic tests |
| **0018** RX rings aligned with the reference profiles | 0002 had two unreferenced values | SRC review |
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

## Stage status
| Stage | Status |
|---|---|
| **A** offline engineering readiness | **COMPLETE**: image integrity (FIT hashes, config), correct firmware/board files (any OTP), valid DTB (51 checks incl. 16 read-only partitions), source-level memory audit, upstream fixes, build, focused tests (7 unit suites + static + NAND lab + twin), RAM-boot safety audit, remaining uncertainty documented |
| **B** physical functionality | **NOT STARTED**: needs the unit + UART |
| **C** physical stability | **NOT STARTED** |
| **D** persistent installation | **BLOCKED** by design until B/C pass and the owner separately authorizes |

## Final verdict: **CONDITIONAL GO**
Condition: the owner accepts a **1.8 V-safe UART** for the first RAM boot. With it, the
next step is a bench session whose success criteria, profiles and diagnostics are fully
prepared. Without it: **NO-GO** for this owner (no legitimate UART-free route exists).
No physical stage is claimed complete.
