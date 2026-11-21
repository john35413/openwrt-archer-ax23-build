# NAND, boot and installation safety: Archer AX23 v2

Tags as in `source-audit.md`. **Nothing in this project has written to any
router's flash, and no image here is approved for flashing.**

## 1. Flash layout (128 MiB ESMT F50D1G41LB SPI-NAND, 128 KiB blocks, 2 KiB pages)

| mtd | Name | Offset | Size | DTS | Rule |
|---|---|---|---|---|---|
| 0 | 0:SBL1 | 0x0 | 512K | ro | never write |
| 1 | 0:MIBIB | 0x80000 | 512K | ro | never write (partition table) |
| 2 | 0:BOOTCONFIG | 0x100000 | 256K | ro | never write; not the A/B switch on this board |
| 3 | 0:BOOTCONFIG1 | 0x140000 | 256K | ro | never write |
| 4 | 0:QSEE | 0x180000 | 1M | ro | never write |
| 5 | 0:DEVCFG | 0x280000 | 256K | ro | never write |
| 6 | 0:CDT | 0x2c0000 | 256K | ro | never write (DDR config) |
| 7 | 0:APPSBLENV | 0x300000 | 512K | **rw** | only via a validated env procedure (§3) |
| 8 | 0:APPSBL | 0x380000 | 1.25M | ro | never write (U-Boot) |
| 9 | 0:ART | 0x4c0000 | 1M | ro | never write (per-unit RF calibration) |
| 10 | 0:TRAINING | 0x5c0000 | 512K | ro | never write |
| 11 | rootfs | 0x640000 | 53.5M | rw | slot 0 (UBI: kernel + ubi_rootfs) |
| 12 | rootfs_1 | 0x3bc0000 | 53.5M | rw | slot 1 |
| 13 | tp_data | 0x7140000 | 8.25M | ro | never write (MAC, device-id, PIN, user-config) |
| 14 | radio | 0x7980000 | 4.25M | ro | never write |
| 15 | data | 0x7dc0000 | 512K | rw | unknown use; leave alone |

Matches `/proc/mtd` from hardware `[HW-3P]`. Checked on every built DTB by `tests/static/check_dtb.py` `[STATIC]`.

## 2. What the dev image does to flash at runtime `[SRC]`

- **preinit 09_mount_tp_data:** `ubiattach` + `mount -o ro` of tp_data. The MTD partition is `read-only`, so UBI attaches in read-only mode and cannot scrub, wear-level or erase. The third-party logs show `UBIFS (ubi1:0): recovery needed … recovery deferred` `[HW-3P]`: the stock firmware left tp_data uncleanly unmounted, and a **read-write** mount would write a UBIFS recovery. The read-only mount is therefore required, not optional.
- **caldata hotplug:** reads ART into RAM (`/lib/firmware`). Never writes ART.
- **sysupgrade:** refused for this board in both `platform_check_image` and `platform_do_upgrade` (dev 0005). `-F` cannot bypass it, and the refusal happens before any flash access.
- **uboot-envtools:** no config is generated for this board, so `fw_setenv` has no target. This is deliberate; see §3.
- Nothing attaches `rootfs`, `rootfs_1` or `data`.

The **baseline** (unmodified Sply-Dev v0.5-test) image has no sysupgrade interlock. Do not run `sysupgrade` on it.

## 3. A/B boot selection: what is known and what is not

| Item | Status |
|---|---|
| Slot variable is `tp_boot_idx` in the U-Boot env (APPSBLENV), 0 → `rootfs`, 1 → `rootfs_1` | `[SRC]` per Sply's reading of the AX23 v2 GPL source (`configs/ipq5018.h BOOT_IDX_FLAG`, `nvrammanager`) and kuncy7's AX55/AX5x platform.sh. **Not re-verified here** (GPL tarball not available on this host). |
| BOOTCONFIG/BOOTCONFIG1 are not the switch | `[SRC]` same sources; kept read-only. |
| U-Boot environment on the tested unit has a **bad CRC** (`*** Warning - bad CRC, using default environment`) | `[HW-3P]`, AX21 v5 U-Boot `jenkins-Router-Archer_AX23v2-8` |
| Consequence | U-Boot runs on its **built-in** default environment. `fw_setenv` with a default uboot-envtools config would write a *new* environment that lacks this U-Boot's `bootcmd` (the AX55 v4 case: board stops at the U-Boot prompt). kuncy7's `tplink_set_boot_idx()` handles this by writing `bootcmd bootipq` together with `tp_boot_idx`. **For the AX23, the correct built-in bootcmd, env size and env offset are not verified.** |
| Fallback behaviour | Per kuncy7 for TP-Link IPQ50xx U-Boot: if the selected slot **fails to load**, U-Boot tries the other slot. There is no boot counter, so a kernel that loads and then crashes is **not** detected. Unverified for AX23. |
| Env size | Unknown. AX55 v1 uses `0:APPSBLENV 0x0 0x40000 0x20000`. `tools/uboot/ubootenv.py` finds the size from a read-only dump by CRC, but a bad-CRC env cannot show its size. In that case the size has to come from the GPL U-Boot `CONFIG_ENV_SIZE` or from `printenv` on the UART console. |

