# Physical hardware bring-up: staged procedure (Stage 0–6)

Labels as in `wifi-root-cause.md`. This is the **owner-run** procedure to take the
dev image from "never run" to "validated on the real Archer AX23 v2", in stages that
each gate the next. **Nothing writes flash before Stage 5, and Stage 5/6 need the
owner's separate explicit authorization** after a hardware-validated recovery plan,
per the owner's constraints. Every automated step here is **read-only on the router**
until that authorization.

Companion scripts: `tests/hardware/ax23-selfdiag.sh` (read-only, redacted),
`tests/hardware/router-collect.sh`, `tests/hardware/pc-traffic-tests.sh`,
`tests/hardware/soak-monitor.sh`, `tests/hardware/backup-flash-ro.sh`,
`tools/fit-verify.py`. Safety STOP conditions: `boot-nand-feasibility.md` §5.

---

## Stage 0 — Bench and non-destructive recovery proof (no UART, no writes)
**Goal:** prove the owner can always get back to stock before anything else.
1. PC on LAN at `192.168.0.10/24`, `tcpdump -ni <if>` running, browser ready for
   `http://192.168.0.1/`. **Do not upload anything.**
2. Hold reset, power on, keep holding ~5 s, release. Expect (SRC → HW): power LED
   off, **WAN LED orange**, HTTP page at 192.168.0.1 (`boot-nand-feasibility.md` §4).
3. Power-cycle → stock boots normally (recovery writes nothing until a signed file is
   uploaded).
- **Gate:** the recovery page appears. This upgrades the UART-free stock-recovery
  path from SRC to **HW** and guarantees a way back. If it does **not** appear,
  **stop** and do not proceed to any flashing stage — UART becomes mandatory for
  recovery too.
- Keep the plaintext **EU 1.0.2** image on hand as the restore file (the only image
  U-Boot recovery can write, `uart-free-final-investigation.md` §4). Verify it first
  with `tools/bdf/tplink-fw-unpack.py` (TP-Link signature OK).

## Stage 1 — UART console and environment capture (read-only)
**Equipment:** USB-UART that supports **1.8 V** logic, **or** a 3.3 V adapter **plus a
level shifter**. **Never drive the 1.8 V RX pin with 3.3 V.** (3P: the JP1 header
lacks the shifter parts.)
1. Connect TX/RX/GND (not VCC). Power on; capture the full log.
2. At "Hit any key to stop autoboot" (1 s) → U-Boot prompt. `printenv` → capture
   `bootcmd`, `bootdelay`, `tp_boot_idx` (expect built-in defaults if env CRC is bad).
   **No `saveenv`, no `nand`/`ubi`/`sf`/`mtd` writes.**
- **Gate:** clean console, `printenv` captured. Anything garbled or unexpected →
  power-cycle, stop (NAND untouched).

## Stage 2 — RAM boot of the dev image (no writes)
1. TFTP server on PC/Pi (`dnsmasq --enable-tftp` throwaway, or Tftpd64). Serve
   `artifacts/ram-only/dev/…initramfs-uImage.itb`. Verify its SHA256 against
   `SHA256SUMS` and run `tools/fit-verify.py <itb> --config config@mp02.1` first.
2. At the U-Boot prompt: `setenv serverip <pc>; setenv ipaddr 192.168.1.1;
   tftpboot 0x44000000 <itb>; bootm 0x44000000`.
3. Power-cycle returns to stock from NAND (nothing was written).
- **Gate:** kernel boots, login prompt. `bootm` hash/format error or panic →
  power-cycle, stop.
- **Radio isolation (only if the Wi-Fi gate below fails):** add one profile to the
  kernel command line at the U-Boot prompt before `bootm`, for that boot only (no
  `saveenv`): `setenv bootargs "${bootargs} ax23_radios=none"`, then `2g`, `5g`,
  `seq`. Patch 0017 holds the other radio back from ath11k in RAM, so each boot
  isolates one radio's firmware/board data and the memory peak of a simultaneous
  start (`ath11k-final-hardware-readiness.md` §3).

## Stage 3 — Read-only self-diagnostic and acceptance (no writes)
Over SSH from the LAN PC (keys only), **read-only**:
```
ssh root@192.168.1.1 sh -s < tests/hardware/ax23-selfdiag.sh > selfdiag-$(date +%s).txt
ssh root@192.168.1.1 sh -s < tests/hardware/router-collect.sh > hw-$(date +%s).tsv
```
Check the gate lines the self-diagnostic prints:
- **Stage-1 gate:** `S1.5 RAM boot` PASS, all `S1.8 mtd … read-only` PASS, `S1.7
  sysupgrade interlock` PASS.
- **Wired gate:** `S2.1` RTL8367S-VB, `S2.2` 2.5G trunk up, **`S2.4` frames cross the
  CPU trunk** (not just link-up — the EX511/MR80X failure was link-up with zero
  frames). Then `pc-traffic-tests.sh` LAN↔WAN, LAN↔LAN, all four LAN ports, trunk-gap.
