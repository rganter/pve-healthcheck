#!/usr/bin/env bash
set -uo pipefail

# Read-only health check for Proxmox VE hosts.
# Exit codes: 0 = OK, 1 = warnings, 2 = critical findings.

LOOKBACK_HOURS=24
USE_COLOR=1
WARNINGS=0
CRITICALS=0
CHECK_MODE=""
backup_rows=""

CHECKS=(host services cluster ha memory arc zfs storage iscsi backups reboots logs)

usage() {
    cat <<'EOF'
Usage: pve-healthcheck.sh [--all | --menu | --check NAME] [--hours N] [--no-color] [--help]

Performs read-only checks for:
  - Proxmox version, failed services, cluster quorum and HA
  - RAM, swap and ZFS ARC configuration
  - ZFS pool and Proxmox storage status
  - active and stale iSCSI records
  - completed and failed vzdump backup tasks
  - reboots and possible causes from the previous boot journal
  - recent OOM, watchdog, kernel stall and i915 messages

Exit codes: 0 healthy, 1 warnings, 2 critical findings.

Checks: host, services, cluster, ha, memory, arc, zfs, storage, iscsi,
        backups, reboots, logs

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

if ((USE_COLOR)) && [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=''; C_YELLOW=''; C_GREEN=''; C_BLUE=''; C_CYAN=''; C_DIM=''
    C_BOLD=''; C_RESET=''
fi

valid_check() {
    local wanted=$1 check
    for check in "${CHECKS[@]}"; do
        [[ $wanted == "$check" ]] && return 0
    done
    return 1
}

show_menu() {
    local choice
    while :; do
        printf '\n%s%s+----------------------------------------------------------+%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
        printf '%s%s|                    PVE HEALTHCHECK                       |%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
        printf '%s%s+----------------------------------------------------------+%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
        printf '  %sRead-only diagnostics for Proxmox VE%s\n' "$C_DIM" "$C_RESET"
        printf '  Analysis period: %s%s hour(s)%s\n\n' "$C_CYAN" "$LOOKBACK_HOURS" "$C_RESET"

        printf '  %s%sFULL CHECK%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        printf '  %s[ 1]%s  Complete health check\n\n' "$C_GREEN" "$C_RESET"

        printf '  %s%sINDIVIDUAL CHECKS%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
        printf '  %s[ 2]%s  %-25s %s[ 8]%s  %s\n' "$C_CYAN" "$C_RESET" 'Host information' "$C_CYAN" "$C_RESET" 'ZFS pools'
        printf '  %s[ 3]%s  %-25s %s[ 9]%s  %s\n' "$C_CYAN" "$C_RESET" 'Failed systemd services' "$C_CYAN" "$C_RESET" 'Proxmox storages'
        printf '  %s[ 4]%s  %-25s %s[10]%s  %s\n' "$C_CYAN" "$C_RESET" 'Cluster and quorum' "$C_CYAN" "$C_RESET" 'iSCSI'
        printf '  %s[ 5]%s  %-25s %s[11]%s  %s\n' "$C_CYAN" "$C_RESET" 'High availability' "$C_CYAN" "$C_RESET" 'Backup details and error logs'
        printf '  %s[ 6]%s  %-25s %s[12]%s  %s\n' "$C_CYAN" "$C_RESET" 'Memory and swap' "$C_CYAN" "$C_RESET" 'Reboots and possible causes'
        printf '  %s[ 7]%s  %-25s %s[13]%s  %s\n\n' "$C_CYAN" "$C_RESET" 'ZFS ARC' "$C_CYAN" "$C_RESET" 'Recent critical log patterns'

        printf '  %s[ 0]%s  Exit\n\n' "$C_DIM" "$C_RESET"
        printf '  %sSelection:%s ' "$C_BOLD" "$C_RESET"
        read -r choice
        case $choice in
            1) CHECK_MODE=all; break ;;
            2) CHECK_MODE=host; break ;;
            3) CHECK_MODE=services; break ;;
            4) CHECK_MODE=cluster; break ;;
            5) CHECK_MODE=ha; break ;;
            6) CHECK_MODE=memory; break ;;
            7) CHECK_MODE=arc; break ;;
            8) CHECK_MODE=zfs; break ;;
            9) CHECK_MODE=storage; break ;;
            10) CHECK_MODE=iscsi; break ;;
            11) CHECK_MODE=backups; break ;;
            12) CHECK_MODE=reboots; break ;;
            13) CHECK_MODE=logs; break ;;
            0) exit 0 ;;
            *) printf '\n  %sInvalid selection: %s. Please choose 0-13.%s\n' "$C_RED" "$choice" "$C_RESET" ;;
        esac
    done
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
memory_some_avg10=""
memory_full_avg10=""
if [[ -r /proc/pressure/memory ]]; then
    memory_some_avg10=$(awk '/^some / {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub(/^avg10=/, "", $i); print $i}}' /proc/pressure/memory)
    memory_full_avg10=$(awk '/^full / {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub(/^avg10=/, "", $i); print $i}}' /proc/pressure/memory)
