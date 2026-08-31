# Su Scheduler — 统一运行时状态与事件日志（P1-09）

> **任务**：P1-09 · 统一运行时状态和事件日志
> **依赖**：P1-03（Task State Machine v2）、P1-08（ActionProvider / 任务工件）
> **性质**：在不破坏现有 CLI / 旧任务工件的前提下，建立**新的统一 Task 状态
> 来源**与**结构化事件日志**，为后续 Supervisor 提供可审计的运行时事实。
> **实现位置**：`tests/runtime/lib.sh`（状态/日志库）、`tests/runtime/test.sh`
> （回归）、本文档。
> **日期**：2026-08-31

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [文件布局与兼容原则](#2-文件布局与兼容原则)
3. [事件行 Schema](#3-事件行-schema)
4. [写入规则与原子化](#4-写入规则与原子化)
5. [失败语义（不中止任务执行）](#5-失败语义不中止任务执行)
6. [权限](#6-权限)
7. [daemon 重启残留识别](#7-daemon-重启残留识别)
8. [与 P1-03 / P1-08 的衔接](#8-与-p1-03--p1-08-的衔接)
9. [验收标准对照](#9-验收标准对照)
10. [接线边界（非目标）](#10-接线边界非目标)

---

## 1. 目的与范围

- **现状问题**：任务目录是一堆互不关联的旧工件（`status.txt`/`pid.txt`/
  `output.log`/`exit_code.txt`/`end_time.txt`），状态没有统一来源，事件没有
  结构化记录；P1-03 状态机定义的状态集合尚未持久化。
- **目的（P1-09）**：
  1. 保留旧工件**原样只读**（现有 CLI `task-info`/`task-output` 等继续按旧
     语义读取）——验收 1、2；
  2. 新增统一状态来源 `state.txt`（P1-03 v2 状态集合），**不覆盖**旧
     `status.txt`——验收 2；
  3. 新增事件日志 `events.log`，每次关键变化记录
     `timestamp|task_id|event|state|pid|exit_code|message`——验收要求；
  4. 日志写入尽量原子化；日志失败**绝不中止任务执行**；
  5. 明确权限（目录 0755、文件 0644）；
  6. daemon 重启后识别残留运行记录——验收 3。
- **范围**：测试域实现（`tests/runtime/`），不改 daemon / CLI / 旧工件；
  接线（daemon 在启动扫描/任务执行处调用本库）属后续任务。

## 2. 文件布局与兼容原则

```
<task_dir>/
  status.txt     旧状态（RUNNING/SUCCESS/FAILED/ZOMBIE_CRASHED）— 只读兼容
  pid.txt        旧进程记录                              — 只读兼容
  output.log     旧 stdout+stderr 合并                   — 只读兼容
  exit_code.txt  旧退出码                                — 只读兼容
  end_time.txt   旧结束时间                              — 只读兼容
  start_time.txt 旧开始时间                              — 只读兼容
  state.txt      ★ 新：统一状态来源（P1-03 v2 状态集合，单值）— 本库写入
  events.log     ★ 新：事件日志（追加式，每行一次关键变化）— 本库写入
```

- **兼容原则**：本库**只写** `state.txt` 与 `events.log`；旧工件只**读**、绝不
  改写。新旧状态是两个独立文件——互不覆盖（验收 2）。
- `runtime_current_state` 读取顺序：新源 `state.txt` 优先；缺失/为空时由旧
  `status.txt` 经 `task_state_from_legacy`（P1-03）推导，**推导不写任何文件**。

## 3. 事件行 Schema

```
<timestamp>|<task_id>|<event>|<state>|<pid>|<exit_code>|<message>
```

| 字段 | 含义 | 说明 |
| :--- | :--- | :--- |
| `timestamp` | `YYYY-MM-DD HH:MM:SS` | 镜像 daemon 工件时戳格式 |
| `task_id` | 任务 id | registry 稳定 id（t11_boot 等） |
| `event` | 关键变化名 | ∈ `RT_EVENTS` |
| `state` | P1-03 v2 状态 | 写入前的目标状态（校验后） |
| `pid` | 进程 pid | 可为空（`||`） |
| `exit_code` | 退出码 | 可为空（`|`） |
| `message` | 人类可读说明 | 内 `|` 归一为 `;`（保持 7 字段稳定） |

- `RT_EVENTS`（关键变化集合，与 P1-03 触发原因令牌 `TSM_CAUSES` 对齐 +
  `create`/`delete`）：
  `create config_load time_trigger manual_exec spawn action_success
  action_failure timeout stop_request daemon_restart rearm enable disable
  supervisor probe recover`
- **校验**：`state` 须通过 `task_state_is_valid`；`event` 须在 `RT_EVENTS`；
  任一非法 → 整体拒绝（rc 1），事件与状态**都不写**（不污染状态源，P1-03
  「非法转换必须被拒绝并记录日志」的持久化对应）。

## 4. 写入规则与原子化

1. **顺序固定**：先追加事件行（`events.log`），再更新 `state.txt`——状态写
   失败时事件已留档（可审计「最后一次尝试」）。
2. **事件行**：`O_APPEND` 单行追加（POSIX 对普通文件 append 单行写原子）——
   「尽量原子化」的实现。
3. **状态文件**：`printf > state.txt.tmp && mv -f tmp state.txt`（tmp+mv 原子
   替换，镜像 task-registry `current` 指针手法）；失败时清理 `*.tmp`。
4. 两个文件都无 `.tmp` 残留（测试断言）。

## 5. 失败语义（不中止任务执行）

- 写失败（只读文件 / 只读目录 / 磁盘错误）→ 返回 **2**（写失败），内部
  **不 `exit`**；调用方忽略返回值时，任务执行流程不受影响（测试 §4 实证：
  权限恢复后可继续写，且后续用例全部照常执行）。
- 非法 state / event → 返回 **1**（拒绝），同样不中止。
- 成功 → 返回 **0**。

## 6. 权限

| 对象 | 权限 | 依据 |
| :--- | :--- | :--- |
| 任务目录 | 0755 | P1-01 §3（`tasks/<id>/`） |
| `state.txt` / `events.log` | 0644 | P1-01 §3（任务工件惯例） |

## 7. daemon 重启残留识别

`runtime_scan_stale <tasks_dir>`（验收 3）：

1. 遍历 `<tasks_dir>/*` 中含 `pid.txt` 的任务目录；
2. **运行态判定**（新旧任一来源）：当前状态 ∈ 执行态
   （STARTING/RUNNING/HEALTHY/UNHEALTHY/RECOVERING/STOPPING）；新源缺失时由旧
   `status.txt` 推导（`task_state_from_legacy`）；
3. **存活判定**：`/proc/<pid>` 可见（daemon 重启前未结束的进程 = 存活，不识别）；
4. **残留**（运行态 + pid 不可见）：
   - 记 `daemon_restart` 事件（pid=记录值，exit_code 空，message 说明）；
   - `state.txt` 按 `task_state_rehydrate`（P1-03：执行态→FAILED）原子更新；
   - **旧 `status.txt` 保持原样**（验收 2：CLI 仍看到旧 RUNNING；接线层可另行
     决定是否沿旧语义标 `ZOMBIE_CRASHED`）；
5. stdout 输出识别出的残留 id（每行一个），rc 0。

> 本函数只做「识别 + 记录」，不杀进程、不删目录——清理/再拉起属后续接线层。

## 8. 与 P1-03 / P1-08 的衔接

- **P1-03**：`state.txt` 使用 `TSM_STATES`（11 个 v2 状态）；非法转换拒绝；
  `task_state_rehydrate`（daemon 重启再水合）与 `task_state_from_legacy`
  （旧状态推导）直接复用——本库不重定义状态集合。
- **P1-08**：`state.txt`/`events.log` 落在 ActionProvider 的任务目录
  （`TPR_ACTION_DIR/<id>/`），与旧工件（status.txt/output.log/pid.txt…）同目录
  并存；事件 `spawn`/`action_success`/`action_failure` 对应 P1-08 的 start /
  finalize 语义。
- 依赖链：P1-09 → P1-03（状态机）+ P1-08（任务目录/工件）。

## 9. 验收标准对照

| 验收要求 | 落实 |
| :--- | :--- |
| 保留 status.txt/pid.txt/output.log 等兼容文件 | §2（只读兼容；测试断言全程原样） |
| 增加统一的 Task 状态来源 | §2 `state.txt`（P1-03 v2 状态集合） |
| 每次关键变化记录 timestamp/task_id/event/state/pid/exit_code/message | §3 事件行 Schema（7 字段） |
| 日志写入尽量原子化 | §4（append 单行 + tmp+mv） |
| 日志失败不中止任务执行 | §5（只返回码，不 exit；测试实证） |
| 明确日志文件权限 | §6（0644 / 0755） |
| 现有 CLI 仍能查看旧任务结果（验收 1） | §2/§9 测试：旧工件内容保持可读且与 P1-08 产物一致 |
| 新状态和旧状态不会互相覆盖（验收 2） | §2 独立文件；scan_stale 只更新 state.txt，status.txt 不动 |
| daemon 重启后可识别残留运行记录（验收 3） | §7 `runtime_scan_stale`（事件 + 再水合 + 不覆盖旧件） |

## 10. 接线边界（非目标）

- **不改** daemon / CLI / 旧工件（C2/C4 延续）；本库写新文件为纯增量。
- **不做**：进程清理/再拉起、ZOMBIE_CRASHED 同步标记（属接线层决策）、事件
  轮转/压缩、集中式事件库（本方案每任务目录本地日志，简单可审计）。
- **不引入**外部运行时（POSIX sh + date/sed/awk/mv/cat，C3）。