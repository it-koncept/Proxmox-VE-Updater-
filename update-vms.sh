#!/bin/bash
#
# Proxmox VE guest auto-update (v3.1)
#
# Updates running LXC containers and QEMU VMs on the local node based on
# Proxmox tags (tags are ';' separated in PVE, matched EXACTLY):
#   apt     -> apt-get update + upgrade (noninteractive, keeps old conffiles)
#   yum     -> dnf -y update if present, else yum -y update
#   windows -> skipped
#
# v3.1 (B4) adds CLI surface (FR-008, SEC-007):
#   --version          print version and exit
#   --list             list node guests + planned action (read-only, non-root ok)
#   --check            preflight + inventory summary, no changes (root required)
#   --only <ids>       only these VMIDs (comma-separated, numeric)
#   --exclude <ids>    skip these VMIDs (comma-separated, numeric)
#   --only/--exclude combine with --dry-run/--list/--check.
#
# v3 hardening over v2 (see docs/CURRENT_STATE.md and tests/):
#   - preflight: root check (dry-run/list exempt), required binaries, numeric
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
# Usage: ./update-vms.sh [--dry-run] [--list] [--check] [--version]
#                        [--only <vmid,vmid>] [--exclude <vmid,vmid>]
# Env:   PVE_NODE=<name>          override node (default: hostname)
#        QEMU_EXEC_TIMEOUT=<sec>  qm guest exec timeout (default: 1800)
#        PCT_EXEC_TIMEOUT=<sec>   pct exec wrapper timeout (default: 1800)
#        LOCK_FILE=<path>         single-instance lock path
#
set -u -o pipefail

VERSION="3.1.0"
EXIT_OK=0
EXIT_GUEST_FAILURE=1
EXIT_PREFLIGHT=2
EXIT_LOCK=3

LOCK_FILE="${LOCK_FILE:-/var/lock/update-vms.lock}"
NODE="${PVE_NODE:-$(hostname)}"
QEMU_EXEC_TIMEOUT="${QEMU_EXEC_TIMEOUT:-1800}"
PCT_EXEC_TIMEOUT="${PCT_EXEC_TIMEOUT:-1800}"
DRY_RUN=0
LIST=0
CHECK=0
ONLY=""
EXCLUDE=""

log() { echo "[$(date '+%F %T')] $*"; }

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") [options]
  (no options)     update apt/yum-tagged running guests on this node
  --dry-run        preview actions without changing anything (non-root ok)
  --list           list guests on this node with planned action (non-root ok)
  --check          run preflight + inventory summary, no changes (root required)
  --version        print version and exit
  --only <ids>     only these VMIDs (comma-separated, numeric)
  --exclude <ids>  skip these VMIDs (comma-separated, numeric)
  -h, --help       this help
exit codes: 0 ok | 1 guest failure(s) | 2 preflight/usage | 3 lock busy
EOF
}

# ---- argument parsing (unknown args are rejected, SEC-007) ---------------
require_value() {
    # require_value <flag-name> <remaining-argc>
    if [ "$2" -lt 2 ]; then
        echo "error: $1 requires a value" >&2
        usage
        exit "$EXIT_PREFLIGHT"
    fi
}
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --list)    LIST=1 ;;
        --check)   CHECK=1 ;;
        --version) echo "update-vms $VERSION"; exit "$EXIT_OK" ;;
        --only)
            require_value --only $#; ONLY="$2"; shift ;;
        --only=*)    ONLY="${1#--only=}" ;;
        --exclude)
            require_value --exclude $#; EXCLUDE="$2"; shift ;;
        --exclude=*) EXCLUDE="${1#--exclude=}" ;;
        -h|--help) usage; exit "$EXIT_OK" ;;
        *) echo "error: unknown argument: $1" >&2; usage; exit "$EXIT_PREFLIGHT" ;;
    esac
    shift
done

# ---- preflight (SEC-005/007/008): validate before touching anything ------
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

in_list() { printf '%s' ",$1," | grep -q ",$2,"; }

# Validate a comma-separated VMID list (SEC-007); exits 2 on any bad entry.
# An empty list means "no filter" and is valid.
validate_id_list() {
    local list="$1" name="$2" item
    [ -z "$list" ] && return 0
    local IFS=','
    local -a items
    read -ra items <<< "$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        if ! is_uint "$item"; then
            log "preflight: $name: invalid VMID '$item' (numeric, comma-separated)"
            exit "$EXIT_PREFLIGHT"
        fi
    done
}
validate_id_list "$ONLY" --only
validate_id_list "$EXCLUDE" --exclude

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

# --list is read-only and allowed as non-root; --check must verify the real
# root prerequisite, so it is NOT exempt.
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ] && [ "$LIST" -ne 1 ]; then
    log "preflight: root is required for real runs (use --dry-run or --list as non-root)"
    exit "$EXIT_PREFLIGHT"
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

