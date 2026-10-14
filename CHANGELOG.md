# Changelog

## v2
- **Fix:** iteration is now line-based (`while read` + process substitution). v1 used `for VM in $VM_LIST`, which word-split the JSON — any guest with a `description` containing spaces produced garbage VMIDs.
- **Fix:** `qm guest exec --timeout` (default 1800s, configurable via `QEMU_EXEC_TIMEOUT`). v1 used the 30s default and killed package updates mid-run, risking broken dpkg/rpm states.
- **Fix:** tags are matched exactly per `;`-separated entry (case-insensitive). v1 substring-matched, so e.g. a `compat` tag triggered apt.
- **Fix:** node name passed to jq via `--arg` instead of shell-interpolated into the filter.
- **Fix:** guest command exit codes are now checked (`pct exec` rc / `qm guest exec` JSON `.exitcode`); failures are logged with output tail and the script exits non-zero.
- **New:** `flock` single-instance guard — safe for overlapping cron runs.
- **New:** numeric VMID validation before any `pct`/`qm` call.
- **New:** `DEBIAN_FRONTEND=noninteractive` + dpkg `--force-confdef/--force-confold` so unattended apt upgrades never hang on prompts.
- **New:** dnf auto-detection for `yum`-tagged guests (yum is gone on RHEL8+/Fedora).
- **New:** `--dry-run` flag, `PVE_NODE` override, timestamped logs, end summary.
- **Docs:** fixed broken code fences in README, corrected script paths, added security notes and timeout explanation; added LICENSE file (README claimed MIT but none existed).

## v1
- Initial version: tag-driven apt/yum updates for running LXC/QEMU guests, windows tag skipped.
