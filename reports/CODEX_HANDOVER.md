# Codex handover for Archer AX23 EU V2.0

## A. Workspace and revisions

Repository https://github.com/john35413/DuinoCoinUSB_ESP8266, development branch `claude/openwrt-archer-ax23-v2-5vtpoe`. Codex started from `a4aa07ec193771eb5aaa69768b6dc099e7a2e2c4` in a clean WSL Ubuntu checkout. Repo root `/home/jfits/DuinoCoinUSB_ESP8266`. Project `/home/jfits/DuinoCoinUSB_ESP8266/AX23_V2_OPENWRT`. The Claude cloud path was `/home/user/DuinoCoinUSB_ESP8266/AX23_V2_OPENWRT`. All Codex work is under the original project directory and its history. The upstream Sply project is a pinned read-only reference.

The report's containing Git revision can be resolved with `git log -1 --format=%H -- reports/CODEX_HANDOVER.md` from the project. For the actual current branch HEAD and push state use `git rev-parse HEAD` and `git ls-remote origin refs/heads/claude/openwrt-archer-ax23-v2-5vtpoe`. The independently prepared inner firmware source is `adc91ccde8a2f25a00e994fe01485e1fb56e33a2`, based on OpenWrt `98b1185d039344553aaf8270d0661cfad4f0a54d` and Sply `93028b47d291e251dc108de5fbd8bd3f77a9300c`. All three feed pins are in configs/sources.lock.

## B. Takeover state and artifact provenance

No original cloud working tree, final build log or ITB was available locally. The previous developer reported that the incremental 0001–0018 build completed; final artifact collection and reports were interrupted. An earlier communicated measurement for the RAM ITB was 13,334,464 bytes, SHA256 `82bc7083ed7fb6eb275aadabccdb7a5c81a88e394bd42b646911963a068023cf`, with 69 checks passing. Codex has not verified those bytes. The initial pushed manifest instead names an older build with SHA256 `14f21390e1497c691a4285c9d4fb273fc5f600083012355adee15e450689c38d` and inner revision `0b25ecfe1e4121aedd6a172edf806e90de8dc335`. Historical logs copied by Git are not evidence of this local build. The expected filename in all three cases is `openwrt-qualcommax-ipq50xx-tplink_archer-ax23-v2-initramfs-uImage.itb`.

## C. Corrections and scope

The full per-patch and cross-device analysis is in [codex-patch-audit.md](codex-patch-audit.md). [real-memory-budget.md](real-memory-budget.md), [nand-write-protection-audit.md](nand-write-protection-audit.md) and [ethernet-initialization-comparison.md](ethernet-initialization-comparison.md) contain the corresponding measurements and unresolved conditions. Git's exact file inventory including every new patch, tool and test is available with `git diff --name-status a4aa07e..HEAD -- .`.

| Commit | Scope | Consequence |
|---|---|---|
| dd3b5be, 03a4168 | board2 parser, EU extractor, build/validator and tests | High. Rejects unknown board identities, wrong radio payload and unqualified fallback. |
| 906f9cb (0019), b438f7b (0022) | ath11k descriptor-bank and datapath startup unwind | High. Prevents releasing the wrong descriptor pool or retaining startup allocations after failure. |
| c6e710b (0020), 3d4c674 | kernel UBI auto-attach, DT checks, device diagnostics | High consequence. Avoids probing unused data, detects writable or unreadable MTD flags and checks remaining high-order capacity. |
| 83417ea (0021) | preinit radio holds and sequential bring-up, shell regressions | Medium. Reports ineffective holds; a failed 2.4 GHz start leaves 5 GHz held. |
| ac87fa3, e6ed77f, 004d13b | FIT selector, extracted DT/kernel, embedded initramfs and tests | High validation impact. Establishes actual boot payload and compares the selected kernel's embedded modules and hooks against staging. |
| 58640fe, cf753d4 | test selection, result propagation, static AArch64 emulator discovery | Medium validation impact. Records unavailable inputs and supports packaged qemu-user. |
| 8a2c26e | original patch set, OEM/PCS comparison, MPD binding and memory accounting | Corrects prior assertions about fallback IDs, the entire host DMA budget, and Q6 crash recovery. |

## D. Reproduction and evidence

Run from the WSL project folder. Private OEM downloads and extracted board-data payloads stay in ignored storage. Do not stage these, calibration files or a firmware binary containing them in the public repo.

