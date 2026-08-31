# Su Scheduler — P1 阶段交接资料（P1-13）

> **任务**：P1-13 · 补充架构、升级与回滚文档
> **依赖**：P1-01 ~ P1-12（本总览覆盖其全部交付）
> **性质**：给后续代码组与维护者的**稳定交接入口**——新成员按 §2 阅读路径可
> 仅凭文档理解 Task 流程（验收 1）；§4/§5 明确 P1 已实现/未实现/下一阶段接口
> （验收 2）；Watchdog、WebUI、Dependency **明确标注未实现**，不宣称为已完成
> （验收 3）。
> **日期**：2026-09-01

---

## 目录

1. [交接对象与目标](#1-交接对象与目标)
2. [新成员阅读路径](#2-新成员阅读路径)
3. [Task 流程全景](#3-task-流程全景)
4. [P1 已实现清单](#4-p1-已实现清单)
5. [P1 未实现与下一阶段接口](#5-p1-未实现与下一阶段接口)
6. [接口契约速查](#6-接口契约速查)
7. [升级说明](#7-升级说明)
8. [回滚说明](#8-回滚说明)
9. [验收标准对照](#9-验收标准对照)

---

## 1. 交接对象与目标

- **给谁**：P2 阶段代码组、维护者、评审者、新加入的 Agent。
- **目标**：
  1. 新成员**只读文档**即可理解「配置 → 内部 Task → 调度决策 → 执行 →
     运行时状态 → 生命周期 → 只读 CLI」的完整流程；
  2. 明确 P1 **已实现**、**未实现**、**下一阶段接口**三者边界（不模糊）；
  3. 明确升级路径（P1 层如何被采用/接线）与回滚路径（回到 v1.6.8 基线）；
  4. 明确哪些能力**不是** P1 完成的（Watchdog 增强 / WebUI / Dependency /
     App-Action / 健康恢复真实探测 / 生产接线）。

## 2. 新成员阅读路径

按序阅读（每份 10–40 分钟；先总览后细节）：

```
1. AGENTS.md / 任务清单（P1-01..P1-13 的逐个任务目标）
2. docs/phase-1-baseline.md            ← 旧行为基线（P1-01）：一切兼容性的基准
3. docs/architecture/task-schema-v2.md ← 内部 Task 模型（P1-02）
4. docs/architecture/task-state-machine.md ← 生命周期状态机（P1-03）
5. docs/architecture/provider-contracts.md ← Provider 契约（P1-04）
6. docs/architecture/task-id-rules.md  ← 稳定 Task ID 规则（P1-05）
7. docs/architecture/task-registry.md  ← Canonical Registry（P1-06）
8. docs/architecture/compatibility-layer.md ← 新旧共存策略（P1-13，本文档第 5/8 节配套）
9. docs/architecture/p1-regression.md  ← P1 回归装订（P1-12）
10. docs/P1-HANDOVER.md（本文档，可作快速总览随时参照）
```

> 每份文档头部均有「任务/依赖/接线边界」注记块；P1-13 在其上补充了
> 「已实现/未实现状态标注」（见 §4/§5）。

## 3. Task 流程全景

```
                       ┌──────────────────────────────────────────┐
                       │ 旧世界（生产，零改动）                    │
                       │ daemon 扫描 config.txt、execute_task、   │
                       │ service.sh 看护锁 —— 全部原样（C2）       │
                       └───────────────┬──────────────────────────┘
                                       │ config.txt（只读）
                                       ▼
   ┌──────────────┐   legacy-adapter   ┌──────────────────────┐
   │ config.txt   │ ──────────────────►│ 内部 Task v2 快照     │
   │ (旧格式不变)  │   (P1-05, 行号保留) │ Registry (P1-06)     │
   └──────────────┘                    └──────────┬───────────┘
                                                  │ registry_task_ids/files
                                                  ▼
   ┌────────────────────┐              ┌──────────────────────┐
   │ trigger_decision    │◄─────────────│ 每轮唯一数据源       │
   │ (P1-07 TriggerProvider)            │ （不重新解析配置）    │
   └───────┬────────────┘               └──────────────────────┘
           │ id=.. cause=..
           ▼
   ┌────────────────────┐   artifacts   ┌──────────────────────┐
   │ action-run         │ ─────────────►│ 任务目录：            │
   │ (P1-08 ActionProvider│             │ status.txt/pid.txt/   │
   │  命令/脚本/Termux/   │              │ output.log/exit_code  │
   │  Interactive)       │              └──────────┬───────────┘
   └────────────────────┘                         │ 观察/镜像
                                                  ▼
   ┌────────────────────┐              ┌──────────────────────┐
   │ runtime (P1-09)    │              │ state.txt + events.log│
   │ lifecycle (P1-10)  │              │ (新增文件，不与旧件互覆盖)│
   │ task-cli (P1-11)   │              └──────────────────────┘
   └────────────────────┘
```

- 主路径：`config.txt` → adapter → Registry 快照 → 决策 → 执行 → 工件 +
  状态/事件；daemon 未接线前，这套是**可独立验证的旁路投影**（P1-12 回归装订）。
- 只读查询：`task_cli_list`/`task_cli_status` 只读 Registry 快照与运行时
  状态文件（P1-11）。

## 4. P1 已实现清单

| P1 任务 | 交付（测试域 + 文档） | 验证（回归断言数） |
| :--- | :--- | :--- |
| P1-01 行为基线 | `docs/phase-1-baseline.md`、`tests/fixtures/legacy/` | golden 派生 + 解析 fixtures |
| P1-02 Task Schema v2 | `docs/architecture/task-schema-v2.md`、`tests/fixtures/task-v2/` | 样例 fixtures（17 任务派生） |
| P1-03 状态机 | `docs/architecture/task-state-machine.md`、`tests/state-machine/` | 183 PASS |
| P1-04 Provider 契约 | `docs/architecture/provider-contracts.md`、`tests/providers/` | 136 PASS（含 P1-08 全模式） |
| P1-05 Legacy Adapter | `tests/legacy-adapter/`、`docs/architecture/task-id-rules.md` | 107 PASS |
| P1-06 Task Registry | `tests/task-registry/`、`docs/architecture/task-registry.md` | 44 PASS |
| P1-07 Trigger 决策 | `tests/scheduling/trigger-decision/` | 39 PASS |
| P1-08 Action 执行 | `tests/execution/action-run/` | 24 PASS |
| P1-09 运行时状态/事件 | `tests/runtime/`、`docs/architecture/runtime-state-events.md` | 45 PASS |
| P1-10 生命周期 | `tests/lifecycle/`、`docs/architecture/lifecycle.md` | 56 PASS |
| P1-11 只读 Task CLI | `tests/task-cli/`、`docs/architecture/task-cli.md` | 39 PASS |
| P1-12 P1 回归 | `tests/run_p1.sh`、`tests/p1-regression/`、`tests/p1-build/`、`tests/p1-device/` | 11 套 0 FAIL（P1-12） |
| P1-13 交接文档 | 本文档 + `compatibility-layer.md` + README 兼容性章节 + 升级/回滚说明 | 文档验收 |

- **全部 P1 提交仅含 `tests/`、`docs/`（README 追加章节除外）——生产
  `system/bin/*`、`service.sh`、`customize.sh`、`build.sh`、`module.prop`、
  `update.json` 零改动**（提交历史可核，`git show --stat`）。

## 5. P1 未实现与下一阶段接口

> **硬性声明（验收 3）**：以下各项在 P1 **未实现**，任何文档不得把它们表述为
> 已完成；P1 只提供**接口预留点**。

| 未实现项 | P1 预留点 | 下一阶段实现入口（P2 候选） |
| :--- | :--- | :--- |
| **Watchdog（增强）** | `lifecycle_watchdog_tick`（单轮镜像，`tests/lifecycle/lib.sh`） | 在 `service.sh` 既有 60s 循环内委托 tick；如需要退避/降级，扩 tick 语义（不建第二个调度循环） |
| **WebUI** | 无实现、无占位目录；`task_cli_*` 只读输出可作为未来展示数据源 | 新层直接读 Registry 快照 + `state.txt`/`events.log` |
| **Dependency（依赖/条件触发）** | 状态机预留 `WAITING` 态与 `PENDING>WAITING` 边（P1-03 §非目标）；schema `dependency=` 字段为空 | 接线 WAITING 门控：扩展 trigger 决策层，依赖满足才放行 |
| **App/Process/Service Action** | Provider 契约 §10 模板（`provider_register action app …` + 前缀函数） | 注册 `action>app` 等 + 分发零改动接入 |
| **Health/Recovery 真实探测** | `health>builtin`/`recovery>builtin` 空实现 stub（P1-04 §9） | 新 `health>probe`、`recovery>restart` Provider + 状态机 reserved 边（RUNNING→HEALTHY 等） |
| **daemon/CLI 生产接线** | 各层文档「接线边界」节；`run_p1.sh` 为接线回归 | 把 `provider_dispatch`/`registry`/`lifecycle`/`task_cli_*` 逐点挂入生产（P2，逐任务独立接入 + 每步回归） |

- **P1 未做**：不实现新的高级触发器；不实现 `--boot`（P0 D1 决策延后）；不改
  `config.txt` 格式（C4）；不删除旧解析/执行路径（C2）。

## 6. 接口契约速查

```sh
# Provider 分发（P1-04；核心唯一执行入口）
provider_dispatch <kind> <name> <cap> [args...]      # kind: trigger|action|health|recovery
provider_register <kind> <name> <prefix>             # 静态注册一行

# Registry（P1-06；配置 → 任务快照唯一来源）
registry_init <base> <config>; registry_reload <config>
registry_task_ids; registry_task_file <id>; registry_manifest

# 运行时状态/事件（P1-09）
runtime_log_event <dir> <id> <event> <state> <pid> <exit_code> <message>
runtime_scan_stale <tasks_dir>; runtime_current_state <dir>

# 生命周期（P1-10）
lifecycle_start <base> <config> <lock>; lifecycle_stop <lock>
lifecycle_restart <lock> <base> <config> <daemon_cmd>
lifecycle_watchdog_tick <lock> [daemon_cmd]

# 只读 CLI（P1-11）
task_cli_list; task_cli_status <id>   # rc: 1 not-found / 2 invalid-config / 3 daemon-down
```

## 7. 升级说明

- **P1 阶段（叠加采用）**：`tests/`、`docs/` 全部为新增；不替换任何旧文件。
  README 的兼容性章节为**追加**（既有章节原样保留）。因此"升级" = 合入 P1
  提交（P1-01..P1-13），无需迁移配置、无需改 daemon。
- **生产接线升级（P2 候选路径）**：在 daemon 启动序列（`su-schedulerd`
  L544-602 区域）插入 `lifecycle_start`（或逐原语替换）；主循环内用
  `trigger_decision_cycle` + `provider_dispatch` 替换/包住当前扫描；CLI 加
  `task` 子命令委托 `task_cli_*`；每步先跑 `tests/run_p1.sh` 全绿再继续。
- **版本一致性**：升级不影响 `module.prop`/`build.sh`/`update.json` 六处版本
  号（`tests/p1-build/build_check.sh` 校验其一致性，P1 期间版本仍 v1.6.8）。

## 8. 回滚说明（回到 v1.6.8 基线）

因为 P1 **从未触碰生产文件**，回滚**零风险**：

1. **代码回滚**：`git revert` P1-01..P1-13 提交（或整组
   `git checkout 3fe7631 -- tests/ docs/ README.md` 后提交）；
2. **残留清理核对**：`tests/`、`docs/`（P1 新增）、README 追加的兼容性章节
   移除后，工作树应与 `3fe7631`（v1.6.8）一致——除 AGENTS.md（如已在工作树，
   属既有未跟踪文件，不受回滚影响）；
3. **生产零影响声明**：`system/bin/*`、`service.sh`、`customize.sh`、
   `build.sh`、`module.prop`、`update.json` 在 P1 期间**从未被修改**，回滚后
   与基线逐字节一致（`git diff 3fe7631 -- system/ service.sh customize.sh
   build.sh module.prop update.json` 应为空）；
4. **运行期状态**：P1 新增的 `state.txt`/`events.log` 只存在于使用了 P1 层/测试
   的目录中；生产 `/data/adb/su-scheduler/` 与 `/sdcard/.../config.txt` 不受
   影响。若有测试遗留文件，按测试清理（各 test.sh 尾部 `rm -rf` 已处理临时
   目录；CI 环境无残留）。
5. **升级-回滚循环**：因新旧零耦合，可重复升级/回滚而不产生迁移负担。

## 9. 验收标准对照

| 验收标准 | 落实 |
| :--- | :--- |
| 新成员只读文档即可理解 Task 流程 | §2 阅读路径 + §3 流程全景 + 各架构文档 |
| 明确 P1 已实现、未实现和下一阶段接口 | §4 已实现清单 / §5 未实现与下一阶段接口表 |
| 不把未实现的 Watchdog、WebUI、Dependency 宣称为已完成 | §5 硬性声明 + `compatibility-layer.md` §8 + P1-03/P1-10 文档原有「非目标」节，均明确标注未实现/预留 |
| 交付物 7 项齐备 | task-schema-v2 / task-state-machine / provider-contracts / compatibility-layer（本文档配套）/ phase-1-baseline 注记、README 兼容性章节、升级回滚说明（§7/§8） |