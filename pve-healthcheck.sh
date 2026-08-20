#!/usr/bin/env bash
set -uo pipefail

# Read-only health check for Proxmox VE hosts.
# Exit codes: 0 = OK, 1 = warnings, 2 = critical findings.

LOOKBACK_HOURS=24
USE_COLOR=1
WARNINGS=0
CRITICALS=0
CHECK_MODE=""

CHECKS=(host services cluster ha memory arc zfs storage iscsi backups logs)

usage() {
    cat <<'EOF'
Usage: pve-healthcheck.sh [--all | --menu | --check NAME] [--hours N] [--no-color] [--help]

Performs read-only checks for:
  - Proxmox version, failed services, cluster quorum and HA
  - RAM, swap and ZFS ARC configuration
  - ZFS pool and Proxmox storage status
  - active and stale iSCSI records
  - completed and failed vzdump backup tasks
  - recent OOM, watchdog, kernel stall and i915 messages

Exit codes: 0 healthy, 1 warnings, 2 critical findings.

Checks: host, services, cluster, ha, memory, arc, zfs, storage, iscsi,
        backups, logs

With an interactive terminal and no mode option, a menu is displayed.
Without an interactive terminal, the complete health check is run.
EOF
}

while (($#)); do
    case "$1" in
        --hours)
            [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "--hours requires an integer" >&2; exit 2; }
            LOOKBACK_HOURS=$2
            shift 2
            ;;
        --all) CHECK_MODE=all; shift ;;
        --menu) CHECK_MODE=menu; shift ;;
        --check)
            [[ -n ${2:-} ]] || { echo "--check requires a check name" >&2; exit 2; }
            CHECK_MODE=$2
            shift 2
            ;;
        --no-color) USE_COLOR=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

valid_check() {
    local wanted=$1 check
    for check in "${CHECKS[@]}"; do
        [[ $wanted == "$check" ]] && return 0
    done
    return 1
}

show_menu() {
    local choice
    printf '\nPVE Healthcheck\n\n'
    printf '  1) Complete health check\n'
    printf '  2) Host information\n'
    printf '  3) Failed systemd services\n'
    printf '  4) Cluster and quorum\n'
    printf '  5) High availability\n'
    printf '  6) Memory and swap\n'
    printf '  7) ZFS ARC\n'
    printf '  8) ZFS pools\n'
    printf '  9) Proxmox storages\n'
    printf ' 10) iSCSI\n'
    printf ' 11) Backup details and error logs\n'
    printf ' 12) Recent critical log patterns\n'
    printf '  0) Exit\n\n'
    read -r -p 'Selection: ' choice
    case $choice in
        1) CHECK_MODE=all ;;
        2) CHECK_MODE=host ;;
        3) CHECK_MODE=services ;;
        4) CHECK_MODE=cluster ;;
        5) CHECK_MODE=ha ;;
        6) CHECK_MODE=memory ;;
        7) CHECK_MODE=arc ;;
        8) CHECK_MODE=zfs ;;
        9) CHECK_MODE=storage ;;
        10) CHECK_MODE=iscsi ;;
        11) CHECK_MODE=backups ;;
        12) CHECK_MODE=logs ;;
        0) exit 0 ;;
        *) echo "Invalid selection: $choice" >&2; exit 2 ;;
    esac
}

if [[ -z $CHECK_MODE ]]; then
    [[ -t 0 && -t 1 ]] && CHECK_MODE=menu || CHECK_MODE=all
fi
[[ $CHECK_MODE == menu ]] && show_menu
if [[ $CHECK_MODE != all ]] && ! valid_check "$CHECK_MODE"; then
    echo "Unknown check: $CHECK_MODE" >&2
    usage >&2
    exit 2
fi

should_run() { [[ $CHECK_MODE == all || $CHECK_MODE == "$1" ]]; }

