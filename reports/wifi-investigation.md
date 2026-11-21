# Wi-Fi investigation: ath11k "failed to load board data file: -12"

Evidence tags follow `source-audit.md`: `[SRC]` source, `[STATIC]` offline test,
`[HW-3P]` third-party UART logs from an **AX21 v5 (US) running AX23 v2
firmware** (forum t/254876, posts by Veraxis, 2026-11-12 … 11-20). No log in
this report comes from our own hardware, and **no radio has been tested by this project**.

## 1. The observed failure `[HW-3P]`

The same sequence appears in all six posted boots (v0.3 … v0.5):

```
ath11k c000000.wifi: FW memory mode: 2
ath11k b00a040.wifi: Multipd architecture - userpd: 2
ath11k b00a040.wifi: FW memory mode: 2
ath11k b00a040.wifi: qmi ignore invalid mem req type 10
ath11k c000000.wifi: failed to fetch board data for bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2 from ath11k/IPQ5018/hw1.0/board-2.bin
ath11k c000000.wifi: failed to fetch board data for bus=ahb,qmi-chip-id=0,qmi-board-id=255 from ath11k/IPQ5018/hw1.0/board-2.bin
ath11k c000000.wifi: failed to fetch board data for bus=ahb,qmi-chip-id=0,qmi-board-id=255 from ath11k/IPQ5018/hw1.0/board-2.bin
ath11k c000000.wifi: failed to fetch board.bin from IPQ5018/hw1.0
ath11k c000000.wifi: qmi failed to fetch board file: -12
ath11k c000000.wifi: failed to load board data file: -12
(identical four lines + -12 for b00a040.wifi / QCN6122)
```

## 2. What already works (inferred from the log, `[HW-3P]`)

Before the board-data step, both radios have:
- probed with `fw-memory-mode 2` applied;
- had the Q6 remoteproc boot the multi-PD firmware and spawn **userpd 2** for the QCN6122. The `q6v5_wcss` boot-args (PCIE1, UPD2, reset GPIO27) are therefore accepted;
- completed QMI host-capability and target-memory negotiation. The FW requests memory and ath11k answers; "ignore invalid mem req type 10" is the normal, benign path in `ath11k_qmi_alloc_target_mem_chunk` `[SRC]`;
- reached `ath11k_qmi_load_bdf_qmi()`, which is called only after the FW reported its board ID (0xFF = OTP unprogrammed) and chip ID (0) `[SRC]`.

So remoteproc, PD selection, firmware API compatibility, the QMI transport and the DTS memory layout for the BDF and M3 regions are **not** where this fails.

## 3. Exact failing code path `[SRC]`

`drivers/net/wireless/ath/ath11k/qmi.c: ath11k_qmi_load_bdf_qmi()` → `core.c: ath11k_core_fetch_bdf()`:

1. `ath11k_core_fetch_board_data_api_n(board-2.bin, "…,variant=TP-Link-Archer-AX23-v2")`
2. same, with the no-variant fallback name
3. same, with the chip-ID-only name `bus=ahb,qmi-chip-id=0`
4. `ath11k_core_fetch_board_data_api_1("board.bin")`. If this fails, the four `failed to fetch …` lines are printed and **its** error code is returned.

Steps 1-3 can only return `-ENOENT`, `-ENODATA` or `-EINVAL` when a file or name is missing. The `kzalloc` failures in `ath11k_core_fetch_bdf` return `-ENOMEM` *before* any of the four messages are printed. The four messages were printed, so the final `-12` came from the `board.bin` request (step 4).

`ath11k_core_firmware_request()` → `firmware_request_nowarn()`. OpenWrt sets `CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y` and `CONFIG_FW_LOADER_PAGED_BUF=y` `[SRC]` (`target/linux/generic/config-6.18`, `qualcommax/config-6.18`). When a file is not on disk, the kernel falls back to the sysfs user helper. procd's firmware hotplug handler answers a request for a non-existent file by writing `loading=1`, no data, then `loading=0` (verified in the procd built for this image, `procd-2026.10.07~6a22d396/plug/hotplug.c: handle_firmware()`: on `stat()` failure it sets `s.st_size = 0` and `goto send_to_kernel`). The kernel then takes the path in `drivers/base/firmware_loader/fallback.c` (6.18.55, lines 127-131):