### Proposed installation design (NOT implemented in the dev image, NOT validated)

Required preconditions, all on real hardware:
1. A working **1.8 V** UART console (the unit has no level-shifter populated). This is the only verified recovery path.
2. A full read-only flash backup (`tests/hardware/backup-flash-ro.sh`) with verified checksums, stored off-device.
3. From UART: `printenv` output saved (built-in env, `bootcmd`, `tp_boot_idx` if any).
4. Env size and offset determined (GPL source or `printenv`/`saveenv` behaviour), and a test on a `rootfs_1`-only image proving that U-Boot boots slot 1 when `tp_boot_idx=1`.

Install procedure (to be implemented only after 1-4):
- Identify the running slot. In a RAM boot neither slot is running, so **always target the slot that does not hold the newest stock firmware** and leave the other untouched as a recoverable stock fallback.
- Write the target slot first (`ubiformat` + UBI volumes), verify by reading back, and **only then** flip `tp_boot_idx`. This is the MR80X v2 order; kuncy7's AX5x case flips first.
- When writing the env, include the verified `bootcmd`, because the env CRC was bad on the tested unit.
- Never touch BOOTCONFIG*, ART, tp_data, radio, APPSBL, SBL1, QSEE, CDT, MIBIB.
- Recovery: UART → `tftpboot` the RAM image (verified path) → from OpenWrt, `tp_boot_idx` back to the stock slot or rewrite the slot from the backup.

## 4. UART-free installation: research result

| Path | Evidence | Verdict |
|---|---|---|
| Stock web UI upgrade with an OpenWrt image | Stock images are RSA-2048 PSS-signed and AES-encrypted, with the key derived from the signature salt `[SRC]` (`docs/FIRMWARE-EXTRACTION-METHOD.md`). The web UI verifies the signature. An OpenWrt image cannot carry a valid TP-Link signature. | **Not possible.** Editing headers would not pass RSA verification, and this project does not try to bypass it. |
| AX55 v1 method (older MD5-checked stock + telnet repack) | Applies to TP-Link images from 2022-2024. The AX23 v2 U-Boot is dated Feb 2025, and every AX23 v2 image examined (1.1.2) is RSA-signed `[SRC]`. No MD5-only AX23 v2 release is known. | **Not available, as far as is known.** |
| Stock root shell via the "disclosed LuCI vulnerability" mentioned in the Sply-Dev DTS header | Not documented anywhere public that was reachable. Depends on firmware version and may be patched. | **Not an independently documented method.** Not used. |
| U-Boot TFTP or web recovery (reset held at power-on) | U-Boot prints `button_init done~` `[HW-3P]`, so it reads the button. Whether it then starts a TFTP client or an HTTP recovery server is **unknown**. | **Unverified.** Safe passive test: §5. |
| UART + TFTP RAM boot | Verified repeatedly `[HW-3P]` (`setenv serverip …; tftpboot; bootm`, image at 0x44000000). | **The only verified path.** It requires opening the case and adding a 1.8 V adapter (or 1.8 V-capable USB-UART). |

**Conclusion: no safe UART-free installation method can be shown for the AX23(EU) v2.0.** Physical UART access (1.8 V) is required for both testing and recovery.

## 5. Safe, passive experiment the user can do without UART (optional)

Goal: find out whether U-Boot has a network recovery mode, **without** sending it anything.
1. PC wired to a LAN port; PC address 192.168.0.66/24 (a common TP-Link recovery server address; also try 192.168.1.66 on a second run). Start `sudo tcpdump -ni <if> -w recovery.pcap` with **no** TFTP or HTTP server running.
2. Power the router on while holding reset for about 10 s.
3. Look in the capture for ARP who-has or TFTP RRQ (and the requested file name) from the router, or try `http://192.168.0.1` for a recovery page. **Do not upload anything.** Power-cycle normally afterwards. With nothing served, U-Boot boots the existing slot.

A TFTP RRQ would reveal a recovery path. Using it still requires an image that U-Boot accepts, which for TP-Link usually means a signed stock image, so it would be a **stock-firmware** recovery path, not an OpenWrt installer.

## 6. Status

| Item | Status |
|---|---|
| Partition map correct, factory partitions read-only | PASS `[STATIC]` + `[HW-3P]` /proc/mtd |
| sysupgrade cannot write NAND (dev) | PASS `[STATIC]` (interlock present in built rootfs); runtime NOT HARDWARE TESTED |
| A/B boot (`tp_boot_idx`) | **NOT TESTED**; design only |
| NAND installation | **BLOCKED**: env size/bootcmd unverified; UART required |
| Recovery | **BLOCKED** for this project (no UART adapter); verified by a third party via UART TFTP |
