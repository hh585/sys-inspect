#!/usr/bin/env bash
#
# inspect-node.sh - 单机采集 CPU/内存/磁盘/服务，输出一行 | 分隔数据
#
# 输出: hostname|ip|cores|load1|cpu_pct|mem_total_mb|mem_used_mb|mem_pct|disk_root_pct|disk_data_pct|services|status
#
set -uo pipefail

SERVICES="${INSPECT_SERVICES:-sshd}"
WARN="${INSPECT_WARN:-80,80,80}"
CRIT="${INSPECT_CRIT:-90,90,90}"

while getopts ":s:w:c:" opt; do
    case "$opt" in
        s) SERVICES="$OPTARG" ;;
        w) WARN="$OPTARG" ;;
        c) CRIT="$OPTARG" ;;
        *) ;;
    esac
done

IFS=',' read -r CPU_WARN MEM_WARN DISK_WARN <<< "$WARN"
IFS=',' read -r CPU_CRIT MEM_CRIT DISK_CRIT <<< "$CRIT"

hostname_=$(hostname)
ip_=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$ip_" ]] && ip_="127.0.0.1"

cores_=$(nproc)
load1_=$(awk '{print $1}' /proc/loadavg)

read -r t1 i1 < <(awk '/^cpu / {print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)
sleep 1
read -r t2 i2 < <(awk '/^cpu / {print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)
dt=$((t2 - t1))
di=$((i2 - i1))
if (( dt > 0 )); then
    cpu_pct_=$(( (100 * (dt - di)) / dt ))
else
    cpu_pct_=0
fi

mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
mem_total_mb=$((mem_total_kb / 1024))
mem_used_mb=$(( (mem_total_kb - mem_avail_kb) / 1024 ))
if (( mem_total_kb > 0 )); then
    mem_pct_=$(( 100 * (mem_total_kb - mem_avail_kb) / mem_total_kb ))
else
    mem_pct_=0
fi

disk_root_pct_=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
[[ -z "$disk_root_pct_" ]] && disk_root_pct_=0

disk_data_pct_="-"
if mountpoint -q /data 2>/dev/null; then
    disk_data_pct_=$(df -P /data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
fi

services_str=""
for svc in ${SERVICES//,/ }; do
    [[ -z "$svc" ]] && continue
    if ! systemctl list-unit-files --type=service 2>/dev/null \
            | awk '{print $1}' | grep -qx "${svc}.service"; then
        state="missing"
    else
        state=$(systemctl is-active "$svc" 2>/dev/null || true)
        [[ -z "$state" ]] && state="unknown"
    fi
    [[ -n "$services_str" ]] && services_str+=","
    services_str+="${svc}:${state}"
done
[[ -z "$services_str" ]] && services_str="-"

status="OK"

check() {
    local val="$1" w="$2" c="$3"
    [[ "$val" == "-" ]] && return 0
    if (( val >= c )); then
        status="CRIT"
    elif (( val >= w )) && [[ "$status" != "CRIT" ]]; then
        status="WARN"
    fi
}

check "$cpu_pct_" "$CPU_WARN" "$CPU_CRIT"
check "$mem_pct_" "$MEM_WARN" "$MEM_CRIT"
check "$disk_root_pct_" "$DISK_WARN" "$DISK_CRIT"
[[ "$disk_data_pct_" != "-" ]] && check "$disk_data_pct_" "$DISK_WARN" "$DISK_CRIT"

if [[ "$services_str" == *":failed"* || "$services_str" == *":inactive"* ]]; then
    status="CRIT"
fi

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$hostname_" "$ip_" "$cores_" "$load1_" "$cpu_pct_" \
    "$mem_total_mb" "$mem_used_mb" "$mem_pct_" \
    "$disk_root_pct_" "$disk_data_pct_" "$services_str" "$status"
