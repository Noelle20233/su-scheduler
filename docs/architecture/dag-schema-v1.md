# Su Scheduler — DAG / 链式调度 Schema v1 架构裁决（P6-05 ADR D46–D58）

> **状态**：**`ACCEPTED — 已获人工批准（签核 2026-09-08，D-01..D-13 全部按草案批准，含五项风险决策：手动 stop 满足缺省边 / 回滚不回滚链态 / 超限不对称不强杀在途 / 链不自动重放且 v1 无链取消 API / 触发族命名 chain）`**
> **任务**：P6-05 · DAG / 链式调度需求与架构裁决（文档任务，零生产改动）
> **作者/日期**：P6-05 · 2026-09-08
> **上游**：`docs/P6-05.md`（需求裁决表 D-01…D-13）、`docs/P4-DEPENDENCY-REQUIREMENTS.md`
> （FR-8）、`docs/P5-HANDOVER.md` §5、`docs/architecture/dependency-schema.md`（D1–D45）、
> `docs/architecture/trigger-schema-v2.md`（D41–D45）、`docs/architecture/task-schema-v2.md`、
> `docs/architecture/task-state-machine-transitions.tsv`（183 迁移冻结）
> **编号**：沿用 dependency-schema.md 全局 D 序列（P4 D1–D37、P5-02 D38–D40、P5-04 D41–D45），
> 本文占用 **D46–D58**；§2 各条括注 `docs/P6-05.md` 裁决编号（D-xx）供签核对照。
> **实现归属**：全部生产接线在 **P6-06**（本 ADR 批准前零实现）。

---

## 1. 背景与目标

P4 交付了「单任务依赖门控 + registry DFS 无环」（D6–D17），P5 冻结了 Trigger Schema v2
（D41–D45）。P5-HANDOVER §5 明确遗留：「依赖图已是简单 DFS 无环；如需通用 DAG 需重新立项」。
本 ADR 即该立项的 **schema 与语义冻结**：把「若干相互依赖的 managed 任务、由一个根触发器一次
点火、按拓扑序执行、失败按边传播」的形式化定义钉死在既有字段/校验/调度通道之上，不引入第二套
依赖语法、第二常驻循环、新 IPC op 或任务状态枚举扩充。

```
 根（真实触发器，Task v2）                 例：trigger=interval:60
   │ dependency= 边（D2 语法）             B: dependency=root_a
   ▼                                      C: dependency=root_b,root_c（合流）
 链内节点（trigger=chain，仅被传播执行）    合流/分支/串行 = 同一边集的拓扑形态
```

## 2. 字段与合法值（Schema）

**零新增字段。** 链声明完全由既有 Task v2 字段承载；唯一枚举扩充是 `trigger` 家族新增裸关键字
`chain`（D47）。下表 = 链相关字段的权威定义（本表是 `tests/p6-dag/test.sh` §schema-doc 一致性
断言的 golden 来源；fixtures 仅允许使用本表字段名）：
| 字段 | 类型 | 合法值（链语境约束） | 定义来源 |
| `schema_version` | 数字 | `2`（不变） | task-schema-v2 |
| `id` | 字符串 | 既有规则：`secv_id_ok`/`tcfg_editor_id_ok`（`[A-Za-z0-9_.-]{1,128}`、无 `..`/`/`/`*`） | P3-08 / D2 |
| `trigger` | 字符串 | 根 = D41 全家族任一；链内节点 = `chain`（裸关键字、无参数、仅 managed） | D41 / D47 |
| `dependency` | 字符串 | `[?]<task-id>[:<STATE>]`（逗号规范分隔、≤`DEP_MAX=32` 条）——**即 DAG 入边集**，STATE ∈ {`STOPPED`,`FAILED`}，缺省 `STOPPED` | D1/D2 / D46 |
| `condition` | 字符串 | 不变（P4-06/P5-03 白名单文法；链节点释放时同样求值） | D18–D22/D38–D40 |
| `enabled` | 0/1 | 不变；`0` = 链中断路（D15 语义） | P3 |
| `retry.max` / `retry.interval` / `retry.cooldown` | 数字 | 不变；**节点级重试，仅节点级** | P4-07 D23–D26 |
| `action.*` | 既有 | 不变（执行路径零改动：SYSTEM/TERMUX/INTERACTIVE/notify/msg） | P3/P4 |
| `health.*` / `recovery.type` | 既有 | 不变（supervisor 节点级交互零改动，D25 沿用） | P3 |
| `source.*` / `runtime.*` | 既有 | 不变 | P3 |

