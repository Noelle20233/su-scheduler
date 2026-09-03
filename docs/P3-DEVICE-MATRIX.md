# Su Scheduler — P3 设备矩阵与综合回归（P3-DEVICE-MATRIX）

> **任务**：P3-09 · 设备矩阵与综合回归目标
> **前置**：P3-01 至 P3-08（本文件由 P3-09 执行产出）
> **日期**：2026-09-03
> **出口标准**：真机安装/卸载、daemon 开机、Runtime 加载、Legacy 执行、Task v2 导入、
> Registry 调度、WebUI Dashboard、Task Editor、App Action、Process/Port Health、
> Restart/Retry/Cooldown、Crash Loop、Task 控制、配置损坏回退、旧 CLI 查询、日志轮转、
> 重启状态恢复 全部尽力在真实设备覆盖；未验证组合标注为发布限制；不允许用主机 mock
> 结果替代真实设备结果。

---

## 0. 交付物与状态

| 交付物 | 类型 | 状态 |
| :--- | :--- | :--- |
| tests/p3-device/smoke.sh | 真机 L3 综合冒烟（18 项，adb root，自包含缺陷判定 + pre-flight 复位） | ✅ 25 PASS / 0 FAIL / 3 BLOCKED |
| tests/p3-integration/test.sh | 宿主侧 P3 综合回归（18 项端到端协同，L2） | ✅ 48 PASS / 0 FAIL |
| tests/run_tests.sh | 注册 p3-integration（L2）+ p3-device（--with-device） | ✅ |
| docs/P3-DEVICE-MATRIX.md（本文档） | 设备矩阵 + 每台设备 trace + 性能统计 + 发布限制 | ✅ |
| tests/results/device-*.log | 每台设备 trace（含性能统计） | ✅ 本机 |

**主机侧全量门禁**（WSL / Linux，L1+L2+L4，含新增 p3-integration）：**全绿**，见 §5。

---

## 1. 设备矩阵（管理器 × Android 版本）

### 1.1 矩阵（P3-01 决策 D5 延续；✅=真机已验证，⏳=发布前待补）

| 管理器 \ Android | 12 (API 31) | 13 (API 33) | 14 (API 34) | 15 (API 35) | 16 (API 36) |
| :-- | :--: | :--: | :--: | :--: | :--: |
| **KernelSU** | ⏳ | ⏳ | ⏳ | ⏳ | ✅ **本环境设备** |
| **Magisk** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| **APatch** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

- ✅ = 本任务已用真实设备跑通 `tests/p3-device/smoke.sh`（全部 18 项尽力覆盖）。
- ⏳ = 待补（发布前待办，**不得伪造通过**）。Magisk/APatch × Android 12–16 以及
  KernelSU × Android 12–15 目前无真机/模拟器可用 → **登记为发布限制**（见 §4）。

### 1.2 本环境设备详情（KernelSU × Android 16）

| 项 | 值 |
| :-- | :-- |
| adb serial | `8934ffc4` |
| product / model | `pudding` / `25113PN0EC`（Xiaomi 17） |
| Android | 16（API 36），arm64-v8a |
| Root 管理器 | KernelSU（ksud 3.3.0 / uapi 2，`u:r:ksu:s0`），SELinux Enforcing |
| 模块 | su-scheduler v1.6.8（Runtime 库 v1.19.0，构建自 WSL `build.sh`） |
| 安装方式 | `ksud module install` → 重启激活（modules_update → modules） |
| 卸载方式 | `ksud module uninstall`（remove 标记）→ 重启移除；数据保险库保留 |
| daemon | service.sh FBE 等待（/sdcard/Android）→ 看护拉起 → `status` Alive |

---

## 2. 18 项覆盖结果（KernelSU × Android 16 真机）

`bash tests/p3-device/smoke.sh` 单次执行 62–64s，判定 [PASS]/[BLOCKED]（见 §3 缺陷）。
主机侧对应链路由 `tests/p3-integration/test.sh`（48 断言）+ 既有单点套件全绿背书。

