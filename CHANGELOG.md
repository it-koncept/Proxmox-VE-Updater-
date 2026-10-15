# Changelog

## v3.4 (host updates, Fase B B7)
- **New:** `--host` updates the PVE host itself: `apt-get update` then `apt-get -y dist-upgrade` (noninteractive, keeps conffiles), each phase bounded by `HOST_UPDATE_TIMEOUT` (default 3600 s).
- **Policy gate (SEC-001):** a real host run requires typing `YES` at an interactive prompt; with no tty (cron/timer/ssh non-interactive) it refuses with exit 2 unless `--yes` is given explicitly. Never automatic.
- **Gates:** cluster quorum via `pvecm status` (standalone ok, quorum lost -> refuse, SEC-013); host `/` free space >= `MIN_HOST_FREE_MB` (default 1000); failed `apt-get update` aborts before dist-upgrade (SEC-003); lock held during the run.
- **New:** after success, `/var/run/reboot-required` (path via `HOST_REBOOT_MARKER`) -> status `warning` "reboot required"; the tool NEVER reboots (FR-009 policy).
- **New:** `--host --dry-run` runs `apt-get -s dist-upgrade` simulation only — no apt state change; `--host` cannot be combined with `--only/--exclude/--list/--check`; host run recorded in the JSON report as vmid `host`.
- **Tests:** 12 new cases (60 total, all passing): dry-run simulation-only, unattended refusal, --yes flow, update-failure blocks upgrade, dist failure, quorum lost/quorate, low disk refusal, flag conflicts, report entry, reboot-required warning, non-root refusal. New mocks: `apt-get`, `pvecm`.
- Live prod-node verification: NOT RUN this round (approval prompt timed out; no retry per policy). Mock coverage stands; live check pending user approval.

## v3.3 (reporting, Fase B B6)
- **New:** `--report <path>` writes a JSON report after the run: tool/version/node/mode, start/finish/duration, `summary` (success/warning/skipped/failed) and a `guests` array with per-guest `vmid, type, name, action, status, reason, duration_s` (FR-013). Built with jq only — no hand-concatenated JSON; unwritable path fails in preflight (exit 2) before any work.
- **New:** `--log-file <path>` appends every timestamped log line to a file (FR-006); unwritable path fails in preflight.
- **New:** per-guest status model: `success | warning | skipped | failed` for update runs, `planned` for dry-run/list/check. A guest updated despite a backup-coverage warning ends as `warning`, not `success`.
- **New:** end-of-run per-guest results table in the log; summary line now shows `(N with warnings)` when warnings occurred (existing `N updated, F failed, S skipped` prefix preserved).
- **Tests:** 7 new cases (48 total, all passing): report validity/completeness/summary, failure reflected, warning status, log-file content, unwritable log/report paths rejected pre-run, dry-run and check report modes. Two real bugs caught and fixed: jq `tonumber? // .[0]` indexed a string after the pipe (report crashed on malformed entries), and a test-side quoting bug (`\"` inside single quotes).
- Verified live on prod-node with `--dry-run --report --log-file` (read-only): 16 guests reported, 102/104 correctly `skipped - no guest agent`, valid JSON, files removed after.

## v3.2 (safety preflight, Fase B B5)
- **New:** QEMU Guest Agent preflight — update candidates are checked via `pvesh get /nodes/<node>/qemu/<id>/agent` before any exec; no/unresponsive agent -> guest **skipped** with an explicit fix hint (`qm set <id> -agent enabled=1`), never reported as success. Disable with `AGENT_CHECK=0` (then the exec path fails as before).
- **New:** guest disk-space preflight — `df -P -k /` inside the guest; free space below `MIN_GUEST_FREE_MB` (default 500) or a failed/unparseable check -> guest skipped with a warning (SEC-009: unknown prerequisites are never treated as ready). Skipped in `--dry-run` (keeps dry-run free of guest exec). Disable with `DISK_CHECK=0`.
- **New:** backup coverage (FR-010) — enabled vzdump jobs read from `/cluster/backup`; guests not covered by any enabled job warn per guest; unreadable job list warns `backup status unknown`. Advisory by design (warn, don't block); disable with `BACKUP_CHECK=0`.
- **New:** `--check` now also reports update candidates without guest agent and without backup-job coverage.
- **New env:** `MIN_GUEST_FREE_MB`, `DISK_CHECK`, `AGENT_CHECK`, `BACKUP_CHECK` (validated: numeric / 0-1).
- **Tests:** 9 new cases (40 total, all passing): low disk skip, failed disk check skip, disk check disable, backup not-covered warning, backup-unknown warning, --check gap reporting, invalid env rejection, agent-check disable. Mocks extended with df/agent/backup-job fixtures. One real bug caught and fixed: free-space parsing concatenated all digits of the df table into one overflow number.
- Verified live on prod-node with `--check` only (read-only): correctly reported 2 yum candidates without guest agent (102, 104) and 0 backup coverage gaps (weekly all=1 job).

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
