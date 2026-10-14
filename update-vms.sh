#!/bin/bash
#
# Proxmox VE guest auto-update (v2)
#
# Updates running LXC containers and QEMU VMs on the local node based on
# Proxmox tags (tags are ';' separated in PVE, matched EXACTLY):
#   apt     -> apt-get update + upgrade (noninteractive, keeps old conffiles)
#   yum     -> dnf -y update if present, else yum -y update
#   windows -> skipped
#
# v2 fixes over v1:
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
#
set -u

LOCK_FILE="/var/lock/update-vms.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another update-vms run is already in progress - exiting." >&2
    exit 1
fi

NODE="${PVE_NODE:-$(hostname)}"
QEMU_EXEC_TIMEOUT="${QEMU_EXEC_TIMEOUT:-1800}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date '+%F %T')] $*"; }

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
        out=$(pct exec "$vmid" -- bash -c "$cmd" 2>&1)
        rc=$?
    else
        out=$(qm guest exec "$vmid" --timeout "$QEMU_EXEC_TIMEOUT" -- bash -c "$cmd" 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then
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

log "=== update-vms start (node=$NODE${DRY_RUN:+, dry-run}) ==="

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

    # yum checked before apt (same precedence as v1)
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
done < <(pvesh get /cluster/resources --type vm --output-format json \
         | jq -c --arg node "$NODE" '.[] | select(.node == $node)')

log "=== done: $OK updated, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
