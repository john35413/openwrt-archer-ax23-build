# Cross-device equivalence: what the AX23 v2 can borrow, and what it cannot

Evidence labels as in `wifi-root-cause.md` (**HW** our real AX23 · **ID** identical
hardware · **REL** related hardware · **SRC** source analysis · **BUILD** build/static ·
**SIM** simulation only · **HYP** hypothesis). No EU AX23 v2 has been run by anyone;
all "AX23" hardware facts remain 3P (Veraxis' AX21 v5 running AX23 v2 firmware,
forum t/254876). This report maps each sibling to the exact AX23 subsystem it
informs and states what does **not** transfer.

## 1. The IPQ5018 + QCN6122 family (OpenWrt main and vendor trees)

| Board | RAM | 5 GHz | Switch | Wi-Fi in tree | fw-mem-mode | Source |
|---|---|---|---|---|---|---|
| **TP-Link Archer AX23 v2** (ours) | **256 MiB** | QCN6122 | **RTL8367S-VB** | dev patches | **2** both | this project |
| TP-Link RE700X | 256 MiB | QCN6122 | (1 port, RTL8211F) | **disabled** pending low-mem patch | 1 | main a20047f6ee |
| Mercusys MR80X v2 | **256 MiB** | QCN6122 | RTL8367S | **disabled** ("256 MiB too few for ath11k") | 2 | main 938f67a519 |
| TP-Link EX511 v2 | 256 MiB | QCN6102(6122 fw) | RTL8367S-VB | **enabled** | **2** both | kuncy7 c3po-tag-8021q |
| TP-Link Archer AX55 v1 | 512 MiB | QCN6122 | RTL8367S | enabled | 1 | main 8ac63a1c35 |
| GL.iNet GL-B3000 | 512 MiB | QCN6122 | QCA8337 | enabled | 1 | main |
| Linksys MR5500/MX5500 | 512 MiB+ | QCN6122 | QCA8337 | enabled | 1 | main |
| Wallys DR5018S | 512 MiB | 2×QCN6122 | — | enabled | 1 | main 14423144a5 |
| Mercusys MR90X / ZTE T5400 / AVM 4050 | ≥256 | QCN6122 | mixed | enabled/varies | varies | main |

**Key finding (ID/REL):** the AX23 v2 is in the hardest class — 256 MiB **with two
radios** — and every other in-tree 256 MiB IPQ5018+QCN6122 board either keeps Wi-Fi
**disabled** (RE700X, MR80X v2) or runs it only with **fw-memory-mode 2 plus a
low-memory ath11k change** (EX511 v2, out-of-tree). The 512 MiB boards (AX55 v1,
GL-B3000, Linksys, DR5018S) run mode 1 and are **not** a memory precedent for the
AX23. This is the single most important cross-device conclusion and it is **why
patches 0002 + 0012 exist**.

## 2. Per-subsystem transfer

### 2.1 Low-memory Wi-Fi — EX511 v2 is the closest analogue (REL)
EX511 v2 (kuncy7) is IPQ5018 + QCN6102(as 6122) + **RTL8367S-VB** + **256 MiB** — the
same four parts as the AX23 v2. Its DTS notes (SRC, their HW):
- **Both radios at `fw-memory-mode = 2`** "which is what stock uses and what this
  board needs. Mode 1 ... here, with 256 MiB and both radios up, ath11k's firmware
  DMA allocations left barely 16 MiB free and the board died writing a 12 MiB file"
  with an OOM panic. → **directly corroborates our DTS choice of mode 2 on both
  radios** (matches our `wifi-root-cause.md` §4, which derived mode 2 from the stock
  DTB independently). **REL, their HW.**
- QCN6102 on **userpd 2**, boot-args `<1 4 2 15 0 0>` (PCIE0, reset gpio15). The
  AX23 stock DTB uses userpd2 with a **different reset tuple** (`<2 4 2 0x1b 0 0>`,
  gpio27) — so the boot-args are **board-specific and do not transfer**; ours come
  from the AX23 stock DTB (SRC). EX511 only confirms the *userpd2* placement.
- `coherent_pool`: EX511 measured the three atomic DMA pools at **8 MiB** on a
  256 MiB board and cut `coherent_pool` to 512K after proving nothing but the Q6
  MPD loader draws on it, and that the loader's `-12` is fixed by giving it
  `GFP_KERNEL` (their patch 0828). **Our dev image keeps `coherent_pool=2M`**
  (3P-tested value) — see `real-memory-budget.md` §4 for why we do **not** adopt
  512K blindly (the AX23 Q6 loader path is ath11k-upstream, not their vendor MPD).
- **Does not transfer:** EX511 board data (BR region, different FEM masks), its
  zero-filled ART handling, its NSS region sizing (it enables NSS; we do not), its
  switch reset GPIO 33 vs our 39, its MAC-from-nvmem scheme.

### 2.2 RE700X — the low-memory ath11k patch and the UART-free install question (REL)
RE700X (main) is 256 MiB IPQ5018+QCN6122 with Wi-Fi **disabled in tree** pending
"the ath11k patch that selects smaller rings on low-memory boards" — the very LKML
series (Eduard Hart) our patch 0012 adapts. The RE700X author **is** that patch's
author. So:
- Our 0002+0012 are the OpenWrt-side realisation of exactly the change RE700X waits
  for, keyed on `fw-memory-mode==2` instead of total-RAM so only declared boards
  change (`ath11k-low-memory-analysis.md`). **SRC.**