**fixtures 字段白名单**（机器可读 golden；`tests/p6-dag/test.sh` §schema-doc 逐行提取比对，
本块与上表同步维护）：

```dag-fields
schema_version
id
name
enabled
trigger
condition
dependency
action.type
action.command
action.notify_start
action.notify_end
action.delete
action.termux
action.interactive
action.run_once_now
action.boot
action.msg
health.type
health.target
recovery.type
retry.max
retry.interval
retry.cooldown
source.type
source.line
source.raw
```

**非字段状态定义（常量，P6-06 落地；均 `VAR=${VAR:-默认}` 可环境覆盖）：**

| 常量 | 值 | 语义 |
| `DAG_CHAIN_NODES_MAX` | 32 | 单链闭包节点数上限（配置期拒绝） |
| `DAG_CHAIN_EDGES_MAX` | 128 | 单链闭包去重边数上限（配置期拒绝） |
| `DAG_CHAIN_DEPTH_MAX` | 16 | 链最长路（根→节点）上限（配置期拒绝） |
| `DAG_RUNS_MAX` | 8 | 全 scheduler 活跃 run 并发上限（运行期：新 run 不启动） |
| `DAG_PARALLEL_MAX` | 4 | 单 run 在途节点进程上限（运行期：顺延下一 tick） |
| `DAG_RUN_TIMEOUT` | 86400 | 单 run 总时限秒（= WAIT_MAX 对齐；超时 run=FAILED） |
| `DAG_RUNS_KEEP` | 8 | 每链保留历史 run 目录数（prune） |

### 2.1 示例 Task 文件（规范样例）

```
schema_version=2
id=demo_build
name=build
enabled=1
trigger=interval:60
condition=
dependency=
action.type=command
action.command=/data/adb/su-scheduler/demo/build.sh
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=none
recovery.type=none
retry.max=0
retry.interval=60
```

```
schema_version=2
id=demo_deploy
name=deploy
enabled=1
trigger=chain
condition=
dependency=demo_build
action.type=command
action.command=/data/adb/su-scheduler/demo/deploy.sh
...（action.*/health/retry 同上，缺省）
```

```
schema_version=2
id=demo_cleanup
trigger=chain
dependency=demo_deploy,?demo_notify:FAILED
...
```

（完整机器可读 fixtures：`tests/p6-dag/fixtures/`，全部为**当前** `tcfg_validate_task`/
`dep_validate_graph` 可解析的合法 Task v2 文件——提案 schema 不依赖任何未实现字段。）

## 3. 裁决记录（D46–D58）

### D46 边载体 = `dependency=`（P6-05 D-01）

DAG 边与 P4 依赖边**同一字段、同一语法、同一校验器**（`dep_validate`/`dep_normalize`/
`dep_entry_ok`/`dep_validate_graph` 逐字节复用）。Required/Optional（`?`）与期望终态
（`:STATE`）即边类型，与 D15/D16 一一映射（D51）。禁止第二边语法/新字段（`dag.edges=` 被拒，
理由见 §6）。

> **现行为注记（`tests/p6-dag` PB-05/06/07 诚实锁定）**：D1 文法声明的「空格/制表符容错」
> 在 `dep_validate` 层实际只余**空格**可达（TAB 先被可打印性门 `[^ -~]` 拒绝）；链校验升级
> （D55）**必须继承该门与既有消息**，不得借 DAG 立项顺手放宽或改写 P4 存储层行为。

