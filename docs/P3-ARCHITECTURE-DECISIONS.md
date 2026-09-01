# Su Scheduler — P3 架构决策（P3-ARCHITECTURE-DECISIONS）

> **阶段**：P3（正式 Task 控制面与 WebUI，V0.3）架构冻结
> **日期**：2026-09-01
> **依据**：P2-EXIT-REPORT（P2 出口）+ `docs/P3-01.md`（P3-01 门禁执行记录）
> **本文件内容**：P3 阶段架构决策（含版本策略、Registry 初始化顺序、WebUI
> 数据面边界）、KernelSU/Magisk/APatch × Android 12–16 设备矩阵、P3 风险清单。
> **生效**：决策一经本文件冻结即视为 P3 默认契约；未经评审不得背离。

---

## 0. 决策总览（TL;DR）

| 决策 | 编号 | 结论 |
| :-- | :-- | :-- |
| 执行入口不变量 | D1 | legacy 调度 = 唯一执行入口；Runtime = 旁路数据面（叠加，不替换） |
| Registry 初始化顺序 | D2 | 保持现状（锁前初始化）为 P3 基线；**推荐**移锁后由 P3-02+ 实施（风险 R2） |
| WebUI 数据面边界 | D3 | Web 端只读消费 `state.txt/events.log` + Registry 快照；**禁止 JS 直执 Root 命令** |
| 版本策略 | D4 | 模块版本 = 发布契约（8 处一致）；Runtime 库版本 = 内部实现线（不绑定） |
| 设备矩阵 | D5 | 管理器 × API 级矩阵；缺失格子为发布前待办，不得伪造通过 |
| P3 不实现清单 | D6 | Dependency / Condition / 任务 DAG / 高级事件链 / 云同步 / 多设备 / 新 daemon / WebJS 直执 Root |

---

## 1. 背景与范围

P3 目标是让用户通过**安全的 WebUI** 创建、查看、编辑、启动、停止、恢复 Task，
同时保证旧版 `config.txt`、旧 CLI、旧任务目录与 Root 执行能力继续兼容。
P3-01 是 WebUI/配置改造前的**发布门禁与架构冻结**，本文件记录其决策输出。

**P3 明确不实现**（P4 再实现 Dependency/Condition 与任务链）：
Dependency、Condition、任务 DAG、高级事件链、云端同步、多设备管理、新的长期
驻留 daemon、WebUI JavaScript 直接执行 Root 命令。

---

## 2. 决策依据（P2 边界事实）

P3-01 门禁已核对（详见 `docs/P3-01.md`）：

1. P2-01..P2-15 生产改动 = `su-scheduler-runtime`（新增，v1.12.0）+
   `su-schedulerd`（+123 旁路接线）+ `su-scheduler`（+122 加载块/CLI 修复/
   task 子命令）+ `.su-scheduler-docs`（版本头）；`service.sh` 零改动。
2. daemon/CLI 共用同一加载契约（`RUNTIME_LOADED` + selfcheck + legacy fallback）。
3. **legacy 调度仍是实际执行入口**：daemon 主循环扫描 config.txt 原样，
   执行点 `action_run`/`execute_task` 门控旁路，旧工件只读不动。
4. 模块版本 `v1.6.8`（8 处一致，build_check 强制）；Runtime 库版本
   `RUNTIME_LIB_VERSION=1.12.0`（内部实现线）。
5. 主机门禁 1215 PASS / 0 FAIL；设备矩阵存在缺口（见 §6）。

---

## 3. 决策 D1：执行入口不变量（P3 全阶段约束）

```
[不可违反] 旧配置解析 + 主循环时间匹配 + heredoc + modifiers + execute_task
           执行路径（SYSTEM/TERMUX/INTERACTIVE）持续可运行，任何新增只能以
           兼容方式叠加（继承 P0 C2）。
```

- WebUI 的「启动/停止/恢复」必须经**既有 CLI 通道**（`su-scheduler` 旧命令或
  `task` 子命令）或 daemon 既有执行点落盘，不得绕过 legacy 执行器新建第二套
  调度/执行引擎（P3 不建新 daemon）。
- 「查看」类数据一律读 Runtime 旁路产物（`state.txt/events.log`/Registry 快照
  /旧 status/pid/output/exit_code 工件），不重扫 config、不产生副作用。

---

## 4. 决策 D2：Registry 初始化顺序（P3-01 审计结论）

### 4.1 现状

daemon 启动序列：加载 runtime → `crash_guard_enter` → `shadow_init`
（`registry_init`）/`runtime_map_refresh`/`lifecycle_startup_registry` 预热 →
（函数定义）→ 单实例等待 → 僵尸剪枝 → 状态再水合 → `echo $$ > LOCK_FILE` →
boot → 主循环。

**Registry 初始化位于单实例锁声明之前。**

### 4.2 审计结论