- **UART-free install precedent:** RE700X ships a `factory-webflash.bin`
  (`scripts/tplink-re700x-factory.py`) that the **stock web UI accepts without
  UART**, because the RE700X stock flasher's `nvrammanager` wraps the payload in the
  "tplink2022" container and does **not** RSA-verify it. **This does NOT transfer to
  the AX23 v2:** we disassembled the AX23 stock `libnvrammanager.so` (1.2.1) and its
  default check hook calls `rsaVerify*` with the same two TP-Link keys as U-Boot
  (`uart-free-final-investigation.md` §3). So a keyless web-flash image is possible
  for the RE700X but **not** for the AX23 v2. **SRC (disassembly).** The RE700X
  author's own note — "This path has not been tested end to end ... keep UART at
  hand" — also tempers the precedent.

### 2.3 Switch / 2.5G trunk — MR80X v2 and EX511 both warn on HSGMII (REL)
- MR80X v2 (RTL8367S, 256 MiB): over 12 reboots, **2 came up with the 2.5G CPU
  trunk passing no traffic** (eth0 TX while switch port-6 in-octets stayed 0, link
  reporting 2.5 Gbps) — the UNIPHY-before-switch ordering race (openwrt#25153). It
  ships at **sgmii/1G** until the fix lands.
- EX511 v2 (RTL8367S-VB, same as AX23): HSGMII came up "Link is Up - 2.5Gbps/Full"
  but **not one frame crossed** in either direction; ships at **sgmii/1G**. Suspects
  the RTL8367S-VB (0x6642/0x0010) SerDes tuning in rtl8365mb being lifted from
  RTL8367S (0x6367/0x00A0) parts.
- **For the AX23 (REL):** the AX23 3P logs *do* show a working 2.5G trunk with real
  client traffic (v0.5-test, `ethernet-nat-validation.md`), so the AX23 trunk is not
  in the EX511/MR80X failure state — **but these two siblings are concrete evidence
  that the cold-boot trunk race is real on RTL8367S + IPQ5018**, which is why our
  dev image carries the UNIPHY fixes 0006–0009 (PR #26597) and the trunk-gap test
  exists. The AX23 ships 2.5G because 3P tested it; MR80X/EX511 ship 1G because
  theirs failed — the difference is the UNIPHY patch set, not the hardware.

### 2.4 NAND / A-B / recovery — MR80X v2, AX55 v1, RE700X (REL/SRC)
- A/B via `tp_boot_idx` ping-pong, write inactive slot then switch: **MR80X v2,
  RE700X, AX55 v1 all do this**, matching our `boot-nand-feasibility.md` §6 install
  design. **REL (their HW) + SRC (our GPL U-Boot analysis).**
- MR80X v2: "U-Boot web recovery ... verifies an RSA1024 signature and has no
  keyless path. Use the stock web UI." — **independent confirmation** of our AX23
  finding that U-Boot recovery is RSA-gated (our §2). **REL.**
- MR80X v2 needs "the backported spi-qpic-snand ECC context fix, otherwise about
  half of the boots end in 'Waiting for root device'." → a **NAND driver risk to
  watch** on the AX23; our image is on the same `qpic_nand`. Logged as a risk, not
  yet seen on AX23 3P (R-NAND, `real-memory-budget.md`).
- **Does not transfer:** every board's MAC derivation offsets differ (MR80X uses
  default-mac −1/−2; AX23 uses +1 for WAN per 3P/our `test_mac_derivation`); slot
  sizes differ; Mercusys uses a different fwup container (`mercusys-fwup.py`) than
  TP-Link.

### 2.5 MDIO / GCC — a bug fixed upstream that does **not** affect us (SRC)
main b7afc4baab fixes swapped MDIO clocks/resets in gcc-ipq5018, but states "No
affected targets ... every other IPQ5018 board enables both MDIO buses." The AX23
DTS enables mdio0 **and** mdio1, so this is **not** a live bug for us (BUILD: our
DTS has both). Noted so a future single-MDIO change would need the fix.

## 3. What no sibling can supply (must stay AX23-specific)
Per the owner's constraints and `wifi-root-cause.md`: **board data, calibration,
MAC addresses, NAND layout specifics, boot-args, switch reset GPIO** are all
per-board. We take from siblings only **design patterns and failure modes**
(mode-2 memory, A/B write-inactive-slot, RSA-gated recovery, trunk race), never
transplanted data. The EU board data comes from the AX23's own signed firmware
(`board-data-from-tplink-firmware.sh`), not from AX53 v2 or EX511.

## 4. Bottom line for the readiness matrix
- **Memory (REL, strong):** two independent 256 MiB IPQ5018+QCN6122 boards keep
  Wi-Fi disabled without a low-memory ath11k change; the one that enables it
  (EX511 v2) uses mode 2 on both radios exactly as we do. Our 0002+0012 are the
  necessary-and-matching change. Effect still **HYP for the AX23** until a hardware
  `free`/`dmesg` is taken.
- **UART-free OpenWrt install (SRC, strong):** possible on RE700X (no RSA in its web
  flasher), **not possible on the AX23 v2** (RSA-enforced in both U-Boot and the
  stock web flasher). This closes the "can we avoid UART" question in the negative
  for first install.
- **Trunk (REL):** the cold-boot 2.5G race is real on this switch family; our
  UNIPHY patch set is the mitigation the 1G-shipping siblings lack, and AX23 3P logs
  show it working — still needs our own 20× cold-boot HW test.