### D47 `trigger=chain` 家族（P6-05 D-02/D-12）

- 裸关键字（同 `boot_completed` 先例，无参数）；语义：**该任务无自主时间触发，仅由链引擎在
  frontier 满足时释放执行**。
- **仅 Managed**（B16）：`tcfg_editor_trigger_ok` 增枚举；`legacy_adapter_parse` 零 diff；
  `trigger_decide` 增 `chain` 分支，恒 `due=N|cause=`（释放不经时间窗口，经 D49/D50 通道）。
- 链 = 从根（任一真实触发器任务）沿**反向依赖闭包**（`dependency` 引用根的 `trigger=chain`
  节点，传递闭包）推导，**无独立链配置对象/注册表/IPC op**。链的身份 = 根 id。
- 节点可被多根闭包共享（合法 DAG 形态）；各链 run 独立记账，互不读取。

### D48 链运行与触发重复（P6-05 D-03）

- 链为模板：根**每轮**触发（含 interval/cron/boot/boot_completed/时间族；P6-02 catch-up 的
  补执行同样算一轮）创建一次链运行。
- `chain_id = 根任务 id`（已受 id 门约束）；`run_id = sched_cycle_token`（`YYYYMMDDHHMM`，
  12 位数字 ⊂ `secv_id_ok` 字符集）。**同一根同一分钟窗口至多一次 run**（目录名=token 天然去重，
  与任务级 cycle 去重同轴）。
- **手动 `tctl start/restart`（含 force）不创建 run**（v1）；run 是调度器行为产物。
- run 登记时机 = 根动作**终态被调度器观察到**（execute/advance/catch-up/boot 通道）；观察机制
  归 P6-06（未决 U-1）。

### D49 状态文件布局（P6-05 D-13/D-09）

```
$base/dag/                          0700（root-only；纳入 secv_fix_perms）
  <chain_id>/                       = 根任务 id（secv_id_ok 已门）
    runs/
      <run_id>/                     = cycle token（12 位数字）
        run.txt                     唯一状态文件（tmp+mv 原子整写，单遍重写）
```

`run.txt` 格式（`key=value` 头 + 每节点一行）：

```
chain=demo_build
run=202609080600
state=RUNNING                       # PENDING|RUNNING|SUCCESS|FAILED|CANCELLED(预留)
created=1789192800                  # epoch 秒
root=demo_build|STOPPED|1           # id|run.txt 态|attempt 记账位
demo_deploy|chain|RUNNING|
demo_cleanup|chain|PENDING|opt-wait
```

- 路径拼接只允许已验证 id 与数字 token；读取前 `secv_inside "$base/dag" <path>` +
  `secv_nosymlink`；目录不存在 = 无链（非错误）。
- 每链 `runs/` 下超 `DAG_RUNS_KEEP` 的旧 run 目录按 token 字典序（=时间序）prune。
- `secv_sweep_tmp` 扩展模式：`$base/dag/*/runs/*/run.txt.tmp.*`（P6-06）。
- run.txt 不可解析 → 审计 `dag=run-corrupt` → 按超时路径置 FAILED → 正常 prune（不猜态）。

### D50 链级状态记录（非 TSM 扩充）（P6-05 D-13）

- 链级状态 ∈ `run.txt.state`：`PENDING → RUNNING → SUCCESS|FAILED`；`CANCELLED` **枚举预留、
  v1 不产出**（链取消 API 归后续立项）。
- **任务状态机零改动**：183 条迁移（`task-state-machine-transitions.tsv`）不增不删不改；
  节点态仍 ∈ 11 态枚举由 `state.txt` 管辖。run.txt 是**聚合登记簿**，不是状态机实例。
- 新事件令牌仅 2 个，走 `RT_EVENTS`（D13 先例，不入 `TSM_CAUSES`）：`dag_register`（run 创建）、
  `dag_dispatch`（节点释放→执行）。若 P6-06 借道 WAITING 通道释放，节点级事件仍用既有
  `gate_wait`/`gate_ok`/`gate_fail` 令牌。

