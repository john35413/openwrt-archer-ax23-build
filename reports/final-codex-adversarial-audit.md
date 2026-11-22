# Codex adversarial audit after 9576d3e

Starting outer commit: 9576d3ea680aabcf9a14eb905c97ad99a7d430b8. The local branch contains an additional diagnostic correction; resolve its final hash with `git log -1`. No new firmware image was built or verified here. The 13,329,084-byte ITB and SHA256 f9aeb6987e5181d191c32b271de9faa890af137b5d01efe740b0f433b0d7c8c4 remain Claude-reported results from a different workspace.

## Confirmed defects

| Severity | Failure | Correction and evidence |
|---|---|---|
| High diagnostic | S2.4 treated nonzero lifetime eth0 RX/TX counters as current two-way trunk traffic. Stale packets could produce PASS after a failed SerDes restart. | tests/hardware/ax23-selfdiag.sh now reports the counters as INFO, requiring a fresh client transfer and before/after counters for the physical gate. VERIFIED BY SOURCE ANALYSIS. |
| Medium diagnostic | S3.22 described byte counts at matching ART/BDF offsets as ART filling a target-power table. The format and field semantics were not established. | Label now says only that ART bytes at BDF offsets are nonzero. It explicitly disclaims RF-power interpretation. S3.20 also no longer tells an operator to add a newly observed OTP ID without board/front-end evidence. VERIFIED BY SOURCE ANALYSIS. |
| High build provenance | Local outer patch series was synchronized through 0027 while the reusable prepared kernel and backports sources were still at 0025. A source inspection could mistakenly treat them as compiled. | Applied existing inner 0821 and 965 patches to the prepared source files. Both passed `patch --dry-run` first. Inner OpenWrt source HEAD is d0e9750. This is source preparation only. The build output must be rebuilt before physical use. VERIFIED BY SOURCE ANALYSIS. |

The only newly committed code change is the diagnostic script in ec07e66. The 0026/0027 preparation is confined to ignored build directories and makes no claim about compiled objects. The original implementation's false S2.4 PASS follows directly from testing cumulative counters. Shell syntax, ShellCheck and the read-only diagnostic test pass after the change.

## Critical source review

**Q6 MPD.** Patch 0026 is present in the prepared `qcom_q6v5_mpd.c`. The remoteproc core processes crash work under its per-rproc mutex. The root starts, increments `boot_gen` and queues user-PD work. The user load path flushes root crash work before booting the root. The queued root worker flushes user crash work before reporting any still-running user with an older generation. The root handler does not synchronously wait for the queued worker, so this examined root/user dependency does not form a closed wait cycle. SCM stop and MSA unlock failure can still leave a user PD offline. A later crash with an OFFLINE user remains outside the automatic recovery path. The mock regression covers eight scenarios but cannot prove IRQ timing, workqueue scheduling or SCM behavior. `bash tests/unit/test_mpd_recovery.sh` passes with the prepared driver and demonstrates failures after reversing 0821. Verdict: source paths are internally consistent for the modeled cases; concurrency safety on physical IPQ5018 remains unverified. VERIFIED BY SOURCE ANALYSIS and VERIFIED IN SIMULATION ONLY.

**ath11k DMA.** The prepared backports source has 965. The ring allocation now requests `entries * entry_size`, and the alignment failure path frees the same allocation size. The model produces 1,184 KiB of listed rings per radio and highest order 6, compared with the documented 2,112 KiB/order 7 before 965. The 2 MiB WBM descriptor banks remain. `python3 -I tests/unit/check_ath11k_ring_alloc.py build/backports-7.2/drivers/net/wireless/ath/ath11k/dp.c` passes. `check_ath11k_cleanup.py` passes on the actual prepared functions with injected allocation failures. The OpenWrt mac80211 package has not been prepared in the local build_dir, so the wrapper `test_ath11k_ring_alloc.sh` skips. Repeated firmware recovery and physical fragmentation cannot be established offline. VERIFIED BY SOURCE ANALYSIS and VERIFIED IN SIMULATION ONLY.

**Ethernet.** The active DTS still selects GPIO 39 for switch reset. Signed OEM evidence identifies GPIO 26 as its Realtek reset and GPIO 39 with the QCA8337 path. Physical continuity is unverified. Patches 0024/0025 keep IPQ5018 CMN bus clocks available and add family-D chip/PCS settling delays. The selected 2.5 G link and optional 1 G variant need a built DTB to check both endpoints. The `test_trunk_variant.sh` wrapper skips because the local prepared tree has no compiled reference DTB. The variant is outside patches/openwrt/series. Keep the current reset mapping pending passive wiring evidence. A RAM boot can use the current baseline only with a known-good recovery path and a plan to stop if the switch fails. VERIFIED BY OEM ANALYSIS, VERIFIED ON RELATED HARDWARE and UNVERIFIED ON OUR PHYSICAL AX23.

**Wi-Fi/RF.** Separate board-2 files, restricted 255/36 and 255/96 identities, EU radio hashes, ART at 0x1000 and 0x26800, 0x20000-byte extraction, preserved factory regulatory words and per-radio MAC derivation are present in source. The extraction ranges do not overlap: first ends at 0x21000 and second starts at 0x26800. Valid offsets and nonzero bytes do not establish firmware acceptance or RF calibration semantics. S3.21 reads `iw dev` configured/reported power; it does not measure emitted RF power. The 13 dBm and target-power hypotheses remain open. VERIFIED BY SOURCE ANALYSIS and UNVERIFIED ON OUR PHYSICAL AX23.

**NAND/RAM.** Configured kernel disables MTD_CMDLINE_PARTS and MTD_PARTITIONED_MASTER and enables MTD_OF_PARTS. Sixteen DT partition flags, UBI implicit attach suppression and the sysupgrade guard are present in the patch stack. Kernel MTD flags provide the write barrier; user-space guards add a separate layer. No local current FIT exists, so selected config, decompressed kernel extent, embedded protections and exact RAM placement cannot be revalidated for this source. A new RAM image must pass the artifact validator, then passive on-device MTD/UBI/cmdline inventory before any wireless activity. VERIFIED BY SOURCE ANALYSIS; compiled result and physical behavior unverified.

## Physical observations required

1. Passively establish whether TLMM 26 or 39 reaches RTL8367S-VB nRESET, including polarity and power-on waveform.
2. During a RAM boot, record current MTD flags and UBI backing device with no write probes; test fresh LAN/WAN traffic and before/after switch and eth0 counters.
3. Record both QMI board IDs, BDF acceptance, calibration response, regulatory flags and each PHY identity separately.
4. Record memory/buddyinfo before each radio and after a natural Q6 recovery. Time both PDs and PHYs across any natural crash.
5. Compare stock and OpenWrt driver-reported power on matching band, channel and country, and measure RF output with suitable equipment before interpreting the target-power tables.

## Gate

**NO-GO for a first RAM boot using the current local artifact set.** No locally verified ITB containing the prepared 0026/0027 source and updated diagnostics exists. After a new build passes FIT, embedded-rootfs and NAND-policy validation, a conditional RAM-boot decision also requires safe console voltage, read-only recovery arrangements and a non-destructive test plan. Physical functionality and daily-use reliability remain unverified.
