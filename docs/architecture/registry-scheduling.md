# 调度接管架构 ADR（P3-03）：Registry 正式调度源

> **状态**：已接受（P3-03 冻结）
> **作者/日期**：P3-03 · 2026-09-01
> **关联**：`docs/P3-03.md`（执行记录）、P3-02（config-authority ADR）、
> P2-05/06（Trigger/ActionProvider）、P2-07/12/13（State/Supervisor）

## 问题

P2 阶段 Registry 只是 Shadow Mode（旁路比对/日志），真正的执行仍由 daemon 主
循环扫描 config.txt 驱动——「双轨」状态导致两个事实源。P3-03 决定结束双轨：
**Registry 成为正式调度数据源**。

## 决策（D1–D10）

### D1 正式调度链（唯一执行路径）

RUNTIME_LOADED=1 时，daemon 主循环只经 `scheduler_tick` 获取任务：

```
Registry Task ──trigger_decide(TriggerProvider)──▶ 到期？
    └─due=Y─▶ action_run(ActionProvider) ──▶ Runtime State ──▶ Supervisor
```

禁止再出现：Registry 只做日志、legacy config 扫描才真正执行。

### D2 双模式数据源

- **managed**（task-config/MANAGED 存在）：`sched_snapshot_managed` 从
  task-config/*.task 重建快照（校验 schema_version=2 / id==文件名 / trigger
  非空）；**不再重新扫描 config.txt**。
- **legacy**（无 MANAGED）：`registry_reload(config.txt)`（KEPT 回退最后有效
  快照）——config.txt 仍是权威，Registry 是其投影（与 P2-03 shadow agree 一致）。
- **fallback**（RUNTIME_LOADED=0）：daemon 既有 config.txt 扫描原样（C2）。

### D3 原子 reload（配置变更）

- reload 以**源指纹（md5）**判定是否变化（`scheduler/source.md5`），仅变化才
  重建——避免每 tick 无谓重建，且**不产生重复执行**。
- 重建 = 写新快照 + 原子 flip `current` 指针（tmp+mv）；损坏/无效 → KEPT
  （current 不动，任务集保留最后有效）。

### D4 同周期去重（同一 Task 至多一次）

- `scheduler/cycle-<YYYYMMDDHHMM>` 分钟级标记：同周期已执行 id 跳过。
- 未到期任务不标记（配置变更后同一周期可正常到期执行一次）。

### D5 单任务错误隔离

- `scheduler_tick` 逐任务执行，任何 Task 错误只记 audit、`continue`，**不中止
  tick、不退出 daemon**（与 §12 state_sync 同构的容错哲学）。

### D6 后置语义保留

- `--run-once-now`：执行后 registry 置 0 +（managed）tcfg_set_field /
  （legacy）config.txt 行修剪；
- `--delete`：执行后移除（managed）task-config + 快照 /（legacy）config.txt 行；
- heredoc / Termux / Interactive / notify / msg 经 `action_run` 原样透传
  （任务文件字段即执行参数，不重建第二执行器）。

### D7 旧运行目录 / 旧运行 ID 兼容

- 执行落 `tasks/<id>`（canonical id）；idmap（§9）双向映射保留；
- 旧 CLI（task-info/task-output/task-kill）仍按既有语义查询/终止（P2-04 边界）。

### D8 快照移除的任务继续监督（要求 9）

- 执行时把任务文件 stash 到运行目录 `task.v2`；
- `supervisor_task_file` 在 registry + idmap 均 miss 时**兜底读取 task.v2**——
  即使任务从新快照移除，已运行的旧任务仍被监督/收尾，不被无声丢弃。

### D9 审计（调度来源日志）

- `<base>/scheduler/audit.log`：reload / exec / tick / boot 每事件一条
  `|` 分隔记录（mode/rc/task/trigger 等）——调度来源可追溯。

### D10 不变量

1. RUNTIME_LOADED=0 时 daemon 行为与 P2 完全一致（fallback 文本原样）；
2. config.txt 行格式零变更（C4）；
3. 不引入 WebUI / Watchdog / Dependency（P3 边界，C5）。

## 后果

- 正向：单一事实源（Registry），触发/执行/状态/监督全链路统一；双轨结束；
  快照移除的任务仍受监督；单任务故障不拖垮 daemon。
- 代价：RUNTIME_LOADED=1 下 legacy 与 managed 的 Registry 来源不同，需保证
  legacy 投影与 config.txt 一致（shadow/golden 套件守护）；审计日志磁盘占用
  （`runtime_protect` 已限制其大小）。
- 回退：若接线有缺陷，移除 daemon 的 scheduler_tick 调用即回到 P2 双轨语义
  （RUNTIME_LOADED=1 分支仍保留 legacy 扫描文本于 fallback）。

## 附：决策记录

- 2026-09-01：P3-03 建立本 ADR（D1–D10 冻结）。
