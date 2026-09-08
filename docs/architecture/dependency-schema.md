# Dependency & Condition Schema 规范与裁决 ADR（P4-02）

> **状态**：已接受（P4-02 冻结）
> **作者/日期**：P4-02 · 2026-09-04
> **上游**：`docs/P4-DEPENDENCY-REQUIREMENTS.md`（FR-1..FR-8 / NF-1..NF-8）、
> `docs/P4-BASELINE-COMPATIBILITY.md`（B5/B9）、Task Schema v2（
> `docs/architecture/task-schema-v2.md` + `task-schema-v2-validation.md`）、
> `docs/architecture/task-config-store.md`、`docs/architecture/config-authority.md`
> **配套实现**：Runtime §26 `dep_*`/`cond_*`（`system/bin/su-scheduler-runtime`）
> **关联**：P4-03（存在性/环检测）、P4-05（Required/Optional 传播）、P4-06
> （Condition 求值引擎）、P4-10（上限常量复用）

---

## 1. 背景与冲突

Task Schema v2（P1-02）预留 `dependency`/`condition` 字段但**未定义解析语义**
（`task-schema-v2.md` §3/§5 描述 `dependency` 为空列表、存 id 列表且「空格分隔」）。
P4 Dependency 需求（FR-3）则以 **逗号** 举例（`dependency=a,b,c`）。两个权威来源
对同一字段的**分隔符描述不一致**，且 P1-02 对「Required/Optional / 期望终态」的
单条 entry 语法无定义。本 ADR 冻结冲突裁决与正式语法。

---

## 2. 裁决（D1–D5）

### D1 规范分隔符 = 逗号；解析容忍空格/制表符（解决 schema「空格」vs FR-3「逗号」）

- **规范保存（canonical form）**：`dependency=a,b,c`——逗号分隔，单任务依赖列表
  以**逗号作为唯一写回分隔符**（`dep_normalize` 保证写回为逗号）。
- **解析容错**：读取/校验时同时容忍 **空格 / 制表符**作为分隔（兼容早期 schema
  文档对「空格分隔」的描述与潜在旧数据）。容错只发生在**输入侧**；任何持久化
  写回（`tcfg_apply_task`/`tcfg_set_field`/emit）一律使用**规范逗号**。
- 空值 `dependency=`（或键缺省）= 无依赖，恒通过。

### D2 单条 entry 语法 `[?]<task-id>[:<STATE>]`（Required/Optional 表示法）

- `?` 前缀 → **Optional**（缺省 Required）。
- `:<STATE>` 后缀 → 指定**期望终态**；STATE ∈ {**STOPPED**, **FAILED**}（TSM 两
  个终态）。缺省 = **STOPPED**（「已执行成功」语义）。
- 组合：`?t_boot:FAILED` = Optional 依赖 t_boot 且期望其 FAILED。
- 保留符号：`?`（Optional 前缀）、`:`（STATE 分隔）、STATE 枚举关键字。三者均
  **不在** task id 字符集 `[A-Za-z0-9_.-]` 内 → 解析无歧义。
- task-id 本身须过既有 id 规则（同 `tcfg_editor_id_ok`：charset
  `[A-Za-z0-9_.-]`、非空、无 `..`/`/`/`*`），杜绝路径穿越 / glob 注入。
- **P4-05 依赖说明**：本表示法为 Required/Optional 运行期失败传播策略的直接输入——
  Required 依赖不满足 → 本任务**不执行**（WAITING 等待 / 超时 FAILED，reserved
  边）；Optional 依赖不满足 → **不阻塞**（忽略该条，仍按其余依赖判定）。

### D3 condition 字段 = 存储层安全约束（求值文法归 P4-06）

- 单行、**可打印 ASCII**（拒绝换行/控制符/高位字节）。
- 长度 ≤ **256**（`COND_MAX_LEN`）。
- 空/缺省 = 无条件（恒真占位）。
- **本任务只做存储层安全校验，不做求值**。完整表达式文法白名单（谓词集合、
  语法树）归 P4-06；注入面（`eval`/`sh -c` 拼接）在任何阶段均禁止
  （P4-DEPENDENCY-REQUIREMENTS §4）。

### D4 上限常量与作用域

- 常量：`DEP_MAX=32`（单任务依赖条数上限，超则拒绝）、`COND_MAX_LEN=256`。
  定义于 Runtime §26 顶部，供 P4-10（资源/上限）复用；`DEP_MAX` 同时受
  Runtime 既有资源上限护栏约束（不引入新维度失控）。
- 作用域：仅 **Task v2（managed 域）**。Legacy `config.txt` 格式零改动（C4）；
  Legacy 解析/执行路径（daemon 既有主循环、heredoc、modifiers、execute_task）
  零改动（C2）；`service.sh` 零改动（C5）。`dependency`/`condition` 只在
  task-config 权威存储与 Task Editor payload 校验路径生效。

### D5 错误与原子性

- 非法字段（语法/枚举/超长/控制符/超上限）→ **后端权威校验拒绝（rc 非 0）**，
  失败时原 task 文件 / config **逐字节不变**（沿用 tmp+mv 原子写 + 回滚，B9）。
- 错误消息遵循 `docs/architecture/task-editor-schema.md` §5.3 风格：
  `[editor] ERROR: <field> <原因>` / `[task-config] ERROR: <原因>`，指明字段名与
  约束（含上限值），不输出字段原文内容以外多余数据。

---

## 3. 正式语法

```
dependency-value  := "" | entry-list
entry-list        := entry (sep entry)*
sep               := "," | SP | HT          # 规范写回只用 ","（D1）
entry             := ["?"] task-id [":" state]
state             := "STOPPED" | "FAILED"   # 缺省 STOPPED（D2）
task-id           := 同 Task id 规则（[A-Za-z0-9_.-]+，无 ".." | "/" | "*"，非空）
reserved          := "?" ":" "STOPPED" "FAILED"

condition-value   := "" | expr
expr              := 可打印 ASCII（0x20..0x7E），无换行/控制符，≤256
                     （文法白名单与求值归 P4-06；本任务只做安全约束）
```

约束：
1. entry 数 ≤ `DEP_MAX`（32）；超出 → 拒绝。
2. 纯分隔符串（如 `,,`/`   `）解析为**空依赖**（非合法条目列表）。
3. 空段（连续分隔符，如 `a,,b`）**宽容跳过**（不产生空条目、不拒绝）——与
   空格容错同为解析侧 lenient 行为；规范化写回会移除空段。
4. `dependency` 值内的可打印性检查：任一字符不在 `0x20..0x7E` → 拒绝。

## 4. 错误码与消息表

