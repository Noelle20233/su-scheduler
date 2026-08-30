# Su Scheduler — Provider 接口契约（P1-04）

> **任务**：P1-04 · 定义 Provider 接口契约
> **依赖**：P1-02（Task Schema v2）、P1-03（Task State Machine v2）
> **性质**：为后续扩展 Trigger / Action / Health / Recovery 建立**稳定接口**。
> 第一阶段采用**静态 Provider 注册 + 函数契约**（不要求动态插件加载）；核心引擎
> （Supervisor）只依赖 `provider_dispatch` 这一个入口——**不依赖任何具体 Provider
> 名字**。新增 Provider（如未来的 AppAction）＝ 注册一行 + 一组前缀函数，**核心
> 零改动**（验收标准）。
> **接线边界**：本任务**不改 daemon**（C2/C4）；实现位于测试域
> （`tests/providers/`），daemon 接线是后续任务。Provider **不得**修改核心任务
> 状态机（P1-03）——provider 只返回结果/退出码，状态转换由引擎按桥接表触发
> （§7）。
> **日期**：2026-08-30

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [Provider 模型](#2-provider-模型)
3. [四类 Provider 与能力表](#3-四类-provider-与能力表)
4. [能力契约（逐能力）](#4-能力契约逐能力)
5. [Provider 注册表（当前静态注册清单）](#5-provider-注册表当前静态注册清单)
6. [接口调用约定](#6-接口调用约定)
7. [与状态机的集成（桥接表）](#7-与状态机的集成桥接表)
8. [CommandActionProvider 适配](#8-commandactionprovider-适配)
9. [Health / Recovery 接口与空实现](#9-health--recovery-接口与空实现)
10. [新增 Provider 指南](#10-新增-provider-指南)
11. [验收标准对照](#11-验收标准对照)
12. [非目标](#12-非目标)

---

## 1. 目的与范围

- **目的**：把 Trigger、Action、Health、Recovery 四类扩展点统一为“Provider =
  静态注册 + 命名函数契约”，使：核心引擎只依赖契约；新增能力不动核心；替换
  实现（如 Health 从 stub 换成真实探测器）不触碰其他 Provider。
- **范围（P1-04）**：
  - 定义四类 Provider 的能力集合与逐能力契约；
  - 提供静态注册表 + 分发入口（`tests/providers/lib.sh`）；
  - 提供具体实现：CommandActionProvider（全实现）、Boot/Time TriggerProvider、
    Health/Recovery 空实现 stub（`tests/providers/providers.sh`）；
  - 提供契约测试（`tests/providers/test.sh`）与本文档。
- **范围外**：动态插件加载（第一阶段明确不做）；daemon 接线；Provider 修改状态机。

## 2. Provider 模型

```
Provider = (kind, name, prefix)
  kind   ∈ {trigger, action, health, recovery}
  name   = kind 内唯一标识（如 trigger>boot、trigger>time、action>command）
  prefix = 该 Provider 全部能力函数的统一前缀（如 tpr_trigger_boot）

能力函数 = <prefix>_<capability>
注册      = provider_register <kind> <name> <prefix>     （静态：加载时调用一次）
分发      = provider_dispatch <kind> <name> <cap> [args…]  （核心唯一入口）
默认分发  = provider_dispatch_default <kind> <cap> [args…] （kind 第一个已注册）
```

- 注册约束（`provider_register`）：kind 必须已知；同 kind 同 name 重复注册被拒；
  未知 kind 被拒——**绝不**因注册失败退出/清表（与 P1-02 校验原则一致）。
- 注册表是静态的、加载时构建（`TPR_REGISTRY` 空格分隔 `kind>name>prefix`）；
  **没有**动态发现/插件扫描（第一阶段目标就是简单、可审计）。

## 3. 四类 Provider 与能力表

| Provider 类 | 能力子集 | 必备能力（必须实现） |
| :--- | :--- | :--- |
| `trigger` | `validate parse matches next_due` | `validate parse` |
| `action` | `validate prepare start stop status restart` | `validate prepare start` |
| `health` | `validate check` | `validate check` |
| `recovery` | `validate recover` | `validate recover` |

- 全局能力集：`validate parse matches next_due prepare start stop status restart
  check recover`（11 项，覆盖任务要求的能力清单）。
- 必备能力之外的子集成员为**可选**：Provider 可实现也可不实现；分发时未实现的
  能力按“不支持”处理（rc=2）。
- **验证方式**：`provider_cap_is_of_kind <cap> <kind>` 判定能力归属；
  `TPR_CAPS_REQUIRED`（lib.sh）列出每类必备能力；测试断言必备 ⊆ 子集 ⊆ 全局。

## 4. 能力契约（逐能力）

> 统一约定：stdout 至多一行值；stderr 日志；返回码 0=成功 / 1=失败、非法 /
> 2=能力不支持或用法错误（与 P1-03 校验函数同构）。Provider 不得写任务状态文件、
> 不得调用 `task_state_transition`（状态转换归引擎，§7）。

| 能力 | 签名（前缀函数） | 参数 | stdout | 返回码语义 |
| :--- | :--- | :--- | :--- | :--- |
| `validate` | `<p>_validate <subject>` | 待校验串（触发串 / 命令串 / 策略串） | （可无） | 0=合法 1=非法 |
| `parse` | `<p>_parse <subject>` | 同上 | 结构化一行（`key=value;key=value`） | 0=成功 1=不可解析 |
| `matches` | `<p>_matches <raw>` | 触发原始串（上下文经环境变量） | （可无） | 0=当前命中 1=未命中 |
| `next_due` | `<p>_next_due <raw>` | 触发原始串 | 距离下次命中秒数（0=已到期） | 0=可计算 1=不可计算（如 boot 上下文外） |
| `prepare` | `<p>_prepare <task_id> <command>` | 任务 id + 命令 | task 目录路径 | 0=就绪 1=失败 |
| `start` | `<p>_start <task_id> <command>` | 同上 | 后台进程 PID | 0=已启动 1=启动失败 |
| `stop` | `<p>_stop <task_id> <pid>` | 任务 id + PID | （无） | 0=已请求停止 1=失败 |
| `status` | `<p>_status <task_id> <pid>` | 同上 | （无） | 0=存活 1=已退出 |
| `restart` | `<p>_restart <task_id> <command> <old_pid>` | 任务 id + 命令 + 旧 PID | 新 PID | 0=已重启 1=失败 |
| `check` | `<p>_check` | （无） | `ok`（或未来 `degraded`） | 0=健康 1=不健康 2=不适用 |
| `recover` | `<p>_recover` | （可带策略参数） | 策略名（如 `none`） | 0=已处理 1=失败 |

- 上下文约定：`matches`/`next_due` 的“当前”由 Provider 自行取 `date` 或读环境
  标志（boot 用 `TPR_BOOT_CONTEXT`）。引擎不代算时间——Provider 契约持有时间语义
  （与 P1-01 §5.2/5.3 的匹配语义一致）。
- 异步约定：`start` 自身后台化并回显 PID；引擎把 PID 存入 `runtime.pid`
  （P1-02 运行时字段）；`status`/`stop`/`restart` 用该 PID。

## 5. Provider 注册表（当前静态注册清单）

| kind | name | prefix | 能力状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- |
| trigger | boot | `tpr_trigger_boot` | 全实现 | Boot 触发（daemon 启动上下文匹配，P1-01 §5.1 语义） |
| trigger | time | `tpr_trigger_time` | 全实现 | HHMM/HH:MM 日常触发（P1-01 §5.2 语义） |
| action | command | `tpr_action_command` | 全实现 | 现有 Shell 命令适配（§8） |
| health | builtin | `tpr_health_builtin` | 接口+空实现 | `check` 恒 ok（Supervisor 未接线，P1-02 health.type=none） |
| recovery | builtin | `tpr_recovery_builtin` | 接口+空实现 | `recover` 恒 no-op（recovery.type=none） |

> 进阶触发（weekly/nweekly/monthly/nmonthly/yearly）**不在**当前注册表——它们与
> time 同属 trigger kind，后续作为新 trigger Provider 注册（或扩展 time Provider
> 的 `parse`/`matches`），不改分发与状态机（§10 模板）。

## 6. 接口调用约定

1. **核心入口**：`provider_dispatch <kind> <name> <cap> [args…]`（name 显式）。
   单 Provider 场景可用 `provider_dispatch_default <kind> <cap> [args…]`
   （kind 第一个已注册）。
2. **返回码**：0 成功 / 1 失败非法 / 2 能力不支持或用法错误。引擎对非 0 按
   §7 桥接处理（记录 + 状态转换），**不**因 Provider 失败而退出/清库。
3. **错误路径**（分发层，测试覆盖）：未知 kind → 1；未知能力 → 2；kind 内无该
   Provider → 1；能力不属于该 kind → 2；Provider 未实现该能力 → 2。
4. **日志钩子**：`provider_log`（默认 stderr `[provider] …`；`TPR_LOG=0` 静音；
   daemon 接线时覆盖为写 `su-scheduler.log`）。分发失败一律记录，绝不静默。
5. **环境**：`TPR_ACTION_DIR`（action 任务目录根；测试用临时目录，daemon 接线取
   `tasks` 目录）、`TPR_BOOT_CONTEXT`（引擎启动阶段置 1，boot 匹配依据）。
6. **隔离**：Provider 之间不互相调用（除非经分发）；Provider 不读/改配置文件
   （`config.txt` 只由引擎读）；Provider 不写任务状态文件（P1-03 状态归引擎）。
7. **无外部运行时**：全部 Provider 与分发为 POSIX sh（C3：sh/sed/grep/awk/cut）、
   无 jq/Python/Node（P1-02/P1-04 约束）。

## 7. 与状态机的集成（桥接表）

> 规则：Provider 只产出**结果**（rc + stdout）；**状态转换由引擎发起**，cause 按
> 下表映射（P1-03 §4 令牌）。Provider 永不直接调用 `task_state_transition`
> （测试 §8 断言 Provider 不引入/不修改状态机）。

| Provider 结果 | 引擎动作 | 状态转换（P1-03） | cause |
| :--- | :--- | :--- | :--- |
| trigger `matches`=0 | 调度命中 | PENDING→STARTING | time_trigger / manual_exec |
| trigger `matches`=1 | 不动作 | — | — |
| action `start` ok | 记录 pid | STARTING→RUNNING | spawn |
| action `start` 失败 | 记录失败 | STARTING→FAILED | action_failure |
| action 进程退 0（引擎观察） | 记录成功 | RUNNING→STOPPED | action_success |
| action 进程退非 0 / `status` 意外消失 | 记录失败 | RUNNING→FAILED | action_failure |
| action `stop` ok | — | RUNNING→STOPPING→STOPPED | stop_request |
| 引擎超时定时器 | 请求停止/强杀 | RUNNING→STOPPING（软）/→FAILED（硬） | timeout |
| health `check` ok | 标记健康 | RUNNING→HEALTHY | probe |
| health `check` 非 ok | 标记不健康 | HEALTHY→UNHEALTHY | probe |
| recovery `recover` 完成 | 重新拉起 | UNHEALTHY→RECOVERING→STARTING | supervisor |
| daemon 重启 | 再水合 | 执行态→FAILED（P1-03 §6） | daemon_restart |

> 桥接不在 P1-04 接线（引擎/daemon 属后续任务）；本表是给接线任务的**固定映射**
> ——接线不得发明新 cause 或绕过状态机。

## 8. CommandActionProvider 适配

- **适配对象**：现有 Shell 命令任务（legacy `execute_task` 语义，P1-01 §5）。
  映射：`sh -c "<command>" > <task_dir>/output.log 2>&1 &`（异步）；PID 回显；
  `status` 用 `/proc/<pid>` 存活判定；`stop` 用 `kill`（与 `task-kill` 的杀法
  一致，P1-01 §5.10）；`prepare` 建 task 目录并写 `command.txt`。
- **局限（如实记录）**：当前实现是“无状态 shell 命令”适配。legacy 的
  `--termux`/`--interactive`/智能脚本执行（P1-01 §5.4-5.5）属于**同一合同下的
  后续 Provider 扩展**（可新注册 `action>termux`、`action>interactive`，或将命令
  预处理留给引擎）——核心与分发零改动。
- 空命令语义：`command=""` 仍合法（legacy `sh -c ""` 退 0，P1-02 §5）。

## 9. Health / Recovery 接口与空实现

- **HealthProvider（builtin）**：P1 只提供接口 + 空实现。`validate` 仅接受
  `none`/空（P1-02 `health.type` 唯一合法值）；`check` 恒输出 `ok`（= 不启用
  健康检查即为健康）。Supervisor 接线后：同 kind 新注册 `health>probe`（或扩展
  builtin），分发/状态机不动（§7 桥接表已有 probe 边，P1-03 reserved）。
- **RecoveryProvider（builtin）**：`validate` 仅接受 `none`/空；`recover` 恒
  输出 `none`（= 无恢复动作）。恢复语义（restart/relaunch）后续 Provider 实现。
- **验收对应**：“Supervisor 尚未实现时 HEALTHY、UNHEALTHY 等状态也已预留”——
  P1-03 reserved 边（RUNNING→HEALTHY→UNHEALTHY→RECOVERING）已定义且本机校验
  接受；P1-04 提供 Health/Recovery Provider 接口与其空实现。
- **测试**：`tests/providers/test.sh` §6 断言 stub 行为。

## 10. 新增 Provider 指南

以未来 **AppActionProvider**（如启动 `.apk`）为例，**核心零改动**：

```sh
# 1) 实现前缀函数（能力子集取自 §3/§4）
tpr_action_app_validate() { [ -n "$1" ] && return 0 || return 1; }   # 命令串校验
tpr_action_app_prepare()  { mkdir -p "${TPR_ACTION_DIR:-/tmp/su-scheduler-actions}/$1"; ... }
tpr_action_app_start()    { am start -n "$2" ...; echo "$!"; }        # 启动 App
tpr_action_app_stop()     { am force-stop "$2" ...; }
tpr_action_app_status()   { ... }
tpr_action_app_restart()  { ... }

# 2) 注册一行（加载时静态注册；重复注册被 lib 拒绝）
provider_register action app tpr_action_app
```

- 引擎用 `provider_dispatch action app start <id> <cmd>` 调用——**引擎不认识
  “app” 也能工作**（只认 kind+cap）。这就是“后续增加 App Action 无需重写核心
  Supervisor”的机制保证（验收标准 2）。
- 新增 trigger（weekly 等）同理：`provider_register trigger weekly …`。

## 11. 验收标准对照

| 验收要求 | 落实 |
| :--- | :--- |
| 定义 Trigger/Action/Health/Recovery 四类 Provider | §2/§3/§5（kind/name/prefix/能力表/注册表） |
| 建议能力 validate/parse/matches/next_due/prepare/start/stop/status/restart/check/recover | §4 逐能力契约（11 项全覆盖） |
| 静态 Provider 注册、函数契约；不做动态插件加载 | §2/§6（静态注册表 + 前缀函数；无插件扫描） |
| 新 Provider 不修改核心 Task 状态机 | §7 桥接表 + 测试 §8（Provider 不引入 TSM_ALLOWED、不调 task_state_transition） |
| 现有 Shell 命令经 CommandActionProvider 适配 | §8（异步 sh -c、PID、/proc 存活、kill） |
| Health/Recovery 暂未实现：接口 + 空实现 | §9（builtin stub：check→ok、recover→none、validate 仅 none） |
| 核心引擎只依赖 Provider 契约 | §6 单一入口 provider_dispatch（测试断言错误路径与默认分发） |
| 后续增加 App Action 无需重写核心 Supervisor | §10 模板（注册一行 + 前缀函数，核心零改动；测试验证分发机制） |
| 状态转换可独立测试（P1-03 延续） | `bash tests/state-machine/test.sh` 与 `bash tests/providers/test.sh` 独立运行、互不依赖，二者共存亦绿（测试 §8） |

## 12. 非目标

- **不做**动态插件加载/插件扫描/热插拔（第一阶段静态注册）。
- **不改** daemon 与 `config.txt`（C2/C4）；接线（引擎把 dispatch 接到主循环）属
  后续任务。
- **不做** App/WebUI 等具体 Provider 实现（只给契约与模板）。
- Provider **不得**：直接改任务状态、写配置、互相硬编码调用、引入外部运行时。"