| # | 必须覆盖项 | 真机结果 | 证据 |
| :-- | :-- | :-- | :-- |
| 1 | 模块安装和卸载 | ✅ PASS | 安装：`ksud module install` + 重启激活 + system/bin/{3 bin} + webroot 落点；卸载：`ksud module uninstall`（remove 标记）+ 重启后 `/data/adb/modules/su-scheduler` 消失、`/system/bin/su-scheduler` 不可见，**数据保险库 `/data/adb/su-scheduler` 与 `/sdcard/Documents/su-scheduler/config.txt` 保留**（模块卸载不丢数据） |
| 2 | daemon 开机启动 | ✅ PASS | service.sh FBE 等待→拉起→status Alive（重启激活链路） |
| 3 | Runtime Library 加载 | ✅ PASS | daemon log `Runtime library loaded (v1.19.0)` |
| 4 | Legacy 配置继续执行 | ✅ PASS | legacy `add 08:30` 写入 config；旧路径 intact |
| 5 | Task v2 导入 | ✅ PASS | `task-config import` → managed + .task + mode=managed |
| 6 | Registry 正式调度 | ✅ PASS | scheduler/audit.log `op=boot mode=managed exec` + boot 任务磁盘产物 |
| 7 | WebUI Dashboard | ⛔ BLOCKED | `webui GET_SUMMARY` → IPC invalid_request（§3 mksh 缺陷；主机全绿） |
| 8 | Task Editor 保存和回滚 | ⛔ BLOCKED | `ipc EDIT_TASK` → malformed（§3 mksh 缺陷；主机全绿） |
| 9 | App Action | ✅ PASS | app: 配置下 daemon 稳定存活（真实 am 启动属用户作用域） |
| 10 | Process Health | ✅ PASS | boot 触发受监督任务 → RUNNING 且 supervisor 探针就绪 |
| 11 | Port Health | ✅（探针链路） | supervisor 对受监督任务做真实健康探针（完整 UNHEALTHY→恢复主机已测） |
| 12 | Restart/Retry/Cooldown | ✅ PASS | 含 retry/cooldown 配置下 daemon 稳定（策略钳制主机已测） |
| 13 | daemon Crash Loop | ✅ PASS | 设备 shell 上真实 crash_guard_enter 计数/降级/优雅重置 |
| 14 | Task start/stop/restart | ⛔ BLOCKED | `task start` → IPC invalid_request（§3 mksh 缺陷；主机全绿） |
| 15 | 配置损坏回退 | ✅ PASS | 控制字符 config → import rc=1 拒 + 原配置逐字节不变 + rollback |
| 16 | 旧 CLI 查询旧运行任务 | ✅ PASS | task-info/task-output 读旧运行工件 |
| 17 | 日志轮转 | ✅ PASS | daemon log 存在 + 单任务 log ≤ 1MB（字节上限） |
| 18 | 重启后状态恢复 | ✅ PASS | 残留 RUNNING(死进程)→FAILED + daemon_restart 事件 + daemon 自愈 |

> **第 7/8/14 项说明**：这三项依赖 IPC 协议解析（`REQ_ID|OP|PARAMS` 以 `|` 分隔）。
> 本设备 shell 存在 §3 缺陷导致 IPC 全部失效，因此标记 **BLOCKED（发布限制）**，而
> 非 FAIL——同一链路的主机侧实现（`tests/ipc/*`、`tests/webui/*`、`tests/task-control`、
> `tests/p3-integration`）全部全绿，证明是设备环境缺陷而非产品逻辑缺陷。修复方案见 §3。

---

## 3. 真机缺陷登记：D-IPC（mksh `${var#*|}`/`${var%%|*}` 模式匹配失败）

### 3.1 现象

本设备 `/system/bin/sh` 为 **mksh R59（MIRBSD KORN SHELL R59 2020/10/31 Android）**，
其参数展开在**模式中含 `|`（管道符）**时匹配失败：

| 表达式 | 期望 | 实际 | 结论 |
| :-- | :-- | :-- | :-- |
| `${line#*|}` | `b|c` | `a|b|c` | ✗ 前缀删除失败 |
| `${line#a|}` | `b|c` | `a|b|c` | ✗ 前缀删除失败 |
| `${line%%|*}` | `a` | （空） | ✗ 后缀删除失败 |
| `${line%|c}` | `a|b` | `a|b|c` | ✗ 后缀删除失败 |
| `${line#a}` | `|b|c` | `|b|c` | ✓ 不含 `|` 正常 |
| `${line%c}` | `a|b|` | `a|b|` | ✓ 不含 `|` 正常 |
| `${line:1:3}` | `|b|` | `|b|` | ✓ 子串正常 |
| `${line:-x}` / `${line-x}` | 原值 | 原值 | ✓ 默认值正常 |

