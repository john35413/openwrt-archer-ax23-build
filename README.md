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

Start with **`reports/final-validation.md`**: validation matrix, decision, next steps.

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
reports/                      audit, Wi-Fi, Ethernet, NAND safety, simulation, final validation
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

## Pinned sources

See `configs/sources.lock` and every `artifacts/*/BUILDINFO`.