if ((USE_COLOR)) && [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=''; C_YELLOW=''; C_GREEN=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

section() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"; }
ok()      { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()    { printf '[INFO] %s\n' "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
crit()    { printf '%s[CRIT]%s %s\n' "$C_RED" "$C_RESET" "$*"; CRITICALS=$((CRITICALS + 1)); }
have()    { command -v "$1" >/dev/null 2>&1; }

bytes_gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b/1073741824 }'; }

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root so all checks are available." >&2
    exit 2
fi

if ! have pveversion; then
    echo "This does not appear to be a Proxmox VE host (pveversion missing)." >&2
    exit 2
fi

CHECKED_AT=$(date --iso-8601=seconds)
LOG_PERIOD_START=$(date -d "${LOOKBACK_HOURS} hours ago" --iso-8601=seconds)
mem_available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
mem_total_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)

if should_run host; then
section "Host"
printf 'Hostname:       %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'Checked at:     %s\n' "$CHECKED_AT"
printf 'Journal period: %s to %s\n' "$LOG_PERIOD_START" "$CHECKED_AT"
printf 'Period hint:    Narrow log checks with --hours N (example: %s --hours 1)\n' "${0##*/}"
printf 'Scope note:     Live-state checks are current; this period applies to journal analysis.\n'
printf 'Kernel:         %s\n' "$(uname -r)"
printf 'PVE manager:    %s\n' "$(pveversion 2>/dev/null || true)"
printf 'Uptime:         %s\n' "$(uptime -p 2>/dev/null || uptime)"
fi

if should_run services; then
section "Failed systemd services"
mapfile -t failed_units < <(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF {print $1}')
if ((${#failed_units[@]} == 0)); then
    ok "No failed systemd units"
else
    for unit in "${failed_units[@]}"; do
        warn "Failed unit: $unit"
    done
fi
fi

if should_run cluster; then
section "Cluster and quorum"
if [[ -s /etc/pve/corosync.conf ]] && have pvecm; then
    quorum_output=$(pvecm status 2>&1 || true)
    printf '%s\n' "$quorum_output" | grep -E '^(Name:|Nodes:|Expected votes:|Total votes:|Quorum:|Flags:|Quorate:)'

    printf '\nPVE cluster nodes:\n'
    pvecm nodes 2>&1 || warn "Unable to retrieve PVE cluster node list"

    printf '\nCurrent quorum membership, including QDevice:\n'
    membership_output=$(awk '
        /^Membership information/ { show=1 }
        show { print }
    ' <<<"$quorum_output")
    if [[ -n $membership_output ]]; then
        printf '%s\n' "$membership_output"
    else
        warn "Unable to retrieve current quorum membership"
    fi

    if grep -qE '^Quorate:[[:space:]]+Yes' <<<"$quorum_output"; then
        ok "Cluster has quorum"
    else
        crit "Cluster is not quorate"
    fi
else
    info "Standalone node or no Corosync configuration"
fi
fi

if should_run ha; then
section "High availability"
ha_resources=0
if [[ -r /etc/pve/ha/resources.cfg ]] && grep -qE '^[[:space:]]*(vm|ct):' /etc/pve/ha/resources.cfg; then
    ha_resources=1
fi

if ((ha_resources)); then
    for service in pve-ha-lrm pve-ha-crm; do
        enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
        active=$(systemctl is-active "$service" 2>/dev/null || true)
        printf '%-14s enabled=%-10s active=%s\n' "$service" "$enabled" "$active"
        [[ $enabled == enabled ]] || crit "$service is not enabled although HA resources exist"
        [[ $active == active ]] || crit "$service is not active although HA resources exist"
    done
    if have ha-manager; then
        ha_output=$(ha-manager status 2>&1 || true)
        printf '%s\n' "$ha_output"
        grep -q 'quorum OK' <<<"$ha_output" || crit "HA manager does not report quorum OK"
        if grep -qE 'old timestamp|dead\?|error|request_(stop|start)' <<<"$ha_output"; then
            warn "HA status contains stale, error, or pending states"
        fi
    fi
else
    info "No HA resources configured; HA daemon autostart is not evaluated"
fi
fi

if should_run memory; then
section "Memory and swap"
free -h
avail_pct=$(awk -v a="$mem_available_kib" -v t="$mem_total_kib" 'BEGIN {printf "%.0f", (a/t)*100}')
if ((avail_pct < 10)); then
    crit "Only ${avail_pct}% of RAM is available"
elif ((avail_pct < 20)); then
    warn "Only ${avail_pct}% of RAM is available"
else
    ok "${avail_pct}% of RAM is available"
fi

swap_total_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
swap_free_kib=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
if ((swap_total_kib == 0)); then
    warn "No swap is configured"
else
    swap_used_pct=$(( (swap_total_kib - swap_free_kib) * 100 / swap_total_kib ))
    ((swap_used_pct < 75)) && ok "Swap usage is ${swap_used_pct}%" || warn "Swap usage is ${swap_used_pct}%"
fi
fi

if should_run arc; then
section "ZFS ARC"
if [[ -r /sys/module/zfs/parameters/zfs_arc_max ]]; then
    arc_max=$(< /sys/module/zfs/parameters/zfs_arc_max)
    arc_size=$(awk '/^size[[:space:]]/ {print $3; exit}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo 0)
    ram_bytes=$((mem_total_kib * 1024))
    effective_max=$arc_max
    if ((arc_max == 0)); then
        effective_max=$(awk '/^c_max[[:space:]]/ {print $3; exit}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo 0)
        warn "zfs_arc_max is unlimited (0); effective maximum is $(bytes_gib "$effective_max") GiB"
    else
        ok "Explicit ARC maximum: $(bytes_gib "$arc_max") GiB"
    fi
    info "Current ARC size: $(bytes_gib "$arc_size") GiB"
    if ((effective_max > ram_bytes * 50 / 100)); then
        crit "ARC may use more than 50% of host RAM; verify an explicit limit"
    elif ((effective_max > ram_bytes * 25 / 100)); then
        warn "ARC may use more than 25% of host RAM"
    fi
    info "Proxmox's common default guideline is about 10% of host RAM (workload dependent)"
else
    info "ZFS module is not loaded"
fi
fi

if should_run zfs; then
section "ZFS pools"
if have zpool; then
    pools=$(zpool list -H -o name 2>/dev/null || true)
    if [[ -z $pools ]]; then
        info "No imported ZFS pools"
    else
        while IFS= read -r pool; do
            state=$(zpool list -H -o health "$pool" 2>/dev/null || echo UNKNOWN)
            if [[ $state == ONLINE ]]; then ok "Pool $pool: ONLINE"; else crit "Pool $pool: $state"; fi
        done <<<"$pools"
        zpool status -x 2>/dev/null || true
    fi
fi
fi

if should_run storage; then
section "Proxmox storages"
if have pvesm; then
    storage_output=$(pvesm status 2>&1 || true)
    printf '%s\n' "$storage_output"
    while read -r name status; do
        [[ -z $name ]] && continue
        [[ $status == active ]] || crit "Storage $name is $status"
    done < <(printf '%s\n' "$storage_output" | awk 'NR>1 {print $1, $3}')
fi
fi

if should_run iscsi; then
section "iSCSI"
if have iscsiadm; then
    sessions=$(iscsiadm -m session 2>&1 || true)
    nodes=$(iscsiadm -m node 2>&1 || true)
    discoveries=$(iscsiadm -m discoverydb 2>&1 || true)
    if grep -q 'No active sessions' <<<"$sessions"; then ok "No active iSCSI sessions"; else printf '%s\n' "$sessions"; fi
    if grep -qE 'No records found|No records' <<<"$nodes"; then
        ok "No saved iSCSI nodes"
    else
        printf '%s\n' "$nodes"
        while read -r portal iqn; do
            [[ $portal =~ ^[0-9a-fA-F:.]+,?[0-9]* ]] || continue
            host=${portal%%:*}; host=${host%%,*}
            if ! grep -qE '^[[:space:]]*iscsi:' /etc/pve/storage.cfg 2>/dev/null; then
                warn "Saved iSCSI node $iqn at $portal is not represented by any PVE iSCSI storage"
            fi
            if grep -qF "server $host" /etc/pve/storage.cfg 2>/dev/null; then
                info "$host is also used by another PVE storage type; do not remove that storage when cleaning iSCSI"
            fi
        done <<<"$nodes"
    fi
    if grep -qE '^[^[:space:]]+:[0-9]+[[:space:]]+via[[:space:]]+' <<<"$discoveries"; then
        info "Saved discovery records:"
        printf '%s\n' "$discoveries"
    else
        ok "No saved iSCSI discovery records"
    fi
else
    info "iscsiadm is not installed"
fi
fi

if should_run backups; then
section "Backups"
backup_since_epoch=$(date -d "${LOOKBACK_HOURS} hours ago" +%s)
backup_rows=""
backup_error=""
backup_page_start=0
backup_page_limit=500

while :; do
    if ! backup_page_json=$(pvesh get /cluster/tasks --typefilter vzdump \
        --since "$backup_since_epoch" --start "$backup_page_start" \
        --limit "$backup_page_limit" --output-format json 2>&1); then
        backup_error=$backup_page_json
        break
    fi

    backup_page_count=$(perl -MJSON::PP -0777 -e '
        my $tasks = eval { decode_json(<STDIN>) };
        exit 1 if $@ || ref($tasks) ne "ARRAY";
        print scalar(@$tasks);
    ' <<<"$backup_page_json" 2>/dev/null || true)

    backup_page_rows=$(perl -MJSON::PP -0777 -e '
        my $tasks = eval { decode_json(<STDIN>) };
        exit 1 if $@ || ref($tasks) ne "ARRAY";
        for my $task (@$tasks) {
            next if !defined($task->{endtime}) || !defined($task->{status});
            my @values = map { defined($_) ? $_ : "" }
                @{$task}{qw(status node id user starttime upid)};
            s/[|\r\n]/ /g for @values;
            print join("|", @values), "\n";
        }
    ' <<<"$backup_page_json" 2>/dev/null || true)

    if [[ ! $backup_page_count =~ ^[0-9]+$ ]]; then
        backup_error="Proxmox returned an unreadable task list"
        break
    fi
    [[ -n $backup_page_rows ]] && backup_rows+="${backup_page_rows}"$'\n'
    ((backup_page_count < backup_page_limit)) && break
    backup_page_start=$((backup_page_start + backup_page_limit))
done

backup_rows=${backup_rows%$'\n'}

if [[ -n $backup_error ]]; then
    warn "Unable to retrieve backup task history: $backup_error"
else

    backup_total=0
    backup_ok=0
    backup_failed=0
    while IFS='|' read -r status node guest user starttime upid; do
        [[ -n $upid ]] || continue
        backup_total=$((backup_total + 1))
        if [[ $status == OK ]]; then
            backup_ok=$((backup_ok + 1))
        else
            backup_failed=$((backup_failed + 1))
        fi
    done <<<"$backup_rows"

    printf 'Period:      last %s hour(s)\n' "$LOOKBACK_HOURS"
    printf 'Total:       %d\nSuccessful:  %d\nFailed:      %d\n' \
        "$backup_total" "$backup_ok" "$backup_failed"

    if ((backup_total == 0)); then
        warn "No completed backup tasks found in the selected period"
    elif ((backup_failed > 0)); then
        warn "$backup_failed of $backup_total backup task(s) failed"
    else
        ok "All $backup_total backup task(s) completed successfully"
    fi

    if [[ $CHECK_MODE == backups && -n $backup_rows ]]; then
        printf '\nCompleted backup tasks:\n'
        while IFS='|' read -r status node guest user starttime upid; do
            [[ -n $upid ]] || continue
            started=$(date -d "@$starttime" --iso-8601=seconds 2>/dev/null || printf '%s' "$starttime")
            printf '  %-12s node=%-15s guest=%-8s started=%s user=%s\n' \
                "$status" "$node" "${guest:--}" "$started" "${user:--}"
        done <<<"$backup_rows"

        if ((backup_failed > 0)); then
            printf '\nLogs of failed backup tasks:\n'
            while IFS='|' read -r status node guest user starttime upid; do
                [[ -n $upid && $status != OK ]] || continue
                printf '\n--- node=%s guest=%s status=%s ---\n' "$node" "${guest:--}" "$status"
                task_log_json=$(pvesh get "/nodes/$node/tasks/$upid/log" \
                    --output-format json 2>/dev/null || true)
                if [[ -n $task_log_json ]]; then
                    perl -MJSON::PP -0777 -e '
                        my $lines = eval { decode_json(<STDIN>) };
                        exit 1 if $@ || ref($lines) ne "ARRAY";
                        for my $line (@$lines) {
                            print(($line->{t} // ""), "\n");
                        }
                    ' <<<"$task_log_json" 2>/dev/null || warn "Unable to parse task log: $upid"
                else
                    warn "Unable to retrieve task log: $upid"
                fi
            done <<<"$backup_rows"
        fi
    fi
fi
fi

if should_run logs; then
section "Recent critical log patterns"
since="$LOG_PERIOD_START"
log_data=$(journalctl --since "$since" --no-pager -o short-iso 2>/dev/null || true)
log_findings=0
while IFS='|' read -r label pattern; do
    count=$(grep -Eic "$pattern" <<<"$log_data" || true)
    if ((count > 0)); then
        log_findings=1
        warn "$label: $count matching message(s) in the last ${LOOKBACK_HOURS} hour(s)"
        grep -Ei "$pattern" <<<"$log_data" | tail -n 3 | sed 's/^/  /'
    fi
done <<'EOF'
OOM / killed processes|out of memory|oom-killer|killed process
i915 GPU memory purge|purging GPU memory
Kernel stalls / lockups|blocked for more than|soft lockup|hard lockup
Watchdog / kernel panic|watchdog.*(reset|timeout)|kernel panic
I/O errors|I/O error
Corosync link loss|corosync.*no active links
EOF
if ((log_findings == 0)); then
    ok "No matching critical patterns in the last ${LOOKBACK_HOURS} hour(s)"
else
    info "Use --hours 1 for a short post-fix view; the default also reports earlier incidents"
fi
fi

section "Summary"
printf 'Critical findings: %d\nWarnings:          %d\n' "$CRITICALS" "$WARNINGS"
if ((CRITICALS > 0)); then
    printf '%sResult: ACTION REQUIRED%s\n' "$C_RED" "$C_RESET"
    exit 2
elif ((WARNINGS > 0)); then
    printf '%sResult: REVIEW WARNINGS%s\n' "$C_YELLOW" "$C_RESET"
    exit 1
else
    printf '%sResult: HEALTHY%s\n' "$C_GREEN" "$C_RESET"
    exit 0
fi
