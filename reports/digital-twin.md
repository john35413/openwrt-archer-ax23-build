# AX23 v2 digital twin: full-system software simulation

> **What this is:** the AX23 v2 *software* (the same OpenWrt revision `98b1185`,
> the same feeds, the same Sply-Dev staging and dev patch series) booted as a
> complete aarch64 OpenWrt system in QEMU. Virtual NICs carry the AX23 port names
> and two simulated radios stand in for the AX23 radios. A second VM provides
> the ISP, the Internet and wired PCs.
>
> **What this is not:** an emulation of the AX23 hardware. No emulator exists
> for the IPQ5018 SoC, the ath11k driver and its proprietary Q6/WCSS firmware,
> the QCN6102 radio, board data and calibration, RF propagation, the
> RTL8367S-VB switch ASIC, the 2.5G UNIPHY trunk, SPI-NAND or the TP-Link U-Boot.
> **A PASS here does not show that the physical router works.** It shows that
> everything above the hardware drivers (netifd, hostapd/wpa_supplicant WPA2/WPA3,
> mac80211/cfg80211, regulatory, bridging, VLAN/zone policy, fw4/nftables, NAT,
> dnsmasq DHCP/DNS, odhcpd/IPv6, uhttpd/LuCI, dropbear, reboot recovery) is
> configured correctly and works together.

## Model

| AX23 v2 hardware | Twin stand-in | Fidelity |
|---|---|---|
| IPQ5018, 2× Cortex-A53, 256 MB | QEMU `virt`, 2× Cortex-A53 (TCG), **200 MiB** (≈118 MB available after boot; the AX23 reports 173 MB) | same ISA and core type; slower (emulated); memory tighter than the real board |
| RTL8367S-VB ports `wan`, `lan1-4` (DSA) | 5 virtio NICs renamed `wan`, `lan1..lan4` at preinit | same netdev names and the same netifd/UCI config as the AX23 board.d generates; **switching is a Linux software bridge, not the ASIC** |
| IPQ5018 2.4 GHz radio (ath11k) | `mac80211_hwsim` radio0, 2.4 GHz ch 6 HE20 | same mac80211/cfg80211/hostapd/netifd path; **driver, FW and RF not modelled** |
| QCN6102 5 GHz radio (ath11k) | `mac80211_hwsim` radio1, 5 GHz ch 36 HE80 | as above |
| Wi-Fi clients | hwsim radios 2/3 in separate network namespaces running wpa_supplicant | real supplicant/SAE/PMF |
| ISP, Internet, LAN PCs | helper VM (Linux 6.8) with namespaces, connected by QEMU socket "cables" | |

Config under test: the AX23 network layout (`lan1-4 → br-lan`, `wan` DHCP, `wan6`),
EU regulatory domain (DE), WPA2-PSK on 2.4 GHz, WPA3-SAE (PMF required) on 5 GHz,
plus the shipped `configs/uci/10-guest-iot-networks.uci` (guest WPA3 SSID,
WPA2 IoT SSID, firewall zones).

Reproduce: `./tools/build-twin.sh && ./tests/twin/run-twin.sh`
(results: `logs/twin/results.tsv`; router console `logs/twin/router-console.log`).

## Results

**Run 6: 48 PASS, 0 FAIL, 1 INFO** (`logs/twin/results-run6.tsv`). Runs 7 and 8 (repeats; run 8 with the final committed harness): **48 PASS, 0 FAIL** each (`logs/twin/results-run7.tsv`, `results-run8.tsv`). Earlier runs 1-5 failed while the bugs below were being found and fixed; their logs are kept in `logs/twin/run*.console`.

Throughput figures come from an *emulated* CPU (QEMU TCG on x86) and simulated radios. They say nothing about the real router's performance.

