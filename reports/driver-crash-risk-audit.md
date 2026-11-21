# Driver crash and recovery risk audit

**Codex correction to C1 and section 4.** The AX23 compatible selects qcom_q6v5_mpd.c. Patch 0016 acts on a different driver. Actual MPD recovery and recovery duration require a live event. Capture the driver symlink, state, recovery policy and timestamps passively.

Question: once the router boots, what could make it lose Wi-Fi or crash every few
hours, and what does the image do about it? Labels as in `wifi-root-cause.md`.

## 1. Fixed in this phase
| # | Defect | Effect on the AX23 | Fix | Evidence |
|---|---|---|---|---|
| C1 | Q6 remoteproc (`qcom_q6v5_wcss_sec`, used by IPQ5018) set `RPROC_COREDUMP_INLINE` | after any Q6 firmware assert, recovery waited for an unread devcoredump until the **5-minute** timeout: **both radios down for 5 min per crash**, while hostapd still reported the BSSes as enabled | **0016** = main `b97760cbc9` (coredump disabled by default, recovery immediate) | SRC (our driver line 379) + REL (IPQ6018 HW: WCSS up 0.4 s after the dump was discarded) |
| C2 | ath11k RXDMA error-destination ring cut to 128 (0002) | possible RXDMA back-pressure during RX error bursts | **0018** keeps the default 1024 (all references do) | SRC review |
| C3 | IPQ5018 RXDMA buffer ring 512 (0002), unmeasured | RX overflow drops under 2.4 GHz bursts | **0018** 1024 (ath-next / PR #21495 value) | SRC review |
| C4 | TX completion: `size−1` in-flight frames could strand a completion behind "status_fifo is full" | delayed TX completion + warning spam under load | **0012** bounds the IDR at `size−2` | SRC + model test |

## 2. Fixed in the previous phase (re-verified)
- 0013: ath11k/ath12k `mac_phy_caps` stride heap overflow (CVE-2026-90398/9).
- 0014: ath11k NULL dereference in ahb remove after an incomplete QMI init (the
  exact path a board-data failure takes), init-failure leaks (PM notifier,
  reg_info, service-ready-ext), `dp_srng_setup` leak, `rx_tid` locking, IDR
  mutation during mgmt-TX cleanup, WMI TLV/CSA overreads, IRQ enable imbalance,
  short-mgmt-frame rejection; mac80211 use-after-frees on station/chanctx teardown
  and the oversized-fragment `extra_len` overflow (remotely triggerable by a peer).
- Patch-set integrity: the complete mac80211 patch set (incl. 960/961/962) applies to
  the pristine backports-7.2 tarball with **zero fuzz** (`patch -F0`).

## 3. Remaining risks (cannot be closed offline)
| Risk | Why it remains | Detector on the device | Resolving observation |
|---|---|---|---|
| Q6 firmware 2.7 vs OEM 2.5 behaviour on this board | 2.7 reaches QMI/BDF on HW-3P; full operation never observed | S3.13 (crash lines), S3.15/S3.16 (remoteproc state, coredump mode) | 24 h with both radios loaded, 0 "fatal error received" |
| Concurrent dual-radio start-up memory peak | the TX ring's order-9/order-8 allocations are gone (0012), but **two order-9 link-descriptor banks per radio remain** (upstream design, no reference reduces them; EX511 v2 runs with them) and the start-up overlap is unmeasured | S3.8, M.3/M.4/M.10 | boot with `ax23_radios=seq` vs `both`; compare free order ≥ 8 blocks and allocation failures |
| Regulatory init with the OEM EU 5 GHz BDF | EX511 saw `regd update: -22` with a stock 5 GHz BDF (different region/FEM) | S3.7 | first boot dmesg: no "failed to perform regd update" |
| DFS / channel change on 5 GHz | never exercised (hwsim has no radar) | dmesg/hostapd log | owner: use a non-DFS channel (36–48) first; test DFS later |
| Reassociation leak | twin shows 20/20 WPA3 reconnects (SIM); real firmware peers untested | `soak-monitor.sh` MemAvailable slope | 24 h with periodic client reconnects |
| Switch reset line (GPIO 39 vs 26) | no deterministic reset in Linux | S2.1/S2.4 every boot | 20× cold/warm boots; GPIO-26 variant (`oem-openwrt-differential-analysis.md` §3) |

## 4. Recovery must not hide defects
- 0016 changes only **how long** recovery is blocked. Every crash is still logged
  ("fatal error received", remoteproc crash messages), and `ax23-selfdiag.sh` S3.13
  counts them.
- Not added on purpose: any watchdog that silently reboots or restarts Wi-Fi in a
  loop. A recurring crash must stay visible.
- Debug option for the first bring-up, if a crash happens: `echo inline >
  /sys/class/remoteproc/remoteprocN/coredump`, then read `/sys/class/devcoredump/*/data`
  promptly. Do **not** use `enabled` mode on 256 MiB (it copies the whole Q6 region).
