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
    export MOCK_CALLS="$T_CALLS"
    export MOCK_FIXTURES="$FIXTURES"
    export MOCK_ID_UID=0
    export MOCK_PVESH_FAIL=0 MOCK_PVESH_GARBAGE=0
    export MOCK_PCT_FAIL_VMS="" MOCK_PCT_HANG=0
    export MOCK_QM_AGENT_DOWN_VMS="" MOCK_QM_RC=0
    export MOCK_GUEST_DF_FAIL_VMS="" MOCK_BACKUP_FAIL=0
    unset PCT_EXEC_TIMEOUT QEMU_EXEC_TIMEOUT MOCK_PVESH_FIXTURE
    unset MOCK_GUEST_DF MOCK_BACKUP_FIXTURE MIN_GUEST_FREE_MB
    unset DISK_CHECK AGENT_CHECK BACKUP_CHECK
    OUT=""; RC=0
}

run_script() {
    OUT=$(PATH="$MOCKDIR:$PATH" bash "$SCRIPT" "$@" 2>&1)
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

# ---- run -----------------------------------------------------------------
for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    t "${fn#test_}" "$fn"
done

echo
echo "=== $PASS passed, $FAIL failed ==="
[ -n "$FAILED_NAMES" ] && echo "failed:$FAILED_NAMES"
[ "$FAIL" -eq 0 ]