| 场景 | rc | 消息（示例） |
| :-- | :-- | :-- |
| dependency 语法非法 | 1（`set`）/1（`validate`→rc1，`EDIT_TASK`→rc4） | `[editor] ERROR: dependency syntax invalid (got 't_a:IDLE'; expect '[?]<task-id>[:STATE]', ',' or space separated, <= 32 entries)` |
| dependency 超条数上限 | 同上 | `dependency … <= 32 entries`（同表第一行） |
| dependency 含控制符/非 ASCII | 同上 | 同语法非法 |
| dependency id 路径穿越 | 同上 | 同语法非法（`..`/`/`/`*` 由 `tcfg_editor_id_ok` 拒绝） |
| condition 非法（非可打印/超长） | 同上 | `[editor] ERROR: condition invalid (got '<值>'; printable ASCII, <= 256 chars)` |
| `tcfg_set_field` dependency/condition 非法 | 1 | `[task-config] ERROR: invalid dependency '<值>' (…)` |
| `tcfg_validate_task` 遇非法 dependency/condition 条目 | 1 | （文件级非法；读取侧 lenient 跳过该条目，P1-02 §2） |

> IPC 信封侧：`VALIDATE_TASK`/`EDIT_TASK` 校验失败统一
> `configuration_invalid`（rc 4）+ `task invalid (config unchanged)`（
> task-editor-schema.md §5.1）；底层 `tcfg_editor_validate_payload` rc1 +
> stderr `[editor] ERROR:` 明细。

## 5. 持久化接线点（P4-02 落地）

| 接线点 | 行为 |
| :-- | :-- |
| Runtime §26（新） | `dep_*`/`cond_*` 纯 POSIX 校验/规范化函数（`dep_entry_ok`/`dep_validate`/`dep_normalize`/`cond_validate`）+ `DEP_MAX`/`COND_MAX_LEN` |
| §19 `tcfg_validate_task` | dependency/condition 语法 sanity（文件级合法判定；P4-03 在此叠加存在性/环检测） |
| §19 `tcfg_set_field` | `set dependency/condition` 时先 `dep_validate`/`cond_validate`，非法拒绝（原文件逐字节不变） |
| §19 `_rt_emit_task` / 新建模板 | 写回 `dependency=`/`condition=`（空值或规范逗号分隔） |
| §23 `tcfg_editor_validate_payload` | key case 接受 `dependency`/`condition`（不再按未知键拒绝），合法通过 / 非法报错 |
| CLI `task-config show/set` | 经 tcfg 通用键路径自然支持两键；`show` 回显含两字段 |
| `runtime_lib_selfcheck` | 注册 `dep_*`/`cond_*` |

## 6. 后果

- 正向：字段语法/校验单一事实源，CLI/Editor/IPC 全走同一 §26 校验；Task v2
  文件可安全承载依赖/条件配置；P4-03..P4-06 消费同一解析语义。
- 代价：空格与逗号两种分隔符并存于输入（规范化收敛到逗号）；单条 entry 语法
  从「纯 id 列表」升级为「`[?]id[:STATE]`」，旧文档「空列表/空格分隔」描述被
  取代（task-schema-v2.md / task-schema-v2-validation.md 同步更新）。
- 回退：§26 为纯增量（新 § + 既有 §19/§23 key 分支扩展），移除不影响既有
  解析/执行路径；无破坏性结构变更。

---

## 7. P4-03 增补裁决：依赖图校验与循环检测（ADR D6–D10）

> **状态**：已接受（P4-03 冻结）。在 D1–D5 之上叠加图级引用完整性校验。

### D6 未知依赖拒绝；前向引用允许

- `dependency` 引用的 task-id 在 task-config 目录（含自身）中不存在 → 校验
  拒绝（rc 非 0）。**前向引用（引用后续才定义的任务）允许**，只要最终图无环
  且全部存在——引用完整性按「目录全集」判定，不按文件顺序判定。

### D7 自依赖与环检测（简单 DFS，无通用 DAG）

- 自依赖（任务 dependency 含自身 id）→ 拒绝（属环特例，单独报
  `self-dependency in '<id>'`）。
- 直接环（a→b→a）与间接环（a→b→c→a）均拒绝。检测算法 = 简单 DFS/迭代
  （N≤32×任务数，POSIX sh 可实现），**不引入通用 DAG 调度器**（P4 明确禁止）。
- 环错误消息含完整环路径（`cycle: a->b->c->a`），便于定位。

### D8 Optional（`?`）不豁免环/未知校验

- Optional 的语义是「依赖失败时不阻断执行」（P4-05 消费），但**引用完整性仍
  必须成立**：`?` 条目同样参与未知 id 与环检测（引用关系即边），未知/环在
  P4-03 一律拒绝。环中任一环即拒绝（简单策略）。

### D9 图校验接入点（全部落盘写路径，后端权威）

| 接线点 | 行为 |
| :-- | :-- |
| `tcfg_apply_task`（经 `tcfg_editor_validate_payload`） | 以「当前目录 + 该 payload 替换原文件后的有效集合」校验（新建/编辑一视同仁）；失败不写盘 |
| `tcfg_set_field`（dependency 键） | 写改后同样以「当前目录 + 写改后的有效集合」校验 |
| `tcfg_import` | 整体导入校验「最终有效集合」= 既有 task-config + staging 提升后；失败 config 逐字节不变 |
| `sched_snapshot_managed` | 快照构建时过滤：源目录图非法 → KEPT（不写 current、维持旧快照） |
| `dep_validate_graph <dir> [<id>] [<content>] [<prefix>]` | 新图函数；遍历 `<dir>/*.task` 构建 id 集合 + 依赖边；`<content>` 为覆盖节点新内容；错误写 stderr |

### D10 错误码与消息约定（沿用 D5 / task-editor-schema §5.3）

- 失败 → rc 非 0 + 具体原因（`unknown dependency 'x' in 't_a'` /
  `self-dependency in 't_a'` / `cycle: a->b->c->a`）。
- 前缀：editor 路径 `[editor] ERROR:`（`tcfg_editor_validate_payload`）；
  set/import/snapshot 路径 `[task-config] ERROR:`。
- IPC 信封统一 `configuration_invalid`（rc 4）+ `task invalid (config unchanged)`；
  底层明细在 stderr。

---

## 8. P4-04 增补裁决：WAITING 门控决策层（ADR D11–D14）

> **状态**：已接受（P4-04 冻结）。在 D1–D10 之上把 TSM reserved 边
> （PENDING>WAITING / WAITING>STARTING / WAITING>PENDING / WAITING>FAILED）
> 接入调度层，实现「触发匹配但依赖未满足 → WAITING」门控链。
> **配套实现**：Runtime §20 `sched_dep_satisfied` / `sched_gate_check` /
> `sched_advance_waiting` / `sched_gate_*` + `WAIT_MAX`；`sched_execute_one` 门控
> 插入点；`scheduler_tick` WAITING 复查通道；`state_rehydrate_residual` WAITING
> 保留（P4-04 合法语义变更）。详见 docs/P4-04.md。

### D11 门控插入点

- 门控判定位于 `sched_execute_one` 的 due=Y 分支内、`trigger_decide` 返回 due
  之后、`action_run` 之前；已 WAITING 任务由 `scheduler_tick` 首部的 advance 通道
  逐周期复查（每个 tick 至多一次）。
