# Su Scheduler — P2 出口评审报告（P2-EXIT-REPORT）

> **阶段**：P2（生产化）综合回归与发布评审
> **版本**：runtime lib `v1.12.0`（模块 module.prop `v1.6.8`，versionCode 11608）
> **日期**：2026-09-02
> **范围**：P2-15 出口评审——对 P2-01 ~ P2-14 全部生产化成果做一次**综合回归**，
> 逐项核对 P2-15 覆盖清单，产出本报告，作为「进入 WebUI / Dependency 规划」的前置门禁。
> **入口**：`bash tests/run_tests.sh`（L1 + L2 + L4；L3 设备冒烟为可选项，见 §5）。

---

## 0. 结论（TL;DR）

**P2 生产化阶段"通过发布评审"，可进入 WebUI / Dependency 规划。**

- 全量主机回归 **ALL SUITES GREEN**，`exit 0`，**0 FAIL**。
- P2-15 覆盖清单九项逐项核验：**旧配置兼容 / 旧 CLI 兼容 / 新 Task CLI / App Action /
  Process-Port Health / Restart-Retry-Cooldown / daemon kill-task kill-脚本 hang-应用崩溃-重启 /
  三管理器安装** 均有**具名主机套件**覆盖且全绿（§4 覆盖矩阵）；**Android 12–16 设备矩阵**
  属 L3 真机验证，本环境无 adb 设备，登记为**发布前唯一待办缺口**（§5），CI/真机接线任务
  已列入后续规划（§8）。
- 无已知阻断性缺陷。

---

## 1. 评审对象（P2 生产化成果盘点）

| 编号 | 生产模块 | 引入 | 关键构建物 |
| :-- | :-- | :-- | :-- |
| P2-01 | 统一回归入口 + CLI/daemon 基线修复 | lib 前置 | `tests/run_tests.sh`、Q1–Q13 终态 |
| P2-02 | 生产 Runtime 库 | lib v1.0.0 | `system/bin/su-scheduler-runtime`（§1–7 生产化原语）|
| P2-03 | Registry Shadow Mode | lib v1.1.0 | `shadow_init`、快照/KEPT 语义 |
| P2-04 | Canonical↔Legacy Run ID | lib v1.2.0 | `runtime_map_*`，零旧路径改动 |
| P2-05 | TriggerProvider | lib v1.3.0 | `trigger_decide` 单一入口 |
| P2-06 | CommandActionProvider | lib v1.4.0 | `action_run` 唯一执行入口 |
| P2-07 | 统一状态与事件日志 | lib v1.5.0 | `state_log_event`、state/events 双写、对账/再水合 |
| P2-08 | 生产 Task CLI | lib v1.6.0 | `task list|status`（registry 只读挂载）|
| P2-09 | daemon 生命周期 | lib v1.7.0 | `lifecycle_startup_*`、最后有效快照 |
| P2-10 | App Action | lib v1.8.0 | `action_run app`，am 固定模板 argv |
| P2-11 | Process/Port Health | lib v1.9.0 | `health_check` 统一三态 |
| P2-12 | Supervisor 核心 | lib v1.10.0 | `supervisor_tick/step` 统一事件循环 |
| P2-13 | Recovery/Retry/Cooldown | lib v1.11.0 | `supervisor_recover`、策略钳制 |
| P2-14 | Crash Loop 与资源保护 | lib v1.12.0 | `crash_guard_*`、`runtime_protect*`、健康间隔/超时护栏 |

生产源码：`system/bin/su-scheduler-runtime`（唯一生产 runtime lib）、
`system/bin/su-schedulerd`（守护）、`system/bin/su-scheduler`（CLI）。

---

## 2. 回归门禁与方法

- **唯一入口**：`bash tests/run_tests.sh`（L1 静态语法 + L2 行为 + L4 构建/版本一致性；
  L3 设备可选）。
- **判定**：输出不得出现 `[FAIL]`；全部通过 → `exit 0`。
- **可追溯**：每次运行完整逐层输出落盘 `tests/results/run_tests-<时间戳>.log`（`.gitignore`
  忽略，不污染工作树）。
- **本次新增（P2-15）两个套件**：
  - `tests/p2-integration/test.sh` —— 故障注入与重启的**端到端综合回归**（见 §3.2）；
  - `tests/p2-install/test.sh` —— 三管理器安装结构与发布契约校验（见 §3.9）。
  - 二者均已注册进 `run_tests.sh` 头部注释与 for 循环，并写入 README 回归表。

---

## 3. P2-15 覆盖清单 → 具名套件映射（逐项核验）

