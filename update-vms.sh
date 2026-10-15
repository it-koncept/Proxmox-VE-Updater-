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
# v3.5 (Phase 1) adds stable engine interfaces for the GUI backend:
#   --scan             READ-ONLY scan with package preview (FR-002/FR-007):
#                      guests: apt -> apt-get update -qq (index only) + apt-get -s
#                      upgrade; yum -> dnf/yum check-update (rc 100 = updates).
#                      host (--host --scan): apt-get update + apt-get -s
#                      dist-upgrade. No package state is changed anywhere.
#                      Report gains per-guest "packages" array + counts.
#                      Requires root (execs into guests); takes NO global lock
#                      but per-target locks (busy target -> skipped, never queued).
#   --backup-status    machine-readable JSON: job coverage per update candidate
#                      + backup_status ok|unknown (FR-009/FR-010 groundwork).
#   per-target locks   TARGET_LOCK_DIR (default /var/lock): update-vms-<type>-
#                      <vmid>.lock held during guest exec (FR-014); the global
#                      LOCK_FILE guard is unchanged.
#
# v3.4 (B7) adds host updates (FR-002, SEC-001/003/013) - gated by policy:
#   --host             update THIS host: apt-get update && dist-upgrade
#   --yes              skip interactive confirmation (explicit policy only;
#                      without it a real host run needs a tty + typing YES)
#   - refused when cluster quorum is lost (pvecm status; standalone ok)
#   - refused when host / free space < MIN_HOST_FREE_MB (default 1000)
#   - failed apt-get update aborts before dist-upgrade (SEC-003)
#   - HOST_UPDATE_TIMEOUT (default 3600) bounds each apt phase
#   - after success: reboot-required marker -> status warning (no auto reboot)
#   - --host --dry-run: simulation only (apt-get -s), no state change
#   - never combine --host with --only/--exclude/--list/--check
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

VERSION="3.5.0"
EXIT_OK=0
EXIT_GUEST_FAILURE=1
EXIT_PREFLIGHT=2
EXIT_LOCK=3

LOCK_FILE="${LOCK_FILE:-/var/lock/update-vms.lock}"
TARGET_LOCK_DIR="${TARGET_LOCK_DIR:-/var/lock}"
NODE="${PVE_NODE:-$(hostname)}"
QEMU_EXEC_TIMEOUT="${QEMU_EXEC_TIMEOUT:-1800}"
PCT_EXEC_TIMEOUT="${PCT_EXEC_TIMEOUT:-1800}"
HOST_UPDATE_TIMEOUT="${HOST_UPDATE_TIMEOUT:-3600}"
MIN_HOST_FREE_MB="${MIN_HOST_FREE_MB:-1000}"
HOST_REBOOT_MARKER="${HOST_REBOOT_MARKER:-/var/run/reboot-required}"
MIN_GUEST_FREE_MB="${MIN_GUEST_FREE_MB:-500}"
DISK_CHECK="${DISK_CHECK:-1}"
AGENT_CHECK="${AGENT_CHECK:-1}"
BACKUP_CHECK="${BACKUP_CHECK:-1}"
DRY_RUN=0
LIST=0
CHECK=0
SCAN=0
BSM=0
HOST_MODE=0
ASSUME_YES=0
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
    # --backup-status emits machine-readable JSON on stdout: keep stdout pure
    # by routing log lines to stderr in that mode.
    if [ "$BSM" -eq 1 ]; then
        echo "$line" >&2
    else
        echo "$line"
    fi
    if [ -n "$LOG_FILE_PATH" ]; then
        if ! printf '%s\n' "$line" >> "$LOG_FILE_PATH"; then
            echo "error: cannot write log file: $LOG_FILE_PATH" >&2
        fi
    fi
}

