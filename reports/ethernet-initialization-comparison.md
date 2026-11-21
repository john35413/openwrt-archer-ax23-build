# Ethernet / RTL8367S-VB initialisation: OEM vs ours vs siblings

**Reset trace (OEM binary + GPL source, [rtl8367-reset-trace.md](rtl8367-reset-trace.md)).** TP-Link's U-Boot and the signed stock kernel both reset the RTL8367 on GPIO 26, active low (U-Boot 500 ms, kernel 200 ms); GPIO 39 is read only by the QCA8337 code path. The DTS keeps 39 until continuity is measured. The vendor also applies a 129-write SerDes patch (`SDSNctrlPatch`) that our driver lacks. It is a ROM patch for the switch's NCTL SerDes-control sequencer (§6 there); it is proprietary and has no open implementation. The documented family-D carrier-up/no-frames cause is handled by 777-08 and 0006–0009, so NCTL stays a candidate only if S2.4 fails with re-latch events logged. A 1 G SGMII diagnostic variant is prepared in `patches/variants/` (not in the image).

**Codex source comparison.** The signed EU DT has two different reset properties. Their physical destinations remain unknown. Keep GPIO 39 pending passive continuity or waveform evidence. Of ten 777 patches in two pinned sibling trees, eight differ in bytes from the project pin and none showed an executable hunk difference. The separate 778 conduit-up change remains a candidate if the trunk reports carrier while dropping frames. See [the patch audit](codex-patch-audit.md) for revisions.

Labels as in `wifi-root-cause.md`. Complements `ethernet-nat-validation.md`.

## 1. Silicon and topology (AX23 v2)
- Switch: **RTL8367S-VB**, chip id/version **0x6642 / 0x0010** (rtl8365mb "family D"),
  MDIO address 29 on `mdio1` (0x90000). **HW-3P** probe line "found an RTL8367S-VB".
- CPU trunk: IPQ5018 **gmac1 → UNIPHY0 → HSGMII (2500base-x)** → switch port 6.
  OEM: `switch_mac_mode = 0x0c` (SGMII+, TP-Link edit), `forced-speed 2500`, NSS-DP.
  Ours: stmmac `dwmac-ipq5018` + `pcs-qca-uniphy` + rtl8365mb DSA, fixed-link 2500,
  conduit MTU 1508 (8-byte RTL8_4 tag). **HW-3P**: link up at 2.5 G and real client
  NAT (≈445/100 Mbit/s), 5/5 boots.
- Ports: lan1–lan4 + wan on the switch PHYs 0–4 (02_network, HW-3P forwarding).

