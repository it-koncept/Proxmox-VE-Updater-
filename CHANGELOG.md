# Changelog

## v3.1 (CLI, Fase B B4)
- **New:** `--version` prints the version (now `3.1.0`).
- **New:** `--list` — read-only table of node guests with planned action per guest (`apt`/`yum`/`windows`/`stopped`/`no-tag`/`excluded`/`not-targeted`/`malformed`); works as non-root; takes no lock.
- **New:** `--check` — runs the full preflight (root included) and prints an inventory summary by action; makes no changes.
- **New:** `--only <ids>` / `--exclude <ids>` (comma-separated, numeric; `FR-008`). Values are validated as VMID lists before use — injection-style values are rejected (exit 2). `--only` VMIDs not found on the node produce a typo warning. Filters combine with `--dry-run`/`--list`/`--check`.
- **Tests:** 12 new cases (31 total, all passing): version, list, check (root + non-root), only/exclude filtering, invalid-list rejection, unknown-VMID warning, dry-run+filter, list classification, check with pvesh failure, missing flag value.
- Verified live on prod-node with read-only flags only (`--version`, `--list`, `--check`, `--dry-run --only`); no production changes.

## v3 (hardening, Fase B B1–B3)
- **Fix (critical):** `pvesh` failure or non-JSON output is now a hard error (exit 2). v2 silently reported `0 updated, 0 failed` **success** when pvesh failed or output was corrupt.
- **Fix:** `pct exec` now bounded by `timeout` (`PCT_EXEC_TIMEOUT`, default 1800 s). v2 only bounded `qm guest exec`. Note: the timeout bounds the pct client; a killed client does not necessarily stop the package command already running inside the container.
- **Fix:** `", dry-run"` marker was printed on every run (`${DRY_RUN:+…}` is true even when `DRY_RUN=0`); now only on dry runs.
- **New:** preflight before any guest is touched: root required for real runs (dry-run exempt), required binaries (`jq pvesh pct qm flock timeout`), numeric validation of `QEMU_EXEC_TIMEOUT`/`PCT_EXEC_TIMEOUT`.
- **New:** unknown CLI arguments rejected (usage + exit 2) instead of silently ignored; `-h/--help` added.
- **New:** `LOCK_FILE` env override (default path unchanged). Unopenable lock file = preflight error.
- **New:** loud warning when 0 guests match the node (catches wrong `PVE_NODE`).
- **Change:** explicit exit codes: `0` ok | `1` guest failure(s) | `2` preflight/usage | `3` lock busy (v2 used 1 for both guest failures and lock contention).
- **Tests:** new mock-based suite `tests/run_tests.sh` (19 cases) — PATH-shadowed mocks of `pvesh`/`pct`/`qm`/`id` with a call log proving no real system command is reached. Baseline against v2: 9/17 passed (the 8 failures were exactly the bugs above); against v3: 19/19. `bash -n` and ShellCheck 0.11.0 clean.

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