# Per-guest record (TSV -> JSON at report time). Reason is tab-sanitized.
record_guest() {
    # record_guest <vmid> <type> <name> <action> <status> <reason> <duration_s> [packages]
    local pkgs="${8:-}"
    printf '%s	%s	%s	%s	%s	%s	%s	%s\n' \
        "$1" "$2" "${3//$'	'/ }" "$4" "$5" "${6//$'	'/ }" "$7" "${pkgs//$'	'/,}" >> "$GUESTS_FILE"
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
  --host           update this host (apt update + dist-upgrade) (v3.4)
  --scan           read-only update scan with package preview (v3.5, root)
  --backup-status  JSON: backup-job coverage per candidate (v3.5, root)
  --yes            non-interactive confirmation for --host (explicit policy)
  -h, --help       this help
safety env: MIN_GUEST_FREE_MB (default 500), DISK_CHECK/AGENT_CHECK/BACKUP_CHECK (1|0)
host env: HOST_UPDATE_TIMEOUT (3600), MIN_HOST_FREE_MB (1000), HOST_REBOOT_MARKER
lock env: TARGET_LOCK_DIR (default /var/lock) - per-target locks (v3.5)
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
        --host)    HOST_MODE=1 ;;
        --scan)    SCAN=1 ;;
        --backup-status) BSM=1 ;;
        --yes)     ASSUME_YES=1 ;;
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
if ! is_uint "$HOST_UPDATE_TIMEOUT"; then
    log "preflight: HOST_UPDATE_TIMEOUT must be a non-negative integer (got: $HOST_UPDATE_TIMEOUT)"
    exit "$EXIT_PREFLIGHT"
fi
if ! is_uint "$MIN_HOST_FREE_MB"; then
    log "preflight: MIN_HOST_FREE_MB must be a non-negative integer (got: $MIN_HOST_FREE_MB)"
    exit "$EXIT_PREFLIGHT"
fi
if [ "$HOST_MODE" -eq 1 ] && { [ -n "$ONLY" ] || [ -n "$EXCLUDE" ] || [ "$LIST" -eq 1 ] || [ "$CHECK" -eq 1 ]; }; then
    log "preflight: --host cannot be combined with --only/--exclude/--list/--check"
    exit "$EXIT_PREFLIGHT"
fi
# --scan combines with --host (host scan) and --only/--exclude, never with the
# other read-only modes; --backup-status is standalone (filters allowed).
if [ "$SCAN" -eq 1 ] && { [ "$LIST" -eq 1 ] || [ "$CHECK" -eq 1 ] || [ "$BSM" -eq 1 ]; }; then
    log "preflight: --scan cannot be combined with --list/--check/--backup-status"
    exit "$EXIT_PREFLIGHT"
