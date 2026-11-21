# Source audit: TP-Link Archer AX23 v2 OpenWrt port

Audit date: 2026-11-21. Scope: the Sply-Dev tree applied to the documented
OpenWrt base, plus the upstream code it depends on.

## Evidence tags

| Tag | Meaning |
|---|---|
| `[SRC]` | Read in source code (file and function named) |
| `[STATIC]` | Confirmed by a static/offline test in this project (test named) |
| `[SIM]` | Simulation (network namespaces in a VM, synthetic data) |
| `[HW-3P]` | Third-party hardware report: Veraxis' **Archer AX21 v5 (US)** that runs AX23 v2 firmware (forum t/254876). **This is not an EU AX23 v2.** |
| `[HW]` | Our own hardware test. **There are none in this report.** |

## Revisions audited

| Item | SHA / version |
|---|---|
| OpenWrt base | `98b1185d039344553aaf8270d0661cfad4f0a54d` (2026-10-08, "mt76: update to Git HEAD") |
| AX23 v2 tree (Sply-Dev) | `93028b47d291e251dc108de5fbd8bd3f77a9300c` = tag `v0.5-test`, unchanged since the earlier inspection |
| Feeds (pinned to base date) | packages `a16d10144dd3`, luci `4bc2f85da828`, routing `4b9891b91362` |
| Kernel | 6.18.55 (`target/linux/generic/kernel-6.18`) |
| mac80211/ath11k | backports 7.2 (sha256 `6ec76a4c…9454`, matches `PKG_HASH`) + 23 OpenWrt ath11k patches |
| ath11k firmware | `WLAN.HK.2.7.0.1-01744-QCAHKSWPL_SILICONZ-1` (IPQ5018_QCN6122_QCN6122) |
| ipq-wifi (qca-wireless) | `6a0f508b9ce3` |
| Comparison refs | openwrt PR #19644 head `aed91e033f` (rtl8365mb **v13-pre0**, 13 patches), PR #26597 `5e086c964e` (UNIPHY), PR #21495 `24ca694d58` (ath11k smallbuffers), kuncy7/openwrt-nss-edma `c3po-tag-8021q` `092adebb06` |

**The v0.5-test release binaries could not be inspected** (github.com release pages are blocked
from this build host). The forum says v0.5-test was built with PR #26597. The repository tree at
the same tag does not contain #26597. So the published binary and the published source may differ.
This project therefore applies #26597 explicitly (dev series 0006-0009).

## Hardware identity: what is established

| Fact | Status |
|---|---|
| SoC IPQ5018, 256 MB, 128 MB SPI-NAND (ESMT F50D1G41LB), machid 0x8040000, FIT config `config@mp02.1` | `[HW-3P]` U-Boot log + `[SRC]` |
| U-Boot build `jenkins-Router-Archer_AX23v2-8` (2016.01, Feb 24 2025) | `[HW-3P]` |
| Switch RTL8367S-VB (family D, 0x6642/0x0010) | `[HW-3P]` rtl8365mb probe; `[SRC]` qca-ssdk analysis |
| Stock firmware support list contains **both** US (`55530000`) and EU (`45550000`) special_ids in the same image | `[SRC]` forum t/249493 #1 |
| EU AX23 v2 identical to the US unit | **Not established.** Same firmware image is strong evidence of the same board, but the stock rootfs keeps region directories (`CA/default/…/WIFI_FW`), so region-specific board data is possible. |

## 1. Target configuration (qualcommax/ipq50xx)

- Correct: subtarget, `KERNEL_PATCHVER 6.18`, `FW_LOADER_USER_HELPER(_FALLBACK)=y`, `FW_LOADER_PAGED_BUF=y` `[SRC]`.
- Correct: device block. `IMAGE_SIZE 54784k` = 0x3580000 slot, `DEVICE_DTS_CONFIG config@mp02.1` matches U-Boot's selection `[SRC]` `[HW-3P]`.
- **Defect D1:** `DEVICE_PACKAGES` has no board-data package (`ipq-wifi-*`), so no `board-2.bin` is installed for either radio `[SRC]`. This is the Wi-Fi blocker. See `wifi-investigation.md`.
- **Documentation defect D2:** `docs/BUILD.md` says to apply the `777-*` kernel patches with `patch -p1` at the OpenWrt root. They patch `drivers/net/dsa/realtek/*` and have to be copied into `target/linux/generic/pending-6.18/` instead `[STATIC]` (`tools/build-dev.sh` stage 04).
- Build host note: GNU tar/coreutils refuse to configure as root unless `FORCE_UNSAFE_CONFIGURE=1` is set. The pipeline sets it when it runs as root.

## 2. DTS and included DTSI files

