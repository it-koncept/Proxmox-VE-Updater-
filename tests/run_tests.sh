#!/bin/bash
# Mock-based test suite for update-vms.sh.
#
# SAFETY: real pvesh/pct/qm/id are shadowed by tests/mocks/ via PATH.
# Every mock call is appended to $MOCK_CALLS; tests assert on that log to
# prove no real system command was reached. Never run this on production
# guests; it never calls real package managers.
#
# Usage: ./tests/run_tests.sh [name-substring]
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT="${SCRIPT:-$REPO_DIR/update-vms.sh}"
MOCKDIR="$TESTS_DIR/mocks"
FIXTURES="$TESTS_DIR/fixtures"

PASS=0; FAIL=0; FAILED_NAMES=""
WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT"' EXIT

# ---- per-test environment -----------------------------------------------
reset_env() {
    T_DIR="$WORKROOT/$1"
    mkdir -p "$T_DIR"
    T_CALLS="$T_DIR/calls.log"
    T_LOCK="$T_DIR/lock"
    : > "$T_CALLS"
    # defaults: pretend root, basic fixture, no injected failures
    export PVE_NODE=testnode
    export LOCK_FILE="$T_LOCK"
    export TARGET_LOCK_DIR="$T_DIR"
    export MOCK_CALLS="$T_CALLS"
    export MOCK_FIXTURES="$FIXTURES"
    export MOCK_ID_UID=0
    export MOCK_PVESH_FAIL=0 MOCK_PVESH_GARBAGE=0
    export MOCK_PCT_FAIL_VMS="" MOCK_PCT_HANG=0
    export MOCK_QM_AGENT_DOWN_VMS="" MOCK_QM_RC=0
    export MOCK_GUEST_DF_FAIL_VMS="" MOCK_BACKUP_FAIL=0
    export MOCK_APT_UPDATE_FAIL=0 MOCK_APT_DIST_FAIL=0 MOCK_PVECM_MODE=standalone
    unset MOCK_PVECM_FIXTURE
    unset MOCK_PCT_SCAN_MODE MOCK_PCT_YUM_SCAN MOCK_QM_SCAN_MODE MOCK_APT_SCAN_MODE
    unset PCT_EXEC_TIMEOUT QEMU_EXEC_TIMEOUT MOCK_PVESH_FIXTURE
    unset MOCK_GUEST_DF MOCK_BACKUP_FIXTURE MIN_GUEST_FREE_MB
    unset DISK_CHECK AGENT_CHECK BACKUP_CHECK
    unset REPORT_PATH LOG_FILE_PATH
    unset HOST_UPDATE_TIMEOUT MIN_HOST_FREE_MB HOST_REBOOT_MARKER
    OUT=""; RC=0
}

