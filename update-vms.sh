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
# v3.3 (B6) adds reporting (FR-006, FR-013):
#   --report <path>    write a JSON report (per-guest status/reason/duration,
#                      summary, mode, timings) after the run
#   --log-file <path>  append timestamped log lines to a file
#   Per-guest status model: success | warning | skipped | failed (update runs),
#   planned (dry-run/list/check). Summary line gains "(N with warnings)".
#
# v3.2 (B5) adds safety preflight (FR-007/010, SEC-009):
#   - Guest Agent preflight for QEMU update candidates: no agent -> skipped
#     with an explicit reason, never reported as success.
#   - Guest disk-space preflight (df -P /): free space below
#     MIN_GUEST_FREE_MB (default 500 MB) or an unparseable/failed check
#     -> guest skipped with a warning. Skipped in --dry-run (no guest exec).
#   - Backup coverage (FR-010): enabled vzdump jobs from /cluster/backup;
#     guests not covered by any enabled job warn; unreadable job list
#     warns "backup status unknown". Advisory (warn), never blocks.
#   Env: MIN_GUEST_FREE_MB, DISK_CHECK, AGENT_CHECK, BACKUP_CHECK (see usage).
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

VERSION="3.3.0"
EXIT_OK=0
EXIT_GUEST_FAILURE=1
EXIT_PREFLIGHT=2
EXIT_LOCK=3

LOCK_FILE="${LOCK_FILE:-/var/lock/update-vms.lock}"
NODE="${PVE_NODE:-$(hostname)}"
QEMU_EXEC_TIMEOUT="${QEMU_EXEC_TIMEOUT:-1800}"
PCT_EXEC_TIMEOUT="${PCT_EXEC_TIMEOUT:-1800}"
MIN_GUEST_FREE_MB="${MIN_GUEST_FREE_MB:-500}"
DISK_CHECK="${DISK_CHECK:-1}"
AGENT_CHECK="${AGENT_CHECK:-1}"
BACKUP_CHECK="${BACKUP_CHECK:-1}"
DRY_RUN=0
LIST=0
CHECK=0
ONLY=""
EXCLUDE=""
REPORT_PATH="${REPORT_PATH:-}"
LOG_FILE_PATH="${LOG_FILE_PATH:-}"

RUN_START=$SECONDS
STARTED=$(date '+%F %T')
GUESTS_FILE=$(mktemp) || { echo "error: cannot create temp file" >&2; exit "$EXIT_PREFLIGHT"; }
trap 'rm -f "$GUESTS_FILE"' EXIT

log() {
    local line
    line="[$(date '+%F %T')] $*"
    echo "$line"
    if [ -n "$LOG_FILE_PATH" ]; then
        if ! printf '%s\n' "$line" >> "$LOG_FILE_PATH"; then
            echo "error: cannot write log file: $LOG_FILE_PATH" >&2
        fi
    fi
}

# Per-guest record (TSV -> JSON at report time). Reason is tab-sanitized.
record_guest() {
    # record_guest <vmid> <type> <name> <action> <status> <reason> <duration_s>
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "${3//$'\t'/ }" "$4" "$5" "${6//$'\t'/ }" "$7" >> "$GUESTS_FILE"
}

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
  --report <path>  write JSON report to path after the run (v3.3)
  --log-file <p>   also append log lines to file (v3.3)
  -h, --help       this help
safety env: MIN_GUEST_FREE_MB (default 500), DISK_CHECK/AGENT_CHECK/BACKUP_CHECK (1|0)
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
        --report)
            require_value --report $#; REPORT_PATH="$2"; shift ;;
        --report=*)    REPORT_PATH="${1#--report=}" ;;
        --log-file)
            require_value --log-file $#; LOG_FILE_PATH="$2"; shift ;;
        --log-file=*)  LOG_FILE_PATH="${1#--log-file=}" ;;
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
if ! is_uint "$MIN_GUEST_FREE_MB"; then
    log "preflight: MIN_GUEST_FREE_MB must be a non-negative integer (got: $MIN_GUEST_FREE_MB)"
    exit "$EXIT_PREFLIGHT"
fi
for flag in DISK_CHECK AGENT_CHECK BACKUP_CHECK; do
    case "${!flag}" in
        0|1) ;;
        *) log "preflight: $flag must be 0 or 1 (got: ${!flag})"; exit "$EXIT_PREFLIGHT" ;;
    esac
done

