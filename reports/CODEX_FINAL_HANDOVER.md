# Preliminary Codex handover

Baseline 9576d3ea680aabcf9a14eb905c97ad99a7d430b8. Latest local outer commit is the parent repository's current `git rev-parse HEAD`. This handover remains preliminary until a new build and validation are complete. No push was made.

No new numbered patch was justified. Diagnostic correction ec07e66 changes `tests/hardware/ax23-selfdiag.sh`: cumulative trunk counters now carry INFO status, ART byte counts no longer imply transmit-power fields, and an unfamiliar OTP ID requires board evidence before mapping. See [the adversarial audit](final-codex-adversarial-audit.md).

The prepared inner OpenWrt source is d0e9750 after applying outer 0026 and 0027. Its kernel source has inner 0821; `build/backports-7.2` has inner 965. These prepared files have not been compiled locally. The local OpenWrt build directory, downloads, toolchain and cached objects remain intact.

Focused checks: `bash tests/unit/test_mpd_recovery.sh` passed its prepared-source model and reverse-patch negative cases; the actual-source ring allocator and cleanup models passed; ShellCheck, `sh -n` and the read-only selfdiag test passed. The ring and trunk wrapper scripts skip because there is no locally prepared mac80211 package tree or compiled reference DTB. No new image was produced. Claude's reported ITB is not independently present or hashed here.

Next action: use the existing build cache for a targeted incremental build of the updated kernel/mac80211 and image, then run `tools/validate-artifacts.sh` on the resulting tree. Verify the new ITB checksum, selected FIT configuration, embedded modules/DTB, NAND flags and diagnostics before deciding on physical RAM boot. The GPIO 26/39 trace, dual-radio calibration and live Q6 recovery require physical observations. Do not treat the test models as hardware evidence.