### D51 失败传播映射 = D15/D16 逐行复用（P6-05 D-05）

见 `docs/P6-05.md` D-05 表。要点：Required 边上游终态 ≠ 期望 → 节点立即 FAILED（不等超时）并
沿边级联；Optional 任何不满足不阻断（`opt-unsat`）；`:FAILED` 边 = 「上游失败才执行」的合法
故障分支；全部成员终态后 run = 无 FAILED 则 SUCCESS 否则 FAILED。

### D52 编排与并行（P6-05 D-04）

frontier 每 tick 单遍计算；节点释放叠加 `sched_cond_check`（假 → 不释放，审计 `dag=cond-unmet`）；
单 run 在途进程 ≤ `DAG_PARALLEL_MAX=4`，超限顺延；无新执行体/线程/第二循环（C5/P2-12）。

### D53 优先级矩阵（P6-05 D-06）

每 tick 层序固定：`WAITING advance(P4) ▶ 链引擎 pass(P6-06 新) ▶ retry-arm(P4-07) ▶
catch-up(P6-02) ▶ 主循环`。根侧触发/门控/条件顺序 = D44 原文不动。重试仅节点级（D23–D26 原语义，
gate_fail 不接退避、不 auto-recovery——D25）；**链永不自动重放**；跳拍补偿仅作用于可补偿族的
根；cooldown/crash guard 节点级不变。

### D54 手动控制（P6-05 D-07）

`task stop/restart/start/check`（含批量 ≤50）逐节点零特判；手动 stop → STOPPED 可满足缺省
`:STOPPED` 边（文档化行为，README 将显式警示）；disable = 中断路（D15 有界等待→超时 FAILED）；
v1 无链级取消；零新 IPC op（B7）。

### D55 配置期校验升级（P6-05 D-08）

`dep_validate_graph` 尾部新增链段（既有未知/自依赖/环消息与 rc **逐字节不变**）：深度/节点数/
边数超限、孤儿 `trigger=chain`（无有效入边）→ 配置期拒绝；接入点 = D9 表四写路径
（apply/set/import/snapshot）零新增；IPC 信封 = `configuration_invalid`（rc4）+ P6-04
`configuration_invalid: <字段级原因>` 通道。

### D56 运行期图变更与一致性（P6-05 D-09）

run 成员集登记时冻结；frontier 每 tick 按**现图**重算；删除/禁用成员 → D15 missing/disabled
有界等待；配置回滚不回滚 run.txt（运行态前滚）；run.txt 单文件 tmp+mv。

### D57 上限与超限行为（P6-05 D-10）

见 §2 常量表。结构非法（环/超限/孤儿）= 配置期拒绝；资源风暴（活跃 run 超 `DAG_RUNS_MAX`）=
运行期**不启动新 run**（审计 `dag=run-limit`），根照常执行、在途 run 不受影响；run 超时只停止
释放，**不强杀在途节点进程**。

### D58 可观测性预留（B8 只增键）与错误映射（P6-05 交付物 B 要求）

| 面 | 键（P6-06 落地；**只增不改删**） |
| GET_SUMMARY | `dag: { "active": <int>, "limit": <int>, "recent_failed": <int> }` |
| GET_TASK_DETAIL | `dag: { "chain_root": "<id|''>", "role": "root|node|''", "run": "<token|''>", "run_state": "<五态|''>" }` |
| CLI `task status/info` | 追加行 `Chain Root:` / `Run:` / `Run State:`（旧行零改动，D32 兼容） |
| 审计 | `op=dag|action=register|dispatch|limit|timeout|corrupt|prune|task=<id>|chain=<root>|run=<token>|...` |

**错误语义 → 既有 IPC 码（零新码）**：