fi

swap_in_kib=0
swap_out_kib=0
if have vmstat; then
    swap_sample=$(vmstat 1 2 2>/dev/null | tail -n 1 || true)
    read -r swap_in_kib swap_out_kib < <(awk '{print $7, $8}' <<<"$swap_sample")
    [[ $swap_in_kib =~ ^[0-9]+$ ]] || swap_in_kib=0
    [[ $swap_out_kib =~ ^[0-9]+$ ]] || swap_out_kib=0
fi
swap_active=0
((swap_in_kib + swap_out_kib >= 1024)) && swap_active=1

memory_pressure_elevated=0
memory_pressure_critical=0
if [[ -n $memory_some_avg10 ]] && awk -v value="$memory_some_avg10" 'BEGIN {exit !(value >= 1)}'; then
    memory_pressure_elevated=1
fi
if [[ -n $memory_full_avg10 ]] && awk -v value="$memory_full_avg10" 'BEGIN {exit !(value >= 1)}'; then
    memory_pressure_elevated=1
fi
if [[ -n $memory_full_avg10 ]] && awk -v value="$memory_full_avg10" 'BEGIN {exit !(value >= 10)}'; then
    memory_pressure_critical=1
fi

memory_context="PSI some=${memory_some_avg10:-unknown}% full=${memory_full_avg10:-unknown}%, swap-in=${swap_in_kib} KiB/s swap-out=${swap_out_kib} KiB/s"
if ((avail_pct < 5 || memory_pressure_critical)); then
    crit "Memory pressure is critical: ${avail_pct}% RAM available; $memory_context"
elif ((avail_pct < 10 || swap_active || (avail_pct < 20 && memory_pressure_elevated))); then
    warn "Memory pressure requires attention: ${avail_pct}% RAM available; $memory_context"
elif ((avail_pct < 20)); then
    info "RAM headroom is reduced (${avail_pct}% available), but no current memory pressure was detected; $memory_context"
else
    ok "${avail_pct}% of RAM is available; no current memory pressure detected"
fi

swap_total_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
swap_free_kib=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
if ((swap_total_kib == 0)); then
    warn "No swap is configured"
