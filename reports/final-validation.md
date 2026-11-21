# Final validation: TP-Link Archer AX23(EU) v2.0 OpenWrt

Date: 2026-11-21. **No physical AX23 v2 was used by this project. No router was
connected, flashed or modified.**

Evidence kinds: **SRC** source inspection · **STATIC** static/offline test ·
**SIM** simulation (namespaces in a VM / qemu-user) · **HW-3P** third-party
hardware logs on an *AX21 v5 (US) running AX23 v2 firmware* (not an EU AX23 v2) ·
**HW** our own hardware test (none) · **TWIN** full-system digital twin: the same OpenWrt software booted in QEMU with simulated radios (`reports/digital-twin.md`, 48/48 PASS in three consecutive runs (6, 7, 8)). TWIN never exercises the AX23 chips.

## Deliverable

`artifacts/ram-only/dev/openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`
(13,321,784 bytes, sha256 `aac3c65684eca661677b511b4cf2275013b1399753795b71cf736c5f009d466e`; built from scratch with patches 0001-0010, no host-tool seeding).
**RAM boot only (UART + TFTP).** Binaries are git-ignored; rebuild with `./tools/build-dev.sh --variant dev`.
The checksums and BUILDINFO are committed. Everything in `artifacts/experimental-do-not-flash/` stays unflashed.

## Validation matrix

| Component | Status (our dev build) | Evidence |
|---|---|---|
| Linux boot | NOT HARDWARE TESTED | STATIC: FIT/DTB/load-address validation (`reports/artifacts-dev.txt`). HW-3P: same kernel/DTS family boots via TFTP (v0.2-v0.5). TWIN: userspace boots, reboot recovery S05 |
| Ethernet switch | NOT HARDWARE TESTED | HW-3P: RTL8367S-VB probe, 2.5G trunk, 5/5 boots (v0.5-test). SRC: 777 v7 + UNIPHY fix #26597 |
| LAN ports | NOT HARDWARE TESTED | HW-3P: lan1-4 forwarding (v0.3). STATIC: the image's board.d produces lan1-4→br-lan |
| WAN | NOT HARDWARE TESTED | HW-3P: 1G link, DHCP, external ping. SIM N01. TWIN T04-T06 (DHCP, IPv6) |
| NAT | NOT HARDWARE TESTED | HW-3P: client browsing + 445/100 Mbit/s speedtest (v0.5-test). SIM N09-N13 PASS. TWIN T11-T15 |
| DHCP/DNS | NOT HARDWARE TESTED | HW-3P: client DHCP via router. SIM N03-N06, N17. TWIN T08/T09, W05/W06/W20/W24 |
| Wi-Fi 2.4 GHz | **BLOCKED** (hardware) | root cause found (no board data; SRC + HW-3P logs); fix packaged; needs the unit's own board data. TWIN: the configuration above the driver works (AP, WPA2, HE, DHCP, Internet, Wi-Fi↔LAN) |
| Wi-Fi 5 GHz | **BLOCKED** (hardware) | as above. TWIN: HE80 ch 36, WPA3-SAE/PMF, 20/20 reconnects |
| WPA2/WPA3 | NOT HARDWARE TESTED | TWIN W05-W08, W17-W19: WPA2-PSK and WPA3-SAE work; wrong password and WPA2-on-SAE-only correctly rejected |
| VLAN | NOT HARDWARE TESTED | SIM N03-N05, N14-N22 (Linux bridge VLAN, not the switch VLAN table). TWIN W20-W26: guest/IoT SSIDs and isolation |
| Firewall | NOT HARDWARE TESTED | SIM: the image's own fw4 ruleset, N14-N29. TWIN T17/T18, W22/W23/W25 |
| VPN (WireGuard) | NOT TESTED | optional package list only |
| A/B boot | NOT TESTED | SRC: `tp_boot_idx` design; HW-3P: U-Boot env has a bad CRC → hazard documented |
| NAND installation | **BLOCKED** | no validated env size/bootcmd; sysupgrade interlocked (STATIC) |
| Recovery | **BLOCKED** (for us) | HW-3P: UART + TFTP RAM boot works; we have no 1.8 V UART adapter |
| Long-term stability | NOT HARDWARE TESTED | TWIN S04: 3 min mixed load only; 24/48 h soak scripts ready (`tests/hardware/soak-monitor.sh`) |

