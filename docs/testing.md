# 测试规范

本文定义 sys-inspect 的测试步骤和验收标准。每个测试都有前置条件、执行命令、预期结果。

## 0. 测试环境

### 0.1 单机深度模式

- Linux + systemd
- root 或 sudo 权限
- 已安装 `lsof`、`bc`、`coreutils`、`findutils`、`procps`、`util-linux`

### 0.2 多机批量模式

- 控制端：bash 4.0+、`ssh`、`xargs`、`timeout`
- 被控端：Linux、`systemctl`、`/proc` 可读
- 控制端到被控端 SSH 免密

```bash
# 验证免密
ssh -o BatchMode=yes localhost "hostname"
```

### 0.3 测试前检查

```bash
for c in df du find awk sort head systemctl journalctl lsof bc numfmt ssh xargs timeout; do
    command -v "$c" >/dev/null || echo "MISSING: $c"
done
```

无输出表示齐全。

## 1. 单机深度模式测试

### T1.1 基础执行

**目的**：验证脚本能完整执行并输出报告。

```bash
sudo ./bin/health-check.sh; echo "exit=$?"
```

**预期**：

- 输出包含 `Load`、`Memory`、`Disk Usage`、`Inode Usage`、`Top Files`、`Deleted Files`、`Services`、`Failed Units` 各段。
- 正常机器退出码为 `0`。
- 报告末尾有 `Summary: WARN=x, CRIT=y`。

### T1.2 大文件告警

**目的**：验证 `find -xdev -size +500M` 能发现大文件。

```bash
# 造 600MB 文件
sudo dd if=/dev/zero of=/var/tmp/test-big.img bs=1M count=600 status=none

# 执行
sudo ./bin/health-check.sh | grep -A6 "Top 5 Files"

# 清理
sudo rm -f /var/tmp/test-big.img
```

**预期**：输出包含 `/var/tmp/test-big.img`，大小约 `600M`。

### T1.3 已删除未释放

**目的**：验证 `lsof +L1` 能发现“`rm` 了但空间没释放”的文件。

```bash
# 造 200MB 文件并持有 fd，然后删除
sudo dd if=/dev/zero of=/var/tmp/deleted.img bs=1M count=200 status=none
sudo bash -c 'exec 3>/var/tmp/deleted.img; rm -f /var/tmp/deleted.img; sleep 300' &

# 执行
sudo ./bin/health-check.sh | grep -A6 "Deleted Files"

# 清理
sudo pkill -f "sleep 300"
```

**预期**：输出包含 `deleted.img`，大小约 `200M`，带 `PID` 和进程名。

**说明**：这是本项目最关键的测试。如果 `lsof +L1` 段为空，说明 service 权限不足（如用了 `nobody`）。

### T1.4 阈值告警与退出码

**目的**：验证阈值触发和退出码语义。

```bash
# 临时下调磁盘阈值
sudo sed -i 's/^DISK_WARN=80/DISK_WARN=1/' bin/health-check.sh

# 执行
sudo ./bin/health-check.sh > /tmp/hc.out; echo "exit=$?"

# 恢复
sudo sed -i 's/^DISK_WARN=1/DISK_WARN=80/' bin/health-check.sh
```

**预期**：

- `/tmp/hc.out` 包含 `[WARN] Disk / used: ...`。
- `exit=1`。

CRIT 测试同理，把 `DISK_CRIT=90` 改成 `1`，预期 `exit=2`。

### T1.5 systemd 集成

**目的**：验证 service 和 timer 部署后正常工作。

```bash
sudo cp bin/health-check.sh /usr/local/bin/
sudo cp systemd/health-check.service systemd/health-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now health-check.timer

# 查看 timer
systemctl list-timers | grep health-check
systemctl status health-check.timer

# 手动触发
sudo systemctl start health-check.service
journalctl -u health-check.service --since "1 min ago"
```

**预期**：

- `list-timers` 显示下次触发时间。
- `status` 显示 `active (waiting)`。
- `journalctl` 能看到完整报告。

### T1.6 沙箱配置验证

**目的**：确认安全加固生效。

```bash
systemctl show health-check.service \
  -p ProtectSystem \
  -p ProtectHome \
  -p CapabilityBoundingSet \
  -p NoNewPrivileges
```

**预期**：

```text
ProtectSystem=strict
ProtectHome=read-only
CapabilityBoundingSet=cap_sys_ptrace cap_dac_read_search
NoNewPrivileges=yes
```

### T1.7 关机补跑

**目的**：验证 `Persistent=true`。

```bash
# 临时把 timer 改成 1 分钟后触发
sudo systemctl edit health-check.timer
# 写入：
# [Timer]
# OnCalendar=
# OnCalendar=*-*-* HH:MM:00   # 改成 1 分钟后
# Persistent=true

sudo systemctl daemon-reload
sudo systemctl restart health-check.timer

# 在触发时间前关机或停 timer
sudo systemctl stop health-check.timer

# 等过触发时间后重新启动
sudo systemctl start health-check.timer

# 检查是否补跑
journalctl -u health-check.service --since "10 min ago" | head
```

**预期**：开机后 service 补跑了一次，日志时间接近启动时间而不是原定触发时间。

测试完记得恢复 timer 配置。

## 2. 多机批量模式测试

### T2.1 单机采集器

**目的**：验证 `inspect-node.sh` 输出格式正确。