Correct `[SRC]` `[STATIC]` (`tests/static/check_dtb.py` checks these on the built DTB):
- The partition table matches the `/proc/mtd` that Veraxis posted from hardware, byte for byte `[HW-3P]`: 16 partitions, no overlaps, erase-aligned, all inside 128 MiB.
- SBL1, MIBIB, BOOTCONFIG, BOOTCONFIG1, QSEE, DEVCFG, CDT, APPSBL, ART, TRAINING, tp_data and radio are all `read-only`. APPSBLENV and the two rootfs slots are writable. That is needed for any future install, and nothing in the dev build writes them (see §8).
- Wi-Fi: `wifi@c000000` uses pd1 with bdf-addr 0x4c400000. `wifi@b00a040` uses pd2/`q6v5_wcss_userpd2` with bdf-addr 0x4d100000 and m3-dump 0x4df00000. All three addresses fall inside `q6_region` (0x4b000000 + 0x3000000, from `ipq5018-qcn6122.dtsi`). Boot-args `<2 4 2 0x1b 0 0>` put UPD2 on PCIE1 with reset GPIO27. The hardware logs show `Multipd architecture - userpd: 2` and QMI memory negotiation completing on both radios `[HW-3P]`, so the boot-args and PD choice work on this board. AX55 v1 instead uses pd3 without boot-args; that is a different layout, and **switching to it is not recommended** without a stock-DTB comparison.
- `mdio0` is enabled. Per the AX55 v1 finding, the GE-PHY reset gates the shared MDC/MDIO path `[SRC]`.
- Switch reset is GPIO39. GPIO33 is driven low as the (off) 2.4 GHz LED while the switch works `[HW-3P]`, so GPIO33 cannot be an active-low switch reset on that unit. That settles the conflict with vram's stock log line `GPIO33 reset switch done`, at least on the AX21 v5.

Defects and issues:
- **D3 (fixed, dev 0004):** the Wi-Fi LED triggers were reversed relative to the DTS's own reasoning (5 GHz on `phy0tpt`). In every posted log the 2.4 GHz radio registers first. Still needs a hardware check.
- D4: there is no WPS/Wi-Fi button node. The OEM U-Boot DTB lists only `reset` (GPIO14) `[SRC]` (t/249493). Whether the EU unit has a second button, and on which GPIO, is unknown. `tests/hardware/router-collect.sh` dumps `/sys/kernel/debug/gpio` so it can be identified by pressing the button.
- D5: the DTS header claimed "NOT yet read from the physical unit" and "no UART". That is stale; corrected in dev 0004.
- The amber WAN LED is left without a trigger. Upstream AX55 v1 does the same, so this is acceptable.

## 3. Ethernet switch and Realtek patches (777-01…10 = net-next **v7**)

- Applies cleanly on top of the base's backports (`942-*`/`943-*`/`944-*`/`946-*`: rtl8365mb VLAN/FDB/SGMII/HSGMII). The kernel compiled with them `[STATIC]` (baseline build, `logs/baseline/`).
- Upstream state: PR #19644 is now at **v13-pre0** (13 patches). It adds refactor patches for forcemode, VLAN 4k, PVID and L2 MAC, and it **removes "re-latch the family D SerDes"**, which the AX23 tree carries as 777-08. The forum reports that patch is on hold on netdev while the UNIPHY-side fix (#26597) is investigated `[SRC]`.
- **Risk R1 (777-08):** once the link has latched, a delayed work item keeps checking the SerDes link every 10 s and parks the lane for 20 ms whenever the status bit reads "down" `[SRC]`. A false-negative status read would cause a 20 ms trunk outage every 10 s. Nothing in the hardware logs shows this `[HW-3P]`, but nobody has looked for it. `tests/hardware/pc-traffic-tests.sh --mode trunk-gaps` tests for exactly this.
- Decision: keep v7 for the dev build, because it is the version with the best hardware evidence (`[HW-3P]` 5/5 boots with LAN→WAN traffic). Add #26597 plus its three same-file prerequisites from upstream main (dev 0006-0009, cherry-picked with `-x`; they touch only `pcs-qca-uniphy.c/h` and `dwmac-ipq5018.c`). Moving to v13-pre0 should be a separate, hardware-tested variant.
- `pause;` on the fixed links is honoured through `rtl8365mb_ext_config_forcemode()` `[SRC]` (as corrected in the forum).
- No memory-corruption pattern was found in the parts reviewed (locking around the SDS indirect-access window, `disable_delayed_work_sync` on teardown/reboot) `[SRC]`. This was a targeted review, not a full line-by-line audit of 2,000+ lines.

## 4. Board-specific calibration (patch 0001)

- Cases sit under the correct firmware names: `ath11k/IPQ5018/hw1.0/cal-ahb-c000000.wifi.bin` reads ART+0x1000 and `ath11k/QCN6122/hw1.0/cal-ahb-b00a040.wifi.bin` reads ART+0x26800, each 0x20000 bytes `[SRC]`. The offsets are the same as AX55 v1. Sply reports a bit-for-bit match against hardware dumps (not reproducible here).
- The reads are `caldata_extract` from the read-only `0:ART` into `/lib/firmware` in RAM. **ART is never written** `[SRC]`.
- **Defect D6 (upstream, fixed in dev 0001):** `ath11k_remove_regdomain` is called with no target. Its `hexdump` then reads stdin, and it zeroes 0x450/0x458/0x500/0x5a8 whether or not those offsets hold a regdomain copy. This affects 15 ipq50xx call sites. `[STATIC]` `tests/unit/test_caldata_regdomain.sh` runs the real `caldata.sh` and reproduces the bug on the base, then shows the fix.
- Wi-Fi MACs are label−1 (2.4 GHz) and label−2 (5 GHz), copied from the AX55 v1 convention. They are **not verified** against AX23 stock behaviour. The arithmetic, including byte borrow, is tested in `[STATIC]` `test_mac_derivation.sh`.

