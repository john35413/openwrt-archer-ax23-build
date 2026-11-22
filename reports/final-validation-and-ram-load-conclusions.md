# Final validation reconciliation and RAM-load conclusions

HEAD at the start of this step: `4328d47` (Codex), after my checkpoint `9576d3e`.
Labels: **SRC** (source or GPL tree), **BUILD**, **REL** (related hardware), **UNV**.

## 1. Checkout and what Codex changed
The cloud checkout was fast-forwarded to `4328d47` (clean tree, five Codex commits).
Codex changed: `tests/hardware/ax23-selfdiag.sh` (S2.4 stale counters, S3.22 ART/BDF
semantics), `tests/static/check_dtb.py` (dtc string-list cells such as `0x4c400000`
rendered as `"L@", ""`) with three regressions in `tests/unit/test_tools.py`, and the
handover, manifest, checklist, adversarial-audit and project-state reports. It
republished `artifacts/ram-only/dev/*` metadata and `reports/artifacts-dev.txt` for its
own local image (13,330,704 bytes, sha256 `6d85f2a8…a9ff`). That image is a separate
build from my cloud image (`f9aeb698…`); neither is in git.

## 2. 80 vs 77 PASS: exact difference
No check differs. My `10-validate.log` had 80 lines starting `PASS`; Codex reports 77
PASS + 1 INFO. The 3-line gap is **helper stdout, not checks**: two
`PASS: exact AX23 keys and matching board payloads` lines printed by `board2.py scoped`
and one `PASS actual driver allocation functions …` line printed by
`check_ath11k_cleanup.py`. Comparing check names, my 77 `r PASS` lines plus the 1 INFO
(rootfs size) equal Codex's list one for one. `tools/validate-artifacts.sh` is
unchanged between the two checkpoints. Codex's validator also ran against a different
build, so this reconciles the counts only; it does **not** validate its binary.

## 3. Tests run here (source and my own build tree only)
- Static runner: PASS, dev DTB 53 checks (my DTB, using Codex's updated `check_dtb.py`).
- Unit: all 12 suites PASS; `test_tools.py` 18 tests OK (includes Codex's three new cases).
- `unit-selfdiag-calregions`: PASS with **no SKIPs**; the two EU-fixture subchecks Codex
  had to skip ran against the stock EU board data present in this environment.
- `ubireader_extract_images` is available here (Codex's SKIP does not apply); no other
  suite was skipped.
None of this proves Codex's local ITB: its hash, FIT and rootfs were not available to me.
Recompute its sha256 locally before use.

## 4. UART-free installation: reviewed, unchanged
`uart-free-final-verdict.md` stands: web flasher and reset-held HTTP recovery are RSA-gated
(stock restore only); stock SSH gives no shell; telnet disabled; TDDP excluded; RE700X and
MR80X keyless methods do not transfer. No new legitimate network or service route was found
in this pass (U-Boot network boot at power-on does not exist: autoboot runs only `bootipq`).

## 5. Can U-Boot console commands boot our FIT under the signature policy?
- **Policy in TP-Link's GPL U-Boot (SRC):** `ipq5018_defconfig` has
  `# CONFIG_FIT_SIGNATURE is not set`; `CONFIG_CMD_BOOTM/NET/LOADB/LOADS` are enabled.
  Authentication lives only in `bootipq` (flash boot): it calls `qca_scm_call(SCM_SVC_FUSE,
  QFPROM_IS_AUTHENTICATE_CMD)` and takes the signed path (`qca_scm_auth_kernel`) only when
  the authenticate fuse reads 1. A console `tftpboot` + `bootm` is generic U-Boot: it checks
  the FIT's hash nodes, which our image carries, and performs no signature check. The
  bootloader itself is protected by the SoC boot chain, which we do not touch.
- **Real hardware precedent (REL):** the AX21 v5 unit running AX23 v2 firmware, Sply
  v0.2–v0.4-3, reached the U-Boot prompt over UART (1.8 V), loaded an **unsigned**
  initramfs FIT with TFTP and `bootm`, and booted to a shell, with no bypass.
- **Conclusion:** the supported way to load our FIT is the normal serial-console
  `tftpboot` + `bootm`; no security mechanism needs defeating. It is **UNV on the exact AX23
  EU V2.0** (fuse state, shipped U-Boot build and autoboot-abort setting are not observable
  offline) and the GPL defconfig may differ from the shipped binary.
- **Console requirement is unavoidable:** autoboot window is `CONFIG_BOOTDELAY` 1 to 5 s
  (the two defines in `ipq5018.h`), and `tftpboot`/`bootm` exist only at the prompt.

## 6. Remaining blockers and practical prerequisites
1. A **1.8 V-safe UART** (adapter with 1.8 V I/O or a level shifter): the only path to the
   prompt. Receive-only first; confirm voltage and pinout with a meter (checklist).
2. A TFTP host on the same LAN segment (Raspberry Pi with a throwaway dnsmasq TFTP on a
   dedicated USB Ethernet, per `uart-free-final-verdict.md` §4).
3. Observe at the prompt, before loading anything: `version`, `printenv bootdelay bootcmd`,
   and that `bootm` of our FIT prints `Verifying Hash Integrity ... OK`. If `bootm` rejects the
   image, or only a signed path is offered, **stop**: do not bypass.
4. Passive GPIO 26/39 trace and stock-recovery check (`first-ram-boot-checklist.md`).
5. Never `saveenv`, flash or run sysupgrade; no persistent image is authorised.
