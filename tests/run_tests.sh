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
    unset PCT_EXEC_TIMEOUT QEMU_EXEC_TIMEOUT MOCK_PVESH_FIXTURE
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
    line=$(grep -F "pct exec 107" "$T_CALLS" | head -1)
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

# 11. Missing guest agent: guest must be failed, never success.
test_agent_down_not_success() {
    MOCK_QM_AGENT_DOWN_VMS=102 run_script
    assert_rc 1
    assert_log "1 failed"
    assert_log_not "3 updated"
}

# 12. pct exec must respect PCT_EXEC_TIMEOUT.
test_pct_timeout() {
    PCT_EXEC_TIMEOUT=1 MOCK_PCT_HANG=1 run_script
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

# ---- run -----------------------------------------------------------------
for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    t "${fn#test_}" "$fn"
done

echo
echo "=== $PASS passed, $FAIL failed ==="
[ -n "$FAILED_NAMES" ] && echo "failed:$FAILED_NAMES"
[ "$FAIL" -eq 0 ]
