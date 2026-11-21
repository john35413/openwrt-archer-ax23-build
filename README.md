# AX23_V2_OPENWRT: TP-Link Archer AX23(EU) v2.0 OpenWrt development

A reproducible development pipeline, patch series, offline test suite and
hardware test plan for OpenWrt on the **TP-Link Archer AX23 v2.0** (Qualcomm IPQ5018,
256 MB, RTL8367S-VB switch, QCN6102 5 GHz). It builds on Sply-Dev's port
(github.com/Sply-Dev/openwrt-archer-ax23-v2) and does not replace it.

> **Safety status:** RAM-boot images only. Nothing here has been run on, or
> written to, a router by this project. `artifacts/experimental-do-not-flash/`
> holds build by-products that **must not be flashed** (see
> `reports/nand-boot-safety.md`). The AX23 **v1** (MediaTek) is a different
> device; nothing here applies to it.

Start with [the Codex handover](reports/CODEX_HANDOVER.md) for the current source revision, RAM image status and hardware gates. The [independent audit](reports/codex-patch-audit.md) covers all 25 patches. The [final hardware readiness](reports/final-hardware-readiness.md) report and `reports/physical-hardware-test-plan.md` describe the bench procedure.

## Layout

```
upstream/                     clones (git-ignored; created by build-dev.sh)
patches/openwrt/              dev patch series (git format-patch) + series file
configs/                      sources.lock (pinned SHAs), build diffconfigs, UCI profiles
tools/build-dev.sh            pipeline: deps → checkout → SHA verify → stage → patches → feeds
                              → config → kernel → world → validate → collect/checksums
tools/test-dev.sh             static + unit + network-simulation suites
tools/clean-dev.sh            removes generated build output only (asks for confirmation)
tools/validate-artifacts.sh   FIT/DTB/rootfs checks on build output
tools/bdf/                    board-2.bin inspector/packer, OEM board-data extractor
tools/uboot/ubootenv.py       offline U-Boot env analyser (read-only)
tools/pi-integration/         least-privilege Raspberry Pi monitoring/backup
tests/static|unit|network     offline tests (network = namespaces inside a QEMU VM)
tests/hardware/               router/PC scripts + HARDWARE-TEST-PLAN.md (read-only on the router)
artifacts/ram-only/           initramfs-uImage.itb + SHA256SUMS + BUILDINFO
artifacts/experimental-do-not-flash/
tests/nand/                   NAND/UBI lab on simulated NAND (nandsim) with the AX23 layout
reports/                      audit, Wi-Fi, Ethernet, NAND safety, cross-device, memory budget,
                              ath11k low-memory, UART-free, readiness matrix, final validation
logs/                         build and test logs
```

## Build (Linux, WSL2 Ubuntu/Debian, or this repo's cloud container)

Requirements: about 30 GB free disk, 4+ cores recommended (about 1.5 h from scratch on 4 cores),
the OpenWrt build prerequisites (`tools/build-dev.sh` stage 01 checks them),
and network access to github.com, sources.cdn.openwrt.org, ftp.gnu.org and cdn.kernel.org.

```bash
./tools/build-dev.sh --variant baseline   # Sply-Dev v0.5-test tree exactly as documented
./tools/build-dev.sh --variant dev        # baseline + patches/openwrt/series
./tools/build-dev.sh --variant dev --resume   # rebuild without re-staging (keeps kernel stamps)
./tools/test-dev.sh                       # static + unit + network simulation
./tools/build-twin.sh && ./tools/test-dev.sh twin   # full-system digital twin (QEMU)
```

**Digital twin** (`reports/digital-twin.md`): the same OpenWrt software, booted in QEMU as an
aarch64 system with the AX23 port names and two simulated radios (mac80211_hwsim). It runs
48 end-to-end checks covering wired LAN/WAN/NAT/IPv6, WPA2/WPA3 Wi-Fi on both bands, the guest/IoT
SSIDs, LuCI, the firewall and reboot recovery. It found two bugs that would have shipped to the real router. It does **not**
emulate the AX23's chips (radios/firmware, switch, NAND), so it cannot prove the hardware works.

On Windows 11: install WSL2 (`wsl --install -d Ubuntu-24.04`) and keep the project
**inside** the WSL filesystem (`~/`), not under `/mnt/c`; builds on `/mnt/c` fail
on case-insensitivity and are very slow. Give WSL at least 8 GB RAM in `.wslconfig`.
WSL2 was not available in this environment, so these WSL steps have not been tested.

### Wi-Fi board data (required for Wi-Fi)