No hardware-dependent item is marked PASS.

## Decision

### **B. PROMISING BUT INCOMPLETE**

The build is reproducible, the Wi-Fi blocker has an identified root cause and a
clear fix path, and third-party tests show the wired side (switch, trunk, LAN, WAN,
DHCP, NAT) working on closely related hardware. But both radios remain
unverified and blocked on board data that only the user's unit can provide, there is
no validated NAND install or UART-free recovery, and nothing has run on an EU unit.

**Daily production use: NO.** RAM boot only. It loses everything on power-cycle,
has no Wi-Fi yet, and needs a UART cable to start.

## What works (as far as evidence goes)

- Reproducible baseline and dev builds from pinned SHAs (STATIC).
- Wired switching, trunk, LAN→WAN routing/NAT, DHCP/DNS on the third-party unit (HW-3P).
- Board scripts, the shipped guest/IoT profile and fw4 policy in simulation (SIM 33/33).

## What does not work / is unproven

- Wi-Fi: both radios fail at board data (-12). Fixed in packaging; data must be extracted from your own unit.
- No persistent installation; sysupgrade deliberately refused.
- No UART-free install or recovery method exists that can be shown to be safe.
- EU vs. US hardware equivalence is not proven (same firmware image lists both regions).

## What I fixed (patches/openwrt, applied on Sply-Dev v0.5-test)

1. Upstream `ath11k_remove_regdomain` bug that zeroed unrelated caldata words (with regression test).
2. ath11k host RX rings sized at runtime for FW memory mode 2 (about 42 MiB less pre-posted RAM, source estimate).
3. Board-data package `ipq-wifi-tplink_archer-ax23-v2` plus extraction tooling. This addresses the Wi-Fi root cause.
4. Wi-Fi LED phy mapping reversed in the DTS.
5. sysupgrade interlock: the board previously fell through to `default_do_upgrade`.
6. Upstream UNIPHY cold-boot trunk fix #26597 plus its three prerequisites.
7. **wifi-scripts bug (found by the digital twin, dev patch 0010):** one radio left at country `00` made hostapd reject every AP's config, so no AP started.
8. **Guest/IoT profile bug (found by the digital twin):** the profile lacked `dhcpv4 'server'`, so guest/IoT clients would have received no DHCP lease on the real router.
Also corrected in the build process: the 777 patch placement, the root-user configure issue, and unsafe host-tool seeding between build trees (removed; the dev image was rebuilt from scratch).

## Tests actually executed

Static checks, 4 unit suites, fw4/board.d under qemu-user, 33 network-namespace tests in a VM,
artifact validation of both builds, and the **digital twin**: 48 end-to-end checks, 48/48 PASS in two
consecutive runs after the bugs above were fixed. See `simulation-results.md` and `digital-twin.md`.
**Zero hardware tests.**

## Next blocking problem

Wi-Fi board data. RAM-boot the dev image with a 1.8 V UART adapter, take the read-only backup,
extract `bdwlan.b24`/`bdwlan.b60` (EU directory), rebuild, then run HW-12…HW-17.

## Can it become a stable OpenWrt router?

Realistically yes for the **wired** side: the evidence is good. For **Wi-Fi**, probably. The same
Q6/QMI stack already reaches the BDF stage on this board, and sibling 256 MB IPQ5018+QCN6122 boards
run both radios with reduced rings. The 256 MB memory budget is the main long-term risk; the
24/48 h soak will settle it. Expect about 450 Mbit/s NAT without NSS (third-party figure).
Mainline acceptance is uncertain because of 256 MB.

## UART / physical intervention

**Required.** A 1.8 V UART is the only verified way to boot test images and to recover.
The case must be opened, and the unpopulated level-shifter pads bridged or bypassed.

## Keep or return the unopened device?

If you need a reliable Wi-Fi 6 router now, or you don't want to open the case and solder 1.8 V UART
wires, **return it** and buy a device with official OpenWrt support. If you want to take part in the
bring-up and accept UART work, **keep it**. The path is concrete, and your unit would be the first EU
AX23 v2 tested. Opening the case may void the warranty and makes a return impossible.

---

## Update 2026-11-21 (second investigation): blockers, root causes, Go/No-Go

