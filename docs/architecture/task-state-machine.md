# Su Scheduler — 任务状态机（Task State Machine v2）（P1-03）

> **任务**：P1-03 · 定义并实现 Task State Machine
> **依赖**：P1-02（Task Schema v2）
> **性质**：本机是**规范状态机**（canonical state machine）：统一任务生命周期，取代
> legacy 的 `RUNNING/SUCCESS/FAILED/ZOMBIE_CRASHED` 无规则扩展。P1-03 交付：状态
> 转换表（`task-state-machine-transitions.tsv`，单一事实源）、校验函数
> （`tests/state-machine/lib.sh`，POSIX sh）、状态机测试（`tests/state-machine/test.sh`）
> 与本文档。
> **接线边界**：本任务**不改 daemon**（C2/C4）。`wired` 边是 daemon 已具备语义的
> 投影（触发/结果/停止/重启/再武装）；`reserved` 边（WAITING 门控、HEALTHY/
> UNHEALTHY/RECOVERING、重试退避）由后续任务（依赖/条件、Supervisor、重试）接线；
> 本次只定义与预留，**不接线**（验收条件：Supervisor 未实现时这些状态也已预留）。
> **日期**：2026-08-30
> **P1-13 注记（2026-09-01）**：状态机已实现并被 P1-09/10/11 复用（daemon 重启
> 再水合、僵尸恢复、CLI 状态列）。**P1 未接线（不得宣称完成）**：HEALTHY/
> UNHEALTHY/RECOVERING 与 WAITING 门控为 reserved 边（Supervisor / Dependency
> 未实现，见 §非目标与 `docs/P1-HANDOVER.md` §5）。

---

## 目录