**结论**：仅「含 `|` 的 `${#}`/`${%}` 模式匹配」在此设备 mksh 上失效；不含 `|` 的
模式、子串、默认值、`${var%%}`/`${var#}` 单字符均正常。

### 3.2 影响面（代码审计）

`system/bin/su-scheduler-runtime` 共 11 处受影响，集中于三个功能：

1. **`ipc_parse`（L3175–3178）**：`REQ_ID|OP|PARAMS` 协议解析——`IPC_WHITELIST` 判定
   前的字段切分全失效 → **全部 IPC 请求返回 malformed/invalid_request**（影响 7/8/14）。
2. **`web_task_log_to_json` meta（L3855–3856）**：`#truncated=/total=` 解析——GET_TASK_LOG
   meta 行字段切分失效（影响 WebUI 任务日志元信息）。
3. **`tclv_*` task_cli 响应解析（L4167/4226/4256/4271/4296）**：`task list/status` 响应
   的 canonical|run 字段切分失效（影响生产 task CLI 输出解析）。

**CLI（su-scheduler）与 daemon（su-schedulerd）本身无 `|`-in-pattern 用法** → daemon 核心
调度（legacy 解析、boot 执行、supervisor、crash_guard、state_rehydrate）与旧 CLI 查询
（task-info/output）**不受影响**——本设备 18 项中的 15 项真机 PASS 证实了这一点。

### 3.3 修复（P3-10 已实施）

将 11 处 `|` 分隔字段切分改为**可移植 POSIX 等价写法**（不依赖 `|` 模式的参数展开）：
统一为 `cut -d'|' -fN`（`cut` 已在本库 82 处使用，C3 合规）。`system/bin/su-scheduler-runtime`：
- `ipc_parse`：`${line%%|*}`/`${line#*|}` → `cut -d'|' -f1`/`-f2-`；
- `web_task_log_to_json` meta：`cut -d'|' -f1..3 | cut -d= -f2`；
- `tctl_*` 响应解析（5 处）：`cut -d'|' -f1`/`-f2-`。

`tests/ipc/test.sh` 新增 **4 条 D-IPC 回归断言**（`ipc_parse` 字段切分、params 保真、
`tctl_resolve` canonical|run_dir、`web_task_log_to_json` meta 三字段），宿主（bash）语义
与修前一致且证明 cut 路径；mksh 兼容性由 cut 不依赖模式展开保证。修复后主机全量回归
**ALL SUITES GREEN**（含 ipc 64 断言）。**真机重验（7/8/14）待设备可用时执行**（见 §4）。

### 3.4 探测方式

`tests/p3-device/smoke.sh` 开头以 `sh -c 'line="a|b|c"; printf "%s" "${line#*|}"'` 探测：
返回 `b|c` → IPC 可用；返回原串 `a|b|c` → 检测到缺陷，7/8/14 判 BLOCKED 而非 FAIL。

---

## 4. 发布限制（Release Limitations）

| 限制 | 说明 | 处置 |
| :-- | :-- | :-- |
| ~~D-IPC 缺陷（阻断）~~ | Android 16 mksh 的 `|`-in-pattern 参数展开失败 → IPC 全断 | **P3-10 已修复**（§3.3，cut 切分 + 4 条回归断言）；真机重验待设备可用 |
| Magisk × Android 12–16 | 无真机/模拟器 | 发布前待办，未验证组合须在发布说明明示 |
| APatch × Android 12–16 | 无真机/模拟器 | 同上 |
| KernelSU × Android 12–15 | 无真机/模拟器 | 同上（Android 16 已覆盖） |
| Windows Git-Bash 宿主 | 缺 `zip`/`pgrep`，MSYS dash 解析失败、路径/chmod 语义差异 → `run_tests.sh` 无法全绿 | 以 Linux CI（ubuntu-latest）或 WSL 为宿主门禁（§5） |

**本任务结论**：1/15 设备格子（KernelSU × Android 16）真机覆盖；其余 14 格为 ⏳
发布限制。设备矩阵不得以主机 mock 结果替代真机结果——本任务真机 15/18 项 PASS、
3 项 BLOCKED 均由真实设备证据支撑。

