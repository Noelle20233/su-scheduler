# Su Scheduler — 生命周期接入层（P1-10）

> **任务**：P1-10 · 安全接入 daemon 和 service 生命周期
> **依赖**：P1-06（Canonical Task Registry）、P1-09（Runtime State & Event Log）
> **性质**：把新的 Task 基础安全接入现有 daemon / `service.sh`，**保留可恢复
> 性**，不删除现有 daemon 自保能力，不创建第二个独立调度循环。
> **实现位置**：`tests/lifecycle/lib.sh`（生命周期原语）、`tests/lifecycle/test.sh`
> （回归）、`tests/lifecycle/README.md`、本文档。
> **日期**：2026-09-01

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [镜像语义对照表](#2-镜像语义对照表)
3. [单实例锁](#3-单实例锁)
4. [启动初始化序列](#4-启动初始化序列)
5. [僵尸清理与崩溃恢复](#5-僵尸清理与崩溃恢复)
6. [停止与重启](#6-停止与重启)
7. [service.sh 兼容（看护单轮）](#7-servicesh-兼容看护单轮)
8. [目录与权限](#8-目录与权限)
9. [最后有效配置快照（fail-safe）](#9-最后有效配置快照fail-safe)
10. [失败语义与约束](#10-失败语义与约束)
11. [接线边界（非目标）](#11-接线边界非目标)
12. [验收标准对照](#12-验收标准对照)

---

## 1. 目的与范围

- **现状**：daemon（`su-schedulerd`）拥有单实例锁、启动僵尸清理、每分钟扫描
  等自保能力（L544-602）；`service.sh` 拥有 FBE 等待 + 60s 看护循环（L51-78）。
  新的 Task 基础（P1-06 registry、P1-09 状态/事件）尚未接入这些生命周期点。
- **目的（P1-10）**：
  1. 提供可由 daemon / service.sh 直接调用的生命周期原语（锁、僵尸清理、
     启动初始化、停止/重启、看护单轮）；
  2. **保留可恢复性**：stale 锁可恢复、崩溃后任务不永久 RUNNING、配置损坏
     回退到最后有效快照；
  3. 遵守约束：不创建第二个独立调度循环；不删除现有 daemon 自保能力；
     不因新模块初始化失败而无限重启；配置错误 fail-safe；任务执行失败不
     终止 daemon。
- **范围**：测试域实现（`tests/lifecycle/`），不改 daemon / service.sh 生产
  代码；文档给出接线点。验收五项全部由 `tests/lifecycle/test.sh` 断言。

## 2. 镜像语义对照表

| 本层原语 | 镜像生产语义（文件行号） |
| :--- | :--- |
| `lifecycle_lock_alive` | `service.sh` L60-65（锁存在 + pid 非空 + `/proc/<pid>` 可见） |
| `lifecycle_lock_acquire` | daemon 写锁 `echo $$`（L576）+ stale 清理（L562）；**活锁拒绝**（单实例） |
| `lifecycle_lock_force_reclaim` | daemon L546-562（等待窗 ≤5s 轮询 → 超时无条件 `rm` + 写） |
| `lifecycle_lock_release` | daemon/CLI 释放锁（`rm -f`） |
| `lifecycle_ensure_dirs` | daemon L41-45（`mkdir -p tasks/shells/audit`；0755） |
| `lifecycle_cleanup_zombies` | daemon L564-573（RUNNING → `ZOMBIE_CRASHED`）+ P1-09 再水合（`state.txt`→FAILED + 事件） |
| `lifecycle_start` | daemon 启动序列（目录→锁→僵尸清理→配置快照） |
| `lifecycle_stop` | CLI stop（kill 锁内 pid + 释放锁） |
| `lifecycle_restart` | CLI restart（stop → sleep 1 → `nohup` 新 daemon） |
| `lifecycle_watchdog_tick` | `service.sh` L56-76 的**单轮**看护判定 |

## 3. 单实例锁

```
lifecycle_lock_acquire <lockfile>    # 0=已获取($$) 1=已有存活实例(拒绝) 2=写失败
lifecycle_lock_alive    <lockfile>   # 0=存活 1=无锁或 stale
lifecycle_lock_force_reclaim <lockfile>  # 等待窗后无条件接管（镜像 daemon）
lifecycle_lock_release  <lockfile>   # rm -f
```

- **判定**：`[ -f lock ] && pid 非空 && /proc/<pid> 可见` → alive（service.sh
  语义）。
- **stale 恢复**：锁内 pid 已死 → `acquire` 自动清理重建（验收：stale lock
  能恢复）。
- **强接管**：`force_reclaim` 等待 `$LIFECYCLE_LOCK_WAIT`（缺省 5，镜像 daemon
  等待窗），超时无条件接管（镜像 daemon L561-562；**不删除**现有自保
  能力——daemon 自身始终可强接管）。
- 权限：0644（`echo $$ >`，默认 umask 022）。

## 4. 启动初始化序列

```
lifecycle_start <base> <config> <lockfile>
  1) lifecycle_ensure_dirs "$base"        # $base/tasks $base/audit 0755
  2) lifecycle_lock_acquire "$lockfile"   # 单实例；失败→rc 1（拒绝，不动作）
  3) lifecycle_cleanup_zombies "$base/tasks"  # 崩溃恢复（§5）
  4) registry_init "$base" "$config"      # 最后有效快照（§9）
     → 有当前快照 ⇒ 就绪 rc 0
     → 无快照（首次失败）⇒ 释放锁回滚 rc 2（不留半初始化）
```

- **失败即回滚**：目录不可建 → rc 2（不碰锁）；锁被占 → rc 1（不动作）；
  首次解析失败 → rc 2 + **锁已释放**（fail-safe，可安全重试）。
- 与 P1-09 衔接：`cleanup_zombies` 内部用 `runtime_current_state` /
  `runtime_log_event` / `task_state_rehydrate`（新状态源），镜像 P1-09 的
  `scan_stale` 判定但**无条件恢复**（daemon 新实例视角 = 无活动任务）。

## 5. 僵尸清理与崩溃恢复

```
lifecycle_cleanup_zombies <tasks_dir>   # stdout：恢复数
```

- 判定：`runtime_current_state`（新 `state.txt` 优先；缺失时由旧 `status.txt`
  经 `task_state_from_legacy` 推导）∈ 执行态
  （STARTING/RUNNING/HEALTHY/UNHEALTHY/RECOVERING/STOPPING）。
- 恢复动作（**新旧都恢复，验收 3**）：
  - 旧兼容：`status.txt` 含 RUNNING → `ZOMBIE_CRASHED`（镜像 daemon L568-570）；
  - 新统一源：`runtime_log_event`（`daemon_restart`，state = `task_state_rehydrate`
    = FAILED）+ `state.txt` 原子更新；
  - **旧件仅当旧值为运行态才标记**（混合态中新源优先——测试 §3 断言）。
- 已完成（SUCCESS 等）任务不动；进程存活与否**不查**（镜像 daemon：新实例
  视角无活动任务）——`runtime_scan_stale`（P1-09）的 pid 存活分支由接线层
  在需要时叠加。
- **结果**：崩溃后不存在任何残留 RUNNING（新旧源均恢复）——旧任务不会被
  **永久**标记为运行中。

## 6. 停止与重启

```
lifecycle_stop <lockfile>       # kill 锁内 pid（≤5s 轮询）+ 释放锁
lifecycle_restart <lockfile> <base> <config> <daemon_cmd>
    # stop → sleep 1 → nohup "$daemon_cmd" &（新 daemon **自行**写锁/初始化）
```

- 镜像 CLI `stop`（kill + `rm -f` 锁）与 `restart`（stop → sleep 1 →
  `nohup "$DAEMON_BINARY" &`，L883-890）。
- `restart` **不在当前进程写锁**（避免「冒认 daemon」）：锁由新 daemon 进程
  通过 `lifecycle_start` 自建；若新进程未写锁（如配置损坏+无快照），锁保持
  释放状态，看护循环将按既有逻辑处理。

## 7. service.sh 兼容（看护单轮）

```
lifecycle_watchdog_tick <lockfile> [daemon_cmd]
    # 0=alive（不动作）；1=stale/无锁（清 stale 锁 + nohup 拉起 daemon_cmd）
```

- **镜像** `service.sh` L56-76 的**一轮**判定：alive 判定 → 不动作；死/无锁 →
  清理 + 拉起。
- **约束落地（不创建第二个独立调度循环）**：本函数是**单轮**检查，**不含
  `while true` 主循环**（测试结构断言：`grep -c 'while true' lib.sh == 0`）；
  每 60s 的循环仍由 `service.sh` 既有看护承担。接线方式：在 service.sh 的
  既有循环体内把「判定 + 拉起」替换/委托为 `lifecycle_watchdog_tick`。
- **不因新模块失败无限重启**：tick 单轮判定；Lifecycle 初始化失败返回非 0
  且不留半状态（§10）；看护方维持既有 60s 节奏，不会形成快速无限重启。

## 8. 目录与权限

| 目录/文件 | 权限 | 依据 |
| :--- | :--- | :--- |
| `$base` / `$base/tasks` / `$base/audit` | 0755 | P1-01 §3（数据/任务/审计目录惯例） |
| 锁文件 | 0644 | daemon `/dev/.su_scheduler.lock` 惯例 |
| `state.txt` / `events.log` | 0644 | P1-09 §6 |

- 路径一律**参数注入**：lib 无硬编码 `/data/adb/...`、`/dev/.su_scheduler.lock`
  （测试结构断言）——接线时传 daemon 实际路径，零冲突（C2/C4 延续）。

## 9. 最后有效配置快照（fail-safe）

- `lifecycle_start` 内 `registry_init`（P1-06）：配置损坏时 registry
  `KEPT` 回退（保留最后一个有效快照，任务不消失）。
- 判定：**有当前快照即就绪**（KEPT 视为成功——fail-safe 语义），而非看
  `registry_init` 返回码（KEPT 返回 1 但快照保留）。
- 全新无快照 + 坏配置 → 无 current → rc 2 + 释放锁（拒绝启动，不留半状态）。
- 测试：已有 snap_2 + broken 配置重启 → 就绪且快照保留、17 任务仍由最后
  有效快照提供。

## 10. 失败语义与约束

| 约束（任务要求） | 落实 |
| :--- | :--- |
| 不创建第二个独立调度循环 | §7（tick 单轮；无 while true；循环归 service.sh） |
| 不删除现有 daemon 自保能力 | 不改生产文件；锁/僵尸/强接管语义全部镜像保留 |
| 不因新模块初始化失败而无限重启 | §4/§7（失败回滚 + 单轮看护 + 既有 60s 节奏） |
| 配置错误必须 fail-safe | §9（KEPT 回退 / 首次失败拒绝启动） |
| 任务执行失败不能导致 daemon 退出 | 执行归 P1-08/P1-09（FAILED 落工件）；lifecycle 不介入执行，锁/快照不受影响 |

## 11. 接线边界（非目标）

- **不改** daemon / `service.sh` / CLI 生产文件（P1-10 为测试域 + 接线蓝图）。
- **不做**：真实调度主循环（仍归 daemon）；`shells` 目录管理（daemon 既有）；
  `audit` 内容生产（daemon 既有）；进程清理/再拉起动作的自动执行（接线层
  决策）。
- 接线点建议（文档化，不实现）：daemon 启动序列 L544-576 处插入
  `lifecycle_start`（或逐原语替换）；`service.sh` 看护循环体委托
  `lifecycle_watchdog_tick`。

## 12. 验收标准对照

| 验收标准 | 落实（tests/lifecycle/test.sh 断言） |
| :--- | :--- |
| daemon 正常启动、停止、重启 | §4 §6：模拟 daemon 子进程 start→ready（锁+17 任务快照）、stop（kill+释放锁）、restart（停旧拉新） |
| stale lock 能恢复 | §1：死 pid 锁 → acquire/force_reclaim 恢复重建（0644） |
| daemon 崩溃后不把旧任务永久标记为运行中 | §3/§4：僵尸清理 → status ZOMBIE_CRASHED + state FAILED + 事件；无 RUNNING 残留 |
| service.sh 行为保持兼容 | §7：watchdog_tick 单轮（alive 不动作/stale 清锁+拉起）；无 while true；lib 无硬编码路径 |
| 配置错误 fail-safe / 最后有效快照 | §1/§5：全新坏配置拒绝启动+回滚锁；已有快照+坏配置 → KEPT 仍就绪 |