- 门控判定入口（单一）：`sched_gate_check <tasks_dir> <id>` → 0=通过 1=未通过；
  当前仅依赖维度，P4-06（Condition 求值）在同一入口叠加 AND 语义。

### D12 依赖满足判定

- 解析复用 §26：`dep_normalize`（D1 容错）得规范逗号串，逐条切分
  `[?]<task-id>[:<STATE>]`（D2）。
- 被依赖任务实时态 = `runtime_current_state "<tasks_dir>/<dep_id>"`——只读运行
  目录 `state.txt`（缺省 PENDING），**无副作用**（需求 §4 边界）。
- Required 条目须达到该 entry 指定 `:STATE`（缺省 STOPPED）才算满足；`?` Optional
  未满足**不阻断**（只记 `opt-unsat:` 原因；失败传播策略归 P4-05）。
- 依赖任务处于 **WAITING** 视为未满足（等待其先解除）。
- `DISABLED` 任务不做门控（沿用既有行为）。

### D13 WAITING 边接线（cause 令牌）

| 场景 | 转换 | 事件令牌（RT_EVENTS） | TSM cause（语义） |
| :-- | :-- | :-- | :-- |
| 触发匹配 + 依赖未满足 | PENDING>WAITING | `gate_wait`（msg=原因如 `dep unsat: t_b`） | time_trigger |
| 依赖全部满足 + 触发仍匹配 | WAITING>STARTING | `gate_ok` | time_trigger |
| 依赖满足但触发不再匹配 / 依赖未满足且触发不再匹配 | WAITING>PENDING（rearm） | `rearm` | rearm |
| 依赖未满足 + 触发仍匹配 + 超过 `WAIT_MAX` | WAITING>FAILED | `gate_fail`（msg=`wait timeout …`） | action_failure |

- `gate_*` 令牌只入 `RT_EVENTS`，**不入** `TSM_CAUSES`（TSM cause 保持规范令牌；
  `state_log_event` 对 WAITING 边不校验 cause，写入校验通过）。
- 终态（STOPPED/FAILED）任务触发时先 `rearm` 回 PENDING 再门控（TSM 无
  STOPPED>WAITING 边；FAILED>WAITING 保留给重试退避语义）。
- 超时兜底优先级：**依赖满足判定先行**（满足即解除/执行）；`WAIT_MAX` 超时作为
  「触发窗口内持续等待」的后置硬性兜底，保证无永久 WAITING。
- `WAIT_MAX=86400` 秒（需求「有界 WAITING」硬性；依赖 P4-05 细化语义），可经
  环境覆盖（测试确定性）。

### D14 每窗口一次 + 重启保留

- 进入 WAITING **不 mark** cycle（未解除不误标为已执行）；解除后同窗口至多执行
  一次（执行时 mark）——与 P3-03「同周期去重、配置变更后可执行一次」语义兼容。
- daemon 重启后 WAITING **原样保留**（`state_rehydrate_residual` 不再
  WAITING→FAILED，P4-04 合法语义变更）；下个 tick 复查依赖；`gate.wait_start`
  重启后重新计时（保持有界）。
- `runtime_dir_active` 视 WAITING 目录为活跃（门控等待豁免，不被上限修剪误删，
  P4-07 深化）；`supervisor_step` 对 WAITING 无动作（保持）。
- disable WAITING 任务沿用既有 tcfg/disable 路径，不报错。

---

## 9. P4-05 增补裁决：Required/Optional 失败传播（ADR D15–D17）

> **状态**：已接受（P4-05 冻结）。在 D11–D14 之上定义依赖任务终态/缺失/禁用后的
> 传播策略，保证**无永久 WAITING、终态稳定**。
> **配套实现**：Runtime §20 `sched_dep_satisfied` 细分返回码（0=满足 / 1=可等待
> 的未满足 / 2=终态不匹配立即失败）、`sched_advance_waiting` 的 dep-failed 分支、
> `tctl_start` force 跳过门控。详见 docs/P4-05.md。

### D15 Required 失败传播矩阵（门控 → 本任务终态）

| 依赖运行期事实 | entry `:STATE` | 本任务行为 | 事件/原因 |
| :-- | :-- | :-- | :-- |
| 终态 = 指定 `:STATE`（含 dep FAILED 且 `:FAILED`） | 任意 | 满足 → 执行 | `gate_ok` |
| 终态 ≠ 指定（如 dep FAILED 且缺省 `:STOPPED`） | STOPPED/FAILED | **立即** `WAITING>FAILED`（不等 WAIT_MAX） | `gate_fail` msg=`dep failed: t_b` |
| 缺失（registry 无此任务） | 任意 | 有界等待 → 超时 `WAITING>FAILED` | `gate_fail` msg=`wait timeout …; dep missing: t_b` |
| DISABLED（enabled=0，含曾 STOPPED/FAILED 后被禁用） | 任意 | 有界等待 → 超时 `WAITING>FAILED` | `gate_fail` msg=`wait timeout …; dep disabled: t_b` |
| 非终态（PENDING/RUNNING/WAITING…） | 任意 | 有界等待 → 超时 `WAITING>FAILED` | `gate_fail` msg=`wait timeout …; dep unsat: t_b` |

- **判定优先序**：终态不匹配（立即失败）> 缺失 > 禁用 > 非终态等待。同一判定
  函数内单次遍历即可分类（`sched_dep_satisfied` 返回 0/1/2 + stdout 原因）。
- `:FAILED` 语义 = 「依赖失败才执行」：依赖 FAILED 反而**满足门控**，本任务照常
  执行；依赖 STOPPED（成功）才是终态不匹配 → 失败。既有 entry 按条检查的语义
  自然延伸，无新增配置语法（C4 零改动）。
- 判定读 registry 任务文件（缺失检测 `registry_task_file`）+ 运行目录实时态
  （`runtime_current_state`），无副作用（需求 §4 边界延续）。

### D16 Optional 不参与失败传播

- `?` Optional 依赖任何终态（FAILED/STOPPED）或缺失/禁用均**不阻断**、**不导致
  本任务 FAILED**，仅记 `opt-unsat:` 原因；门控按其余 Required 依赖继续判定。
- Optional 依赖缺失/禁用与 Required 同走 registry 检测路径，但结果仅作原因记录。

### D17 手动 start / WAIT_MAX / 重试衔接

- **手动 start**：`tctl_start` 非 force 对 WAITING → 非法拒绝（rc 3，状态不变）；
  force=1（含 `tctl_restart` = stop + force start）对 WAITING → **跳过依赖门控**
  直接 `WAITING>STARTING`（TSM 允许边 manual_exec），并清除 `gate.wait_start`。
  `tctl_check` 仅健康探测，不改状态。
- **WAIT_MAX 语义**：默认 `86400` 秒，语义 = 「进入 WAITING 起（`sched_gate_start`
  落桩）超过仍不满足则 `WAITING>FAILED`」。经环境覆盖（测试短超时）。超时与
  dep-failed 均落 FAILED 终态，事件原因可区分（`dep failed` / `dep missing` /
  `dep disabled` / `wait timeout`），无永久 WAITING（需求 5 硬性）。