- **Wi-Fi gate (the one that unblocks everything):** `S3.4` no board-data fetch
  failure, `S3.9` both radios registered, `S3.7` no regd failure, `S3.13` no Q6
  crash, **no `S3.8` allocation-failure lines**, `S3.14` no TX-FIFO-full. Then:
  associate WPA2 (2.4) and WPA3/SAE (5), DHCP, LAN↔WAN through each band,
  simultaneous dual-band.
- **Memory gate:** `M.2` MemAvailable ≥ 50 MiB, `M.3/M.4` free blocks of order ≥ 5
  present (the ath11k ring allocations), `M.5/M.6` no OOM / page-allocation failures,
  before and after `wifi up`. Confirms `real-memory-budget.md` §3.
- **Soak:** `soak-monitor.sh` for 24–48 h (MemAvailable slope, OOM count, FW crashes).
- **Reboot:** 20× cold + 20× warm, trunk + both radios + LAN→WAN each time (catches
  the cold-boot trunk race, `cross-device-equivalence.md` §2.3).
- **Bundle for remote review:** `ssh root@192.168.1.1 sh -s -- --bundle <
  tests/hardware/ax23-selfdiag.sh > bundle.txt` (filtered, redacted dmesg + meminfo +
  buddyinfo + /proc/mtd; nothing written on the router).
- **Switch reset line (optional, owner-approved, after the above is green):**
  `oem-openwrt-differential-analysis.md` §3: read GPIO 26/39 states, then try the
  GPIO-26 variant image and repeat the 20× boot test on both. OEM code resets the
  switch on GPIO 26, active low (`rtl8367-reset-trace.md` §1). The variant must use the
  stock timing (assert ≥ 200 ms, ≥ 200 ms before the first MDIO access) and needs
  continuity on GPIO 26 first (§5 there); selfdiag S2.8 records both lines.
- **Gate:** all of the above green. **This is the full RAM-boot acceptance.** If any
  Wi-Fi gate fails, the root-cause map in `wifi-root-cause.md` §6 says what next;
  **do not proceed to Stage 4+.**

## Stage 4 — Full read-only flash backup (no writes)
**Only after Stage 0–3 pass.** From the RAM-booted system:
```
tests/hardware/backup-flash-ro.sh    # ssh cat /dev/mtdNro, sha256, store off-device
```
Back up **every** partition read-only, verify SHA256, store **off the device** (and a
second copy). Especially `0:ART` (per-unit calibration), `tp_data`, `0:APPSBLENV`.
- **Gate:** every partition backed up and re-readable; `0:ART` and `tp_data`
  preserved. Without verified backups, **stop** — no flashing.

## Stage 5 — Persistent install **(requires separate owner authorization)**
**Blocked until:** Stage 0 recovery proven on HW **and** a real stock re-flash through
it tested on the owner's unit (proves UART-free return to stock), Stage 4 backups
verified, and the owner gives **explicit, separate** go-ahead. Design
(`boot-nand-feasibility.md` §6):
1. Write the **inactive** slot only (keep stock in the other). Never touch SBL1,
   MIBIB, QSEE, CDT, APPSBL, ART, tp_data, BOOTCONFIG*. (Our DTS marks all 16
   partitions read-only — patch 0015 — so the **running** kernel cannot; a
   persistent install is a deliberate, authorized, reviewed change that would relax
   exactly the two slot partitions, nothing else.)
2. Verify the written slot by **read-back** (`fit-verify.py` on the slot's kernel
   volume + full SHA compare) before switching.
3. Only then set `tp_boot_idx` to the new slot; include `bootcmd=bootipq` if env CRC
   was bad (the kuncy7 AX55 lesson).
- **Gate:** read-back matches; stock slot intact and still boots (test by setting
  `tp_boot_idx` back). The NAND/UBI lab (`tests/nand`, SIM) rehearses this whole
  sequence — slot isolation, truncated-write fallback, env layout — before any real
  write.

## Stage 6 — Rollback drill and sign-off **(requires owner authorization)**
1. From OpenWrt, set `tp_boot_idx` back to the stock slot → stock boots.
2. Separately, via the Stage 0 reset-held HTTP recovery with the EU 1.0.2 image →
   stock restored. Proves two independent rollbacks.
3. Re-run Stage 3 acceptance on the persistent image.
- **Gate:** both rollbacks work and acceptance still passes. Only now is the port
  "validated on hardware" for persistent use.

---

## Gate summary (A–E, from the mission)
| Gate | Meaning | Can be reached offline? |
|---|---|---|
| A | Builds, static/sim all pass | **Yes** — done (`final-readiness-matrix.md`) |
| B | RAM-boot acceptance (Stage 2–3) | No — needs UART + the unit |
| C | Persistent install validated (Stage 5) | **No** — owner-authorized, hardware only |
| D | Recovery/rollback proven (Stage 0 + 6) | **No** — hardware only |
| E | Soak-stable in daily use | **No** — hardware only |

C, D and E **cannot** be declared complete from this environment and are not. A is
complete; B is fully prepared (scripts + gates) and waits only on the owner's bench.
