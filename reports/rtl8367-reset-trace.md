# RTL8367S-VB reset and initialisation: traced consumers

Scope: the Realtek switch reset line, its sequencing, and the 2500BASE-X trunk set-up
on the Archer AX23 EU V2.0. No router was touched and nothing extracted was executed.
Labels:
- **OEM-BIN**: static ARM disassembly of the signed TP-Link 1.2.1 image (`qca-ssdk.ko`).
- **OEM-SRC**: TP-Link's GPL tarball for this model (`GPL_AX23v2.tar.gz`, U-Boot 2016).
- **SOURCE**: our compiled kernel 6.18.55.
- **REL**: related hardware.
- **UNV**: unverified.

Nothing here is **VERIFIED ON OUR PHYSICAL AX23**.

## 1. Which GPIO resets the Realtek switch
| Consumer | GPIO and sequence | Evidence |
|---|---|---|
| TP-Link U-Boot `ipq5018_gmac.c: rtl8367_sw_init()` | `reset_rtl8367_switch_gpio(CONFIG_SWITCH_RESET)`, with `config.mk: -DCONFIG_SWITCH_RESET=26`. TLMM CFG = `0x203` (GPIO function, OE, pull-up, 2 mA); OUT = 0 for **500 ms**, then 1, wait **500 ms**; then `rtk_switch_init()` and `MODE_EXT_HSGMII` 2500 forced on EXT0/EXT1. Runs from `board_eth_init` → `initr_net` on every boot; U-Boot's `ipq5018-mp02.1.dts` sets `rtl_switch_enable = <1>`. | OEM-SRC |
| Stock kernel `qca-ssdk.ko`, function at `.text 0xa8d20` (called from module init) | Hard-coded **GPIO 26**: output high, 500 ms; **low** 200 ms; high, 200 ms; logs "GPIO%d reset switch done" with 26. It runs unconditionally after the ISISC/SCOMPHY device loop, then `rtk_switch_init` (up to 5 tries) and VLAN init. | OEM-BIN |
| Stock kernel `/proc/driver/rtl8367s` `rtl8367_gpio_reset` | "gpio reset: resetting RTL8367 via GPIO%d" with **26** | OEM-BIN |
| Stock kernel ISISC branch (`.init.text 0x2e8–0x47c`) | `reset_gpio` from DT (= **39**, inside the `qcom,ess-switch-qca83xx` node with `ar8327-initvals`): low 200 ms, high | OEM-BIN. This is the **QCA8337** driver path; the AX23 has no QCA8337. |
| Stock DT pinmux | `mdio@90000` `pinctrl-0 = phy_pins` muxes **gpio26 = GPIO**, pull-down, output-low (`phy-reset-gpio = <&tlmm 26 0>`). The `blsp1_uart_cts` alternative on gpio26 sits in a pin group no node uses. No pinctrl state touches gpio39. | OEM-BIN (DTB) |

**Conclusion (OEM-BIN + OEM-SRC):** TP-Link's bootloader and TP-Link's kernel, the only
two pieces of software written for this board, both reset the RTL8367 on **GPIO 26**,
**active low**, muxed as a plain GPIO. GPIO 39 is consumed only by the QCA8337 code path.
Sply's GPIO 39 was read from that QCA8337 node of the live DT (`upstream/ax23/docs/DEVICE-TREE.md`),
which is a label, not a consumer. PCB continuity remains **UNV**.

## 2. What that means for our image (SOURCE)
- On every boot, cold or warm, U-Boot pulses GPIO 26 for 500 ms and initialises the switch
  before Linux starts (OEM-SRC).
- Linux then **hardware-resets the chip through `CHIP_RESET`** in `rtl8365mb_setup()`
  (1 s wait for family D, 0025) and programs it from scratch. HW-3P's working 2.5 G
  trunk therefore already comes from a chip initialised from reset by Linux, not from
  U-Boot's configuration.
- Our `reset-gpios = <&tlmm 39 GPIO_ACTIVE_LOW>` drives a line the vendor never uses
  for this switch. Per the OEM evidence it is a no-op for the switch.