```c
if (fw_state_is_aborted(fw_priv)) { … }
else if (fw_priv->is_paged_buf && !fw_priv->data)
        retval = -ENOMEM;
```

That is, **a missing firmware file is reported as -ENOMEM (-12)**. In this context, `-12` means "board.bin / board-2.bin entry not found". It is not an allocation failure.

## 4. Root cause

| Check | Result |
|---|---|
| Does the AX23 image install any `board-2.bin`? | **No.** `DEVICE_PACKAGES` has no `ipq-wifi-*` package `[SRC]`; `ath11k-firmware-ipq5018-qcn6122` ships firmware only `[SRC]`. |
| Does any public board-2.bin contain `variant=TP-Link-Archer-AX23-v2`? | **No.** Checked openwrt/firmware_qca-wireless `6d7ddb8` (and the `6a0f508` pinned by ipq-wifi) and kuncy7's `ipq-wifi/files` `[STATIC]` (`tools/bdf/board2.py list`). |
| Board-name format the driver asks for | `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=TP-Link-Archer-AX23-v2`. Every TP-Link IPQ5018/QCN6122 entry found (AX55 v1, RE700X, EAP650, AX53 v2, AX58 v2, EX511 v2, MX515v) uses chip-id 0 / board-id 255, so **the variant string is the only thing that tells boards apart** `[STATIC]`. |
| Is the calibration variant string wrong? | No. It follows the upstream naming convention. It just has no matching data. |
| ART offsets 0x1000 / 0x26800, 0x20000 each | Correct cases under the correct firmware names `[SRC]`; same as AX55 v1; bit-exact match reported by Sply. **Not reproducible here.** |

**Root cause: there is no AX23 v2 board data anywhere in the image.** The memory configuration is not the cause of this failure. A genuine allocation `-12` in the same step is a real, documented risk on 256 MB boards. gusfmora's kuncy7 patch notes record the second radio losing a `GFP_KERNEL` allocation when NSS also holds its reservation. Section 6 covers that risk; it is not what the AX23 logs show.

## 5. Fix implemented

### 5a. Board-data packaging (dev patch 0003)
A package `ipq-wifi-tplink_archer-ax23-v2` is added to `DEVICE_PACKAGES`. It installs
`/lib/firmware/ath11k/{IPQ5018,QCN6122}/hw1.0/board-2.bin` **from locally supplied files only**.
When the files are missing, the package installs `/lib/firmware/ath11k/AX23-V2-BOARD-DATA-MISSING`.
`router-collect.sh` and `validate-artifacts.sh` then report Wi-Fi as **BLOCKED** rather than failing silently.

**No board data is shipped and none was fabricated.** Using another board's file, such as AX55 v1
or AX53 v2, would mean running a different board's RF front-end and regulatory power tables on this
board. That was rejected.

### 5b. Getting the device's own board data (read-only procedure)
The stock firmware keeps the board files in its rootfs (`…/lib/firmware/IPQ5018/WIFI_FW/bdwlan.b24`
and `…/qcn6122/bdwlan.b60`, 128 KiB each, under per-region directories `[SRC]` docs/HARDWARE.md).
The stock firmware is still on the user's NAND, because only RAM boots have been performed.

1. RAM-boot the dev initramfs (UART + TFTP; see `tests/hardware/HARDWARE-TEST-PLAN.md`).
2. On the PC: `tests/hardware/backup-flash-ro.sh 192.168.1.1`. This streams every partition from `/dev/mtdNro` (the read-only nodes), with sha256 verified on both ends.
3. `tools/bdf/extract-oem-bdf.sh <backup>/mtd11_rootfs.bin --region <dir>`. This does UBI → squashfs → bdwlan → board-2.bin, using the exact AX23 name. It **refuses to guess** when per-region copies differ. An EU unit should use the EU directory if one exists `[STATIC]` (`test_bdf_extract.sh`, synthetic image).
4. `./tools/build-dev.sh --variant dev`. Stage 05 validates the exact name with `board2.py lookup` before packaging.

The resulting files are proprietary per-device data. `board-data/` is git-ignored. Do not publish them.
Upstreaming means sending them to openwrt/firmware_qca-wireless in the usual way, which is the user's decision.

