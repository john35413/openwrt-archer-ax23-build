# Ethernet, switching and routing validation

Tags as in `source-audit.md`. Simulation results (`[SIM]`) come from
`tests/network/run-netns-tests.sh`, run in a QEMU VM with a stock Linux 6.8
kernel. They exercise Linux bridging/VLAN/nftables/dnsmasq **in software only**:
not the IPQ5018 GMAC, not the 2.5G UNIPHY trunk, not the RTL8367S-VB switch.
**A simulated PASS is not evidence that the router works.**

## 1. Hardware path

```
IPQ5018 GMAC1 --UNIPHY0 (2500base-x, fixed-link, pause)--> RTL8367S-VB port 6 (CPU, DSA tag)
RTL8367S-VB: port0 = wan, ports 1-4 = lan1..lan4 (internal PHYs 0-4 on the switch's SMI MDIO)
switch on mdio1 @ 0x1d (GPIO36 MDC / GPIO37 MDIO), reset GPIO39 (active low); mdio0 kept enabled
```

| Item | Evidence | Status |
|---|---|---|
| Switch probe as RTL8367S-VB | `[HW-3P]` boots v0.2-v0.5 | PASS (third party, AX21 v5) |
| CPU trunk 2.5G full duplex, rx/tx pause | `[HW-3P]` `Link is Up - 2.5Gbps/Full - flow control rx/tx` | PASS (third party) |
| HSGMII is the stock mode | OEM 312.5 MHz UNIPHY clock, `forced-speed 2500`, U-Boot `Set RTL8367S SGMII 2.5Gbps` | `[SRC]` + stock runtime measurement by Sply |
| Cold-boot trunk training race | Upstream: 18/51 failed boots → 0/32 with PR #26597 (MR80X v2). AX21 v5 with v0.5-test: 5/5 OK (3 power cycles, 2 reboots) `[HW-3P]` | dev 0006-0009 applies the fix; **our build NOT HARDWARE TESTED** |
| 777-08 periodic SerDes park | `[SRC]` risk, see `source-audit.md` R1 | test `pc-traffic-tests.sh --mode trunk-gaps`; NOT HARDWARE TESTED |
| lan1-4 in br-lan, LAN-to-LAN forwarding | `[HW-3P]` v0.3 (SSH into a second router through lan2) | PASS (third party) |
| WAN 1G/Full, router-originated ping | `[HW-3P]` v0.4-2/v0.4-3 | PASS (third party) |
| LAN client DHCP, DNS, NAT, web browsing, speedtest ≈445/100 Mbit/s | `[HW-3P]` v0.5-test, 2026-11-20 (5 boots) | PASS (third party, ISP-limited figure; not a router maximum) |
| Board scripts: `lan1-4`→br-lan, `wan`→wan, LED triggers | `[STATIC]` `gen-fw4-ruleset.sh` runs the image's own `board_detect`/`config_generate` under qemu-user | see `simulation-results.md` |

## 2. Software configuration tested in simulation `[SIM]`

Topology: ISP (DHCP/DNS) + "internet" host + second uplink; router namespace with
a VLAN-filtering `br-lan` (ports lan1/lan2 → VLAN 1 lan, lan3 → VLAN 20 guest,
lan4 → VLAN 30 IoT, the same structure DSA bridge-VLANs give on the AX23);
clients `c1 c2 g1 i1`. Rulesets tested: (a) a reference with fw4's structure, and
(b) **the ruleset produced by the built image's own `fw4`** for the shipped config
(`configs/uci/10-guest-iot-networks.uci`).

Covered: WAN DHCP client, LAN/guest/IoT DHCP, DNS forwarding, router reachability,
client-to-client L2 switching (proven not to be routed), NAT source rewrite,
TCP/UDP through NAT, sustained TCP load + latency, UDP stream, guest→Internet only,
IoT no Internet, LAN→IoT allowed, no L2 leakage between VLANs, WAN inbound blocked
(v4/v6), fw4 Allow-Ping, IPv6 SLAAC + routing + UDP, software flow offload,
5 % loss / 40 ms uplink integrity, CAKE shaping, WAN carrier-loss failover and
recovery. Results and numbers: `simulation-results.md`.

Not simulated: PPPoE (no PPPoE server in the harness; `ppp-mod-pppoe` is in the
image), multi-WAN policy routing with mwan3 (failover was tested with kernel
link-down route handling only), DSA tagging and the switch's own VLAN table
(the RTL8367S-VB VLAN 4k/PVID code from 777-05/06 only runs on real hardware).

## 3. Hardware tests still required

HW-03 … HW-11, HW-22 and HW-26 in `tests/hardware/HARDWARE-TEST-PLAN.md`:
per-port link, real client-to-client switching throughput (must stay in the switch),
NAT throughput with iperf3 (CPU-bound; ~450 Mbit/s without NSS is the third-party
experience, **not measured by us**), trunk-gap detector, VLAN isolation **on the
switch**, 20× reboot/power-cycle trunk reliability with our dev build.

## 4. Status

| Component | Status | Evidence type |
|---|---|---|
| Ethernet switch | PASS (third party) / NOT HARDWARE TESTED (our build) | `[HW-3P]` |
| LAN ports | PASS (third party) / NOT HARDWARE TESTED (our build) | `[HW-3P]` |
| WAN | PASS (third party) / NOT HARDWARE TESTED (our build) | `[HW-3P]` |
| NAT / DHCP / DNS | PASS (third party, v0.5-test) + PASS `[SIM]` | `[HW-3P]` + `[SIM]` |
| VLAN isolation | PASS `[SIM]`; switch VLAN table NOT HARDWARE TESTED | `[SIM]` |
| Firewall | PASS `[SIM]` with the image's own fw4 | `[SIM]` |