| ID | Result | Check | Measurement / detail |
|---|---|---|---|
| T01 | PASS | router VM boots; LAN DHCP answers | 76 s after helper start (TCG emulation) |
| T02 | PASS | SSH to router from LAN (key auth) |  |
| T03 | PASS | AX23 port names; br-lan members | lan1 lan2 lan3 lan4 phy0-ap0 phy1-ap0  |
| T04 | PASS | WAN DHCP lease from ISP | 203.0.113.114 |
| T05 | PASS | WAN IPv6 (SLAAC/RA via wan6) | 2001:db8:ffff:0:5054:ff:fe23:0/64 |
| T06 | PASS | router IPv6 reachability to Internet |  |
| T07 | PASS | LuCI login page served (HTTP 403 = not yet authenticated, by design) and root login yields a session | login: 302 |
| T08 | PASS | DHCP on lan1, lan2, lan3 | 192.168.1.235 192.168.1.236 192.168.1.237 |
| T09 | PASS | DNS through router dnsmasq |  |
| T10 | PASS | lan1 <-> lan2 client-to-client |  |
| T11 | PASS | LAN -> Internet NAT | src=203.0.113.114 |
| T12 | PASS | TCP (HTTP) through NAT |  |
| T13 | PASS | UDP through NAT |  |
| T14 | PASS | 3 MB download intact through router |  |
| T15 | PASS | iperf3 LAN->WAN through NAT (TCG-emulated CPU) | 192 Mbit/s |
| T16 | PASS | iperf3 lan1->lan2 (software bridge here; switch ASIC on the AX23) | 204 Mbit/s |
| T17 | PASS | router SSH not reachable from WAN |  |
| T18 | PASS | LuCI not reachable from WAN |  |
| W01 | PASS | both radios up under netifd/hostapd | radio0 (2.4G) + radio1 (5G) |
| W02 | PASS | regulatory domain DE (EU) applied |  |
| W03 | PASS | AP channels/widths | channel 6 (2437 MHz), width: 20 MHz ; channel 36 (5180 MHz), width: 80 MHz |
| W04 | PASS | 4 SSIDs broadcast (main 2G/5G, guest, IoT) | AX23-2G AX23-5G CHANGE-ME-guest CHANGE-ME-iot  |
| W05 | PASS | 2.4 GHz WPA2-PSK client associates + DHCP | 192.168.1.110 |
| W06 | PASS | 5 GHz WPA3-SAE (PMF required) client associates + DHCP | 192.168.1.159 |
| W07 | PASS | 5 GHz link uses SAE (WPA3) | key_mgmt=SAE |
| W08 | PASS | both clients associated with 802.11ax (HE) capabilities | 2 HE stations |
| W09 | INFO | station rates reported by hwsim (not RF) | 2G: tx bitrate: |
| W10 | PASS | Wi-Fi clients reach router (both bands) |  |
| W11 | PASS | Wi-Fi clients reach Internet via NAT (both bands) |  |
| W12 | PASS | HTTP over 5 GHz Wi-Fi |  |
| W13 | PASS | Wi-Fi <-> wired LAN both directions |  |
| W14 | PASS | DNS for Wi-Fi clients |  |
| W15 | PASS | simultaneous dual-band traffic, 0% loss | 2G loss 0% / 5G loss 0% (30 pings each, concurrent) |
| W16 | PASS | iperf3 over 2.4G Wi-Fi to Internet (hwsim+TCG, NOT RF) | 67.3 Mbit/s |
| W16 | PASS | iperf3 over 5G Wi-Fi to Internet (hwsim+TCG, NOT RF) | 65.4 Mbit/s |
| W17 | PASS | WPA3 rejects a wrong password |  |
| W18 | PASS | WPA2-PSK client cannot join the SAE-only 5 GHz SSID |  |
| W19 | PASS | 20/20 WPA3 disconnect/reconnect cycles with traffic | 135 s total |
| W20 | PASS | guest SSID (WPA3) -> guest network | 192.168.20.160 |
| W21 | PASS | guest Wi-Fi reaches Internet |  |
| W22 | PASS | guest Wi-Fi isolated from LAN |  |
| W23 | PASS | guest Wi-Fi cannot reach router SSH |  |
| W24 | PASS | IoT SSID (WPA2) -> IoT network | 192.168.30.160 |
| W25 | PASS | IoT Wi-Fi has no Internet |  |
| W26 | PASS | LAN can reach IoT device (e.g. Pi home automation) |  |
| S01 | INFO | router MemAvailable with 4 SSIDs + 2 clients (200 MiB VM; hwsim, not ath11k) | 69640 kB |
| S02 | PASS | no kernel oops/panic/OOM/segfault |  |
| S03 | PASS | hostapd still running |  |
| S04 | PASS | 3 min mixed wired+Wi-Fi load: router responsive | LAN ping loss 0%, 2.4G client still online |
| S05 | PASS | reboot: LAN, WAN and both radios come back | 116 s |


## Bugs found by the twin

| # | Where | Finding | Action |
|---|---|---|---|
| 1 | **OpenWrt wifi-scripts** (`hostapd.uc: device_country_code`) | The country of *every* radio in `network.wireless status` overwrote the AP radio's own country, and the last one won. One radio left at the world domain `00` (wifi auto-detect uses `00` for 6 GHz-capable phys) gave every AP `country_code=00` with `ieee80211d=1`; hostapd failed with `Invalid country_code '00'` and **no AP started**. | Fixed: **dev patch 0010** (also in the AX23 image). Prefers the radio's own country, else the first explicit non-`00` one, and never passes `00`. Before/after: run 2 W03/W04 PASS (run 1: FAIL). |
| 2 | harness | `.test` is a locally-served domain in OpenWrt's dnsmasq | test name changed (router behaviour correct) |
| 3 | harness | dnsmasq's DNS-rebind protection treats the documentation nets (192.0.2/24, 198.51.100/24, 203.0.113/24) as private and refuses answers pointing there (`rfc1035.c: private_net()`) | simulated Internet moved to a public-style address (router behaviour correct and desirable) |
| 4 | harness | a hwsim phy moved into a namespace has no interface | the station helper creates one |
| 5 | harness | LuCI must be requested as `/cgi-bin/luci/` (the root page redirects there); BusyBox `pgrep -c` is not available | fixed |
| 6 | **shipped UCI profile** `configs/uci/10-guest-iot-networks.uci` | In this OpenWrt revision a `dhcp` section defaults to `dhcpv4 'disabled'`. The profile omitted `option dhcpv4 'server'`, so guest and IoT clients associated but got **no DHCP lease** (`no address range available for DHCP request via br-guest`). It would have failed the same way on the real router. The namespace simulation missed it because it used its own dnsmasq instead of OpenWrt's init scripts. | Fixed in the profile (run 6 W20/W24 PASS) |
| 7 | twin provisioning | rewriting `/etc/config/wireless` from uci-defaults raced with wifi auto-detect hotplug and one run started with no APs | network/wireless configs now shipped in the twin image |
| 8 | harness | BusyBox ping on OpenWrt rejects fractional `-i`; LuCI's login page is served with HTTP 403 (by design) | fixed |
| 9 | build | copying `build_dir/host` between OpenWrt trees carries absolute install prefixes (pkgconf/meson) | host-tool seeding removed from both build scripts |

## Remaining limits (unchanged by any simulation)

Wi-Fi on the real board still needs the unit's own board data (see
`wifi-investigation.md`). Real ath11k memory use, RF performance, switch VLAN/ASIC
behaviour, trunk stability, NAND install and recovery can only be validated on
hardware (`tests/hardware/HARDWARE-TEST-PLAN.md`).