1. [目的与设计要点](#1-目的与设计要点)
2. [状态枚举（11 个）](#2-状态枚举11-个)
3. [状态转换表（35 条允许边）](#3-状态转换表35-条允许边)
4. [触发原因清单](#4-触发原因清单)
5. [非法转换的拒绝与日志](#5-非法转换的拒绝与日志)
6. [daemon 重启再水合规则](#6-daemon-重启再水合规则)
7. [legacy / P1-02 兼容映射](#7-legacy--p102-兼容映射)
8. [校验函数与独立测试](#8-校验函数与独立测试)
9. [验收标准对照](#9-验收标准对照)
10. [非目标与后续任务](#10-非目标与后续任务)

---

## 1. 目的与设计要点

- **目的**：统一任务生命周期，避免 `RUNNING/SUCCESS/FAILED` 等状态继续无规则扩展
  （task 目录 `status.txt` 曾出现 RUNNING/SUCCESS/FAILED/ZOMBIE_CRASHED/STALE/
  UNKNOWN 等随意值——P1-01 §3/§6）。P1-03 收紧为**固定 11 态 + 35 条允许边**，
  非法边一律拒绝并记录。
- **设计要点**：
  1. **单一事实源**：允许边只在 `tests/state-machine/lib.sh` 的 `TSM_ALLOWED` 与
     `docs/architecture/task-state-machine-transitions.tsv` 两处出现，且**测试断言
     两者完全一致**（§8），消除“文档与实现漂移”。
  2. **合法性即判定**：任何不在允许集中的 `from>to` 都是非法转换（默认拒绝），
     不需要逐一枚举“非法表”。
  3. **可独立测试**：校验函数是纯 POSIX sh、无副作用（日志为可覆盖钩子），
     121 个状态对全量穷举测试（§8）。
  4. **预留而非占位**：WAITING/HEALTHY/UNHEALTHY/RECOVERING 及其边在本次**完整
     定义**（语义+原因），只是 daemon 尚未接线（`reserved`）；接线任务不得**另起
     炉灶**改状态集，只能“接线”已定义的边。
  5. **与 P1-02 关系**：本机是 P1-02 `runtime.state` 的**规范实现**；P1-02 旧值
     （idle/running/success/failed/zombie/disabled/invalid）全部可映射（§7）。

## 2. 状态枚举（11 个）

| 状态 | 语义 | 性质 |
| :--- | :--- | :--- |
| `DISABLED` | 停用（enabled=0）。不参与调度匹配；含 P1-02 隔离（invalid）条目 | 非执行态 |
| `PENDING` | 已注册且启用，**等待触发**（时间/boot/手动）。配置加载后 enabled=1 的默认态 | 非执行态 |
| `WAITING` | 已被门控阻塞：依赖未满足 / 条件未通过 / 重试退避 / 等待 Supervisor（预留） | 非执行态 |
| `STARTING` | 启动过程：建 task 目录/工件、spawn 进程 | 执行态 |
| `RUNNING` | 执行中（进程存活）。legacy 主执行态 | 执行态 |
| `HEALTHY` | 执行中且健康探测通过（Supervisor 预留） | 执行态（RUNNING 派生） |
| `UNHEALTHY` | 执行中但健康探测失败（Supervisor 预留） | 执行态（RUNNING 派生） |
| `RECOVERING` | Supervisor 恢复流程进行中（预留） | 执行态 |
| `FAILED` | 本轮执行失败（终态；可再武装/重试/停用） | 终态 |
| `STOPPING` | 停止流程中：停止请求 / 超时软停 / daemon 关闭 | 执行态 |
| `STOPPED` | 本轮成功完成或被干净停止（终态；可再武装/停用） | 终态 |

分类：**执行态**={STARTING, RUNNING, HEALTHY, UNHEALTHY, RECOVERING, STOPPING}——
daemon 重启时这些状态视为崩溃（§6）；**非执行态**={DISABLED, PENDING, WAITING}；
**终态**={FAILED, STOPPED}（对应 legacy 一次性任务路径终点，§7）。

## 3. 状态转换表（35 条允许边）

> 完整机器可读表：`docs/architecture/task-state-machine-transitions.tsv`
> （列：FROM / TO / CAUSE / WIRING / NOTE）。下表为其渲染。
> `WIRING`: **wired** = 当前可接线（daemon 语义投影）；**reserved** = 后续任务接线。

| FROM | TO | CAUSE | WIRING | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| DISABLED | PENDING | enable | wired | 启用（enabled 0→1，手工/日后配置） |
| PENDING | DISABLED | disable | wired | 停用（enabled 1→0，配置加载/手工） |
| PENDING | STARTING | time_trigger \| manual_exec | wired | 触发匹配（时间/boot 属 time_trigger 家族）或手动执行 |
| PENDING | WAITING | time_trigger | reserved | 触发已匹配但被依赖/条件门控阻塞 |
| WAITING | PENDING | rearm | reserved | 门控在窗口前解除/取消，回到待触发 |
| WAITING | STARTING | time_trigger \| manual_exec | reserved | 门控解除 → 启动 |
| WAITING | FAILED | action_failure | reserved | 门控永久失败（如依赖任务终态失败） |
| WAITING | DISABLED | disable | wired | 停用（等待中） |
| STARTING | RUNNING | spawn | wired | 进程成功拉起（task 目录/工件就绪） |
| STARTING | WAITING | spawn | reserved | 启动被阻塞（资源/Supervisor 未就绪）——预留；当前 spawn 失败直接 FAILED |
| STARTING | FAILED | action_failure | wired | spawn 失败（无法执行） |
| STARTING | STOPPING | stop_request | wired | 启动中收到停止请求 |
| RUNNING | STOPPED | action_success | wired | Action 成功（exit 0）——legacy 一次性任务主路径 |
| RUNNING | FAILED | action_failure \| timeout | wired | Action 失败（exit≠0）或硬超时/崩溃 |
| RUNNING | STOPPING | stop_request \| timeout \| daemon_restart | wired | 停止请求 / 超时软停 / daemon 关闭 |
| RUNNING | HEALTHY | probe | reserved | Supervisor 健康探测通过 |
| HEALTHY | UNHEALTHY | probe | reserved | Supervisor 健康探测失败 |
| HEALTHY | STOPPED | action_success | reserved | Action 成功（健康态正常完成） |
| HEALTHY | FAILED | action_failure \| timeout | reserved | Action 失败/硬超时（健康态崩） |
| HEALTHY | STOPPING | stop_request \| daemon_restart | reserved | 停止请求 / daemon 关闭 |
| UNHEALTHY | RUNNING | probe | reserved | 探测自然恢复（未触发恢复流程） |
| UNHEALTHY | RECOVERING | supervisor | reserved | Supervisor 启动恢复流程 |
| UNHEALTHY | STOPPED | action_success | reserved | Action 仍成功完成 |
| UNHEALTHY | FAILED | action_failure \| timeout | reserved | Action 失败/硬超时 |
| UNHEALTHY | STOPPING | stop_request \| daemon_restart | reserved | 停止请求 / daemon 关闭 |
| RECOVERING | STARTING | supervisor | reserved | 恢复完成 → 重新启动 |
| RECOVERING | FAILED | supervisor \| action_failure | reserved | 恢复失败/策略耗尽 |
| RECOVERING | STOPPING | stop_request | reserved | 恢复中止 → 停止 |
| STOPPING | STOPPED | stop_request | wired | 清理完成（正常停止/被干净终止）——legacy 一次性任务主路径 |
| STOPPING | FAILED | timeout \| action_failure | wired | 强制杀/清理失败 |
| FAILED | PENDING | rearm \| manual_exec | wired | 再武装：下一周期/手动重跑 |
| FAILED | WAITING | rearm | reserved | 重试退避（retry.max/interval，P1-02 字段） |
| FAILED | DISABLED | disable | wired | 停用（失败后） |
| STOPPED | PENDING | rearm \| manual_exec | wired | 再武装：下一周期/手动重跑 |
| STOPPED | DISABLED | disable | wired | 停用（成功/停止后） |

**归纳**：主执行环 `PENDING→STARTING→RUNNING→{STOPPED|FAILED}`；再武装环
`{STOPPED|FAILED}→PENDING`（循环/每日任务）；停止通道
`{STARTING|RUNNING|HEALTHY|UNHEALTHY|RECOVERING}→STOPPING→{STOPPED|FAILED}`；
健康通道 `RUNNING⇄HEALTHY⇄UNHEALTHY→RECOVERING`（预留）；门控通道
`PENDING⇄WAITING`、`FAILED→WAITING`（预留）；生命开关 `⇄DISABLED`（非执行态）。

## 4. 触发原因清单

> 令牌集合（`TSM_CAUSES`，`tests/state-machine/lib.sh`）：
> `config_load time_trigger manual_exec action_success action_failure timeout
> daemon_restart stop_request rearm enable disable supervisor spawn probe`

需求指定原因与对应转换：

| 需求原因 | 令牌 | 触发边（举例） |
| :--- | :--- | :--- |
| 配置加载 | `config_load` | 加载后置初态：enabled=1 → PENDING；enabled=0/隔离 → DISABLED（§6 注） |
| 时间触发 | `time_trigger` | PENDING→STARTING；boot 属本家族 |
| 手动执行 | `manual_exec` | PENDING→STARTING；FAILED/STOPPED→PENDING（重跑） |
| Action 成功 | `action_success` | RUNNING→STOPPED（HEALTHY/UNHEALTHY 同） |
| Action 失败 | `action_failure` | RUNNING→FAILED；STARTING→FAILED；STOPPING→FAILED |
| 超时 | `timeout` | RUNNING→STOPPING（软）/RUNNING→FAILED（硬）；STOPPING→FAILED（强杀） |
| daemon 重启 | `daemon_restart` | 再水合规则（§6）：执行态→FAILED；RUNNING→STOPPING 通道关闭期也见 daemon_restart |

扩展令牌（后续接线任务用）：`stop_request`（停止请求）、`rearm`（再武装）、
`enable`/`disable`（生命开关）、`supervisor`（Supervisor 动作）、`spawn`（拉起）、
`probe`（健康探测）。

## 5. 非法转换的拒绝与日志

- **判定规则**：`task_state_transition <from> <to> [cause]`：
  - 0 = 允许；1 = 非法（已拒绝并记录）；2 = 边允许但 cause 令牌未知。
  - 未知状态（含遗留旧值 `success`/`zombie`/`idle`…）→ 非法（须先经 §7 映射）。
- **日志**：非法边经 `task_state_log`（默认 stderr，`[WARNING] …ILLEGAL transition
  'FROM'->'TO' rejected…`；daemon 接线时覆盖为写 `su-scheduler.log`）。**绝不**
  因非法转换退出/清库（与 P1-02 校验原则 P3/P4 一致）。
- **典型非法边**（测试覆盖）：
  - `RUNNING→PENDING`（跳过停止/收尾）✗
  - `STOPPED→RUNNING`（未再武装直达执行）✗
  - `DISABLED→RUNNING`（跳 PENDING/STARTING）✗
  - `PENDING→RUNNING`（跳 STARTING）✗
  - `FAILED→STOPPED`（失败不能“变成功”）✗
  - `STOPPED→FAILED`（成功态不可“转失败”；失败须经新执行轮）✗
  - `RUNNING→SUCCESS`（遗留值未映射即判定非法）✗

## 6. daemon 重启再水合规则

daemon 重启时（对注册表内每个任务）：

| 重启前状态 | 再水合后 | 理由 |
| :--- | :--- | :--- |
| STARTING / RUNNING / HEALTHY / UNHEALTHY / RECOVERING / STOPPING | **FAILED** | 进程已随 daemon 消失 = 崩溃中断（对应 legacy ZOMBIE_CRASHED） |
| DISABLED / PENDING / WAITING / FAILED / STOPPED | 原样保留 | 非执行态/终态不依赖进程存活 |

实现：`task_state_rehydrate <state>`（lib.sh）。**注**：再水合是“重启动态下的特例
状态判定”，不是一条普通转换边；`config_load` 置初态也遵循同一函数（PENDING/
DISABLED 之外的历史记录态按上表判定）。

## 7. legacy / P1-02 兼容映射

| legacy 事实（P1-01/P1-02） | 映射 |
| :--- | :--- |
| `status.txt=RUNNING` / P1-02 `runtime.state=running` | RUNNING |
| `status.txt=SUCCESS` / `success` | STOPPED |
| `status.txt=FAILED` / `failed` | FAILED |
| `status.txt=ZOMBIE_CRASHED` / `zombie` | FAILED（再水合语义，§6） |
| P1-02 `idle` | PENDING |
| P1-02 `disabled` / `invalid`（隔离） | DISABLED |
| P1-01 `status.txt=STALE`（碰撞清理）/ `UNKNOWN`（历史） | 非规范值：按 §5 非法；使用方先经 §7 映射或置 DISABLED 审计 |

**一次性任务主路径**（验收要求）：
```
成功：PENDING → STARTING → RUNNING → STOPPED
失败：PENDING → STARTING → RUNNING → FAILED
```
对应 legacy 每轮执行（time/advanced/run-once/immediate）：RUNNING→SUCCESS =
PENDING→…→STOPPED；RUNNING→FAILED = PENDING→…→FAILED（§3 已含，测试 §8 断言）。

## 8. 校验函数与独立测试

| 文件 | 角色 |
| :--- | :--- |
| `docs/architecture/task-state-machine-transitions.tsv` | 转换表（单一事实源之一，机器可读） |
| `tests/state-machine/lib.sh` | 校验函数（POSIX sh，可被 daemon source）：`task_state_is_valid`、`task_state_cause_is_valid`、`task_state_transition`（0/1/2）、`task_state_rehydrate`、`task_state_from_legacy`、`task_state_log`（钩子）；`TSM_STATES`/`TSM_ALLOWED`/`TSM_CAUSES` |
| `tests/state-machine/test.sh` | 状态机测试（bash 运行器） |

运行：

```bash
bash tests/state-machine/test.sh   # 期望：全 [PASS]，exit 0
```

测试覆盖（183 项断言）：
1. 11 状态全部合法、垃圾状态/遗留值非法；
2. **11×11 穷举**：允许边 ⇔ `TSM_ALLOWED` 精确一致（121 对）；
3. **TSV 与 lib 一致性**：表中 FROM>TO 边集合 == lib 允许集；表中 cause 令牌全部
   属于规范集合；
4. cause 令牌合法性（合法全认可、垃圾拒绝）；
5. 允许边 + 未知 cause → rc=2；
6. 重启再水合：执行态→FAILED、其余保留；
7. legacy 映射全表（status.txt 与 P1-02 值）；
8. 一次性任务主路径：成功/失败两条链全允许；
9. 非法边拒绝且 `[WARNING] …ILLEGAL…` 记录；`TSM_LOG=0` 静音；
10. DISABLED 进出（enable/disable）与重启保留。

## 9. 验收标准对照

| 验收要求 | 落实 |
| :--- | :--- |
| 状态转换可独立测试 | §8：纯函数 + 121 对穷举 + 表一致性断言；`bash tests/state-machine/test.sh` 全绿（183 PASS，exit 0） |
| 明确每个允许转换 | §3 35 条允许边全表（TSV 单一事实源 + 文档渲染） |
| 明确触发原因 | §4：需求七类 + 扩展令牌，逐类对应边 |
| 非法转换拒绝并记录 | §5：默认拒绝 + `[WARNING] ILLEGAL` 日志钩子 + 绝不退出/清库 |
| 11 状态定义 | §2（DISABLED/PENDING/WAITING/STARTING/RUNNING/HEALTHY/UNHEALTHY/RECOVERING/FAILED/STOPPING/STOPPED） |
| legacy 一次性任务映射 | §7 两条主路径，测试 §8.8 断言 |
| Supervisor 未实现时 HEALTHY/UNHEALTHY 等已预留 | §3 reserved 边 + §2 语义定义；状态与边完整定义但 daemon 未接线（验收即“预留”） |

## 10. 非目标与后续任务

- **不改 daemon**（C2/C4）；本机是模型/校验层，接线（写 status.txt、daemon 启动置
  初态、超时/停止实现）属于后续任务。
- **不实现** Supervisor（健康探测）、依赖/条件门控、重试退避的执行逻辑——`reserved`
  边已定义，交由相应 P1 任务接线。
- **不新增**状态：任何新需求（如“PAUSED”）必须先过本机评审：若可用现有 11 态表达
  则不新增；确需新增则更新 TSV + lib + 测试三处（一致性由 §8.3 保证）。
- P1-02 的 `runtime.state` 枚举以此为准（`docs/architecture/task-schema-v2.md` §9
  已指向本机；`task_state_from_legacy` 提供旧值映射）。

## 11. 交叉引用：DAG / 链式调度（P6-05，追加不重写）

- **183 条迁移与 11 态枚举冻结不变**。P6-05 DAG 裁决（`docs/architecture/dag-schema-v1.md`
  D50，草案待批准）明确：链运行状态（`PENDING/RUNNING/SUCCESS/FAILED/CANCELLED`）是
  `$base/dag/<chain>/runs/<run>/run.txt` 的**文件级聚合记录**，不是任务状态枚举扩充；链内
  节点态仍由本机 11 态（`state.txt`）管辖，复用既有 `PENDING>WAITING`/`WAITING>STARTING`/
  `WAITING>FAILED` 等 reserved→wired 通道语义，链传播失败沿用 `gate_fail` 事件令牌
  （RT_EVENTS，非 TSM_CAUSES，D13 先例）。
- `tests/state-machine/test.sh`（183 断言）为守卫：任何 DAG 实现若触碰本机三处一致性
  （TSV/lib/测试）即回归失败。