- `tools/bdf/board-data-from-tplink-firmware.sh` verifies TP-Link's signed EU image. Local logs `build/extract-eu.log` and `logs/dev/board-data.status`. Signed regional raw hashes (IPQ5018, QCN6122 respectively) are `35b9f9028e0a50860796c078ba17477bce8f320d06e091fee6d7635cc9ccfc1b` and `722e3aeed84377436aab8bf3aebe418536311753e1226ed8b4aa4b4c23a8bbd2`.
- `python3 -W ignore -I tests/unit/test_tools.py -v` passed all 15 tests, including negative FIT and board-data cases. `bash tests/unit/test_radio_profile.sh` passed 13 checks against fake sysfs. `python3 -I tests/unit/test_ath11k_rings.py -v` exercises the ring model. `python3 -I tests/static/check_dtb.py logs/dtb-dev.dts` passed on the archived predecessor DTS including the MPD match. These are VERIFIED BY STATIC/BINARY VALIDATION or VERIFIED IN SIMULATION ONLY.
- `tools/test-dev.sh all` during preparation exposed the unavailable rootfs/VM and lack of permission to create a mount namespace for the caldata fixture. The latter passed using `sudo env PATCHED_CALDATA="$PWD/build/dev/openwrt/package/base-files/files/lib/functions/caldata.sh" bash tests/unit/test_caldata_regdomain.sh`. See `build/regression.log`, `build/test-radio.log`, `build/test-fit-final.log` and `logs/test-*.log`. The archived compiled DTS is separate from the required new FIT validation.
- Exact backports source and all applicable backports patch directories were replayed under `build/backports-7.2` with the pinned OpenWrt `scripts/patch-kernel.sh`. Log `build/backports-patch.log`. This checks application to the driver's real sources, independently of the outer Git series.
- Fresh independent build: `tools/build-dev.sh --variant dev --jobs 4`. Pipeline log `build/codex-build.log` and active stage logs `logs/dev/08-kernel.log` and `logs/dev/09-world.log`. **Checkpoint: clean build in progress. No independent ITB or checksum at this checkpoint.** Logs for later stages and RAM artifact metadata present in the checkout at takeover refer to an earlier build. A new result requires stages 10 and 11 and a local SHA256 of the actual file.

## E. Open observations

| Question | Evidence now | Smallest discriminating observation |
|---|---|---|
| GPIO 26 or 39 | VERIFIED BY OEM SOURCE ANALYSIS. MDIO reset is 26, QCA83xx reset is 39. Neither identifies the PCB trace. | Unpowered continuity from RTL8367S-VB nRESET to accessible candidate net or passive high-impedance capture of both candidates and nRESET through one stock power-on. Keep GPIO 39 pending evidence. |
| Radio and OTP | VERIFIED BY OEM SOURCE ANALYSIS. Stock b24/b60 correspond to 36/96. AX21 sibling reported 255. | Capture each radio's QMI chip/board ID and requested variant, BDF acceptance, per-unit ART load, country, PHY registration and regulatory flags. Test each radio alone first. |
| DMA, fragmentation and both radios | VERIFIED BY UPSTREAM SOURCE ANALYSIS. At least two 2 MiB WBM requests per radio survive the TX change. | Save buddyinfo, MemAvailable, allocation failures and QMI/firmware events before probe and after each PHY appears. Compare sequential and concurrent probe. |
| Ethernet, resets and cold boot | VERIFIED ON RELATED HARDWARE for sibling symptoms. AX23 EU behavior unmeasured. | One real bidirectional LAN/WAN test with port counters/FCS at both ends; repeat cold and warm starts and look for carrier with zero frames. |
| Q6 recovery | VERIFIED BY UPSTREAM SOURCE ANALYSIS. MPD compatible. 0016 affects a different driver. | Read actual remoteproc driver, recovery and coredump mode. Time recovery/PHY reappearance after a naturally occurring assert, without forcing a crash. |
| NAND | VERIFIED BY UPSTREAM SOURCE ANALYSIS for partition protections and attach policy. | Record cmdline, /proc/mtd, each sysfs MTD flag, UBI backing MTD and tp_data mount flags without any writes. |
| Physical memory and stability | UNVERIFIED HYPOTHESIS on this unit. | Track load/available memory, buddy orders, firmware restarts, FCS and link counters through a representative 24–48 h soak, including reconnects and cold boots. |
| UART-free operation and persistence | No documented signed-stock path to start this custom image in reviewed materials. Persistent image, rollback and recovery await separate authorization. | A vendor-documented supported boot method for the exact hardware/firmware would change the UART-free verdict. First RAM test requires measured console levels and correct adapter; read-only backup/recovery verification is a separate prerequisite for a future installation decision. |

## F. Resume

Check the current build stage and the final section of this report first. Preserve any uncommitted Claude cloud files separately when that workspace returns. For a prepared checkout use `tools/build-dev.sh --variant dev --resume --jobs 4`. Do not launch a second make in a live tree. Start by verifying the new FIT against its recorded hash, selected config@mp02.1 kernel and FDT, embedded board profiles and per-radio modules. Only a local RAM ITB that passes those checks is a candidate for owner-controlled physical testing. Begin with radios held, capture MTD/UBI and Ethernet evidence, then individual radios, then sequential dual radio. No router or Raspberry Pi was accessed by Codex.

No need to repeat the prior long hwsim matrix to infer hardware behavior. Repeat focused software tests when their inputs change. The board-data lookup boundary (0003), WBM allocation and failure paths (0012/0018/0019/0022), boot-time overrides (0017/0021) and MTD policy (0005/0015/0020) are the relevant patches for the first hardware log. Persistent installation remains outside this task.