## 2. Driver code we run vs siblings
| Item | AX23 (ours) | EX511 v2 (kuncy7) | MR80X v2 (main) | AX55 v1 (main) |
|---|---|---|---|---|
| mainline rtl8365mb backports 942–946 (VLAN/FDB/bridge, SGMII, HSGMII) | yes | yes | yes | yes |
| family-D series `777-01..10` v7 (RTL8367S-VB, SDS13 PCS, LUT, 777-08 re-latch) | yes | **same v7 code** (only context/offset refreshes differ) | n/a in main | n/a |
| UNIPHY probe-time programming (#26597, our 0006–0009) | **yes** | not identified in their tree | not in base (race noted) | — |
| trunk speed shipped | **2.5 G** (HW-3P works) | **1 G SGMII** (2.5 G: link up, **zero frames**) | **1 G SGMII** (2.5 G: 2/12 boots no traffic) | 2.5 G |
| switch reset GPIO | 39 (from a QCA8337 boilerplate node) | 33 (HW-verified) | **26** on `&mdio1` (HW-tested) | 33 |

## 3. Findings
1. **The 2.5 G trunk failure seen on two siblings is real for this switch family**
   (REL). EX511 hit it with the *same* family-D code we ship, and MR80X describes
   the mechanism: the switch end of the trunk gets configured before the IPQ5018
   UNIPHY resets and recalibrates its PLL. Our image carries the UNIPHY probe-time
   programming (0006–0009), and AX23 HW-3P logs show traffic at 2.5 G. The EX511
   difference is **not fully explained** (UNIPHY ordering vs board-level SerDes
   tuning). **Mitigations in place:** `ax23-selfdiag.sh` S2.4 checks that frames
   actually cross the trunk (link-up alone proved nothing on EX511/MR80X); the
   20× cold/warm boot test is in Stage 3.
2. **Fallback if S2.4 fails on our unit:** the siblings' working configuration:
   gmac1 `phy-mode = "sgmii"` with fixed-link 1000 **and** the CPU port at sgmii
   (both ends must match, per MR80X). 1 G full-duplex per direction is enough for a
   1 G WAN, because WAN→LAN traffic crosses the trunk once in each direction.
   Documented as a variant, not applied: 2.5 G is what HW-3P validated.
3. **Switch reset line: probably GPIO 26, not 39** (`oem-openwrt-differential-analysis.md`).
   Today the switch runs on U-Boot's initialisation, and the driver's reset pulse on
   GPIO 39 likely reaches nothing. Effect: no deterministic switch reset in Linux.
   This is a robustness item for warm/cold-boot repeatability, not a bring-up blocker.
   Variant to measure after the Stage-3 baseline (MR80X form: `&mdio1 { reset-gpios =
   <&tlmm 26 GPIO_ACTIVE_LOW>; }` + pull-down pinctrl).
4. **777-08 SerDes re-latch** (10 s health check, 20 ms lane park): dropped in the
   upstream v13-pre0 series. Kept because it is part of the HW-3P-validated
   combination. S2.5 counts its events, and `pc-traffic-tests.sh --mode trunk-gaps`
   measures any traffic gaps it causes.
5. **Flow control / MTU / VLAN:** `pause` on both fixed links honoured by
   `rtl8365mb_ext_config_forcemode()` (SRC); conduit 1508 (HW-3P). Guest/IoT
   isolation is verified only on the Linux bridge (SIM). On hardware it runs through
   the 942 VLAN/bridge offload on the switch, which Stage 3 must verify on a real
   port (e.g. lan4 in the IoT VLAN, profile `20-wired-vlan-lan4.uci`).
6. **LAN→WAN NAT** is HW-3P-validated with real client traffic (not just
   router-originated ping). Our build adds UNIPHY fixes only. Stage 3 repeats it with
   `pc-traffic-tests.sh --mode lan-wan`.

## 4. What is NOT copied
No OEM SSDK register sequence was transplanted. The OEM `ar8327-initvals` belong to a
QCA8337 this board does not have. EX511's GPIO 33 reset is board-specific (GPIO 33 is
the AX23's 2.4 GHz LED).

## Codex comparison of reset owners and cold-start timing

| Source | Controller, line and consumer | Polarity, mux and timing evidence |
|---|---|---|
| Signed AX23 EU 1.2.1 mp02.1 DT | TLMM 26 at MDIO phy-reset-gpio; separate QCA83xx reset_gpio 39 | GPIO 26 pinctrl requests pull-down and output-low. An alternate UART CTS mux also exists in the tree. The vendor property and numeric flag alone do not establish polarity at the RTL8367S-VB pin. The QCA83xx table targets a different switch. |
| AX23 development DTS | TLMM 39 on switch@1d, MDIO address 29 | GPIO_ACTIVE_LOW. Device-tree metadata establishes the requested polarity. No physical pulse or connection to nRESET was observed. |
| Pinned OpenWrt MR80X DTS | TLMM 26 on MDIO | Bus-level reset. The independent hardware-tested MR80X branch below uses a different configuration. |
| Gameplayer MR80X working branch | TLMM 39 on MDIO, TLMM 26 on the switch | Both active low. Switch revision 0x00a0, CPU port 6. Its owner reports that interrupting U-Boot changes whether the switch gets initialised. Separate vendor, switch revision and board. |
| Archer AX55 v1 DTS | TLMM 33 on the switch | Active low with the switch driver owning the pulse. AX23 uses GPIO 33 for an LED. |

VERIFIED BY OEM SOURCE ANALYSIS and VERIFIED BY UPSTREAM SOURCE ANALYSIS for the properties above. Whether the AX23 bootloader drives GPIO 26 to the Realtek reset input is UNVERIFIED HYPOTHESIS. Neither the public board views nor the reviewed code establish trace continuity. Use passive continuity to the switch reset net, or correlate both candidates with a high-impedance observation of nRESET on stock cold boot. Do not actively drive either candidate to decide wiring. [Signed AX23 EU firmware](https://static.tp-link.com/upload/firmware/2026/202611/20261113/Archer%20AX23%20_V2_1.2.1%20Build%2020261026.zip) · [MR80X measured setup](https://github.com/Gameplayer-1-8/openwrt_mrx80_v2/tree/b429b145cddc7cb6f8191e364e5b4011e1e5e04d) · [AX55 device tree](https://github.com/openwrt/openwrt/blob/73c3e16baca94b628759ad10c395fc2e87df9f7a/target/linux/qualcommax/dts/ipq5018-archer-ax55-v1.dts)

VERIFIED ON RELATED HARDWARE. The separate MR80X port reports successful 2.5 Gb/s trunk operation after respecting chip reset and SerDes settle times. Its 69,000-packet observation covers that board only. In the actual AX23 prepared family-D path the driver issues the same two-phase BMCR reset and proceeds immediately to the next SerDes access. At the chip level it polls after just 100 ms despite documenting a one-second reset interval. Patch 0025 waits one second before polling the family-D chip and 98 ms after the family-D BMCR datapath reset. It preserves the register sequence and GPIO mapping. Cold-boot success, packet loss and effect on restart latency remain physical tests. [Sibling patch](https://github.com/Gameplayer-1-8/openwrt/commit/e839879dda243b)

VERIFIED BY UPSTREAM SOURCE ANALYSIS. The selected DT binds the IPQ5018 CMN PLL at 0x9b000, with AHB and SYS clocks. The pinned driver drops its last probe reference, matching the early-boot timing problem reported on AX55, GL-B3000 and Cudy P5. Patch 0024 takes a device-managed reference, scoped to the IPQ5018 compatible. Probe failure and unbind release it. Do not infer a steady-state clock dependency from the boot failure. The author's late-gating experiment on GL-B3000 specifically distinguished these cases. [Upstream v4 submission](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2608.1/10164.html) · [Author's observations](https://lore-kernel.gnuweeb.org/linux-arm-msm/20260811195317.128954-1-kuncy7%40gmail.com/T/)

The sibling QPIC SET_FEATURE ordering correction is already in the base Linux 6.18.55 sources. The value is programmed before command execution and the later io_op returns without a duplicate write. The extra sibling change that removes ESMT OTP registration has no demonstrated need here. Keeping normal ESMT support preserves driver functionality. NAND OTP in this context is separate from the Wi-Fi QMI board ID. [Pinned QPIC driver](https://github.com/gregkh/linux/blob/v6.18.55/drivers/spi/spi-qpic-snand.c)