| 场景 | 码 | 载荷（P6-04 字段级透传通道） |
| 环/自依赖/未知依赖 | `configuration_invalid`(rc4) | `configuration_invalid: cycle: a->b->a`（既有消息） |
| 链超限/孤儿 | `configuration_invalid`(rc4) | `configuration_invalid: chain depth 17 exceeds DAG_CHAIN_DEPTH_MAX=16` 等 |
| 非法 id/边字符 | `invalid_request`(rc1) | `invalid_request: invalid id (charset/path-traversal)`（既有） |
| 非 managed | `configuration_invalid`(rc4) | 既有 import-first 提示 |
| 查询不存在的链 | `task_not_found`(rc3) | 既有 |
| daemon 离线/超时/频控 | `daemon_unavailable`(6)/`operation_timeout`(5)/`rate_limited`(7) | 既有 |

## 4. 安全边界（P6-06 必须实现）

1. **ID/路径门**：`chain_id`/`node_id`/路径段全部过 `secv_id_ok`；run 目录名仅 `[0-9]{12}`；
   拼接前校验、读时 `secv_inside`/`secv_nosymlink`（P3-08 既有三件套）。
2. **零 Shell 求值**：run.txt 解析 = 纯字段切分（`cut -d'|'`，mksh 兼容 NF-7/D34 惯例）；
   节点 id/边字符串永不进入 `eval`/`sh -c`/反引号/`$( )`；frontier 判定只读 `state.txt`。
3. **注入拒绝预期**（fixtures 已锁定校验层现行为）：`;` `|` `$()` 反引号 `..` `/` 换行
   超 128 字符 → `secv_id_ok`/`dep_validate`/`tcfg_validate_task` 全部拒绝（`tests/p6-dag` §inject）。
4. **资源界**：D57 上限表 + `DAG_RUNS_KEEP` prune + `secv_sweep_tmp` 扩展 + IPC 频控（既有）。
5. **权限**：`$base/dag` 0700 / `run.txt` 0600（`secv_fix_perms` 覆盖）。

## 5. Legacy 边界（重申）

DAG 与 legacy `config.txt` **零关系**（D-12/B16）：legacy 语法零变化、`legacy_adapter_parse`
零 diff、非 managed 模式下链引擎 pass 不运行。`tests/legacy/golden.sh` 与 `tests/parsing`
golden 持续守卫。

## 6. Alternatives considered（被拒方案汇总）

| 方案 | 拒因 |
| `dag.edges=` 新字段 | 与 `dependency=` 双源边、冲突权威无解；环/字符集/上限校验全套分叉（§2 D-01） |
| `chain=<root-id>` 成员字段 | 第二身份源可与边集矛盾；字段说属链 A、边闭包说链 B |
| 独立 `.chain` 配置对象 | 新权威实体：import/export/回滚/原子写/版本一致性全套扩容（D-02） |
| 事件推送式传播（收尾回调拉起下游） | 改 `execute_task`/`action_run` 收尾路径（C2 违例）；daemon 重启断链 |
| `RUN_CHAIN`/`CANCEL_DAG` 新 IPC op | B7 违例；WebUI Root 直执链风险 |
| 任务状态枚举扩充（CHAINED 等） | 183 迁移表回炉 + WebUI counts 键语义破坏 B8（D-13） |
| 链级自动重放（retry.policy=chain） | 已成功节点重复副作用；Android shell 任务幂等不可静态判定（D-06） |
| 超活跃 run 上限时杀最旧 run | 误杀用户执行中任务；拒启动新 run 严格更安全（D-10） |
| 无上限（D35 类比） | run 数 = 根周期×链数，可无界增长；WAITING 的有界终态论证不迁移 |

## 7. P6-06 实施接线清单（批准后生效；本任务零实现）