- **重试衔接**：WAITING>FAILED 到达终态后，后续 rearm（FAILED>PENDING）与既有
  语义一致；FAILED>WAITING 重试退避边**不在本任务接线**（P4-07），本任务只保证
  因依赖失败而 FAILED 的任务不悬挂、下一窗口可 rearm。

---

## 10. P4-06 增补裁决：Condition 受限表达式引擎（ADR D18–D22）

> **状态**：已接受（P4-06 冻结）。在 D3（存储层安全）之上定义受限表达式文法、
> 白名单谓词、求值语义与安全边界。**禁止任意 Shell 执行**（无 eval / sh -c 拼接 /
> 用户函数 / 重定向）。
> **配套实现**：Runtime §26b `cond_grammar_ok` / `cond_eval`（L4990–5210）、
> `sched_cond_check` 门控并列接入（§20）；写路径校验期拒绝（§19/§23）。详见
> docs/P4-06.md。

### D18 谓词白名单

表达式必须为 `{{ <谓词> }}` 包裹的**单谓词**（`{{`/`}}` 内首尾空白容忍）。白名单：

| 谓词 | 语义 | 校验约束 |
| :-- | :-- | :-- |
| `task.state(<id>) ==/!= <STATE>` | 另一任务实时态比较（读 `tasks/<id>/state.txt`，缺省 PENDING） | id 过 `secv_id_ok`；STATE ∈ TSM 11 态（`COND_TSM_STATES`） |
| `time.hour ==/!= <0-23>` | 当前小时 | 数字 0-23（去前导零，防 octal） |
| `time.minute ==/!= <0-59>` | 当前分钟 | 数字 0-59 |
| `time.wday ==/!= <0-6>` | 星期（0=Sunday） | 数字 0-6 |
| `env.<NAME> ==/!= <值>` | 白名单环境变量 | **仅** CONFIG_FILE / DATA_DIR / TASKS_DIR（`COND_ENV_ALLOW`）；其余 env.<X> 非法拒绝 |
| `file.exists(<绝对路径>)` | 文件/目录存在性（只读探测） | 必须绝对路径；仅允许 CONFIG_FILE 同目录或 DATA_DIR 下（词法包含 + 禁 `..`/`//`）；无运算符 |

### D19 运算符集合

- 仅 `==`（等于）/ `!=`（不等于）。`<` / `>` / `>=` / `<=` / `contains` **不在
  P4-06 范围**（ADR 声明，P5 可扩）。`file.exists` 无比较运算符（存在即真）。

### D20 三态语义

- **真** → 允许执行；
- **假** → 本轮不满足（**不进入 WAITING、不改状态、不 mark cycle**，直接跳过，
  下一周期再求值；`sched_advance_waiting` 中条件未满足 → rearm 回 PENDING）；
- **非法** → 校验期拒绝（写盘前，旧配置逐字节不变，D5/B9 原子性）+
  运行期防御（理论不应发生，`cond_eval` 返回 2，视为「不满足」并记录，不执行）。
- condition 空/缺省 = 恒真（不额外求值）。

### D21 安全边界

- 禁止 `eval` / `sh -c` / `$(...)` / 反引号 / 管道到命令 / 重定向 / 用户函数。
- 纯 POSIX 字符串解析 + case/字段比对 + 白名单表驱动，**绝不把用户表达式拼进任何
  被执行的 shell 片段**（`COND_PREDS` / `conde_charset_ok` 双保险）。
- `file.exists` 路径仅允许 CONFIG_FILE 同目录或 DATA_DIR 下（`conde_path_in` 词法
  包含 + 禁 `..`/`//`）；运行时只读探测，无副作用。

### D22 与依赖门控关系

- 条件与依赖门控**并列 AND**：依赖满足 + 条件真 → 执行；条件假 → 本轮跳过。
- `sched_gate_check`（依赖维度，返回 0/1/2，P4-04/05 契约）保持不动；条件维度由
  `sched_cond_check` 独立返回 0=通过 / 1=未满足 / 2=非法（防御），互不破坏返回码
  语义。

---

## 11. P4-07 增补裁决：Supervisor / Recovery / Retry 联动（ADR D23–D26）

> **状态**：已接受（P4-07 冻结）。接线 **FAILED>WAITING（重试退避）** reserved 边，
> 使依赖门控与 P3 既有 Supervisor/Recovery/Retry/Cooldown/Crash Loop 协同。
> **配套实现**：Runtime §20b `sched_retry_arm`/`sched_retry_pending`/`rty_policy`
> + `scheduler_tick` 接线 + `sched_advance_waiting` 退避复查 + `sched_execute_one`
> WAITING 屏蔽 + §14 state_sync WAITING 移出对账列 + §17 gate.fail 不 auto-recovery
> + §18 WAITING prune 豁免。详见 docs/P4-07.md。

### D23 FAILED>WAITING 退避接线

- 任务 FAILED（action_failure 执行失败 或 gate_fail 依赖失败传播）后，retry 策略
  允许（retry.max>0 且未达上限）→ 进入 WAITING 退避（reserved 边，cause rearm）。
- 运行目录工件：`retry.count`（已退避次数，≤ retry.max）、`retry.until`（退避截止
  epoch 秒，经 `sched_gate_epoch` 计时，重启后继续）。退避期间 `sched_execute_one`
  对 WAITING 一律不执行；到点 + 依赖满足 + 触发匹配 → `WAITING>STARTING`
  （gate_ok）执行。
- 未接线（retry.max=0 / 达上限 / cooldown 内）保持 FAILED 终态（既有
  FAILED>PENDING rearm 不变）。

### D24 退避与门控顺序

- 退避复查先于依赖满足判定：`retry.until` 未到 → 保持 WAITING（即使依赖已满足也
  不释放、不执行）；到点后**强制可执行**（重试针对失败动作本身，不依赖触发窗口，
  trigger_decide 对已过窗口的触发返回 due=N 时被 rty_release 覆盖为 due=1）。
- `sched_retry_pending` 返回契约：0=不在退避/已到截止（释放）；1=退避中（保持）。

### D25 依赖失败不 auto-recovery / 不重试

- gate_fail（依赖失败传播 / 依赖超时）落 FAILED 时写运行目录标记 `gate.fail`。
- Supervisor RECOVERING 分支遇 `gate.fail` → **不派发 recovery 动作**
  （restart/start/stopstart/script）→ 直接 FAILED（终态，等待 rearm/人工）。依赖
  失败 ≠ 进程崩溃。执行期失败（无 gate.fail）维持既有 recovery 语义。
- `sched_retry_arm` 对 `gate.fail` 任务同样不接退避（依赖门控失败不重试，仅记录
  原因；与 D15 失败传播矩阵一致）。

### D26 WAITING prune 豁免 / 重启恢复

- `runtime_dir_active` 原不把 WAITING 当活跃 → 会被 `runtime_prune_tasks` 误删。
  P4-07 改为 WAITING 任务目录在 prune 中**豁免**（门控等待中的活任务，P4-10 复查
  上限）。
