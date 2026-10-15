#!/bin/bash
#
# Proxmox VE guest auto-update (v3)
#
# Updates running LXC containers and QEMU VMs on the local node based on
# Proxmox tags (tags are ';' separated in PVE, matched EXACTLY):
#   apt     -> apt-get update + upgrade (noninteractive, keeps old conffiles)
#   yum     -> dnf -y update if present, else yum -y update
#   windows -> skipped
#
# v3 hardening over v2 (see docs/CURRENT_STATE.md and tests/):
#   - preflight: root check (dry-run exempt), required binaries, numeric
#     timeout validation - all before any guest is touched
#   - pvesh failure or non-JSON output is a HARD ERROR (exit 2); v2 silently
#     reported "0 updated" success when pvesh failed or jq output was broken
#   - pct exec now runs under `timeout` (PCT_EXEC_TIMEOUT, default 1800);
#     v2 only bounded qm guest exec
#   - LOCK_FILE overridable via env (default unchanged: /var/lock/update-vms.lock)
#   - unknown CLI arguments are rejected (usage, exit 2) instead of ignored
#   - fixed: ", dry-run" marker was printed on every run, not only dry runs
#   - explicit exit codes: 0 ok | 1 guest failure(s) | 2 preflight/usage | 3 lock busy
#
# v2 fixes over v1 (preserved):
#   - line-based iteration (v1 word-split the JSON; broke on descriptions with spaces)
#   - qm guest exec --timeout (v1 used the 30s default and killed updates mid-run)
#   - exact tag matching on ';' (v1 substring match: tag 'compat' matched 'apt')
#   - jq --arg for the node name (no broken filter if hostname has special chars)
#   - flock single-instance guard (safe for cron overlap)
#   - numeric VMID validation before exec
#   - DEBIAN_FRONTEND=noninteractive + dpkg confdef/confold (no unattended prompts)
#   - dnf auto-detect for yum-tagged guests
#   - per-guest exit codes, summary, non-zero exit if anything failed
#   - --dry-run flag
#
# Usage: ./update-vms.sh [--dry-run]
# Env:   PVE_NODE=<name>          override node (default: hostname)
#        QEMU_EXEC_TIMEOUT=<sec>  qm guest exec timeout (default: 1800)
#        PCT_EXEC_TIMEOUT=<sec>   pct exec wrapper timeout (default: 1800)
#        LOCK_FILE=<path>         single-instance lock path
#
set -u -o pipefail

EXIT_OK=0
EXIT_GUEST_FAILURE=1
EXIT_PREFLIGHT=2
EXIT_LOCK=3

LOCK_FILE="${LOCK_FILE:-/var/lock/update-vms.lock}"
NODE="${PVE_NODE:-$(hostname)}"
QEMU_EXEC_TIMEOUT="${QEMU_EXEC_TIMEOUT:-1800}"
PCT_EXEC_TIMEOUT="${PCT_EXEC_TIMEOUT:-1800}"
DRY_RUN=0

log() { echo "[$(date '+%F %T')] $*"; }

usage() {
    echo "usage: $(basename "$0") [--dry-run]" >&2
    echo "  --dry-run   preview actions without changing anything" >&2
}

# ---- argument parsing (unknown args are rejected, SEC-007) ---------------
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit "$EXIT_OK" ;;
        *) echo "error: unknown argument: $arg" >&2; usage; exit "$EXIT_PREFLIGHT" ;;
    esac
done

# ---- preflight (SEC-005/007/008): validate before touching anything ------
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

if ! is_uint "$QEMU_EXEC_TIMEOUT"; then
    log "preflight: QEMU_EXEC_TIMEOUT must be a non-negative integer (got: $QEMU_EXEC_TIMEOUT)"
    exit "$EXIT_PREFLIGHT"
fi
if ! is_uint "$PCT_EXEC_TIMEOUT"; then
    log "preflight: PCT_EXEC_TIMEOUT must be a non-negative integer (got: $PCT_EXEC_TIMEOUT)"
    exit "$EXIT_PREFLIGHT"
fi

for bin in jq pvesh pct qm flock timeout; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "preflight: required command not found: $bin"
        exit "$EXIT_PREFLIGHT"
    fi
done

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ]; then
    log "preflight: root is required for real runs (use --dry-run as non-root)"
    exit "$EXIT_PREFLIGHT"
fi

if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
    log "preflight: cannot open lock file: $LOCK_FILE"
    exit "$EXIT_PREFLIGHT"
fi
if ! flock -n 9; then
    log "Another update-vms run is already in progress - exiting."
    exit "$EXIT_LOCK"
fi