fi
if [ "$BSM" -eq 1 ] && { [ "$HOST_MODE" -eq 1 ] || [ "$SCAN" -eq 1 ] || [ "$LIST" -eq 1 ] || [ "$CHECK" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; }; then
    log "preflight: --backup-status must run standalone (only --only/--exclude allowed)"
    exit "$EXIT_PREFLIGHT"
fi
if [ ! -d "$TARGET_LOCK_DIR" ] || [ ! -w "$TARGET_LOCK_DIR" ]; then
    log "preflight: TARGET_LOCK_DIR not writable: $TARGET_LOCK_DIR"
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

# Per-target lock (FR-014). Returns: 0 acquired (fd 8 open) | 1 busy | 2 error.
target_lock() {
    local path="$TARGET_LOCK_DIR/update-vms-$1-$2.lock"
    if ! { exec 8>"$path"; } 2>/dev/null; then return 2; fi
    if flock -n 8; then return 0; fi
    exec 8>&-
    return 1
}
target_unlock() { flock -u 8 2>/dev/null; exec 8>&-; }

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
        (.[0] as $id | .[6] as $dur | .[7] as $pkgs |
        { vmid: ($id | tonumber? // $id),
          type: .[1], name: .[2], action: .[3],
          status: .[4], reason: .[5],
          duration_s: ($dur | tonumber? // 0),
          packages: (($pkgs // "") as $p | (if $p == "" then [] else ($p | split(",")) end)) }))' "$GUESTS_FILE")
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

# Cluster quorum check before host changes (SEC-013); standalone is fine.
host_quorum_ok() {
    local out rc
    out=$(pvecm status 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$out" | grep -qi "no cluster configuration"; then
            log "host: standalone node (no cluster) - quorum check not applicable"
            return 0
        fi
        log "host preflight: pvecm status failed (rc=$rc):"
        printf '%s\n' "$out" | head -3 | sed 's/^/   | /'
        return 1
    fi
    if printf '%s' "$out" | grep -qE "^Quorate:[[:space:]]+Yes"; then
        log "host: cluster quorum ok"
        return 0
    fi
    log "host preflight: cluster quorum LOST - refusing host update (SEC-013)"
    return 1
}

# Host update workflow (FR-002). Never automatic: needs tty+YES or --yes.
run_host_update() {
    local out rc answer free hstart=$SECONDS
    for bin in apt-get pvecm df; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "host preflight: required command not found: $bin"
            return "$EXIT_PREFLIGHT"
        fi
    done
    if ! host_quorum_ok; then return "$EXIT_PREFLIGHT"; fi
    free=$(df -P -k / | awk 'NR==2 {print $4}')
    if ! is_uint "$free" || [ "$free" -lt $((MIN_HOST_FREE_MB * 1024)) ]; then
        log "host preflight: free space on / below MIN_HOST_FREE_MB=$MIN_HOST_FREE_MB - refusing"
        return "$EXIT_PREFLIGHT"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "HOST DRY-RUN: would run: apt-get update && apt-get -y dist-upgrade (timeout ${HOST_UPDATE_TIMEOUT}s each)"
        out=$(apt-get -s dist-upgrade 2>&1)
        printf '%s\n' "$out" | tail -3 | sed 's/^/   | /'
        record_guest "host" "host" "$NODE" "dist-upgrade" planned "dry-run simulation" $((SECONDS-hstart))
        if [ -n "$REPORT_PATH" ]; then write_report "host-dry-run"; fi
        return "$EXIT_OK"
    fi
    # confirmation gate (SEC-001): typed YES on a tty, or explicit --yes policy
    if [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -t 0 ]; then
            log "host: refusing unattended host upgrade - stdin is not a terminal and --yes was not given (SEC-001)"
            return "$EXIT_PREFLIGHT"
        fi
        printf 'Type YES to run apt-get update + dist-upgrade on host %s: ' "$NODE"
        if ! IFS= read -r answer; then
            log "host: no confirmation received - aborting"
            return "$EXIT_PREFLIGHT"
        fi
        if [ "$answer" != "YES" ]; then
            log "host: confirmation not given - aborting"
            return "$EXIT_PREFLIGHT"
        fi
    else
        log "host: --yes given - running without interactive confirmation (explicit policy)"
    fi
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        log "preflight: cannot open lock file: $LOCK_FILE"
        return "$EXIT_PREFLIGHT"
    fi
    if ! flock -n 9; then
        log "Another update-vms run is already in progress - exiting."
        return "$EXIT_LOCK"
    fi
    log "=== host update start (node=$NODE) ==="
    out=$(timeout "$HOST_UPDATE_TIMEOUT" apt-get update 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        log "host: apt-get update failed (rc=$rc) - dist-upgrade NOT attempted (SEC-003)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   | /'
        record_guest "host" "host" "$NODE" "dist-upgrade" failed "apt-get update failed" $((SECONDS-hstart))
        if [ -n "$REPORT_PATH" ]; then write_report "host"; fi
        return "$EXIT_GUEST_FAILURE"
    fi
    out=$(timeout "$HOST_UPDATE_TIMEOUT" apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        log "host: apt-get dist-upgrade failed (rc=$rc)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   | /'
        record_guest "host" "host" "$NODE" "dist-upgrade" failed "dist-upgrade failed" $((SECONDS-hstart))
        if [ -n "$REPORT_PATH" ]; then write_report "host"; fi
        return "$EXIT_GUEST_FAILURE"
    fi
    if [ -f "$HOST_REBOOT_MARKER" ]; then
        log "host: updated; reboot required ($HOST_REBOOT_MARKER) - NOT rebooting automatically (SEC-001)"
        WARN=$((WARN+1))
        record_guest "host" "host" "$NODE" "dist-upgrade" warning "reboot required" $((SECONDS-hstart))
    else
        log "host: updated successfully"
        OK=$((OK+1))
        record_guest "host" "host" "$NODE" "dist-upgrade" success "" $((SECONDS-hstart))
    fi
    log "=== host update done ==="
    if [ -n "$REPORT_PATH" ]; then write_report "host"; fi
    return "$EXIT_OK"
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
# Scan commands (v3.5): read-only w.r.t. package state. apt-get update -qq only
# refreshes the index; -s / check-update never install.
APT_SCAN='apt-get update -qq >/dev/null 2>&1; apt-get -s upgrade'
YUM_SCAN='if command -v dnf >/dev/null 2>&1; then dnf -q check-update; else yum -q check-update; fi'

# Scan exec: sets SCAN_OUT / SCAN_RC (guest rc; for yum, 100 = updates available).
scan_guest_cmd() {
    # scan_guest_cmd <type> <vmid> <shell-command>
    local type="$1" vmid="$2" cmd="$3" out rc
    if [ "$type" = "lxc" ]; then
        out=$(timeout "$PCT_EXEC_TIMEOUT" pct exec "$vmid" -- bash -c "$cmd" 2>&1)
        rc=$?
    else
        out=$(qm guest exec "$vmid" --timeout "$QEMU_EXEC_TIMEOUT" -- bash -c "$cmd" 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            rc=$(printf '%s' "$out" | jq -r '.exitcode // 0' 2>/dev/null || echo 1)
            out=$(printf '%s' "$out" | jq -r '.out-data // ""' 2>/dev/null)
        fi
    fi
    SCAN_OUT="$out"; SCAN_RC="$rc"
}

# Parse scan output -> SCAN_COUNT + comma-joined SCAN_PKGS (max 200).
parse_apt_scan() {
    SCAN_COUNT=$(printf '%s\n' "$1" | grep -c '^Inst ' || true)
    SCAN_PKGS=$(printf '%s\n' "$1" | awk '/^Inst /{print $2}' | head -200 | paste -sd, -)
}
parse_yum_scan() {
    SCAN_COUNT=$(printf '%s\n' "$1" | awk '/^[^[:space:]]+[[:space:]]+[0-9]/{print $1}' | wc -l)
    SCAN_PKGS=$(printf '%s\n' "$1" | awk '/^[^[:space:]]+[[:space:]]+[0-9]/{print $1}' | head -200 | paste -sd, -)
}

# Host scan (v3.5, FR-002/FR-007): index refresh + simulation only.
run_host_scan() {
    local out rc hstart=$SECONDS
    for bin in apt-get timeout; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "host preflight: required command not found: $bin"
            return "$EXIT_PREFLIGHT"
        fi
    done
    if ! target_lock host "$NODE"; then
        log "⏭ HOST scan skipped - target locked by another run"
        return "$EXIT_OK"
    fi
    out=$(timeout "$HOST_UPDATE_TIMEOUT" apt-get update 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        log "host scan: apt-get update failed (rc=$rc)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   | /'
        record_guest "host" "host" "$NODE" "scan" failed "apt-get update failed" $((SECONDS-hstart))
        target_unlock
        if [ -n "$REPORT_PATH" ]; then write_report "host-scan"; fi
        return "$EXIT_GUEST_FAILURE"
    fi
    out=$(timeout "$HOST_UPDATE_TIMEOUT" apt-get -s dist-upgrade 2>&1); rc=$?
    target_unlock
    if [ "$rc" -ne 0 ]; then
        log "host scan: apt-get -s dist-upgrade failed (rc=$rc)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   | /'
        record_guest "host" "host" "$NODE" "scan" failed "simulation failed" $((SECONDS-hstart))
        if [ -n "$REPORT_PATH" ]; then write_report "host-scan"; fi
        return "$EXIT_GUEST_FAILURE"
    fi
    parse_apt_scan "$out"
    if [ "$SCAN_COUNT" -gt 0 ]; then
        log "host scan: $SCAN_COUNT package update(s) available"
        record_guest "host" "host" "$NODE" "scan" success "$SCAN_COUNT updates available" $((SECONDS-hstart)) "$SCAN_PKGS"
    else
        log "host scan: up to date"
        record_guest "host" "host" "$NODE" "scan" success "up to date" $((SECONDS-hstart))
    fi
    if [ -n "$REPORT_PATH" ]; then write_report "host-scan"; fi
    return "$EXIT_OK"
}

# ---- host mode dispatch (v3.4 update / v3.5 scan) -------------------------
if [ "$HOST_MODE" -eq 1 ]; then
    if [ "$SCAN" -eq 1 ]; then
        run_host_scan
    else
        run_host_update
    fi
    exit $?
fi

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

# ---- backup-status mode (v3.5, FR-009/FR-010): JSON, no changes, no lock --
if [ "$BSM" -eq 1 ]; then
    cands=""
    while IFS= read -r VM; do
        VMID=$(printf '%s' "$VM" | jq -r '.vmid')
        TYPE=$(printf '%s' "$VM" | jq -r '.type')
        STATUS=$(printf '%s' "$VM" | jq -r '.status')
        TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')
        NAME=$(printf '%s' "$VM" | jq -r '.name // ""')
        ACTION=$(guest_action "$VMID" "$STATUS" "$TAGS")
        case "$ACTION" in apt|yum) ;; *) continue ;; esac
        covered=0
        if [ "$BACKUP_STATUS" = "ok" ] && backup_covers "$VMID"; then covered=1; fi
        cands+=$(printf '%s\t%s\t%s\t%s\n' "$VMID" "$TYPE" "${NAME//$'\t'/ }" "$covered")$'\n'
    done < <(printf '%s' "$resources" | jq -c --arg node "$NODE" '.[] | select(.node == $node)')
    jq -n --arg tool "update-vms" --arg version "$VERSION" --arg node "$NODE" \
          --arg mode "backup-status" --arg backup_status "$BACKUP_STATUS" \
          --argjson jobs "$(printf '%s' "$BACKUP_JOBS" | jq -c '[.[] | select((.enabled // 0) | tostring == "1")] | length')" \
          --rawfile cands <(printf '%s' "$cands") \
        '{tool:$tool, version:$version, node:$node, mode:$mode,
          backup_status:$backup_status, enabled_backup_jobs:$jobs,
          candidates:($cands | split("\n") | map(select(length > 0)) | map(split("\t") |
            { vmid: (.[0] | tonumber? // .[0]), type: .[1], name: .[2],
              backup_covered: (.[3] == "1") }))}'
    exit "$EXIT_OK"
fi

# ---- scan mode (v3.5, FR-002/FR-007): read-only w.r.t. package state ------
# No global lock (scans must stay available during update runs); per-target
# locks make a target that is being updated report as locked-skipped.
if [ "$SCAN" -eq 1 ]; then
    log "=== update-vms start (node=$NODE, scan) ==="
    if [ "$node_guest_count" -eq 0 ]; then
        log "⚠ no guests found on node $NODE (fetched $total_count total) - check PVE_NODE"
    fi
    while IFS= read -r VM; do
        VMID=$(printf '%s' "$VM" | jq -r '.vmid')
        TYPE=$(printf '%s' "$VM" | jq -r '.type')
        STATUS=$(printf '%s' "$VM" | jq -r '.status')
        TAGS=$(printf '%s' "$VM" | jq -r '.tags // ""')
        NAME=$(printf '%s' "$VM" | jq -r '.name // ""')
        gstart=$SECONDS

        if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
            log "⚠ Skipping malformed entry (vmid=$VMID)"
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "malformed entry" 0
            SKIP=$((SKIP+1)); continue
        fi
        if [ -n "$ONLY" ] && ! in_list "$ONLY" "$VMID"; then
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "not in --only list" 0
            SKIP=$((SKIP+1)); continue
        fi
        if [ -n "$EXCLUDE" ] && in_list "$EXCLUDE" "$VMID"; then
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "in --exclude list" 0
            SKIP=$((SKIP+1)); continue
        fi
        if [ "$STATUS" != "running" ]; then
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "status $STATUS" 0
            SKIP=$((SKIP+1)); continue
        fi
        if has_tag "$TAGS" "windows"; then
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "tag: windows" 0
            SKIP=$((SKIP+1)); continue
        fi
        SCAN_CMD=""; SCAN_KIND=""
        if has_tag "$TAGS" "yum"; then
            SCAN_CMD="$YUM_SCAN"; SCAN_KIND="yum/dnf"
        elif has_tag "$TAGS" "apt"; then
            SCAN_CMD="$APT_SCAN"; SCAN_KIND="apt"
        else
            record_guest "$VMID" "$TYPE" "$NAME" "-" skipped "no apt/yum/windows tag" 0
            SKIP=$((SKIP+1)); continue
        fi
        if [ "$AGENT_CHECK" -eq 1 ] && [ "$TYPE" = "qemu" ] && ! guest_has_agent "$VMID"; then
            log "⏭ Skipping $VMID (qemu) - no guest agent"
            record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" skipped "no guest agent" 0
            SKIP=$((SKIP+1)); continue
        fi
        tlrc=0
        target_lock "$TYPE" "$VMID" || tlrc=$?
        if [ "$tlrc" -eq 1 ]; then
            log "⏭ Skipping $VMID ($TYPE) - target locked by another run"
            record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" skipped "target locked by another run" 0
            SKIP=$((SKIP+1)); continue
        elif [ "$tlrc" -eq 2 ]; then
            log "⏭ Skipping $VMID ($TYPE) - cannot open target lock"
            record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" skipped "cannot open target lock" 0
            SKIP=$((SKIP+1)); continue
        fi
        log "▶ Scanning $VMID ($TYPE) [$SCAN_KIND]"
        scan_guest_cmd "$TYPE" "$VMID" "$SCAN_CMD"
        gdur=$((SECONDS-gstart))
        target_unlock
        if [ "$SCAN_KIND" = "apt" ]; then
            if [ "$SCAN_RC" -ne 0 ]; then
                log "   ✗ scan failed (rc=$SCAN_RC):"
                printf '%s\n' "$SCAN_OUT" | tail -5 | sed 's/^/     | /'
                FAIL=$((FAIL+1))
                record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" failed "scan command failed" "$gdur"
            else
                parse_apt_scan "$SCAN_OUT"
                if [ "$SCAN_COUNT" -gt 0 ]; then
                    log "   $SCAN_COUNT update(s) available"
                    OK=$((OK+1))
                    record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" success "$SCAN_COUNT updates available" "$gdur" "$SCAN_PKGS"
                else
                    log "   up to date"
                    OK=$((OK+1))
                    record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" success "up to date" "$gdur"
                fi
            fi
        else
            if [ "$SCAN_RC" -eq 100 ]; then
                parse_yum_scan "$SCAN_OUT"
                log "   $SCAN_COUNT update(s) available"
                OK=$((OK+1))
                record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" success "$SCAN_COUNT updates available" "$gdur" "$SCAN_PKGS"
            elif [ "$SCAN_RC" -eq 0 ]; then
                log "   up to date"
                OK=$((OK+1))
                record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" success "up to date" "$gdur"
            else
                log "   ✗ scan failed (rc=$SCAN_RC):"
                printf '%s\n' "$SCAN_OUT" | tail -5 | sed 's/^/     | /'
                FAIL=$((FAIL+1))
                record_guest "$VMID" "$TYPE" "$NAME" "$SCAN_KIND" failed "scan command failed (rc=$SCAN_RC)" "$gdur"
            fi
        fi
    done < <(printf '%s' "$resources" | jq -c --arg node "$NODE" '.[] | select(.node == $node)')
    updated_total=$((OK+WARN))
    extra=""
    [ "$WARN" -gt 0 ] && extra=" ($WARN with warnings)"
    log "=== done: $updated_total updated, $FAIL failed, $SKIP skipped$extra ==="
    rc="$EXIT_OK"
    [ "$FAIL" -gt 0 ] && rc="$EXIT_GUEST_FAILURE"
    if [ -n "$REPORT_PATH" ]; then
        write_report "scan" || rc="$EXIT_PREFLIGHT"
    fi
    exit "$rc"
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

    # per-target lock (v3.5, FR-014): never two mutating runs on one target
    tlrc=0
    target_lock "$TYPE" "$VMID" || tlrc=$?
    if [ "$tlrc" -eq 1 ]; then
        log "⏭ Skipping $VMID ($TYPE) - target locked by another run"
        record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" skipped "target locked by another run" 0
        SKIP=$((SKIP+1)); continue
    elif [ "$tlrc" -eq 2 ]; then
        log "⏭ Skipping $VMID ($TYPE) - cannot open target lock"
        record_guest "$VMID" "$TYPE" "$NAME" "$UPDATE_KIND" skipped "cannot open target lock" 0
        SKIP=$((SKIP+1)); continue
    fi
    log "▶ Updating $VMID ($TYPE) [$UPDATE_KIND]"
    gdur=0
    if run_guest_cmd "$TYPE" "$VMID" "$UPDATE_CMD"; then
        gdur=$((SECONDS-gstart))
        target_unlock
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
        target_unlock
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