run_script() {
    OUT=$(PATH="$MOCKDIR:$PATH" bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

# stdout-only capture for machine-readable modes (JSON on stdout, logs on stderr)
run_script_stdout() {
    OUT=$(PATH="$MOCKDIR:$PATH" bash "$SCRIPT" "$@" 2>/dev/null)
    RC=$?
}

# ---- assertions ----------------------------------------------------------
fail() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $T_NAME"; echo "  FAIL: $*"; }

assert_rc() {
    [ "$RC" -eq "$1" ] || fail "expected rc=$1 got rc=$RC (output: $(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-200))"
}
assert_log() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" || fail "log missing: '$1'"
}
assert_log_not() {
    printf '%s\n' "$OUT" | grep -qF -- "$1" && fail "log must not contain: '$1'"
    return 0
}
assert_calls() {
    grep -qF -- "$1" "$T_CALLS" || fail "calls missing: '$1'"
}
assert_calls_not() {
    grep -qF -- "$1" "$T_CALLS" && fail "calls must not contain: '$1' (REAL COMMAND REACHED?)"
    return 0
}

t() {
    local name="$1"; shift
    T_NAME="$name"
    reset_env "$name"
    _FAIL_MARK=$FAIL
    echo "== $name"
    "$@"
    if printf '%s\n' "$OUT" | grep -qE 'password|passwd|token=|secret' ; then
        fail "possible secret in output"
    fi
    if [ "$FAIL" -eq "$_FAIL_MARK" ]; then
        PASS=$((PASS+1)); echo "  ok"
    fi
}

# ---- tests (expectations = hardened spec; see docs/CURRENT_STATE.md) -----

# 1. Dry-run: preview only, zero mutating calls.
test_dry_run_no_side_effects() {
    run_script --dry-run
    assert_rc 0
    assert_log "DRY-RUN"
    assert_calls_not "pct exec"
    assert_calls_not "qm guest exec"
}

# 2. Full successful run: 107+111 (apt lxc) and 102 (yum qemu) updated.
test_all_success() {
    run_script
    assert_rc 0
    assert_log "3 updated, 0 failed"
    assert_calls "pct exec 107"
    assert_calls "qm guest exec 102"
    assert_log_not ", dry-run"   # dry-run marker must not appear on real runs
}

# 3. One guest fails, others succeed: both visible, exit non-zero.
test_one_guest_fails() {
    MOCK_PCT_FAIL_VMS=111 run_script
    assert_rc 1
    assert_log "2 updated, 1 failed"
    assert_log "failed (rc=100)"
}

# 4. SEC-003: apt upgrade must be chained after apt-get update with &&.
test_apt_update_chained() {
    run_script
    local line
    line=$(grep -F "pct exec 107" "$T_CALLS" | grep -F "apt-get" | head -1)
    [ -n "$line" ] || fail "no apt-get call for 107"
    printf '%s' "$line" | grep -qF "apt-get update" || fail "no apt-get update in call"
    printf '%s' "$line" | grep -qE 'apt-get update.*&&.*upgrade' || fail "update not &&-chained to upgrade"
}

# 5. pvesh failure must be a hard error, never a silent 0-guest success.
test_pvesh_failure_hard_error() {
    MOCK_PVESH_FAIL=1 run_script
    assert_rc 2
    assert_log "pvesh"
}

# 6. pvesh returning non-JSON must be a hard error.
test_pvesh_garbage_hard_error() {
    MOCK_PVESH_GARBAGE=1 run_script
    assert_rc 2
}

# 7. Non-root real run must abort before touching anything.
test_non_root_aborts() {
    unset MOCK_ID_UID
    run_script
    assert_rc 2
    assert_log "root"
    assert_calls_not "pct exec"
    assert_calls_not "qm guest exec"
}

# 8. Non-root dry-run is allowed (safe, read-only).
test_non_root_dry_run_ok() {
    unset MOCK_ID_UID
    run_script --dry-run
    assert_rc 0
}

# 9. Concurrent instance is rejected by the lock.
test_lock_contention() {
    exec 8>"$T_LOCK"
    flock -n 8
    run_script
    exec 8>&-
    assert_rc 3
    assert_log "already in progress"
}

# 10. Stopped guests are skipped without any exec call.
test_stopped_guest_skipped() {
    run_script
    assert_log "Skipping 114"
    assert_calls_not "pct exec 114"
}

# 11. Missing guest agent: preflight skips the guest; never success.
test_agent_down_not_success() {
    MOCK_QM_AGENT_DOWN_VMS=102 run_script
    assert_rc 0
    assert_log "no guest agent"
    assert_calls_not "qm guest exec 102"
    assert_log "2 updated, 0 failed"
}

# 12. pct exec must respect PCT_EXEC_TIMEOUT (disk preflight off here).
test_pct_timeout() {
    DISK_CHECK=0 PCT_EXEC_TIMEOUT=1 MOCK_PCT_HANG=1 run_script
    assert_rc 1
    assert_log "timed out"
}

# 13. Exact tag matching: 'compat' must NOT trigger apt/yum on 999.
test_exact_tag_match() {
    run_script
    assert_calls_not "999"
    assert_log "Skipping 999"
}

# 14. Malformed vmid entry is skipped with a warning.
test_malformed_vmid() {
    run_script
    assert_log "malformed entry"
}

# 15. Non-numeric timeout env must be rejected.
test_invalid_timeout_env() {
    QEMU_EXEC_TIMEOUT=abc run_script
    assert_rc 2
    assert_log "QEMU_EXEC_TIMEOUT"
}

# 16. Unknown CLI arguments must be rejected, not silently ignored.
test_unknown_arg_rejected() {
    run_script --frobnicate
    assert_rc 2
    assert_log "usage"
}

# 17. Guests on other nodes are never touched.
test_other_node_untouched() {
    run_script
    assert_calls_not "207"
}

# 18. Unopenable lock file is a preflight error, not a crash.
test_lock_file_unopenable() {
    LOCK_FILE="$T_DIR/no-such-dir/lock" run_script
    assert_rc 2
    assert_log "cannot open lock file"
}

# 19. Wrong PVE_NODE: warn loudly instead of silently "succeeding" on 0 guests.
test_wrong_node_warns() {
    PVE_NODE=nonexistent-node run_script
    assert_rc 0
    assert_log "no guests found on node nonexistent-node"
    assert_calls_not "pct exec"
}

# 20. --version prints the version and exits 0.
test_version() {
    run_script --version
    assert_rc 0
    assert_log "update-vms 3."
}

# 21. --list shows guests incl. stopped ones, works as non-root, no exec calls.
test_list_mode() {
    unset MOCK_ID_UID
    run_script --list
    assert_rc 0
    assert_log "107"
    assert_log "[apt]"
    assert_log "[stopped]"
    assert_log "[windows]"
    assert_calls_not "pct exec"
    assert_calls_not "qm guest exec"
}

# 22. --check reports inventory summary and preflight ok, no exec calls.
test_check_mode() {
    run_script --check
    assert_rc 0
    assert_log "preflight ok"
    assert_log "inventory: apt = 2"
    assert_calls_not "pct exec"
}

# 23. --check as non-root must FAIL (it verifies the root prerequisite).
test_check_requires_root() {
    unset MOCK_ID_UID
    run_script --check
    assert_rc 2
    assert_log "root is required"
}

# 24. --only restricts updates to the named VMIDs.
test_only_filter() {
    run_script --only 107
    assert_rc 0
    assert_calls "pct exec 107"
    assert_calls_not "pct exec 111"
    assert_calls_not "qm guest exec 102"
    assert_log "not in --only list"
    assert_log "1 updated, 0 failed"
}

# 25. --exclude removes named VMIDs from the run.
test_exclude_filter() {
    run_script --exclude 107
    assert_rc 0
    assert_calls_not "pct exec 107"
    assert_calls "pct exec 111"
}

# 26. Injection attempts in --only must be rejected (SEC-007).
test_only_invalid_ids_rejected() {
    run_script --only "107; rm -rf /"
    assert_rc 2
    assert_log "invalid VMID"
    assert_calls_not "pct exec"
}

# 27. --only with a VMID that does not exist warns about a typo.
test_only_unknown_vmid_warns() {
    run_script --only 99999
    assert_rc 0
    assert_log "VMID 99999 not found on node"
    assert_calls_not "pct exec"
}

# 28. --only combines with --dry-run: preview only the selected guest.
test_only_with_dry_run() {
    run_script --dry-run --only 107
    assert_rc 0
    assert_log "DRY-RUN: lxc 107"
    OUT_HAS_111=$(printf '%s\n' "$OUT" | grep -c "DRY-RUN: lxc 111")
    [ "$OUT_HAS_111" -eq 0 ] || fail "dry-run must respect --only (111 previewed)"
    assert_calls_not "pct exec"
}

# 29. --list reflects --exclude classification.
test_list_reflects_exclude() {
    run_script --list --exclude 107
    assert_rc 0
    printf '%s\n' "$OUT" | grep -qF "107" || fail "107 row missing"
    printf '%s\n' "$OUT" | grep "107" | grep -qF "[excluded]" || fail "107 not marked excluded"
}

# 30. --check with failing pvesh is a hard error.
test_check_pvesh_failure() {
    MOCK_PVESH_FAIL=1 run_script --check
    assert_rc 2
}

# 31. --only without a value is a usage error.
test_only_missing_value() {
    run_script --only
    assert_rc 2
    assert_log "requires a value"
}

# 32. Low free disk in guest -> guest skipped, never updated (SEC-009).
test_disk_low_skips_guest() {
    MOCK_GUEST_DF=1000 run_script
    assert_rc 0
    assert_log "insufficient disk space"
    printf '%s\n' "$OUT" | grep -q "apt-get" && fail "upgrade must not run on low-disk guest"
    grep -E "pct exec .*apt-get" "$T_CALLS" && fail "apt call reached low-disk guest"
    assert_log "0 updated, 0 failed"
}

# 33. Failing/unparseable disk check -> skip (unknown prerequisites).
test_disk_check_failure_skips() {
    MOCK_GUEST_DF_FAIL_VMS=107 run_script
    assert_rc 0
    assert_log "disk space check failed"
    printf '%s' "$(grep -c "pct exec 107.*apt-get" "$T_CALLS")" | grep -qx 0 || fail "107 must not be updated"
    assert_calls "pct exec 111"
}

# 34. Disk preflight can be disabled explicitly.
test_disk_check_disabled() {
    DISK_CHECK=0 MOCK_GUEST_DF=1000 run_script
    assert_rc 0
    assert_log "3 updated, 0 failed"
}

# 35. Guest not covered by an enabled backup job -> warn but proceed (FR-010).
test_backup_not_covered_warns() {
    MOCK_BACKUP_FIXTURE="$FIXTURES/jobs_partial.json" run_script --dry-run
    assert_rc 0
    assert_log "102 (qemu): not covered by any enabled backup job"
    assert_log_not "107 (lxc): not covered"
}

# 36. Unreadable backup job list -> "backup status unknown" warning (FR-010).
test_backup_unknown_warns() {
    MOCK_BACKUP_FAIL=1 run_script --dry-run
    assert_rc 0
    assert_log "backup status unknown"
}

# 37. --check reports agent and backup gaps for update candidates.
test_check_reports_agent_and_backup_gaps() {
    MOCK_QM_AGENT_DOWN_VMS=102 MOCK_BACKUP_FIXTURE="$FIXTURES/jobs_partial.json" run_script --check
    assert_rc 0
    assert_log "update candidates without guest agent: 1"
    assert_log "update candidates not covered by an enabled backup job: 1"
}

# 38. Invalid MIN_GUEST_FREE_MB rejected.
test_min_free_invalid() {
    MIN_GUEST_FREE_MB=abc run_script
    assert_rc 2
    assert_log "MIN_GUEST_FREE_MB"
}

# 39. Invalid check-flag env (DISK_CHECK=2) rejected.
test_check_flag_invalid() {
    DISK_CHECK=2 run_script
    assert_rc 2
    assert_log "DISK_CHECK must be 0 or 1"
}

# 40. Agent preflight can be disabled explicitly (then exec path fails, rc 1).
test_agent_check_disabled_fails_via_exec() {
    AGENT_CHECK=0 MOCK_QM_AGENT_DOWN_VMS=102 run_script
    assert_rc 1
    assert_log "1 failed"
}

# 41. --report writes valid JSON with all node guests and correct summary.
test_report_json_valid() {
    run_script --report "$T_DIR/report.json"
    assert_rc 0
    jq -e . "$T_DIR/report.json" >/dev/null || fail "report not valid JSON"
    local n s
    n=$(jq '.guests | length' "$T_DIR/report.json")
    [ "$n" -eq 8 ] || fail "expected 8 guests in report, got $n"
    s=$(jq -r '.summary.success' "$T_DIR/report.json")
    [ "$s" -eq 3 ] || fail "summary.success=$s expected 3"
    [ "$(jq -r '.mode' "$T_DIR/report.json")" = "update" ] || fail "mode wrong"
    grep -qiE 'password|token=|secret' "$T_DIR/report.json" && fail "secret-like content in report"
}

# 42. Report marks the failing guest failed and counts it.
test_report_reflects_failure() {
    MOCK_PCT_FAIL_VMS=111 run_script --report "$T_DIR/r.json"
    assert_rc 1
    [ "$(jq -r '.summary.failed' "$T_DIR/r.json")" -eq 1 ] || fail "summary.failed != 1"
    [ "$(jq -r '.guests[] | select(.vmid==111) | .status' "$T_DIR/r.json")" = "failed" ] || fail "111 not failed"
}

# 43. Backup warning -> guest status "warning", visible in summary and line.
test_warning_status() {
    MOCK_BACKUP_FIXTURE="$FIXTURES/jobs_partial.json" run_script --report "$T_DIR/r.json"
    assert_rc 0
    [ "$(jq -r '.summary.warning' "$T_DIR/r.json")" -eq 1 ] || fail "summary.warning != 1"
    [ "$(jq -r '.guests[] | select(.vmid==102) | .status' "$T_DIR/r.json")" = "warning" ] || fail "102 not warning"
    assert_log "1 with warnings"
}

# 44. --log-file receives the timestamped log.
test_log_file_written() {
    run_script --log-file "$T_DIR/run.log"
    assert_rc 0
    [ -s "$T_DIR/run.log" ] || fail "log file empty"
    grep -q "done:" "$T_DIR/run.log" || fail "log file missing summary line"
}

# 45. Unwritable log/report paths fail in preflight (before any work).
test_log_file_unwritable() {
    run_script --log-file "$T_DIR/nodir/run.log"
    assert_rc 2
    assert_log "cannot write log file"
    assert_calls_not "pct exec"
}
test_report_path_unwritable() {
    run_script --report "$T_DIR/nodir/r.json"
    assert_rc 2
    assert_log "report path not writable"
    assert_calls_not "pct exec"
}

# 46. dry-run report: mode dry-run, candidates planned, no exec calls.
test_dry_run_report() {
    run_script --dry-run --report "$T_DIR/r.json"
    assert_rc 0
    [ "$(jq -r '.mode' "$T_DIR/r.json")" = "dry-run" ] || fail "mode not dry-run"
    [ "$(jq '[.guests[] | select(.status=="planned")] | length' "$T_DIR/r.json")" -eq 3 ] || fail "planned != 3"
    assert_calls_not "pct exec"
    assert_calls_not "qm guest exec"
}

# 47. check-mode report: mode check, all guests planned.
test_check_report() {
    run_script --check --report "$T_DIR/r.json"
    assert_rc 0
    [ "$(jq -r '.mode' "$T_DIR/r.json")" = "check" ] || fail "mode not check"
    [ "$(jq '.guests | length' "$T_DIR/r.json")" -eq 8 ] || fail "guests != 8"
    [ "$(jq '[.guests[] | select(.status=="planned")] | length' "$T_DIR/r.json")" -eq 8 ] || fail "not all planned"
}

# 48. --host --dry-run: simulation only, no mutating apt calls (SEC-011).
test_host_dry_run_simulation_only() {
    run_script --host --dry-run
    assert_rc 0
    assert_log "HOST DRY-RUN"
    assert_calls "apt-get -s dist-upgrade"
    assert_calls_not "apt-get update"
    assert_calls_not "apt-get -y"
}

# 49. Real --host without --yes on a non-tty must refuse (SEC-001).
test_host_refuses_unattended() {
    run_script --host
    assert_rc 2
    assert_log "not a terminal"
    assert_calls_not "apt-get update"
}

# 50. --host --yes (explicit policy) runs update then dist-upgrade.
test_host_yes_runs() {
    run_script --host --yes
    assert_rc 0
    assert_calls "apt-get update"
    assert_calls "dist-upgrade"
    assert_log "updated successfully"
}

# 51. Failed apt-get update must abort before dist-upgrade (SEC-003).
test_host_update_failure_blocks_upgrade() {
    MOCK_APT_UPDATE_FAIL=1 run_script --host --yes
    assert_rc 1
    assert_log "NOT attempted"
    assert_calls_not "apt-get -y"
}

# 52. dist-upgrade failure is reported as failed.
test_host_dist_failure() {
    MOCK_APT_DIST_FAIL=1 run_script --host --yes
    assert_rc 1
    assert_log "dist-upgrade failed"
}

# 53. Lost cluster quorum refuses the host update (SEC-013).
test_host_no_quorum_refuses() {
    MOCK_PVECM_MODE=noquorum run_script --host --yes
    assert_rc 2
    assert_log "quorum LOST"
    assert_calls_not "apt-get update"
}

# 54. Quorate cluster passes the quorum gate.
test_host_quorate_ok() {
    MOCK_PVECM_MODE=quorate run_script --host --yes
    assert_rc 0
    assert_log "quorum ok"
}

# 54b. Real pvecm status output format must parse (regression: field is
# 'Quorate: Yes', not 'Quorum: Yes').
test_host_quorum_real_output() {
    MOCK_PVECM_FIXTURE="$FIXTURES/pvecm_real.txt" run_script --host --yes
    assert_rc 0
    assert_log "quorum ok"
    assert_calls "apt-get update"
}

# 55. Low host disk space refuses the update.
test_host_low_disk_refuses() {
    MIN_HOST_FREE_MB=999999999 run_script --host --yes
    assert_rc 2
    assert_log "below MIN_HOST_FREE_MB"
    assert_calls_not "apt-get update"
}

# 56. --host cannot be mixed with guest filters/modes.
test_host_conflict_flags() {
    run_script --host --only 107
    assert_rc 2
    assert_log "cannot be combined"
}

# 57. Host run appears in the report with status success.
test_host_report() {
    run_script --host --yes --report "$T_DIR/r.json"
    assert_rc 0
    [ "$(jq -r '.mode' "$T_DIR/r.json")" = "host" ] || fail "mode not host"
    [ "$(jq -r '.guests[0].vmid' "$T_DIR/r.json")" = "host" ] || fail "host entry missing"
    [ "$(jq -r '.guests[0].status' "$T_DIR/r.json")" = "success" ] || fail "host not success"
}

# 58. reboot-required marker -> warning, never an automatic reboot (FR-009).
test_host_reboot_required_warning() {
    touch "$T_DIR/reboot-required"
    HOST_REBOOT_MARKER="$T_DIR/reboot-required" run_script --host --yes --report "$T_DIR/r.json"
    assert_rc 0
    assert_log "reboot required"
    assert_log "NOT rebooting"
    [ "$(jq -r '.guests[0].status' "$T_DIR/r.json")" = "warning" ] || fail "host not warning"
    [ "$(jq -r '.summary.warning' "$T_DIR/r.json")" -eq 1 ] || fail "summary.warning != 1"
}

# 59. Real --host as non-root aborts before anything (SEC-008).
test_host_requires_root() {
    unset MOCK_ID_UID
    run_script --host --yes
    assert_rc 2
    assert_log "root is required"
    assert_calls_not "apt-get update"
}

# 61. --help prints usage and exits 0 (v2 silently ignored unknown flags;
# --help must be an explicit, tested path).
test_help_flag() {
    run_script --help
    assert_rc 0
    assert_log "usage:"
    assert_log "this help"
    assert_calls_not "pvesh"
}

# 60. systemd unit files parse cleanly (ExecStart rewritten to the real
# script path so verify can stat it). Skipped when systemd-analyze is absent.
test_systemd_units_valid() {
    command -v systemd-analyze >/dev/null 2>&1 || { echo "  (skipped: no systemd-analyze)"; return 0; }
    sed "s|/usr/local/bin/update-vms.sh|$SCRIPT|" \
        "$REPO_DIR/contrib/systemd/update-vms.service" > "$T_DIR/update-vms.service" || fail "sed failed"
    cp "$REPO_DIR/contrib/systemd/update-vms.timer" "$T_DIR/update-vms.timer"
    local out
    out=$(cd "$T_DIR" && systemd-analyze verify update-vms.service update-vms.timer 2>&1)
    [ -z "$out" ] || fail "systemd-analyze verify: $out"
}

# ---- v3.5 scan / backup-status / per-target lock tests --------------------

# 63. Host scan: simulation only, package preview in report, no installs.
test_host_scan_packages() {
    run_script --host --scan --report "$T_DIR/r.json"
    assert_rc 0
    assert_log "host scan: 2 package update(s) available"
    assert_calls "apt-get -s dist-upgrade"
    assert_calls_not "apt-get -y"
    [ "$(jq -r '.mode' "$T_DIR/r.json")" = "host-scan" ] || fail "mode not host-scan"
    [ "$(jq -r '.guests[0].status' "$T_DIR/r.json")" = "success" ] || fail "host not success"
    [ "$(jq '.guests[0].packages | length' "$T_DIR/r.json")" -eq 2 ] || fail "packages != 2"
}

# 64. Host scan: failed apt-get update -> failed, exit 1, no simulation.
test_host_scan_update_fail() {
    MOCK_APT_UPDATE_FAIL=1 run_script --host --scan
    assert_rc 1
    assert_log "apt-get update failed"
    assert_calls_not "apt-get -s dist-upgrade"
}

# 65. Host scan: up-to-date host.
test_host_scan_current() {
    MOCK_APT_SCAN_MODE=current run_script --host --scan
    assert_rc 0
    assert_log "host scan: up to date"
}

# 66. Guest scan (apt): read-only, package preview, zero mutating calls.
test_guest_scan_apt_packages() {
    run_script --scan --report "$T_DIR/r.json"
    assert_rc 0
    assert_calls "pct exec 107"
    assert_calls_not "apt-get -y"
    assert_calls_not "dist-upgrade"
    [ "$(jq -r '.mode' "$T_DIR/r.json")" = "scan" ] || fail "mode not scan"
    [ "$(jq -r '.guests[] | select(.vmid==107) | .status' "$T_DIR/r.json")" = "success" ] || fail "107 not success"
    [ "$(jq '.guests[] | select(.vmid==107) | .packages | length' "$T_DIR/r.json")" -eq 2 ] || fail "107 packages != 2"
}

# 67. Guest scan: up-to-date guest.
test_guest_scan_current() {
    MOCK_PCT_SCAN_MODE=current run_script --scan
    assert_rc 0
    assert_log "up to date"
}

# 68. Guest scan (yum): rc 100 means updates available, parsed.
test_guest_scan_yum_available() {
    run_script --scan --report "$T_DIR/r.json"
    assert_rc 0
    assert_log "2 update(s) available"
    [ "$(jq -r '.guests[] | select(.vmid==102) | .status' "$T_DIR/r.json")" = "success" ] || fail "102 not success"
}

# 69. Guest scan (yum): command failure -> failed, exit 1, never success.
test_guest_scan_yum_fail() {
    MOCK_QM_SCAN_MODE=fail run_script --scan
    assert_rc 1
    assert_log "scan failed (rc=1)"
}

# 70. Guest scan: QEMU without agent -> skipped, never scanned.
test_scan_no_agent_skip() {
    MOCK_QM_AGENT_DOWN_VMS=102 run_script --scan
    assert_rc 0
    assert_log "Skipping 102 (qemu) - no guest agent"
    assert_calls_not "qm guest exec 102"
}

# 71. Scan respects per-target lock held by another process (FR-014).
test_scan_target_locked() {
    flock "$T_DIR/update-vms-lxc-107.lock" -c 'sleep 5' &
    local holder=$!
    sleep 0.5
    run_script --scan --only 107
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_rc 0
    assert_log "target locked by another run"
    assert_calls_not "pct exec 107"
}

# 72. Update run skips a target whose lock is held; others proceed.
test_update_target_locked() {
    flock "$T_DIR/update-vms-lxc-107.lock" -c 'sleep 5' &
    local holder=$!
    sleep 0.5
    run_script
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    assert_rc 0
    assert_log "Skipping 107 (lxc) - target locked by another run"
    assert_calls_not "pct exec 107 -- bash -c export DEBIAN_FRONTEND"
    assert_calls "pct exec 111"
}

# 73. --backup-status: machine-readable JSON, coverage flags.
test_backup_status_json() {
    MOCK_BACKUP_FIXTURE="$FIXTURES/jobs_partial.json" run_script_stdout --backup-status
    assert_rc 0
    printf '%s' "$OUT" | jq -e . >/dev/null || fail "output not JSON"
    [ "$(printf '%s' "$OUT" | jq -r '.backup_status')" = "ok" ] || fail "backup_status not ok"
    [ "$(printf '%s' "$OUT" | jq '.candidates | length')" -eq 3 ] || fail "candidates != 3"
    [ "$(printf '%s' "$OUT" | jq -r '.candidates[] | select(.vmid==107) | .backup_covered')" = "true" ] || fail "107 should be covered"
    [ "$(printf '%s' "$OUT" | jq -r '.candidates[] | select(.vmid==102) | .backup_covered')" = "false" ] || fail "102 should NOT be covered"
}

# 74. --backup-status: unreadable job list -> unknown, never healthy.
test_backup_status_unknown() {
    MOCK_BACKUP_FAIL=1 run_script_stdout --backup-status
    assert_rc 0
    [ "$(printf '%s' "$OUT" | jq -r '.backup_status')" = "unknown" ] || fail "backup_status not unknown"
    [ "$(printf '%s' "$OUT" | jq -r '.candidates[0].backup_covered')" = "false" ] || fail "unknown must not report covered"
}

# 75. Scan requires root (execs into guests).
test_scan_nonroot_refused() {
    unset MOCK_ID_UID
    run_script --scan
    assert_rc 2
    assert_log "root"
    assert_calls_not "pct exec"
}

# 76. Mode conflicts rejected: --scan with --list; --backup-status standalone.
test_scan_mode_conflicts() {
    run_script --scan --list
    assert_rc 2
    run_script --backup-status --host
    assert_rc 2
}

# 77. Existing update reports stay valid JSON with the new packages field.
test_report_packages_field_backward_compat() {
    run_script --report "$T_DIR/r.json"
    assert_rc 0
    jq -e '.guests | all(has("packages"))' "$T_DIR/r.json" >/dev/null || fail "packages field missing"
    [ "$(jq '.guests[] | select(.vmid==107) | .packages | length' "$T_DIR/r.json")" -eq 0 ] || fail "update run must not carry packages"
}

# ---- run -----------------------------------------------------------------
for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    t "${fn#test_}" "$fn"
done

echo
echo "=== $PASS passed, $FAIL failed ==="
[ -n "$FAILED_NAMES" ] && echo "failed:$FAILED_NAMES"
[ "$FAIL" -eq 0 ]
