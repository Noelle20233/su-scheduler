# Su Scheduler — P5 阶段交接资料（P5-HANDOVER）

> **任务**：P5-11 · P5 综合回归与出口评审（本文件为「文档交接」交付物）
> **前置**：P4-HANDOVER、P4-EXIT-REPORT、P5-01..P5-10
> **性质**：给 P6 代码组与维护者的**稳定交接入口**——新成员按 §2 阅读路径可仅凭
> 文档理解 P5（Condition 扩展/新 Trigger/WebUI 增强/CLI 审计/设备验证）全链路；
> §5 明确 P6 候选需求与 P5 遗留观察（诚实边界）。
> **日期**：2026-09-07
> **版本**：模块 `v1.6.8`（不变）；Runtime 库 `1.30.0`（P5 出口）

---

## 目录

1. [交接对象与目标](#1-交接对象与目标)
2. [新成员阅读路径](#2-新成员阅读路径)
3. [P5 流程全景](#3-p5-流程全景)
4. [P5 已实现清单](#4-p5-已实现清单)
5. [P6 候选需求与 P5 遗留](#5-p6-候选需求与-p5-遗留)
6. [接口契约速查](#6-接口契约速查)
7. [安全边界（P6 必须延续）](#7-安全边界p6-必须延续)
8. [升级与回滚](#8-升级与回滚)
9. [验收标准对照](#9-验收标准对照)

---

## 1. 交接对象与目标

- **给谁**：P6 代码组（候选需求立项）、维护者、评审者、新加入的 Agent。
- **目标**：
  1. 新成员**只读文档**即可理解「新 Trigger → Condition 门控 → 调度 → WebUI/CLI 可观测」
     的 P5 全链路；
  2. 明确 P5 **已实现**、**遗留观察**、**P6 候选**三者边界；
  3. 明确升级/回滚路径与数据兼容；
  4. 明确 P5 安全边界如何在 P6 延续（零 Shell 求值、只增键、19 op、无 Root 直执）。

## 2. 新成员阅读路径

按序阅读（先总览后细节）：

```
1. docs/P5-EXIT-REPORT.md           ← P5 出口评审（回归/约束/缺陷/矩阵/出口判定）
2. docs/P5-01.md / P5-BASELINE-COMPATIBILITY.md   ← P5 基线冻结（B15-B21）
3. docs/P5-02.md + docs/P5-03.md    ← Condition 语法冻结 + 运算符实现（D38-D40）
4. docs/P5-04.md + docs/architecture/trigger-schema-v2.md   ← Trigger Schema v2（D41-D45）
5. docs/P5-05.md                    ← 新 Trigger 调度接线
6. docs/P5-06.md + docs/P3-05-WEBUI-DATA.md       ← WebUI 实时状态 + 数据契约
7. docs/P5-07.md                    ← 依赖可视化与批量操作
8. docs/P5-08.md                    ← CLI 与审计增强（next_due/cause）
9. docs/P5-09.md + docs/security-audit.md         ← 资源安全加固
10. docs/P5-10.md + docs/P3-DEVICE-MATRIX.md      ← 设备矩阵发布验证
11. docs/P5-CANDIDATES.md           ← 缺陷状态与观察项
12. docs/P4-HANDOVER.md             ← P4 交接（前置依赖/门控基线）
```

## 3. P5 流程全景

```
   Task v2（managed，新 Trigger + condition + dependency）
          │  tcfg_* 权威存储（原子 tmp+mv，校验期拒绝）
          ▼
   Registry 调度（P3-03 §20 + P5-05 接线）
     trigger_decide（boot/time/advanced + oneshot/delay/interval/cron/boot_completed）
       → due=Y|cause=<family>
       → 依赖门控 sched_gate_check（WAITING/Retry，P4-04/05/07）
       → 条件门控 sched_cond_check（==/!=/</>/<=/>=/contains，P5-03）
       → action_run（SYSTEM/TERMUX/INTERACTIVE）
       → 后置（delete/ron/oneshot 自删/last-run 键）
          │  audit.log（op=exec|cause=，P5-08 透传）
          ▼
   WebUI/CLI 只读面（P5-06/07/08，只增键 B8，19 op B7）
     GET_SUMMARY（counts 9 键 + dep_errors）
     GET_TASK_DETAIL（dependency_state/condition_state/gate_state/last_event）
     task status/info（trigger_kind/next_due/last_trigger_cause/批量查询）
```

- **主路径**：`.task`（managed）→ 权威存储 → Registry → 触发决策（新/旧家族）→ 依赖/条件
  门控 → `action_run`；WAITING 由 `scheduler_tick` 逐周期复查；控制/查询经 IPC 白名单。
- **新 Trigger 仅 Managed**（B16）：oneshot/delay/interval/cron/boot_completed 不出现在
  legacy config.txt。

## 4. P5 已实现清单

| P5 任务 | 交付（生产面 + 测试域 + 文档） | 验证（回归断言） |
| :-- | :-- | :-- |
| P5-01 | 基线冻结 + B15–B21 + 设备矩阵缺口登记 | 宿主 1906/0；D-P5-01 后续修复 |
| P5-02 | Condition 语法冻结（D38–D40 ADR + 正负注入 fixtures） | p5-condition 60/0 |
| P5-03 | Condition 运算符实现（`<`/`>`/`<=`/`>=`/`contains`，注入面按字段判定） | p5-condition 60/0；46 套件全绿 |
| P5-04 | Trigger Schema v2 + 持久化（D41–D45；Editor 校验扩展） | p5-trigger 81/0；validation 41/0 |
| P5-05 | 新 Trigger 调度接线（5 Provider + trigger_decide 分流 + rearm + boot_completed 上下文） | p5-trigger 117/0；真机 5/5 |
| P5-06 | WebUI 实时状态（周期刷新/错误保留/WAITING/RECOVERING/condition_state/last_event） | p5-webui 43/0；48 套件全绿 |
| P5-07 | 依赖可视化与批量操作（dep_errors + CLI 批量多 id + 前端依赖视图/批量 UI） | p5-webui 64/0；task-control 55/0 |
| P5-08 | CLI 与审计增强（next_due 真计算×6 + cause 透传 + 批量查询；Runtime 1.30.0） | p5-trigger 135/0；task-cli 55/0 |
| P5-09 | 资源安全加固（cron 列表/批量上限 + mksh/主循环断言 + per-task 节流裁决） | 生产 +5 行；48 套件 2236/0 |
| P5-10 | 设备矩阵发布验证（KernelSU×A16 全链路 A–H） | host 2236 + p3 28 + p1 11 |
| P5-11 | 出口评审 + O-1 修复 | 全绿（§1） |

- **生产改动**：`su-scheduler-runtime`（+699，P5 主体：Trigger Provider/Condition 运算符/
  WebUI 聚合器/CLI 查询）、`su-schedulerd`（+37：boot_completed 上下文）、`su-scheduler`
  （+56：批量/查询/错误消息）、`webroot/`（+302：刷新/依赖视图/批量 UI）。
- **service.sh 零改动**（C5）。

## 5. P6 候选需求与 P5 遗留

> **硬性声明**：以下各项在 P5 **未实现/未处理**，任何文档不得把候选表述为已完成。

| 项 | 现状 | 建议入口 | 优先级 |
| :-- | :-- | :-- | :-- |
| **通用 DAG / 拓扑调度 / 链式依赖** | 零实现（P4 D7/D4 边界延续） | 依赖图已是简单 DFS 无环；如需通用 DAG 需重新立项 | P6 候选（禁止提前实现） |
| **O-2 主循环跳拍 catch-up** | 主循环偶发 >60s 间隙导致精确 HHMM 无补跑 | `scheduler_tick` 增加 catch-up（上次 tick 分钟差 >1 时补执行） | P6 候选 |
| **O-3 cron `task-config new` ID 派生** | `tcfg_new_id` 对含空格 trigger 失败（apply/task 文件路径正常） | 优化 ID 派生（空格→`_` 或哈希） | 后续任务 |
| **O-4 EDIT_TASK 错误透传** | `configuration_invalid` 吞具体 stderr；ipc 双编码易误用 | 错误透传增强 + ipc 参数约定文档 | 后续任务 |
| **设备矩阵扩展** | 仅 KernelSU×A16；Magisk/APatch/A12-15 共 14 格未覆盖 | 需真实设备/模拟器；优先级见 P5-10 | P6 发布前提（如有设备） |
| **秒级 interval/delay** | P5 冻结分钟级（B20 tick 周期） | 需改 daemon 唤醒周期，架构决策 | P6+ 候选 |
| **配置加密 / 备份增强 / 多配置切换** | 未实现（P0 AGENTS §9 延续） | 重新评估需求 | P6+ 候选 |
| **Watchdog 增强** | 既有看护循环原样（service.sh 零改动） | 不触碰 service.sh；如需新机制需架构决策 | P6+ 候选（谨慎） |
| **云同步 / 多设备 / 多用户** | 零实现 | 未列入需求 | P6+ 候选 |

## 6. 接口契约速查

```sh
# Trigger Schema v2（P5-04，仅 Managed，详见 trigger-schema-v2.md）
trigger=oneshot:<HHMM> | delay:<MIN> | interval:<MIN> | cron:<m> <h> <dom> <mon> <dow> | boot_completed
# Condition 运算符（P5-03，D38-D40）
#   time.*  : == != < > <= >=     字符串域（task.state/env.*）: == != contains
cond_grammar_ok / cond_eval（三态 0/1/2，零 Shell 求值）
# 只增键（B8）：
GET_SUMMARY   counts.{total,running,healthy,failed,disabled,unhealthy,unknown,waiting,recovering} + tasks[].dependency + dep_errors
GET_TASK_DETAIL task.{...,dependency_state,gate_state,condition_state,last_event}
# CLI（P5-08）：
task status <id>...（trigger_kind/next_due/last_trigger_cause/condition_state/dependency_state）
task-info（Trigger:/Next Due:/Last Trigger Cause:/Condition State:/Dependency State:）
# 批量（P5-07，≤50 id，B7 零新 op）：task {start|stop|restart|check|enable|disable} <id>...
# 审计（P5-08）：op=exec|task=...|trigger=...|mode=...|rc=...|cause=<family>
```

## 7. 安全边界（P6 必须延续）

1. **Condition 零任意 Shell 求值**：纯字符串解析 + 白名单表驱动；`<`/`>` 仅运算符位置合法，
   右值/谓词位置仍拒（D40）；禁 eval/sh -c/`$(`/反引号/管道到命令。
2. **B7 白名单 19 op 不变**：批量/增强全部在既有 op 之上实现（CLI/前端层循环）。
3. **B8 只增键不删字段**：WebUI JSON 契约只增不改。
4. **WebUI 无 Root 直执**：webroot 零 su -c/sh -c；仅经 IPC 只读；textContent 防注入。
5. **mksh 兼容（D36/D37）**：P5 新代码全为逗号/字面量/转义 `*` pattern；禁裸 `|`/`(`/`)`
   in-pattern 展开（lint 断言锁定）。
6. **原子保存/回滚（B9/B19）**：tcfg tmp+mv 原子；失败逐字节不变；批量部分失败不破坏配置。
7. **主循环恰 1（B20）**：`while true` 仅 su-schedulerd L737；库零常驻（stress 断言锁定）。

## 8. 升级与回滚

- 命令级手册：`docs/P4-UPGRADE-ROLLBACK.md`；P5 验证记录：`docs/P5-10.md` §H。
- 升级 = 安装 `su-scheduler-v1.6.8.zip`（Runtime 1.30.0）；回滚 = 卸载或重装旧版；
  数据保险库（`/data/adb/su-scheduler` 与 config.txt）卸载时保留，P5-10 实测无迁移负担
  （mode/task/audit/schedule_state 全保留）。

## 9. 验收标准对照

| 验收标准 | 落实 |
| :-- | :-- |
| P5 全量回归全绿 | `P5-EXIT-REPORT.md` §1（48 套件 2236/0 + 设备 39/0） |
| 约束审计 C1–C5 | `P5-EXIT-REPORT.md` §3（全部通过） |
| P5 已实现/未实现/候选边界 | §4 / §5 |
| 设备矩阵如实 | `P5-EXIT-REPORT.md` §5（1/15 + 14 格限制） |
| 缺陷状态 | `docs/P5-CANDIDATES.md`（D-P5-01..05 + O-1 已修复；O-2..O-4 登记） |
| P6 移交清单 | §5 |
| P5 出口判定与签核 | `P5-EXIT-REPORT.md` §7（出口条件 1–9；14 格 ⏳ 需人工签核） |
