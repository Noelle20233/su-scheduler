# Runtime State & Event Log — P1-09

> **任务**：P1-09 · 统一运行时状态和事件日志
> **依赖**：P1-03（Task State Machine v2）、P1-08（ActionProvider）
> **位置**：`tests/runtime/`（lib.sh 状态/日志库 + test.sh 回归 + 本文档）

## 目标

在不破坏现有 CLI / 旧任务工件的前提下，建立**统一的 Task 状态来源**与
**结构化事件日志**：

- **保留旧兼容文件**（只读，绝不改写）：`status.txt`、`pid.txt`、`output.log`、
  `exit_code.txt`、`end_time.txt`、`start_time.txt`（P1-08 产物）。
- **新状态来源**：`<task_dir>/state.txt`（单值，P1-03 v2 状态集合
  `TSM_STATES`）。
- **事件日志**：`<task_dir>/events.log`（追加式，每次关键变化一行）。

## 事件行格式（验收字段序）

```
<timestamp>|<task_id>|<event>|<state>|<pid>|<exit_code>|<message>
```

- `timestamp`：`YYYY-MM-DD HH:MM:SS`（镜像 daemon 工件时戳）。
- `event`：关键变化名，集合 `RT_EVENTS`（与 P1-03 触发原因令牌对齐 +
  `create`/`delete`）——未知 event 整体拒绝（rc 1），保证格式统一。
- `state`：P1-03 v2 状态（`task_state_is_valid` 校验）；非法 state 整体拒绝
  （rc 1），不污染状态源。
- `message` 内 `|` 归一为 `;`（保持 7 字段稳定）。

## 原子化与失败策略

- `state.txt`：`tmp + mv` 原子替换（镜像 task-registry `current` 指针）。
- `events.log`：`O_APPEND` 单行追加（POSIX 原子追加）——「尽量原子化」。
- **日志失败绝不中止任务执行**（验收）：任何写失败只返回非 0（2=写失败），
  内部不 `exit`；调用方忽略返回值时任务流程不受影响（test.sh §4 实证）。
- 写顺序固定：先 events.log 后 state.txt（状态失败时事件已留档）。

## 权限

任务目录 0755、`state.txt`/`events.log` 0644（与现有任务工件一致，P1-01 §3）。

## 残留运行记录识别（验收 3）

`runtime_scan_stale <tasks_dir>`：对每个含 `pid.txt` 的任务目录——

- 「运行态」= 新 `state.txt` 为执行态（STARTING/RUNNING/HEALTHY/UNHEALTHY/
  RECOVERING/STOPPING），或新源缺失时由旧 `status.txt=RUNNING` 推导
  （`task_state_from_legacy`）；
- 记录 pid 不存在（`/proc/<pid>` 不可见）→ **残留运行记录**：
  - 记 `daemon_restart` 事件；`state.txt` 按 `task_state_rehydrate` 置
    `FAILED`（执行态→FAILED，P1-03 再水合）；
  - **旧 `status.txt` 保持不变**（验收 2：新旧不互覆盖；CLI 仍按旧语义读取）；
- pid 存活 / 非运行态 → 不识别；本函数只识别+记录，不杀进程、不删目录
  （清理属接线层）。

## 接口

```sh
runtime_state_file  <dir>                        # → <dir>/state.txt
runtime_events_file <dir>                        # → <dir>/events.log
runtime_current_state <dir>                      # → 新源；缺省从旧 status.txt 推导
runtime_log_event <dir> <task_id> <event> <state> <pid> <exit_code> <message>
    # 0 成功 / 1 拒绝（非法 state 或 event）/ 2 写失败（任务不中止）
runtime_scan_stale <tasks_dir>                   # → 残留 id（每行一个）
```

## 测试

```bash
bash tests/runtime/test.sh    # 全 [PASS] 且 exit 0
```

覆盖：文件/格式/权限、7 字段事件行、原子性、写失败不中止任务、非法拒绝、
验收 1（旧工件保持可读）与验收 2（新旧不互覆盖）、验收 3（scan_stale 全分支）。