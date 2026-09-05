# Su Scheduler — P4 阶段交接资料（P4-HANDOVER）

> **任务**：P4-12 · P4 出口评审与发布准备（本文件为「文档交接」交付物）
> **前置**：P3-HANDOVER、P3-EXIT-REPORT、P4-01..P4-11
> **性质**：给 P5/P6 代码组与维护者的**稳定交接入口**——新成员按 §2 阅读路径可仅凭
> 文档理解 P4（Dependency/Condition/WAITING/Retry/可观测/真机验证）全链路；
> §5/§6 明确 P4 已实现/未实现/下一阶段候选需求（诚实边界，不宣称为已完成）。
> **日期**：2026-09-05
> **版本**：模块 `v1.6.8`（不变）；Runtime 库 `1.28.0`（P4 出口）

---

## 目录

1. [交接对象与目标](#1-交接对象与目标)
2. [新成员阅读路径](#2-新成员阅读路径)
3. [P4 流程全景](#3-p4-流程全景)
4. [P4 已实现清单](#4-p4-已实现清单)
5. [P4 未实现与下一阶段候选](#5-p4-未实现与下一阶段候选)
6. [接口契约速查](#6-接口契约速查)
7. [安全边界](#7-安全边界)
8. [升级与回滚](#8-升级与回滚)
9. [验收标准对照](#9-验收标准对照)

---

## 1. 交接对象与目标

- **给谁**：P5 代码组（候选需求立项）、维护者、评审者、新加入的 Agent。
- **目标**：
  1. 新成员**只读文档**即可理解「配置 → 权威存储 → Registry 调度 → Dependency/
     Condition 门控 → WAITING/Retry → IPC 控制面 → WebUI 编辑/可观测」完整链路；
  2. 明确 P4 **已实现**、**未实现**、**P5/P6 候选**三者边界（不模糊、不提前实现）；
  3. 明确升级（发布采用）与回滚路径（`docs/P4-UPGRADE-ROLLBACK.md`）；
  4. 明确 P4 安全边界（Condition 零任意 Shell 求值、依赖图无环/未知拒绝、WAITING
     有界可观测、IPC 白名单 19 op 不变）如何在 P5/P6 延续。

## 2. 新成员阅读路径

按序阅读（每份 10–30 分钟；先总览后细节）：

```
1. AGENTS.md / P4-01..P4-11 任务文档（按序）
2. docs/architecture/dependency-schema.md     ← Dependency/Condition ADR D1–D37（P4 核心）
3. docs/P4-DEPENDENCY-REQUIREMENTS.md         ← P4 需求输入（NF-1..NF-8、安全边界）
4. docs/P4-BASELINE-COMPATIBILITY.md          ← B1–B14 冻结契约（P4-01）
5. docs/architecture/registry-scheduling.md   ← Registry 调度（P3-03，P4 门控叠加点）
6. docs/architecture/config-authority.md      ← 配置权威双模式（P3-02）
7. docs/architecture/ipc-protocol.md          ← IPC 协议（P3-04，P4 复用不扩 op）
8. docs/P4-11.md                              ← 真机全链路验证 + D-A/D-B/D-C 缺陷记录
9. docs/P3-DEVICE-MATRIX.md                   ← 设备矩阵（KernelSU×Android16 已覆盖）
10. docs/P4-EXIT-REPORT.md                    ← 出口评审与覆盖矩阵（P4-12 冻结）
11. docs/P4-HANDOVER.md（本文档，快速总览）
```

> 每份文档头部均有「任务/依赖/接线边界」注记块。

## 3. P4 流程全景

```
   Task v2（managed，含 dependency=/condition= 键）         legacy config.txt
          │  tcfg_* 权威存储（原子 tmp+mv，图校验写前拒绝）      │ legacy_adapter
          ▼                                                     ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │         Registry 正式调度（P3-03 §20，P4 门控叠加）              │
   │   scheduler_tick：TriggerProvider 决策 → sched_execute_one       │
   │     ├─ 依赖门控（P4-04 §20b）：dep 不满足 → PENDING>WAITING      │
   │     │    WAITING 复查：满足 → gate_ok STARTING；超时 → gate_fail │
   │     │    Required 失败传播（P4-05）；Optional 不阻断             │
   │     ├─ Condition 门控（P4-06）：白名单谓词求值（真执行/假跳过）  │
   │     ├─ Retry 退避（P4-07）：FAILED>WAITING + retry.until 计时    │
   │     └─ Supervisor/Recovery（P2-12，gate.fail 不 auto-recovery）  │
   └───────────────────────────┬──────────────────────────────────────┘
                               │ action_run（统一执行入口）
                               ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │   本地 IPC 受控边界（P3-04 §21，白名单仍 19 op）                 │
   │   GET_SUMMARY/GET_TASK_DETAIL/GET_TASK_EVENTS/…（P4-09 只读查询）│
   │   VALIDATE_TASK/EDIT_TASK（P4-08 依赖编辑器，不新增 op）         │
   └───────────────┬────────────────────┬─────────────────────────────┘
                   │ read                │ write/control
                   ▼                     ▼
   ┌─────────────────────────┐  ┌──────────────────────────────┐
   │ WebUI 只读数据面         │  │ Task Editor / Task 控制      │
   │ dependency_state/gate_…  │  │ EDIT_TASK（含 dep/cond 键）  │
   │ waiting 计数（P4-09）    │  │ tctl_start/stop/restart/…    │
   └─────────────────────────┘  └──────────────────────────────┘
```

- **主路径**：`.task`（managed）或 `config.txt`（legacy）→ 权威存储 → Registry →
  触发决策 → 依赖/条件门控 → `action_run` 执行；WAITING 任务由 `scheduler_tick`
  逐周期复查（有界 WAIT_MAX=86400s）；控制/查询经 IPC 白名单路径。
- **门控插入点**：`sched_execute_one` due=Y 分支（依赖）+ `sched_cond_check`
  独立契约（条件，与依赖 AND）；`scheduler_tick` 首部 WAITING 复查通道（D11/D14）。

## 4. P4 已实现清单

| P4 任务 | 交付（生产面 + 测试域 + 文档） | 验证（回归断言） |
| :-- | :-- | :-- |
| P4-01 | 基线冻结 + D-IPC 真机复验 + Runtime 版本检查 A/B | WSL 基线 1631 PASS / 0 FAIL |
| P4-02 | Dependency/Condition Schema 解析 + 权威校验 + 原子持久化（§26 `dep_*`/`cond_*`） | p4-dependency 52/0 |
| P4-03 | 依赖图校验与循环检测（未知/自依赖/环，覆盖 apply/set/import/snapshot） | p4-dependency 81/0 |
| P4-04 | WAITING 状态 + 依赖门控（gate_wait/ok/fail、WAIT_MAX 有界） | p4-dependency 110/0 |
| P4-05 | Required/Optional 失败传播（终态不匹配立即 FAILED、缺失/禁用有界等待、force start） | p4-dependency 134/0 |
| P4-06 | Condition 受限表达式引擎（白名单谓词、==/!=、三态、零任意 Shell 求值） | p4-dependency 157/0 |
| P4-07 | Supervisor/Recovery/Retry 联动（FAILED>WAITING 退避、gate.fail 不 auto-recovery、prune 豁免） | p4-dependency 194/0 |
| P4-08 | IPC 与 WebUI 依赖编辑器（复用 VALIDATE_TASK/EDIT_TASK、注入拒绝 + B9） | webui editor 41/0、security 27/0 |
| P4-09 | CLI/日志可观测查询面（dependency=/Gate 行、detail 新字段、summary waiting） | p4-dependency 207/0 |
| P4-10 | 安全/资源/兼容性加固 + D34（`|`-in-pattern cut 修复）+ D35（WAITING 取舍） | p4-dependency 218/0；全量 1900/0 |
| **P4-11** | **设备矩阵与综合回归**：真机全链路（KernelSU×Android16）+ D-A/D-B/D-C 三缺陷修复 | `run_tests.sh --with-device` 全绿：宿主 3812 + p1-device 11 + p3-device 28 |
| **P4-12** | **出口评审与发布准备**（本阶段） | 见 `P4-EXIT-REPORT.md` §5（宿主 3812 + p1-device 11 + p3-device 28 + p3-integration 48 + p4-dependency 219 + build 26） |

- **全部 P4 生产改动**叠加于 `system/bin/su-scheduler-runtime`（新增 §20b 门控、
  §26 依赖/条件、§26b 可观测）+ `su-scheduler`/`su-schedulerd` 兼容接线与 P4-11
  缺陷修复 + `webroot/`（Editor Advanced 字段）；`service.sh` 零改动（C5）。

## 5. P4 未实现与下一阶段候选

> **硬性声明（验收）**：以下各项在 P4 **未实现**，任何文档不得把候选需求表述为
> 已完成；本节是 **P5/P6 候选需求清单**（交付物之一），不提前实现。

| 候选（P5/P6） | 现状 | 建议入口 | 优先级参考 |
| :-- | :-- | :-- | :-- |
| **Condition 运算符扩展**（`<`/`>`/`>=`/`<=`/`contains`） | P4-06 只做 `==`/`!=`（ADR D19 明确不在 P4 范围） | 扩展 `cond_grammar_ok`/`conde_*` 文法 + 新增谓词/运算符校验 + 测试 | P5 可选（明确不在 P4，D19） |
| **通用 DAG / 拓扑调度 / 链式依赖** | 零实现（P4 边界 ADR D7/D4） | 依赖图已是简单 DFS 无环；如需通用 DAG 调度器需重新立项 | P5/P6 候选（禁止提前实现） |
| **云同步 / 多设备 / 多用户** | 零实现 | 未列入需求 | P6+ 候选 |
| **新 Trigger 家族**（cron/interval/oneshot/boot_completed/delay） | Editor 表单 Trigger 未实现项 disabled | P4 未列 Trigger；P5 候选（非 Dependency 范围） | P5 候选 |
| **WebUI 增强**（Dashboard 实时刷新 / 依赖拓扑可视化 / 批量操作） | 只读数据面 + Editor 已就绪；无 WebSocket/自动刷新 | 前端只读消费扩展（不经新 IPC op） | P5 候选 |
| **配置加密 / 备份增强 / 多配置切换** | 未实现（P0 AGENTS §9 禁止项延续） | 需重新评估需求 | P6+ 候选 |
| **Watchdog 增强（service.sh 之外的自愈）** | 既有看护循环原样（C5） | 不触碰 service.sh；如需新看护机制需架构决策 | P6+ 候选（谨慎） |
| **依赖数量上限 / WAITING 数量显式上限再评估** | DEP_MAX=32 有上限；WAITING 数量不设显式上限（D35） | 若「注册任务无上限 + 大量同时 WAITING」进入需求，按 D35 重估 | 条件触发 |

- **P4 不做**：不实现上述候选；不改 `config.txt` 格式（C4）；不删除旧解析/执行路径
  （C2）；`service.sh` 看护原样（C5）；不新增 IPC op（白名单仍 19，B7）。

## 6. 接口契约速查

```sh
# 依赖/条件 Schema（P4-02 §26，详见 dependency-schema.md）
dep_entry_ok <entry>          # [?]<task-id>[:<STATE>]，STATE∈{STOPPED,FAILED} 缺省 STOPPED
dep_normalize <list>          # 逗号规范写回（空格/制表符容错）
dep_validate <list>           # 语法 + DEP_MAX(32) + 注入/穿越拒绝
dep_validate_graph <dir> [<id>] [<content>]   # 未知/自依赖/环拒绝（P4-03）
cond_validate <expr>          # 可打印 ASCII + COND_MAX_LEN(256)
cond_grammar_ok <expr>        # 谓词白名单 + ==/!=（P4-06）
cond_eval <expr> <tasks> [<now>] [<wday>]     # 0=真 1=假 2=非法（零 Shell 求值）
# 门控/WAITING（P4-04/05/07）
sched_gate_check / sched_cond_check / sched_advance_waiting / sched_retry_arm
WAIT_MAX=86400                # 有界终态（D13/D17/D35）
# 可观测（P4-09）
obs_gate_state <base> <id> / obs_dep_state <base> <id> / web_agg_summary（waiting 计数）
# CLI 查询
su-scheduler task status <id>（dependency=/Gate: 行，managed）；task-info（Dependency:/Condition:）

# IPC（P3-04 §21，白名单 19 op 不变；P4-08 编辑器复用 VALIDATE_TASK/EDIT_TASK）
# 新增 Task v2 键：dependency、condition（schema_version=2，managed 域）
```

## 7. 安全边界（P5/P6 必须延续）

1. **Condition 零任意 Shell 求值**：纯字符串解析 + 白名单表驱动；禁
   `eval`/`sh -c`/`$(`/反引号/重定向/管道到命令；非法 → 校验期拒绝（写盘前逐字节
   不变）+ 运行期防御不执行（`tests/security/fuzz` + `p4-dependency` §cond R）。
2. **依赖图无环 / 未知依赖拒绝**：`dep_validate_graph` 覆盖全部写路径
   （apply/set/import/snapshot/editor），环/未知/自依赖在写盘前拒绝，B9 原子性
   （原文件逐字节不变）。
3. **WAITING 有界且可观测**：`WAIT_MAX=86400` 保证每个 WAITING 任务有终态；
   prune 豁免 + registry 有界保证数量有界；`GET_SUMMARY` waiting 计数 /
   `GET_TASK_DETAIL` gate_state 可观测。
4. **IPC/WebUI 延续 P3 边界**：19 op 白名单 + base64 + 键白名单 + 原子响应；WebUI
   无 Root 直执（Editor 仅 payload 传参，后端权威校验）；只增键不删改（B8）。
5. **mksh 兼容（D34/D36/D37）**：`|`/`(`/`)` in-pattern 参数展开在 Android 16 mksh
   不可靠——新增代码一律 `cut -d'<c>' -fN` 切分；P4-11 后 daemon 单实例保护拒绝
   双实例接管、cmd_stop 按 `/proc` cmdline 匹配全部实例。

## 8. 升级与回滚

- 命令级手册：`docs/P3-UPGRADE-ROLLBACK.md`；P4 验证记录：
  `docs/P4-UPGRADE-ROLLBACK.md`。
- 升级 = 安装发布候选 zip（`ksud module install` / Magisk / APatch）；回滚 = 卸载
  或重装旧版；数据保险库（`/data/adb/su-scheduler` 与
  `/sdcard/Documents/su-scheduler/config.txt`）在卸载时保留，升级无迁移负担
  （legacy 配置兼容 + managed 可选导入 + 旧运行 ID 只读工件保留）。

## 9. 验收标准对照

| 验收标准 | 落实 |
| :-- | :-- |
| 新成员只读文档即可理解 P4 流程 | §2 阅读路径 + §3 流程全景 + 各架构文档 |
| 明确 P4 已实现/未实现/下一阶段候选 | §4 已实现 / §5 候选清单 |
| 不把候选需求宣称为已完成 | §5 硬性声明 + `P4-EXIT-REPORT.md` |
| Dependency/Condition schema 与 ADR | `docs/architecture/dependency-schema.md`（D1–D37） |
| P4 综合测试报告 | `docs/P4-EXIT-REPORT.md` §5（含全量数字） |
| 设备矩阵报告 | `docs/P3-DEVICE-MATRIX.md`（KernelSU×Android16 全链路）+ `docs/P4-11.md` |
| 构建产物和升级回滚验证记录 | `docs/P4-UPGRADE-ROLLBACK.md`（P4 实测） |
| 下一阶段候选需求清单 | §5（P5/P6 候选表） |
| P4 出口报告完成并人工签核 | `docs/P4-EXIT-REPORT.md`（§7 出口判定 + 签核） |