## 5. ath11k firmware loading

Fully traced in `wifi-investigation.md`. Summary: `-12` is the firmware user-helper's result for a **missing file**. It is not an allocation failure in ath11k.

## 6. Memory reservation and allocation

- No-map reservations total 58 MiB: tz_apps 4, bootloader 2, sbl 1, smem 1, tz 2, and q6_region 48 (raised from 27 MiB by `ipq5018-qcn6122.dtsi`). The kernel reports `Memory: 173056K/262144K available` `[HW-3P]`.
- `fw-memory-mode = 2` on both radios is valid in this ath11k. It is handled per device in `ath11k_core_pre_init`, sets 8 vdevs and 128 peers per radio, and disables coldboot calibration `[SRC]`. It does **not** shrink host RX rings. Those default to 1 GiB-class sizes and pre-post about 9,200 2 KiB buffers per radio, roughly 25 MiB per radio estimated from source. Fixed for this board in dev 0002 (see `wifi-investigation.md`).
- `coherent_pool=2M` is in bootargs. The AX5x 256M tree uses 512K together with a separate patch. Left unchanged here.

## 7. NAND partition mapping, U-Boot env, A/B

See `nand-boot-safety.md`. Key findings:
- **Defect D7 (safety):** in the base tree this board has no case in `platform_do_upgrade`, so `sysupgrade` falls through to `default_do_upgrade`, while `platform_check_image` accepts any image `[SRC]`. Fixed in dev 0005: refused in both places, before any flash access.
- U-Boot reports `*** Warning - bad CRC, using default environment` `[HW-3P]`. The env in APPSBLENV is invalid or erased on that unit. A naive `fw_setenv tp_boot_idx` would write a fresh uboot-envtools default env that has no `bootcmd=bootipq`, and the board would stop at the U-Boot prompt. kuncy7 documented this failure mode on an AX55 v4.
- No uboot-envtools config exists for this board. **That is deliberate:** the env size has not been verified. `tools/uboot/ubootenv.py` determines it offline from a read-only dump.

## 8. Default LAN/WAN configuration (0002), MAC (0003), tp_data (0004), LEDs (0005)

- 0002: `lan1-4` → br-lan, `wan` → wan `[SRC]` `[HW-3P]`.
- 0003/0004: tp_data is attached and mounted from a `read-only` MTD partition. UBI attaches read-only MTD devices in read-only mode, so preinit cannot write tp_data `[SRC]`. MAC = `default-mac`, WAN = +1 `[HW-3P]` `[STATIC]`.
- 0004 applies with fuzz 1 and 0003 with fuzz 2. The results are correct (verified diff in `logs/baseline/04-stage-ax23.log`) `[STATIC]`. No `.orig` or `.rej` files remain `[STATIC]`.
- 0005: netdev triggers for LAN/WAN `[HW-3P]`.

## 9. Firmware image generation

- `initramfs-uImage.itb` (FIT, LZMA kernel + embedded initramfs, `config@mp02.1`, load 0x41000000). Stock U-Boot TFTP-loads it to 0x44000000 `[HW-3P]`. `tools/validate-artifacts.sh` checks that the decompressed kernel ends below 0x44000000 and that the FIT ends below the Q6 region.
- `squashfs-factory.ubi` and `squashfs-sysupgrade.bin` are produced but **not installable**. There is no validated install path (see `nand-boot-safety.md`). They are kept only in `artifacts/experimental-do-not-flash/`.

## Summary of findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| D1 | Blocker (Wi-Fi) | No board-data package; no AX23 v2 entry exists in any public board-2.bin | Packaging fixed (dev 0003); **data must come from the user's own stock firmware** |
| D6 | Medium | `ath11k_remove_regdomain` zeroes unrelated caldata words (upstream bug) | Fixed (dev 0001) + regression test |
| D7 | High (safety) | sysupgrade falls through to `default_do_upgrade` | Interlocked (dev 0005) |
| M1 | High (stability) | ath11k host RX rings sized for 1 GiB on a 256 MiB board | Fixed for FW-mode-2 boards (dev 0002), not hardware-tested |
| D3 | Low | Wi-Fi LED phy mapping reversed | Fixed (dev 0004), needs hardware confirmation |
| R1 | Medium | 777-08 periodic SerDes park on false link-down | Test written; not hardware-tested |
| U1 | Medium (stability) | Trunk cold-boot training race | Upstream fix #26597 applied (dev 0006-0009) |
| D2 | Doc | `patch -p1` instruction for 777-* is wrong | Pipeline does it correctly |
| D4 | Low | WPS/Wi-Fi button absent/unknown | Needs hardware GPIO discovery |
| E1 | Safety | U-Boot env bad CRC on the third-party unit | Install design accounts for it; env size still unknown |
