# Contributing

1. Confirm the change applies only to the Archer AX23 EU V2.0 target and identify the source-backed failure it addresses.
2. Keep firmware changes in a focused numbered patch under `patches/openwrt/`; add it to `patches/openwrt/series` in order. Keep optional diagnostic hardware variants outside the default series.
3. Add or update a focused test. State clearly whether evidence is source analysis, build, simulation, related hardware or the exact AX23.
4. Run applicable unit/static/artifact validation and record skipped inputs. Never convert an unknown result to PASS or weaken an artifact gate to silence a failure.
5. Update relevant reports, build provenance and handover notes. Do not claim physical validation unless the exact hardware was tested and raw evidence is available.
6. Preserve the upstream revision pins and all SPDX/copyright/license notices unless a documented engineering reason requires a change.

Never commit OEM firmware, board-2 data, ART/calibration dumps, credentials, private keys, raw logs containing identifying information, build caches, toolchains or firmware binaries. Keep private EU board data under ignored `board-data/`.

Physical work must follow `reports/first-ram-boot-checklist.md` and `tests/hardware/HARDWARE-TEST-PLAN.md`. Do not flash, erase, run sysupgrade, save U-Boot environment changes or bypass signature verification.