New primary evidence: TP-Link's GPL source for this model (U-Boot) and all four official
firmware images (signatures verified with TP-Link's own public keys). Details:
`wifi-root-cause.md`, `boot-nand-feasibility.md`, `ethernet-nat-validation.md`, `stability-risks.md`.

Current RAM-boot image: `artifacts/ram-only/dev/…initramfs-uImage.itb`, sha256
`3bc04b192a06e11f7597d72c80cf777f467bd7239c243e70e13d5f8491d0544f` — patches 0001-0011 **plus the
EU board data** generated from the official firmware (proprietary data: image kept local, not
committed; reproduce with `tools/bdf/board-data-from-tplink-firmware.sh` + `tools/build-dev.sh`).

### Decision table

| Component | Current evidence | Exact remaining blocker | Fix implemented / proposed | Validation still required | Risk | Confidence |
|---|---|---|---|---|---|---|
| Wi-Fi 2.4 GHz | `-12` = missing board file (STATIC, full path traced; 3P log). EU board data from official FW, region-selected like stock (STATIC). DTS = stock pd1/mem-mode 2 (STATIC) | none known offline | board-2.bin in image; 0001, 0002, 0010 | one RAM boot: dmesg shows fw_build_id, no fetch errors; AP + clients | medium (memory, FW 2.7 vs stock 2.5) | moderate: every known cause addressed; no HW run |
| Wi-Fi 5 GHz | same; stock uses userpd2 + board_id 0x60 = our pd2 (STATIC); userpd2 reached QMI on HW (3P) | none known offline | same | same + 5 GHz throughput/overflow | medium | moderate |
| WPA2/WPA3, guest/IoT | QEMU 48/48 ×3; profile DHCP bug fixed | radios on HW | 0010, profile fix | HW-13…HW-17, HW-22 | low once radios up | high for config, none for HW |
| Switch / LAN / WAN / NAT | 3P: client NAT + browsing, 5/5 boots (v0.5-test) | our exact build not run on HW | 0006-0009 (#26597) | HW-03…HW-11, HW-26 | low-medium | moderate-high |
| VLAN / firewall | QEMU (fw4 of the image) | switch VLAN table on HW | — | HW-22 | low-medium | moderate |
| VPN / SQM / Pi integration | packages/configs exist; CAKE works in simulation | not on HW | optional profile | after base validation | low | moderate |
| Memory/stability | 173 MiB available pre-Wi-Fi (3P); RX rings reduced | real FW + driver usage unknown | 0002 | `free`, 24/48 h soak | **medium-high** (the main long-term risk) | low-moderate |
| RAM boot | 3P: UART + TFTP works | needs 1.8 V UART | — | first boot | low | high |
| Ethernet-only RAM boot | not possible (STATIC: autoboot runs only bootipq) | inherent | — | — | — | high |
| UART-free stock recovery | in TP-Link U-Boot source: reset-held HTTP recovery, signed plaintext images (STATIC) | not observed on HW | documented passive test | passive test §4 of boot report | low | moderate |
| Persistent install | design only; env layout now verified (0011) | UART, backup, recovery drill | interlock 0005 | items 1-7 in boot report §6 | high until validated | n/a |
| UART-free OpenWrt install | impossible without an exploit (signatures enforced in web UI and U-Boot; STATIC) | inherent | — | — | — | high |

### Verdict: **CONDITIONAL GO**

The device can realistically become a stable OpenWrt router: the wired path has third-party
hardware proof of working NAT, the Wi-Fi blocker is understood and addressed with the
manufacturer's own board data, and a UART-free *stock* recovery exists in the vendor's
bootloader source. Conditions (all mandatory):
1. The owner accepts **opening the case and using a 1.8 V-safe UART** — there is no
   UART-free way to boot or install OpenWrt on this model (vendor-signature enforced).
2. The first RAM boot shows both radios initialising (single observation in `wifi-root-cause.md` §7).
3. The passive reset-held recovery test shows the U-Boot HTTP recovery page.
4. Memory stays healthy in a 24 h soak with both radios loaded.

**If condition 1 is unacceptable (owner's stated preference: no UART), the answer is NO-GO
for this owner** → return the router while it is unopened and buy a model with official
OpenWrt support and a UART-free install path.