> 每个条目给出「覆盖的既有套件」与「P2-15 新增/集成验证」。

### 3.1 旧配置兼容
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| 既有 config.txt 行格式（triggers + `; : modifiers`） | `tests/legacy/golden.sh`（逐字节 golden 锁定） | ✅ |
| `--delete` 删除管线（Q13 单激活行短路） | `tests/legacy/delete-pipeline.sh` | ✅ |
| CLI add 写回格式与 daemon 解析不变（C4） | `tests/cli/test.sh`、`tests/legacy/golden.sh` | ✅ |
| P2-14 等新逻辑仅叠加、不断旧路径（C2） | 全量回归红线守护（legacy/cli 套件不回退） | ✅ |

### 3.2 旧 CLI 兼容
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| 旧命令（add/list/remove/edit/log/tasks/task-info/task-output/status/restart/stop/test/audit）零改动 | `tests/cli/test.sh`、`tests/legacy-adapter/test.sh` | ✅ |
| 旧运行 ID / status.txt 只读不动（P2-04/07 边界） | `tests/task-cli/test.sh`、`tests/idmap/test.sh` | ✅ |
| `log -n`/`add` 触发器集/`list` 空态/`task-output` 去重（Q1–Q4） | `tests/cli/test.sh` | ✅ |

### 3.3 新 Task CLI
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| `task list` / `task status`（registry 只读挂载，不重扫配置） | `tests/task-cli-prod/test.sh` | ✅ |
| 稳定 Task ID + 旧运行 ID 双向解析 | `tests/task-cli-prod/test.sh`、`tests/idmap/test.sh` | ✅ |
| 三态错误区分（rc1 not found / rc2 配置无效 / rc3 daemon 未运行） | `tests/task-cli-prod/test.sh` | ✅ |

### 3.4 App Action
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| `app:op:target[:extras]` 结构化 spec（package/activity/broadcast/service） | `tests/app-action/test.sh` | ✅ |
| 全参数校验拒绝注入 + 固定 am 模板 argv | `tests/app-action/test.sh`（mock am 逐 argv + 注入零调用断言） | ✅ |
| `action_run app` 先于 execute_task 委托 | `tests/app-action/test.sh`、`tests/action/test.sh` | ✅ |

### 3.5 Process / Port Health
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| Process Check / Port Check（/proc 进程 / /proc/net/tcp LISTEN） | `tests/health/test.sh` | ✅ |
| 统一三态 HEALTHY/UNHEALTHY/UNKNOWN + reason/latency/target | `tests/health/test.sh` | ✅ |
| 真实监听起停验证 | `tests/health/test.sh` | ✅ |

### 3.6 Restart / Retry / Cooldown
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| 恢复动作 recovery.type=restart/stopstart/start/script | `tests/recovery/test.sh` | ✅ |
| retry.max 钳制禁止无限重启（非负 + 硬上限 100） | `tests/recovery/test.sh` | ✅ |
| retry.interval 节奏 + 基础 cooldown（FAILED 后冷却） | `tests/recovery/test.sh`、`tests/supervisor/test.sh` | ✅ |
| 完整生命周期 RUNNING→HEALTHY→UNHEALTHY→RECOVERING→STARTING\|FAILED | `tests/supervisor/test.sh` | ✅ |

### 3.7 daemon kill / task kill / 脚本 hang / 应用崩溃 / 重启
| 场景 | 覆盖 | 结果 |
| :-- | :-- | :-- |
| **daemon kill**（SIGKILL 崩溃 → 降级抑制；优雅 TERM → last_clean=1 不误判） | `tests/crashguard` §2/11、`tests/p2-integration` §2 | ✅ |
| **task kill**（被监督任务 `kill -9` → 探针 UNHEALTHY → RECOVERING → 重跑 → HEALTHY） | `tests/p2-integration` §3（新增端到端） | ✅ |
| **脚本 hang**（超 TASK_RUNTIME_MAX → FAILED 终止进程 + 事件） | `tests/crashguard` §10、`tests/p2-integration` §4（新增端到端） | ✅ |
| **应用崩溃**（监听进程多次死亡 → 每次重跑自愈恢复 HEALTHY） | `tests/p2-integration` §5（新增，2 轮崩溃-恢复循环） | ✅ |
| **重启**（daemon 重启残留 RUNNING→FAILED + daemon_restart；优雅停不遗留幽灵态） | `tests/p2-integration` §6、`tests/lifecyle-prod`、`tests/state` | ✅ |