# Exact match of a tag in a ';'-separated PVE tag list (case-insensitive).
has_tag() {
    local tags="$1" want="$2" t
    local IFS=';'
    read -ra arr <<< "$tags"
    for t in "${arr[@]}"; do
        t="${t//[[:space:]]/}"
        [ "${t,,}" = "$want" ] && return 0
    done
    return 1
}

OK=0; FAIL=0; SKIP=0

run_guest_cmd() {
    # run_guest_cmd <type> <vmid> <shell-command>
    local type="$1" vmid="$2" cmd="$3" out rc
    if [ "$DRY_RUN" -eq 1 ]; then
        log "   DRY-RUN: $type $vmid: $cmd"
        return 0
    fi
    if [ "$type" = "lxc" ]; then
        # NOTE: the timeout bounds the pct client; a killed client does not
        # necessarily stop the command already running inside the container.
        out=$(timeout "$PCT_EXEC_TIMEOUT" pct exec "$vmid" -- bash -c "$cmd" 2>&1)
        rc=$?
        if [ "$rc" -eq 124 ]; then
            log "   ✗ timed out after ${PCT_EXEC_TIMEOUT}s (pct exec $vmid)"
            return "$rc"
        fi
    else
        out=$(qm guest exec "$vmid" --timeout "$QEMU_EXEC_TIMEOUT" -- bash -c "$cmd" 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            # qm guest exec returns JSON; the guest command's code is in .exitcode
            rc=$(printf '%s' "$out" | jq -r '.exitcode // 0' 2>/dev/null || echo 1)
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        log "   ✗ failed (rc=$rc):"
        printf '%s\n' "$out" | tail -5 | sed 's/^/     | /'
    fi
    return "$rc"
}

APT_CMD='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade'
YUM_CMD='if command -v dnf >/dev/null 2>&1; then dnf -y update; else yum -y update; fi'

# ---- fetch guest inventory (SEC-010: never a silent empty success) -------
if ! resources=$(pvesh get /cluster/resources --type vm --output-format json 2>&1); then
    log "preflight: pvesh failed:"
    printf '%s\n' "$resources" | head -3 | sed 's/^/   | /'
    exit "$EXIT_PREFLIGHT"
fi
if ! printf '%s' "$resources" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "preflight: unexpected pvesh output (not a JSON array) - aborting"
    exit "$EXIT_PREFLIGHT"
fi
total_count=$(printf '%s' "$resources" | jq 'length')
node_guest_count=$(printf '%s' "$resources" | jq --arg node "$NODE" '[.[] | select(.node == $node)] | length')

MODE=""
[ "$DRY_RUN" -eq 1 ] && MODE=", dry-run"
log "=== update-vms start (node=$NODE$MODE) ==="

if [ "$node_guest_count" -eq 0 ]; then
    log "⚠ no guests found on node $NODE (fetched $total_count total) - check PVE_NODE"
fi

while IFS= read -r VM; do
    VMID=$(printf '%s' "$VM" | jq -r '.vmid')
    TYPE=$(printf '%s' "$VM" | jq -r '.type')
    STATUS=$(printf '%s' "$VM" | jq -r '.status')
    TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')

    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        log "⚠ Skipping malformed entry (vmid=$VMID)"
        SKIP=$((SKIP+1)); continue
    fi

    if [ "$STATUS" != "running" ]; then
        log "⚪ Skipping $VMID ($TYPE) - status $STATUS"
        SKIP=$((SKIP+1)); continue
    fi

    if has_tag "$TAGS" "windows"; then
        log "🟦 Skipping $VMID ($TYPE) - tag: windows"
        SKIP=$((SKIP+1)); continue
    fi

    # yum checked before apt (same precedence as v1/v2)
    if has_tag "$TAGS" "yum"; then
        log "▶ Updating $VMID ($TYPE) [yum/dnf]"
        if run_guest_cmd "$TYPE" "$VMID" "$YUM_CMD"; then
            OK=$((OK+1))
        else
            FAIL=$((FAIL+1))
        fi
    elif has_tag "$TAGS" "apt"; then
        log "▶ Updating $VMID ($TYPE) [apt]"
        if run_guest_cmd "$TYPE" "$VMID" "$APT_CMD"; then
            OK=$((OK+1))
        else
            FAIL=$((FAIL+1))
        fi
    else
        log "⚠ Skipping $VMID ($TYPE) - no apt/yum/windows tag (tags: ${TAGS:-none})"
        SKIP=$((SKIP+1))
    fi
done < <(printf '%s' "$resources" | jq -c --arg node "$NODE" '.[] | select(.node == $node)')

log "=== done: $OK updated, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
    exit "$EXIT_GUEST_FAILURE"
fi
exit "$EXIT_OK"
