# Su Scheduler — Phase 1 行为基线（P1-01）

> **任务**：P1-01 · 建立现有行为基线
> **基线版本**：v1.6.8（Git `main` @ `3fe7631`，working tree 含本任务新增文件）
> **文档性质**：固化当前 Su Scheduler 的**真实**行为，作为后续一切回归的标准。
> **日期**：2026-08-30
> **P1-13 注记（2026-09-01）**：本基线为 P1 全部回归的兼容基准（P1-01）；P1-02~
> P1-12 的实现层未改动本基线任何旧行为（生产文件零改动，`docs/P1-HANDOVER.md`
> §4 核对）。AGENTS §9 与本基线所述 Watchdog（增强）、WebUI、Dependency 在 P1
> **同样未实现**（仅接口预留，`docs/P1-HANDOVER.md` §5），不得宣称为已完成。
> **验证方法**：本基线中的解析 golden 全部由 **bash 实际执行生产脚本内真实函数**推导
> （`tests/fixtures/legacy/tools/derive-goldens.sh`），非手写；设备端行为标注为
> `L3待验`（当前环境无 adb 设备，见 §10）。

---

## 目录

1. [基线快照](#1-基线快照)
2. [组件清单与职责](#2-组件清单与职责)
3. [运行目录、路径与权限](#3-运行目录路径与权限)
4. [配置格式基线](#4-配置格式基线)
5. [能力行为基线（10 项）](#5-能力行为基线10-项)
6. [已登记行为怪癖与文档-实现差异](#6-已登记行为怪癖与文档-实现差异)
7. [旧配置样例与预期输出](#7-旧配置样例与预期输出)
8. [回归测试清单](#8-回归测试清单)
9. [验收标准对照](#9-验收标准对照)
10. [L3 设备验证状态与缺口](#10-l3-设备验证状态与缺口)

---

## 1. 基线快照

| 对象 | 值 |
| :--- | :--- |
| 模块版本 | v1.6.8（`module.prop`：version=v1.6.8, versionCode=11608；`build.sh` VERSION=v1.6.8；CLI `VERSION="1.6.8"`；daemon `VERSION="1.6.8"`） |
| 文档版本 | `.su-scheduler-docs` 头部标 `Version: 1.6.7`（README badge 为 1.6.8）——**文档版本与实现版本不一致为基线事实** |
| 发布管线 | `update.json`：version=v1.6.8 / versionCode=11608 / downloadURL=`…/releases/download/v1.6.8/su-scheduler-v1.6.8.zip` |
| 仓库文件 | 见 `AGENTS.md` §1 表格；无 `tests/`、无 `docs/`（本任务首次创建） |
| 行尾事实 | 仓库以 **LF** 存储（`git ls-files --eol` → `i/lf`）；Windows 检出（`core.autocrlf=true`）工作树为 CRLF。**基线语义以 LF 为准**；CRLF 检出环境下 `bash -n` 对 5 个生产脚本**全部 FAIL**（实测，2026-08-30），LF 归一后全部 OK → CRLF 检出既不是语法基线也不是可发布形态（`build.sh` 在 CRLF 检出下打包会把 CRLF 带入 zip）。记录，不修 |
| 版本一致性 | 六处版本号：module.prop、build.sh、CLI、daemon、README badge、update.json — 除 `.su-scheduler-docs` 内嵌 1.6.7 外全部一致 |

## 2. 组件清单与职责

| 组件 | 路径 | 职责（基线事实） |
| :--- | :--- | :--- |
| 开机服务 | `service.sh` | FBE 等待（每 10s 轮询 `/sdcard/Android` 存在）→ 5s 稳定 → **看护循环**（每 60s 检查锁文件 PID；daemon 不在则 `nohup` 重启）→ 事件写 `events.log` |
| 守护进程 | `system/bin/su-schedulerd` | 单实例锁、僵尸任务清理、启动期 boot 任务执行、主循环（每分钟扫描配置、hot reload、时间/进阶调度、modifiers、heredoc、任务隔离执行、通知、审计文件维护） |
| CLI 管理端 | `system/bin/su-scheduler` | add/list/remove/edit/log/clear-log/tasks/audit/history|all-tasks/task-info/task-output/task-kill/shell-attach/shell-send/exec|run/examples/test/status/stop/restart/help |
| Termux 桥接 | `system/bin/su-scheduler-termux` | validate/setup/exec/status；状态输出 READY / NOT_INSTALLED / LOCKED |
| 安装器 | `customize.sh` | 解包、建目录、写 genesis 配置（首次）、设权限 |
| 文档 | `system/bin/.su-scheduler-docs` | CLI `help` 的分页文档源（README 合并产物） |

## 3. 运行目录、路径与权限

| 用途 | 路径 | 创建者 | 权限（基线观察） |
| :--- | :--- | :--- | :--- |
| 配置文件（master schedule） | `/sdcard/Documents/su-scheduler/config.txt` | `customize.sh`（缺省时）；CLI `add` 追加 | 安装器 heredoc 创建，root 所有，FUSE/sdcardfs 下通常 0644（ROM 相关）；daemon 只读 |
| 用户文档目录 | `/sdcard/Documents/su-scheduler/` | `customize.sh` / `examples restore` | 0755 惯例 |
| 数据目录 | `/data/adb/su-scheduler/` | `customize.sh` + daemon | 0755，root:root |
| **daemon 主日志** | `/data/adb/su-scheduler/su-scheduler.log` | daemon | 0644；ANSI 彩色 `[时间] [LEVEL] 消息`；子 shell 还追加 `[时间] [DEBUG] …` 明文行 |
| **服务事件日志** | `/data/adb/su-scheduler/events.log` | `service.sh` | 0644；格式 `YYYY-MM-DD HH:MM:SS - [Service] …` |
| **锁文件（daemon 单实例）** | `/dev/.su_scheduler.lock` | daemon（`echo $$ >`） | 0644 root（/dev tmpfs）；service.sh 看护与 CLI status/stop 均读它 |
| 任务目录 | `/data/adb/su-scheduler/tasks/<task_id>/` | daemon `execute_task` | 0755 目录、0644 文件 |
| 任务工件 | `command.txt`、`start_time.txt`、`status.txt`(RUNNING→SUCCESS/FAILED/ZOMBIE_CRASHED)、`exec_mode.txt`(SYSTEM/TERMUX)、`output.log`、`pid.txt`、`exit_code.txt`、`end_time.txt`、`task.lock`（执行中，结束后删除） | daemon | 见 `system/bin/.su-scheduler-docs` L685-697 文档（内容与实现一致） |
| 交互 shell 目录 | `/data/adb/su-scheduler/shells/<task_id>.in`(FIFO)、`<task_id>.out`、`<task_id>.fifo`(创建但未使用) | daemon（`--interactive`） | FIFO 0644；`.out` 常规文件 |
| 审计目录 | `/data/adb/su-scheduler/audit/`、`audit.log`、`config.snapshot`、`last_pulse` | daemon（mkdir/touch） | 0644；**`audit.log` 实际恒为空**（见 §6 Q7） |
| 高级调度状态 | `/data/adb/su-scheduler/schedule_state.txt` | daemon（首次进阶匹配时） | 0644；键格式见 `tests/fixtures/legacy/expected/state-keys.txt` |
| daemon 二进制 | `/system/bin/su-schedulerd`（`service.sh` 另有 `$MODDIR/system/bin/…` 回退） | 模块 | 0755（`customize.sh` `set_perm_recursive $MODPATH/system/bin … 0755 0755`） |
| CLI / Termux 桥 / docs | `/system/bin/su-scheduler`、`/system/bin/su-scheduler-termux`、`/system/bin/.su-scheduler-docs` | 模块 | 0755 / 0755 / 0644（`set_perm_recursive $MODPATH 0 0 0755 0644` 递归，bin 覆盖为 0755） |

## 4. 配置格式基线

### 4.1 行格式

```
<trigger> <command>[;] : <modifiers>
```

- 分隔约定：`<command>` 与 ` : <modifiers>` 之间惯例有一个 `;`（模板与 CLI 写出行均为
  `cmd; : mods`）；daemon 解析时对 `;` 是**可选**的（`extract_command` 的
  `s/[ \t]*;*[ \t]*:[ \t]*--.*//`，`su-schedulerd` L541）。
- modifiers 必须以 `--` 开头且以 ` : ` 前导；若无 ` : ` 段，整行为纯命令。
- 注释行：行首 `#`（修剪空白后判断）；空行跳过（daemon L626-629、CLI list/remove 类似）。
- 行首/行尾空白：daemon 每次扫描先 `sed 's/^[ \t]*//;s/[ \t]*$//'`（L585/L624）。

### 4.2 触发器枚举（daemon 接受/匹配的格式）

| 触发 | 格式 | 匹配语义（§5 详述） |
| :--- | :--- | :--- |
| boot | `boot` | 每次 daemon 启动执行（≈每次开机） |
| 日常 | `HHMM` 或 `HH:MM` | 主循环 `trigger_norm`（去冒号，L650）== 当前 `HHMM` **精确相等** |
| 周 | `weekly:DOW:HHMM`（1=Mon…7=Sun） | 星期匹配 + `当前时间 >= HHMM` + 状态键防重 |
| N 周 | `nweekly:N:DOW:HHMM` | 同上 + 周差 `>= N` |
| 月 | `monthly:DD:HHMM` | 日匹配 + 时间 >= + 状态键防重 |
| N 月 | `nmonthly:N:DD:HHMM` | 同上 + 月差 `>= N` |
| 年 | `yearly:MMDD:HHMM` | `MMDD` 匹配 + 时间 >= + 状态键防重 |

> 注：文档（README/.su-scheduler-docs/customize.sh 模板）写作 `yearly:MM:DD:HHMM`
> （3 段冒号 + 时间）；**实现** `should_run_advanced_schedule` 取 `cut -d: -f2` 为
> `target_date`（L191）——即实现按 `yearly:MMDD:HHMM`（2 段冒号）解析。
> `yearly:12:25:0800` 在实现中 target_date=`12`、target_time=`25`，而当前 `MMDD`
> 形如 `1225`，**永不匹配**。这是文档-实现格式差异（§6 Q9），CLI `add` 也因先剥冒号
> 拒绝这些行（Q2）。基线以**实现**为准。

### 4.3 modifiers 枚举（parse_modifiers，su-schedulerd L491-530）

| modifier | flag（daemon 全局） | 语义 |
| :--- | :--- | :--- |
| `: --notify` | notify_start=1, notify_end=1 | 开始+结束都通知 |
| `: --notify-start` | notify_start=1 | 仅开始 |
| `: --notify-end` | notify_end=1 | 仅结束 |
| `: --delete` | delete_after=1 | 执行后从配置删除该行 |
| `: --interactive` | interactive=1 | 交互 shell（FIFO） |
| `: --termux` | use_termux=1 | Termux 环境执行 |
| `: --run-once-now` | run_once_now=1 | 立即执行并修剪修饰符 |
| `: --msg="…"` | custom_msg | 通知文案；**必须双引号**（`sed -n 's/.*--msg="\([^"]*\)".*/\1/p'`） |
| `: --boot` | **无实现** | 文档化但 daemon 未解析（§6 Q10 / AGENTS D5） |

### 4.4 heredoc 块

```
<trigger> <interp> <<EOF[; : <mods>]
<body 行…>
EOF
```

- 仅在**主循环**内重组（`su-schedulerd` L632-646）；重组为
  `<trigger> <cmd_start> '<body…>'; : <mods>`；**产生的行含 ` : : ` 双冒号工件**
  （模板 `'; : $mods'` 与 `$mods` 本身带 `: ` 前缀叠加）——golden 已实证（§7）。
- 启动阶段（boot 扫描，L582-601）**不做** heredoc 重组：boot+heredoc 行在启动时只以
  头部 `interp <<EOF` 执行（无块体，stdin=/dev/null），块体不执行（§5.1/§5.4）。
- `\n` 拼接为字面量（`multiline_cmd="${multiline_cmd}${block_line}\n"`，L641）；
  是否在后续 `echo` 时变真实换行取决于 shell 的 echo 实现（mksh/dash 解释、bash
  不解释）→ **设备端 heredoc 行为环境相关，L3 待验**。
- EOF 判定：`grep -q '^EOF'`（行首 EOF；同一行尾随内容不处理）。

### 4.5 CLI `add` 写出行格式

`cmd_add`（`su-scheduler` L130-154）：去冒号校验后在 `$CONFIG_FILE` **追加**
`<trigger> <cmd>`（无 `; :` 修饰段——修饰符由用户在 cmd 字符串中自带）。
写出行保持 daemon 已支持格式（C4 合规）。

## 5. 能力行为基线（10 项）

> 每项记录：**输入 / 处理（实现出处）/ 输出 / 状态记录 / 怪癖 / 验证状态**。
> 状态记录条目 = 磁盘上可断言的状态（任务目录、日志、配置文件变化）。

### 5.1 boot

- **输入**：`boot <cmd>[; : <mods>]` 行。
- **处理**：daemon 启动后、进入主循环前（`su-schedulerd` L582-601）扫描全部行，
  凡首词 `boot` → `parse_modifiers` + `extract_command` → `execute_task`。
- **输出**：任务目录 `tasks/startup_<N>_<epoch>/`；`su-scheduler.log` 追加
  `🚀 Task [startup_…] starting: <cmd>`（TERMUX 时为 `🐧 … starting in TERMUX environment`）。
- **状态记录**：`status.txt` RUNNING→SUCCESS/FAILED；`exit_code.txt`；`output.log`
  （无输出文件时任务退出码仍写入）；启动日志序列：
  `🎬 Su Scheduler Daemon v1.6.8 initialized (PID: n)` →
  `🏁 Startup phase: Executing initialization tasks...` → 各 boot 任务 →
  `💓 Daemon pulse detected. Entering main loop.`
- **怪癖**：
  - boot = “每次 daemon 启动都执行”；service.sh 看护重启 daemon（≤60s）会**再次**
    触发全部 boot 任务（§5.10）。
  - `boot … : --delete` **不会**自毁：启动路径不检查 `delete_after`，主循环不匹配
    `boot`（§5.7）。
  - `boot … : --run-once-now` 启动执行**一次**，随后主循环又立即执行并修剪修饰符
    （§5.8 双执行）。
  - boot+heredoc 块体不执行（§5.4）。
- **验证状态**：解析与启动路径＝源码+golden 已锁定；设备端整链路＝L3 待验。

### 5.2 日常时间触发

- **输入**：`HHMM <cmd>` 或 `HH:MM <cmd>`。
- **处理**：主循环每分钟唤醒（`sleep $((60 - $(date +%S)))`，L701），`current_time`
  取 `date "+%H%M"`（L609）；行触发去冒号后与当前时间**精确相等**（L683）→ 执行；
  任务 id `time_<HHMM>_<N>_<epoch>`。
- **输出**：`tasks/time_…/`；日志 `🚀 Task [time_…] starting: …`。
- **状态记录**：同 §5.1（任务工件 + `status.txt`）。
- **怪癖**：
  - 每分钟窗口由唤醒点决定：分钟 `MM` 只在“该分钟内的某次扫描”命中的那一刻执行
    一次；**无补跑**——daemon 停机跨越该分钟则该分钟任务当日不再执行。
  - 若 daemon 恰在 `MM:00` 唤醒且 `%S=0`，`sleep 60` 会跨到下一分钟整（扫描仍覆盖
    当前分钟，因 `current_time` 在睡眠前已捕获）——覆盖同一分钟不重复。
  - `--delete`、`--run-once-now` 在本路径生效（§5.7/§5.8）。
- **验证状态**：逻辑由源码锁定；真实分钟对齐需 L3（+2min 调度法）。

### 5.3 weekly / nweekly / monthly / nmonthly / yearly

- **输入**：`weekly:DOW:HHMM`、`nweekly:N:DOW:HHMM`、`monthly:DD:HHMM`、
  `nmonthly:N:DD:HHMM`、`yearly:MMDD:HHMM`（实现格式，§4.2 注）。
- **处理**：`should_run_advanced_schedule`（L84-206）：日/星期/日期匹配 + `当前时间 -ge
  目标时间`（**非精确**） + `schedule_state.txt` 状态键防重；命中 → 任务 id
  `advanced_<N>_<epoch>`。
- **输出**：`tasks/advanced_…/`；日志 `📅 Advanced schedule matched: <trigger>` →
  `🚀 Task [advanced_…] starting: …`。
- **状态记录**：`schedule_state.txt` 追加/更新键（结构 golden 见
  `tests/fixtures/legacy/expected/state-keys.txt`）：
  - weekly：`weekly_<dow>_<hhmm>_<md5(行+换行)>_<YYYYMMDD>`
  - monthly：`monthly_<dd>_<hhmm>_<md5>_<YYYYMM>`
  - yearly：`yearly_<MMDD>_<hhmm>_<md5>_<YYYY>`
  - nweekly：`nweekly_<n>_<dow>_<hhmm>_<md5>=<周号>`；周差 `(cur-last+53)%53 >= n`
  - nmonthly：`nmonthly_<n>_<dd>_<hhmm>_<md5>=<月号>`；月差含年滚动
  - md5 覆盖**整行**（含末尾换行，`echo | md5sum`）。
- **怪癖**：
  - 时间判定 `-ge`：当日开机晚于目标时间时**仍会执行**（例如 daemon 周一 10:00 才
    启动，`weekly:1:0800` 依旧命中），依靠状态键当日防重。
  - 状态键**只增不减**（无清理）；nweekly 键不含日期 → 跨年/周数不连续时周差计算
    依赖 `%53` 取模，行为按现状锁定。
  - `--delete` 对本路径生效（执行后删行，L678-681）。
- **验证状态**：键结构+匹配逻辑已 golden；设备端周期命中= L3（临时配置法）待验。

### 5.4 heredoc 多行命令

- **输入**：`<trigger> <interp> <<EOF[; : <mods>]` + 块体 + `EOF`。
- **处理**：主循环 L632-646 重组为
  `<trigger> <cmd_start> '<body…>'; : <mods>`，再走统一的 trigger/modifiers 判定。
- **输出 / 状态记录**：任务工件同 §5.1；重建行含 ` : : ` 双冒号工件（golden 实证
  `heredoc-reconstruction.txt`）；`extract_command` 对重建行输出 `interp '<body…>'`
  并残留尾部（golden 中残留 `'; :`/`:` 形态，取决于块体）。
- **怪癖**：
  - 块体拼接是字面 `\n`，最终是否成为多行命令取决于 shell echo（§4.4）；设备端
    mksh 预期可执行多行，但**语义未锁定**，需 L3。
  - 块体内含 `" : --…"` 字样会被 `extract_command` 按修饰符剥离（sed 逐行处理）；
    块体行含 `'` 会破坏单引号重组。
  - **时间/进阶触发**的 heredoc 在主循环正常重组执行；**boot** 触发不重组（§5.1）。
- **验证状态**：重组算式已 golden 锁定；真实执行（块体是否作为多命令运行）= L3。

### 5.5 --termux

- **输入**：行修饰 `: --termux`（或在 CLI `run`/`exec` 输入中）。
- **处理**：daemon 执行分支（L400-426）：调
  `/system/bin/su-scheduler-termux status`；READY →
  `su-scheduler-termux exec "<cmd>"`；LOCKED → `ERROR: User 0 locked`；其他 →
  `ERROR: Termux not installed`（均写 `output.log`，exit 1）。
- **输出 / 状态记录**：`tasks/…/exec_mode.txt` = `TERMUX`；日志
  `🐧 Task […] starting in TERMUX environment`；失败时日志 `[ERROR] ❌ Termux …`；
  `status.txt` FAILED。
- **桥接行为**（`su-scheduler-termux`）：`status` → `READY|NOT_INSTALLED|LOCKED`；
  `exec`：validate → 设环境（PREFIX/HOME/TMPDIR/SHELL/USER/LOGNAME/TERM/COLORTERM/
  LANG/LD_PRELOAD(若 libtermux-exec.so)/PATH/LD_LIBRARY_PATH）→ `cd $TERMUX_HOME || cd /`
  → `exec "$TERMUX_SHELL" -c "$cmd"`；用户解析用 `stat -c %u`（需 toybox stat）。
- **怪癖**：守护线程对 LOCKED / NOT_INSTALLED 的**优雅失败**（exit 1，不崩溃）——
  这是文档承诺的“优雅报错”（T3 用例 8）；CLI `run "… : --termux"` 包装
  `/system/bin/su-scheduler-termux exec "..."` 后 `sh -c`（L799-802）。
- **验证状态**：分支逻辑源码锁定；READY/NOT_INSTALLED/LOCKED 三态需 L3 设备。

### 5.6 --notify / --notify-start / --notify-end / --msg

- **输入**：modifiers（§4.3）。
- **处理**（daemon L209-230 `send_notification` / L471-478）：
  - 开始通知：`notify_start=1` → 标题 `Su Scheduler - Task Started`，正文
    `${custom_msg:-Task started}: <cmd>`；
  - 结束成功：`notify_end=1` 且 exit 0 → `Su Scheduler - Task Complete` / `✅ <cmd>`；
  - **失败通知无条件**：任何 exit≠0 → `Su Scheduler - Task Failed` / `❌ <cmd>
    (exit: N)`——即使未请求 notify（L477，基线怪癖）；
  - 发送尝试：`cmd notification post -S bigtext -t …`（`su -lp 2000` + 环境变量传参）
    与 `termux-notification`（若可用）；无论成败都记日志
    `📢 Notification sent [<tag>]: …`。
- **输出 / 状态记录**：日志（含失败路径也记 `[ERROR] ❌ Task […] failed`）；
  `tasks/…/status.txt`、`exit_code.txt`。
- **怪癖**：`--notify` 与 `--notify-start/end` 混用时按 `grep -q --notify` 且非
  `--notify-` 判定双端（L514）；`--msg` 仅双引号有效（单引号不解析）。
- **验证状态**：分支已锁定；通知可见性需 L3。

### 5.7 --delete

- **输入**：`<time|advanced> <cmd>; : --delete`。
- **处理**：主循环命中执行后 `delete_after=1` →
  `grep -v -F "$line" "$CONFIG_FILE" > tmp && mv tmp`（L680/L692）；日志
  `💥 Boom. Task deleted.`。
- **输出 / 状态记录**：配置文件该行被**整行删除**；任务工件完整（SUCCESS/FAILED）。
- **怪癖**：**对 `boot` 行无效**（永不删行，每次 daemon 启动都执行——§5.1）；对
  heredoc 行同样只作用主循环路径；删除是全文 `grep -v -F`（精确行匹配）。
- **验证状态**：逻辑已锁定；T3 用例 5（设备端删除后配置比对）待验。

### 5.8 --run-once-now

- **输入**：任意触发行修饰 `: --run-once-now`。
- **处理**（主循环 L653-667）：立即执行（任务 id `immediate_<N>_<epoch>`，日志
  `⚡ Immediate execution triggered: <trigger>`）→ 从配置裁剪修饰符：
  `sed "s/--run-once-now//; s/  */ /g; s/ :[ \t]*$//; s/[ \t]*$//"` →
  `awk` 精确替换原行（L664-665），日志 `✂️ Pruning --run-once-now from config`。
- **裁剪结果（golden 实证）**：`14:30 echo "Run me now"; : --run-once-now --notify` →
  `14:30 echo "Run me now"; : --notify`；若仅 `--run-once-now` 单修饰符 →
  `trigger cmd;`（**尾部分号保留**）。
- **状态记录**：配置文件行保留（仅修饰符被剪，成为常规调度行）；任务目录
  `tasks/immediate_…/`。
- **怪癖**：boot+`--run-once-now` 行在启动与主循环**各执行一次**（双执行）；修剪在
  “主循环扫描到该行时”发生（对 heredoc 行先重组再执行，修剪作用于**原行**）。
- **验证状态**：修剪 golden 已锁定；设备端执行+文件比对＝T3 用例 4 待验。

### 5.9 hot reload

- **输入**：修改 `config.txt`（不重启 daemon）。
- **处理**：主循环**每分钟完整重扫配置**（每次迭代 `exec 3<` 重新打开，L622）；
  mtime 检测（`ls -l … | awk '{print $6$7$8}'`，L613）仅用于日志——mtime 变化时记
  `🔥 New configuration detected! Hot reloading presets...`；`LAST_MTIME` 初始 0 →
  **首次迭代必记该日志**。
- **输出 / 状态记录**：新/变配置在 ≤60s 内生效，无需重启；日志多一条 hot reload 行。
- **怪癖**：mtime 只是“日志触发”，真正生效来自全量重扫；mtime 字符串格式依赖
  `ls`（区域设置），不影响判定生效。
- **验证状态**：源码锁定；设备端“改配置→≤60s 生效”＝T3 用例待验。

### 5.10 daemon stop / restart（含看护交互）

- **输入**：`su-scheduler stop` / `su-scheduler restart`（或 daemon 被杀）。
- **处理**：
  - `stop`（L862-880）：`pidof su-schedulerd`（或锁文件 PID 回退）→ `kill`（SIGTERM）
    + `rm -f /dev/.su_scheduler.lock`；输出 `🛑 Halted. …` / 无进程时
    `The daemon was already sleeping.`（任一路径都 rm 锁）。
  - `restart`（L883-890）：`cmd_stop` → `sleep 1` → `nohup "$DAEMON_BINARY" &` →
    `sleep 1` → `cmd_status` 输出。
  - daemon 自身启动：单实例锁检查（锁内 PID 存活则最多等 5s，L546-559）→ 僵尸任务
    标记 `ZOMBIE_CRASHED`（L565-573）→ 写锁 → boot 任务 → 主循环。
  - **service.sh 看护**：每 60s 检查锁；无存活 daemon → `rm lock` + `nohup` 重启。
- **输出 / 状态记录**：`status` = `💓 Alive! Daemon is running smooth (PID: n)`（exit 0）
  或 `💀 Dead. …`（exit 1，锁存在时附 `(Lockfile exists but process seems dead. Stale lock?)`）。
- **怪癖（重要基线）**：`stop` **只停当前 daemon 实例**——service.sh 看护会在
  ≤60s 内将其重新拉起，并**再次执行全部 boot 任务**；因此 `stop` 是瞬态操作，
  “持久停止”目前不存在（除非停用模块服务）。`restart` 亦因此会“额外”跑一轮 boot。
- **验证状态**：源码锁定；看护时序（60s 内重启、boot 重跑）＝T3 用例 1/2 待验。

## 6. 已登记行为怪癖与文档-实现差异

> 编号 Q1–Q10；与 AGENTS.md §6 候选缺陷的对应关系标注。全部**仅记录，不修复**
> （修复权属 P0 T2 / 后续 P1 任务，且须先过回归门禁）。

| ID | 位置 | 基线事实（输入 → 现状输出） | 关联 |
| :-- | :--- | :--- | :--- |
| Q1 | CLI `cmd_log` L305-318 | `log -n 50` 与 `log` 等价：无论 `-n NUM` 一律 `tail -n 20`；仅 `-f` 分支生效 | AGENTS D1 |
| Q2 | CLI `cmd_add` L139-149 | `add weekly:1:0800 …`：先剥全部冒号 → `weekly10800` 非 4 位 → `❌ Error: Invalid trigger 'weekly10800'. Use 'boot' or HH:MM.` exit 1；**文档承诺的进阶触发器无法经 CLI 添加**（可直接编辑配置文件） | AGENTS D2 |
| Q3 | CLI `cmd_list` L166-256 | 匹配行照常打印，但 `found_any` 只在管道子 shell 置位 → 末尾**恒打印** `No active missions matching '<pattern>' were found in the scrolls.`（即使有匹配） | AGENTS D4 |
| Q4 | CLI `cmd_task_output` | 同名函数定义两次（L472 与 L494），后者覆盖前者 → 生效版为“output.log → 无则 shells/.out → 无则报错” | AGENTS D3 |
| Q5 | daemon heredoc 重组 L632-646 | 重组行 `…'; : : --…` 双冒号工件；块体字面 `\n` 依赖 shell echo（设备端行为环境相关） | 新增登记 |
| Q6 | daemon 启动 boot 扫描 L582-601 | boot+heredoc 不重组（块体不执行）；boot+`--delete` 不自毁；boot+`--run-once-now` 两次执行 | 新增登记 |
| Q7 | daemon 审计 L233-285 | `track_config_changes`/`audit_check_gaps`/`log_audit` 均**无调用点**（死代码）→ `audit.log` 恒空、`config.snapshot`/`last_pulse` 从不维护；CLI `su-scheduler audit` 输出“Last 20 events”表头后为空 | 新增登记 |
| Q8 | daemon 交互模式 L345-380 | `.fifo` 创建后未使用；`pid.txt` 先写 shell PID（L372）后被外层 `$!`（子 shell PID，L486）覆盖 → `task-kill` 杀的是子 shell | 新增登记 |
| Q9 | `should_run_advanced_schedule` L189-202 | 文档 `yearly:MM:DD:HHMM` vs 实现 `yearly:MMDD:HHMM`（见 §4.2 注）→ 文档格式的 yearly 永不触发 | 新增登记（与 Q2 同源） |
| Q10 | daemon `parse_modifiers` | `: --boot` 文档化（README/模板/help）但**无任何实现分支** | AGENTS D5（需 Sign-off，P0 不实现） |
| Q11 | 通知 L477 | 失败通知无条件发送（不依赖 notify flags）；`--msg` 仅双引号格式生效 | 新增登记 |
| Q12 | 版本元数据 | `.su-scheduler-docs` 头部 1.6.7 vs 其余 1.6.8；`update.json` changelog 仍写 v1.6.7 | 新增登记（T4 关注） |

## 7. 旧配置样例与预期输出

### 7.1 样例文件

| 文件 | 说明 |
| :--- | :--- |
| `tests/fixtures/legacy/config.txt` | 激活态 master 样例：全部触发器×代表 modifiers×heredoc×注释/空行×无修饰符行 |
| `tests/fixtures/legacy/config.example.txt` | 安装器 genesis 模板（`customize.sh` L52-191 逐字节）——含 `--boot` 文档示例（其实现状态见 Q10） |
| `tests/fixtures/legacy/expected/*.txt` | 机器推导 golden（真实函数执行结果） |
| `tests/fixtures/legacy/tools/derive-goldens.sh` | golden 复现器（bash，从生产脚本提取函数） |

### 7.2 预期输出摘要（golden 实证节选）

**parse_modifiers**（`expected/parse_modifiers.txt`）：
```
LINE: 08:30 logcat -c; : --notify-end --msg="Logs cleared"
  notify_start=0 notify_end=1 delete_after=0 interactive=0 use_termux=0 run_once_now=0
  custom_msg="Logs cleared"
LINE: 14:30 echo "Run me now"; : --run-once-now --notify
  notify_start=1 notify_end=1 delete_after=0 interactive=0 use_termux=0 run_once_now=1
```

**extract_command**（`expected/extract_command.txt`）：
```
LINE: boot pkg update && pkg upgrade -y; : --termux
CMD: pkg update && pkg upgrade -y
LINE: 09:15 python <<EOF; : --termux --notify
CMD: python <<EOF        ← 启动路径（未重组）下 heredoc 只取头部
```

**heredoc 重组**（`expected/heredoc-reconstruction.txt`）：
```
HEADER: weekly:7:2300 sh <<EOF; : --notify --msg="Weekly backup"
RECONSTRUCTED: weekly:7:2300 sh 'echo "Weekly maintenance"
df -h
'; : : --notify --msg="Weekly backup"
```
（可见 ` : : ` 双冒号工件；后续 `extract_command` 输出残留尾部 `'; :`/`:`。）

**--run-once-now 修剪**（`expected/run-once-now-prune.txt`）：
```
ORIGINAL: 14:30 echo "Run me now"; : --run-once-now --notify
PRUNED:   14:30 echo "Run me now"; : --notify
```

**状态键**（`expected/state-keys.txt`）：weekly/monthly/yearly/nweekly/nmonthly 键结构
与 md5 样例（md5 覆盖整行含换行）。

### 7.3 日志/状态示例（观察格式，L3 确认内容）

daemon 启动日志序列（`/data/adb/su-scheduler/su-scheduler.log`）：
```
[2026-08-30 10:00:00] [INFO] 🎬 Su Scheduler Daemon v1.6.8 initialized (PID: 1234)
[2026-08-30 10:00:00] [INFO] 🏁 Startup phase: Executing initialization tasks...
[2026-08-30 10:00:00] [TASK] 🚀 Task [startup_1_1785…] starting: echo "Boot marker written"
[2026-08-30 10:00:01] [INFO] 💓 Daemon pulse detected. Entering main loop. I'm watching you... in a good way!
[2026-08-30 10:00:01] [INFO] 🔥 New configuration detected! Hot reloading presets...
```
任务目录 `tasks/startup_1_1785…/`：`command.txt`、`start_time.txt`、`status.txt`
(`SUCCESS`)、`exec_mode.txt` (`SYSTEM`)、`exit_code.txt` (`0`)、`end_time.txt`、
`output.log`、`pid.txt`。

服务日志 `/data/adb/su-scheduler/events.log`：
```
2026-08-30 10:00:00 - [Service] 🛌 Waking up... System boot detected.
2026-08-30 10:00:00 - [Service] 🔓 Storage decrypted! Proceeding...
2026-08-30 10:00:05 - [Service] ✅ Handover complete. Closing service script.
（daemon 掉线 60s 内）
2026-08-30 10:01:05 - [Service] ⚠️ Daemon not running. (Re)starting...
```

## 8. 回归测试清单

> 契约：**后续任务不得改变 §5 各能力的输入/输出/状态语义**。每条测试给出
> 输入、期望输出/状态与验证途径。`状态`列：`建`=本任务已建（golden），
> `待`=后续任务执行（P0 T1/T3 或 P1 后续）。层面：L1 语法 / L2 host 解析 /
> L3 设备冒烟 / L4 构建。

| ID | 层面 | 能力/对象 | 输入 | 期望输出 / 状态 | 状态 |
| :-- | :-- | :--- | :--- | :--- | :-- |
| R-01 | L1 | 全部 shell 脚本 | `sh -n`/`bash -n`（按 AGENTS §4.1） | 全 [PASS] | 待 |
| R-02 | L2 | 行级解析 | fixture 每行（含注释/空白） | 修剪后与 golden 逐字节一致 | 建 |
| R-03 | L2 | parse_modifiers | fixture 每行 | 6 个 flag + `custom_msg` 与 `expected/parse_modifiers.txt` 一致 | 建 |
| R-04 | L2 | extract_command | fixture 每行 | 与 `expected/extract_command.txt` 一致 | 建 |
| R-05 | L2 | heredoc 重组 | fixture 两个 heredoc 块 | 重组行（含 ` : : ` 工件）与 golden 一致 | 建 |
| R-06 | L2 | --run-once-now 修剪 | `14:30 …; : --run-once-now --notify` | `PRUNED` 行与 golden 一致；修剪后行保留于文件 | 建 |
| R-07 | L2 | 状态键结构 | 5 类进阶触发行 | 键结构与 `expected/state-keys.txt` 一致 | 建 |
| R-08 | L2 | CLI add | `add 08:00 "logcat -c; : --notify"` | 追加 `08:00 logcat -c; : --notify`，exit 0 | 待 |
| R-09 | L2 | CLI add（怪癖） | `add weekly:1:0800 echo hi` | exit 1 + `Invalid trigger 'weekly10800'`（锁定 Q2） | 待 |
| R-10 | L2 | CLI list | fixture 上 `list` | 打印匹配行且**必含** “No active missions matching …”（锁定 Q3） | 待 |
| R-11 | L2 | CLI log | `log -n 5` | 输出为 `tail -n 20` 等价（锁定 Q1） | 待 |
| R-12 | L2 | CLI remove | `remove <行号>` / `remove <pattern>` | 行号：`sed -i "${1}d"` 删行 + 提示；pattern：去冒号计数+整行删 | 待 |
| R-13 | L2 | CLI task-output | 有 output.log / 有 shells .out / 均无 | 三段行为（锁定 Q4 生效版） | 待 |
| R-14 | L2 | CLI audit | 新装空 audit.log | 表头+空（锁定 Q7） | 待 |
| R-15 | L2 | boot 启动路径 | `boot <cmd>` 行 | 启动扫描执行 `startup_*`；`status.txt` 转 SUCCESS/FAILED | L3必验 |
| R-16 | L2 | boot+--delete | `boot …; : --delete` | 行**不删除**、每次启动重跑（锁定 Q6） | 待 |
| R-17 | L2 | boot+heredoc | `boot sh <<EOF` | 仅 `sh <<EOF` 头部执行、块体不执行（Q6） | 待 |
| R-18 | L3 | 时间触发 | 设备时钟 +2min 调度 `HH:MM` | 分钟窗口内执行；`tasks/time_…/` + 日志可见 | 待 |
| R-19 | L3 | 进阶调度 | 临时 weekly（当日）+ 状态键 | `advanced_*` 执行；`schedule_state.txt` 键出现；同日不重跑 | 待 |
| R-20 | L3 | heredoc 真实执行 | `09:15 python <<EOF`（设备 sh） | 块体是否多行执行——**决定式记录**（echo 语义环境相关） | 待 |
| R-21 | L3 | --termux 三态 | 未装 Termux / 已装 | 优雅失败（output.log=ERROR… exit 1）或 READY 执行；日志有 ERROR | 待 |
| R-22 | L3 | --notify 链 | `--notify/--notify-start/--notify-end` + 失败任务 | 开始/结束/失败通知日志序列（失败通知无条件，Q11） | 待 |
| R-23 | L3 | --delete | `08:00 …; : --delete` | 执行后配置行消失；`grep -vF` 全文删 | 待 |
| R-24 | L3 | --run-once-now | `14:30 …; : --run-once-now --notify` | `immediate_*` 执行 + 配置行修剪为 golden 形态 | 待 |
| R-25 | L3 | hot reload | 修改配置（不重启） | ≤60s 内新配置生效；日志 hot reload 行 | 待 |
| R-26 | L3 | stop/restart | `stop` / `restart` | stop：瞬态（≤60s 看护重启+boot 重跑）；restart：Alive | 待 |
| R-27 | L3 | status/exit code | `status` | Alive→exit 0 / Dead→exit 1（锁残留提示） | 待 |
| R-28 | L3 | 配置自愈 | 冒烟前后比对 config.txt | 除 --delete/--run-once-now 自身预期变化外逐字节一致 | 待 |
| R-29 | L4 | 构建/版本 | `bash build.sh` + 六处版本比对 | zip 完整；六处版本一致（Q12 备注 docs 1.6.7） | 待 |
| R-30 | L2/L3 | task 管理链 | task-info/task-output/task-kill/history/tasks | 各命令输出与状态工件一致（task-kill 杀子 shell——Q8） | 待 |

## 9. 验收标准对照

| P1-01 验收要求 | 本任务落实情况 |
| :--- | :--- |
| 后续任务不得改变旧配置语义 | §4 锁定行格式/触发器/modifiers/heredoc 语义；§6 登记怪癖作为“现状即标准”；fixtures 不可变输入（`tests/fixtures/legacy/README.md` 约定） |
| 所有旧行为都有明确的输入、输出和状态记录 | §5 十项能力逐一给出 输入/处理/输出/状态记录/怪癖/验证状态；§7 给出样例与机器推导 golden；§8 回归清单逐条含输入与期望输出/状态 |
| 梳理 service.sh、daemon、CLI、配置文件和运行目录 | §2 组件表 + §3 路径/权限表（含 events.log、su-scheduler.log、锁文件、任务目录、shells、audit、schedule_state.txt） |
| 覆盖 boot/日常/周月年/heredoc/--termux/--notify/--delete/--run-once-now/hot reload/stop-restart | §5.1–§5.10 全覆盖（含 nweekly/nmonthly、notify-start/end、msg 子项） |
| 建立旧配置样例和预期输出 | §7：`tests/fixtures/legacy/config.txt`、`config.example.txt`、`expected/*`（机器推导，非手写） |
| 回归测试清单 | §8 R-01..R-30（每项输入/期望输出/状态/验证途径/状态列） |

## 10. L3 设备验证状态与缺口

当前环境**无 adb 设备/模拟器**（`adb devices` 不可用），因此：

- **已锁定（host 可断言）**：L1 语法、L2 全部分析语义（R-02..R-14 中已建部分）、
  全部 golden；
- **L3 待验**：R-15..R-28（设备端执行、分钟对齐、Termux 三态、通知、看护重启、
  heredoc 真实执行、配置自愈）；
- **关键待验判定点**：① heredoc 块体在 mksh/toybox `sh` 下是否真正多行执行；
  ② `stop` 后 60s 内看护重启与 boot 重跑时序；③ `--termux` 三态输出文案。

> 设备可用后执行 `tests/device/smoke.sh`（P0 T3 交付物）或按 §8 逐条 L3 验证，
> 并将结果回填本节与 §8 状态列。