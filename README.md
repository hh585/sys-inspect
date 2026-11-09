# sys-inspect

Linux 系统巡检工具，提供两种执行尺度：

- **单机深度模式**：systemd oneshot service + timer 每日调度，实现完整磁盘满排查链，带安全沙箱，结果统一输出到 journald。
- **多机批量模式**：SSH 并发快速采集多台机器的 CPU、内存、磁盘、服务状态，输出终端表格和 CSV。

两种模式共享 `OK` / `WARN` / `CRIT` / `FAIL` 状态语义和 `0/1/2` 退出码，但深度和开销不同：单机模式查得深，批量模式查得快。

## 为什么分两层

巡检不是一种场景：

| 场景 | 需求 | 对应模式 |
|---|---|---|
| 一台机器报警，定位原因 | 查得深，回答“哪个目录、哪个文件、哪个进程” | 单机深度模式 |
| 早上扫 50 台机器 | 查得快，一台失败不影响其他 | 多机批量模式 |
| CI 发布后自动跑 | 有退出码语义，能自动判断 | 两种模式都支持 |

只有单机模式，扫 50 台要串行 SSH；只有批量模式，磁盘满了只知道“满了”不知道“为什么满”。两层互补，不是重复。详细设计决策见 [docs/design.md](docs/design.md)。

## 架构

```text
                    ┌─────────────────────────────┐
                    │        sys-inspect          │
                    └─────────────┬───────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              │                                       │
     ┌────────▼────────┐                     ┌────────▼────────┐
     │   单机深度模式    │                     │   多机批量模式    │
     │ health-check.sh │                     │ batch-inspect.sh │
     │ + systemd timer │                     │ + SSH + xargs -P │
     └────────┬────────┘                     └────────┬────────┘
              │                                       │
              │                              ┌────────▼────────┐
              │                              │ inspect-node.sh │
              │                              │  （远程端采集）  │
              │                              └─────────────────┘
              │
     ┌────────▼────────┐
     │ 磁盘满排查链     │
     │ df → df -i →    │
     │ du → find →     │
     │ lsof +L1        │
     └─────────────────┘
```

## 功能对比

| 能力 | 单机深度 | 多机批量 |
|---|---|---|
| 负载 / 内存 | ✅ | ✅ |
| 分区使用率 | ✅ 所有本地分区 | ✅ `/` 和 `/data` |
| inode 使用率 | ✅ | ❌ |
| du 下钻 Top 目录 | ✅ 仅超阈值触发 | ❌ |
| 大文件 Top N | ✅ 限定目录 + `-xdev` | ❌ |
| /var/log 大日志 | ✅ | ❌ |
| lsof +L1 删除未释放 | ✅ | ❌ |
| 关键服务状态 | ✅ | ✅ |
| 失败 systemd 单元 | ✅ | ❌ |
| SSH 并发调度 | ❌ | ✅ |
| 失败主机隔离 | — | ✅ 标记 FAIL 不中断 |
| 输出 | journald 详细报告 | 终端表格 + CSV |
| 调度 | systemd timer | 人工 / cron / CI |
| 安全加固 | 沙箱 + 最小能力集 | 依赖 SSH 权限 |

## 环境要求

### 单机深度模式

- Linux + systemd
- bash 4.0+
- `lsof`、`bc`、`coreutils`、`findutils`、`procps`、`util-linux`

```bash
# Debian / Ubuntu
sudo apt install -y lsof bc coreutils findutils procps util-linux

# RHEL / Rocky / Alma / CentOS
sudo dnf install -y lsof bc coreutils findutils procps-ng util-linux
```

### 多机批量模式

- 控制端：bash 4.0+、`ssh`、`xargs`、`timeout`、`mktemp`
- 被控端：Linux、`systemctl`、`/proc` 可读
- 控制端到所有被控端已配置 SSH 密钥免密

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id user@host1
ssh-copy-id user@host2

# 验证免密
ssh -o BatchMode=yes user@host1 "hostname"
```

## 快速开始

### 单机深度模式

```bash
git clone https://github.com/lxy/sys-inspect.git
cd sys-inspect

sudo chmod 755 bin/health-check.sh
sudo cp bin/health-check.sh /usr/local/bin/
sudo cp systemd/health-check.service systemd/health-check.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now health-check.timer

# 手动触发一次
sudo systemctl start health-check.service
journalctl -u health-check.service --no-pager --since today
```

### 多机批量模式

```bash
chmod 755 bin/inspect-node.sh bin/batch-inspect.sh