- 重启后 WAITING 保留（P4-04）且 `retry.until` 桩继续计时（退避可跨重启继续）；
  终态（STOPPED/FAILED）对账后清除退避工件（retry.count/retry.until/gate.fail）。

---

## 12. P4-08 增补裁决：IPC 与 WebUI 依赖编辑器（ADR D27–D29）

> **状态**：已接受（P4-08 冻结）。通过既有 IPC 白名单开放 Dependency/Condition
> 配置，在 WebUI Task Editor Advanced 步骤开放两字段输入，**不新增 IPC op**。
> **配套实现**：webroot/app.js（TASK_FORM_SCHEMA + formToContent + validateForm）；
> Runtime 零逻辑改动（P4-02/03/06 后端权威已就绪，仅确认接线 + 版本 1.26.0）。
> 详见 docs/P4-08.md。

### D27 复用既有 IPC 路径（不新增 op）

- Dependency/Condition 编辑器开放**不新增** IPC op。前端「校验预览」仍走
  `VALIDATE_TASK`（payload 分支，P3-06 既有）；保存走 `EDIT_TASK`（payload 分支）。
- 后端权威校验已在 `tcfg_editor_validate_payload` 就绪：dependency 键 →
  `dep_validate`（语法/DEP_MAX/路径穿越）+ `dep_validate_graph`（未知 id/自依赖/环，
  P4-03）；condition 键 → `cond_validate`（可打印 ASCII/长度）+ `cond_grammar_ok`
  （谓词白名单/运算符 ==、!=，P4-06）。编辑器只把两键随 payload 传入。
- 错误信封沿用既有约定：`configuration_invalid`（rc 4）+ `task invalid (config
  unchanged)`（task-editor-schema.md §5.1）。**理由**：VALIDATE_TASK/EDIT_TASK 的
  payload 本就是「完整 Task v2 内容」通道，新增键只需在 §23 校验函数与表单 schema
  各加一处，无需协议扩展；新增 op 反而引入白名单/版本/文档多源维护成本。

### D28 前端校验非安全边界

- WebUI 对 dependency/condition 提供即时前端提示（validateForm）：dependency 条目
  `[?]<id>[:STATE]` 基础语法 + id 字符集；condition 形如 `{{ 谓词 }}` 且拒绝
  `;`/`$`/反引号/`|`/`>`/`<` 注入字符。
- **前端提示不构成安全边界**——最终以后端 `tcfg_editor_validate_payload` 为准
  （含图校验/文法白名单）；前端仅避免明显笔误、不拦截合法表达式。前端渲染经
  `input.value`/`textContent`（无 innerHTML / 无 Root 直执 / 无 eval）。
- 与 NF-5（WebUI 不直执 Root，配置经 IPC 白名单路径）一致：保存仍
  `write("EDIT_TASK", {id, payload})`，无新增直执通道。

### D29 失败原子性重申（B9）

- 编辑失败（依赖环 / 未知依赖 id / 非法 condition 文法 / 注入串）→
  `tcfg_apply_task` 校验不通过 → **不写盘**，task-config **逐字节不变**（既有
  tmp+mv 原子写 + 图校验在写前拒绝）。前端显示后端错误消息（「保存失败（旧配置
  未变）：rc=4 …」）。
- 该原子性与 P4-02 D5 / P4-03 D9 的「校验失败不写盘」契约一致，此处针对编辑器
  开放后新增的注入面重申并由 webui/editor、webui/security、fuzz 三套件锁定。

## 13. P4-09 增补裁决：CLI/日志可观测查询面（ADR D30–D33）

> **状态**：已接受（P4-09 冻结）。在 D11–D29 之上补齐依赖状态、条件结果与 WAITING
> 原因的**只读查询面**，不改任何调度/门控/Retry/Supervisor 实现。
> **配套实现**：Runtime §22 `obs_gate_state`/`obs_dep_state` + `web_agg_summary`
> waiting 计数 + `web_task_detail` 新字段 + §7 `task_cli_status` dependency=/Gate
> 行 + CLI `cmd_task_info` managed 附加行。详见 docs/P4-09.md。

### D30 可观测面复用既有 IPC 只读通道（不新增 op）

- 依赖/条件/门控状态全部经既有 `GET_TASK_DETAIL` / `GET_SUMMARY` /
  `GET_TASK_EVENTS` 暴露，**不新增 IPC op**（白名单仍 19 op，B7）。
- `dependency_state` = 当前门控判定摘要（ok|satisfied|waiting|unsat），复用 §20
  `sched_dep_satisfied` **只读消费**（返回码 0/1/2 映射，无副作用、不改工件）；
  无依赖 → `ok`，满足 → `satisfied`，可等待未满足（缺失/禁用/非终态）→ `waiting`，
  终态不匹配立即失败 → `unsat`。
- `gate_state` = 任务当前是否 WAITING + 原因，由 `obs_gate_state` 只读聚合运行目录
  `state.txt` + events.log 最新 gate 事件 / 工件（retry.until=退避中、gate.fail
  标记）得到，形如 `WAITING (dep unsat: t_b)` / `WAITING (retry backoff …)`。
- CLI 侧：`task status` 经既有 `task_cli_status_id` 通道补 `dependency=` 与 `Gate:`
  行；`task-info` 经既有旧工件命令在 managed 域附加 `Dependency:`/`Condition:`。

### D31 JSON 只增键不删改（B8 统一契约）

- `GET_TASK_DETAIL` task 对象既有字段（id/name/status/trigger/action/enabled/
  health/recovery/pid/last_*/restart_count/run_count/source/has_run_dir）**名字与
  结构零变更**，仅新增 `dependency` / `condition` / `dependency_state` /
  `gate_state` 4 键。
- `GET_SUMMARY` counts 既有 7 键（total/running/healthy/failed/disabled/unhealthy/
  unknown）不变，仅新增 `"waiting"`（WAITING 不再计入 unknown）。
- WebUI 前端对未知键既有容错（`counts.total || 0` 等），新键自动兼容，无需前端改动。

### D32 CLI 旧输出兼容

- task status / task-info 既有行格式**不动**（新行附加）：`dependency=`/`condition=`
  空值输出空；`Gate:` 行仅 WAITING 时输出（缺省空）；`task-info` 的
  `Dependency:`/`Condition:` 仅 managed 域显示（legacy 不显示新字段）。
- task-output / task-log 语义零改动（cmd_task_output 读 output.log、
  cmd_task_logs 走 GET_TASK_LOG 均保持既有行为）。

### D33 WAITING 控制行为固化（引用 D17）

- WAITING 下 start/stop/restart/check 行为沿用 P4-05 D17，**不再改动实现**：
  force start（含 restart）跳过门控直接执行（manual_exec）、非 force start 拒绝
  （rc 3）、stop 不写状态、check 只健康探测不改 state.txt。
- 查询面作为可观测证据：GET_TASK_EVENTS 返回 gate_wait/gate_ok/gate_fail/
  retry-backoff 事件且原因可读；测试固化这些控制行为 + 事件断言。

---

