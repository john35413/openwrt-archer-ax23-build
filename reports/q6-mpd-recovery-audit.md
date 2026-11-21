# IPQ5018 Q6 MPD crash and recovery audit

Scope: only the Q6 crash/recovery path of the driver the AX23 actually uses. No router was
touched, and no crash was forced. Evidence labels: **SOURCE** (the exact compiled source
in `build/dev`, kernel 6.18.55 + backports 7.2), **OEM** (TP-Link 1.2.1 firmware/DT),
**BUILD** (built image and validator), **SIM** (host model in
`tests/unit/check_mpd_recovery.py`, not hardware), **REL** (related hardware),
**UNV** (unverified). Nothing here is **VERIFIED ON OUR PHYSICAL AX23**.

## 1. Which driver runs
| Conclusion | Evidence |
|---|---|
| The AX23 DT selects `qcom,ipq5018-q6-mpd`, served by `drivers/remoteproc/qcom_q6v5_mpd.c` (OpenWrt kernel patches 0805–0815, `CONFIG_QCOM_Q6V5_MPD=y`). Patch 0016 changes `qcom_q6v5_wcss_sec.c`, which does not bind on this board (Codex's finding is correct). | SOURCE, BUILD (validator: "IPQ5018 Q6 uses the MPD remoteproc driver") |
| The MPD driver is an unmerged series that OpenWrt carries. Neither it nor wcss-sec is in mainline (`torvalds/linux` master returns 404 for both files). | SOURCE (fetched 2026-11-21) |
| Root PD: wdog, fatal, ready, handover and stop-ack IRQs (`qcom_q6v5_init`). Each user PD (pd-1 IPQ5018, pd-2 QCN6122): fatal, ready, stop-ack and spawn-ack. No wdog. Every fatal/wdog calls `rproc_report_crash()`, and recovery runs on the unbound `rproc_recovery_wq`. | SOURCE |
| ath11k on AHB never power-cycles the rproc after a firmware crash (`reset_work` is queued only by MHI/PCI and debugfs). It sets recovery flags on QMI `SERVER_EXIT` and waits for `SERVER_ARRIVE`. **Wi-Fi returns only if the user PD is respawned.** | SOURCE (`ath11k/qmi.c`, `core.c`, `ahb.c`) |

## 2. Crash-recovery delays
| Conclusion | Evidence |
|---|---|
| **No coredump stall.** MPD registers no dump segments, and `rproc_coredump()` returns at `list_empty(&rproc->dump_segments)`. The 5-minute inline-coredump hold that 0016 fixes for wcss-sec cannot occur here. No change needed. | SOURCE |
| Recovery is bounded by timeouts in the driver: root ≤ 5 s for `wait_for_start`; user PD ≤ 5 s for spawn-ack + ≤ 10 s for start. Actual duration on this firmware is unmeasured. | SOURCE / UNV |
| `qcom_q6v5_request_stop()` skips the SMP2P stop handshake when the rproc is not RUNNING, so a crashed PD's teardown does not wait 5 s for a stop-ack. | SOURCE |

## 3. Defects found and fixed (outer patch 0026 = kernel patch 0821)
| # | Defect in the compiled driver | Consequence | Fix | Evidence |
|---|---|---|---|---|
| M1 | A root-PD restart never respawns the user PDs. Only `wcss_pd_start()` sets a spawn bit, and root recovery restarts only the root. | After a root-PD crash, both radios stay down until reboot, **unless** the firmware also raises each user PD's fatal IRQ (UNV). | Count root-PD starts. After each start, report a crash for every user PD still RUNNING from an earlier root instance (user PDs that already respawned are skipped). | SOURCE; OEM (`qca,auto-restart` on the root **and both** user PDs, i.e. stock restarts all three); SIM S5, S6 |
| M2 | `rproc_boot()` returns 0 for a root PD that is already powered, **even while it is CRASHED**. A user-PD recovery that runs first loads and spawns into the dead Q6 and times out. | That radio stays down permanently (the core does not retry a failed recovery). | Before `rproc_boot(root)`, flush the root's crash work, then refuse to load unless the root is RUNNING. | SOURCE; SIM S4 |
| M3 | `rproc_start()` does not call `.stop` when `.start` fails. A failed spawn or internal-radio power-up kept the **MSA lock** and the **root-PD reference** taken in `.load`, and a failed segment load kept the root reference. | The root PD can never power down; a later `msa_lock` for that PD may be refused. | Unwind in `.start`/`.load`; flags make each release happen exactly once (stop no longer double-unlocks). | SOURCE (`rproc_start`); SIM S2, S3 |

Regression: `tests/unit/check_mpd_recovery.py` extracts the real driver functions and compiles them against a model of the core's `rproc_boot`/`rproc_shutdown` refcounting, crash handler and `rproc_start` semantics (taken from the same source). The **built** driver passes S1–S8. The same file with 0821 reversed fails S2–S6 and S8, and passes the baselines S1 (boot/shutdown) and S7 (user-PD-only crash). Wired into `tools/test-dev.sh` (`unit-mpd-recovery`) and the artifact validator. **SIM**: it models the core, not the firmware.

## 4. Examined and deliberately not changed
| # | Observation | Why unchanged | Evidence |
|---|---|---|---|
| N1 | If a user-PD recovery still fails (e.g. the root crash IRQ arrives more than one spawn timeout late), the core leaves the PD OFFLINE with ath11k's power reference held. The exported API cannot restart it (`rproc_boot` skips at power > 1, `rproc_shutdown` rejects OFFLINE). A reboot is needed. | Fixing it needs a remoteproc-core change (outside scope). Detector: selfdiag **S3.19** (PD not running after a crash). | SOURCE |
| N2 | `wcss_pd_stop()` returns before releasing the root PD if the internal-radio shutdown or MSA unlock SCM call fails. | No evidence these calls fail on this firmware; HW-3P starts both PDs. | SOURCE; REL |
| N3 | Probe error paths: `kfree()` on an `rproc_alloc()` object, clocks left enabled, root left registered if a user PD fails to register (a retry would then fail in `of_platform_device_create`). | Reachable only if user-PD resources defer after the root's succeeded, but they come from the same SMP2P/IRQ providers. HW-3P probes. Not a crash-recovery path. | SOURCE; REL |
| N4 | `cb0ed8006f` (skip MSA lock for pd-1, DR5018S). | Still not adopted: HW-3P runs pd-1 with the lock. It does not affect recovery timing. | REL |
| N5 | A user PD can be both reported by its own fatal IRQ and respawned by M1. | S6 shows no second restart when it respawned first. If its IRQ arrives later, one extra restart can follow (converges). | SIM |
| N6 | User-PD teardown SCM calls can run while the root PD is being reset. | Pre-existing ordering. TrustZone behaviour is UNV. | SOURCE / UNV |

## 5. Research coverage
- OpenWrt main since our base: the only MPD change is `cb0ed8006f` (N4). It has no recovery fixes. **SOURCE**
- Mainline Linux: neither driver is present. **SOURCE**
- Posted MPD series revisions (lore / patchwork / Linaro): blocked by this environment's proxy. Whether a later revision addressed M1–M3 is **UNV**.
- EX511 v2 tree (kuncy7): board overlay only, no Q6 driver. **REL**, nothing to compare.
- OEM: stock DT sets `qca,auto-restart` on all three PDs (QSDK driver, not redistributable here). This shows the intended behaviour (all PDs come back), not the implementation. **OEM**

## 6. The observation that settles it (passive, no forced crash)
On a natural Q6 crash, the redacted `ax23-selfdiag.sh --bundle` shows:
- `crash detected in` lines naming the root and/or the pd-1/pd-2 rprocs (which IRQs the firmware raises);
- `did not survive the root PD restart` (M1 engaged) or `root PD is not running` (M2 refusal);
- S3.15/S3.19: every PD `running` again;
- the time from the crash line to both radios' `fw_build_id`/phy registration.
