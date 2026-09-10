# Su Scheduler — P6 阶段交接资料（P6-HANDOVER）

> **任务**：P6-12 · P6 出口评审与下一阶段移交（本文件为「文档交接」交付物）
> **前置**：P5-HANDOVER、P5-EXIT-REPORT、P6-01..P6-11 各分篇、`docs/architecture/dag-schema-v1.md`
> **性质**：给 P7 代码组与维护者的**稳定交接入口**——新成员按 §1.2 阅读路径可仅凭文档理解
> P6（跳拍补偿/锁主围栏/Cron ID/IPC 错误透传/DAG 链式引擎/加固/可观测/CLI/设备矩阵/综合验证）
> 全链路；§3 明确**未实现硬边界**、§6 给出 P7 候选清单（诚实边界）。
> **日期**：2026-09-10
> **版本**：模块 `v1.6.8`（不变）；Runtime 库 `1.32.0`（P6 出口）

---

## 目录

1. [交接对象与目标（含阅读路径）](#1-交接对象与目标含阅读路径)
2. [P6 能力全景](#2-p6-能力全景)
3. [未实现清单（硬边界）](#3-未实现清单硬边界)
4. [接口契约速查](#4-接口契约速查)
5. [安全边界再声明](#5-安全边界再声明)
6. [P7 候选需求清单](#6-p7-候选需求清单)
7. [运维 runbook 索引](#7-运维-runbook-索引)

---

## 1. 交接对象与目标（含阅读路径）

- **给谁**：P7 代码组（§6 候选立项）、维护者、评审者、新加入的 Agent。
- **目标**：
  1. 新成员**只读文档**即可理解「分钟 tick + catch-up → 单常驻主循环 + 锁主围栏 → DAG 链引擎
     （run.txt 账本）→ WebUI/CLI 同源可观测 → 真机矩阵」的 P6 全链路；
  2. 明确 P6 **已实现 / 未实现（硬边界）/ P7 候选**三者边界（§2/§3/§6）；
  3. 明确接口契约（§4）与安全边界如何延续（§5）；
  4. 明确运维动作序与取证惯例（§7、EXIT §8）。

### 1.2 新成员阅读路径（先总览后细节）

```
1. docs/P6-EXIT-REPORT.md            ← P6 出口评审（回归/条件判定/约束/缺陷/签核项）
2. docs/P6-05.md + docs/architecture/dag-schema-v1.md   ← 需求冻结 D-01..13 + ADR D46-D58（ACCEPTED）
3. docs/P6-01.md                     ← P5 基线复核与 O-2/O-3/O-4 复现（P6 起点）
4. docs/P6-02.md / P6-03.md / P6-04.md   ← catch-up（last_tick 语义）/ Cron ID 派生 / IPC 错误透传
5. docs/P6-06.md                     ← DAG 引擎实施（tick 层序/run.txt/上限接线）
6. docs/P6-07.md                     ← 资源/安全/并发加固（F1-F4：字面匹配/scanmark/计数/replenish）
7. docs/P6-08.md + docs/P3-05-WEBUI-DATA.md §7   ← WebUI dag 键契约（D58 + dag.audit）
8. docs/P6-09.md                     ← CLI chain 子命令 / task 追加行 / 审计 catchup=1、op=dag
9. docs/P6-10.md + docs/P6-10-DEVICE-MATRIX.md   ← 真机九场景、缺陷 D-P6-10-01/02/03、§9 修后复验与 §9.5 动作序
10. docs/P6-11.md                    ← 宿主综合九项（性能/注入/原子/双模式/升降级演练）+ 延后清单
11. docs/P5-HANDOVER.md              ← P5 交接（Trigger/Condition/依赖门控基线）
```

## 2. P6 能力全景

> 语义权威在各分篇 + ADR；本节为速览。测试域：p6-reliability（25）、p6-dag（177）、
> p6-webui（82）、p6-cli（47）、p6-verify（30）、p6-device（真机 56）+ lifecycle-prod §8 / crashguard §16。

### 2.1 跳拍补偿（catch-up）与 last_tick / 围栏（P6-02 + D-P6-10-02 修后态）

- **`$base/scheduler/last_tick`**：内容 = 上次 `sched_cycle_token`（分钟级墙钟 `%Y%m%d%H%M`，
  测试经 `SCHED_CYCLE_NOW` 覆盖）。`scheduler_tick` 末尾写回。
- **补偿语义**：同日（`ld==cd`）且分钟不同 → 中间窗口逐分钟补执行，**上限 `CATCHUP_MAX=3`**
  （只补最近 3 窗）；**可补偿族** = 分钟精确 `HHMM`/`HH:MM` + `weekly/nweekly/monthly/nmonthly/yearly`；
  **不补**：`oneshot/delay/interval/cron/boot_completed/run-once-now`（自校正或一次性语义）；
  跨午夜不补；无 last_tick（首拍/重启）不补——防历史窗口误重放。
- **同窗口至多一次**：补偿执行成功即 `sched_cycle_mark`（当前 token），主循环节点跳过；
  补偿走 `sched_execute_one` 原路径——依赖/条件/retry/cooldown 门控**零绕过**。
- **审计**：`op=tick|…|catchup=<n>`（聚合计数）；被补偿的 `op=exec` 行尾 `catchup=1`（只增字段，
  常规行逐字节不变）。
- **锁主围栏（单常驻不变量的第二道闸）**：`lifecycle_lock_owner_fence`——daemon 主循环顶检查
  锁内 PID 若为另一存活的 `su-schedulerd`，本实例=非持有者，**自退不删锁**、记 WARNING 审计
  （clean exit）；CLI `cmd_stop` 仅在确认持有者死亡后才删锁。`while true` 恒恰 1（B20）。

### 2.2 Cron ID 稳定派生（P6-03）

`tcfg_new_id`：去冒号 → `tr -c 'A-Za-z0-9._-' '_'` → 2+ 连点折叠 `_` → 连续 `_` 折叠 → 空回退 `t`。
全部在**拼路径前**完成；旧 ID golden 6 条逐字节不变；任务文件 `trigger=` 字段**逐字保留原文**
（ID 仅是文件名派生）。

### 2.3 IPC 错误透传与净化管线（P6-04）

- 响应首行第 4 段 = **`符号: 原因`**（如 `configuration_invalid: trigger 'oneshot:2460' invalid/…`）；
  载荷行原样保留（旧消费者零破坏）。
- 净化在 `ipc_respond` **唯一咽喉**（`ipc_err_sanitize`，单 awk）：取首个非空行 → 非可打印
  ASCII→空格、`|`→`/` → 剥 `[editor]/[task-config] ERROR:` 前缀 → 路径脱敏（daemon base /
  TCFG_DIR / `/data/adb/...` → `<path>`）→ 截断 256（`…(truncated)`）→ 空 reason 优雅回退纯符号。
- 只读诊断函数 `tcfg_validate_reason`（镜像 `tcfg_validate_task` 判定顺序，不改其结果）。
- 客户端合成码（`permission_denied/task_not_found/operation_timeout/daemon_unavailable`）**完全未动**。

### 2.4 DAG / 链式调度（P6-05..09 全栈，依 ADR D46-D58）

- **模型**：边 = 既有 `dependency=`（`[?]<id>[:STATE]`，DEP_MAX=32，零新字段/新语法）；
  节点 = `trigger=chain`（裸关键字，**仅 managed**，B16）；根 = 任一真实触发器任务；
  链身份 = 根 id；**链不是配置对象**（无注册表、无新 IPC op、无第二循环）。
- **run 账本**：每次根触发（含 catch-up 补执行、boot 通道）登记一次链运行
  `run_id = cycle token`（同根同分钟至多一 run，目录名天然去重）；
  路径 `$base/dag/<chain_id>/runs/<run_id>/run.txt`（tmp+mv 原子整写、0700/0600、
  `DAG_RUNS_KEEP=8` prune）；**手动 `tctl start/restart` 不点火**（D48）。
- **tick 层序（D53）**：`WAITING advance ▶ scheduler_dag_pass ▶ retry-arm ▶ catch-up ▶ 主循环`；
  frontier 每 tick 单遍（Required 上游达期望终态才释放；`:FAILED` 边=故障分支合法；
  Optional 不阻断记 `opt-unsat`；cond 叠加 `cond-unmet`；同 tick 单波推进）。
- **失败传播**：D15/D16 逐行复用（Required 不满足→立即 FAILED 级联 `gate-fail`；disable=中断路
  →有界等待→超时 FAILED）；重试**仅节点级**（P4-07 原语义，`dag_retry_replenish` 以 events.log
  全部失败事件计尝试、终局 `dag_retry_terminate` 拒重放——D-P6-10-03 修后态）；**链永不自动重放**。
- **上限常量表（D57 七常量 + 修后新增 1，均 `VAR=${VAR:-默认}` 环境可覆盖）与超限不对称**：

| 常量 | 值 | 超限行为 |
| :-- | :-- | :-- |
| `DAG_CHAIN_NODES_MAX` | 32 | **配置期拒绝**（`dep_validate_graph` 尾部链段，四写路径全覆盖） |
| `DAG_CHAIN_EDGES_MAX` | 128 | 配置期拒绝 |
| `DAG_CHAIN_DEPTH_MAX` | 16 | 配置期拒绝 |
| `DAG_RUNS_MAX` | 8 | **运行期不启动新 run**（审计 `action=limit`），根照常执行、**在途不杀** |
| `DAG_PARALLEL_MAX` | 4 | **顺延下一 tick**（note=`defer`，不丢弃） |
| `DAG_RUN_TIMEOUT` | 86400 | run=FAILED、停止释放、**不强杀在途进程** |
| `DAG_RUNS_KEEP` | 8 | prune（token 字典序最旧先删，审计 `action=prune`） |
| `DAG_SCAN_MAX_AGE_MIN` | 1440 | （P6-10-fix 增）登记候选 token 年龄超窗 → 跳过登记不 pending（D-P6-10-01） |

  原则：**错配置不让写盘；资源风暴不误杀用户任务**（签核③冻结）。
- **引擎扫描工件**：`dag/.scanmark`（高水位，稳态 O(新增)）、`dag/.scanpending`（limit 阻塞后滚，
  有效性=源 cycle 字面行仍在——防陈旧复活）；cycle 标记匹配为**字面整行**（`grep -Fxq`，F1）。

### 2.5 WebUI dag 键契约（P6-08，D58 + B8 只增键）

- `GET_SUMMARY.dag = {active, limit, recent_failed, chains[]（≤64，展示 run 投影
  {root,run,run_state,created,done,total,frontier[],nodes[][{id,role,state,note}]}）,
  audit[]（scheduler/audit.log 尾读 op=dag 最近 ≤10 行）}`；
- `GET_TASK_DETAIL.dag = {chain_root, role, run, run_state, node_state, note, reason, runs[]}`
  （非链任务=全空字段 + `runs:[]`，schema 恒在；多根共享 v1 口径=字典序首链，O-P6-08-01）；
- 前端 `#dag` 路由：链视图/节点徽标/进度条/frontier/失败传播注记/`dag.reason`；
  **链级控制 = 节点级批量**（「停止链/重启链/启用链/禁用链」→ 逐成员 `write(op,{id})`，
  P5-07 B19 逐任务结果；UI 明示「v1 无链级取消 API」）；
- 注入防御：run.txt 内容经 `dag_run_parse` 同门 + 枚举白名单归一（白名单外→UNKNOWN）+
  `web_json_escape` + 前端 `textContent`；聚合只读零执行零写盘。

### 2.6 CLI 与审计（P6-09）

- `su-scheduler chain [<chain-id>]`：纯文件读（`$base/dag`+现图，daemon 不参与、离线可用；
  坏图回退 task-config 权威目录）；清单=每链一行 + 汇总 `chains=/active_runs=/limit=/remaining=`；
  详情=账本 + `closure=` + `runs=[json]` + 尾审计行 + 图非法时 `validation_error=`。
- `task status`：**追加行**链七键（`chain_root/role/run/run_state/node_state/note/reason`，
  role 非空才出现——与 WebUI **同源** `web_dag_detail_compute`）+ `last_tick_catchup=<n>` +
  `catchup_executed=0|1`；既有行序逐字节不变。
- `task-info`：`Upstream:/Downstream:`（`(required|optional) want=<STATE> via=chain|gate`）+
  `Chain Root:/Role:/Run:/Run State:/Node State:/Node Note:/Reason:` + 多根共享 `Member Of Chains:`。
- 审计：`op=dag|action=register|dispatch|fail-propagate|cond-unmet|timeout|limit|corrupt|prune|complete`
  （`complete` 每 run 终态恰一条）；错误一致性三源同文：CLI apply stderr == IPC
  `configuration_invalid: …` == chain `validation_error=…`。

## 3. 未实现清单（硬边界）

> **硬性声明**：以下各项 P6 **未实现**，任何文档/代码不得表述为已完成；解除边界须 P7 立项+ADR。

| 项 | P6 状态 | 边界出处 |
| :-- | :-- | :-- |
| **链级取消/暂停 API**（stop-chain、CANCEL_DAG） | **v1 裁决不做**；run.txt `CANCELLED` 枚举**预留不产出**（诚实声明，非占位实现）；停链 = 批量 disable/stop 节点 | D54/D50（P6-05 D-07） |
| **链自动整链重放**（retry.policy=chain） | 不做（重试仅节点级）；根重触发=新一轮 run | D53/D-06 |
| **秒级 tick / 亚秒 IPC 响应** | 冻结分钟级（B20）；E2E ~1–2s = 双端 1s poll **设计成本** | P6-11 §8-4 |
| **`depg_dfs` 合流误判**（合流 id 字母序先于依赖→假环） | P4 域既有缺陷，P6 **未修**（复验未恶化）；测试以 `zjoin` 命名规避 | P6-06 §10.6 / P6-07 O-P7-06 |
| **`sched_cycle_seen` 正则面**（O-P7-01） | 登记未修（`grep -qx` 以 id 作正则，`.` 跨行误配，O(1)/当窗自愈） | P6-07 §7 |
| **catch-up 回滚重放窗口**（O-P6-11-01） | 未修，已 **LOCK 固化**（p6-verify upg-5 断言当前行为）；策略待 P7 裁决 | P6-11 §5 |
| 事件推送式传播（回调拉起下游）/ `dag.edges=` / 独立 `.chain` 对象 / `RUN_CHAIN` op / 任务枚举 `CHAINED` / 链图形化编辑器 | 全部 ADR §6 **被拒方案**，零实现 | dag-schema §6 |
| Legacy 域链（`--chain` modifier / legacy chain 行） | 零出现（B16/D12）；chain-token 行 import 被拒且 config 逐字节（EX-19b） | P6-05 D-12 |
| P7+ 域（配置加密、备份增强、多 profile、WebUI 增强、Watchdog 增强、Dependency 扩张、云同步） | 零实现零占位（AGENTS §9 纪律延续） | P5-HANDOVER §5 结转 |

## 4. 接口契约速查

```sh
# ── IPC 响应协议（四段首行 + 可选载荷行；P6-04 后第 4 段可带原因） ──
<rid>|<op>|<rc>|<symbol>[: <reason>]        # reason 已过净化：可打印ASCII、无 '|'、≤256、路径脱敏 <path>
<payload...>                                 # 原样保留（旧消费者读此行为主）

# ── 错误码（6+1，语义与触发集恒未变；B7：19 op 白名单恒 19） ──
0 ok / 1 invalid_request / 2 permission_denied / 3 task_not_found /
4 configuration_invalid / 5 operation_timeout / 6 daemon_unavailable / (7 rate_limited)
# 文法：服务端首行 = `symbol: sanitized_reason`；2/3/5/6 为客户端合成纯符号

# ── dag/ 目录结构（0700 root-only；运行态数据，不入 config/回滚域 B9） ──
$base/dag/<chain_id=根id>/runs/<run_id=YYYYMMDDHHMM>/run.txt     # 0600，tmp+mv 整写
$base/dag/.scanmark / .scanpending                                # 引擎扫描工件
# 路径段全部过 secv_id_ok；run 目录名仅 [0-9]{12}（dag_token_ok）

# ── run.txt 行格式 ──
chain=<root-id>
run=<token>
state=PENDING|RUNNING|SUCCESS|FAILED          # CANCELLED 枚举预留、v1 不产出
created=<epoch-秒>
root=<id>|<账本态>|<attempt 记账位>
<node-id>|chain|<PENDING|RUNNING|STOPPED|FAILED>|<note>
#   note ∈ disp | gate-fail | waiting | disabled | defer | cond-unmet | opt-unsat（root 行=attempt）

# ── 事件令牌（RT_EVENTS 新增，不入 TSM_CAUSES；183 迁移零改动） ──
dag_register（run 创建）/ dag_dispatch（节点释放→执行）

# ── 审计 ──
op=dag|action=register|dispatch|fail-propagate|cond-unmet|timeout|limit|corrupt|prune|complete|chain=|run=|task=|…|mode=
op=exec|…|cause=<family>|catchup=1            # 仅补偿执行，尾字段
op=tick|…|catchup=<n>
# ── catch-up 常量：CATCHUP_MAX=3；last_tick=分钟 token 文件（$base/scheduler/last_tick）──
# ── 上限 7 常量（§2.4 表）+ DAG_SCAN_MAX_AGE_MIN=1440 ──
```

## 5. 安全边界再声明（P7 必须延续）

1. **WebUI 非安全边界，后端校验唯一事实源**：一切合法性由 runtime 校验器（editor/
   `dep_validate_graph`/链段）裁决；WebUI 展示层对任何伪造 run.txt/chain 目录**免疫**
   （corrupt→FAILED 有界、零求值、只读零副作用）；`dag.audit` 尾读不扩参（B7 一致）。
2. **零任意 Shell 求值**：链引擎 §27 结构审计零 `eval`/`sh -c`/反引号/kill 系（DAG-P7-02）；
   run.txt/边/id 字符串永不进求值通道（IJ-05 `/tmp/pwn` 恒不存在）；Condition 白名单文法不变。
3. **ID/路径三件套**：`secv_id_ok`/`tcfg_editor_id_ok`（`[A-Za-z0-9._-]{1,128}`、无 `..`/`/`/`*`）、
   拼接前校验、读时 `secv_inside`+`secv_nosymlink`；`tcfg_new_id` sanitize 在拼路径前完成。
4. **净化管线**：所有 IPC 错误经 `ipc_err_sanitize` 咽喉（协议段数稳定 + 脱敏 + 截断）；
   新代码接入点无需重复实现。
5. **B7/B8**：IPC 恒 19 op；WebUI JSON 只增键不删改（dag 键族按 §4/§2.5 冻结）。
6. **B9/原子**：配置域 tmp+mv + 失败逐字节不变；dag/ 运行态**前滚不回滚**（签核②）；
   回滚=数据面旧版只读忽略（upg-2/3/6 + RB-3 实证）。
7. **mksh/POSIX 纪律（D36/D37）**：`${}` pattern 禁裸 `|`/`(`/`)`；dash -n 全脚本 + 真机 mksh 终裁。
8. **单常驻主循环（B20）+ 锁主围栏**：`while true` 恰 1、库零常驻；围栏审计行
   `Lock-owner fence: …non-holder… exiting`（孪生=病征必查）。

## 6. P7 候选需求清单

> 全部为 P6 **未实现**项；「执行条件」满足前不立项（诚实边界）。

| # | 项 | 执行条件 / 设计输入 | 优先级 |
| :-- | :-- | :-- | :-- |
| 1 | **设备矩阵扩展（14 格）**：Magisk×5、APatch×5、KernelSU×A12–15×4 | 需①第二真机或②可换 root 管理器（解锁/重刷属破坏性须单独授权）或③启用 KVM 的 Android 模拟器（Google APIs + `adb root`）；**另须安静窗条件**（充电+锁屏静置/飞行，P6-10 §5.3.4）；顺带补 U-4 多根共享真机专列演练 + §9.5 组合全绿（属 P6 遗留非新需求） | P7 发布前提（如有资源） |
| 2 | **链级取消与整链重试 v2 设计输入** | v1 裁决冻结面：`CANCELLED` 预留不产出、手动 stop≈满足缺省边、链不自动重放（D54/D53/签核①④）；v2 需回答：取消的在途节点处置（不强杀原则是否让步）、重放的幂等边界、新 op 与 B7 的取舍（须 ADR 改版） | P7 候选 |
| 3 | **秒级调度 / 亚秒 IPC** | 需改 daemon 唤醒模型（tick 粒度）+ IPC poll（双 1s 粒度=当前设计成本）；牵动 cycle token/run_id 时间轴（12 位分钟）——架构级 ADR | P7+ 候选 |
| 4 | **`depg_dfs` 合流误判修复** | 含**消息继承门禁方案**：P4 golden 错误消息/ rc 逐字节冻结，修复只可新增判定不可改文；影响面 = `tests/p4-dependency` 220 条 + 四写路径 | P7（P4 域） |
| 5 | **catch-up 回滚重放窗口策略（O-P6-11-01）** | 数据输入：p6-verify upg-5 LOCK、有界同日 ≤3 分钟、真实重启路径不触发；候选方案：catch-up 前查 `cycle-<窗口token>` 字面行含该 id 即跳过（与 `.scanpending` 有效性检查同源）；触碰 P6-02 冻结语义需 golden 评审 | P7 裁决 |
| 6 | **`sched_cycle_seen` 正则面（O-P7-01）** | 与 F1 同款（`-qx`→`-Fx`）；影响 P4 冻结语义（当窗自愈面）——评估修复成本 vs 收益后裁决 | P7 裁决 |
| 7 | **CI `fetch-depth:0`** | `test.yml` checkout 加 fetch-depth:0（或推 p5/p6 tag 上 origin）使 p6-verify §upgrade CI 真跑；属 CI 配置变更，**待人工**（P6-11 §7-D、EXIT Q5） | 低（ hygiene ） |
| 8 | **dag 多根共享链语义（O-P6-08-01）** | B8 兼容路径：detail 增键 `chains[]`（复数归属）+ 前端多链视图；CLI `Member Of Chains` 已给事实源 | P7 候选 |
| 9 | 可选：配置备份增强 / 多 profile 切换 | P0 AGENTS §9 起延续未做；立项前无占位 | P7+ |
| 10 | 登记类小项结转：O-P7-05（`GET_SUMMARY.dag` 真机时延 quiet 15–58s/负载 >80s → 分片/缓存）、O-P6-10-06（`root=` 行 STOPPED 展示语义）、P6-04 §9 三条（REQ_ID 段 id 门 / update 事务性 / tctl 详情口径）、`legacy_adapter_task_id` sanitize 统一（P6-03 §8.1） | 各附证据见 EXIT §4.2 总表 | P7 打包处理 |

## 7. 运维 runbook 索引

| 场景 | 入口 |
| :-- | :-- |
| **设备增量清理（P6 遗留现场）** | `docs/P6-10.md` **§9.5 下一窗口动作序**（①§7 runbook 步骤 2 增量清理组合遗留——`p6_*`/`p3` 残留 HHMM 任务**先复位再动** ②bind/staging 复核（staging 重启前勿删，§9.2/§9.6）③安静窗 `run_tests.sh --with-device`）；清理 runbook 本体 = P6-10 §7 步骤 1..5 |
| **升级 / 回滚（用户路径）** | 安装 `su-scheduler-v1.6.8.zip`（Runtime 1.32.0）；回滚 = 覆盖装旧 zip / 卸载（数据保险库保留）；真机演练记录 = `docs/P6-10-DEVICE-MATRIX.md` §4（RB-1..6 + UPGRADE）；命令级手册 = `docs/P4-UPGRADE-ROLLBACK.md` |
| **开发机文件级热升级（双轨法，仅测试基建）** | `docs/P6-10.md` §9.2：模块目录同步（重启生效源）+ 当会话 per-file bind（KSU boot-time overlay 环境事实）；纪律=push 后 chmod 755 再 mount、版本恒等时**按修复原语 grep 判别** pre/post-fix |
| **性能误红判别** | 起测前 `uptime` 记 load；§perf 近界档按 **A/B 地板口径**（参照档同涨=环境噪声、独涨必红，P6-11 起测试内建）；全量回归只在 WSL 原生 FS/Linux 跑（AGENTS §4.4，Windows 仅 `--lint-only`）；疑似卡死先查 CPU/持续 [PASS]，勿叠 `bash -x` |
| **flake 台账** | `docs/P6-EXIT-REPORT.md` §8（task-control/lifecycle IPC 时序、设备环境项、历史 WSL 回收坑） |
| **链运维** | 只读：`su-scheduler chain [<id>]`、`task status/info`、WebUI `#dag`；停链 = 批量 disable/stop 节点（v1 无取消 API）；`$base/dag` 可整树删除=纯运行态（回退面 ADR §9） |
| **出口与签核状态** | `docs/P6-EXIT-REPORT.md` §7（Q1–Q5 待人工裁决；tag `p6-baseline-v1.6.8-runtime1.32.0` 建议未执行） |