- **Moving the DTS to GPIO 26 is not adopted yet.** It gives no cold-boot gain (U-Boot
  already pulses 26 on every boot), and `rtl83xx_probe()` would assert it for only
  25 ms and read the chip ID 100 ms after release. Stock waits 200 ms (kernel) or
  500 ms (U-Boot) before the first access, and still retries `rtk_switch_init`.
  Switching the line without matching timing could turn a working HW-3P path into a
  probe failure. GPIO 39 is kept, as required, until the measurement in §5.

## 3. 2500BASE-X trunk: differences from stock
| Item | Stock | Ours | Evidence / status |
|---|---|---|---|
| SerDes table (`HSGCfg`, 9 SDS writes incl. `0x0410 = 0x0002`, the "HSGMII signal" fix that U-Boot's comment says moved into API 1.4.2) | applied | **identical 9 values** + `{0x0004, 0x074F}` (from the 777-07 series) | OEM-SRC vs SOURCE. The extra entry's provenance is the 777 author's vendor driver version, not this tarball. |
| `SDSNctrlPatch`: 129 writes (`0x6100 = 0x2800`, words to `0x7000–0x707c` via `0x6135/0x6136`, closing `0x6100–0x6104`), applied before the table on every SGMII/HSGMII set-up | applied | **not applied**. Linux's `CHIP_RESET` erases U-Boot's copy. | OEM-SRC. A **candidate** explanation for sibling 2.5 G "link up, zero frames" (EX511 v2, MR80X v2, REL). **Not imported:** the source file is marked Realtek proprietary, and no open driver implements it (GitHub search: only two vendor-API copies). HW-3P passes traffic without it. |
| Embedded DW8051 | vendor loads firmware | held in reset by design (it would race with phylink) | SOURCE |
| CPU-port flow control | `txpause = rxpause = DISABLED` (U-Boot) | `pause` on both fixed links | OEM-SRC vs SOURCE. HW-3P works with pause. Measurable variable, not changed. |
| CPU port mode | HSGMII 2500 forced, nway disabled; stock DT `switch_mac_mode = 0x0c`, `forced-speed 2500` | 2500base-x fixed-link, in-band AN off | matches |

Patches **0024** (CMN PLL bus clocks) and **0025** (family-D reset/SerDes waits) were
re-read against the vendor sequence. No defect was found: the vendor's longer waits
point the same way. Kept unchanged.

## 4. Sibling fixes (not repeating Codex's 777/778 comparison)
- **AX55 v1:** GPIO 33 on the switch (an LED on the AX23). Not applicable.
- **EX511 v2:** GPIO 33, 1 G SGMII shipped. No further reset fix applies.
- **MR80X v2:** upstream uses GPIO 26 on `&mdio1`; the separately tested fork puts 26 on the switch. Both agree that **26 belongs to the switch reset on IPQ5018+RTL8367S boards built from this reference**. REL, consistent with §1.
- There is no open-source fix for `SDSNctrlPatch` to import.

## 5. The physical measurement that closes it
Passive and read-only, in this order:
1. **UART, stock cold boot (Stage 0/1 wiring, 1.8 V-safe):** capture U-Boot's
   `rtk_switch_init ret = …` / `Set RTL8367S SGMII 2.5Gbps` lines. That confirms the
   shipped U-Boot runs §1's code.
2. **Unpowered continuity:** RTL8367S-VB `nRESET` to the IPQ5018 GPIO 26 net (and to 39).
   Alternatively, observe `nRESET` with a high-impedance probe through one stock cold
   boot: expect two low pulses (500 ms U-Boot, 200 ms kernel). Never drive either line.
3. **First RAM boot:** `ax23-selfdiag.sh` **S2.8** (new) records how GPIO 26 and 39 are
   claimed and muxed, plus S2.1/S2.2/S2.4/S2.5.
4. **Only if (2) confirms 26:** a one-variable variant image with
   `reset-gpios = <&tlmm 26 GPIO_ACTIVE_LOW>` on the switch node, a pinctrl state
   `gpio26: function "gpio", bias-pull-up`, and a reset assert ≥ 200 ms / release-to-access
   ≥ 200 ms (stock timing). Repeat the 20× cold/warm boot test against the GPIO 39 baseline.
5. **Only if S2.4 fails at 2.5 G:** the existing 1 G SGMII fallback
   (`ethernet-initialization-comparison.md` §3.2), then pause off, one variable at a time.
