# tests/fixtures/task-v2 — 内部 Task Schema v2 fixture 样例

> 由 **P1-02：定义内部 Task Schema v2** 交付。锁定的对象模型规范见
> `docs/architecture/task-schema-v2.md`，字段校验规则见
> `docs/architecture/task-schema-v2-validation.md`。
> 本目录是**机器生成的合法 Task 样例**（schema_version=2），来源为 P1-01 的
> legacy 基线 fixture（`tests/fixtures/legacy/config.txt`），转换使用
> `system/bin/su-schedulerd` v1.6.8 的**真实** `parse_modifiers`/`extract_command`
> 函数——与 P1-01 golden 同源。

## 目录结构

| 路径 | 说明 |
| :--- | :--- |
| `samples/*.task` | 17 个合法 Task 样例（每任务一个文件，`key=value` 文本） |
| `tools/derive-task-fixtures.sh` | 复现器：从 legacy fixture 重新生成全部样例 |

## 转换矩阵（legacy 行/块 → Task 样例）

> 行号 = `tests/fixtures/legacy/config.txt` 物理行号（注释/空行计入，与 P1-01 一致）。

| legacy 行/块 | 样例文件 | 关键字段（要点） |
| :--- | :--- | :--- |
| L11 `boot echo …; : --notify` | `t11_boot.task` | trigger=boot；notify_start=1, notify_end=1 |
| L12 `boot sh; : --interactive` | `t12_boot.task` | interactive=1 |
| L13 `boot pkg update && pkg upgrade -y; : --termux` | `t13_boot.task` | termux=1 |
| L16 `08:30 logcat -c; : --notify-end --msg="Logs cleared"` | `t16_0830.task` | notify_end=1；action.msg=`Logs cleared` |
| L17 `0830 echo "Daily ping" >> /sdcard/ping.log` | `t17_0830.task` | 无修饰符，全 0 |
| L20 `weekly:1:0800 …; : --notify-start` | `t20_weekly10800.task` | trigger 原文保留；notify_start=1 |
| L21 `nweekly:2:5:1400 …` | `t21_nweekly251400.task` | 无修饰符 |
| L24 `monthly:01:0000 …; : --notify` | `t24_monthly010000.task` | notify 双端 |
| L25 `nmonthly:3:15:1200 …; : --msg=…` | `t25_nmonthly3151200.task` | msg=`Quarterly done` |
| L26 `yearly:12:25:0800 …; : --delete --notify` | `t26_yearly12250800.task` | delete=1；notify 双端（yearly 实现格式 Q9 原文保留） |
| L29 `14:30 …; : --run-once-now --notify` | `t29_1430.task` | run_once_now=1；notify 双端 |
| L30 `08:00 …; : --delete` | `t30_0800.task` | delete=1 |
| L31 `10:00 …; : --interactive` | `t31_1000.task` | interactive=1 |
| L32 `boot …backup.sh; : --delete` | `t32_boot.task` | delete=1 **但 trigger=boot（legacy 不自毁，Q6 原样）** |
| 块 35-37 `09:15 python <<EOF; : --termux --notify` | `t35_0915.task` | source.type=block；action.command 含重构残留（P1-01 golden） |
| 块 39-42 `weekly:7:2300 sh <<EOF; : --notify --msg=…` | `t39_weekly72300.task` | source.line=39-42；notify 双端；msg |
| L45 `22:00 echo "No modifiers at all"` | `t45_2200.task` | 无修饰符；末行无换行边界（P1-01 锁定） |

## 保真声明（不可更改）

1. **id 派生**：`t<行号>_<trigger_norm>`（norm = 去冒号，同 daemon L650）；
2. **action.command** = `extract_command` 结果**原文**（含怪癖残留：heredoc 重构后的
   `'; :` 残留、字面 `\\n` 转义、boot heredoc 头部形式等——见
   `docs/phase-1-baseline.md` §6 Q5/Q6）；
3. **flags** = `parse_modifiers` 结果（P1-01 `expected/parse_modifiers.txt` 一致）；
4. **source.raw** = legacy 原文（转义存储；heredoc 块不含 EOF 行，块体间为**真实换行**、
   存储转义为 `\n`；而 `action.command` 内的**字面** `\n`（daemon L641 拼接结果）转义为
   `\\n`——两种形态含义不同，解码器须区分）；
5. **runtime.state** 使用 P1-03 规范初态 `PENDING`（enabled=1 默认态；P1-02 过渡值
   `idle` 已废弃，映射见 `docs/architecture/task-state-machine.md` §7）；
5. **怪癖禁止修正**：boot+`--delete` 不自毁、yearly 实现格式、`--boot` 保留标志等
   一律照录（Schema §8.3）。
6. **编辑纪律**：改动 `tests/fixtures/legacy/config.txt` 后必须重跑生成器并 diff：
   ```bash
   bash tests/fixtures/task-v2/tools/derive-task-fixtures.sh
   git diff tests/fixtures/task-v2/samples/
   ```
   差异须属于意图内的语义变化；否则视为破坏 P1-01/P1-02 基线。

## 与校验规则的关系

每个样例都是 `docs/architecture/task-schema-v2-validation.md` §2 矩阵的**合法**
实例（全部字段合法、无隔离）。后续加载器实现（接线任务）必须以本批样例为
**正例集合**，以矩阵中的“非法值（例）”列构造反例集合（负例），验证
P3/P4（绝不退出、绝不清空）。

## 生成环境

- host：bash（GNU 5.x）+ sed/grep/awk/cut（C3 允许的测试工具）；
- 仓库行尾：LF（Windows 检出 CRLF 时生成器以 `tr -d '\r'` 归一，语义不变）；
- 不依赖 jq/Python/Node.js（P1-02 约束）。