## 14. P4-10 增补裁决：安全、资源与兼容性加固复核（ADR D34–D35）

> **状态**：已接受（P4-10 冻结）。本任务是 P4 出口加固，在 D1–D33 之上做**资源/安全/
> 兼容性复核**。复核发现 **1 处生产缺陷**（D34）并最小修复；其余 7 项复核通过，
> 由既有实现 + 既有/新增断言共同锁定。详见 docs/P4-10.md 与 docs/P4-EXIT-REPORT.md。
> **配套实现**：Runtime §26 `dep_validate_graph`/`depg_dfs` 邻接表切分改 `cut`
> （D34）；版本 1.27.0 → 1.28.0。

### D34 依赖图邻接表切分改可移植 `cut`（B7/NF-7 回归修复）

- **缺陷**：P4-03 引入的 `dep_validate_graph`/`depg_dfs` 用
  `depg_targets=${depg_adjline#*|}` 切分邻接表（`<node>|<targets>`）。该 `|`-in-pattern
  参数展开正是 P3-10 D-IPC 修复在 Android 16 mksh 上确认失败的构造（B7/NF-7 已禁
  `${var#*|}`/`${var%%|*}`），会导致依赖图校验在 mksh 设备上失效（图校验拒绝失效
  → 未知/环依赖可能被放行）。属 P4-03 引入的 mksh 兼容回归，P4-10 复核发现。
- **修复**：两处（`dep_validate_graph` 主遍历 + `depg_dfs` DFS）改为
  `depg_targets=$(printf '%s' "$depg_adjline" | cut -d'|' -f2-)`——与 §21/§24
  P3-10 D-IPC 修法同源（`cut` 已为库内既有工具，C3 合规）。行为不变：邻接行恒含
  `|`（由 `grep "^$depg_n|"` 保证），`cut -f2-` 与 `${var#*|}` 产出等价。
- **守护测试**：`tests/p4-dependency/test.sh` §hard-p4-10 静态断言
  「生产脚本（runtime/schedulerd/CLI）零 `${var#*|}`/`${var%%|*}` 残留」+
  「`cut -d'|' -f2-` ≥3 调用点」。修前（HEAD 1.27.0）该断言 FAIL（5518/5552 命中），
  修后（1.28.0）PASS——FAIL→PASS 证据见 docs/P4-10.md §3。
- **版本**：1.27.0 → 1.28.0（同一 § 内缺陷修复，无 API 变更）。

### D35 WAITING 任务数量不设显式上限（WATING_MAX 取舍，D26 深化）

- **复核结论**：**不新增** `WATING_MAX`/`WAITING_MAX` 显式常量，理由：
  1. **有界终态**：每个 WAITING 任务在进入后 ≤ `WAIT_MAX`（86400s，D13/D17）即
     `WAITING>FAILED`/rearm，**无永久悬挂**（需求 5 硬性）——WAITING 数量不可能
     无限累积（单任务不重复计）。
  2. **registry 有界**：WAITING 任务目录数 ≤ 注册任务数（每任务至多一个运行目录），
     registry 规模由用户管理的 task-config 决定（managed 域），非攻击面增长。
  3. **prune 交互**：WAITING 目录在 `runtime_prune_tasks` 豁免（D26）是为「活任务
     不误删」，但豁免对象本身被 1/2 双门有界——不会形成「无限 WAITING 目录」的
     资源失控（非活跃 FAILED/STOPPED 目录仍受 TASK_DIRS_MAX=200 修剪）。
  4. **与 TASK_DIRS_MAX 语义区别**：TASK_DIRS_MAX 管「非活跃历史目录」上限（磁盘
     回收）；WAITING 是**有终态保证的活跃目录**，其上限由 WAIT_MAX + registry 规模
     隐式约束。若未来引入「注册任务数无上限 + 大量任务同时 WAITING」场景，再评估
     显式上限（复用 TASK_DIRS_MAX 语义即可，届时新增常量并接 runtime_dir_active）。
- **守护测试**：`§retry-p4-07` R5（WAITING prune 豁免，TASK_DIRS_MAX 下不误删）
  + `§gate-p4-04` D（WAIT_MAX 超时 FAILED）+ `§hard-p4-10`（WAIT_MAX=86400 常量断言）
  + `§obs-p4-09` O（summary waiting 计数有界）。取舍记录见 docs/P4-10.md §5 与
  docs/P4-EXIT-REPORT.md §2 item 3。

## 15. P4-11 增补裁决：真机复验发现的兼容缺陷（ADR D36–D37）

> **状态**：已接受（P4-11 冻结）。本任务是 P4 的设备矩阵与综合回归——在同一台
> KernelSU × Android 16 真机完整执行 `run_tests.sh --with-device`，首次激活
> Runtime 1.28.0 后暴露 **D34 同源新面**（mksh `(`-in-pattern 参数展开）与
> CLI/daemon 实例管理缺陷。前者属本 ADR（Condition 引擎解析层）；后者属
> CLI/daemon 生命周期层（见 docs/P4-11.md §3 D-B/D-C），非 schema 范畴。
> **配套实现**：`cond_grammar_ok`/`cond_eval` 的 task.state/file.exists 谓词提取
> 改 `cut`；daemon 单实例保护拒绝接管；cmd_stop 按 `/proc` cmdline 匹配。
> 详见 docs/P4-11.md。

### D36 mksh `(`-in-pattern 参数展开（D34 新面，B7/NF-7 回归）

- **缺陷**：P4-06 引入的 `cond_grammar_ok`/`cond_eval` 用
  `${conde_l#task.state(}` / `${conde_id%)}` 这种 **pattern 含裸 `(`/`)`** 的参数
  展开提取 `task.state(<id>)` / `file.exists(<path>)` 谓词参数。设备
  `/system/bin/sh`（mksh R59，Android 16）**无法解析**（`no closing quote`）→
  Condition 引擎两个函数语法错误 → 整个 Runtime 库（5622 行）source 失败 →
  daemon 降级 legacy（P4 全功能真机不可用）。bash/dash 正常，故宿主测试无法发现。
- **修复**：4 处改为
  `conde_id=$(printf '%s' "$conde_l" | cut -d'(' -f2 | cut -d')' -f1)` ——与 D34 /
  P3-10 D-IPC 同源手法（`cut` 已在库内 80+ 处使用，C3 合规）；语义不变（id/path
  字符集受 `secv_id_ok`/`conde_charset_ok` 约束，不含 `(`/`)`，cut 提取等价）。
- **守护测试**：`tests/p4-dependency/test.sh` §hard-p4-11 静态断言「生产库零裸
  `(`/`)`-in-pattern 参数展开」（修前 FAIL，修后 PASS）+ 真机 Runtime 1.28.0
  loaded + p3-device 28 PASS 全绿（FAIL→PASS 证据见 docs/P4-11.md §3 D-A）。

### D37 mksh 兼容面扩展声明（B7/NF-7 复核结论）