| # | 文件 | 改动 |
| 1 | `system/bin/su-scheduler-runtime` | `tcfg_editor_trigger_ok` 增 `chain`；`trigger_decide` 增 `chain` 恒 `due=N` 分支；`dep_validate_graph` 尾部链段校验（D55）；链引擎 pass（`scheduler_tick` 内，D52/D53）；run.txt 读写（tmp+mv，D49）；prune + `secv_sweep_tmp`/`secv_fix_perms` 扩展；§22 聚合器只增键（D58）；`runtime_lib_selfcheck` 注册新函数 |
| 2 | `system/bin/su-schedulerd` | 预计**零改动**（引擎在库内；若登记观察需 tick 上下文，最小 diff 另行评审） |
| 3 | `system/bin/su-scheduler`（CLI） | `task status/info` 增列（D58）；其余复用 |
| 4 | `webroot/` | 只读展示（B8 键）；链图形化**不做**（范围外） |
| 5 | `tests/p6-dag/test.sh` | 全部 `[SKIP]` 断言转 `[PASS]`（出口条件）；设备冒烟链用例 |

## 8. 未决事项（不阻塞批准，P6-06 前需定）

- **U-1 run 登记观察机制**：根终态→run 创建的探测方式（state.txt 差分 vs 执行标记文件 vs
  tick 审计回读）。约束：不改 `execute_task`/`action_run` 签名与路径（C2）。
- **U-2 链节点是否借道 WAITING**：frontier 未满足的链节点显示为 `PENDING`（引擎自持等待簿，
  推荐）还是 `WAITING`（复用 P4 通道但语义混叠人工等待）。影响 WebUI 计数展示，零迁移表影响。
- **U-3 `dag_dispatch` 与 cycle token 交互**：同窗口根 run 与节点释放的 mark 顺序细节。
- **U-4 多根共享节点的 run 串扰演练**：设备冒烟用例设计（真机 tick 预算）。

## 9. 后果

- 正向：链式调度获得与 P4 同一事实源的边/校验/传播语义；fixtures 在**未实现引擎**的今天
  已可被现校验器解析/拒绝（行为可锁定、回归可先行）；183 状态机、19 IPC op、Legacy 域、
  config.txt 格式四者零触碰。
- 代价：链可观测性晚于配置语法一个阶段（P6-06 前 `trigger=chain` 任务恒不执行——editor
  白名单未扩充前甚至无法创建，**风险窗口小**）；「手动 stop ≈ 成功」需要文档反复强调。
- 回退：DAG 声明均为既有字段值，删除链配置 = 普通任务编辑；`$base/dag/` 为纯增量运行态目录，
  可整树删除不影响既有调度。

## 附：决策记录

| 编号 | 主题 | 状态 |
| D46 | 边载体 = `dependency=` 扩展 | ACCEPTED·2026-09-08（P6-05 D-01） |
| D47 | `trigger=chain` 家族（managed-only） | ACCEPTED·2026-09-08（P6-05 D-02/D-12） |
| D48 | 链运行/重复触发/run id=cycle token | ACCEPTED·2026-09-08（P6-05 D-03） |
| D49 | 状态文件布局 `$base/dag/<chain>/runs/<token>/run.txt` | ACCEPTED·2026-09-08（P6-05 D-09/D-13） |
| D50 | 链级五态 = 文件记录；183 零改动 | ACCEPTED·2026-09-08（P6-05 D-13） |
| D51 | 失败传播 = D15/D16 一一映射 | ACCEPTED·2026-09-08（P6-05 D-05） |
| D52 | frontier 编排与并行闸 | ACCEPTED·2026-09-08（P6-05 D-04） |
| D53 | 优先级矩阵/重试仅节点级 | ACCEPTED·2026-09-08（P6-05 D-06） |
| D54 | 手动控制节点级 only | ACCEPTED·2026-09-08（P6-05 D-07） |
| D55 | 配置期校验升级口径 | ACCEPTED·2026-09-08（P6-05 D-08） |
| D56 | 运行期图变更一致性 | ACCEPTED·2026-09-08（P6-05 D-09） |
| D57 | 上限数值与超限行为 | ACCEPTED·2026-09-08（P6-05 D-10） |
| D58 | 可观测只增键 + 错误码映射 | ACCEPTED·2026-09-08（交付物 B） |
