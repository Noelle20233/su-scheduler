# Su Scheduler — 兼容层架构（P1-13）

> **任务**：P1-13 · 补充架构、升级与回滚文档（本文档为「compatibility-layer.md」交付物）
> **依赖**：P1-01（基线）、P1-02~P1-12（全部实现层）
> **性质**：**兼容策略的规范说明**——P1 阶段所有新层如何与现有 daemon / CLI /
> 配置文件 / `service.sh` **共存而不破坏**（对应 P1 全局约束 C1-C5 的落地声明）。
> **日期**：2026-09-01

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [兼容承诺（对应全局约束）](#2-兼容承诺对应全局约束)
3. [层清单与兼容角色](#3-层清单与兼容角色)
4. [新旧工件/概念对照](#4-新旧工件概念对照)
5. [读写边界（新旧不互覆盖）](#5-读写边界新旧不互覆盖)
6. [接线边界（生产文件零改动）](#6-接线边界生产文件零改动)
7. [兼容性验证（回归证据）](#7-兼容性验证回归证据)
8. [非目标与不兼容边界](#8-非目标与不兼容边界)

---

## 1. 目的与范围

- **背景**：Su Scheduler v1.6.8 是纯 POSIX shell 的 Android systemless 模块，
  运行期只有 `daemon + CLI + service.sh` 三件套，配置是 `/sdcard/Documents/
  su-scheduler/config.txt` 的 legacy 行格式。P1 阶段在其上叠加了
  「内部模型 → Registry → 决策 → 执行 → 运行时状态 → 生命周期 → 只读 CLI」
  的**平行层**。
- **兼容层** = 让这些平行层与旧世界共存的**策略总和**：
  旧格式不被重写、旧路径不被删除、新层只以**只读/新增**方式附着。
- **本文档**给维护者与后续代码组一个明确答案：「P1 到底改了什么、没改什么、
  新层从哪里接、旧的东西还怎么用」。

## 2. 兼容承诺（对应全局约束）

| 承诺 | 对应约束 | P1 落地 |
| :--- | :--- | :--- |
| 不重写整个 su-scheduler | C1 | 全部 P1 交付在 `tests/`（测试域）+ `docs/`；生产 `system/bin/*`、`service.sh`、`customize.sh`、`build.sh`、`module.prop`、`update.json` **零改动**（P1-01~P1-12 提交均不含生产文件修改；`docs/phase-1-baseline.md` §1 行尾事实注明 `core.autocrlf` 检出环境差异，非内容改动） |
| 不删除旧配置解析与执行路径 | C2 | `su-schedulerd` 的 boot 解析、主循环时间匹配、heredoc 重组、`parse_modifiers`/`extract_command`/`execute_task`（SYSTEM/TERMUX/INTERACTIVE）**原样保留**（P1-01 锁定的 golden 语义由 `tests/fixtures/legacy/` 与 P1 回归冻结）；新层只做「投影副本」 |
| 不引入非 Android 标准外部依赖 | C3 | 所有新层 = POSIX sh（sh/sed/grep/awk/date/cut/printf/mv/ls/cat/sleep）；无 jq/Python/Node/busybox 专有硬依赖；测试用 bash/sh/coreutils/Git-Bash 自带工具 |
| 不改变已有配置文件格式 | C4 | `config.txt` 行格式 `<trigger> <command>[;] : <modifier>` 与全部触发/modifier 语义由 P1-01 锁定、P1-05 adapter 镜像解析；**没有任何 P1 层写回或重排 config.txt** |
| 不提前实现 WebUI/Watchdog/Dependency | C5（P0）| P1 同样**不实现**：详细声明见 §8 与 `docs/P1-HANDOVER.md` |
| 每个任务有可验证验收 | C6 | 每层配套 `tests/<layer>/test.sh`（[PASS]/[FAIL] 计数）；P1-12 将 13 项覆盖清单装订为 `tests/run_p1.sh`（11 套全绿） |

## 3. 层清单与兼容角色

| 层 | 位置 | 兼容角色（相对旧世界） |
| :--- | :--- | :--- |
| P1-01 基线 | `docs/phase-1-baseline.md`、`tests/fixtures/legacy/` | 冻结旧行为 = 兼容基准（golden） |
| P1-02 Task Schema v2 | `docs/architecture/task-schema-v2.md`、`tests/fixtures/task-v2/` | 内部模型：旧配置行的**投影**（不取代 config） |
| P1-03 状态机 | `tests/state-machine/` | 新状态集合；legacy `status.txt` → v2 的映射函数（`task_state_from_legacy`），旧状态不删 |
| P1-04 Provider 契约 | `tests/providers/` | 新执行/触发接口；legacy 命令经 `CommandActionProvider` 适配（不改 daemon 调用方式） |
| P1-05 Legacy Adapter | `tests/legacy-adapter/` | **兼容转换层核心**：`config.txt` → 内部 Task v2（行号/source 保留，命令文本原样） |
| P1-06 Task Registry | `tests/task-registry/` | 新任务单一来源（快照）；`config.txt` 只由 reload 内部读取，绝不出现第二套解析 |
| P1-07 Trigger 决策 | `tests/scheduling/trigger-decision/` | 旧触发语义（boot/时间/advanced）经 TriggerProvider 判断；只判不改、只读状态文件 |
| P1-08 Action 执行 | `tests/execution/action-run/` | 旧命令/脚本/Termux/Interactive 执行语义镜像到 ActionProvider；不做 App/Process/Service Action |
| P1-09 运行时状态/事件 | `tests/runtime/` | 新增 `state.txt`/`events.log`；旧工件只读（`status.txt`/`pid.txt`/`output.log` 等不被改写） |
| P1-10 生命周期 | `tests/lifecycle/` | 单实例锁/stale PID/僵尸清理/最后有效快照/看护单轮——镜像 daemon 自保能力，不删除原能力 |
| P1-11 只读 CLI | `tests/task-cli/` | `task list`/`task status` 只读；不定义/不覆盖旧 CLI 命令名，生产 CLI 零改动 |
| P1-12 回归 | `tests/run_p1.sh` 等 | 13 项覆盖清单装订；构建校验与设备冒烟脚本 |

> **兼容层不存在的例外**：没有「拦截旧 daemon 调用的 shim」。P1 层是**旁路
> （sidecar）投影**：daemon 跑旧逻辑，新层在旁边观察/镜像供验证与下一阶段
> 接线。这是 C2 的最强保证——旧路径物理上未被触碰。

## 4. 新旧工件/概念对照

| 旧（v1.6.8 基线） | 新（P1 层） | 关系 |
| :--- | :--- | :--- |
| `config.txt` 行 | 内部 Task v2（`<id>.task`） | adapter 投影；行号/source 保留（P1-05） |
| `status.txt`（RUNNING/SUCCESS/FAILED/ZOMBIE_CRASHED） | `state.txt`（P1-03 11 态）+ `events.log` | 新源独立文件；`task_state_from_legacy` 映射；**互不覆盖**（P1-09） |
| 任务工件 `pid.txt`/`output.log`/`exit_code.txt`/`end_time.txt`/`start_time.txt` | 同（P1-08 ActionProvider 产出） | 同名同语义；新层不写旧义之外的改造 |
| daemon 锁 `/dev/.su_scheduler.lock` | `lifecycle_lock_*`（P1-10） | 镜像；参数注入，不硬编码路径 |
| daemon 每轮扫配置 | Registry 快照（P1-06） | 新"单一调度入口"为下一阶段接线蓝图；daemon 主循环未改 |
| `su-scheduler` CLI（list/status/tasks/task-info/...） | `task_cli_list`/`task_cli_status`（P1-11） | 只读新命令语义；旧命令零覆盖 |
| `execute_task`（SYSTEM/TERMUX/INTERACTIVE） | `tpr_action_exec_smart/termux/interactive`（P1-08） | 语义镜像（含 interactive 保真怪癖） |

## 5. 读写边界（新旧不互覆盖）

```
              旧世界（生产，只读不写）          新世界（tests/，写入自己的文件）
config.txt  ────────────── 只读 ───────────────► adapter 读
status.txt  ◄────────────────────────────────   lifecycle 启动清理写（镜像 daemon 僵尸标记）
tasks/<id>/ pid.txt/output.log/... ◄──────────── action-run 写（同语义）
state.txt / events.log（新文件） ◄─────────────  runtime 写（P1-09）
```

- **旧工件**：P1-09/10/11 层对 `status.txt`/`pid.txt`/`output.log` 等**只读或
  按旧语义同写**（lifecycle 僵尸清理写 `ZOMBIE_CRASHED` = 镜像 daemon 既有
  行为，P1-10 §5）；`state.txt`/`events.log` 是**新增文件**，不与旧文件同名，
  因此新旧状态**不会互相覆盖**（P1-09 验收 2、P1-13 承诺）。
- **配置**：没有任何 P1 层写回 `config.txt`（修剪/删除是 daemon 旧路径自身
  行为，P1-01 §5.7/5.8 基线记录）。

## 6. 接线边界（生产文件零改动）

- P1 全部实现位于测试域（`tests/`）+ 文档（`docs/`）；**生产接线是明确非目标**
  （P1-07/08/10 文档的「接线边界」节）。
- 接线下一步（P2 候选）：把 `provider_dispatch` 接到 daemon 主循环、把
  `lifecycle_start` 嵌入 daemon 启动序列、把 `task_cli_*` 挂到 CLI `task`
  子命令、把 `compatibility-layer` 从「旁路投影」转为「显式适配」。
- **为什么安全**：因为 P1 层与生产零耦合（无 shim、无钩子、无同名覆盖），
  接线是纯新增调用点，可逐任务接入并独立回归（P1-12 已为此备好回归）。

## 7. 兼容性验证（回归证据）

| 证据 | 位置 | 结论 |
| :--- | :--- | :--- |
| legacy 解析 golden 冻结 | `tests/fixtures/legacy/`（P1-01） | 旧解析语义逐字节锁定 |
| 13 项覆盖矩阵全绿 | `tests/run_p1.sh`（P1-12） | 11 套 0 FAIL（见 `docs/architecture/p1-regression.md`） |
| 「不重新解析第二套任务」 | `tests/task-cli/test.sh`（P1-11 结构断言） | CLI 只读 Registry |
| 「新旧不互覆盖」 | `tests/runtime/test.sh`、`tests/lifecycle/test.sh` | 旧工件全程未变断言 |
| 「生产零改动」 | P1-01~P1-12 提交历史 | 提交均只含 `tests/`、`docs/`（README 追加除外）；`git show` 可核 |

## 8. 非目标与不兼容边界

- **P1 未实现（不宣称为已完成）**：
  - **Watchdog（增强）**：`service.sh` 既有 60s 看护循环之外的新看护/自愈机制——
    P1-10 只提供**单轮** `lifecycle_watchdog_tick` 原语与镜像，不实现增强循环；
  - **WebUI**：无任何实现/占位；`task list/status` 是 CLI 只读，非网页界面；
  - **Dependency（任务依赖/条件触发）**：状态机仅**预留** `WAITING`/`PENDING>WAITING`
    边（P1-03 §非目标），无接线实现；
  - **App/Process/Service Action**：Provider 契约预留（P1-04 §10 模板），未实现；
  - **Health/Recovery 真实探测**：`health>builtin`/`recovery>builtin` 为空实现 stub。
- **不兼容边界**（文档明确，不模糊）：上述各项在「下一阶段接口」清单中，任何
  阅读者不得据本文档宣称它们已完成（验收 3）。