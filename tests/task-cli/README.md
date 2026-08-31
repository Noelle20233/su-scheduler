# Task 只读 CLI 层 — P1-11

> **任务**：P1-11 · 增加只读 Task CLI
> **依赖**：P1-06（Canonical Task Registry）、P1-09（Runtime State & Event Log）、P1-10（锁判定）
> **位置**：`tests/task-cli/`（lib.sh 只读 CLI + test.sh 回归 + 本文档）

## 目标

让内部 Task 模型可被**验证和观察**——只读能力：

```
task_cli_list              # ~ su-scheduler task list
task_cli_status <id>       # ~ su-scheduler task status <id>
```

- **P1 只加只读**：无 `task start/stop/restart`（约束，测试结构断言）。
- **保持原有 CLI 命令**：本层只新增 `task_cli_*` 前缀函数，不定义/不覆盖
  `list/status/tasks/task-info/...` 同名函数（生产 CLI 零改动，验收 2）。

## 数据源（验收 1：CLI 读 Task Registry，不重新解析）

| 信息 | 来源 |
| :--- | :--- |
| 任务 id / name / trigger / action / enabled / source.* | P1-06 registry 快照任务文件（`registry_task_ids` / `registry_task_file` / `registry_manifest`）——**无配置文本扫描**（结构断言） |
| 当前状态 | P1-09 `runtime_current_state`：运行目录 `$TASK_CLI_TASKS_DIR/<id>/state.txt`（新源）→ 旧 `status.txt` 推导 → registry 快照 `runtime.state` 字段（PENDING，任务从未运行） |
| daemon 运行判定 | P1-10 `lifecycle_lock_alive`（`TASK_CLI_LOCK` 注入；空 = 不判定，允许离线查看清单） |

## 输出

- **task list**：每行 `id|name|trigger|action|enabled|state`（6 字段）。
- **task status <id>**：key=value 行——来源（source.type/line/raw）、状态
  （state / legacy_status）、最近一次执行信息（run_count / last_status /
  last_exit / last_start / last_end / last_event=events.log 尾行）、daemon=。

## 错误三态（验收：明确区分）

| rc | 情形 | stderr |
| :--- | :--- | :--- |
| 1 | Task 不存在（registry 无此 id） | `task not found: <id>` |
| 2 | 配置无效（无当前快照——从未成功加载/损坏） | `configuration invalid (no valid task snapshot)` |
| 3 | daemon 未运行（注入锁时锁不可活；磁盘状态可能是崩溃残留） | `daemon is not running — cannot report live task state` |

- stdout 不混错误；错误一律 stderr。
- list 在 daemon 停机时仍可离线查看（静态快照，验收 1）；status 需要
  daemon 存活才能保证实时状态（否则 rc 3）。

## 测试

```bash
bash tests/task-cli/test.sh    # 全 [PASS] 且 exit 0
```

覆盖：只读约束（无 start/stop/restart）、不覆盖原有 CLI、数据源结构断言
（无 text-scan；list id 集 == registry id 集）、list 6 字段、status 全字段、
状态优先级（新源→旧推导→快照字段）、错误三态、离线 list、部分损坏配置
仍有效（fail-safe 子集）。