- **正确性**：registry 是只读旁路数据面，写入原子化（snapshot `snap_<N>` 确定
  性 + `current` 指针 tmp+mv）+ 无效配置 KEPT 回退兜底；正常单实例运行零影响。
- **竞态**：`restart` 重叠窗口（旧 daemon 未退净）存在理论并发写；最坏
  last-writer-wins，不影响 legacy 执行、不损坏旧工件。
- **决策**：P3-01 **保持现状**（本阶段禁止改 daemon 调度路径/启动段）。**推荐**
  在 P3-02+ 把 `shadow_init`/`lifecycle_startup_registry`/`runtime_map_refresh`
  整体移动到 `echo $$ > LOCK_FILE` 之后、boot 任务之前，彻底消除重叠写竞态。
  实施必须：改后全量回归（含 `tests/shadow`、`tests/lifecycle-prod`、
  `tests/p2-integration`）+ 设备冒烟。
- **回退**：若移动导致任何既有套件回归，回滚并登记。

---

## 5. 决策 D4：版本策略说明

### 5.1 模块版本 = 发布契约

- 单一事实源：`build.sh` `VERSION="v1.6.8"`。
- 8 处一致（`tests/p1-build/build_check.sh` 强制）：`module.prop`
  version/versionCode、`su-scheduler` VERSION、`su-schedulerd` VERSION、
  README badge、`update.json` version/versionCode/downloadURL/changelog、
  `.su-scheduler-docs` 头部 Version。
- 版本变化走 `bump_version.sh`；发布经 `release.yml`。

### 5.2 Runtime 库版本 = 内部实现线

- `su-scheduler-runtime` 头部 `RUNTIME_LIB_VERSION`（现 `1.12.0`）随 § 功能
  集合递增，**不参与** 8 处模块一致性校验。
- 映射规则：
  1. 向后兼容叠加（新增 §）→ 库版本递增，模块版本可不变；
  2. 破坏性变化（§ API/语义变更）→ 模块版本必须同步 major；
  3. 模块发布时打包的库版本记入对应 P2-n/P3-n 文档（本文件 §9 维护表）。
- **风险 R4（登记）**：`RUNTIME_LIB_VERSION` 尚未纳入 build_check 版本一致性
  断言。低风险（库自包含、zip 成员校验已覆盖、selfcheck 拦缺失）；建议 P3-02
  在 build_check 增加「`RUNTIME_LIB_VERSION` 存在且语义化版本格式」断言。

### 5.3 P3 阶段版本语义

- P3 首个用户可见里程碑（WebUI 可创建/查看/编辑/启停/恢复 Task）对应模块
  `v0.3`（规划中的 V0.3）；P3 中间接线子任务不 bump 模块版本，只递增文档与
  测试。
- WebUI 发布必须同时满足：主机门禁全绿 + 设备矩阵覆盖项（§6）不为空 + 无
  未登记缺口。

---

## 6. 决策 D5：设备验证矩阵（KernelSU / Magisk / APatch × Android 12–16）

### 6.1 矩阵（管理器 × API 级别）

| 管理器 \ Android | 12 (API 31) | 13 (API 33) | 14 (API 34) | 15 (API 35) | 16 (API 36) |
| :-- | :--: | :--: | :--: | :--: | :--: |
| **KernelSU** | ⏳ | ⏳ | ⏳ | ⏳ | ✅ **本环境设备** |
| **Magisk** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| **APatch** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

- ✅ = 已覆盖；⏳ = 待补（发布前待办，不得伪造）。
- **本环境设备详情**：`8934ffc4`（product `pudding`，model `25113PN0EC`），
  KernelSU（`/data/adb/ksud` + `zygisksu` 存在，`su` context `u:r:ksu:s0`），
  Android 16 / API 36，arm64-v8a，SELinux **Enforcing**，`su -c id` → root OK，
  未安装 su-scheduler 模块。

### 6.2 每格验证项（安装后跑）

对每个「管理器 × API」组合执行：
1. 安装发布 zip（`su-scheduler-v<ver>.zip`）→ `ksud module install` /
   Magisk 刷入 / APatch 刷入；
2. `tests/p1-device/smoke.sh` 全 10 项（boot / time / run-once-now / delete /
   task-info+output / interactive FIFO / termux / 配置自愈 / task CLI）；
3. `tests/p2-install/test.sh` 契约在真机上的落点核对（MODPATH、数据独立目录、
   service.sh 覆盖、system 覆盖、manager-agnostic 路径）；
4. daemon 常驻 + `service.sh` 60s 看护拉起（重启后自动恢复）；
5. FBE 解锁后 boot 任务时序（`/sdcard/Android` 就绪判定）。

### 6.3 执行计划

- P3-02：在本环境 KernelSU/Android 16 设备安装发布 zip，跑全量 L3 冒烟
  （关闭 1/15 格子的 ⏳）；同时登记首个真机证据回填本节。
