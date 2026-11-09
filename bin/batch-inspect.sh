#!/usr/bin/env bash
#
# batch-inspect.sh - 多机批量巡检，SSH 并发执行 inspect-node.sh 并汇总
#
set -euo pipefail

HOSTS_FILE=""
SERVICES="sshd"
PARALLEL=5
TIMEOUT=15
OUT_CSV=""
REMOTE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/inspect-node.sh"
TMP_DIR=""

usage() {
    cat <<EOF
用法: $0 -H hosts.txt [选项]

  -H FILE     主机列表文件（必填）
  -s SVCS     检查的服务，逗号分隔，默认 sshd
  -P N        并发数，默认 5
  -T SEC      SSH 超时秒数，默认 15
  -S FILE     远程单机脚本路径
  -o FILE     输出 CSV
  -h          帮助
EOF
    exit 0
}

while getopts ":H:s:P:T:S:o:h" opt; do
    case "$opt" in
        H) HOSTS_FILE="$OPTARG" ;;
        s) SERVICES="$OPTARG" ;;
        P) PARALLEL="$OPTARG" ;;
        T) TIMEOUT="$OPTARG" ;;
        S) REMOTE_SCRIPT="$OPTARG" ;;
        o) OUT_CSV="$OPTARG" ;;
        h) usage ;;
        \?) echo "未知选项: -$OPTARG" >&2; exit 1 ;;
        :)  echo "选项 -$OPTARG 需要参数" >&2; exit 1 ;;
    esac
done

[[ -n "$HOSTS_FILE" ]] || { echo "错误: 必须指定 -H hosts 文件" >&2; exit 1; }
[[ -f "$HOSTS_FILE" ]] || { echo "错误: hosts 文件不存在: $HOSTS_FILE" >&2; exit 1; }
[[ -f "$REMOTE_SCRIPT" ]] || { echo "错误: 单机脚本不存在: $REMOTE_SCRIPT" >&2; exit 1; }

TMP_DIR=$(mktemp -d /tmp/batch-inspect.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

HOSTS_CLEAN="$TMP_DIR/hosts.txt"
grep -vE '^\s*(#|$)' "$HOSTS_FILE" | sed 's/[[:space:]]*$//' > "$HOSTS_CLEAN"

host_count=$(wc -l < "$HOSTS_CLEAN")
[[ "$host_count" -gt 0 ]] || { echo "错误: hosts 文件无有效主机" >&2; exit 1; }

echo "=== 批量巡检开始 ==="
echo "主机数: $host_count  并发: $PARALLEL  超时: ${TIMEOUT}s  服务: $SERVICES"
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo

run_one() {
    local host="$1"
    local safe out err rc reason
    safe=$(echo "$host" | tr -c 'a-zA-Z0-9._-' '_')
    out="$TMP_DIR/${safe}.out"
    err="$TMP_DIR/${safe}.err"

    if timeout "$TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            "$host" "bash -s -- -s '$SERVICES'" < "$REMOTE_SCRIPT" \
            > "$out" 2> "$err"; then
        :
    else
        rc=$?
        reason=$(tail -1 "$err" 2>/dev/null | tr '|' '/' | cut -c1-60)
        [[ -z "$reason" ]] && reason="ssh failed (rc=$rc)"
        printf '%s|%s|-|-|-|-|-|-|-|-|-|FAIL\n' "$host" "$reason" > "$out"
    fi
}

export -f run_one
export TMP_DIR SERVICES TIMEOUT

xargs -a "$HOSTS_CLEAN" -P "$PARALLEL" -I {} bash -c 'run_one "$@"' _ {}

echo "--- 巡检结果 ---"
printf '%-22s %-16s %6s %8s %6s %6s %8s %10s %-40s %s\n' \
    "HOST" "IP" "CPU%" "MEM%" "MEM(MB)" "DISK%" "DATA%" "LOAD" "SERVICES" "STATUS"

ok=0; warn=0; crit=0; fail=0

for f in "$TMP_DIR"/*.out; do
    [[ -f "$f" ]] || continue
    IFS='|' read -r hn ip cores load1 cpup ct cm mp dr dp svcs st <<< "$(cat "$f")"

    if [[ "$st" == "FAIL" ]]; then
        printf '%-22s %-16s %6s %8s %6s %6s %8s %10s %-40s %s\n' \
            "$hn" "$ip" "-" "-" "-" "-" "-" "-" "-" "FAIL"
        fail=$((fail + 1))
        continue
    fi

    svcs_short="$svcs"
    (( ${#svcs_short} > 38 )) && svcs_short="${svcs_short:0:35}..."

    printf '%-22s %-16s %6s %8s %6s %6s %8s %10s %-40s %s\n' \
        "$hn" "$ip" "$cpup" "$mp" "$cm" "$dr" "$dp" "$load1" "$svcs_short" "$st"

    case "$st" in
        OK)   ok=$((ok + 1)) ;;
        WARN) warn=$((warn + 1)) ;;
        CRIT) crit=$((crit + 1)) ;;
    esac
done

echo
echo "--- 统计 ---"
echo "OK: $ok  WARN: $warn  CRIT: $crit  FAIL: $fail  总计: $((ok + warn + crit + fail))"

if [[ -n "$OUT_CSV" ]]; then
    {
        echo "hostname,ip,cores,load1,cpu_pct,mem_total_mb,mem_used_mb,mem_pct,disk_root_pct,disk_data_pct,services,status"
        for f in "$TMP_DIR"/*.out; do
            [[ -f "$f" ]] || continue
            cat "$f"
        done
    } | sed 's/|/,/g' > "$OUT_CSV"
    echo
    echo "CSV 已写入: $OUT_CSV"
fi

echo "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"

if (( crit > 0 || fail > 0 )); then
    exit 2
elif (( warn > 0 )); then
    exit 1
fi
exit 0