# 准备主机列表
cp examples/hosts.txt hosts.txt
# 编辑 hosts.txt 填入真实主机

# 批量巡检
./bin/batch-inspect.sh -H hosts.txt -s "sshd,nginx,mysqld" -P 10

# 输出 CSV
./bin/batch-inspect.sh -H hosts.txt -s "sshd,nginx" -P 10 -o report.csv
```

## 单机深度模式详解

### 磁盘满排查链

按运维排障顺序实现：

```text
1. df -PT          所有本地分区使用率（排除 tmpfs/overlay/proc 等）
2. df -iPT         inode 使用率（独立告警线）
3. du -x           仅超阈值分区触发，下钻 Top 8 目录
4. find -xdev      指定目录大文件 Top 5（不扫 /）
5. find /var/log   日志大文件 Top 5
6. lsof +L1        已删除但被进程持有的文件
```

第 6 步是最经典的坑：`rm` 了一个 10G 日志，`df` 还是满的，因为写日志的进程还持有 fd。只有重启进程或 `: > /proc/PID/fd/N` 才能释放。

**性能设计**：正常机器上只有第 1、2 步执行；`du` 和 `find` 只在分区超阈值时触发，定时任务不会拖慢系统。

### 安全加固

service 以 root 运行，但通过以下配置收紧权限：

```ini
User=root
CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
```

| 配置 | 原因 |
|---|---|
| `User=root` | `lsof +L1` 读其他进程 `/proc/PID/fd` 需要 `CAP_SYS_PTRACE` |
| `CapabilityBoundingSet=` 只留两个 | 巡检只需要读进程和文件，其余能力全部丢弃 |
| `ProtectSystem=strict` | 文件系统只读，即使脚本被篡改也无法写入 |
| `ProtectHome=read-only` | `/home` 只读可见，因为要扫大文件 |
| 不开 `PrivateTmp` | 需要扫描宿主机 `/tmp`，私有命名空间会导致漏扫 |

效果：**有 root 身份读系统信息，但没有写文件系统的能力，也没有多余特权。**

### 退出码语义

| 退出码 | 含义 | systemd 状态 |
|---|---|---|
| 0 | 全部 OK | success |
| 1 | 有 WARN | failed (exit-code 1) |
| 2 | 有 CRIT | failed (exit-code 2) |

接入监控时直接看 `ExecMainStatus`，不需要解析日志文本。

### 阈值配置

所有阈值在 `bin/health-check.sh` 顶部：

```bash
DISK_WARN=80        DISK_CRIT=90
INODE_WARN=80       INODE_CRIT=90
MEM_WARN=80         MEM_CRIT=90
LOAD_WARN=4.0       LOAD_CRIT=8.0
BIGFILE_SIZE_MB=500
LOG_BIGFILE_SIZE_MB=50
```

按业务调整后 `systemctl restart health-check.timer` 即可。

### timer 配置

```ini
[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true
RandomizedDelaySec=120
AccuracySec=1min
```

- `Persistent=true`：关机错过时间后开机补跑
- `RandomizedDelaySec=120`：多机随机延迟，避免同时触发
- `AccuracySec=1min`：允许 1 分钟精度，降低系统唤醒频率

## 多机批量模式详解

### 两层架构

- `inspect-node.sh`：单机采集器，输出一行 `|` 分隔的结构化数据，可独立使用
- `batch-inspect.sh`：批量调度器，读主机列表，SSH 并发执行采集器，汇总结果

### 并发与失败隔离

```bash
xargs -a hosts.txt -P 10 -I {} bash -c 'run_one "$@"' _ {}
```

- `-P 10`：最多 10 个并发 SSH
- 每台用 `timeout 15 ssh ...` 兜底，单台卡住不拖垮整体
- 失败主机写 `FAIL` 行，不影响其他机器
- **建议并发不超过主机数的 1/3**，避免 SSH 连接风暴

### 输出示例

```text
HOST              IP            CPU%   MEM%  DISK%   LOAD  SERVICES                       STATUS
web01             10.0.0.11      12     45    62      0.35  sshd:active,nginx:active       OK
web02             10.0.0.12      38     72    85      1.20  sshd:active,nginx:active       WARN
db01              10.0.0.21      91     88    93      4.80  sshd:active,mysqld:inactive    CRIT
web03             10.0.0.13      -      -     -       -     -                              FAIL

--- 统计 ---
OK: 1  WARN: 1  CRIT: 1  FAIL: 1  总计: 4
```

### 输出字段说明

| 字段 | 含义 |
|---|---|
| HOST | 主机名（被控端 `hostname` 输出） |
| IP | 第一个非回环 IP |
| CPU% | 1 秒采样 CPU 使用率 |
| MEM% | 内存使用率（`MemTotal - MemAvailable` / `MemTotal`） |
| MEM(MB) | 已用内存，MB |
| DISK% | `/` 使用率 |
| DATA% | `/data` 使用率，无该挂载点为 `-` |
| LOAD | 1 分钟负载 |
| SERVICES | `服务名:状态` 列表，状态为 `active/inactive/failed/missing` |
| STATUS | `OK/WARN/CRIT/FAIL` |

### 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 全部 OK |
| 1 | 有 WARN |
| 2 | 有 CRIT 或 FAIL |

适合在 CI 里用：

```bash
./bin/batch-inspect.sh -H hosts.txt -s "sshd" -P 10 -o report.csv \
  || echo "巡检发现异常，查看 report.csv"
```

### 自定义阈值

```bash
# 单机：CPU/内存/磁盘 警告阈值 70/70/70，严重阈值 85/85/85
./bin/inspect-node.sh -w "70,70,70" -c "85,85,85"

# 批量：通过环境变量传给所有被控端
INSPECT_WARN="70,70,70" INSPECT_CRIT="85,85,85" \
  ./bin/batch-inspect.sh -H hosts.txt -s "sshd"
```

## 定时执行

### cron

见 `examples/cron.txt`：

```cron
# 每天 08:30 批量巡检，CSV 按日期归档
30 8 * * * cd /opt/sys-inspect && ./bin/batch-inspect.sh -H hosts.txt -s "sshd,nginx" -P 10 -o /var/log/inspect/report-$(date +\%F).csv >> /var/log/inspect/cron.log 2>&1
```

### systemd timer

单机模式已自带 `systemd/health-check.timer`。批量模式如需 systemd 调度，可仿照编写：

```ini
[Unit]
Description=Daily Batch Inspect

[Service]
Type=oneshot
WorkingDirectory=/opt/sys-inspect
ExecStart=/opt/sys-inspect/bin/batch-inspect.sh -H hosts.txt -s "sshd,nginx" -P 10 -o /var/log/inspect/report.csv

[Timer]
OnCalendar=*-*-* 08:30:00
Persistent=true
```

## 测试

完整测试规范见 [docs/testing.md](docs/testing.md)。快速验证：

```bash
# 单机模式
sudo ./bin/health-check.sh; echo "exit=$?"

# 单机采集器
./bin/inspect-node.sh -s "sshd"

# 批量模式（需 ssh localhost 免密）
echo "localhost" > /tmp/hosts.txt
./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -P 1

# 失败隔离
printf 'localhost\nno-such-host-xyz\n' > /tmp/hosts.txt
./bin/batch-inspect.sh -H /tmp/hosts.txt -s "sshd" -P 2
```

## 已知限制

- **单机模式不参与批量**：`du` 和 `lsof +L1` 在多机并发场景下开销不可控，批量模式只做浅层采集。
- **批量模式不查 inode**：需要 inode 检查用单机深度模式。
- **批量模式依赖 SSH 免密**：未配置密钥会导致所有主机 FAIL。
- **CPU 采样 1 秒**：批量模式追求速度，CPU 使用率是瞬时值，不如长采样准。要更准可改 `sleep 1` 为 `sleep 5`，但会拖慢批量总时长。
- **`ProtectHome=read-only` 需要较新 systemd**：老版本不支持时改成 `ProtectHome=no`。
- **批量模式不查 `/var/log`**：日志大文件检查只在单机模式做。

## 目录结构

```text
sys-inspect/
├── README.md
├── LICENSE
├── bin/
│   ├── health-check.sh        # 单机深度巡检
│   ├── inspect-node.sh        # 单机采集器（批量远程端）
│   └── batch-inspect.sh       # 多机批量调度器
├── systemd/
│   ├── health-check.service
│   └── health-check.timer
├── examples/
│   ├── hosts.txt
│   └── cron.txt
└── docs/
    ├── design.md              # 架构与设计取舍
    └── testing.md             # 测试规范
```

## License

[MIT](LICENSE)
