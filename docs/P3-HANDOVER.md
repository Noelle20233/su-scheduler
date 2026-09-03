# Su Scheduler — P3 阶段交接资料（P3-HANDOVER）

> **任务**：P3-10 · P3 出口评审与发布准备（本文件为「文档交接」交付物）
> **前置**：P1-HANDOVER、P2-EXIT-REPORT、P3-01..P3-09
> **性质**：给 P4 代码组与维护者的**稳定交接入口**——新成员按 §2 阅读路径可仅凭文档
> 理解 P3 控制面/WebUI 全链路；§5/§6 明确 P3 已实现/未实现/下一阶段接口（Dependency、
> Condition、DAG 明确未实现，不宣称为已完成）。
> **日期**：2026-09-03
> **版本**：模块 `v1.6.8`；Runtime 库 `1.19.0`

---

## 目录

1. [交接对象与目标](#1-交接对象与目标)
2. [新成员阅读路径](#2-新成员阅读路径)
3. [P3 流程全景](#3-p3-流程全景)
4. [P3 已实现清单](#4-p3-已实现清单)
5. [P3 未实现与 P4 接口](#5-p3-未实现与-p4-接口)
6. [接口契约速查](#6-接口契约速查)
7. [安全边界](#7-安全边界)
8. [升级与回滚](#8-升级与回滚)
9. [验收标准对照](#9-验收标准对照)

---

## 1. 交接对象与目标

- **给谁**：P4 代码组（Dependency/Condition 特性）、维护者、评审者、新加入的 Agent。
- **目标**：
  1. 新成员**只读文档**即可理解「配置 → 权威存储 → Registry 调度 → IPC 控制面 →
     WebUI 数据面/Editor/控制」的完整链路；
  2. 明确 P3 **已实现**、**未实现**、**P4 接口预留点**三者边界（不模糊）；
  3. 明确升级（发布采用）与回滚（回到 v1.6.8）路径（见 `P3-UPGRADE-ROLLBACK.md`）；
  4. 明确 P3 的安全边界（WebUI 无直执 Root、IPC 受控、配置原子回滚）如何在 P4 延续。

## 2. 新成员阅读路径

按序阅读（每份 10–30 分钟；先总览后细节）：

```
1. AGENTS.md / 阶段计划（P3-01..P3-10 任务目标）
2. docs/P3-ARCHITECTURE-DECISIONS.md      ← P3 架构决策 D1–D6 + 风险 R1–R7
3. docs/architecture/config-authority.md   ← 配置权威（legacy/managed 双模式，P3-02）
4. docs/architecture/task-config-store.md  ← Task v2 持久化格式（P3-02）
5. docs/architecture/registry-scheduling.md← Registry 正式调度（P3-03）
6. docs/architecture/ipc-protocol.md       ← IPC 协议 ADR D1–D12（P3-04）
7. docs/P3-05-WEBUI-DATA.md                ← WebUI 只读数据契约（P3-05）
8. docs/architecture/task-editor-schema.md ← Task Editor 表单 schema（P3-06）
9. docs/P3-DEVICE-MATRIX.md                ← 设备矩阵 + D-IPC 缺陷记录（P3-09/P3-10）
10. docs/P3-EXIT-REPORT.md                 ← 出口评审与覆盖矩阵（P3-10）
11. docs/P3-HANDOVER.md（本文档，快速总览）
12. docs/P4-DEPENDENCY-REQUIREMENTS.md      ← P4 Dependency 需求输入（P3-10）
```

> 每份文档头部均有「任务/依赖/接线边界」注记块。

## 3. P3 流程全景

```
   旧 config.txt（legacy 模式，只读兼容）        Task v2 task-config（managed 模式）
          │  legacy_adapter（行号保留）                    │ tcfg_*（原子 tmp+mv）
          ▼                                             ▼
        ┌────────────────────────────────────────────────────────┐
        │           Canonical Task 权威存储（P3-02 §19）         │
        │   legacy/managed 双模式；import=备份+staging+提升；    │
        │   rollback 逐字节还原；export 兼容导出                │
        └───────────────────────────┬────────────────────────────┘
                                    │ Registry 快照
                                    ▼
        ┌────────────────────────────────────────────────────────┐
        │   Registry 正式调度（P3-03 §20）                        │
        │   sched_reload（原子源重载+指纹去重）                   │
        │   scheduler_tick（TriggerProvider→ActionProvider 决策）│
        │   scheduler_boot（boot 任务）；scheduler/audit.log      │
        └───────────────────────────┬────────────────────────────┘
                                    │ action_run（统一执行入口）
                                    ▼
        ┌────────────────────────────────────────────────────────┐
        │   本地 IPC 受控边界（P3-04 §21）                        │
        │   请求/响应文件通道 + IPC_WHITELIST + base64 +          │
        │   原子响应 + 6 类错误码；写操作仅 Managed 模式          │
        └───────────────┬────────────────────┬───────────────────┘
                        │ read ops           │ write/control ops
                        ▼                    ▼
        ┌────────────────────────┐  ┌──────────────────────────┐
        │ WebUI 只读数据面(P3-05) │  │ Task Editor(P3-06)       │
        │ GET_SUMMARY/DETAIL/    │  │ EDIT_TASK/GET_TASK_EDIT/  │
        │ EVENTS/DAEMON_LOG      │  │ VALIDATE_TASK（原子保存/  │
        │ 统一 JSON，无 Root 直执 │  │ 回滚）                    │
        └────────────────────────┘  └──────────────┬───────────┘
                                                  │ tctl_*（统一控制 API P3-07）
                                                  ▼
        ┌────────────────────────────────────────────────────────┐
        │   Task 控制操作（P3-07 §24）                           │
        │   start/stop/restart/check/enable/disable + TSM 强制  │
        └────────────────────────────────────────────────────────┘
```

- **主路径**：`config.txt`（legacy）或 `.task`（managed）→ 权威存储 → Registry →
  调度决策 → `action_run` 执行；控制/查询经 IPC → daemon `tcfg_`/`tctl_` 白名单路径。
- **只读数据面**：WebUI 只读消费 `state.txt`/`events.log`/Registry 快照/旧工件，不重扫
  配置、不产生副作用、不直执 Root。

## 4. P3 已实现清单

| P3 任务 | 交付（生产面 + 测试域 + 文档） | 验证（回归断言） |
| :-- | :-- | :-- |
| P3-02 Canonical 配置存储/迁移 | `§19 tcfg_*` + `task-config` CLI | `tests/config-v2` 44 + validation 40 |
| P3-03 Registry 正式调度 | `§20 sched_*` + daemon 接线 + 审计 | `tests/scheduler-prod` 33 |
| P3-04 本地 IPC 控制面 | `§21 ipc_*` + daemon poll + CLI ipc | `tests/ipc` 64 + security 17 |
| P3-05 WebUI 只读数据面 | `§22` Reader + `webroot/` Dashboard/List/Detail/Logs | `tests/webui/read-only` 24 + security 15 |
| P3-06 WebUI Task Editor | `§23 tcfg_editor_*` + `webroot/` Editor + 原子保存/回滚 | `tests/webui/editor` 28 |
| P3-07 Task 控制操作 | `§24 tctl_*` 统一 API + CLI 子命令 | `tests/task-control` 45 |
| P3-08 安全与资源加固 | `§25 secv_*/tpr_*`（权限/路径/频率/资源上限） | `tests/security` fuzz 19 + path 9 + perm 5 + `tests/resource/stress` 10 |
| P3-09 设备矩阵与综合回归 | `tests/p3-device/smoke.sh` + `tests/p3-integration/test.sh` | 真机 25 PASS / 0 FAIL / 3 BLOCKED；p3-integration 48 |
| **P3-10 出口 + D-IPC 修复** | 出口三文档 + P4 输入 + 发布候选 zip + `cut` 切分修复 | 全量 **ALL SUITES GREEN**；D-IPC 回归 4 断言 |

- **全部 P3 生产改动均在 `system/bin/su-scheduler-runtime`（新增 §19–25）+ daemon/CLI
  兼容接线 + `webroot/` + `build.sh`/`customize.sh` 纳入 webroot 打包**；`service.sh`
  零改动（C5）。

## 5. P3 未实现与 P4 接口

> **硬性声明（验收）**：以下各项在 P3 **未实现**，任何文档不得把它们表述为已完成；
> P3 只提供**接口预留点**。

| 未实现项 | P3 预留点 | P4 实现入口 |
| :-- | :-- | :-- |
| **Dependency（任务依赖/条件触发）** | 状态机 **WAITING reserved 边**（`PENDING>WAITING`/`WAITING>STARTING`/`WAITING>FAILED` 等，`task-state-machine.md` §2/§4）；schema 预留 `dependency=` 字段（`task-info` 输出空字段）；Editor 表单预留位置 | `docs/P4-DEPENDENCY-REQUIREMENTS.md`（P3-10 交付）；接线 WAITING 门控：扩展 trigger 决策层，依赖满足才放行 |
| **Condition（执行条件表达式）** | schema 预留 `condition=` 字段（输出空字段） | 与 Dependency 一并设计（P4 需求文档） |
| **任务 DAG / 拓扑调度** | 无实现、无占位 | 禁止提前实现（P4 规划） |
| **高级事件链 / 云端同步 / 多设备** | 无实现 | 禁止提前实现 |
| **新 Trigger 家族**（cron/interval/oneshot/boot_completed/delay） | Editor 表单 Trigger 未实现项 disabled | 未列入 P3；P4 候选（非 Dependency 范围） |

- **P3 不做**：不实现 Dependency/Condition/DAG；不改 `config.txt` 格式（C4）；不删除
  旧解析/执行路径（C2）；`service.sh` 看护原样（C5）。

## 6. 接口契约速查

```sh
# 配置权威（P3-02 §19）
tcfg_import <legacy_cfg>          # 备份+staging+幂等提升+MANAGED 标记
tcfg_rollback <legacy_cfg>        # 逐字节还原回 legacy + 移除 MANAGED
tcfg_export <out>                 # 兼容导出
tcfg_apply_task <id> <payload>    # 原子应用（tmp+mv，payload id 一致性）
tcfg_validate_task <payload>      # 后端权威校验
# CLI: su-scheduler task-config status|import|export|rollback|list|show|set|new|rm

# Registry 调度（P3-03 §20）
sched_reload <base> <cfg>; scheduler_tick <base> <cfg> <tasks>
scheduler_boot <base> <cfg> <tasks>; sched_remove_task; sched_prune_ron

# IPC（P3-04 §21）
ipc_server_init <base>; ipc_server_poll <base> <cfg> <tasks>
ipc_client_send <req_line>        # REQ_ID|OP|k=b64&…
# op 白名单（19）：GET_SUMMARY/GET_TASK_DETAIL/GET_TASK_EVENTS/GET_DAEMON_LOG/
#   GET_TASKS/GET_TASK_STATUS/GET_TASK_LOG/GET_TASK_EDIT/EDIT_TASK/VALIDATE_TASK/
#   CREATE/UPDATE/DELETE/ENABLE/DISABLE/START/STOP/RESTART/CHECK_TASK

# WebUI 只读数据面（P3-05 §22）
# CLI Reader: su-scheduler webui GET_SUMMARY|GET_TASK_DETAIL|GET_TASK_EVENTS|GET_DAEMON_LOG

# Task 控制（P3-07 §24，统一 API）
tctl_start|stop|restart|check|enable|disable <base> <tasks> <qid>

# 安全（P3-08 §25）
secv_id_ok <id>; secv_fix_perms <path>; secv_num_clamp <val> <min> <max> <def>
```

## 7. 安全边界（P4 必须延续）

1. **WebUI 永不直接执行 Root**：所有写操作经 IPC op → daemon 白名单（`tcfg_`/`tctl_`）
   路径；`webroot/` 无任何 `su -c`/exec/spawn（`tests/webui/security` 断言）。
2. **IPC 受控**：`REQ_ID|OP|PARAMS` 固定格式 + 白名单 + base64 值（Shell 元字符不进执行
   路径）+ 键白名单 + `REQ≤4096` + 原子响应 + 6 类错误码；写操作仅 Managed 模式。
3. **配置原子性与回滚**：全部写 tmp+mv；失败/非法保留旧配置逐字节不变；`tcfg_rollback`
   还原。
4. **P3-10 D-IPC 修复**：`|` 字段切分改用可移植 `cut`（mksh 兼容），P4 新增 `|` 分隔
   协议时**不得**使用 `${var#*|}`/`${var%%|*}` 模式展开。

## 8. 升级与回滚

- 完整命令级手册见 **`docs/P3-UPGRADE-ROLLBACK.md`**。
- 升级 = 安装发布候选 zip（`ksud module install` / Magisk / APatch）；回滚 = 卸载模块
  或重装旧版；数据保险库（`/data/adb/su-scheduler` 与 `/sdcard/Documents/su-scheduler/`
  `config.txt`）在卸载时保留，升级无迁移负担（兼容旧配置与旧 CLI）。

## 9. 验收标准对照

| 验收标准 | 落实 |
| :-- | :-- |
| 新成员只读文档即可理解 P3 流程 | §2 阅读路径 + §3 流程全景 + 各架构文档 |
| 明确 P3 已实现/未实现/P4 接口 | §4 已实现 / §5 未实现与 P4 接口 |
| 不把 Dependency/Condition/DAG 宣称为已完成 | §5 硬性声明 + `P3-EXIT-REPORT.md` §3.8 + `P4-DEPENDENCY-REQUIREMENTS.md` |
| 交接 P4 输入 | `docs/P4-DEPENDENCY-REQUIREMENTS.md`（P3-10 交付） |
| 发布候选包 | `su-scheduler-v1.6.8.zip`（通过 `unzip -t`） |