# Su Scheduler — P1 自动化与设备回归（P1-12）

> **任务**：P1-12 · 建立 P1 自动化与设备回归测试
> **依赖**：P1-01 ~ P1-11（回归覆盖全部 P1 层）
> **性质**：证明兼容性和新基础架构没有破坏旧能力——13 项必须覆盖清单逐项
> **成立**，且不以"Shell 语法检查通过"作为完成标准（AGENTS §4：行为/集成
> 断言 + `[PASS]/[FAIL]` + exit 码）。
> **实现位置**：`tests/run_p1.sh`（P1 出口回归入口）、`tests/p1-regression/`
> （12 项跨层集成）、`tests/p1-build/build_check.sh`（第 13 项构建校验）、
> `tests/p1-device/smoke.sh`（设备冒烟）、本文档。
> **日期**：2026-09-01

---

## 目录

1. [目的与范围](#1-目的与范围)
2. [覆盖矩阵（13 项 ↔ 套件）](#2-覆盖矩阵13-项--套件)
3. [回归入口](#3-回归入口)
4. [构建校验（第 13 项）与行尾环境](#4-构建校验第-13-项与行尾环境)
5. [设备冒烟（KernelSU）](#5-设备冒烟kernelsu)
6. [验收标准对照](#6-验收标准对照)

---

## 1. 目的与范围

- **目的**：P1 全部 12 个任务（P1-01~P1-11）已交付层/工具（baseline、schema、
  state-machine、provider 契约、legacy adapter、registry、trigger 决策、
  action 执行、runtime 状态/事件、lifecycle、只读 CLI）——P1-12 把它们
  **装订为自动化回归**，证明：
  1. 旧能力（legacy 解析/触发/执行/锁/构建）在新基础下不回退；
  2. 新基础（registry/状态/事件/生命周期/CLI）可独立验证；
  3. 设备（KernelSU）冒烟是真实环境证据，构建校验是发布证据。
- **完成标准**：`tests/run_p1.sh` 全绿（无 `[FAIL]`，exit 0）；`[SKIP]` 仅限
  环境受限项且明示（CRLF 检出构建、无 adb 设备）——与 P0 L3 `--skip-device`
  的"允许跳过项仅限…须明示"语义一致。
- **不止语法检查**：13 项中每一项都有**行为断言**（解析结果、转换、回退、
  触发、执行、锁语义、CLI 输出、zip 产物），`bash -n` 语法层只是其中一环。

## 2. 覆盖矩阵（13 项 ↔ 套件）

| # | 必须覆盖 | 回归套件 | 断言要点 | 验收映射 |
| :-- | :--- | :--- | :--- | :--- |
| 1 | Legacy 配置解析 | legacy-adapter（107 断言）+ p1-regression §1 | 17 任务、source.line 保留、trigger 原样 | P1-01/05 |
| 2 | Task ID 稳定性 | p1-regression §2 | 两次解析 id 集一致、无时间戳、t<line>_<trigger> | P1-05 |
| 3 | 状态合法/非法转换 | state-machine（183）+ p1-regression §3 | 合法边接受、非法边/非法 cause 拒绝 | P1-03 |
| 4 | 无效配置回退 | task-registry（44）+ p1-regression §4 | 坏配置 → KEPT 保留最后有效快照、任务不消失 | P1-06 |
| 5 | hot reload | task-registry + p1-regression §5 | 追加行 → 全量新快照、无混合、无重复 | P1-06 |
| 6 | boot 任务 | trigger-decision（39）+ p1-regression §6 | boot 上下文 → cause=boot；上下文外不触发 | P1-01/07 |
| 7 | 时间任务 | trigger-decision + p1-regression §7 | NOW 精确分钟匹配；错分钟不命中 | P1-01/07 |
| 8 | heredoc | legacy-adapter + p1-regression §8 | source.type=block、重构残留、trigger 保留 | P1-01/05 |
| 9 | Termux 模式 | providers（136）+ p1-regression §9 | helper 缺失/READY 三态、优雅失败不崩溃 | P1-08 |
| 10 | command/script 执行 | action-run（24）+ p1-regression §10 | 普通成功/失败(FAILED+exit_code)/脚本、output.log | P1-08 |
| 11 | daemon lock & stale PID | lifecycle（56）+ p1-regression §11 | 单实例、stale 恢复、僵尸清理（ZOMBIE_CRASHED+FAILED） | P1-10 |
| 12 | CLI 只读查询 | task-cli（39）+ p1-regression §12 | list 6 字段、status key=value、错误三态 rc1/2/3 | P1-11 |
| 13 | 安装包构建 | `tests/p1-build/build_check.sh` | build.sh → zip、unzip -t、六处版本一致、工作树还原 | P0 L4 / P1-12 |

> **跨层集成价值**（p1-regression）：非逐套重跑，而是**抽代表性场景复用全部
> P1 层端到端**（registry→决策→执行→状态→清理→查询），验证层间接线而非
> 单元孤立正确。

## 3. 回归入口

```bash
bash tests/run_p1.sh               # P1 出口回归：9 套既有 + p1-regression + build_check
bash tests/run_p1.sh --with-device # 追加设备冒烟（无设备 → DEVICE_SKIPPED）
bash tests/_run_all.sh             # 聚合 9 套既有 + p1-regression（既有入口，等绿）
```

- `run_p1.sh` 判定：每套 `[FAIL]` 计数为 0 且退出码 0 → 全绿；任一失败打印
  前 10 条 `[FAIL]` 并 exit 1。

## 4. 构建校验（第 13 项）与行尾环境

`tests/p1-build/build_check.sh`：

1. **构建**：`bash build.sh` 产出 `su-scheduler-v<ver>.zip`；
2. **完整性**：`unzip -t` 无错误；
3. **内容**：zip 含 `module.prop` / `service.sh` / `customize.sh` /
   `system/bin/{su-scheduler,su-schedulerd,su-scheduler-termux}`；
4. **六处版本一致**（build.sh 为单一事实源）：module.prop(version/versionCode)、
   两个 bin(VERSION)、README badge(Version-<nv>)、
   update.json(version/versionCode/downloadURL)；
5. **还原工作树**：删 zip + `git checkout system/bin/.su-scheduler-docs`
   （build.sh 会重建该文件——还原防止污染，同 P0 T4 演练惯例）。

- **行尾环境（P1-01 §1 基线事实）**：仓库以 LF 存储；Windows
  `core.autocrlf=true` 检出为 CRLF，P1-01 已记录"CRLF 检出既不是语法基线
  也不是可发布形态（build.sh 在 CRLF 检出下打包会把 CRLF 带入 zip）——
  **记录，不修**。因此 `build_check.sh` 检测工作树行尾：
  - **LF 工作树**（CI ubuntu 等）→ 完整构建/完整性/内容三段执行；
  - **CRLF 检出** → 构建执行三段**明示 `[SKIP]`**（"CI/LF is the build
    gate"），六处版本一致照常校验——与 P0 L3 `--skip-device` 同类"明示
    跳过"语义，不是静默偷工。

## 5. 设备冒烟（KernelSU）

`tests/p1-device/smoke.sh`（`adb`，root 已授权 KernelSU 设备或 Google APIs
模拟器；`--skip-device` / 无 adb / 无授权设备 → 明示 `DEVICE_SKIPPED`）：

| 用例 | 验证 |
| :-- | :--- |
| 1 | daemon 存活（`su-scheduler status` → Alive） |
| 2 | `boot` 任务：临时配置 boot 行 → 重启 daemon → 磁盘产物 |
| 3 | 时间任务：`HH:MM` +2min 调度 → 分钟内执行 |
| 4 | `--run-once-now`：立即执行 + 配置修剪（T1 golden） |
| 5 | `--delete`：执行后行移除 |
| 6 | task-info / task-output / tasks 链路 |
| 7 | 交互 shell（shells 目录 FIFO 可读） |
| 8 | `--termux`：未安装优雅报错 / READY / LOCKED |
| 9 | 配置自愈：冒烟前后 config 一致（除 4/5 预期变化） |
| 10 | P1 只读 CLI：`task list` / `task status`（registry 快照行） |

- **验收环境**：P1-12 要求"至少一台 KernelSU Android 设备做真实 smoke
  test"——本地无 adb 时脚本就绪并 `DEVICE_SKIPPED` 明示，设备验证缺失按
  P0 D3 例外流程人工裁决；Magisk/APatch 在 P1 仅验证"不破坏安装路径"
  （zip 内容与六处版本一致），不要求新特性在其上完整支持。

## 6. 验收标准对照

| P1-12 验收 | 落实 |
| :--- | :--- |
| 所有 P1 回归测试通过 | `run_p1.sh` 11 套全绿（state-machine 183 / providers 136 / legacy-adapter 107 / task-registry 44 / trigger-decision 39 / action-run 24 / runtime 45 / lifecycle 56 / task-cli 39 / p1-regression 44 / p1-build 9 PASS，0 FAIL）；`_run_all.sh` 聚合 10 套等绿 |
| 不能只以 Shell 语法检查通过作为完成标准 | 全部套件为**行为/集成断言**；`bash -n` 语法层仅一环（build_check 亦校验 build.sh 语法） |
| 覆盖 13 项清单 | §2 覆盖矩阵逐项 ↔ 套件 ↔ 断言 ↔ 验收映射；构建（13）与设备（真实 KernelSU）分别由 p1-build / p1-device 承担 |
| 环境受限明示 | CRLF 检出构建 → `[SKIP]` 明示；无设备 → `DEVICE_SKIPPED` 明示（P0 L3/D3 语义） |