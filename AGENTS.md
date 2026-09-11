# Su Scheduler — P0 阶段 Agents 工作文档

> **适用对象**：参与 P0 阶段开发的所有 Agent 与人工评审。
> **文档性质**：P0 阶段（优先级 0，稳定化阶段）的强制工作清单与执行门禁。
> **基线版本**：v1.6.8（Git `main`，working tree clean 状态作为基线快照）。
> **约定**：文中的所有路径均为仓库相对路径（如 `system/bin/su-schedulerd`）。

---

## 目录

1. [项目背景与关键路径](#1-项目背景与关键路径)
2. [全局约束（不可违反）](#2-全局约束不可违反)
3. [工作流程与任务门禁](#3-工作流程与任务门禁)
4. [回归测试体系定义](#4-回归测试体系定义)
5. [TaskIndex 清单（T0–T5）](#5-taskindex-清单t0t5)
6. [候选缺陷清单（T2 依据）](#6-候选缺陷清单t2-依据)
7. [决策门（Sign-off）](#7-决策门sign-off)
8. [P0 出口标准（Definition of Done）](#8-p0-出口标准definition-of-done)
9. [P1 移交清单（禁止提前实现）](#9-p1-移交清单禁止提前实现)
10. [Agent 行为准则与提交规范](#10-agent-行为准则与提交规范)

---

## 1. 项目背景与关键路径

**Su Scheduler** 是一个 systemless 的 Android 自动化调度模块（支持 Magisk / KernelSU / APatch），全部由 POSIX shell 实现，配置文件为 `/sdcard/Documents/su-scheduler/config.txt`。P0 阶段的目标是**在不做架构变更的前提下，建立可验证的质量基线并修复基线暴露的缺陷**。

| 文件 | 角色 | P0 处理原则 |
| :--- | :--- | :--- |
| `system/bin/su-scheduler` | CLI 管理端（add/list/remove/edit/log/tasks/task-*/shell-*/run/exec/status/restart/stop/test/audit/help） | 只做最小修复，禁止重构 |
| `system/bin/su-schedulerd` | 守护进程（boot/时间/进阶调度、modifiers、heredoc、进程隔离、审计） | 只做最小修复，禁止重构 |
| `system/bin/su-scheduler-termux` | Termux 环境桥接（validate/setup/exec/status） | P0 仅保持不动 |
| `service.sh` | 开机服务（FBE 等待 + 既有看护循环） | P0 **禁止改动**（既有 Watchdog 保持原样，见 C5） |
| `customize.sh` | 安装器 | P0 仅验证，不改逻辑 |
| `build.sh` / `bump_version.sh` | 构建与版本同步 | P0 验证 + 必要时最小修复（T4） |
| `module.prop` / `update.json` / `.github/workflows/release.yml` | 模块元数据与发布管线 | P0 验证一致性（T4） |
| `README.md` / `system/bin/.su-scheduler-docs` | 文档 | P0 可补充"如何运行测试"章节；与实现严重不符处经 T2 决策后处理 |

---

## 2. 全局约束（不可违反）

以下约束对所有 TaskIndex 生效，违反即视为任务失败，须回滚并重新评估。

| ID | 约束 | 细则 |
| :-- | :--- | :--- |
| **C1** | **不重写整个 su-scheduler** | 禁止整体重构、重写文件、重命名脚本/函数/路径。所有改动必须是**增量、最小 diff**，保留既有文件头、函数名、行为与注释结构。 |
| **C2** | **不删除旧配置解析和执行路径** | 既有的 boot 启动解析、主循环时间匹配、heredoc（`<<EOF`）解析、modifiers 解析（`parse_modifiers`/`extract_command`）、`execute_task` 执行路径（SYSTEM / TERMUX / INTERACTIVE）必须持续可运行。新增逻辑只能以兼容方式叠加，不得替换或删除旧路径。 |
| **C3** | **不引入非 Android 标准外部依赖** | 运行期仅允许 Android 系统自带命令（`sh`、`sed`、`grep`、`awk`、`date`、`ls`、`cat`、`cut`、`sleep` 等 toybox 标准工具）。禁止：Python/Node 运行期依赖、busybox 专有扩展的硬依赖、任何需 `apt/pip/npm/pkg` 安装的组件。测试期同样只用 POSIX 工具与 GitHub Actions 标准 runner 自带工具（`bash`/`sh`/coreutils/`grep`/`sed`/`awk`/`zip`/`unzip`），`adb` 作为可选设备通道。 |
| **C4** | **不改变已有配置文件格式** | `config.txt` 的既有行格式 `<trigger> <command>; : <modifiers>` 及全部已文档化触发格式（`boot`、`HHMM`/`HH:MM`、`weekly:`、`nweekly:`、`monthly:`、`nmonthly:`、`yearly:`）与 modifiers 的解析语义**不允许改变**。修复 CLI 后写出的行必须仍为 daemon 已支持的格式。 |
| **C5** | **不提前实现 WebUI、Watchdog、Dependency** | 这三项为 P1+ 范畴。P0 中：不得新建 WebUI 相关文件/接口/占位目录；不得新增或增强 Watchdog（`service.sh` 内既有看护循环保持原样，仅允许被 T3 冒烟验证）；不得引入 Dependency（依赖/条件触发）机制。文档中提及仅限第 9 节"移交清单"。 |
| **C6** | **每个任务必须包含测试或可验证的验收步骤** | 每个 TaskIndex 的"验收步骤"必须给出**可执行命令 + 期望输出/状态**，不允许"人工目测无异常"这类含糊标准。见各任务节。 |
| **C7** | **任务间门禁：先回归，再进入下一个 TaskIndex** | 每个任务完成后，必须先通过第 4 节定义的回归测试（L1–L4，L3 按设备情况）与自身验收清单，**全部通过后才能进入下一个 TaskIndex**。门禁未过不得推进。 |

---

## 3. 工作流程与任务门禁

### 3.1 标准执行循环（每个 TaskIndex 适用）

```
Step 0  阅读本文件第 2、3、4 节与 docs/P0-BASELINE.md（T0 交付后必读）
Step 1  理解当前 TaskIndex 的【目标】【允许改动】【禁止改动】【交付物】【验收步骤】
Step 2  最小 diff 实现（一个任务一个明确的改动面，禁止顺手改无关代码）
Step 3  为该改动补充/更新回归测试（先证明"修前失败/修后通过"，或为新行为写纯新增测试）
Step 4  运行全量回归 tests/run_tests.sh（见第 4 节），并要求 0 失败
Step 5  设备可用时运行设备冒烟（L3）
Step 6  逐条核对本任务【验收步骤】并记录结果
Step 7  更新 docs/P0-BASELINE.md 的对应状态列
Step 8  提交（见第 10 节提交规范）→ 标记该 TaskIndex 完成 → 进入下一个
```

### 3.2 门禁判定（硬性条件）

进入下一 TaskIndex 的**唯一**条件是以下全部满足：

1. `tests/run_tests.sh` 全绿（L1 + L2 + L4；L3 视设备可用性，见 T3 与第 7 节决策）；
2. 当前任务的【验收步骤】逐条通过并有记录；
3. **没有任何既有测试被修改以掩盖失败**（测试文件的改动仅允许修复测试自身的 bug，且必须在提交说明中注明）；
4. 若涉及生产文件改动：diff 最小、无删除旧解析/执行路径（C2 核查）、无新增依赖（C3 核查）、配置格式未变（C4 核查）。

若测试暴露缺陷而当前任务不是修复类任务：**不得顺手修复**，转为登记候选缺陷（第 6 节），由 T2 统一处理。

---

## 4. 回归测试体系定义

P0 建立 `tests/` 目录作为唯一回归入口。所有层级的判定标准统一为：**打印 `[PASS]`/`[FAIL]` 且最终退出码 0（全绿）或非 0（失败）**。

### 4.1 分层结构

| 层 | 名称 | 内容 | 何时运行 |
| :-- | :--- | :--- | :--- |
| L1 | 静态语法检查 | `sh -n` 检查全部 `#!/system/bin/sh` 脚本；`bash -n` 检查 `build.sh`、`bump_version.sh` | 每次回归 |
| L2 | 单元 / 解析行为测试 | 通过测试沙箱（harness）加载脚本头部函数（`parse_modifiers`、`extract_command`、`cmd_add`、`cmd_log`、`cmd_list` 等）与配置 fixtures，验证既有解析语义与 CLI 行为 | 每次回归 |
| L3 | 设备冒烟测试 | 通过 `adb`（root 已授权的设备或 Google APIs 模拟器）对 daemon 做真实运行验证（见 T3 列表）；无设备时 `--skip-device` 跳过并在输出中明示 | 每次回归（有设备时）；T3 为硬性要求 |
| L4 | 构建与版本一致性 | 运行 `build.sh` 验证产物 zip；`unzip -t` 完整性；`module.prop`/`build.sh`/两个 bin 脚本/`README.md`/`update.json` 六处版本号一致性 | 每次回归（构建类任务后必跑） |

### 4.2 目录结构（T0 交付，后续任务只能增补）

```
tests/
  run_tests.sh                 # 入口：串行执行 L1+L2+L4，可选 L3；汇总 PASS/FAIL；非 0 退出表示失败
  lint/syntax.sh               # L1
  harness/lib.sh               # L2 harness：测试 shim（去除 PATH 覆盖、剥离主入口后 source 函数）
  parsing/                     # L2 解析语义 golden 测试（fixtures + 期望输出）
  cli/                         # L2 CLI 行为测试（add/log/list/task-output 等）
  device/smoke.sh              # L3 设备冒烟（adb，--skip-device 支持）
  build/build_check.sh         # L4
  mocks/bin/                   # 测试期 mock：su / cmd / dumpsys / pidof / termux-notification
  fixtures/                    # 配置文件样例（注释、空行、全部触发器、modifiers、heredoc、引号变体）
```

### 4.3 命令与判定

```bash
# 宿主机全量回归（需 POSIX sh；Linux/macOS/WSL 均可，Windows Git-Bash 极慢，Windows 原生 PowerShell 不行）
tests/run_tests.sh

# 带设备冒烟
tests/run_tests.sh --with-device

# 只跑语法层（快速检查）
tests/run_tests.sh --lint-only
```

**判定**：输出中不得出现任何 `[FAIL]`；出现则任务门禁失败。允许跳过项仅限 L3（`--skip-device`，须在输出中明示"DEVICE_SKIPPED"）。

### 4.4 运行环境与性能（重要，避免重蹈覆辙）

**不要在本机 Windows Git-Bash 上跑全量回归。** 测试库与运行时大量使用 `printf | cut | tr`、`grep | head | cut`、`awk` 等 POSIX 管道，在 Windows 上每次子进程派发约 **43ms**（实测），而在 Linux/WSL 原生约 **3.8ms**（≈11 倍差距）。测试是子进程密集型，因此整体耗时被放大同样量级。

实测对照（`tests/p4-dependency/test.sh` 全量，2026-09-04）：

| 运行环境 | 耗时 | 结果 |
| :--- | :--- | :--- |
| Windows Git-Bash | >185s（命令超时被杀） | 107 PASS，未完 |
| WSL + `/mnt/d`（9p 挂载） | ~63s | 全量跑完 |
| WSL + `~/`（原生文件系统） | ~43s | 全量跑完 |

据此定下硬性规则：

1. **全量回归一律在 Linux/macOS 或 WSL 原生文件系统内跑**（把仓库放 `~/su-scheduler`，不要放 9p 挂载的 `/mnt/*`，后者仍有额外开销）。
2. **Windows 上只用 `tests/run_tests.sh --lint-only` 做快速语法检查**。
3. 若必须在 Windows 上跑，**不要一次跑全部套件**——`run_tests.sh` 串行跑了 33+ 个套件，会整体超时；改为按 `run_suite tests/<suite>/test.sh` 单套件逐个跑并单独设超时。
4. 排查慢/疑似卡死时，**勿用 `bash -x` 直接叠在超时命令上**——`-x` 会再放大 5-10 倍，易被误判为死循环。先确认进程 CPU 占用（满载=慢而非卡）或看是否有 `[PASS]` 持续产出。
5. 用 WSL 跑完后若暴露 `[FAIL]`，按第 10 节"测试不可作弊"逐条核查，禁止改测试掩盖。

> 更详细的环境说明与建议见 `docs/RUNNING-TESTS.md`。

---

## 5. TaskIndex 清单（T0–T5）

> 顺序即依赖顺序：**T0 → T1 → T2 → T3 → T4 → T5**。每步通过第 3.2 节门禁后方可推进。

---

### T0 — 基线盘点与回归基座搭建

**目标**：建立 P0 的测试基座；对仓库现状做不可变基线盘点（文件清单、哈希、版本、解析语义快照），为后续任务提供唯一回归入口。

**允许改动**：
- 新增 `tests/` 目录（4.2 结构）及其全部脚本与 fixtures；
- 新增 `.github/workflows/test.yml`（GitHub Actions，`ubuntu-latest`，只使用标准工具）在 push 时运行 `bash tests/run_tests.sh`；
- 新增 `docs/P0-BASELINE.md`；
- `README.md` 追加"🧪 回归测试"小节（不修改既有章节内容）。

**禁止改动**：`system/bin/*`、`service.sh`、`customize.sh`、`build.sh`、`bump_version.sh`、`module.prop`、`update.json`（本任务只验证、不修改）。

**交付物**：
1. `tests/` 全套（含 L1 对全部 shell 脚本通过 `sh -n`/`bash -n` 的检查）；
2. L2 harness 与首批 golden 测试：`parse_modifiers` / `extract_command` 对 fixtures 的解析结果；
3. `docs/P0-BASELINE.md`：仓库文件清单 + `sha256` + 版本号分布 + 已文档化 trigger/modifier 语义枚举 + 文档-实现差异初查（含第 6 节候选缺陷的证据与出处）；
4. `.github/workflows/test.yml`。

**验收步骤（可验证）**：
```bash
bash tests/run_tests.sh          # 期望：全 [PASS]，exit 0
tests/run_tests.sh --lint-only   # 期望：全部脚本语法检查 [PASS]
git status                       # 期望：仅新增 tests/、docs/、.github/workflows/test.yml 与 README 追加行
```
且 `docs/P0-BASELINE.md` 中列出的每个候选缺陷均能给出**文件+行号+触发命令**。

**风险**：harness 的"剥离主入口后 source 函数"需处理 `su-scheduler` 的 PATH 覆盖行（L2 测试 shim 已授权，见 4.2）；若 shim 与脚本结构耦合过深，缩小 L2 范围至"fixtures 级别 golden 测试"，差异在 T1 记录。

---

### T1 — 配置解析行为锁定（golden 语义基线）

**目标**：用测试**锁定**既有配置解析语义（不做任何行为变更），使后续任何改动都不可能无声破坏解析。

**允许改动**：仅新增测试与 fixtures；更新 `docs/P0-BASELINE.md` 的解析语义表；严禁修改任何生产文件（除非 T1 测试确认解析缺陷，此时登记到第 6 节，不修）。

**覆盖范围（必须穷举）**：
- 行级：注释行（`#`）、空白行、行首/行尾空白修剪；
- 触发器：`boot`、`HHMM`、`HH:MM`、`weekly:DOW:HHMM`、`nweekly:N:DOW:HHMM`、`monthly:DD:HHMM`、`nmonthly:N:DD:HHMM`、`yearly:MMDD:HHMM`；
- 分隔符与 modifiers：`; : --run-once-now`、`--delete`、`--notify`、`--notify-start`、`--notify-end`、`--msg="..."`（含引号变体）、`--interactive`、`--termux`；（`--boot` 见第 7 节决策门）
- heredoc：`<<EOF` … `EOF` 解析与 modifiers 保留；
- `--run-once-now` 的"执行后从文件修剪"行为（含修剪后的行内容 golden 断言）。

**交付物**：`tests/parsing/*` 全套、fixtures 扩充、`docs/P0-BASELINE.md` 解析语义矩阵（注明每条已由哪个测试覆盖）。

**验收步骤**：
```bash
bash tests/run_tests.sh   # 期望：T0 全部测试仍绿 + 新增 parsing 测试全 [PASS]
git diff --stat           # 期望：无生产文件改动（仅 tests/、docs/）
```

**风险**：heredoc 解析存在边界情况（嵌套/引号），golden 断言只锁定**当前实际行为**，不做"应该怎样"的主观修正；发现不符文档之处登记为差异项。

---

### T2 — 基线缺陷修复（最小化，逐个门禁）

**目标**：修复 T0/T1 确认的基线缺陷。**每个缺陷 = 最小改动 + 一个先失败后通过的回归测试**，逐项提交、逐项回归，不得合并为一次大改。

**允许改动**：仅修复第 6 节清单中**已被测试确认**的缺陷所涉及的最小代码面；同步更新对应测试与 `docs/P0-BASELINE.md` 状态。其他改动一律禁止。

**禁止改动**：T1 已锁定的解析语义（C4）；daemon 主循环结构（C2）；`service.sh`（C5）；任何未列入清单的行为增强。

**缺陷处理规则**：
1. 每个缺陷先写复现测试（当前应当 `[FAIL]`）；
2. 最小修复后该测试转 `[PASS]`，且 T1 全部 golden 测试仍然全绿（证明解析语义未变）；
3. 涉及 CLI 文档承诺的行为（如 `log -n`、`add` 高级触发器）以 README/help 文档为验收参照；
4. 第 6 节中标注"需 Sign-off"的项（如 `--boot`）不得擅自实现，见第 7 节。

**验收步骤（对每个修复项）**：
```bash
bash tests/run_tests.sh                 # 全绿，且新测试从 FAIL 变 PASS 有记录
git diff system/bin/                    # 人工核查：最小 diff、无旧路径删除
tests/run_tests.sh --lint-only          # 语法层仍绿
```

**交付物**：第 6 节清单中每项的修复提交（独立 commit）、对应测试、基线报告更新。

---

### T3 — 设备端冒烟回归

**目标**：在真实 Android 环境（root 设备或 Google APIs 模拟器 + `adb root`）验证 daemon 全链路，作为 P0 可发布性的硬性证据。

**允许改动**：新增 `tests/device/smoke.sh` 及其文档；不得改动生产代码（冒烟发现缺陷 → 登记，回 T2 流程）。

**冒烟用例（必须全部覆盖）**：
1. 启动：`su-schedulerd` 拉起的 daemon 存活，`su-scheduler status` 输出 Alive；
2. Boot 任务：临时配置含 `boot` 行 → 重启 daemon → 磁盘产物文件生成；
3. 时间任务：`HH:MM` +2 分钟调度 → 分钟内执行且 `tasks`/日志可见；
4. `--run-once-now`：立即执行且配置文件中的该修饰符被修剪，行内容与 T1 golden 一致；
5. `--delete`：执行后行被移除；
6. 任务管理：`task-info` / `task-output` / `task-kill` 全链路；
7. 交互 shell：`--interactive` 的 `.in/.out` FIFO 可用（`shell-send` + `task-output` 验证）；
8. `--termux`：Termux 未安装时优雅报错（不崩溃、日志有 ERROR 记录）；已安装则 `su-scheduler-termux status` 返回 READY；
9. 配置自愈：冒烟前后 `config.txt` 逐字节一致（除第 4、5 项自身预期变化）；
10. 既有的 `su-scheduler test` 设备自测套件可直接复用其结果作为补充证据。

**验收步骤**：
```bash
adb devices                                  # 期望：至少一台授权设备/模拟器
bash tests/device/smoke.sh --with-device     # 期望：全部用例 [PASS]；任何 FAIL 即门禁失败
# 冒烟前后比对配置：除预期变化外逐字节一致
```

**风险/决策**：无设备时该任务视为**阻塞**而非跳过（见第 7 节决策门 D3）；模拟器镜像须为 Google APIs（含 root）或已授权 root 的设备，均为标准资源。

---

### T4 — 构建与版本管线验证

**目标**：验证并可最小修复发布管线（`build.sh`、`bump_version.sh`、`update.json`、`release.yml`），保证 P0 后仍可一键发布。

**允许改动**：`build.sh`/`bump_version.sh`/`update.json`（仅限修复确认的管线缺陷）；新增 `tests/build/build_check.sh`；不得改动模块运行时代码。

**验证项**：
1. 干净克隆后 `bash build.sh` 产出 `su-scheduler-v<ver>.zip`；
2. `unzip -t` 完整性通过；zip 内含 `module.prop`、`service.sh`、`customize.sh`、`system/`；
3. 六处版本号一致：`module.prop`(version/versionCode)、`build.sh`(VERSION)、两个 bin（`VERSION=`）、`README.md`(badge)、`update.json`(version/versionCode/downloadURL)；
4. `update.json` 为合法 JSON 且 downloadURL 指向新版本 release 约定路径；
5. `bump_version.sh` 执行后六处同步（在临时副本上演练，不污染基线）；
6. `release.yml` 为合法 YAML，且其使用的命令均已含于标准 runner。

**验收步骤**：
```bash
bash tests/build/build_check.sh   # 期望：构建、完整性、六处版本一致性全 [PASS]
bash bump_version.sh "chore: P0 test bump" && bash bump_version.sh "chore: revert"  # 演练：同步一致
```
（演练后须 `git checkout` 还原版本相关文件。）

---

### T5 — P0 出口评审

**目标**：执行 P0 出口评审，产出最终报告并冻结 P0 基线，明确移交 P1 范围。

**允许改动**：`docs/P0-BASELINE.md` 终版、`docs/P0-EXIT-REPORT.md`、`README.md` 测试章节完善；**不得再改动生产代码**（除非评审发现阻断性缺陷，则冻结评审、回到 T2 流程）。

**评审内容**：
1. 全量回归（L1+L2+L4）全绿；L3 在至少一台设备/模拟器全绿；
2. 第 2 节约束审计：C1–C5 逐条核对（diff 统计、旧路径清单、依赖审计、配置格式比对、P1 范围零触碰）；
3. 第 6 节清单逐项状态（已修复/已登记/待 Sign-off）；
4. 第 9 节 P1 移交清单成文。

**验收步骤**：`docs/P0-EXIT-REPORT.md` 包含约束审计表、缺陷状态表、回归结果；评审通过后打基线 tag（建议 `p0-baseline-v1.6.8`）。

---

## 6. 候选缺陷清单（T2 依据）

> 以下为 T0 初步盘点发现的**候选**缺陷。T1 之前一律不得直接修改；T2 只处理**已被测试确认（有 FAIL 测试或既有 golden 可证）**的项。状态列由基线报告跟踪。

| ID | 位置 | 现象（证据） | 触发 | 建议最小修复 | Sign-off |
| :-- | :--- | :--- | :--- | :--- | :--- |
| D1 | `system/bin/su-scheduler` `cmd_log`（约 L305–318） | `-n NUM` 被忽略：help/README 承诺 `log -n 50`，实现只处理 `-f`，其余固定 `tail -n 20` | `su-scheduler log -n 5` | 实现 `-n NUM`（默认 20），保留 `-f` 与默认行为 | 否 |
| D2 | 同上 `cmd_add`（约 L139–149） | 文档承诺 `su-scheduler add weekly:1:1000 ...` 等进阶触发器，但实现先剥掉冒号再校验 4 位数字 → 进阶触发器被拒 | `su-scheduler add weekly:1:0900 echo hi` | 校验**已文档化触发器格式集合**（boot/HHMM/HH:MM/weekly:/nweekly:/monthly:/nmonthly:/yearly:），仅对 `HH:MM` 去冒号；写出行仍为 daemon 已支持格式（C4） | 否 |
| D3 | 同上 `cmd_task_output`（约 L472–515） | 同名函数被定义**两次**，后者覆盖前者（死代码 + 行为意外） | `su-scheduler task-output <id>` | 删除重复定义块，保留生效版本；行为由 golden 测试锁定 | 否 |
| D4 | 同上 `cmd_list`（约 L156–256） | `found_any` 在管道子 shell 内赋值不生效 → 有匹配条目时仍可能打印"无匹配"空状态 | 任意 `su-scheduler list`（存在任务时） | 改为 POSIX 安全的非管道循环（临时文件或重定向读取），golden 断言输出 | 否 |
| D5 | `system/bin/su-schedulerd` + CLI | 文档化的 `--boot` 修饰符（"按时 + 每次开机"）在 daemon 中无实现（`parse_modifiers` 未处理） | 配置 `06:00 ...; : --boot` | **不擅自实现**：P0 记录差异，方案由决策门 D1 裁决 | **是** |
| D6 | `tests/`（T0/T1 期间登记） | T1 golden 测试确认的其他解析边界差异 | — | 逐项按 D2 规则处理 | 视项 |

---

## 7. 决策门（Sign-off）

以下事项必须由人工确认后方可执行，Agent 不得自行决定（第 2 节禁止越界）：

- **D1（`--boot` 语义）**：实现"定时 + 开机"（改 daemon 解析，需 T1 更新 golden）或改为文档对齐（声明废弃并提示改用 `boot` 触发器）。默认建议：P0 **仅记录差异**，方案延后到 P1 与 Dependency 特性一并设计，避免与 C5 冲突。
- **D2（L2 harness shim 取舍）**：若"剥离主入口 source 函数"的 shim 维护成本过高，授权缩小 L2 为 fixtures 级 golden 测试（在基线报告中记录取舍）。
- **D3（无设备时的 T3）**：P0 出口的硬性前提是至少一台设备/模拟器的 L3 冒烟全绿；若环境确实无设备，T3 记为阻塞并在出口报告标注"设备验证缺失"，是否放行由人工裁决。

---

## 8. P0 出口标准（Definition of Done）

P0 完成当且仅当：

1. `tests/run_tests.sh` 在 CI（`.github/workflows/test.yml`）与本地全绿（L1+L2+L4）；
2. 至少一台设备/模拟器上 L3 冒烟全绿（见 D3 例外流程）；
3. 第 2 节 C1–C5 审计通过（审计结论写入 `docs/P0-EXIT-REPORT.md`）；
4. 第 6 节清单：全部"无需 Sign-off"项已修复并有测试；Sign-off 项有明确记录与裁决；
5. `docs/P0-BASELINE.md` 与 `docs/P0-EXIT-REPORT.md` 定稿；
6. 配置格式零变更（`config.txt` 样例 fixtures 与 T1 golden 一致）；
7. P1 范围（见下节）零实现、零占位。

---

## 9. P1 移交清单（禁止提前实现）

P0 阶段**禁止**创建以下内容的任何实现、接口、占位目录或测试（提及仅限本文档）：

| 项 | 说明 | P0 态度 |
| :-- | :--- | :--- |
| WebUI | 基于网页的调度/状态界面 | 禁止 |
| Watchdog（增强） | 在 `service.sh` 既有看护循环之外的新看护/自愈机制 | 禁止（既有循环仅验证、不改动） |
| Dependency | 任务间依赖/条件触发/链式执行 | 禁止 |
| （可选）配置加密/备份增强、多配置切换 | 未列入 P0 的需求 | 禁止 |

---

## 10. Agent 行为准则与提交规范

1. **只读先行**：动手前必须阅读 `AGENTS.md`、`docs/P0-BASELINE.md` 与目标文件全部相关内容；禁止基于猜测修改。
2. **最小 diff**：每个 commit 一个目的；禁止顺手格式化、重命名、重排。
3. **测试同行**：任何生产文件改动必须在同一 commit 内附带/更新测试；禁止事后补测。
4. **测试不可作弊**：禁止通过修改测试、删断言、改 fixtures 使失败变绿；测试修复须注明原因。
5. **约束自查**：每次提交前对照 C1–C5 自检（diff 是否含删除旧路径？是否新增依赖？是否触碰配置格式？是否触碰 P1 项？）。
6. **门禁纪律**：回归未过不得标记任务完成、不得进入下一 TaskIndex（C7）。
7. **提交信息**：`[P0-Tn] <type>: <summary>`（type ∈ fix/test/docs/chore/build），如 `[P0-T2] fix: cmd_log honors -n NUM`。
8. **异常上报**：任务中发现本文档未覆盖的缺陷/冲突时，停止实现并登记候选缺陷/决策请求，不得自行扩大范围。