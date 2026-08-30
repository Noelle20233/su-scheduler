# tests/fixtures/legacy — 旧配置行为基线 fixtures

> 由 **P1-01：建立现有行为基线** 交付。锁定 Su Scheduler **v1.6.8**（Git `main`
> @ 3fe7631）的既有配置语义与解析行为，作为后续任务（P1/P0 修复、T1 golden、
> T3 设备回归）的对照基准。**不得**以"应该怎样"修改这些文件；任何改动必须先
> 重新推导 golden 并确认差异是变更意图本身。

## 目录结构

| 路径 | 内容 |
| :--- | :--- |
| `config.txt` | **激活态 golden 输入**：覆盖全部触发器（`boot`/`HHMM`/`HH:MM`/`weekly:`/`nweekly:`/`monthly:`/`nmonthly:`/`yearly:`）、全部 modifiers（`--notify*`/`--msg`/`--termux`/`--delete`/`--run-once-now`/`--interactive`）、heredoc 块、无修饰符行、注释与空行。 |
| `config.example.txt` | **安装器 genesis 模板**：`customize.sh`（L52–L191 的 heredoc 内容）首次安装时写入 `/sdcard/Documents/su-scheduler/config.txt` 的完整文案，逐字节复制。 |
| `expected/` | **机器推导的 golden 输出**（不可手写；由 `tools/derive-goldens.sh` 生成）： |
| `expected/parse_modifiers.txt` | `parse_modifiers()` 对 `config.txt` 每条激活行的 flag 结果（daemon 全局变量）。 |
| `expected/extract_command.txt` | `extract_command()` 对每条激活行剥离 modifiers 后的命令。 |
| `expected/heredoc-reconstruction.txt` | 主循环 heredoc 重组（`trigger cmd '<body>'; : <mods>`）与重组后行的再解析结果。 |
| `expected/run-once-now-prune.txt` | `--run-once-now` 执行后配置行的修剪结果（sed 流水线）。 |
| `expected/state-keys.txt` | `schedule_state.txt` 的状态键结构（weekly/monthly/yearly/nweekly/nmonthly 的 md5 键格式）。 |
| `tools/derive-goldens.sh` | 复现器：从 `system/bin/su-schedulerd` 提取**真实** `parse_modifiers`/`extract_command` 并执行。 |

## 推导方法（golden 的来源）

`tools/derive-goldens.sh` 不做任何"期望语义"假设：

1. 用 `sed` 从 `system/bin/su-schedulerd`（基线 v1.6.8）按注释标记切出
   `parse_modifiers()` 与 `extract_command()` **原文**并 eval 加载；
2. 逐行读取 `config.txt`（跳过注释/空行），调用真实函数；
3. heredoc 重组、`--run-once-now` 修剪、advance 状态键分别按 daemon
   主循环/`should_run_advanced_schedule()` 的**原表达式**复刻。

重新生成：

```bash
bash tests/fixtures/legacy/tools/derive-goldens.sh   # 仓库根目录执行
git diff tests/fixtures/legacy/expected/             # 审查变更是否属于意图
```

## 环境注意事项（基线事实）

- **行尾**：仓库以 LF 存储（`git ls-files --eol` 显示 `i/lf`）；Windows 检出
  （`core.autocrlf=true`）显示 CRLF。推导脚本与 host harness 统一 `tr -d '\r'`
  处理，**这不改变基线语义**；但若 zip 在 CRLF 检出环境构建，模块内脚本将带
  CRLF 安装到设备，与 LF 基线存在差异（记录于 `docs/phase-1-baseline.md`）。
- **heredoc 的 `\n`**：daemon 用 `multiline_cmd="${multiline_cmd}${block_line}\n"`
  拼接（POSIX 双引号内 `\n` 为字面量）。该字面量是否在后续 `echo` 时变成真实
  换行取决于 shell 的 echo 实现（dash/mksh 解释、bash/GNU echo 不解释）——即
  heredoc 行为在设备端 `#!/system/bin/sh`（mksh）与 host bash 下可能不同，属
  基线环境相关性，需 T3/L3 设备实测确认。
- **golden 由 GNU bash 5.3 推导**：`expected/*.txt` 是"bash 环境下真实函数的
  输出"，同时是解析语义的稳定快照；设备端差异不影响本快照的锁定价值。
- **文件尾无换行（刻意）**：`config.txt` 末行 `22:00 echo "No modifiers at all"`
  故意**不带结尾换行**——daemon 用 `while IFS= read -r line <&3 || [ -n "$line" ]`
  （`su-schedulerd` L584/L623）读取，该 guard 保证无换行末行仍被处理；golden
  生成器同样带此 guard（`derive-goldens.sh` 注释 0）。这是被锁定的边界行为。

## 使用约定（后续任务）

- T1（P0）解析 golden：以上述 `expected/*` 为断言目标，把 `config.txt` 视为
  不可变输入；
- T3（P0）设备冒烟：`config.txt` 中时间触发行需按设备时钟换算（另行提供
  `+2min` 变体），boot/heredoc/termux 行可直接复用；
- 任何修复（T2）若触碰上述表达式，必须同步重新推导 golden 并在提交说明中
  指出语义差异，否则视为破坏基线（C4 违规）。