Quickest: `tools/bdf/board-data-from-tplink-firmware.sh` downloads TP-Link's official
AX23 v2 firmware, verifies TP-Link's RSA signature, and extracts the EU board files exactly
as the stock firmware selects them (see `reports/wifi-root-cause.md`). Alternatively, use the
read-only NAND route below.

No AX23 v2 board data exists in any public source, and it is proprietary, so
it is not in this repository. Extract it from your own unit's stock firmware
(read-only), following `tests/hardware/HARDWARE-TEST-PLAN.md` §2 and §4, into
`board-data/` (git-ignored), then rebuild `dev`.

## What changed vs. the Sply-Dev tree (patches/openwrt)

| # | Change | Why |
|---|---|---|
| 0001 | `caldata.sh`: `ath11k_remove_regdomain` default target | upstream bug zeroed unrelated caldata words (regression test included) |
| 0002 | ath11k: smaller host RX rings when FW memory mode = 2 | about 42 MiB less RAM pre-posted for RX on a 256 MB board (source estimate) |
| 0003 | `ipq-wifi-tplink_archer-ax23-v2` package (locally supplied data) | root cause of the `-12` Wi-Fi failure: no board data |
| 0004 | DTS: Wi-Fi LED phy mapping, header facts | LEDs were bound to the wrong radios |
| 0005 | sysupgrade refused on AX23 v2 | it fell through to `default_do_upgrade` |
| 0006-0009 | upstream UNIPHY fixes incl. PR #26597 (cherry-picked with `-x`) | cold-boot 2.5G trunk training race |
| 0010 | wifi-scripts: another radio's `00` country no longer breaks hostapd | found by the digital twin: no AP started |
| 0011 | uboot-envtools entry (env layout from TP-Link's GPL U-Boot) | read-only `fw_printenv tp_boot_idx` diagnostics |
| 0012 | ath11k: smaller TX completion ring in FW memory mode 2 | the 32768-entry ring needs an order-9 (2 MiB) DMA block per radio at firmware-ready time; 2048 avoids it (adapted from the ath-next low-memory proposal) |
| 0013 | ath11k/ath12k mac_phy_caps stride overflow fix (CVE-2026-90398/9) | cherry-picked from OpenWrt main |
| 0014 | ath11k 102-118/954-956 + mac80211 484-490 fixes from OpenWrt main | NULL deref/leaks/use-after-frees merged upstream after our base |
| 0015 | every flash partition `read-only` in the RAM image | the RAM image must not be able to write NAND at all (the auto-attached "data" UBI otherwise mounts read-write) |
| 0016 | wcss-sec: no inline coredump (main `b97760cbc9`) | a Q6 firmware crash otherwise kept both radios down for the 5-minute devcoredump timeout |
| 0017 | `ax23_radios=none/2g/5g/both/seq` bring-up profiles | isolate each radio and the simultaneous start-up memory peak on the first hardware boot (RAM/sysfs only) |
| 0018 | ath11k RX rings follow the reference low-memory profiles | 0002 had two unreferenced values (IPQ5018 RX buffers 512, RXDMA error ring 128) |
| 0019 | ath11k: unwind the requested descriptor banks on partial allocation failure | frees the correct per-radio arrays instead of the global WBM array |
| 0020 | qualcommax: AX23 skip implicit UBI attachment on the unused data partition | prevents unintended probe of a non-essential partition |
| 0021 | qualcommax: report incomplete AX23 radio holds and preserve sequential bring-up on timeout | a failed 2.4 GHz start no longer releases the 5 GHz hold |
| 0022 | ath11k: unwind partial DP startup — WBM idle ring and earlier TX FIFOs | releases pre-allocated WBM idle ring and TX status FIFOs on failure |
| 0023 | qualcommax: preserve AX23 factory regulatory calibration in both ART segments | 0001 caldata fix must not clear per-unit regulatory words from the RAM copy |
| 0024 | qualcommax: keep IPQ5018 CMN bus clocks alive past initial setup | prevents premature clock disable on the AHB path |
| 0025 | qualcommax: wait for RTL8367S-VB chip and SerDes reset to settle | applies correct chip/PCS settling intervals for the family-D switch |

Board data: `board-data-from-tplink-firmware.sh` packs the EU files under the exact
variant-qualified keys for the observed OTP board id (255) and the OEM DT selectors
(36/96). Unknown OTP values require a matching explicit key (`board2.py scoped --eu`
gates the build).

## Pinned sources

See `configs/sources.lock` and every `artifacts/*/BUILDINFO`.
