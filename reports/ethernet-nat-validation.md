# Ethernet, switch and NAT validation: readiness for physical testing

Labels as in `wifi-root-cause.md`. Complements `ethernet-validation.md`.

## 1. What real hardware has shown (all 3P: AX21 v5 running AX23 v2 firmware)

| Fact | Evidence |
|---|---|
| RTL8367S-VB probed by rtl8365mb (777 v7 series) | boot logs v0.2-v0.5 |
| CPU trunk `eth0` (ipq5018-gmac-dwmac) "Link is Up - 2.5Gbps/Full - flow control rx/tx" | logs |
| DSA conduit MTU 1508, user ports 1500 (8-byte RTL8_4 tag accounted) | `ip link` output, post #52+ |
| lan1-4 enslaved to br-lan, LAN↔LAN forwarding (SSH into a device behind lan2) | v0.3 |
| WAN 1G/Full, router ping 1.1.1.1 | v0.4-2/v0.4-3 |
| **LAN client DHCP + web browsing + speedtest ≈445/100 Mbit/s through NAT, 5/5 boots (3 cold, 2 warm), no trunk change** | v0.5-test, post #71/#73 (2026-11-20) |

So LAN-to-WAN NAT is no longer just "router-originated ping": a third party routed real client
traffic. Caveats: one tester, one unit, US variant, ISP-limited throughput, v0.5-test binary
(which per the forum includes UNIPHY PR #26597, as our dev patches 0006-0009 do).

## 2. Our build vs what was tested

| Item | v0.5-test (3P tested) | Our dev image | Risk |
|---|---|---|---|
| rtl8365mb family D | 777-01…10 (v7) | identical files | none |
| UNIPHY probe-time programming (#26597) | reportedly included | 0006-0009 (+3 same-file prerequisites from main) | low: prerequisites are bug fixes in the same driver; not HW-run in this exact combination |
| Network defaults (lan1-4/wan) | 0002 | same | none (STATIC + QEMU-userspace) |
| Historic "eth0 master br-lan" | v0.2 only (pre-0002) | not present | ruled out (STATIC + 3P later logs) |
| fw4 / masquerade | default | default; image's own fw4 ruleset tested | QEMU 33/33 (`simulation-results.md`) |
| Hardware flow offload | — | not available on ipq50xx (no PPE driver); software flowtable only | n/a |

## 3. Source review notes

- **777-08 (SerDes re-latch)** keeps a 10 s health-check that parks the lane for 20 ms on a
  "link down" read; upstream v13-pre0 drops this patch. 3P logs show no symptom; detector:
  `tests/hardware/pc-traffic-tests.sh --mode trunk-gaps`. **Not changed** (it is the tested combination).
- `pause;` on both fixed links is honoured by `rtl8365mb_ext_config_forcemode()` (STATIC; corrected in forum #11).
- Switch reset GPIO39: matches TP-Link's stock DTB `reset_gpio = <0x27>` (STATIC, official firmware); U-Boot's
  `CONFIG_SWITCH_RESET=26` is unused by any U-Boot code (STATIC) → not evidence against 39.
- Checksum/DMA: 3P web traffic + speedtest through NAT shows no corruption symptoms; no source defect found.

## 4. Readiness verdict

**Technically ready for physical validation** of our dev build. Expected to behave like v0.5-test.
Remaining hardware acceptance (none can be done offline): all four LAN ports individually,
guest/IoT VLAN isolation on the switch (bridge-VLAN on DSA ports — only Linux-bridge behaviour
is QEMU-verified), sustained iperf3 LAN→WAN and LAN↔LAN, trunk-gap test, 20× warm/cold reboot
with LAN→WAN each time — `tests/hardware/HARDWARE-TEST-PLAN.md` HW-03…HW-11, HW-22, HW-26.
