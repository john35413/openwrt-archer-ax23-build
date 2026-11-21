# Final readiness matrix

Labels as in `wifi-root-cause.md`: **HW** our real AX23 · **ID** identical hardware ·
**REL** related hardware · **SRC** source analysis · **BUILD** build/static ·
**SIM** simulation only · **HYP** hypothesis · **3P** third-party AX23-firmware report.

No EU AX23 v2 has been run by this project or anyone; all "AX23 hardware" rows are
**3P** (AX21 v5 running AX23 v2 firmware) or **HYP**. Gates per
`physical-hardware-test-plan.md`: **A** build/static/sim · **B** RAM-boot acceptance ·
**C** persistent install · **D** recovery/rollback · **E** soak. **C/D/E cannot be
declared offline and are not.**

## 1. Subsystem matrix

| # | Capability | Best evidence we have | Gate | Offline status |
|---|---|---|---|---|
| 1 | Reproducible build (baseline + dev, pinned SHAs) | BUILD | A | **DONE** |
| 2 | Wi-Fi `-12` root cause = missing board data | SRC + 3P log | A | **DONE** (fix in image) |
| 3 | EU board data from the unit's own signed firmware | SRC (RSA-verified) | A | **DONE** (reproducible, git-ignored) |
| 4 | DTS radio config matches stock (userpd2, mem-mode 2) | SRC (stock DTB) + REL (EX511) | A | **DONE** |
| 5 | ath11k low-memory RX rings (0002) | BUILD + SRC | A | **DONE** (effect HYP) |
| 6 | ath11k low-memory **TX completion ring** (0012) | BUILD + model + REL | A | **DONE** (effect HYP) |
| 7 | Upstream ath11k/mac80211 stability+CVE fixes (0013/0014) | BUILD | A | **DONE** |
| 8 | Wi-Fi actually initialises on hardware | — | **B** | **BLOCKED** (needs unit) |
| 9 | Ethernet/switch probe, 2.5G trunk | 3P logs + REL | A/B | A done; trunk frames **B** |
| 10 | LAN↔WAN NAT, real client traffic | **3P (v0.5-test, real speedtest)** | B | software path done; HW is **B** |
| 11 | VLAN guest/IoT isolation on the DSA switch | SIM (twin W20–W26) | B | SIM done; switch VLAN is **B** |
| 12 | UNIPHY cold-boot trunk race mitigation (0006–0009) | SRC + REL (MR80X/EX511 failures) | B | patches done; 20× reboot is **B** |
| 13 | Full software stack (DHCP/DNS/fw4/LuCI/WPA2/WPA3/guest/IoT/reboot) | **SIM 48/48 ×3** | A | **DONE** (SIM) |
| 14 | Low-memory host-stack behaviour under shrinking RAM | SIM (twin matrix) | A | **DONE** (SIM; not ath11k mem) |
| 15 | NAND partition map, slot isolation, env layout, bad-block, scrub | **SIM (nandsim lab, AX23 geometry)** | A | **DONE** (SIM) |
| 16 | FIT image integrity (hashes + config@mp02.1) | BUILD (`fit-verify.py`) | A | **DONE** |
| 17 | All 16 flash partitions read-only in the RAM image (0015) | BUILD (DTB check) | A | **DONE** |
| 18 | sysupgrade refused on this board (0005) | BUILD | A | **DONE** |
| 19 | U-Boot env read-only diagnostics (0011) | SRC + SIM (lab L04) | A | **DONE** |
| 20 | UART-free **stock** recovery exists | SRC (GPL U-Boot) | **D** | design done; **HW-BLOCKED** |
| 21 | UART-free **OpenWrt** install | **SRC: NOT possible** (RSA enforced, disasm) | — | **ANSWERED (no)** |
| 22 | Read-only hardware self-diagnostic (redacted) | BUILD + SIM (twin S06) | A | **DONE** |
| 23 | Read-only full flash backup procedure | BUILD (script) | **B/C** | script done; run is **B** |
| 24 | Persistent install writes inactive slot only, verified | SIM (lab) + SRC | **C** | design/sim done; **BLOCKED** |
| 25 | Recovery + dual rollback drill | SRC + SIM | **D** | design done; **BLOCKED** |
| 26 | 24–48 h soak stability on hardware | — | **E** | **BLOCKED** |
| 27 | Pi monitor/backup integration (least-privilege) | BUILD (static) + SIM (W26) | B | design done; Pi run **BLOCKED** |
| 28 | GR regulatory configuration | BUILD (see §3) | A/B | config done; RF is **B** |

## 2. Gate roll-up

| Gate | Scope | Status |
|---|---|---|
| **A** build/static/sim | rows 1–7, 13–19, 21, 22, 28 | **COMPLETE** — 67 validator checks, unit + static + network + twin + NAND suites green; dev image builds with 0012–0015 |
| **B** RAM-boot acceptance | rows 8–12, 23, 27 | **PREPARED, BLOCKED** — scripts + gates ready, needs the unit + UART |
| **C** persistent install | row 24 | **BLOCKED** — owner authorization + HW only |
| **D** recovery/rollback | rows 20, 25 | **BLOCKED** — HW only |
| **E** soak | row 26 | **BLOCKED** — HW only |

## 3. Regulatory (GR)
The twin applies country **DE** (EU) as a representative example. For the owner in
Greece, set country **GR** in `/etc/config/wireless` (`option country 'GR'`) on both
radios; the hostapd country-code fix (patch 0010) guarantees a radio's own country is
used and `00` from another radio never breaks AP start. GR and DE are both ETSI/EU
regulatory domains (same 2.4/5 GHz channel and DFS rules), so behaviour is
equivalent; the exact TX-power/DFS table is applied by the kernel's regdb at runtime
and is **RF-verifiable only on hardware** (B). **BUILD** for the config, **HYP** for
the emitted power.

## 4. What is genuinely finished vs. what waits on the bench
- **Finished (A):** every software, build, source-analysis, simulation and
  static-safety item. The image is, as far as any offline method can show,
  **correct and safe to RAM-boot**; the two hardware-flash-risk questions (UART-free
  install; writable partitions) are answered/closed.
- **Waiting (B–E):** anything that needs the physical radios, switch SerDes, NAND
  writes, or days of uptime. These are **fully prepared** (staged plan + read-only
  scripts + gates) and **cannot** be shortcut from here. No row is claimed as
  hardware-validated.

See `final-validation.md` for the decision this matrix supports.