## 6. 256 MB memory: second-order risk, mitigated (dev patch 0002)

Once board data loads, the host data path is allocated. With the base ath11k sizes `[SRC]`
(`dp.h`, `dp_rx.c: ath11k_dp_rxdma_pdev_buf_setup`), every radio pre-posts RX buffers into three rings
(IPQ5018 and QCN6122 both have `rxdma1_enable = true`):

| Ring | Default | FW mode 2 (dev 0002) | QSDK 512M profile | PR #21495 smallbuffers |
|---|---|---|---|---|
| RXDMA buf (posted) | 4096 | 512 (IPQ5018) / 1024 (QCN6122) | 4096 | 1024 |
| Monitor buf (posted) | 4096 | 128 | 128 | 128 |
| Monitor status (posted) | 1024 | 512 | 512 | 512 |
| Monitor dst | 2048 | 128 | 128 | 128 |
| Monitor desc | 4096 | 128 | 4096 | 4096 |
| RXDMA err dst | 1024 | 128 | 1024 | 1024 |
| TX completion | 32768 | unchanged | 8192 | 2048 |

Each posted buffer is `dev_alloc_skb(2048+128)` ≈ 2.5 KiB of page-frag data plus an `sk_buff` head, about 2.8 KiB.
**Source-derived estimate, not measured:** default ≈ 9216 × 2.8 KiB ≈ 25 MiB per radio, about 50 MiB for both.
Dev 0002 brings that to ≈ 3.2 MiB (IPQ5018) + ≈ 4.6 MiB (QCN6122), about 8 MiB, saving about 42 MiB.
For comparison, the kernel reports 173 MB available at boot `[HW-3P]`, and a RAM-booted initramfs also keeps its whole rootfs in RAM.

Design choice: sizes are chosen **at runtime when the radio's DT already declares FW memory mode 2**
(the 256 MiB profile). No build-wide Kconfig flag changes other boards, which was the objection to #21495.
The QCN6122's 1024 RXDMA buffers follow fanha99's measurement on a CR8806 (IPQ5018+QCN6122, 256 MB):
512 overflowed under upload, 1024 did not. The TX completion ring is left alone: its size is built into
the `ATH11K_TX_COMPL_NEXT()` wrap macro and needs a separate, careful change. The patch is compiled in the dev build `[STATIC]`
(`validate-artifacts.sh` checks the built source). Its RF and throughput effect is **NOT HARDWARE TESTED**.

`fw-memory-mode = <2>` itself is valid for both PDs. It is parsed per radio, limits each radio to
8 vdevs and 128 peers, disables coldboot calibration, and is sent to the FW in QMI host-cap. Both radios
got past QMI memory negotiation with it `[HW-3P]`. No further DT memory change is proposed without hardware data.

## 7. Regulatory (EU)

- Patch 0001 calls `ath11k_remove_regdomain` on both radios. Its upstream bug zeroed unrelated caldata
  words; fixed in dev 0001 `[STATIC]`. With the regdomain cleared, the effective country comes from
  `wireless.radioN.country`. **Set it to your EU country** (e.g. `uci set wireless.radio0.country=GR`).
  The OpenWrt default `00` (world) is the most restrictive.
- If the stock rootfs contains region-specific `bdwlan` files, use the EU copy (§5b step 3).

## 8. Acceptance status

| Requirement | Status | Evidence |
|---|---|---|
| Root cause of -12 identified | **Done** | `[SRC]` + `[HW-3P]` logs, §3-4 |
| Board-data packaging in image | **Done** (data not included) | dev 0003, `[STATIC]` |
| Extraction tooling | **Done** | `[STATIC]` synthetic test |
| 2.4 GHz radio initialisation | **NOT HARDWARE TESTED** (BLOCKED on board data from the unit) | — |
| 5 GHz radio initialisation | **NOT HARDWARE TESTED** (BLOCKED on board data from the unit) | — |
| AP creation, 802.11n/ac/ax, WPA2/WPA3, DHCP over Wi-Fi, Internet, Wi-Fi↔LAN, reconnects, dual-band stability, no QMI crash, no leaks, EU reg | **NOT HARDWARE TESTED** | procedures in `tests/hardware/HARDWARE-TEST-PLAN.md` |
