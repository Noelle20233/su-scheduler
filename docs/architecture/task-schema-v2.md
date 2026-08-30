# Su Scheduler — 内部 Task Schema v2（P1-02）

> **任务**：P1-02 · 定义内部 Task Schema v2
> **基线**：v1.6.8（`docs/phase-1-baseline.md`，P1-01）
> **性质**：**内部模型规范**——不改变 `config.txt` 格式（C4）、不删除/替换 legacy 解析与
> 执行路径（C2）、不引入 jq/Python/Node.js 等外部运行时（C3）；P1 只实现模型，
> **不实现**完整 JSON/YAML 用户配置解析。daemon 行为在 P1-02 中**零改动**，
> 模型是"投影"：从旧配置行推导出 Task 对象，供后续 P1 任务（调度/依赖/健康/
> WebUI 等）消费。
> **日期**：2026-08-30

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [术语与背景](#2-术语与背景)
3. [Schema 总览](#3-schema-总览)
4. [配置字段与运行时字段的边界](#4-配置字段与运行时字段的边界)
5. [字段明细](#5-字段明细)
6. [序列化](#6-序列化)
7. [id 与 name 分配规则](#7-id-与-name-分配规则)
8. [兼容转换规则（legacy → v2）](#8-兼容转换规则legacy--v2)
9. [运行时状态机](#9-运行时状态机)
10. [验收标准对照](#10-验收标准对照)
11. [非目标与非承诺](#11-非目标与非承诺)

---

## 1. 目的与范围

- **目的**：建立统一的内部任务对象（Task），使后续功能（依赖、条件、健康/恢复、
  重试、WebUI 展示、审计）都消费同一个对象，**不再把旧配置行直接当作任务执行**。
- **范围（P1-02）**：
  - 定义 Schema v2 字段、类型、缺省值、来源边界（config / derived / runtime）；
  - 定义序列化（POSIX 文本 `key=value`，无 JSON/JQ 依赖）；
  - 定义 legacy → v2 兼容转换规则（`docs/architecture/task-schema-v2-validation.md`
    另附字段校验规则）；
  - 提供 Task fixture 样例（`tests/fixtures/task-v2/samples/`，机器生成）。
- **范围外（P1 内也不行）**：不改 daemon；不解析用户 JSON/YAML；不引入外部运行时
  （无 jq / python / node / busybox 专有扩展硬依赖，仅 `sh/sed/grep/awk/cut` 等）；
  不实现条件/依赖/健康/重试的执行逻辑（字段为**策略占位**，缺省值即"不启用"）。

## 2. 术语与背景

| 术语 | 含义 |
| :--- | :--- |
| **legacy 行** | `config.txt` 中 `<trigger> <command>[;] : <modifiers>` 行（P1-01 §4 锁定）。 |
| **v1 任务（隐式）** | 现状：daemon 直接消费 legacy 行，无显式任务对象；行即任务。 |
| **v2 任务（显式）** | 本规范定义的对象；`schema_version=2` 固定。v2 是 v1 的**投影**：每个 legacy 任务行对应一个 v2 Task；行号/原文保存在 `source.*`。 |
| **投影（projection）** | 转换是**总函数**（每个任务行都能转），且**保持语义**：v2 字段如实记录 legacy 解析结果（含怪癖，见 §8），不做"应该怎样"的修正。 |

## 3. Schema 总览

字段来源标注：**C** = 源自 config.txt（配置意图）；**D** = 模型缺省（策略占位/派生）；
**R** = daemon 运行时独占维护；**X** = 常量。

| 字段 | 类型 | 来源 | 缺省 | 说明（详见 §5） |
| :--- | :--- | :-- | :--- | :--- |
| `schema_version` | int | X | **2** | 固定 = 2；非 2 → 条目隔离（见校验规则） |
| `id` | string | D | 见 §7 | 唯一标识；charset `[A-Za-z0-9_.-]` |
| `name` | string | D | `action.command` 首词（≤40） | 可读名；空 → `task` |
| `enabled` | bool | D | 1 | 0 = 停用（P1 仅模型，daemon 匹配行为不变） |
| `trigger` | string | C | — | legacy 触发器**原文**（冒号保留；C4） |
| `condition` | string | D | 空（恒真） | P1 保留字段 |
| `action.command` | string | C | — | 实际执行命令（`extract_command` 语义，P1-01 golden） |
| `action.notify_start` | bool | C | 0 | 开始通知 |
| `action.notify_end` | bool | C | 0 | 结束通知 |
| `action.delete` | bool | C | 0 | 执行后删除该行（`--delete`） |
| `action.termux` | bool | C | 0 | Termux 环境执行 |
| `action.interactive` | bool | C | 0 | 交互 shell（FIFO） |
| `action.run_once_now` | bool | C | 0 | 立即执行并修剪（`--run-once-now`） |
| `action.boot` | bool | C | 0 | **保留标志**：文档化 `--boot`，daemon 尚未实现（P1-01 Q10/D5） |
| `action.msg` | string | C | 空 | 自定义通知文案（`--msg="…"`，仅双引号形式） |
| `dependency` | list(string) | D | 空 | 依赖任务 id 列表；P1 保留 |
| `health.type` | string | D | `none` | 健康策略类型；P1 保留 |
| `recovery.type` | string | D | `none` | 失败恢复策略；P1 保留 |
| `retry.max` | int | D | 0 | 重试上限；0 = 不重试 |
| `retry.interval` | int | D | 60 | 重试间隔（秒） |
| `source.type` | enum(`line`\|`block`) | C | `line` | 来源形态 |
| `source.line` | int 或 范围 `a-b` | C | — | 行号（单行）/ 块范围（heredoc 头行-EOF 行） |
| `source.raw` | string | C | — | 原始内容（转义存储，§6） |
| `runtime.state` | enum | R | `idle` | 状态机状态（§9） |
| `runtime.run_count` | int | R | 0 | 累计执行次数 |
| `runtime.last_status` | string | R | 空 | 最近结果（success/failed/zombie） |
| `runtime.last_exit` | int | R | 空 | 最近退出码 |
| `runtime.last_start` | string | R | 空 | 最近开始时间 |
| `runtime.last_end` | string | R | 空 | 最近结束时间 |
| `runtime.pid` | int | R | 空 | 最近/当前进程 PID |

## 4. 配置字段与运行时字段的边界

**规则（唯一且明确）**：

1. **配置字段**（`enabled`/`trigger`/`action.*`/`condition`/`dependency`/`health.*`/
   `recovery.*`/`retry.*`/`name`/`id`/`source.*`）表达**用户意图与来源事实**：
   - 由 legacy 行转换而来（C 字段）或在创建时取缺省（D 字段）；
   - daemon 改动配置字段**仅限** legacy 语义内（`--run-once-now` 修剪 → 同步改
     `action.run_once_now` 与 `source.raw`；`--delete` 删行 → 任务条目移除）；
   - 除此之外，**任何执行结果都不得改写配置字段**。
2. **运行时字段**（`runtime.*`）反映**执行事实**，daemon 独占读写：
   - 每次执行更新 `runtime.state/last_*/pid/run_count`；
   - 加载器/重启**不得清空**运行时字段（历史保留原则，与 legacy 任务目录一致）；
   - 僵尸清理沿用 legacy 规则：daemon 启动时 `running` → `zombie`（对应
     `ZOMBIE_CRASHED`）。
3. **派生字段不存储**：如 `trigger.kind`（boot/time/weekly/...）、`next_run`、
   规范化名称——一律在读取时由 `trigger` 现算，避免派生数据与源数据不一致。
4. **边界判定口诀**：*config 回答"做什么、何时、附带什么意图"；runtime 回答
   "刚才发生了什么、现在在哪一步"。*

## 5. 字段明细

> 合法值/非法值/非法时动作的完整矩阵见
> `docs/architecture/task-schema-v2-validation.md`。本节只给语义。

- **schema_version = 2**：对象版本标识。**固定为 2**；任何其他值（缺失、1、3、非数字）
  → 该条目**隔离**（quarantine），daemon 继续运行、其余条目不受影响。
- **id**：唯一键。默认按 §7 派生；不允许与注册表内其他条目重复（重复 → 保留先见者，
  后者隔离并告警）。
- **name**：默认 `action.command` 第一行首词，截断 40 字符；空则 `task`。
- **enabled**：`0|1` 二值。`0` 的语义（P1 定义，不在 P1 接线）：跳过调度匹配、
  保留条目与历史；后续任务再接入 daemon。legacy 无停用概念 → 转换恒为 1。
- **trigger**：legacy 触发原文（`boot` / `HHMM` / `HH:MM` / `weekly:…` / `nweekly:…` /
  `monthly:…` / `nmonthly:…` / `yearly:…`）。**不做任何归一化**（去冒号只在匹配比较
  时由 daemon 现算，见 P1-01 §4.2；yearly 文档/实现格式差异 Q9 原样保留）。
- **condition / dependency / health.type / recovery.type**：P1 策略占位。
  - `condition` 空 = 恒真；非空值语法上合法但 P1 **不解释、不执行**；
  - `dependency` 空列表；存 id 列表（空格分隔；id charset 无空格，可安全切分）；
  - `health.type`/`recovery.type` = `none` 为唯一缺省；其他字符串 P1 接受但无行为
    （未来任务定义枚举）。
- **retry.max / retry.interval**：`0` 表示不重试；非法（负值/非数字）→ 回退缺省并告警。
- **action.command**：daemon 实际执行的命令字符串（`extract_command` 结果，P1-01
  `expected/extract_command.txt`）。**含怪癖原样**：heredoc 重构残留（`'; :`/`:`、
  字面 `\n`）、boot heredoc 头部形式、yearly 格式等（§8）。
- **action.\***：布尔标志 `0|1`（`--msg` 为字符串）。语义逐条锁定自 P1-01 §5.5-5.8/§6。
- **source.type / source.line / source.raw**：转换来源；
  - `line`：单任务行（`source.line=N`）；
  - `block`：heredoc 块（`source.line=头行-EOF行`，如 `35-37`）；
  - `source.raw` 保存旧配置**原始内容**（转义存储；块 = 头行+块体行，不含 EOF 行、
    含字面 `\n` 转义；与 daemon 读取一致）。
- **runtime.\***：见 §4.2 与 §9。

## 6. 序列化

**格式**（P1 约束：无 jq/Python/Node，daemon 现成工具可读）：

```
# 注释行（元数据，可选）
schema_version=2
id=t29_1430
...
key=value
```

1. 每任务一个文件：`samples/<id>.task`（fixture）；运行时注册表拟路径
   `/data/adb/su-scheduler/tasks-v2/<id>.task`（**P1-02 只约定、不创建**，创建权属
   后续接线任务）。
2. 行 = `key=value`；**值 = 首个 `=` 之后全部字符**（无引号语义）。
3. **转义**（存储层）：反斜杠 → `\\`；真实换行 → 字面 `\n`（两字符）。解码器必须
   反转义；未知转义序按字面保留（lenient）。
4. **禁止**：原始控制字符（除 `\n` 转义外）、键内空格（键 charset `[A-Za-z0-9._]`）。
5. **原子写**：先写 `*.tmp` 再 `mv`；任何失败不截断/不留下半成品覆盖。
6. 读取：`grep`/`awk` 按 `^key=` 提取；**未知键忽略并告警**（兼容未来扩展字段）。

## 7. id 与 name 分配规则

- **id 默认规则**：`t<source.line>_<trigger_norm>`，其中 `trigger_norm` = 触发器去冒号
  （同 daemon L650 语义）。
  - 例：行 29 `14:30 …` → `t29_1430`；行 11 `boot …` → `t11_boot`；
    行 20 `weekly:1:0800 …` → `t20_weekly10800`；heredoc 块 35-37 → `t35_0915`。
- 唯一性：同一快照内行号唯一 ⇒ id 唯一。异常（重复）→ 先见者保留，后者追加后缀
  `-N` 隔离。
- **name 默认规则**：`action.command` 首词（截断 40）；空 → `task`。
- 以上均为**缺省派生**；后续版本若允许用户在配置中显式命名/指定 id，须走独立字段
  （P1 配置格式不改，故 P1 中 id/name 永远是派生值）。

## 8. 兼容转换规则（legacy → v2）

### 8.1 转换函数（总函数，逐字段规则）

对每个**任务行**（非注释、非空行；heredoc 头行 + 其块体）`L`：

1. `cl = trim(L)`（daemon 修剪语义，P1-01 §4.1）；
2. `trigger = 首词(cl)` 原文；
3. `parse_modifiers(cl)`（**daemon 真实函数语义**，P1-01 golden）→ 填充
   `action.notify_start/notify_end/delete/termux/interactive/run_once_now/msg`；
4. `extract_command(cl)` → `action.command`；
5. `--boot` 出现在 mods → `action.boot=1`（保留标志；**不得**因此改变任何执行行为）；
6. heredoc 块：`action.command = extract_command(重构行)`（重构 = daemon L632-646 语义，
   含 ` : : ` 工件与字面 `\n`；P1-01 `expected/heredoc-reconstruction.txt`）；
7. `source.type/line/raw` 按 §5；
8. 其余字段取缺省（§3）。

### 8.2 全映射矩阵（fixture 实证）

| legacy 行/块（P1-01 fixture） | → Task sample | 关键字段 |
| :--- | :--- | :--- |
| L11 `boot echo …; : --notify` | `t11_boot.task` | trigger=boot；notify_start=1, notify_end=1 |
| L12 `boot sh; : --interactive` | `t12_boot.task` | interactive=1 |
| L13 `boot pkg …; : --termux` | `t13_boot.task` | termux=1 |
| L16 `08:30 logcat -c; : --notify-end --msg=…` | `t16_0830.task` | notify_end=1；msg="Logs cleared" |
| L17 `0830 echo …` | `t17_0830.task` | 无修饰符，全 0 |
| L20 `weekly:1:0800 …; : --notify-start` | `t20_weekly10800.task` | notify_start=1 |
| L21 `nweekly:2:5:1400 …` | `t21_nweekly251400.task` | 无修饰符 |
| L24 `monthly:01:0000 …; : --notify` | `t24_monthly010000.task` | notify 双端 |
| L25 `nmonthly:3:15:1200 …; : --msg=…` | `t25_nmonthly3151200.task` | msg="Quarterly done" |
| L26 `yearly:12:25:0800 …; : --delete --notify` | `t26_yearly12250800.task` | delete=1, notify 双端 |
| L29 `14:30 …; : --run-once-now --notify` | `t29_1430.task` | run_once_now=1, notify 双端 |
| L30 `08:00 …; : --delete` | `t30_0800.task` | delete=1 |
| L31 `10:00 …; : --interactive` | `t31_1000.task` | interactive=1 |
| L32 `boot …backup.sh; : --delete` | `t32_boot.task` | delete=1 **（boot 行：legacy 不自毁，Q6 原样）** |
| 块 35-37 `09:15 python <<EOF; : --termux --notify` | `t35_0915.task` | termux=1；command 含重构残留 |
| 块 39-42 `weekly:7:2300 sh <<EOF; : --notify --msg=…` | `t39_weekly72300.task` | notify 双端；msg；块范围 |
| L45 `22:00 echo …` | `t45_2200.task` | 无修饰符；末行无换行边界（P1-01 锁定） |

### 8.3 转换必须**保留**的怪癖（禁止"顺手修正"）

| 怪癖 | 转换处理 |
| :--- | :--- |
| boot+`--delete` 不自毁（P1-01 Q6） | `action.delete=1` 照录；`trigger=boot` 照录；**不**推断"应自毁" |
| boot+heredoc 块体不执行（Q6） | `action.command` = 头部形式（如 `sh <<EOF` 残留）；`source.type=block` |
| heredoc 重构 ` : : ` 工件与残留（Q5） | `action.command` = `extract_command(重构行)` **原文残留** |
| boot+`--run-once-now` 双执行（Q6） | `action.run_once_now=1` 照录（legacy 行为，转换不动） |
| yearly 文档/实现格式差异（Q9） | `trigger` 原文照录；**不**改写为文档格式 |
| `--boot` 无实现（Q10） | `action.boot=1` 保留标志；**不**产生任何执行语义 |
| 失败通知无条件（Q11） | 模型不新增"失败通知开关"字段；通知行为仍由 legacy 语义决定 |

### 8.4 反向（canonical legacy 行，工具用）

给定 Task，重建可写回 `config.txt` 的 legacy 行（C4 格式不变）：

```
<trigger> <action.command>[;] : <flags…>
```

- flags 按 `action.notify_start/notify_end/delete/termux/interactive/run_once_now` 生成
  `--notify-start/--notify-end/--delete/--termux/--interactive/--run-once-now`，
  `action.boot=1` 追加 `--boot`（保持文档化形式），`action.msg` 非空追加
  `--msg="…"`；无 flags 时省略 `; :` 段。
- heredoc 任务的反向为**重构行**（§8.1 第 6 步形式），由后续接线任务按
  P1-01 §5.4 决定是否写回为块；P1-02 不写回（模型层只规定规则）。
- **往返等价承诺**：`convert(L)` → task → `reverse(task)` 应产生与 L **语义等价**
  的 legacy 行（执行行为一致；非逐字节一致——修剪/删行后的规范化形式除外）。

## 9. 运行时状态机

```
        ┌──────── enabled=0 ─────────┐
        ▼                            │
   [disabled]                        │
        ▲                            │  （P1 仅模型，不接线）
        │                            │
   [idle] ──matched/触发──▶ [running] ──退出码 0──▶ [success]
     ▲                          │  └──退出码≠0──▶ [failed]
     │                          │                     │
     └────── daemon 重启清理 ◀───┴── running→[zombie]  │
                                                       │
                          [invalid]（校验隔离，非任务态）│
```

| v2 状态 | 对应 legacy 事实 | 转移条件 |
| :--- | :--- | :--- |
| `idle` | 尚无执行记录 | 创建/重置 |
| `running` | `status.txt=RUNNING` | 调度命中 |
| `success` | `status.txt=SUCCESS` | exit 0 |
| `failed` | `status.txt=FAILED` | exit ≠ 0 |
| `zombie` | `status.txt=ZOMBIE_CRASHED` | daemon 启动发现 running 而无存活进程 |
| `disabled` | （无对应） | enabled=0（P1 模型态） |
| `invalid` | （无对应） | 条目校验隔离（§10.2/校验规则） |

## 10. 验收标准对照

| 验收要求 | 落实 |
| :--- | :--- |
| 任意旧配置行都能转换为一个合法的内部 Task | §8 转换函数为**总函数**（每字段有缺省兜底）；`tools/derive-task-fixtures.sh` 对 P1-01 全部 17 个任务行/块机器生成合法样例（§8.2 矩阵全通过） |
| 非法字段不会导致 daemon 退出或清空已有配置 | `docs/architecture/task-schema-v2-validation.md`：lenient 加载、条目级隔离、原子写、快照保留；"绝不"清单（绝不 exit、绝不清空、绝不整体截断） |
| schema_version 固定 2 | §3/§5 常量字段；非 2 → 条目隔离 |
| source 保存行号与原始内容 | `source.type/line/raw`（§5）；样例逐条实证 |
| 配置字段与运行时字段边界明确 | §4 四条规则 + 判定口诀 |
| 缺省值/非法值/兼容转换规则明确 | §3/§5/§8 + 校验规则文档全矩阵 |
| P1 不引入外部运行时 | §1/§6：POSIX 文本、sh/sed/grep/awk 即可读写 |
| P1 只实现内部模型 | §1/§11：不解析用户 JSON/YAML、不改 daemon |

## 11. 非目标与非承诺

- **不实现**完整 JSON/YAML 用户配置解析（未来用户格式若引入，须经独立 P1 任务
  显式立项；转换规则届时另行定义）。
- **不引入** jq / Python / Node.js / busybox 专有扩展硬依赖（C3）。
- **不改动** `config.txt` 格式（C4）、不删除/替换 legacy 解析与执行路径（C2）。
- **不实现** WebUI、Dependency/condition 执行逻辑、健康/恢复/重试执行逻辑——
  本任务只定义字段与缺省；接线属于后续 P1 任务。
- **不承诺**：v2 注册表在 P1-02 创建或 daemon 开始消费（均为后续任务）。