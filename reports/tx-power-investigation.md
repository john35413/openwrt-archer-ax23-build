# The possible 13 dBm TX-power limit: root-cause investigation

Scope: why the stock AX23 EU board data has zeroed target-power regions, and whether
the 13 dBm limit measured on the Archer AX55 v1 under OpenWrt applies to us. No router
was touched. Only offsets, byte counts and the tables' structure are recorded here;
no calibration or board-data values were copied, filled or committed.

Labels:
- **OEM**: static analysis of the signed TP-Link 1.2.1 image.
- **SRC**: compiled driver source.
- **REL**: related hardware.
- **UNV**: unverified on our AX23.

## 1. Findings
| Question | Finding | Evidence |
|---|---|---|
| Board-data format | TP-Link's `bdwlan.b24` / `qcn6122/bdwlan.b60` and Qualcomm's reference files in the same image (`bdwlan.bin`, `b10`, `b20`–`b23`; `qcn6122/bdwlan.bin`, `b50`, `b90`, `bb0`) share one template: identical header words (`0x0001 0x0404 … 0x8000`), 128 KiB, the same field offsets. | OEM |
| What is zero | Inside the target-power table area (0x5580–0xd5c0 on 2.4 GHz, 0x5580–0xd6c0 plus two outliers on 5 GHz), Qualcomm's reference populates 16,396 B / 24,144 B. TP-Link populates **92 % / 93 %** of those bytes (409 / 445 of them with board-specific values) and leaves **39 regions (1,108 B) / 44 regions (1,422 B)** at zero. The zeroed regions are regular, repeating sub-blocks (groups of three at fixed strides), i.e. whole rate or chain groups, not random damage. | OEM (data structure) |
| Deliberate or extraction damage? | **Deliberate.** All four regional variants (EU, CA, EG, TW) leave the same regions zero, and the stock rootfs ships them byte-for-byte as used. Nothing in our extraction alters them (`board2.py scoped --eu` checks the signed EU payload hashes). | OEM |
| What the AX55 fix did | In kuncy7's corrected AX55 v1 files (`fdccd1e`, `f2c37a6`), 29 of 36 (2.4 GHz) and 31 of 41 (5 GHz) of these regions are **byte-identical to Qualcomm's reference board files**. "Filled from the vendor entries of the same file" therefore means **Qualcomm reference-board target powers, not AX55-specific calibration**. | OEM + `firmware_qca-wireless` history |
| Why 13 dBm on AX55 | Under OpenWrt (FW 2.7.0.1-01744) the zero entries made the firmware fall back to 13 dBm. Filling them restored 20/23 dBm (RSSI medians, 30 samples). This is a firmware-side interpretation of zero target power. | REL (kuncy7's measurement) |
| Driver involvement | None. ath11k copies board data verbatim to the fixed BDF address (`memcpy_toio`, `qmi.c`) and then sends the ART calibration. It never parses either. No host-side misinterpretation is possible. | SRC |
| FW 2.5 (stock) vs 2.7 (ours) | Not determinable offline. FW 2.5 keeps plain debug strings (TPC stats with rate, CTL and regulatory arrays; `GenOnepointCalData4BrdData`); 2.7 is QShrink-hashed (174 vs 1,759 related strings). Whether stock also falls back for these rate groups is **UNV**: kuncy7 compared zeroed vs filled, both under OpenWrt, not against stock. | OEM |
| Does stock fill them at runtime? | Stock CNSS passes ART calibration raw at BDF + 128 KiB, as ath11k does. No host-side merge of power tables exists in the stock preinit or CNSS paths examined. Whether the unit's ART carries values in these regions is **UNV**: it is per-unit data, not in any image. | OEM |
| Why TP-Link may zero them | Not documented. One possibility consistent with the data is a deliberate EIRP/compliance margin per rate group (the regional variants differ only in a few power/CTL bytes). That is one more reason **not** to fill them with reference values. | inference, UNV |

## 2. Decision
**No correction.** Every available fill source is either another board (Qualcomm
reference or AX55) or would raise power without AX23 characterisation. Both are excluded.
The only source that would preserve the exact AX23 factory characterisation is the
**unit's own ART**, which cannot be inspected offline.

## 3. Added diagnostic (source tree; streamed at test time, no image change)
**S3.22** counts, per radio, how many of the 39/44 zeroed regions the unit's own
extracted calibration (`cal-ahb-<dev>.bin`, already in RAM) fills. It prints `N/M` only,
never contents. The region list is derived from the AX23 stock image alone, as zero in
TP-Link's EU file and populated in Qualcomm's reference file.

`tests/unit/test_selfdiag_calregions.sh` (`unit-selfdiag-calregions`) checks:
- region edges;
- a short file;
- a missing file;
- with the local stock data present, that every listed region is zero in the EU file.

## 4. Stock-versus-OpenWrt comparison (the only decisive procedure)
Read-only on the router; keep everything fixed except the firmware.
1. **Set-up:** one client (same laptop/phone) at a fixed spot 3–5 m away with line of sight. Router orientation fixed. Country GR/EU on both. Channels 2.4 GHz ch 6 / 20 MHz and 5 GHz ch 36 / 80 MHz (non-DFS). No other changes.
2. **Stock:** 30 RSSI samples of the router's beacons per band, taken at the client (`iw dev <if> scan`/`station dump`, or a Wi-Fi analyser app). Use the median.
3. **OpenWrt RAM boot**, same channels and country:
   - selfdiag S3.21 (AP TX power) and S3.22 (ART fill counts);
   - 30 RSSI samples per band, same client and position.
4. **Interpretation:**
   - ΔRSSI within about ±2 dB of stock: no limit relative to stock, whatever S3.21 says. Nothing to fix.
   - ΔRSSI about 7–8 dB lower (the AX55 delta) **and** S3.21 ≤ 13 dBm: the FW 2.7 fallback applies on our unit. Then:
     - S3.22 `0/M`: the unit's ART does not carry these tables. No AX23-specific source exists, so record the limit and do not fill from reference data.
     - S3.22 `N/M` with N > 0: the unit's own factory data covers those regions. A per-unit, RAM-only merge of exactly those regions from the unit's ART into the board data is the only correction that preserves the AX23 characterisation. Design and review it as a separate, owner-approved change, verified by repeating this comparison. ART itself is never written.
5. Never raise `txpower` above the regulatory limit or use reference/other-router values to compensate.