else
    swap_used_pct=$(( (swap_total_kib - swap_free_kib) * 100 / swap_total_kib ))
    if ((swap_used_pct >= 75 && swap_active)); then
        warn "Swap usage is ${swap_used_pct}% with active swap I/O"
    elif ((swap_used_pct >= 75)); then
        info "Swap usage is ${swap_used_pct}%, but no current swap I/O was detected"
    else
        ok "Swap usage is ${swap_used_pct}%"
    fi
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
    done < <(printf '%s\n' "$storage_output" | awk '
        $1 == "Name" && $2 == "Type" && $3 == "Status" { in_table=1; next }
        in_table && NF >= 3 { print $1, $3 }
    ')
fi
if [[ -r /proc/pressure/io ]]; then
    io_full_avg10=$(awk '/^full / {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub(/^avg10=/, "", $i); print $i}}' /proc/pressure/io)
    io_full_avg60=$(awk '/^full / {for (i=1; i<=NF; i++) if ($i ~ /^avg60=/) {sub(/^avg60=/, "", $i); print $i}}' /proc/pressure/io)
    if [[ -n $io_full_avg10 ]] && awk -v value="$io_full_avg10" 'BEGIN {exit !(value >= 10)}'; then
        warn "High full I/O pressure: avg10=${io_full_avg10}% avg60=${io_full_avg60:-unknown}%"
    elif [[ -n $io_full_avg10 ]] && awk -v value="$io_full_avg10" 'BEGIN {exit !(value >= 1)}'; then
        info "Elevated full I/O pressure: avg10=${io_full_avg10}% avg60=${io_full_avg60:-unknown}%"
    else
        ok "No current full I/O pressure (avg10=${io_full_avg10:-unknown}%)"
    fi
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
backup_error=""
backup_page_limit=500

if ! backup_nodes_json=$(pvesh get /nodes --output-format json 2>&1); then
    backup_error=$backup_nodes_json
    backup_nodes=""
else
    backup_nodes=$(perl -MJSON::PP -0777 -e '
        my $nodes = eval { decode_json(<STDIN>) };
        exit 1 if $@ || ref($nodes) ne "ARRAY";
        for my $node (@$nodes) {
            print(($node->{node} // ""), "\n");
        }
    ' <<<"$backup_nodes_json" 2>/dev/null || true)
    [[ -n $backup_nodes ]] || backup_error="Proxmox returned no readable node list"
fi

while IFS= read -r backup_node; do
    [[ -n $backup_node ]] || continue
    backup_page_start=0

    while :; do
        if ! backup_page_json=$(pvesh get "/nodes/$backup_node/tasks" \
            --start "$backup_page_start" --limit "$backup_page_limit" \
            --output-format json 2>&1); then
            backup_error+="${backup_error:+; }node $backup_node: $backup_page_json"
            break
        fi

        backup_page_count=$(perl -MJSON::PP -0777 -e '
            my $tasks = eval { decode_json(<STDIN>) };
            exit 1 if $@ || ref($tasks) ne "ARRAY";
            print scalar(@$tasks);
        ' <<<"$backup_page_json" 2>/dev/null || true)

        backup_page_oldest=$(perl -MJSON::PP -0777 -e '
            my $tasks = eval { decode_json(<STDIN>) };
            exit 1 if $@ || ref($tasks) ne "ARRAY";
            my @times = map { defined($_->{starttime}) ? $_->{starttime} : () } @$tasks;
            @times = sort { $a <=> $b } @times;
            print($times[0] // 0);
        ' <<<"$backup_page_json" 2>/dev/null || true)

        backup_page_rows=$(perl -MJSON::PP -0777 -e '
            my $since = shift;
            my $tasks = eval { decode_json(<STDIN>) };
            exit 1 if $@ || ref($tasks) ne "ARRAY";
            for my $task (@$tasks) {
                next if ($task->{type} // "") ne "vzdump";
                next if ($task->{starttime} // 0) < $since;
                next if !defined($task->{endtime}) || !defined($task->{status});
                my @values = map { defined($_) ? $_ : "" }
                    @{$task}{qw(status node id user starttime upid)};
                s/[|\r\n]/ /g for @values;
                print join("|", @values), "\n";
            }
        ' "$backup_since_epoch" <<<"$backup_page_json" 2>/dev/null || true)

        if [[ ! $backup_page_count =~ ^[0-9]+$ ]]; then
            backup_error+="${backup_error:+; }node $backup_node returned an unreadable task list"
            break
        fi
        [[ -n $backup_page_rows ]] && backup_rows+="${backup_page_rows}"$'\n'
        [[ $backup_page_oldest =~ ^[0-9]+$ ]] && \
            ((backup_page_oldest < backup_since_epoch)) && break
        ((backup_page_count < backup_page_limit)) && break
        backup_page_start=$((backup_page_start + backup_page_limit))
    done
done <<<"$backup_nodes"

backup_rows=${backup_rows%$'\n'}

if [[ -n $backup_error && -z $backup_rows ]]; then
    warn "Unable to retrieve backup task history: $backup_error"
else
    [[ -n $backup_error ]] && warn "Backup task history is incomplete: $backup_error"

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
            display_status=$status
            [[ $status != OK ]] && display_status="FAILED ($status)"
            printf '  %-28s node=%-15s guest=%-8s started=%s user=%s\n' \
                "$display_status" "$node" "${guest:--}" "$started" "${user:--}"
        done <<<"$backup_rows"

        if ((backup_failed > 0)); then
            printf '\nLogs of failed backup tasks:\n'
            while IFS='|' read -r status node guest user starttime upid; do
                [[ -n $upid && $status != OK ]] || continue
                printf '\n--- node=%s guest=%s status=%s ---\n' "$node" "${guest:--}" "$status"
                if have pvenode; then
                    if ! pvenode task log "$upid" 2>&1; then
                        warn "Unable to retrieve complete task log: $upid"
                    fi
                else
                    warn "pvenode is not installed; unable to retrieve complete task log: $upid"
                fi
            done <<<"$backup_rows"
        fi
    fi
fi
fi

if should_run reboots; then
section "Reboots and possible causes"
lookback_start_epoch=$(date -d "$LOG_PERIOD_START" +%s)
reboot_count=0

boot_start_epoch() {
    local boot_index=$1 first_entry
    first_entry=$(journalctl -b "$boot_index" -o json --no-pager 2>/dev/null | sed -n '1{p;q;}' || true)
    [[ -n $first_entry ]] || return 1
    perl -MJSON::PP -e '
        my $entry = eval { decode_json(<STDIN>) };
        exit 1 if $@ || !defined($entry->{__REALTIME_TIMESTAMP});
        print int($entry->{__REALTIME_TIMESTAMP} / 1000000);
    ' <<<"$first_entry" 2>/dev/null
}

for ((boot_index=0; boot_index>=-20; boot_index--)); do
    current_boot_start=$(boot_start_epoch "$boot_index" || true)
    [[ $current_boot_start =~ ^[0-9]+$ ]] || break
    ((current_boot_start >= lookback_start_epoch)) || break

    reboot_count=$((reboot_count + 1))
    previous_boot_index=$((boot_index - 1))
    reboot_time=$(date -d "@$current_boot_start" --iso-8601=seconds 2>/dev/null || printf '%s' "$current_boot_start")
    previous_window_start=$(date -d "@$((current_boot_start - 900))" --iso-8601=seconds 2>/dev/null || true)
    current_boot_scan_end=$(date -d "@$((current_boot_start + 300))" --iso-8601=seconds 2>/dev/null || true)
    previous_boot_log=$(journalctl -b "$previous_boot_index" --since "$previous_window_start" \
        --no-pager -o short-iso 2>/dev/null || true)
    previous_host_log=$(
        {
            journalctl -b "$previous_boot_index" --since "$previous_window_start" \
                _PID=1 --no-pager -o short-iso 2>/dev/null || true
            journalctl -b "$previous_boot_index" --since "$previous_window_start" \
                -k --no-pager -o short-iso 2>/dev/null || true
        }
    )
    if [[ -z $previous_boot_log ]]; then
        previous_boot_log=$(journalctl -b "$previous_boot_index" -n 500 --no-pager -o short-iso 2>/dev/null || true)
        previous_host_log=$(
            {
                journalctl -b "$previous_boot_index" -n 500 _PID=1 --no-pager -o short-iso 2>/dev/null || true
                journalctl -b "$previous_boot_index" -k -n 500 --no-pager -o short-iso 2>/dev/null || true
            }
        )
    fi
    current_boot_unclean_log=$(journalctl -b "$boot_index" --until "$current_boot_scan_end" --no-pager -o short-iso \
        --grep='corrupt|uncleanly shut down' 2>/dev/null || true)
    unclean_journal=0
    grep -Eqi 'journal.*(corrupt|uncleanly shut down)|corrupted or uncleanly shut down' <<<"$current_boot_unclean_log" && unclean_journal=1

    printf '\nReboot at: %s\n' "$reboot_time"
    if [[ -z $previous_boot_log ]]; then
        warn "Previous boot journal is unavailable; reboot cause cannot be determined"
        continue
    fi

    reboot_reason=""
    reboot_pattern=""
    if grep -Eqi 'watchdog-mux.*client .*watchdog expired - disable watchdog updates' <<<"$previous_boot_log"; then
        reboot_reason="Proxmox HA watchdog client expired; node self-fencing/reset detected"
        reboot_pattern='watchdog-mux.*client .*watchdog (is about to expire|expired)|watchdog-mux.*active connections|watchdog.*did not stop'
    elif grep -Eqi 'kernel panic|panic - not syncing' <<<"$previous_boot_log"; then
        reboot_reason="Kernel panic detected before reboot"
        reboot_pattern='kernel panic|panic - not syncing'
    elif grep -Eqi 'watchdog.*(timeout|reset|lockup|expired|did not stop)|soft lockup|hard lockup' <<<"$previous_boot_log"; then
        reboot_reason="Watchdog timeout or kernel lockup detected before reboot"
        reboot_pattern='watchdog.*(timeout|reset|lockup|expired|did not stop)|soft lockup|hard lockup'
    elif grep -Eqi 'out of memory|oom-killer|killed process' <<<"$previous_boot_log"; then
        reboot_reason="Out-of-memory event detected before reboot"
        reboot_pattern='out of memory|oom-killer|killed process'
    elif grep -Eqi 'critical temperature|temperature above threshold|thermal.*shutdown' <<<"$previous_boot_log"; then
        reboot_reason="Critical temperature or thermal shutdown detected before reboot"
        reboot_pattern='critical temperature|temperature above threshold|thermal.*shutdown'
    elif grep -Eqi 'blk_update_request|Buffer I/O error|end_request: I/O error|nvme.*(I/O error|timeout|reset)|EXT4-fs error|ZFS.*(FAULTED|SUSPENDED)|nfs: server .* not responding' <<<"$previous_boot_log"; then
        reboot_reason="Storage or I/O errors detected before reboot"
        reboot_pattern='blk_update_request|Buffer I/O error|end_request: I/O error|nvme.*(I/O error|timeout|reset)|EXT4-fs error|ZFS.*(FAULTED|SUSPENDED)|nfs: server .* not responding'
    elif grep -Eqi 'systemd-shutdown|reboot: Restarting system|Reached target (reboot|power-off|shutdown)\.target|Shutting down|System Reboot|System Power Off' <<<"$previous_host_log"; then
        reboot_reason="Clean shutdown or planned reboot recorded"
        reboot_pattern='systemd-shutdown|reboot: Restarting system|Reached target (reboot|power-off|shutdown)\.target|Shutting down|System Reboot|System Power Off'
    fi

    if [[ $reboot_reason == "Clean shutdown or planned reboot recorded" ]]; then
        ok "$reboot_reason"
    elif [[ -n $reboot_reason ]]; then
        warn "$reboot_reason"
    else
        if ((unclean_journal)); then
            warn "No orderly shutdown found; the next boot reports an unclean journal (possible crash, watchdog reset, or power loss)"
        else
            warn "No orderly shutdown or clear cause found; possible crash, reset, or power loss"
        fi
    fi

    if [[ -n $reboot_pattern ]]; then
        info "Relevant journal entries from the previous boot:"
        if [[ $reboot_reason == "Clean shutdown or planned reboot recorded" ]]; then
            grep -Ei "$reboot_pattern" <<<"$previous_host_log" | tail -n 5 | sed 's/^/  /'
        else
            grep -Ei "$reboot_pattern" <<<"$previous_boot_log" | tail -n 5 | sed 's/^/  /'
        fi
    else
        info "Last journal entries from the previous boot:"
        tail -n 5 <<<"$previous_boot_log" | sed 's/^/  /'
    fi

    if [[ -n ${backup_rows:-} ]]; then
        local_node=$(hostname -s 2>/dev/null || hostname)
        while IFS='|' read -r status node guest user starttime upid; do
            [[ -n $upid && $status != OK && $node == "$local_node" && $starttime =~ ^[0-9]+$ ]] || continue
            backup_reboot_delta=$((current_boot_start - starttime))
            if ((backup_reboot_delta >= 0 && backup_reboot_delta <= 900)); then
                backup_started=$(date -d "@$starttime" --iso-8601=seconds 2>/dev/null || printf '%s' "$starttime")
                info "Temporal correlation: failed vzdump for guest ${guest:--} started at $backup_started (${backup_reboot_delta}s before this boot)"
            fi
        done <<<"$backup_rows"
    fi
done

if ((reboot_count == 0)); then
    ok "No reboot detected in the last ${LOOKBACK_HOURS} hour(s)"
else
    info "Detected $reboot_count reboot(s) in the last ${LOOKBACK_HOURS} hour(s)"
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
Proxmox HA self-fencing|watchdog-mux.*client .*watchdog expired - disable watchdog updates
Proxmox HA loop delay / watchdog near-expiry|pve-ha-(crm|lrm).*loop took too long|watchdog-mux.*client .*watchdog (is about to expire|was updated before expiring)
Watchdog / kernel panic|watchdog.*(reset|timeout|did not stop)|kernel panic
Storage / NFS I/O errors|blk_update_request|Buffer I/O error|end_request: I/O error|nvme.*(I/O error|timeout|reset)|EXT4-fs error|ZFS.*(FAULTED|SUSPENDED)|nfs: server .* not responding
Corosync link / token loss|corosync.*(link: .* is down|Token has not been received|processor failed|quorum.*lost|lost.*quorum)
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
