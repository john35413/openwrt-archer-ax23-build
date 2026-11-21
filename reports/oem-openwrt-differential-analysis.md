# OEM vs OpenWrt: how TP-Link initialises this hardware, and how we do

Labels: **OEM** read from TP-Link's official AX23 v2 firmware (1.2.1 FIT `fdt@mp02.1`,
the configuration its U-Boot boots; stock rootfs), **GPL** TP-Link's GPL tarball
(U-Boot 2016 + linux-4.4 incl. Qualcomm's reference `qcom-ipq5018-mp02.1.dts`),
**SRC** our tree, **REL** related hardware, **HW-3P** AX21 v5 running AX23 v2
firmware. Nothing here ran on our router. No OEM binary or calibration data is
committed; only facts derived from them.

**Method note (important):** `fdt@mp02.1` is Qualcomm's MP02.1 reference DT as edited by
TP-Link. To avoid treating reference boilerplate as AX23 wiring, every OEM value
below was diffed against the unedited reference `qcom-ipq5018-mp02.1.dts` in TP-Link's
own GPL tree. "**TP-Link edited**" means the value differs from the reference, which
is strong evidence that it is board-specific. "**reference**" means it was inherited
unchanged, which is weaker evidence.

## 1. Differential table

| Subsystem | OEM implementation | Our OpenWrt implementation | Difference | Risk | Correction | Evidence |
|---|---|---|---|---|---|---|
| Q6 root PD | `qcom,ipq5018-wcss-pil`, `qca,auto-restart`, `qcom,share_bootargs`, `bootargs_smem 0x1fb` | `qcom,ipq5018-wcss-sec-pil` (TZ-authenticated loader), recovery via remoteproc | different driver, same firmware ABI path (QMI reaches BDF stage on HW) | low | none needed | OEM + HW-3P |
| Q6 crash recovery | `qca,auto-restart` on root + both user PDs: firmware restarts on crash | wcss-sec set **`RPROC_COREDUMP_INLINE`**: recovery would wait for an unread devcoredump (5 min, radios down) | **we were worse than stock** | **high** (multi-minute Wi-Fi loss per crash) | **patch 0016** (upstream main b97760cbc9): coredump disabled by default, recovery immediate | SRC + REL (IPQ6018 HW) |
| boot-args | 2 tuples: `<1 4 3 0x0f 0 0>` (PCIE0, UPD3, gpio15) + `<2 4 2 0x1b 0 0>` (PCIE1, UPD2, gpio27) — **TP-Link edited** (reference: tuple 1 only) | tuple 2 only | we omit the UPD3 tuple; UPD3 radio (`wifi2`) is **disabled** in OEM too | low | keep (HW-3P: userpd2 up with tuple 2 alone; avoids driving gpio15 for an absent radio); fallback = add tuple 1 only if UPD2 fails | OEM/GPL + HW-3P |
| 2.4 GHz radio | `wifi@c000000`, userpd1, `tgt-mem-mode 2`, `board_id 0x24` (**edited**, ref 0x10), caldb off | pd1, mode 2, caldb off (mode 2 sets `coldboot_cal_mm=false`) | board id comes from OTP in ath11k, from DT in OEM | **was high** (an OTP ≠ 255 broke the lookup) | **board-2.bin now also keyed on 36 and the chip-id name** — resolves for any OTP | OEM + SRC + BUILD |
| 5 GHz radio | `wifi1`, userpd2, mode 2, `board_id 0x60` (**edited**, ref 0x90), separate `qcn6122/m3_fw.mdt` | pd2, `q6v5_wcss_userpd2`, mode 2 | same as above | same | same (key 96) | OEM + BUILD |
| BDF selection | preinit copies `/EU/default/*` then `/EU/$HW_VER/*`; driver loads `bdwlan.b24` / `qcn6122/bdwlan.b60` by DT board_id | EU files from the signed OEM image, packed into board-2.bin | equivalent data, different container | none | — | OEM |
| Q6 memory | `q6_region` 0x4b000000 + 42 MiB; IPQ5018 data @0x4c000000 (11 MiB), QCN6122 @0x4cc00000 (13 MiB) — **edited** (ref: QCN6122 @0x4d300000) | OpenWrt layout 0x4b000000 + 48 MiB, bdf 0x4c400000 / 0x4d100000, m3-dump 0x4df00000 | host tells FW the addresses over QMI; 6 MiB more reserved | low (3P reached BDF stage with ours) | keep (upstream ipq50xx policy, same on RE700X/MR80X) | OEM + SRC + HW-3P |
| NSS | 8 MiB `nss@40000000`, NSS-DP offload | **no NSS** (stmmac + software forwarding) | +8 MiB RAM for us; no hardware NAT | low | keep (NSS is proprietary, needs more RAM) | OEM + SRC |
| Switch/trunk mode | `switch_mac_mode = 0x0c` (**edited**, ref 0xf) = SGMII+ (HSGMII 2.5G), `forced-speed 0x9c4` (2500) | `2500base-x` fixed-link, rtl8365mb HSGMII | equivalent | low (3P trunk OK) | — | OEM + HW-3P |
| **Switch reset line** | `mdio@90000 { phy-reset-gpio = <&tlmm 26 0> }` + pinctrl `phy_reset: gpio26, pull-down, output-low` (**reference**); TP-Link U-Boot `CONFIG_SWITCH_RESET=26` (**product config**); `ess-switch1@1 { reset_gpio = <0x27> }` (**edited**, but `compatible = "qcom,ess-switch-qca83xx"` with `ar8327-initvals`: a **QCA8337** description, and the AX23 has no QCA8337) | `reset-gpios = <&tlmm 39 …>` on the switch node (taken from that QCA8337 node) | **we likely drive the wrong line**; the real reset is probably never pulsed (U-Boot's switch init is what we run on) | medium (warm/cold-boot determinism); **not** a bring-up blocker (HW-3P works with 39) | **leading candidate GPIO 26** — same line and form as upstream MR80X v2 (`&mdio1 { reset-gpios = <&tlmm 26 …> }`, HW-tested). Not changed blind: measure first (§3) | OEM/GPL + REL (MR80X v2, EX511 v2 analysis) |
| GPIO 33 | `CONFIG_2G_LED=33` (U-Boot) | 2.4 GHz LED | n/a — note: EX511/AX55 use 33 as *switch reset*; **not** applicable to AX23 | — | — | GPL |
| Buttons | `gpio-keys-polled`, reset = GPIO14 only | reset GPIO14 | same | none | — | OEM |
| LEDs | power 10, WAN 13, WAN-orange 12, LAN 32, 2G 33, 5G 11, WPS 22 (active-high) | DTS LEDs, 0004 phy mapping | 0004 assumes phy0 = 2.4 GHz (true for normal and `seq` order, not for `ax23_radios=5g`) | cosmetic | documented | GPL + SRC |
| NAND | qpic SPI-NAND, ESMT F50D1G41LB, 128 KiB blocks | same driver class; **all 16 partitions read-only** (0015) | OEM writes slots/env; we write nothing | none (RAM image) | — | OEM + SRC |
| Factory data | `/lib/read_caldata_to_fs.sh` from ART; tp_data UBIFS (default-mac) | caldata hotplug ART+0x1000 / +0x26800 read-only; tp_data ro mount | equivalent, read-only | low | — | OEM + SRC |
| BT / coex | BTSS region `bt@7000000`, `qcom,coex-mode 3` | BT not used | n/a | none | — | OEM |

## 2. What the OEM firmware does to fit in 256 MiB
- **FW memory mode 2** on both radios (8 vdevs, 128 peers): same in ours.
- **caldb disabled**: same in ours.
- **NSS 8 MiB** reserved: we save it.
- QSDK host driver (not ath11k) with its own ring sizes, not visible in the DT. The
  closest public counterpart is the QSDK 512M profile, which 0002/0018 follow for the
  monitor/status rings.

## 3. The switch-reset question, as a hardware measurement
Needed only after the Stage-3 baseline passes (`physical-hardware-test-plan.md`), and
only with the owner's approval, because it briefly resets the switch:
1. With the dev image RAM-booted and a cable in lan1, read the line states without
   changing them: `cat /sys/kernel/debug/gpio | grep -E 'gpio-(26|39) '` (debugfs is
   already mounted by `router-collect.sh`).
2. Build the variant DTS (switch reset on `&mdio1` GPIO 26 as on MR80X v2, nothing
   else changed) and RAM-boot it once: the switch must probe ("found an RTL8367S-VB"),
   all ports link, and `ax23-selfdiag.sh` S2.4 must show frames crossing the trunk.
3. Repeat the 20× cold/warm boot test on both images. Adopt GPIO 26 only if it is at
   least as good. Until then the baseline keeps GPIO 39, which HW-3P has shown works.

## 4. What did not transfer and why
- `qcom,ipq5018-wcss-pil` vs `wcss-sec-pil`: different, TZ-authenticated loader in
  OpenWrt; the firmware and QMI path are the same.
- NSS-DP / SSDK: proprietary, not reproduced; stmmac + rtl8365mb DSA replace them.
- OEM QCA8337 `ar8327-initvals`: belong to a switch this board does not have.