> **P2-15 的关键新增**：§3.7 的 5 类故障此前分散在 crashguard/recovery/supervisor/lifecycle
> 等套件孤立覆盖，但**没有一条把它们串成端到端综合回归**。P2-15 新增
> `tests/p2-integration` 用真实 `nc` 监听 + 真实 fake-daemon 进程，在**同一套件内**把
> daemon kill、task kill、脚本 hang、应用崩溃、重启收敛为一个综合故障→自愈闭环门禁。

### 3.8 KernelSU / Magisk / APatch 基础安装验证
| 方面 | 覆盖套件 | 结果 |
| :-- | :-- | :-- |
| 发布 zip 构建 + 完整性 + 内容成员 | `tests/p1-build/build_check.sh`（L4） | ✅（CI/LF 承担构建执行） |
| 三管理器共享 systemless 模块契约（module.prop/customize.sh/service.sh/system 覆盖、数据独立模块目录、manager-agnostic 安装路径、`$MODPATH`） | **`tests/p2-install/test.sh`（P2-15 新增）** | ✅ |
| 真机安装冒烟 | `tests/p1-device/smoke.sh`（L3，可选） | ⏳ 待真机（§5） |

### 3.9 Android 12–16 设备矩阵
| 方面 | 覆盖 | 结果 |
| :-- | :-- | :-- |
| 宿主内核无关能力（调度/状态/健康/恢复/故障自愈/安装结构/旧兼容） | 全量 L1+L2+L4 主机套件 | ✅ |
| 真实 KernelSU 设备上的 10 项冒烟（含 boot/time/run-once-now/delete/task-info/termux/配置自愈） | `tests/p1-device/smoke.sh` | ⏳ 待真机（§5） |
| Android 12 / 13 / 14 / 15 / 16 系统版本矩阵 | 无本环境设备 | ⏳ **登记为发布前缺口**（§5） |

---

## 4. 本次回归执行结果

**命令**：`bash tests/run_tests.sh`（CRLF 检出环境；L1+L2+L4）

```
ALL SUITES GREEN (L1+L2+L4 host regression; device optional: see p1-device)
exit 0
```

逐层汇总（P2-15 新增套件以 `(+)` 标注）：

| 套件 | PASS | FAIL | SKIP |
| :-- | :-- | :-- | :-- |
| lint (L1) | 8 | 0 | 0 |
| legacy/golden | 8 | 0 | 0 |
| legacy/delete-pipeline | 4 | 0 | 0 |
| cli | 24 | 0 | 0 |
| state-machine | 183 | 0 | 0 |
| providers | 136 | 0 | 0 |
| legacy-adapter | 107 | 0 | 0 |
| task-registry | 44 | 0 | 0 |
| trigger-decision | 39 | 0 | 0 |
| action-run | 24 | 0 | 0 |
| runtime | 45 | 0 | 0 |
| lifecycle | 56 | 0 | 0 |
| task-cli | 39 | 0 | 0 |
| runtime-lib | 20 | 0 | 0 |
| shadow | 23 | 0 | 0 |
| idmap | 25 | 0 | 0 |
| trigger | 21 | 0 | 0 |
| action | 33 | 0 | 0 |
| state | 35 | 0 | 0 |
| task-cli-prod | 33 | 0 | 0 |
| lifecycle-prod | 27 | 0 | 0 |
| app-action | 54 | 0 | 0 |
| health | 55 | 0 | 0 |
| supervisor | 18 | 0 | 0 |
| recovery | 25 | 0 | 0 |
| crashguard | 41 | 0 | 0 |
| **p2-integration `(+)`** | **22** | **0** | 0 |
| **p2-install `(+)`** | **11** | **0** | 1 (CRLF 下构建执行跳过；源树契约已断) |
| p1-regression | 44 | 0 | 0 |
| p1-build (L4) | 11 | 0 | 4 (CRLF 下构建执行跳过；CI/LF 承担) |
| **合计** | **1215** | **0** | **5** |

> 相对 P2-14（1182 PASS / 0 FAIL / 4 SKIP）新增：`p2-integration` 22 + `p2-install`
> 11 断言与 1 个 CRLF 下构建 SKIP 口径 → **1215 PASS / 0 FAIL / 5 SKIP**。
> SKIP 均为**明示**的非阻断项（CRLF 检出下的构建执行──等价 P0 L3 `DEVICE_SKIPPED`
> 语义，CI 的 LF 工作树为构建闸）。

**trace**：`tests/results/run_tests-20260901-173643.log`（完整逐层输出落盘）。

---

## 5. 设备矩阵与发布前缺口（L3）

