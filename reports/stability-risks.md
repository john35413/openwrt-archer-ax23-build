# Memory pressure and stability risks (256 MB)

Labels as in `wifi-root-cause.md`.

## 1. Memory budget

| Item | Value | Evidence |
|---|---|---|
| Physical RAM | 256 MiB | 3P (U-Boot "256 MiB") |
| Kernel "available" at boot (OpenWrt, 58 MiB no-map incl. 48 MiB Q6) | 173,056 KiB | 3P boot log |
| No-map reservations (OpenWrt) | tz_apps 4, bootloader 2, sbl 1, smem 1, tz 2, q6_region 48 = 58 MiB | STATIC (ipq5018.dtsi + qcn6122.dtsi) |
| Stock reservations | NSS 8 MiB @0x40000000, TZ 4 MiB, Q6/WCSS 42 MiB @0x4b000000 (+ per-radio sub-regions inside) | STATIC (official 1.2.1 `fdt@mp02.1`) |
| Initramfs rootfs held in RAM (RAM boot only) | ≈29 MiB uncompressed (`reports/artifacts-dev.txt`) | STATIC |
| ath11k host RX buffers, default sizes | ≈25 MiB per radio (≈9,216 × ~2.8 KiB) | STATIC estimate |
| …with dev patch 0002 (FW memory mode 2) | ≈3.2 MiB (2.4 GHz) + ≈4.6 MiB (5 GHz) | STATIC estimate |
| TX completion rings (unchanged) | 32768 × 32 B per ring, coherent + kmalloc mirror | STATIC; candidate for a later, separate patch |
| QEMU twin with hwsim radios, 200 MiB VM | MemAvailable ≈70 MiB with 4 SSIDs + 2 clients | QEMU (not ath11k; not representative of FW memory) |

Rough RAM-boot projection (HYP): 173 MiB − ~29 MiB initramfs − ~25-35 MiB userspace/kernel
working set − ~8 MiB ath11k RX (patched) − TX rings/peers/firmware-related host memory (unknown)
→ plausibly 70-100 MiB MemAvailable with both radios idle. **Only a hardware `free` reading
can confirm this.** A NAND install would free most of the initramfs share.

## 2. Ranked risks

| # | Risk | Why | Mitigation in place | How to observe on HW |
|---|---|---|---|---|
| R1 | Genuine allocation failure when both radios start (`-ENOMEM` without the four "fetch" lines) | 256 MB boards (RE700X, MR80X v2) keep Wi-Fi disabled upstream for OOM; gusfm saw a 2nd-radio GFP_KERNEL failure with NSS | patch 0002; no NSS reservation; `coherent_pool=2M` | `dmesg`, `free` before/after `wifi up` |
| R2 | OOM under load (many clients, LuCI, conntrack) | 128 peers/radio cap from mode 2; userspace growth | lean core image; optional packages off by default | `soak-monitor.sh` (MemAvailable trend, OOM count) |
| R3 | QCN6122 RXDMA overflow at reduced ring | 1024 entries chosen from CR8806 measurement | 1024 (not 512) for QCN6122 | `iperf3 -R` on 5 GHz; `dmesg` overflow |
| R4 | Firmware crash/recovery loop | Q6 multi-PD on new FW 2.7 vs stock 2.5 | none needed yet | `dmesg | grep -i crash`, H16 |
| R5 | Trunk periodic park (777-08) | see Ethernet report | test exists | `--mode trunk-gaps` |
| R6 | Cold-boot trunk training race | known on IPQ5018 + RTL8367S | 0006-0009 (#26597) | 20× cold/warm reboot HW-26 |
| R7 | Boot ordering (tp_data mount before MAC/caldata) | preinit mount, hotplug caldata | 0004 (3P verified) | H08-H10 |

## 3. Upstream memory options considered

- PR #21495 "smallbuffers" (build-time) — same RX values as 0002; not taken because it changes every board of the build.
- QSDK 512M profile values used for monitor/status rings (STATIC reference).
- NSS offload — **not enabled** (proprietary, extra reservations); not needed for correctness.

## 4. Test plan (hardware; scripts referenced)

1. Idle: `free`, `/proc/meminfo`, `slabtop -o` (if available) after boot, after `wifi up`.
2. Two clients per band simultaneously + `pc-traffic-tests.sh --mode wifi` on each band.
3. LAN→WAN `iperf3 -P 4` while Wi-Fi clients run; 20 DHCP clients (e.g. `dhcpcd` in namespaces on the Pi); DNS flood (`dnsperf`-like loop from the Pi).
4. Guest/IoT isolation (profile `10-guest-iot-networks.uci`, fixed DHCP).
5. 24 h and 48 h soak with `soak-monitor.sh` (MemAvailable slope ≤ a few MiB/day, 0 OOM, 0 FW crash).
6. 10 cold + 10 warm boots: trunk up, both radios up, LAN→WAN OK each time.
7. Unexpected power loss: only after a persistent install exists; RAM-boot images are unaffected by definition.
