# Hardware acceptance plan: Archer AX23(EU) v2.0 (RAM boot only)

Nothing here writes to flash. Every step boots OpenWrt from RAM via TFTP;
power-cycling the router returns it to the stock firmware on NAND.

Record every result as **PASS / FAIL / BLOCKED / NOT TESTED** with the raw log
attached. A test that could not run is BLOCKED, never PASS.

## 0. Prerequisites

| Item | Notes |
|---|---|
| USB-UART adapter **with 1.8 V logic** | The AX23 v2 UART is 1.8 V (GPIO28 RX / GPIO29 TX, header JP1, 115200 8N1). A plain 3.3 V adapter can damage the SoC. Use an adapter with selectable 1.8 V I/O, or a 3.3 V adapter through a bidirectional level shifter (e.g. TXS0108E/BSS138 module, LV side at the board's 1.8 V). The SMD level-shifter pads on the PCB are unpopulated; testers bridged them or wired an off-board shifter (forum t/254876). |
| TFTP server on the PC or Pi | Pi: `dnsmasq --port=0 --enable-tftp --tftp-root=/srv/tftp`. Windows: Tftpd64. PC address 192.168.1.10/24. |
| Image | `artifacts/ram-only/dev/openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`. Check `sha256sum -c SHA256SUMS` first. |
| Cables | PC ↔ router LAN1; upstream modem ↔ WAN for routing tests. |

## 1. RAM boot (repeatable)

```
(power on, press a key at "Hit any key to stop autoboot")
IPQ5018# setenv serverip 192.168.1.10
IPQ5018# setenv ipaddr 192.168.1.1
IPQ5018# tftpboot 0x44000000 openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb
IPQ5018# bootm 0x44000000
```
Do **not** run `saveenv`. Do not run any `nand`/`sf`/`mtd`/`ubi write`/`erase` commands.
Capture the full UART log to `logs/hw/<date>-boot-N.txt`.

## 2. Before anything else: read-only backup

From the PC: `tests/hardware/backup-flash-ro.sh 192.168.1.1 ~/ax23-backup` → every MTD
partition read via `/dev/mtdNro`, with sha256 verified on both sides. Keep it offline. It
contains your MAC, Wi-Fi PIN, calibration and stock firmware, and it feeds `tools/bdf/extract-oem-bdf.sh`.

## 3. Acceptance tests

| # | Test | How | Pass criterion |
|---|---|---|---|
| HW-01 | Linux boot | UART log | reaches shell; no panic/oops |
| HW-02 | State snapshot | `ssh root@192.168.1.1 sh -s < tests/hardware/router-collect.sh > hw.tsv` | H01-H24 as listed in the script |
| HW-03 | Switch + 2.5G trunk | H04/H05 + `ethtool -S eth0` | RTL8367S-VB probed; `2.5Gbps/Full`; no climbing FCS errors |
| HW-04 | LAN ports 1-4 | plug the PC into each port in turn; `ip -s link show lanN` | link + DHCP on each |
| HW-05 | Client-to-client switching | two PCs/Pi on LAN; `pc-traffic-tests.sh --mode lan-lan` | >900 Mbit/s TCP, no loss |
| HW-06 | WAN | upstream modem; `ifstatus wan` | DHCP lease, ping 1.1.1.1 |
| HW-07 | DHCP/DNS/NAT/TCP/UDP | LAN client: lease, `nslookup`, browse; `pc-traffic-tests.sh --mode lan-wan --server <host on WAN side>` | all succeed; record Mbit/s |
| HW-08 | Load + latency | HW-07 output L1/L2 | no loss; record RTT under load |
| HW-09 | Trunk gap detector (777-08 risk) | `pc-traffic-tests.sh --mode trunk-gaps --server <WAN-side host>` (10 min) | G1 PASS (no ~10 s periodic bursts) |
| HW-10 | IPv6 | if the ISP provides it: `ifstatus wan6`, client `ping -6` | global address + reachability |
| HW-11 | PPPoE | only if your ISP uses it | session up |
| HW-12 | Wi-Fi board data | after §4 | H11 PASS (2 phys) |
| HW-13 | 2.4 / 5 GHz AP | `uci set wireless.radioN.country=<EU cc>`; enable; `iw dev`, `iw phy` | both APs beacon; correct channels/power for your country |
| HW-14 | WPA2 / WPA3 | `encryption psk2` then `sae` / `sae-mixed` | client associates on both bands |
| HW-15 | Wi-Fi DHCP, Internet, Wi-Fi↔LAN | client on each band | lease; browse; iperf3 to a wired host |
| HW-16 | Wi-Fi throughput | `pc-traffic-tests.sh --mode wifi` from the Wi-Fi client | record Mbit/s per band |
| HW-17 | Reconnect stability | toggle client Wi-Fi 50×; `logread \| grep -c ath11k` | no driver errors |
| HW-18 | LEDs | observe; H22; `iw phy` band mapping (H14) | LEDs follow phy0=2.4G / phy1=5G |
| HW-19 | Buttons | `cat /sys/kernel/debug/gpio` while pressing reset / WPS | reset = gpio14 low when pressed; record any WPS GPIO |
| HW-20 | MAC addresses | H08/H09; compare to label | match |
| HW-21 | Watchdog / thermal | H20/H21 | present; temperatures plausible |
| HW-22 | VLAN isolation | apply `configs/uci/10-guest-iot-networks.uci` (+20 for wired) | as in simulation N14-N22 |
| HW-23 | Memory | H17/H18 idle, then during HW-16 | MemAvailable > 50 MiB; no OOM |
| HW-24 | 24 h soak | `ssh … sh -s < soak-monitor.sh \| tee soak.csv` + continuous iperf/ping | no crash/OOM; MemAvailable flat (no leak) |
| HW-25 | 48 h soak | as HW-24 | as HW-24 |
| HW-26 | Repeated reboots | 20 cycles: 10 power cycles + 10 `reboot` (each followed by a new TFTP boot) | trunk up and LAN→WAN works every time |
| HW-27 | Recovery | power-cycle after a RAM boot | stock firmware boots normally (the NAND was untouched) |
| HW-28 | Recovery after interrupted service | pull WAN for 5 min during HW-24 | traffic resumes; no manual action |

## 4. Wi-Fi board data (required before HW-12 to HW-17)

```
tools/bdf/extract-oem-bdf.sh ~/ax23-backup/mtd11_rootfs.bin            # lists candidates
tools/bdf/extract-oem-bdf.sh ~/ax23-backup/mtd11_rootfs.bin --region <EU dir>
./tools/build-dev.sh --variant dev --resume
```
If `mtd11` does not hold TP-Link firmware, try `mtd12_rootfs_1.bin`.

## 5. Reporting

Fill `reports/final-validation.md` with the TSV/CSV/UART logs. Keep raw logs, but redact MAC
addresses and Wi-Fi keys before posting publicly.