| 缺口 | 状态 | 影响 | 处置 |
| :-- | :-- | :-- | :-- |
| 真实 KernelSU/APatch/Magisk 设备上的安装冒烟 | 未执行（本环境无 adb 设备） | 中：真机 systemless 覆盖/daemon 常驻/开机自启 | 接续「L3 真机接线」任务（§8）；CI 可挂 adb 设备时自动补跑 `p1-device/smoke.sh` |
| Android 12 / 13 / 14 / 15 / 16 系统版本矩阵 | 未执行 | 中：跨版本 `/proc`、`nc`、toybox 命令差异 | 归入 L3 真机矩阵计划（§8），覆盖 5 个 API 级别 |
| `p1-device/smoke.sh` 用例 10（P1 只读 CLI） | SKIP（该模块已由 P2-08 生产接线，非缺陷） | — | P2 阶段以 `task-cli-prod` 覆盖该能力 |

> **判定**：主机侧 L1+L2+L4 门禁**不受设备缺失阻塞**（与 P0 L3 `--skip-device` 语义一致，
> 明示跳过不计失败）。设备矩阵登记为**发布前待办**，属「放行进入规划、但真机验证须在
> 发布前补齐」的受控缺口。

---

## 6. P2 全量覆盖审计（汇总视图）

| P2-15 覆盖项 | 套件(具名) | 状态 |
| :-- | :-- | :-- |
| 旧配置兼容 | legacy/golden、legacy/delete-pipeline、cli | ✅ |
| 旧 CLI 兼容 | cli、legacy-adapter、task-cli、idmap | ✅ |
| 新 Task CLI | task-cli-prod、idmap | ✅ |
| App Action | app-action、action | ✅ |
| Process/Port Health | health | ✅ |
| Restart/Retry/Cooldown | recovery、supervisor | ✅ |
| daemon kill/task kill/脚本 hang/应用崩溃/重启 | p2-integration（+]）、crashguard、lifecycle-prod、state | ✅ |
| KernelSU/Magisk/APatch 安装 | p2-install（+]）、p1-build | ✅（真机 ⏳ §5） |
| Android 12–16 设备矩阵 | p1-device（L3） | ⏳ 待真机（§5） |

---

## 7. C1–C5 约束自查（P2-15 阶段）

| 约束 | 自查 |
| :-- | :-- |
| C1 不整体重写 | P2-15 仅新增测试套件与文档，生产源码零改动 |
| C2 不删旧解析/执行路径 | 全量 legacy/state/lifecycle 套件不回退（回归红线验证） |
| C3 不引入非标准依赖 | 测试仅用 bash/sh/nc/pgrep/kill/sleep/tail/wc/touch/date——与既有套件一致；生产无新依赖 |
| C4 不改配置格式 | config golden 套件全绿，零触碰 |
| C5 不提前实现 Watchdog/WebUI/Dependency | P2-15 不实现、不占位；进入规划仅以本文档为指引（§8） |

---

## 8. 下一步：WebUI / Dependency 规划入口

P2 生产化阶段已通过本评审，进入 **WebUI / Dependency（任务依赖/条件触发）规划**。规划前置（建议立项）：

1. **L3 真机矩阵任务**：kernel/APatch/Magisk 三管理器基础安装 + Android 12–16 五 API 级
   冒烟（`p1-device/smoke.sh` 扩展为矩阵运行）；完成后方可正式发布。
2. **WebUI 规划**：基于 `task list|status`（P2-08）只读数据面 + registry 快照
   （P2-03），评估 Web 端供电协议（读 `state.txt/events.log` + registry……），
   沿用 C5 边界（不改 daemon 常驻循环、不引入前台常驻进程），并评估
   `runtime_protect*`（P2-14）对快照/日志的既有上限约束对 Web 数据钩子的影响。
3. **Dependency 规划**：在 supervisor/recovery（P2-12/13）之上设计任务级依赖/条件
   触发；复用 TSM 迁移校验与 `state_log_event`，评估 `startup`/`boot` 场景的 DAG
   拓扑与失败惩罚（retry.cooldown 复用），避免与 C4 配置格式冲突（需 config 语法
   决策）。
4. 规划期建议代理为派生任务，逐项出 `docs/` 执行记录并沿用 P2 回归门禁。

---

## 附：P2-15 本次改动文件清单

- 新增：`tests/p2-integration/test.sh`（22 断言，端到端故障自愈综合回归）、
  `tests/p2-install/test.sh`（11 断言，三管理器安装结构/发布契约）、
  `docs/P2-EXIT-REPORT.md`（本报告）
- 修改：`tests/run_tests.sh`（注册两套件：头部注释 + for 循环）、`README.md`
  （回归表增 P2-15 两行）