# Classify one guest -> planned action word (shared by list/check reporting).
guest_action() {
    local vmid="$1" status="$2" tags="$3"
    if ! is_uint "$vmid"; then echo "malformed"; return; fi
    if [ -n "$ONLY" ] && ! in_list "$ONLY" "$vmid"; then echo "not-targeted"; return; fi
    if [ -n "$EXCLUDE" ] && in_list "$EXCLUDE" "$vmid"; then echo "excluded"; return; fi
    if [ "$status" != "running" ]; then echo "stopped"; return; fi
    if has_tag "$tags" "windows"; then echo "windows"; return; fi
    if has_tag "$tags" "yum"; then echo "yum"; return; fi
    if has_tag "$tags" "apt"; then echo "apt"; return; fi
    echo "no-tag"
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

# ---- read-only modes: --list / --check (no lock, no changes) -------------
if [ "$LIST" -eq 1 ] || [ "$CHECK" -eq 1 ]; then
    [ "$CHECK" -eq 1 ] && MODE=", check" || MODE=", list"
    log "=== update-vms start (node=$NODE$MODE) ==="
    if [ "$node_guest_count" -eq 0 ]; then
        log "⚠ no guests found on node $NODE (fetched $total_count total) - check PVE_NODE"
    fi
    declare -A ACTION_COUNT=()
    while IFS= read -r VM; do
        VMID=$(printf '%s' "$VM" | jq -r '.vmid')
        TYPE=$(printf '%s' "$VM" | jq -r '.type')
        STATUS=$(printf '%s' "$VM" | jq -r '.status')
        TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')
        NAME=$(printf '%s' "$VM" | jq -r '.name // ""')
        ACTION=$(guest_action "$VMID" "$STATUS" "$TAGS")
        ACTION_COUNT[$ACTION]=$(( ${ACTION_COUNT[$ACTION]:-0} + 1 ))
        if [ "$LIST" -eq 1 ]; then
            printf '%-8s %-5s %-8s %-24s %s\n' "$VMID" "$TYPE" "$STATUS" "${TAGS:--}" "$NAME [$ACTION]"
        fi
    done < <(printf '%s' "$resources" | jq -c --arg node "$NODE" '.[] | select(.node == $node)')
    if [ "$CHECK" -eq 1 ]; then
        for action in "${!ACTION_COUNT[@]}"; do
            log "  inventory: $action = ${ACTION_COUNT[$action]}"
        done
        log "preflight ok: root, binaries, env, inventory"
    fi
    exit "$EXIT_OK"
fi

# ---- update / dry-run path: lock before touching anything ----------------
if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
    log "preflight: cannot open lock file: $LOCK_FILE"
    exit "$EXIT_PREFLIGHT"
fi
if ! flock -n 9; then
    log "Another update-vms run is already in progress - exiting."
    exit "$EXIT_LOCK"
fi

MODE=""
[ "$DRY_RUN" -eq 1 ] && MODE=", dry-run"
log "=== update-vms start (node=$NODE$MODE) ==="

if [ "$node_guest_count" -eq 0 ]; then
    log "⚠ no guests found on node $NODE (fetched $total_count total) - check PVE_NODE"
fi

ONLY_FOUND=","
while IFS= read -r VM; do
    VMID=$(printf '%s' "$VM" | jq -r '.vmid')
    TYPE=$(printf '%s' "$VM" | jq -r '.type')
    STATUS=$(printf '%s' "$VM" | jq -r '.status')
    TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')

    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        log "⚠ Skipping malformed entry (vmid=$VMID)"
        SKIP=$((SKIP+1)); continue
    fi

    if [ -n "$ONLY" ] && ! in_list "$ONLY" "$VMID"; then
        log "⏭ Skipping $VMID ($TYPE) - not in --only list"
        SKIP=$((SKIP+1)); continue
    fi
    if [ -n "$EXCLUDE" ] && in_list "$EXCLUDE" "$VMID"; then
        log "⏭ Skipping $VMID ($TYPE) - in --exclude list"
        SKIP=$((SKIP+1)); continue
    fi
    ONLY_FOUND="$ONLY_FOUND$VMID,"

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

# Warn about --only VMIDs that do not exist on this node (typo catcher).
if [ -n "$ONLY" ]; then
    IFS=',' read -ra only_items <<< "$ONLY"
    for want in "${only_items[@]}"; do
        want="${want//[[:space:]]/}"
        if ! in_list "$ONLY_FOUND" "$want"; then
            log "⚠ --only: VMID $want not found on node $NODE (typo?)"
        fi
    done
fi

log "=== done: $OK updated, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
    exit "$EXIT_GUEST_FAILURE"
fi
exit "$EXIT_OK"
