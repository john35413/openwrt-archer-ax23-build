# First AX23 v2 RAM boot checklist

**Not a boot authorization by itself.** The generated image is offline-validated; the hardware prerequisites below are still unverified. Do not flash or save U-Boot environment changes.

## Before connecting or booting

- Confirm the chassis label and board identification show **Archer AX23 EU V2.0**. Do not infer the revision from the case alone if the PCB label differs.
- Recompute SHA256 for `artifacts/ram-only/dev/openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`; expected `6d85f2a82117008fc991ffdea54a7fc64a77f2616bdf02f5b9bcabd7a059a9ff`.
- Confirm a documented stock recovery path is available without uploading or writing anything. Confirm the normal NAND firmware still boots before starting RAM tests.
- Measure UART I/O voltage and identify ground, router TX and router RX on the actual board. The repository's 1.8 V/pin references are not physical verification. Start receive-only: connect adapter ground and router TX to adapter RX; leave adapter TX disconnected until voltage and pinout are confirmed.
- Resolve the GPIO 26/39 reset mapping passively before boot. The current DTS drives GPIO 39 for the switch; OEM evidence points to GPIO 26. Establish continuity, polarity and reset waveform without driving either pin. Do not boot with an unresolved possibility of an unsafe switch-reset output.
- Confirm bootloader RAM-load/bootm support, load address/capacity and acceptance of this exact FIT. The FIT has hashes but no signing claim; do not bypass any bootloader signature policy. If acceptance is uncertain or requires bypass, stop.
- Record stock Wi-Fi client RSSI, band, channel and region so later comparisons have a baseline.

## RAM boot and immediate checks

- Follow only the existing RAM-boot procedure in `tests/hardware/HARDWARE-TEST-PLAN.md`; verify its addresses against the actual bootloader's reported memory map before issuing commands.
- Use a temporary transfer/load and boot. Never run `saveenv`, flash, erase, UBI write, sysupgrade or factory commands.
- Capture the full receive-only UART log from power-on. Stop on panic/oops, repeated remoteproc restart, unexpected NAND/UBI write activity, or unexplained switch reset behavior.
- Confirm the reported board is `tplink,archer-ax23-v2`, root is RAM-backed, all 16 MTD partitions report read-only, and any attached UBI device is read-only. Do not probe writability by attempting a write.
- Stream the current self-diagnostic from the PC (it is not embedded in the image):
  `ssh root@192.168.1.1 sh -s -- --bundle < tests/hardware/ax23-selfdiag.sh > selfdiag-bundle.txt`
  Then collect the read-only H-series snapshot with `tests/hardware/router-collect.sh`. Keep both outputs on the PC and redact before sharing.

## Measurements required before daily-use claims

- **Wi-Fi:** both PHYs appear independently; record QMI chip/board IDs (expected EU stock identities 36 for IPQ5018 and 96 for QCN6122, with restricted 255 mapping), firmware/BDF acceptance, regulatory state, channel, configured/driver-reported power and client RSSI. These are not emitted-power measurements. Measure RF output with suitable calibrated equipment before comparing power.
- **Ethernet:** verify switch probe identity, all LAN ports and WAN, 2.5 Gbps CPU link, fresh bidirectional traffic and before/after counters at both endpoints. A carrier-up result alone does not pass S2.4.
- **Memory/recovery:** capture `MemAvailable`, `/proc/buddyinfo` and relevant logs before and after sequential radio startup and any natural recovery. Do not force a crash as a first-boot test.
- **Reliability:** cold boot, WAN/LAN DHCP and traffic, firewall/NAT, DNS, service startup and reboot-to-stock recovery after power removal. Repeat reboots and longer soak tests only after the initial gates pass.

Record each item PASS / FAIL / BLOCKED / NOT TESTED with raw logs. No physical router operation has been performed in this audit.
