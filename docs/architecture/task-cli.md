# Su Scheduler — 只读 Task CLI（P1-11）

> **任务**：P1-11 · 增加只读 Task CLI
> **依赖**：P1-06（Canonical Task Registry）、P1-09（Runtime State & Event
> Log）、P1-10（lifecycle 锁判定）
> **性质**：让内部 Task 模型可被**验证和观察**——P1 只增加只读能力：
> `su-scheduler task list` 与 `su-scheduler task status <id>`；保持全部原有
> CLI 命令；不在 P1 增加 `task start/stop/restart`。
> **实现位置**：`tests/task-cli/lib.sh`（只读 CLI 库）、`tests/task-cli/test.sh`
> （回归）、`tests/task-cli/README.md`、本文档。
> **日期**：2026-09-01

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [命令与输出](#2-命令与输出)
3. [数据源（验收 1：CLI 读 Task Registry）](#3-数据源验收-1cli-读-task-registry)
4. [状态来源优先级](#4-状态来源优先级)
5. [错误三态（验收：明确区分）](#5-错误三态验收明确区分)
6. [daemon 判定与离线语义](#6-daemon-判定与离线语义)
7. [约束：只读、不覆盖、不回归](#7-约束只读不覆盖不回归)
8. [接线边界（非目标）](#8-接线边界非目标)
9. [验收标准对照](#9-验收标准对照)

---

## 1. 目的与范围

- **现状**：内部 Task（P1-02 schema v2）由 P1-05/06 解析进入 Canonical Task
  Registry 快照，运行时状态由 P1-09/10 维护——但外部无**只读观察**入口。
- **目的（P1-11）**：
  1. 提供 `task list` / `task status <id>` 两个**只读**命令语义（测试域
     `task_cli_list` / `task_cli_status`），让内部模型可验证、可观察；
  2. CLI 数据源 = **Task Registry 快照**（验收 1）——不重新解析出第二套
     任务；
  3. 任务错误输出**明确区分**：Task 不存在 / 配置无效 / daemon 未运行；
  4. 原有 CLI（list/status/tasks/task-info/…）**不回归**（验收 2）。
- **范围外（P1）**：`task start/stop/restart` 等写操作——**禁止**。

## 2. 命令与输出

### task list

```
<id>|<name>|<trigger>|<action>|<enabled>|<state>
```

- 每行一个任务（registry 快照序，`registry_task_ids`）；6 字段对应任务要求
  （ID、名称、Trigger、Action、enabled、当前状态）。
- trigger 保留原始格式（如 `22:00`，id 仍为 norm 后 `t45_2200`）。

### task status <id>

key=value 行（对齐 P1-02 task 文件风格）：

```
id / name / enabled / trigger / dependency / condition / action
source.type / source.line / source.raw     # 来源（P1-02 source.*）
state / legacy_status                       # 当前状态 + 旧兼容状态
run_count / last_status / last_exit / last_start / last_end  # 最近一次执行
daemon=running|stopped                      # 注入锁且可判定时
last_event=                                 # events.log 尾行（P1-09）
Gate: <WAITING + 原因>                      # P4-09 门控状态行（仅 WAITING 时，缺省空）
```

- `dependency`/`condition`：managed Task v2 域的配置字段（P4-09 起输出；空值输出空，
  legacy 快照无值亦输出空行）。
- `Gate:` 行（P4-09）：任务当前处于 WAITING 时输出 `Gate: WAITING (<原因>)`，原因取
  自运行目录 gate 工件（retry.until / gate.fail）或 events.log 最新 gate 事件 msg；
  非 WAITING 不产生该行。

## 3. 数据源（验收 1：CLI 读 Task Registry）

| 信息 | 来源 | 结构断言 |
| :--- | :--- | :--- |
| 任务 id / name / trigger / action / enabled / source.* | `registry_task_ids` / `registry_task_file` / `registry_manifest`（P1-06 快照） | lib 无 `IFS= read` 配置扫描循环；无直接 config 读取；必须使用 registry API |
| 当前状态 | P1-09 `runtime_current_state` + 快照 `runtime.state` 字段 | §4 |
| daemon 判定 | P1-10 `lifecycle_lock_alive`（`TASK_CLI_LOCK`） | §6 |

- **不会重新解析出另一套任务**：行为断言 list 的 id 集合 ==
  `registry_task_ids` 集合；字段值来自快照任务文件原文。

## 4. 状态来源优先级

```
1) 运行目录 $TASK_CLI_TASKS_DIR/<id>/state.txt   # P1-09 新统一源（真实运行时）
2) 运行目录 <id>/status.txt                      # 旧兼容（task_state_from_legacy 推导）
3) registry 快照任务文件 runtime.state 字段      # P1-02 默认 PENDING（从未运行）
```

- 与 P1-09 `runtime_current_state` 语义一致（新源优先）；运行目录由
  `TASK_CLI_TASKS_DIR` 注入（镜像 daemon `tasks/`）。

## 5. 错误三态（验收：明确区分）

| rc | 情形 | stderr 消息 |
| :--- | :--- | :--- |
| 1 | **Task 不存在**（registry 无此 id） | `task not found: <id>` |
| 2 | **配置无效**（无当前有效快照——从未成功加载/损坏后无回退） | `configuration invalid (no valid task snapshot)` |
| 3 | **daemon 未运行**（注入锁时锁不可活；磁盘状态可能是崩溃残留） | `daemon is not running — cannot report live task state` |

- stdout 不混错误；错误一律 stderr。判定顺序：配置有效 → 任务存在 →
  daemon 存活。

## 6. daemon 判定与离线语义

- `task_cli_daemon_running`：注入 `TASK_CLI_LOCK` 时用 P1-10
  `lifecycle_lock_alive`（`/proc/<pid>` 语义）判定。
- **list 离线可查**：daemon 停机不影响静态快照清单（验收 1——CLI 读的是
  Registry，与 daemon 进程无关）。
- **status 需要 daemon 存活**：daemon 未运行时状态可能是崩溃残留
  （P1-10 清理只在启动时执行），因此明确返回 rc 3，避免误导。
- 锁未注入（`TASK_CLI_LOCK` 空）→ 跳过 daemon 判定（纯离线快照查看），
  输出不产生 `daemon=` 行。

## 7. 约束：只读、不覆盖、不回归

- **只读**：lib 无 `task_cli_start/stop/restart`（结构断言）。
- **不覆盖**：无 `list()/status()/tasks()/task-info()/...` 同名函数定义
  （生产 CLI 命令零冲突）。
- **不回归**：生产 CLI 文件零改动（本层为纯新增 `task_cli_*` 前缀函数）。
- **fail-safe**：部分行损坏（registry `rc1` 且有任务）的快照仍视为有效
  配置（KEPT 子集）——list 正常输出（测试断言），不因单行损坏回退为
  "配置无效"。

## 8. 接线边界（非目标）

- **不改**生产 CLI（`system/bin/su-scheduler`）；本层提供命令语义与测试，
  接线时在 CLI 的 `task` 子命令下调用 `task_cli_list` / `task_cli_status`。
- **不做**：任务写操作（start/stop/restart/delete）、富格式输出、分页
  （生产 CLI 展示归接线层）。

## 9. 验收标准对照

| 验收标准 | 落实 |
| :--- | :--- |
| CLI 读 Task Registry，不重新解析另一套任务 | §3（结构断言无 text-scan；行为断言 list id 集 == registry id 集） |
| 原有 list、status、tasks 等命令不回归 | §7（不覆盖同名函数；生产文件零改动；部分损坏仍 fail-safe） |
| task list 显示 ID/名称/Trigger/Action/enabled/当前状态 | §2（6 字段）+ 测试断言 |
| task status 显示来源、状态、最近一次执行信息 | §2（source.*/state/run_count/last_*/last_event） |
| 错误明确区分 Task 不存在/配置无效/daemon 未运行 | §5（rc1/2/3 + stderr 消息）+ 测试断言 |
| P1 只增加只读能力 | §7（无 start/stop/restart 结构断言） |
| 保持所有原有 CLI 命令 | §7（零覆盖、零改动） |