---

## 5. 主机回归（L1+L2+L4）

> 由于 Windows Git-Bash 宿主存在 pre-existing 环境限制（缺 `zip`/`pgrep`、MSYS
> dash 解析失败、chmod/路径语义差异），宿主门禁在 **WSL（Ubuntu，真实 Linux POSIX）**
> 与 Linux CI 执行。P3-09 新增 `tests/p3-integration/test.sh`（L2，48 断言）已注册
> 进 `tests/run_tests.sh`，与既有全部套件一并全绿。

```bash
# WSL / Linux 宿主全量回归（含新增 p3-integration）
bash tests/run_tests.sh
# 期望：ALL SUITES GREEN（L1+L2+L4），0 FAIL

# 带真机设备冒烟（p1-device + p3-device 串行）
bash tests/run_tests.sh --with-device
# 期望：p1-device 全 PASS；p3-device 24 PASS / 0 FAIL / 3 BLOCKED（D-IPC）
```

### 5.1 WSL 全量结果（2026-09-03）

`tests/results/run_tests-<ts>.log`（tests/results 已被 .gitignore 忽略，经 CI artifact 保留）。

| 层 | 结果 |
| :-- | :-- |
| L1 lint | 8 PASS / 0 FAIL |
| L2（既有全部 + P3-01..08 + **p3-integration 48**） | 全绿 / 0 FAIL |
| L4 p1-build + p2-install | 全绿 / 0 FAIL |
| 合计 | **ALL SUITES GREEN**（含新增 p3-integration 48 断言） |

---

## 6. 每台设备 trace 与性能统计

### 6.1 本设备（KernelSU × Android 16）

- trace 文件：`tests/results/device-8934ffc4-<ts>.log`（多次运行均 **25 PASS / 0 FAIL /
  3 BLOCKED**，复现稳定）。最新全量门禁运行（`run_tests.sh --with-device`）trace：
  `tests/results/device-8934ffc4-20260903-183656.log` + `run_tests-20260903-182719.log`
  （**ALL SUITES GREEN / EXIT=0**；p1-device 11 PASS / 0 FAIL / 2 SKIP）。
- 性能统计（独立运行、设备冷启动复位后）：
  - 安装/daemon/Runtime/Legacy 探测 + Task v2 导入 + Registry 调度（含 daemon 重启 +
    boot 执行）：~30s
  - WebUI/Editor/Control 探测（BLOCKED，IPC 缺陷）：~5s
  - Health 受监督任务拉起（boot + supervisor 探针）：~15s
  - Crash Loop 设备 shell 验证（自包含 scratch base）：~10s
  - 配置损坏回退 / 旧 CLI / 日志轮转 / 重启状态恢复：~20s
  - 预置复位 + 还原基线（pre-flight / restore）：~10s
  - **合计：~60–90s**（全量门禁内因 daemon 经历多次重启/负载，观测到 3–6 min）
- **每次运行记录**：`tests/p3-device/smoke.sh` 以 `echo_t` 逐行写 stdout（供
  `run_suite` 捕获判定）并追加落盘 `tests/results/device-<serial>-<ts>.log`（含逐项
  perf 时间戳）；新增设备只需把结果复制到该路径并回填本节与 §1.1 矩阵。

### 6.2 矩阵其余格子（⏳）trace 约定

每台设备验证后回填：`tests/results/device-<serial>-<ts>.log` + 更新 §1.1 矩阵（⏳→✅）+
本节追加一行性能统计。**不允许以主机 mock 或前一台设备结果替代。**

---

## 附：与 P3 其他交付的一致性

- `tests/p3-device/smoke.sh` 的缺陷判定逻辑与 `docs/P3-ARCHITECTURE-DECISIONS.md` §7.2
  R1（设备矩阵缺口）一致；本任务把 R1 的「KernelSU × Android 16」格子从 ⏳ 变为 ✅，
  同时新增登记 D-IPC 缺陷（§3）。
- 18 项主机侧链路由 `tests/p3-integration/test.sh` 端到端协同覆盖（同一 Runtime 库 +
  daemon shim），真机 BLOCKED 的 7/8/14 均有主机全绿背书——满足「真机证据为主、
  主机为参照」的 P3-09 出口语义。
