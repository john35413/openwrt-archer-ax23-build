# Cross-device fix inventory

Every candidate fix found on related hardware, with the decision for the AX23 v2.
Kernel 6.18.55, backports-7.2, ath11k-firmware WLAN.HK.2.7.0.1-01744 unless noted.
"HW-tested" = tested on physical hardware by its author.

| # | Fix | Source (repo @ commit) | Hardware | Problem | HW-tested | AX23 decision | Adaptation / regression risk |
|---|---|---|---|---|---|---|---|
| 1 | wcss-sec: no inline coredump on Q6 crash | openwrt main `b97760cbc9` | IPQ6018 (Arista W-318); same driver on IPQ5018 | recovery waits 5 min for an unread devcoredump, radios down | yes | **ADOPTED (0016)** | none; dumps still selectable via sysfs (don't use `enabled` on 256 MiB: full Q6 dump copy) |
| 2 | ath11k 17 upstream fixes (102–118) | main `fe0aacd956` | ath11k (all) | NULL deref in ahb remove after failed QMI, init-failure leaks, rx_tid locking, mgmt IDR mutation, WMI overreads | upstream review | **ADOPTED (0014)** | files only; full set applies with zero fuzz |
| 3 | ath11k 954–956 + mac80211 484–490 | main `24c13d794c` | ath11k / mac80211 | IRQ imbalance, short mgmt frames, ext-IRQ leak; station/chanctx UAFs, oversized-fragment overflow | upstream review | **ADOPTED (0014)** | as above |
| 4 | mac_phy_caps stride overflow (CVE-2026-90398/9) | main `5062c68dfd` | ath11k/ath12k | heap overflow on short TLVs | compile-tested | **ADOPTED (0013)** | none |
| 5 | Low-memory DP rings | ath-next proposal (Eduard Hart, 2026-09-30), PR #21495 | IPQ5018+QCN6122 RE700X (256 MiB) | dual-radio OOM on 256 MiB | author's RE700X | **ADAPTED (0002+0012+0018)** | fw_mem_mode selector; IDR size−2; RX buf 1024 / err-dst default (aligned in 0018) |
| 6 | fw-memory-mode 2 on both radios | kuncy7 `092adeb` (EX511 v2 DTS) | IPQ5018+QCN6102+RTL8367S-VB, 256 MiB | mode 1 OOM-panics with both radios | yes | **ALREADY (DTS)** | — (also matches OEM DTB) |
| 7 | UNIPHY probe-time programming | openwrt PR #26597 (`5e086c964e` + 3 prereqs) | IPQ5018 + RTL8367S | cold-boot 2.5 G trunk race | yes (forum) | **ALREADY (0006–0009)** | — |
| 8 | spi-qpic-snand ECC context publish | backport `441-v7.4` | qpic SPI-NAND (MR80X v2) | ~50 % boots "Waiting for root device" | yes | **ALREADY in base** | — |
| 9 | Skip MSA lock for the IPQ5018 internal radio | main `cb0ed8006f` | Wallys DR5018S | FW rejects MSA lock (-EINVAL), pd-1 offline | yes | **NOT ADOPTED** | HW-3P AX23 logs show pd-1 running with the lock (`c000000.wifi` reaches QMI, fw_build_id, board_id 0xff); the fix would change a validated path. Re-evaluate only if S3 shows "failed to power up pd" for pd-1 |
| 10 | Switch reset on `&mdio1` GPIO 26 | main MR80X v2 DTS (`938f67a519`) | IPQ5018 + RTL8367S, 256 MiB | deterministic switch reset | yes | **CANDIDATE, measure first** | OEM evidence favours 26 over our 39 (`ethernet-initialization-comparison.md`) |
| 11 | Trunk at 1 G SGMII both ends | EX511 v2, MR80X v2 | RTL8367S(-VB) | 2.5 G link up with no frames | yes | **FALLBACK variant** | only if S2.4 fails on our unit |
| 12 | `coherent_pool=512K` + Q6 loader GFP_KERNEL | kuncy7 patch 0828 (EX511) | IPQ5018 256 MiB | 8 MiB of atomic DMA pools | yes (their vendor MPD loader) | **NOT ADOPTED** | our Q6 loader differs; measure `/sys/kernel/debug/dma_pools` on HW first (`real-memory-budget.md` §4) |
| 13 | Board data keyed by OEM DT board_id, not OTP | OEM behaviour (stock loads bdwlan.b24/b60 by DT id) | AX23 OEM | ath11k uses OTP board-id; an OTP ≠ 255 broke our lookup | OEM | **ADOPTED (packer + validator)** | same EU data under 255, 36/96 and chip-id names |
| 14 | MDIO clocks/resets swap in gcc-ipq5018 | main `b7afc4baab` | UniFi 6 Pro (mdio0 only) | wrong MDIO clock when only one bus enabled | yes | **NOT NEEDED** | AX23 enables both MDIO buses, so both clocks run (commit says no in-tree board affected) |
| 15 | ath11k monitor-trim log level | main `83c58ae10f` | ipq807x monitor mode | dmesg flooding | yes | **NOT NEEDED** | no monitor interface in our profile |
| 16 | wcss-sec shared loader refactor | main `f9c89becc3` | — | code sharing | — | **NOT NEEDED** | refactor, no behaviour change for us |
| 17 | RE700X factory-webflash | main `a20047f6ee` | RE700X | UART-free install | **not end-to-end** (author) | **NOT APPLICABLE** | AX23 flasher enforces RSA (`uart-free-final-verdict.md`) |

**Most useful source:** OpenWrt main's qualcommax/mac80211 work since our base (rows
1–4), then the EX511 v2 notes (rows 6, 11, 12: the only other dual-radio 256 MiB
IPQ5018+QCN6122+RTL8367S-VB board with Wi-Fi enabled), then MR80X v2 (rows 8, 10, 11).