```bash
./bin/inspect-node.sh -s "sshd,cron"
```

**预期**：

- 输出一行，`|` 分隔，共 12 个字段。
- 字段依次为：hostname、ip、cores、load1、cpu_pct、mem_total_mb、mem_used_mb、mem_pct、disk_root_pct、disk_data_pct、services、status。
- status 为 `OK`、`WARN` 或 `CRIT`。

示例：

```text
web01|10.0.0.11|4|0.35|12|7983|3541|44|62|-|sshd:active,cron:active|OK
```

### T2.2 本地批量成功

**目的**：验证批量调度器能对 localhost 正常巡检。

```bash
echo "localhost" > /tmp/hosts.txt
./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -P 1; echo "exit=$?"
```

**预期**：

- 输出表格，localhost 一行，STATUS 为 `OK`。
- 统计行 `OK: 1  WARN: 0  CRIT: 0  FAIL: 0`。
- `exit=0`（假设 sshd 正常）。

### T2.3 失败隔离

**目的**：验证一台 SSH 失败不影响其他机器。

```bash
printf 'localhost\nno-such-host-xyz\n' > /tmp/hosts.txt
./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -P 2; echo "exit=$?"
```

**预期**：

- localhost 正常，STATUS 为 `OK`。
- `no-such-host-xyz` 标记 `FAIL`，SERVICES 列为 `-`。
- 统计行 `FAIL: 1`。
- `exit=2`（有 FAIL）。

### T2.4 CSV 输出

**目的**：验证 CSV 格式和字段完整。

```bash
printf 'localhost\nno-such-host-xyz\n' > /tmp/hosts.txt
./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -o /tmp/report.csv

head -1 /tmp/report.csv
cat /tmp/report.csv
awk -F, '$NF != "OK"' /tmp/report.csv
```

**预期**：

- 第一行是表头：`hostname,ip,cores,load1,cpu_pct,mem_total_mb,mem_used_mb,mem_pct,disk_root_pct,disk_data_pct,services,status`。
- 数据行字段数与表头一致。
- `awk` 过滤出非 OK 行。

### T2.5 阈值自定义

**目的**：验证 `-w` 和 `-c` 参数生效。

```bash
# 单机：把 CPU 警告阈值设为 0，必然触发 WARN
./bin/inspect-node.sh -s "sshd" -w "0,80,80" -c "90,90,90"
```

**预期**：status 为 `WARN`（CPU% >= 0）。

### T2.6 并发压力

**目的**：验证并发控制和超时。

```bash
# 造 10 台主机（其中 5 台不存在）
{
    for i in 1 2 3 4 5; do echo "localhost"; done
    for i in 1 2 3 4 5; do echo "no-such-host-$i"; done
} > /tmp/hosts.txt

time ./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -P 5; echo "exit=$?"
```

**预期**：

- 5 台 localhost 成功，5 台不存在的主机 FAIL。
- 总耗时在 `timeout * 2` 以内（两批并发）。
- `exit=2`。

## 3. 回归测试清单

每次改动脚本后，至少跑一遍：

- [ ] T1.1 基础执行，退出码 0
- [ ] T1.2 大文件告警能触发
- [ ] T1.3 删除未释放能触发
- [ ] T1.4 阈值告警退出码正确
- [ ] T1.6 沙箱配置未变
- [ ] T2.1 单机采集器输出 12 字段
- [ ] T2.2 本地批量成功
- [ ] T2.3 失败隔离
- [ ] T2.4 CSV 字段完整

## 4. 故障排查表

| 现象 | 可能原因 | 排查命令 |
|---|---|---|
| `lsof: command not found` | 未安装 lsof | `sudo apt install lsof` |
| `bc: command not found` | 未安装 bc | `sudo apt install bc` |
| Deleted Files 永远 `(none)` | service 用了 `nobody` 或 `CapabilityBoundingSet` 缺 `CAP_SYS_PTRACE` | `systemctl show health-check.service -p CapabilityBoundingSet -p User` |
| `/tmp` 大文件扫不到 | 开了 `PrivateTmp=yes` | `systemctl show health-check.service -p PrivateTmp` |
| 批量模式所有主机 FAIL | SSH 免密未配置 | `ssh -o BatchMode=yes host "hostname"` |
| 批量模式部分主机 FAIL | 目标机 sshd 未运行或网络不通 | `ssh -v host "hostname"` |
| `df -PT` 字段错位 | BusyBox 的 df 不支持 `-T` | `df --version`，确认 GNU coreutils |
| `ProtectHome=read-only` 报错 | systemd 版本老 | `systemctl --version`，改 `ProtectHome=no` |
| timer 不触发 | 未 enable 或未 daemon-reload | `systemctl list-timers | grep health-check` |
| service 显示 failed 但报告正常 | 退出码 1 或 2 是预期行为 | `systemctl show health-check.service -p ExecMainStatus` |

## 5. 测试记录模板

每次发布前填写：

| 测试项 | 日期 | 执行人 | 结果 | 备注 |
|---|---|---|---|---|
| T1.1 基础执行 | | | | |
| T1.2 大文件告警 | | | | |
| T1.3 删除未释放 | | | | |
| T1.4 阈值告警 | | | | |
| T1.6 沙箱验证 | | | | |
| T2.1 采集器输出 | | | | |
| T2.2 本地批量 | | | | |
| T2.3 失败隔离 | | | | |
| T2.4 CSV 输出 | | | | |
