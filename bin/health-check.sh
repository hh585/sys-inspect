#!/usr/bin/env bash
#
# health-check.sh - 单机深度巡检：负载、内存、磁盘、inode、大文件、删除未释放、服务
#
set -uo pipefail

# ===== 阈值 =====
DISK_WARN=80
DISK_CRIT=90
INODE_WARN=80
INODE_CRIT=90
MEM_WARN=80
MEM_CRIT=90
LOAD_WARN=4.0
LOAD_CRIT=8.0

# ===== 磁盘满排查参数 =====
BIGFILE_SIZE_MB=500
BIGFILE_TOPN=5
DU_TOPN=8
LOG_BIGFILE_SIZE_MB=50
DELETED_TOPN=5

BIGFILE_SCAN_DIRS="/var /tmp /home /data /opt"
EXCLUDE_FSTYPES="tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|overlay|squashfs|nsfs|ramfs"

warnings=0
criticals=0
report=""

add_line() { report+="$1"$'\n'; }

mark() {
    local level="$1" msg="$2"
    if [[ "$level" == "CRIT" ]]; then
        criticals=$((criticals + 1))
    elif [[ "$level" == "WARN" ]]; then
        warnings=$((warnings + 1))
    fi
    add_line "[$level] $msg"
}

human() {
    numfmt --to=iec "$1" 2>/dev/null || echo "$1"
}

add_line "========== Health Check $(date '+%Y-%m-%d %H:%M:%S') =========="
add_line "Hostname: $(hostname)"
add_line "Uptime:   $(uptime -p 2>/dev/null || uptime)"
add_line ""

# ---------- 1. 负载 ----------
load1=$(awk '{print $1}' /proc/loadavg)
if (( $(echo "$load1 >= $LOAD_CRIT" | bc -l) )); then
    mark CRIT "Load(1m): ${load1} (threshold ${LOAD_CRIT})"
elif (( $(echo "$load1 >= $LOAD_WARN" | bc -l) )); then
    mark WARN "Load(1m): ${load1} (threshold ${LOAD_WARN})"
else
    add_line "[OK]   Load(1m): ${load1}"
fi

# ---------- 2. 内存 ----------
mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
mem_used_pct=$(awk -v t="$mem_total" -v a="$mem_avail" 'BEGIN {printf "%.1f", (t-a)/t*100}')
if (( $(echo "$mem_used_pct >= $MEM_CRIT" | bc -l) )); then
    mark CRIT "Memory used: ${mem_used_pct}% (threshold ${MEM_CRIT}%)"
elif (( $(echo "$mem_used_pct >= $MEM_WARN" | bc -l) )); then
    mark WARN "Memory used: ${mem_used_pct}% (threshold ${MEM_WARN}%)"
else
    add_line "[OK]   Memory used: ${mem_used_pct}%"
fi

# ---------- 3. 所有本地分区使用率 ----------
add_line ""
add_line "--- Disk Usage (per filesystem) ---"
full_mounts=()

while read -r fs type size used avail pcent mount; do
    [[ -z "${pcent:-}" ]] && continue
    if (( pcent >= DISK_CRIT )); then
        mark CRIT "Disk ${mount} (${type}) used: ${pcent}% (threshold ${DISK_CRIT}%)"
        full_mounts+=("$mount")
    elif (( pcent >= DISK_WARN )); then
        mark WARN "Disk ${mount} (${type}) used: ${pcent}% (threshold ${DISK_WARN}%)"
        full_mounts+=("$mount")
    else
        add_line "[OK]   Disk ${mount} (${type}) used: ${pcent}%"
    fi