- D34 禁 `${var#*|}`/`${var%%|*}`、本 ADR 禁 `${var#...(`/`${var%)}`——复核结论：
  **Android 16 mksh 对 pattern 中裸 `|`、`(`、`)` 的参数展开均不可靠**（P3-10/
  P4-10/P4-11 三次真机确认）。新增 P4 代码一律用 `cut -d'<c>' -fN` 切分；写入
  ADR 决策记录，供 P5+ 引用。
- `runtime_lib_selfcheck` 已覆盖 cond/dep 函数存在性；宿主 dash -n + 真机
  `sh -n` 双语法门保持。

---

## 16. P5-02 增补裁决：Condition 运算符扩展语法冻结（ADR D38–D40）

> **状态**：已接受（P5-02 冻结）。本任务是**纯语法冻结**——先定新运算符的语法与
> 兼容边界，生产代码**零改动**（C1）。新运算符（`<`/`>`/`<=`/`>=`/`contains`）
> **不实现**；P5-03 严格按本 ADR 与 docs/P5-02.md §3/§4 落地，并执行既有断言
> 反转清单（p4-dependency R/U、fuzz.sh、错误消息，见 docs/P5-02.md §5）。既有
> `==`/`!=` 对所有谓词的求值语义**逐字节不变**。
> **配套实现**：Runtime §26b `cond_grammar_ok`（L5322–5389）/`cond_eval`
> （L5391–5453）——P5-03 修改；P5-02 仅冻结语法。基线常量不变：`COND_MAX_LEN=256`、
> `COND_TSM_STATES` 11 态、`COND_ENV_ALLOW=CONFIG_FILE DATA_DIR TASKS_DIR`、
> `conde_charset_ok`。详见 docs/P5-02.md。

### D38 新增运算符集合与适用矩阵（冻结）

- **新增运算符 5 个**：`<`、`>`、`<=`、`>=`（数值比较）、`contains`（字符串
  子串匹配）。`==`/`!=` 不变。
- **运算符适用矩阵**（docs/P5-02.md §3.1，P5-03 实现严格按此）：

| 谓词 | `==` | `!=` | `<` | `>` | `<=` | `>=` | `contains` |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| `time.hour` / `time.minute` / `time.wday` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `task.state(<id>)` | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `env.<NAME>` | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| `file.exists(<path>)` | 无运算符（存在即真，不扩展） | | | | | | |

- **裁决理由**：`time.*` 为数值域，序关系语义明确，`contains` 对纯数字无意义且
  易混淆 → **拒绝**；`task.state`/`env.*` 为枚举/字符串路径域，`<`/`>` 序关系
  语义未定义 → **拒绝**，`contains` 子串匹配对状态名/路径值有意义 → **允许**；
  `file.exists` 维持无运算符。
- **兼容性**：`==`/`!=` 语义不变；新运算符仅**叠加**到运算符白名单。

### D39 类型规则与空值/非法值语义（冻结）

- **数值域（`time.*`）右值**：纯数字（`case ''|*[!0-9]*`）→ 去前导零（防 octal）
  → 范围校验 hour≤23 / minute≤59 / wday≤6；空/非数字/越界 → **校验期拒绝**
  （写盘前，旧配置逐字节不变，B9 原子性）。
- **字符串域右值**：`task.state` 的 `==`/`!=` 右值须 ∈ `COND_TSM_STATES` 11 态；
  `contains` 右值非空且过 `conde_charset_ok`（`[A-Za-z0-9_/.:+-]`）；`env.*` 的
  `==`/`!=`/`contains` 右值均过 `conde_charset_ok`（非空）。
- **空值/非法值语义**（docs/P5-02.md §3.3）：表达式为空/缺省 → 恒真（P4-06
  不变）；运算符为空（谓词后无运算符）→ 校验期拒绝；运算符不在适用矩阵内（如
  `time.hour contains 8`）→ 校验期拒绝；**运行期非法**（绕过校验落盘）→
  `cond_eval` return 2，视为「不满足」不执行（防御，不变）。
- **长度**：`COND_MAX_LEN=256` **不变**（`cond_validate` 存储层上限维持）。

### D40 注入面新规则（P5-03 实现必须遵守）

- **`conde_op` 位置**（`IFS=' '; set --` 第 2 字段）：精确匹配运算符白名单
  `==`/`!=`/`<`/`>`/`<=`/`>=`/`contains` 之一；否则拒绝。
- **`conde_l` 位置**（第 1 字段，谓词）：谓词名是枚举白名单匹配（task.state /
  time.* / env.* / file.exists），不得以 `<`/`>` 作为谓词名的一部分。
- **`conde_r` 位置**（第 3 字段，右值）：`time.*` 纯数字校验天然排除 `<`/`>`；
  `task.state`/`env.*` 过 `conde_charset_ok` 天然排除 `<`/`>`/空白。
- **残余注入字符检查保留**（任何位置都拒绝）：`;`、反引号、`$(`、`sh -c`、`|`、
  `&`、`>`、`<`——**但仅对 `conde_l`/`conde_r` 位置生效**；`conde_op` 位置的
  `<`/`>`/`<=`/`>=` 是合法运算符 token，不受此限。不得对 `conde_in` 整体做
  `<`/`>` 拒绝（docs/P5-02.md §4.1 实现提示）。
- **禁止项**（延续 D21，扩展后同样适用）：禁 `eval`/`sh -c`/`$(...)`/反引号/
  管道到命令/重定向/用户函数；`contains` 求值用 **case 子串 pattern**
  （`case "$val" in *"$needle"*)`），不使用 `${var#*}` 截取（D37）；数值比较用
  `[ "$a" -lt "$b" ]` 等 `test` 原语（右值已做数字+范围校验，无 octal 风险）。
- **单谓词结构**：保持单谓词、单运算符，**不引入复合表达式**（`&&`/`||`/嵌套
  均禁止）；因无复合，优先级概念不适用（docs/P5-02.md §3.4）。

---

## 17. 交叉引用：DAG / 链式调度立项（P6-05，追加不重写）

> **状态**：引用 `docs/architecture/dag-schema-v1.md`（ADR D46–D58，**ACCEPTED 已批准 2026-09-08**，
> 引擎实现属 P6-06，此前零实现）。本节**不改动** D1–D45 任何裁决与运行行为，仅登记后续立项对本域的复用关系。

- **D46（P6-05 D-01）**：DAG 的边 = 本文 D1/D2 的 `dependency=` entry，**同一语法、同一校验器**
  （`dep_validate`/`dep_normalize`/`dep_entry_ok`/`dep_validate_graph`）。Required/Optional 与
  `:STATE` 语义与 D15/D16 一一映射（dag-schema D51）；D15 传播矩阵在链语境逐行复用，判定材料
  同源（dependency entry + 上游终态），仅新增「终态须落在本 run 登记簿（run.txt）」的 run 绑定层。
- **D55（P6-05 D-08）**：`dep_validate_graph` 计划**尾部叠加**链段校验（深度 ≤16 / 节点 ≤32 /
  边 ≤128 / 孤儿 `trigger=chain` 拒绝）；本文 D6–D10 的未知/自依赖/环检测行为、消息文案、
  覆盖节点协议与 D9 四写路径接入点**逐字节不变**（`tests/p4-dependency` + 新增
  `tests/p6-dag` 双侧 golden 锁定现行为作为升级基线）。
