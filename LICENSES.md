# Licensing and attribution notes

This project combines patches, scripts, configuration, test fixtures and documentation from different authors and upstream projects. There is no blanket relicensing claim in this file.

- The original Archer AX23 v2 port and hardware documentation are by Sply-Dev: <https://github.com/Sply-Dev/openwrt-archer-ax23-v2>. That repository identifies its license as GPL-2.0. The pinned source commit is recorded in `configs/sources.lock`; the unmodified license text is retained at `licenses/GPL-2.0.txt`.
- OpenWrt/Linux code represented by patches remains under its original license. Preserve the upstream notices and SPDX identifiers in each patch and in the code to which it applies.
- Project scripts that declare an SPDX identifier remain under that declared license. Files without a license identifier retain their existing author/rights status; this migration does not add a blanket license to them.
- Proprietary TP-Link firmware, radio board data and factory calibration are not included and are not licensed for redistribution by this project.

The build downloads upstream source trees at the exact revisions in `configs/sources.lock`; those sources retain their own license and attribution files and are not vendored in this repository.
