# 设计说明

本文记录 sys-inspect 的架构决策和关键取舍。不是使用文档，而是回答“为什么这么设计”。

## 1. 背景与问题

运维巡检有两个典型场景：

1. **单机故障定位**：一台机器报警，需要回答“磁盘为什么满、哪个目录大、哪个文件还在被写”。
2. **多机日常巡检**：早上到工位，需要快速知道 50 台机器有没有异常。

这两个场景需求相反：前者要**深**，后者要**快**。用一个脚本硬扛，要么批量时慢得不可接受，要么单机时查得不够深。

## 2. 设计目标

- 单机模式能完整回答磁盘满的原因，包括“已删除未释放”这种隐蔽问题。
- 批量模式能在可接受时间内扫完几十台机器，单台失败不影响整体。
- 两种模式共享状态语义和退出码，方便统一接监控。
- 单机模式的 service 即使脚本被篡改，也不能写文件系统。

## 3. 核心决策：分两层

### 3.1 为什么 `du` 和 `lsof +L1` 不进批量模式

- `du -x /` 在根分区有几十万文件时可能跑几十秒。50 台机器同时跑，对共享存储和监控系统的 IO 压力不可控。
- `lsof +L1` 要遍历 `/proc` 下所有进程的 fd，单机可接受，并发时开销叠加。
- 批量模式的目标是“快速发现异常”，不是“定位异常原因”。发现问题后，再对单台跑深度模式。

### 3.2 为什么单机模式不做 SSH 分发

单机模式由 systemd timer 在本机调度，不依赖控制端。原因：

- 故障机器可能 SSH 不可达，但 timer 仍能本地执行。
- 不需要维护主机列表和密钥分发。
- 日志留在本机 journald，故障复盘时直接看。

### 3.3 两层如何共享语义

`health-check.sh` 和 `inspect-node.sh` 都输出 `OK` / `WARN` / `CRIT` / `FAIL`，退出码都是 `0/1/2`。监控接入时不需要区分模式，直接看 `ExecMainStatus` 或命令退出码。

## 4. 关键取舍

### 4.1 service 用 root 而不是 nobody

**初始方案**：`User=nobody`，看起来更安全。

**问题**：`lsof +L1` 读其他进程的 `/proc/PID/fd` 需要 `CAP_SYS_PTRACE`，读任意文件需要 `CAP_DAC_READ_SEARCH`，`nobody` 都没有。测试时 Deleted Files 段永远是 `(none)`。

**最终方案**：

```ini
User=root
CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ProtectSystem=strict
ProtectHome=read-only
NoNewPrivileges=yes
```

**理由**：巡检的本质是**只读诊断**，需要看到全系统信息。正确做法不是降权到无法工作，而是用 root 身份 + 最小 capability + 只读文件系统。

- `CapabilityBoundingSet` 只留两个：读进程、读文件。
- `ProtectSystem=strict`：整个文件系统只读，即使脚本被篡改也无法写入。
- `NoNewPrivileges=yes`：禁止通过 SUID 等方式提权。

**效果**：有 root 身份读信息，但没有写文件系统的能力，也没有多余特权。

### 4.2 不开 `PrivateTmp`

**初始方案**：`PrivateTmp=yes`，给服务独立 `/tmp` 命名空间。

**问题**：脚本要扫描宿主机 `/tmp` 大文件，私有命名空间导致永远扫不到。

**最终方案**：不开 `PrivateTmp`，在 README 和 service 注释中说明原因。

**理由**：这是安全配置和功能需求的冲突。巡检需要看到宿主机真实 `/tmp`，这是功能前提。`ProtectSystem=strict` 已经保证脚本不能写 `/tmp`，风险可控。

### 4.3 用 systemd timer 而不是 cron

| 对比项 | cron | systemd timer |
|---|---|---|
| 日志 | 需自己重定向 | 自动进 journald |
| 关机补跑 | 不支持 | `Persistent=true` |
| 随机延迟 | 需脚本实现 | `RandomizedDelaySec` |
| 沙箱 | 无 | 完整支持 |
| 查看下次执行 | `crontab -l` 看不出 | `systemctl list-timers` |

**理由**：新项目优先 timer。cron 仍适合简单场景，但 timer 在可观测性和安全性上明显更好。

### 4.4 批量模式用 SSH + xargs 而不是 Ansible

**理由**：

- 零依赖：目标机器不需要 Python，不需要装 Ansible。
- 可审计：一个 `batch-inspect.sh` 读完就知道全部逻辑。
- 足够用：巡检是只读操作，不需要 Ansible 的幂等和模块体系。

**后续扩展**：如果机器规模超过 200 台，或需要复杂编排，再引入 Ansible 版本。

### 4.5 CPU 采样 1 秒

**理由**：批量模式追求总时长。1 秒采样在 50 台机器上增加约 1 秒总时长，可接受。如果改成 5 秒，总时长增加 5 秒，收益不大。

**代价**：瞬时值不如长采样准，可能错过短时峰值。单机深度模式不采 CPU 使用率，只看 load，避免了这个问题。

### 4.6 输出 `|` 分隔而不是 JSON

**理由**：

- `|` 在路径中极少出现，解析安全。
- 一行一台机器，`awk -F'|'` 直接处理，不需要 `jq`。
- CSV 转换只需 `sed 's/|/,/g'`。

**代价**：字段顺序固定，扩展字段要改解析代码。可接受，因为字段集稳定。

## 5. 数据流

### 5.1 单机深度模式

```text
timer (08:00)
  └── service (oneshot, root + 最小能力集)
        └── health-check.sh
              ├── 读 /proc/loadavg, /proc/meminfo
              ├── df -PT, df -iPT
              ├── 条件触发 du -x, find -xdev
              ├── lsof +L1
              └── stdout → journald
```

### 5.2 多机批量模式

```text
batch-inspect.sh
  ├── 读 hosts.txt
  ├── xargs -P N
  │     └── 每台: timeout ssh "bash -s" < inspect-node.sh
  │           └── inspect-node.sh → 一行 | 分隔数据
  ├── 汇总到终端表格
  └── 可选 CSV
```

## 6. 扩展性考虑

- **接 Prometheus**：在脚本末尾把 WARN/CRIT 计数写到 textfile collector 目录。
- **接告警**：批量模式退出码 2 时，由 CI 或 cron 包装脚本发通知。
- **加检查项**：单机模式在脚本中加函数，保持 `mark` 和 `add_line` 的调用风格。
- **Ansible 版本**：`inspect-node.sh` 可以直接作为 Ansible `script` 模块的目标，无需重写。

## 7. 已知取舍的代价

| 取舍 | 代价 | 缓解 |
|---|---|---|
| root + 最小能力集 | 依赖 systemd 沙箱支持 | 老版本 systemd 降级为 `ProtectHome=no` |
| 不开 PrivateTmp | 与宿主机共享 `/tmp` | `ProtectSystem=strict` 保证只读 |
| 批量不查 inode | 批量模式看不到 inode 满 | 发现问题后跑单机模式 |
| CPU 1 秒采样 | 瞬时值可能错过峰值 | 单机模式看 load，不看 CPU% |
| `|` 分隔 | 字段顺序固定 | 字段集稳定，扩展时改解析 |
