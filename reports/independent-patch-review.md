# Independent (adversarial) review of patches 0001–0018

**Superseding review.** See [the independent Codex audit](codex-patch-audit.md) for all 18 patches. R1 now fails closed on unknown OTP IDs. The board binds MPD, so R2 does not establish a recovery delay here. Patches 0019–0022 close additional cleanup, UBI attach and profile errors. The tables below record the earlier review.

Reviewer stance: assume earlier reports and a green build prove nothing. Each patch
was re-read against the exact built source (kernel 6.18.55, backports-7.2) and,
where it exists, the OEM firmware. Labels as in `wifi-root-cause.md`.

## 1. Defects found in our own work (this review)
| # | Where | Defect | Severity | Fixed by |
|---|---|---|---|---|
| R1 | 0003 + board-data packer | board-2.bin held **one** entry, `qmi-board-id=255` (the third-party unit's unprogrammed OTP). ath11k's lookup chain (`ath11k_core_fetch_bdf`: full → no variant → `bus=ahb,qmi-chip-id=0` → board.bin) **failed for every other OTP value**, which would bring back "failed to fetch board data" on an EU unit with a programmed OTP. Stock never depends on OTP (it loads b24/b60 by DT board_id) | **high** (Wi-Fi) | packer stores the same EU data under 255, the OEM DT id (36/96) and the chip-id name; `board2.py robust` + build/validator gate; rebuilt image PASSes "resolves for any OTP board id" |
| R2 | kernel (inherited) | `qcom_q6v5_wcss_sec` inline coredump: 5-minute Wi-Fi outage per Q6 crash | **high** (stability) | 0016 (`b97760cbc9`) |
| R3 | 0002 | RXDMA **error-destination** ring 128: matches no reference (all keep 1024), saves ~28 KiB/radio, risks RXDMA back-pressure | medium | 0018 |
| R4 | 0002 | IPQ5018 RXDMA **buffer** ring 512: unmeasured, both low-memory references use 1024 | medium | 0018 (1024; +~1.4 MiB) |
| R5 | 0012 (first draft) | IDR bound `size−1` allowed one more in-flight frame than one completion pass can drain | low-medium | fixed before commit (`size−2`), model test |
| R6 | DTS (inherited from Sply) | switch reset on GPIO 39, taken from an OEM **QCA8337** boilerplate node; OEM mdio + TP-Link U-Boot point to GPIO 26 (as on MR80X v2) | medium (boot determinism), not a bring-up blocker | **not changed**: HW-3P works with 39; variant to measure |
| R7 | earlier report `ethernet-nat-validation.md` §3 | claimed the stock DTB "matches" GPIO 39 and dismissed `CONFIG_SWITCH_RESET=26` | report error | corrected in `oem-openwrt-differential-analysis.md`; this table records it |
| R8 | 0004 | LED triggers assume phy0 = 2.4 GHz; wrong only under the new `ax23_radios=5g` diagnostic profile | cosmetic | documented |
| R9 | twin harness | 30-min soak's memory sampler died with its SSH channel (S07 empty) | test gap | `setsid` fix; 160 MiB run now records min/slope |
| R10 | 0012 claim + `real-memory-budget.md` | 0012 was described as removing the order-9 allocation at firmware-ready time, but `ath11k_dp_link_desc_setup()` still allocates **two order-9 (2 MiB) link-descriptor banks per radio**, and the budget omitted those 8.6 MiB | medium (claim/budget) | budget corrected (host DMA ~19 MiB, projection 75–90 MiB); claim narrowed; not patched (no reference reduces it, EX511 runs with it); measured by selfdiag M.4/M.10 |

## 2. Per-patch verdict
| Patch | Purpose | Class | Review result |
|---|---|---|---|
| 0001 caldata `ath11k_remove_regdomain` default target | upstream bug zeroed caldata words | Wi-Fi correctness | OK; unit test |
| 0002 (ath11k 960) RX rings in FW mode 2 | memory | **Wi-Fi-required on 256 MiB** | consistent (every ring-size use goes through the helper; the remaining `DP_RXDMA_REFILL_RING_SIZE` calls pass a *buffer size in bytes*). Values corrected by 0018 (R3/R4) |
| 0003 board-data package | `-12` root cause | **Wi-Fi-required** | R1 fixed in the packer/validator, not in the package |
| 0004 LED phy mapping | cosmetic | optimisation | R8 |
| 0005 sysupgrade interlock | safety | safety | OK: a forced `-F` reaches stage 2, refuses, reboots into untouched stock |
| 0006–0009 UNIPHY (#26597 + prereqs) | cold-boot trunk | **boot/Ethernet-required for 2.5 G** | `-x` cherry-picks, unchanged from upstream |
| 0010 hostapd country | twin-found bug | Wi-Fi-required (AP start) | OK; keeps the original null tolerance |
| 0011 uboot-envtools entry | read-only diagnostics | diagnostic | OK; SIM lab L04 reads the env and rejects a wrong size |
| 0012 (ath11k 961) TX completion ring | memory / order-9 alloc | **Wi-Fi-required on 256 MiB** | OK after R5; all dependent sites converted; validator checks the object |
| 0013 CVE stride fix | security | stability | `-x` cherry-pick |
| 0014 ath11k/mac80211 fixes | stability/security | stability | unchanged upstream files; whole set applies with zero fuzz |
| 0015 all partitions read-only | NAND safety | **safety-required** | sufficient on every kernel write path (`nand-write-protection-audit.md`) |
| 0016 wcss-sec no inline coredump | crash recovery | stability | R2; applies cleanly to our kernel |
| 0017 radio bring-up profiles | diagnostics | diagnostic | sysfs only; 10/10 logic tests; other boards untouched |
| 0018 (ath11k 962) RX rings follow references | memory/stability | Wi-Fi-required on 256 MiB | R3/R4; applies cleanly after 960/961 |

## 3. Dependency matrix
```
boot (any RAM boot)        : base tree + DTS (Sply v0.5-test)            [HW-3P boots]
Ethernet 2.5 G trunk       : 0006 → 0007 → 0008 → 0009                   (same driver, in order)
Wi-Fi (both radios)        : 0003 (board data) + 0001 + 0010
  on 256 MiB               : + 0002 → 0012 → 0018  (ath11k 960 → 961 → 962, applied in order)
Wi-Fi stability/security   : 0013, 0014 (independent of 960–962), 0016 (kernel)
NAND safety                : 0005, 0015 (independent)
diagnostics                : 0011, 0017 (independent)
cosmetic                   : 0004
```
- **Identifiable baseline:** Sply-Dev v0.5-test (`build/baseline`, artifacts-baseline.txt).
- **Independently testable variants** for hardware A/B: (a) dev image as built;
  (b) `ax23_radios=` profiles inside the same image (no rebuild); (c) GPIO-26 switch
  reset DTS; (d) 1 G SGMII trunk DTS. (c) and (d) are documented and not built, so
  the first hardware session uses one image and changes one variable at a time.
- Safety protections (0005, 0015) are never removed to simplify a test.