- 后续：Magisk/APatch 设备（或 Google APIs 模拟器，仅宿主无关项）逐格补齐；
  Android 12–15 用 API 级模拟器/真机矩阵运行（`p1-device/smoke.sh` 扩展为
  矩阵驱动）。

---

## 7. 决策 D6 + P3 风险清单

### 7.1 P3 不实现清单（冻结）

| 项 | 说明 | P3 态度 |
| :-- | :-- | :-- |
| Dependency | 任务间依赖/条件触发/链式执行 | 禁止（P4） |
| Condition | 执行条件表达式 | 禁止（P4） |
| 任务 DAG | 拓扑调度 | 禁止（P4） |
| 高级事件链 | 事件 → 触发链 | 禁止（P4） |
| 云端同步 | 配置/任务云同步 | 禁止 |
| 多设备管理 | 跨设备控制面 | 禁止 |
| 新长期驻留 daemon | 第二常驻进程/循环 | 禁止（daemon 主循环唯一） |
| WebUI JS 直执 Root | 浏览器端拼接任意 Root Shell | 禁止（D3：只读数据面 + 既有 CLI 通道） |

### 7.2 风险清单（登记，按影响排序）

| ID | 风险 | 影响 | 现状 | 处置 |
| :-- | :-- | :-- | :-- | :-- |
| R1 | **设备矩阵缺口**（Magisk/APatch/Android 12–15 无真机） | 高：跨管理器/API 的 `/proc`、`nc`、toybox、安装语义差异未验证 | 未覆盖 | §6 矩阵计划；发布前逐格补齐；缺失须在发布说明明示（不伪造通过） |
| R2 | **Registry 初始化位于单实例锁之前**（restart 重叠竞态） | 中：registry 并发写 last-writer-wins；不影响 legacy 执行 | 存在（理论） | 决策 D2：P3 基线保持；P3-02+ 移锁后（实施前全量回归） |
| R3 | 当前 KernelSU 设备未安装模块 → L3 冒烟未执行 | 中：真机全链路无首次证据 | 待装 | P3-02 安装发布 zip 后跑 `p1-device/smoke.sh` |
| R4 | `RUNTIME_LIB_VERSION` 未纳入 build_check 一致性 | 低：库自包含 + zip 成员校验 + selfcheck | 已登记 | P3-02 增加存在性/格式断言 |
| R5 | CRLF 检出下构建执行 SKIP | 低：CI/LF 为构建闸 | 明示跳过 | 不变（既有语义） |
| R6 | WebUI 对数据面的并发读取与 `runtime_protect*`（P2-14 资源上限）交互 | 中：快照修剪 SNAP_MAX_KEEP 可能截断 Web 正在读的历史 | 设计期 | Web 只读钩子遵循修剪语义：读 current 快照 + 事件日志尾部即可（不断链） |
| R7 | WebUI 编辑 config.txt 与 daemon hot-reload 的原子性 | 中：非原子写可能让 daemon 读到半截配置（registry KEPT 已兜底） | 设计期 | 写侧沿用 CLI add 既有格式 + tmp+mv 原子写；C4 零格式变更 |

---

## 8. 决策 D3：WebUI 数据面边界（P3 WebUI 架构预约束）

- **供电协议**：Web 端只读消费 `$DATA_DIR` 下的 `state.txt`（当前任务状态）、
  `events.log`（事件流）、`snapshots/<current>/*.task`（Registry 快照，P2-03）
  及旧 `tasks/<id>/status|pid|output.log|exit_code` 工件——全部为 Runtime/daemon
  既有产物，Web 不新写、不重扫 config。
- **写侧**：创建/编辑/启停/恢复一律映射到既有 CLI 命令（`add`/`task`/
  `remove`/`restart`/`stop`）或 daemon 既有执行点；**Web 端永不执行任意 Root
  Shell**（与 P2-10 App Action 的「固定 am 模板 + 全参数校验」同一安全哲学）。
- **资源护栏**：遵守 P2-14 `runtime_protect*`（日志/快照/任务目录上限）；Web
  轮询间隔 ≥ daemon tick（分钟级）或读 `last_pulse` 节流。
- **不变量**：任何 WebUI 改动不得触碰 C2/C4（legacy 解析/执行路径与 config 格式）。

---

## 9. 版本-库映射维护表（P3 各接线任务回填）

| 模块版本 | Runtime 库版本 | P3 任务 / 备注 |
| :-- | :-- | :-- |
| v1.6.8（V0.2 出口） | 1.12.0 | P2 出口（P2-EXIT-REPORT） |
| V0.3（规划） | ≥ 1.12.0（随 WebUI 接线递增） | P3-02+ 逐任务回填 |

---

## 附：变更记录

- 2026-09-01：P3-01 创建本文件（决策 D1–D6、设备矩阵、风险清单、版本策略）。
