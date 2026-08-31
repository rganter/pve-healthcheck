#!/usr/bin/env bash
set -uo pipefail

# Read-only incident collector for Proxmox watchdog-mux client timeouts.

OUTPUT_DIR=${PVE_WATCHDOG_DIAG_DIR:-/var/log/pve-watchdog-diagnostics}
COOLDOWN_SECONDS=${PVE_WATCHDOG_DIAG_COOLDOWN:-30}

usage() {
    cat <<'EOF'
Usage: pve-watchdog-diagnose [--watch | --capture PID [MESSAGE]]

  --watch                 Follow watchdog-mux and capture an incident when a
                          client watchdog is about to expire (default)
  --capture PID [MESSAGE] Create a diagnostic capture immediately

Environment:
  PVE_WATCHDOG_DIAG_DIR       Output directory
  PVE_WATCHDOG_DIAG_COOLDOWN  Minimum seconds between captures (default: 30)
EOF
}

section() {
    printf '\n== %s ==\n' "$1"
}

run_limited() {
    local seconds=$1
    shift
    printf '\n$'
    printf ' %q' "$@"
    printf '\n'
    timeout "$seconds" "$@" 2>&1 || printf '[command exited or timed out: %s]\n' "$?"
}

capture_incident() {
    local client_pid=$1 event=${2:-manual capture}
    local stamp incident_dir report proc_file

    stamp=$(date '+%Y%m%dT%H%M%S%z')
    incident_dir="$OUTPUT_DIR/${stamp}-pid${client_pid}"
    mkdir -p "$incident_dir"
    chmod 0700 "$incident_dir"
    report="$incident_dir/report.txt"

    {
        printf 'PVE watchdog diagnostic capture\n'
        printf 'Captured: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'Hostname: %s\n' "$(hostname -f 2>/dev/null || hostname)"
        printf 'Trigger PID: %s\n' "$client_pid"
        printf 'Trigger: %s\n' "$event"

        section "Immediate client state"
        if [[ -d /proc/$client_pid ]]; then
            ps -o pid,ppid,user,stat,ni,pri,psr,pcpu,pmem,etime,wchan:40,cmd -p "$client_pid" 2>&1 || true
            for proc_file in status wchan syscall stack sched io cgroup; do
                printf '\n-- /proc/%s/%s --\n' "$client_pid" "$proc_file"
                timeout 1 cat "/proc/$client_pid/$proc_file" 2>&1 || true
            done
            printf '\n-- /proc/%s/fd --\n' "$client_pid"
            timeout 1 ls -l "/proc/$client_pid/fd" 2>&1 || true
        else
            printf 'PID %s no longer exists\n' "$client_pid"
        fi

        section "System pressure"
        for proc_file in cpu io memory; do
            printf '\n-- /proc/pressure/%s --\n' "$proc_file"
            cat "/proc/pressure/$proc_file" 2>&1 || true
        done

        section "Recent relevant journal"
        run_limited 4 journalctl --since "2 minutes ago" --no-pager -o short-iso \
            -u watchdog-mux -u pve-ha-crm -u pve-ha-lrm -u corosync -u pve-cluster

        # Persist the time-critical evidence before slower supplementary checks.
        sync -f "$report" 2>/dev/null || sync

        run_limited 4 vmstat 1 3
        run_limited 2 free -h
        run_limited 2 uptime

        section "Processes and blocked tasks"
        run_limited 3 ps axo pid,ppid,user,stat,ni,pri,psr,pcpu,pmem,etime,wchan:40,comm,args
        run_limited 2 sh -c "ps axo pid,ppid,stat,wchan:40,comm,args | awk '\$3 ~ /D/ || /pve-ha|pmxcfs|corosync|vzdump/'"

        section "HA and cluster"
        run_limited 3 systemctl status --no-pager watchdog-mux pve-ha-crm pve-ha-lrm corosync pve-cluster
        run_limited 3 pvecm status
        run_limited 2 corosync-cfgtool -s

        section "Network"
        run_limited 2 ip -s link
        run_limited 2 ip route show table all
        run_limited 2 ss -s

        section "Storage"
        run_limited 3 pvesm status
        run_limited 2 zpool status -x
        run_limited 2 df -hT

        section "Recent kernel journal"
        run_limited 5 journalctl -k --since "2 minutes ago" --no-pager -o short-iso
    } >"$report" 2>&1

    logger -t pve-watchdog-diagnose "diagnostic capture saved to $incident_dir"
    printf '%s\n' "$incident_dir"
}

watch_events() {
    local line client_pid now last_capture=0

    mkdir -p "$OUTPUT_DIR"
    chmod 0700 "$OUTPUT_DIR"
    logger -t pve-watchdog-diagnose "watching watchdog-mux; output directory: $OUTPUT_DIR"

    journalctl -f -n 0 -u watchdog-mux.service -o cat --no-pager | while IFS= read -r line; do
        [[ $line =~ client.*\(PID\ [0-9]+\).*watchdog\ is\ about\ to\ expire ]] || continue
        client_pid=$(sed -n 's/.*client (PID \([0-9][0-9]*\)).*/\1/p' <<<"$line")
        [[ $client_pid =~ ^[0-9]+$ ]] || continue
        now=$(date +%s)
        ((now - last_capture >= COOLDOWN_SECONDS)) || continue
        last_capture=$now
        capture_incident "$client_pid" "$line"
    done
}

umask 077

case ${1:---watch} in
    --watch)
        (($# <= 1)) || { usage >&2; exit 2; }
        watch_events
        ;;
    --capture)
        [[ ${2:-} =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
        capture_incident "$2" "${3:-manual capture}"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