done < <(df -PT 2>/dev/null | awk -v re="$EXCLUDE_FSTYPES" '
    NR>1 && $2 !~ re {
        gsub(/%/, "", $6);
        print $1, $2, $3, $4, $5, $6, $7
    }')

# ---------- 4. inode 使用率 ----------
add_line ""
add_line "--- Inode Usage (per filesystem) ---"

while read -r fs type inodes iused ifree ipcent mount; do
    [[ -z "${ipcent:-}" ]] && continue
    if (( ipcent >= INODE_CRIT )); then
        mark CRIT "Inode ${mount} (${type}) used: ${ipcent}% (threshold ${INODE_CRIT}%)"
    elif (( ipcent >= INODE_WARN )); then
        mark WARN "Inode ${mount} (${type}) used: ${ipcent}% (threshold ${INODE_WARN}%)"
    else
        add_line "[OK]   Inode ${mount} (${type}) used: ${ipcent}%"
    fi
done < <(df -iPT 2>/dev/null | awk -v re="$EXCLUDE_FSTYPES" '
    NR>1 && $2 !~ re {
        gsub(/%/, "", $6);
        print $1, $2, $3, $4, $5, $6, $7
    }')

# ---------- 5. 超阈值分区 du 下钻 ----------
if (( ${#full_mounts[@]} > 0 )); then
    add_line ""
    add_line "--- Top Directories on Full Filesystems ---"
    for mnt in "${full_mounts[@]}"; do
        add_line "  [$mnt]"
        while read -r kbytes path; do
            add_line "       $(human $((kbytes * 1024)))  $path"
        done < <(du -x --max-depth=1 "$mnt" 2>/dev/null | sort -rn | head -n "$DU_TOPN")
    done
fi

# ---------- 6. 大文件 Top N ----------
add_line ""
add_line "--- Top ${BIGFILE_TOPN} Files > ${BIGFILE_SIZE_MB}MB (scanned dirs) ---"

bigfile_found=0
while IFS=$'\t' read -r size path; do
    [[ -z "${path:-}" ]] && continue
    bigfile_found=1
    add_line "       $(human "$size")  $path"
done < <(
    for dir in $BIGFILE_SCAN_DIRS; do
        [[ -d "$dir" ]] || continue
        find "$dir" -xdev -type f -size +${BIGFILE_SIZE_MB}M \
            -printf '%s\t%p\n' 2>/dev/null
    done | sort -rn | head -n "$BIGFILE_TOPN"
)
(( bigfile_found == 0 )) && add_line "       (none)"

# ---------- 7. /var/log 大日志 ----------
add_line ""
add_line "--- Top 5 Log Files > ${LOG_BIGFILE_SIZE_MB}MB in /var/log ---"

log_found=0
while IFS=$'\t' read -r size path; do
    [[ -z "${path:-}" ]] && continue
    log_found=1
    add_line "       $(human "$size")  $path"
done < <(
    find /var/log -xdev -type f -size +${LOG_BIGFILE_SIZE_MB}M \
        -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 5
)
(( log_found == 0 )) && add_line "       (none)"

# ---------- 8. 已删除但未释放 ----------
add_line ""
add_line "--- Deleted Files Still Held Open (Top ${DELETED_TOPN}) ---"

deleted_found=0
while IFS=$'\t' read -r size comm pid name; do
    [[ -z "${name:-}" ]] && continue
    deleted_found=1
    add_line "       $(human "$size")  PID=$pid  $comm  $name"
done < <(
    lsof +L1 2>/dev/null \
        | awk 'NR>1 && $7 ~ /^[0-9]+$/ {
            name=$9;
            for (i=10; i<=NF; i++) name=name" "$i;
            print $7"\t"$1"\t"$2"\t"name
        }' \
        | sort -rn | head -n "$DELETED_TOPN"
)
(( deleted_found == 0 )) && add_line "       (none)"

# ---------- 9. 关键服务 ----------
add_line ""
add_line "--- Services ---"

SERVICES_TO_CHECK="sshd chronyd"
for svc in $SERVICES_TO_CHECK; do
    if ! systemctl list-unit-files --type=service 2>/dev/null \
            | awk '{print $1}' | grep -qx "${svc}.service"; then
        add_line "[SKIP] Service ${svc} not installed"
        continue
    fi
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    if [[ "$state" == "active" ]]; then
        add_line "[OK]   Service ${svc}: active"
    else
        mark CRIT "Service ${svc}: ${state:-unknown}"
    fi
done

# ---------- 10. 失败单元 ----------
add_line ""
add_line "--- Failed systemd Units ---"

failed_units=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $1}')
if [[ -n "$failed_units" ]]; then
    mark CRIT "Failed units detected:"
    while IFS= read -r unit; do
        [[ -n "$unit" ]] && add_line "       - $unit"
    done <<< "$failed_units"
else
    add_line "[OK]   No failed systemd units"
fi

# ---------- 汇总 ----------
add_line ""
add_line "========== Summary: WARN=${warnings}, CRIT=${criticals} =========="

printf '%s\n' "$report"

if (( criticals > 0 )); then
    exit 2
elif (( warnings > 0 )); then
    exit 1
else
    exit 0
fi