- Legacy 边界不变（D4/NF-1/C4）：`trigger=chain` 仅 Managed（B16 先例，dag-schema D47）。

---

## 附：决策记录

- 2026-09-04：P4-02 建立本 ADR（D1–D5 冻结）。D2 中 Required/Optional 的
  运行期消费由 P4-05 承接；D3 求值文法由 P4-06 承接；上限常量供 P4-10 复用。
- 2026-09-04：P4-03 增补 D6–D10（依赖图校验与循环检测）。环策略 = 简单 DFS、
  Optional 参与环校验、前向引用允许、图校验接入 apply/set/import/snapshot。
  运行时门控（P4-04）、Required/Optional 失败传播（P4-05）不在本 ADR 范围。
- 2026-09-04：P4-04 增补 D11–D14（WAITING 门控决策层）。门控插入点 =
  `sched_execute_one` due=Y 分支 + `scheduler_tick` WAITING 复查通道；`gate_*`
  事件令牌入 RT_EVENTS 不入 TSM_CAUSES；重启 WAITING 保留为合法语义变更。
  失败传播（P4-05）、Condition 求值（P4-06）不在本 ADR 范围。
- 2026-09-04：P4-05 增补 D15–D17（Required/Optional 失败传播）。Required 依赖
  终态不匹配 → 立即 WAITING>FAILED；缺失/禁用 → 有界等待超时 FAILED；Optional
  不参与失败传播；force start/restart 跳过门控；WAIT_MAX 有界语义成文。重试退避
  （FAILED>WAITING）留 P4-07，Condition 求值留 P4-06。
- 2026-09-04：P4-06 增补 D18–D22（Condition 受限表达式引擎）。白名单谓词（task.
  state / time.* / env.* 三白名单 / file.exists 受限路径）、运算符仅 ==/!=、三态
  语义（真执行/假跳过无副作用/非法校验期拒绝+运行期防御）、禁止任意 Shell 求值、
  与依赖门控并列 AND（sched_cond_check 独立契约）。重试退避留 P4-07，WebUI 开放
  编辑留 P4-08，CLI 查询展示留 P4-09。
- 2026-09-04：P4-07 增补 D23–D26（Supervisor/Recovery/Retry 联动）。接线
  FAILED>WAITING 重试退避（retry.count/retry.until 工件，GATE_NOW 计时重启可续）；
  退避先于依赖满足判定、到点强制可执行；gate.fail 标记 → supervisor 不 auto-
  recovery 且不接退避（依赖失败 ≠ 进程崩溃）；WAITING 目录 prune 豁免。WebUI 开放
  编辑留 P4-08，CLI 查询展示留 P4-09。
- 2026-09-04：P4-08 增补 D27–D29（IPC 与 WebUI 依赖编辑器）。Dependency/Condition
  编辑器开放**不新增 IPC op**——复用 VALIDATE_TASK/EDIT_TASK payload 路径，后端
  权威校验（语法+图+文法）已在 P4-02/03/06 就绪；前端校验非安全边界（仅即时提示，
  textContent 渲染、无 Root 直执/eval）；失败编辑 task-config 逐字节不变（B9 重申）。
  版本 1.25.0 → 1.26.0。CLI 查询展示留 P4-09。
- 2026-09-04：P4-09 增补 D30–D33（CLI/日志可观测查询面）。依赖/条件/门控状态经
  既有只读 IPC 通道暴露（不新增 op），dependency_state 复用 sched_dep_satisfied
  只读消费、gate_state 读运行目录状态/事件；JSON 只增键不删改（B8）；CLI 旧输出
  兼容（新行附加、空值输出空、legacy task-info 不显示新字段、task-output/log 语义
  零改动）；WAITING 控制行为固化引用 D17（不改实现）。版本 1.26.0 → 1.27.0。
- 2026-09-04：P4-10 增补 D34–D35（安全/资源/兼容性加固复核）。D34：`dep_validate_
  graph`/`depg_dfs` 邻接表切分从 `${var#*|}` 改为可移植 `cut -d'|' -f2-`（mksh
  `|`-in-pattern 回归，B7/NF-7，P3-10 D-IPC 同源）——P4-10 复核发现的唯一生产缺陷，
  最小修复 + FAIL→PASS 测试。D35：WAITING 任务数量**不设显式上限**（WAIT_MAX
  有界终态 + registry 有界 + prune 豁免对象有终态保证，理由与取舍成文）。其余 7 项
  复核通过（DEP_MAX/COND_MAX_LEN 写路径全覆盖、注入/穿越零 exec 零写、POSIX 语法、
  单 daemon 循环、Legacy 零改、无新依赖、无 eval）。版本 1.27.0 → 1.28.0。
- 2026-09-05：P4-11 增补 D36–D37（真机复验发现的兼容缺陷）。D36：`cond_grammar_ok`/
  `cond_eval` 的 `${var#task.state(}`/`${var%)}` pattern 含裸 `(`/`)`，Android 16
  mksh 无法解析 → Runtime 库 source 失败 → daemon 降级 legacy；4 处改
  `cut -d'(' -f2 | cut -d')' -f1`（D34/P3-10 同源手法）。D37：mksh 对 pattern 中
  裸 `|`/`(`/`)` 参数展开均不可靠（P3-10/P4-10/P4-11 三次真机确认），P5+ 一律用
  `cut` 切分。CLI/daemon 实例管理缺陷（cmd_stop pidof / 单实例保护）属生命周期层，
  记入 docs/P4-11.md §3 D-B/D-C。版本 1.28.0（不变，缺陷修复不 bump）。
- 2026-09-06：P5-02 增补 D38–D40（Condition 运算符扩展**语法冻结**，纯语法、
  生产代码零改动）。D38 新运算符 `<=`/`>=`/`<`/`>`（仅 `time.*` 数值域）与
  `contains`（仅 `task.state`/`env.*` 字符串域）适用矩阵冻结，`==`/`!=` 不变、
  `file.exists` 无运算符；D39 类型规则与空值/非法值语义（数值右值纯数字+去前导零
  +范围校验；contains 右值非空+`conde_charset_ok`；非法→校验期拒绝 B9，运行期
  防御 return 2；`COND_MAX_LEN=256` 不变）；D40 注入面新规则（conde_op 位置按
  运算符白名单精确匹配；conde_l/conde_r 残余注入字符仍拒绝；禁 eval/sh -c/$()/
  反引号/管道/重定向；contains 用 case 子串 pattern；单谓词无复合无优先级）。
  实现与既有断言反转归 P5-03（docs/P5-02.md §5）。版本 1.28.0（不变）。
- 2026-09-08：P6-05 追加 §17（DAG/链式调度立项交叉引用；引用 `dag-schema-v1.md` D46–D58
  草案，本文 D1–D45 与运行行为零改动；批准与实现归 P6-06）。
