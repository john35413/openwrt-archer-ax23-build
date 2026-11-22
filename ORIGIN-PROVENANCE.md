# Source and history provenance

- Original container repository: <https://github.com/john35413/DuinoCoinUSB_ESP8266>
- Original development branch: `claude/openwrt-archer-ax23-v2-5vtpoe`
- Imported subtree: `AX23_V2_OPENWRT/`
- Source branch HEAD used for extraction: `6847cff6fc5a7bea141c42ccde19d0c4f9f972f4` (Claude's validation reconciliation and console RAM-load notes)
- `git subtree split --prefix=AX23_V2_OPENWRT` result before privacy filtering: `9930dc13d49ada6736f375bf966a0d0dd0c17be0`
- Build-source provenance remains: outer `8673c2e6a001fce6271d11700bfa1d27dc51edc9`, prepared OpenWrt tree `d0e975060d5c71565e0a62abbddf48ef1312478c`; diagnostic correction `ec07e66362f4aba0ce73bc7970d0f33488c012fd`; host DTB-checker correction `bd2326a5002eca746ce3edcdff5b7cb2913188ae`.

The imported project history was split from the original repository, then `logs/` was removed from every historical commit before publication because the tree contained raw build, simulator and device-capture logs. The remaining commit authors, author dates, messages and non-log project changes are retained; commit IDs necessarily changed during subtree extraction/history filtering. The original repository and its history were not rewritten. Build-source commits and image checksums above remain historical provenance, not new-repository commit IDs.

The following local-only material was not imported: `build/`, downloaded dependencies, OpenWrt worktrees, toolchains, ignored EU `board-data/`, the locally generated ITB, private calibration, uncommitted logs and experimental build logs. The one-off script that had been stored under `logs/network/probe.sh` was excluded with the log tree; it hard-coded `/home/user/...` and is not referenced by the test/build pipeline.
