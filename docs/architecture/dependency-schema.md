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

## 附：决策记录

- 2026-09-04：P4-02 建立本 ADR（D1–D5 冻结）。D2 中 Required/Optional 的
  运行期消费由 P4-05 承接；D3 求值文法由 P4-06 承接；上限常量供 P4-10 复用。
- 2026-09-04：P4-03 增补 D6–D10（依赖图校验与循环检测）。环策略 = 简单 DFS、
  Optional 参与环校验、前向引用允许、图校验接入 apply/set/import/snapshot。
  运行时门控（P4-04）、Required/Optional 失败传播（P4-05）不在本 ADR 范围。