# report/log output paths must be writable (fail before doing any work)
if [ -n "$LOG_FILE_PATH" ] && ! touch "$LOG_FILE_PATH" 2>/dev/null; then
    log "preflight: cannot write log file: $LOG_FILE_PATH"
    exit "$EXIT_PREFLIGHT"
fi
if [ -n "$REPORT_PATH" ]; then
    report_dir=$(dirname "$REPORT_PATH")
    if [ ! -d "$report_dir" ] || [ ! -w "$report_dir" ]; then
        log "preflight: report path not writable: $REPORT_PATH"
        exit "$EXIT_PREFLIGHT"
    fi
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

# QEMU Guest Agent readiness (SEC-009): agent configured AND responding.
guest_has_agent() {
    local vmid="$1" out
    out=$(pvesh get "/nodes/$NODE/qemu/$vmid/agent" --output-format json 2>&1) || return 1
    printf '%s' "$out" | jq -e '.status == "ok"' >/dev/null 2>&1 || return 1
    return 0
}

# Backup coverage (FR-010): is VMID covered by an ENABLED vzdump job
# (all=1 or explicit vmid list)? $BACKUP_JOBS must be a JSON array.
backup_covers() {
    local vmid="$1"
    printf '%s' "$BACKUP_JOBS" | jq -e --arg id "$vmid" '
        any(.[];
            (((.enabled // 0) | tostring) == "1")
            and (
                (((.all // 0) | tostring) == "1")
                or (((.vmid // "") | tostring | split(",")
                     | map(gsub("[[:space:]]"; "")) | index($id)) != null)
            )
        )' >/dev/null 2>&1
}

# Guest disk preflight (SEC-009). Returns: 0 ok | 1 below threshold | 2 unknown.
check_guest_disk() {
    local type="$1" vmid="$2" out rc free_kb
    local cmd="df -P -k / | awk 'NR==2 {print \$4}'"
    if [ "$type" = "lxc" ]; then
        out=$(timeout "$PCT_EXEC_TIMEOUT" pct exec "$vmid" -- bash -c "$cmd" 2>&1)
        rc=$?
    else
        out=$(qm guest exec "$vmid" --timeout 60 -- bash -c "$cmd" 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            rc=$(printf '%s' "$out" | jq -r '.exitcode // 1' 2>/dev/null || echo 1)
            out=$(printf '%s' "$out" | jq -r '."out-data" // ""' 2>/dev/null)
        fi
    fi
    [ "$rc" -ne 0 ] && return 2
    # Extract free KB: prefer line 2 field 4 (raw df table), fall back to a
    # bare number (guest-side awk already reduced it). Never concatenate digits.
    free_kb=$(printf '%s\n' "$out" | awk '
        NR==1 { first=$0; n1=NF }
        NR==2 && NF>=4 { print $4; found=1; exit }
        END { if (!found) { if (n1==1) print first; else if (n1>=4) { split(first,f," "); print f[4] } } }' | tr -dc '0-9')
    is_uint "$free_kb" || return 2
    [ "$free_kb" -ge $((MIN_GUEST_FREE_MB * 1024)) ] && return 0
    return 1
}

# JSON report (FR-013). Built with jq only - no hand-concatenated JSON.
write_report() {
    local mode_kind="$1" finished total summary guests
    finished=$(date '+%F %T')
    total=$((SECONDS - RUN_START))
    summary=$(jq -n --argjson s "$OK" --argjson w "$WARN" --argjson k "$SKIP" --argjson f "$FAIL" \
        '{success:$s, warning:$w, skipped:$k, failed:$f}')
    guests=$(jq -R -s -c '
        split("\n") | map(select(length > 0)) | map(split("\t") |
        (.[0] as $id | .[6] as $dur |
        { vmid: ($id | tonumber? // $id),
          type: .[1], name: .[2], action: .[3],
          status: .[4], reason: .[5],
          duration_s: ($dur | tonumber? // 0) }))' "$GUESTS_FILE")
    if ! jq -n --arg tool "update-vms" --arg version "$VERSION" --arg node "$NODE" \
            --arg mode "$mode_kind" --arg started "$STARTED" --arg finished "$finished" \
            --argjson duration_s "$total" --argjson summary "$summary" --argjson guests "$guests" \
        '{tool:$tool, version:$version, node:$node, mode:$mode,
          started:$started, finished:$finished, duration_s:$duration_s,
          summary:$summary, guests:$guests}' > "$REPORT_PATH"; then
        log "error: cannot write report: $REPORT_PATH"
        return "$EXIT_PREFLIGHT"
    fi
    log "report written: $REPORT_PATH"
    return 0
}

OK=0; WARN=0; FAIL=0; SKIP=0

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

# ---- backup job list (FR-010, advisory) ----------------------------------
BACKUP_STATUS="unknown"
BACKUP_JOBS="[]"
if [ "$BACKUP_CHECK" -eq 1 ]; then
    if jobs_json=$(pvesh get /cluster/backup --output-format json 2>&1) \
       && printf '%s' "$jobs_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        BACKUP_STATUS="ok"
        BACKUP_JOBS="$jobs_json"
    else
        log "⚠ backup status unknown: could not read /cluster/backup (FR-010)"
    fi
fi

# ---- read-only modes: --list / --check (no lock, no changes) -------------
if [ "$LIST" -eq 1 ] || [ "$CHECK" -eq 1 ]; then
    [ "$CHECK" -eq 1 ] && MODE=", check" || MODE=", list"
    log "=== update-vms start (node=$NODE$MODE) ==="
    if [ "$node_guest_count" -eq 0 ]; then
        log "⚠ no guests found on node $NODE (fetched $total_count total) - check PVE_NODE"
    fi
    declare -A ACTION_COUNT=()
    NOAGENT=0; NOTCOVERED=0
    while IFS= read -r VM; do
        VMID=$(printf '%s' "$VM" | jq -r '.vmid')
        TYPE=$(printf '%s' "$VM" | jq -r '.type')
        STATUS=$(printf '%s' "$VM" | jq -r '.status')
        TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')
        NAME=$(printf '%s' "$VM" | jq -r '.name // ""')
        ACTION=$(guest_action "$VMID" "$STATUS" "$TAGS")
        ACTION_COUNT[$ACTION]=$(( ${ACTION_COUNT[$ACTION]:-0} + 1 ))
        if [ "$CHECK" -eq 1 ] && { [ "$ACTION" = "apt" ] || [ "$ACTION" = "yum" ]; }; then
            if [ "$AGENT_CHECK" -eq 1 ] && [ "$TYPE" = "qemu" ] && ! guest_has_agent "$VMID"; then
                NOAGENT=$((NOAGENT+1))
            fi
            if [ "$BACKUP_CHECK" -eq 1 ] && [ "$BACKUP_STATUS" = "ok" ] && ! backup_covers "$VMID"; then
                NOTCOVERED=$((NOTCOVERED+1))
            fi
        fi
        if [ "$LIST" -eq 1 ]; then
            printf '%-8s %-5s %-8s %-24s %s\n' "$VMID" "$TYPE" "$STATUS" "${TAGS:--}" "$NAME [$ACTION]"
        fi
        record_guest "$VMID" "$TYPE" "$NAME" "$ACTION" "planned" "" 0
    done < <(printf '%s' "$resources" | jq -c --arg node "$NODE" '.[] | select(.node == $node)')
    if [ "$CHECK" -eq 1 ]; then
        for action in "${!ACTION_COUNT[@]}"; do
            log "  inventory: $action = ${ACTION_COUNT[$action]}"
        done
        log "  update candidates without guest agent: $NOAGENT"
        log "  update candidates not covered by an enabled backup job: $NOTCOVERED"
        log "preflight ok: root, binaries, env, inventory"
    fi
    if [ -n "$REPORT_PATH" ]; then
        if [ "$CHECK" -eq 1 ]; then
            write_report "check"
        else
            write_report "list"
        fi
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
    NAME=$(printf '%s' "$VM" | jq -r '.name // ""')
    gstart=$SECONDS
    GUEST_WARN=0

    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        log "⚠ Skipping malformed entry (vmid=$VMID)"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "malformed entry" 0
        SKIP=$((SKIP+1)); continue
    fi

    if [ -n "$ONLY" ] && ! in_list "$ONLY" "$VMID"; then
        log "⏭ Skipping $VMID ($TYPE) - not in --only list"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "not in --only list" 0
        SKIP=$((SKIP+1)); continue
    fi
    if [ -n "$EXCLUDE" ] && in_list "$EXCLUDE" "$VMID"; then
        log "⏭ Skipping $VMID ($TYPE) - in --exclude list"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "in --exclude list" 0
        SKIP=$((SKIP+1)); continue
    fi
    ONLY_FOUND="$ONLY_FOUND$VMID,"

    if [ "$STATUS" != "running" ]; then
        log "⚪ Skipping $VMID ($TYPE) - status $STATUS"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "status $STATUS" 0
        SKIP=$((SKIP+1)); continue
    fi

    if has_tag "$TAGS" "windows"; then
        log "🟦 Skipping $VMID ($TYPE) - tag: windows"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "tag: windows" 0
        SKIP=$((SKIP+1)); continue
    fi

    # decide update command first (yum before apt, same precedence as v1/v2)
    UPDATE_CMD=""; UPDATE_KIND=""
    if has_tag "$TAGS" "yum"; then
        UPDATE_CMD="$YUM_CMD"; UPDATE_KIND="yum/dnf"
    elif has_tag "$TAGS" "apt"; then
        UPDATE_CMD="$APT_CMD"; UPDATE_KIND="apt"
    else
        log "⚠ Skipping $VMID ($TYPE) - no apt/yum/windows tag (tags: ${TAGS:-none})"
        record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "no apt/yum/windows tag" 0
        SKIP=$((SKIP+1)); continue
    fi

    # ---- B5 safety preflight per update candidate ------------------------
    if [ "$AGENT_CHECK" -eq 1 ] && [ "$TYPE" = "qemu" ] && ! guest_has_agent "$VMID"; then
        log "⏭ Skipping $VMID (qemu) - no guest agent (install qemu-guest-agent in the guest and run: qm set $VMID -agent enabled=1)"
        record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" skipped "no guest agent" 0
        SKIP=$((SKIP+1)); continue
    fi

    if [ "$DISK_CHECK" -eq 1 ] && [ "$DRY_RUN" -ne 1 ]; then
        drc=0
        check_guest_disk "$TYPE" "$VMID" || drc=$?
        if [ "$drc" -eq 1 ]; then
            log "⏭ Skipping $VMID ($TYPE) - insufficient disk space (<${MIN_GUEST_FREE_MB} MB free on /)"
            record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" skipped "insufficient disk space" 0
            SKIP=$((SKIP+1)); continue
        elif [ "$drc" -eq 2 ]; then
            log "⏭ Skipping $VMID ($TYPE) - disk space check failed (unknown prerequisites, SEC-009)"
            record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" skipped "disk check failed" 0
            SKIP=$((SKIP+1)); continue
        fi
    fi

    if [ "$BACKUP_CHECK" -eq 1 ] && [ "$BACKUP_STATUS" = "ok" ] && ! backup_covers "$VMID"; then
        log "⚠ $VMID ($TYPE): not covered by any enabled backup job (FR-010)"
        GUEST_WARN=1
    fi

    log "▶ Updating $VMID ($TYPE) [$UPDATE_KIND]"
    gdur=0
    if run_guest_cmd "$TYPE" "$VMID" "$UPDATE_CMD"; then
        gdur=$((SECONDS-gstart))
        if [ "$DRY_RUN" -eq 1 ]; then
            record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" planned "dry-run preview" "$gdur"
            OK=$((OK+1))
        elif [ "$GUEST_WARN" -eq 1 ]; then
            WARN=$((WARN+1))
            record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" warning "updated with warnings" "$gdur"
        else
            OK=$((OK+1))
            record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" success "" "$gdur"
        fi
    else
        gdur=$((SECONDS-gstart))
        FAIL=$((FAIL+1))
        record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" failed "update command failed" "$gdur"
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

updated_total=$((OK+WARN))
extra=""
[ "$WARN" -gt 0 ] && extra=" ($WARN with warnings)"
log "=== done: $updated_total updated, $FAIL failed, $SKIP skipped$extra ==="

log "=== per-guest results ==="
while IFS=$'\t' read -r g_vmid g_type g_name g_action g_status g_reason g_dur; do
    [ -n "$g_vmid" ] || continue
    log "  $g_vmid $g_type $g_name [$g_action] $g_status ${g_dur}s${g_reason:+ - $g_reason}"
done < "$GUESTS_FILE"

rc="$EXIT_OK"
[ "$FAIL" -gt 0 ] && rc="$EXIT_GUEST_FAILURE"
if [ -n "$REPORT_PATH" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        write_report "dry-run" || rc="$EXIT_PREFLIGHT"
    else
        write_report "update" || rc="$EXIT_PREFLIGHT"
    fi
fi
exit "$rc"
