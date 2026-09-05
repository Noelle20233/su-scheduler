# Su Scheduler — P5 候选缺陷与候选需求登记（P5-CANDIDATES）

> **任务**：P5-01 · P4 发布候选收口与 P5 基线冻结（本文件为「候选登记」交付物）
> **日期**：2026-09-05
> **性质**：登记 P5 起点发现的**已知竞态残留**与 P5 阶段候选需求/决策门；P5-01 仅登记不实现。

---

## 1. 候选缺陷

| ID | 位置 | 现象（证据） | 触发 | 建议最小修复 | Sign-off |
| :-- | :--- | :--- | :--- | :--- | :-- |
| **D-P5-01** | `su-scheduler-runtime` `crash_guard_enter`（~L2409）/`crash_record_exit`（TERM trap）+ `su-schedulerd` 75-78、658-659 | daemon 快速重启恢复路径间歇失败：p1-device run-once-now/prune/--delete（legacy 修剪管道）、p3-device 18-restore（ghost RUNNING + 事件缺失）、偶发 14-control/7-webui `operation_timeout`。**根因**：新旧 daemon 对 `daemon.guard` 文件写竞争（无串行化）→ crash_seq 累加 → 300s 降级窗口 fast-exit（不跑 main loop/不执行 ron/不修剪/不再水合）→ watchdog 反复拉起 → 崩溃循环。**证据**：6 轮冒烟 6 轮命中；events.log `[Service] Daemon not running` 按日 9/3=1101、9/4=6、9/5=5234；设备 daemon sha256 与仓库 HEAD 逐字节一致 | 60s `CRASH_WINDOW` 内密集 `su-scheduler restart`（boot→time→ron→delete 连续用例） | `crash_guard_enter`/`crash_record_exit`/`cmd_stop` 间 guard 写竞争加串行化（或旧 daemon TERM trap 完成后再允许下一实例接管）；降级期抑制 watchdog 风暴侧 | **是**（P4-11 同类残留，P5 后续任务或决策门裁决） |

> **判定**：D-P5-01 为 **P4-11（284b337）已知同类竞态残留，非本构建回归**。P4-11 只修了
> CLI 侧（等待退出、严格单实例），未关闭 guard 文件写竞争与降级期 watchdog 风暴侧。

## 2. P5 候选需求（源自 P4-HANDOVER §5 + P5 TaskIndex，仅登记不实现）

| 候选 | 建议入口 | P5 对应任务 |
| :-- | :-- | :-- |
| Condition 运算符扩展（`<`/`>`/`<=`/`>=`/`contains`） | `cond_grammar_ok`/`cond_eval` 文法 + fixtures | P5-02 / P5-03 |
| 新 Trigger 家族（oneshot/delay/interval/cron/boot_completed） | Task v2 schema + Registry 接线 | P5-04 / P5-05 |
| WebUI 实时状态 / 依赖视图 / 批量操作 | 只读消费扩展（不经新 IPC op） | P5-06 / P5-07 |
| CLI/审计增强（task-info Trigger 解析、下次触发时间、决策原因） | 只增字段或附加行 | P5-08 |
| 设备矩阵扩展（KernelSU×A12-15、Magisk×A16、APatch×A16 等 14 格） | `docs/P5-BASELINE-COMPATIBILITY.md` §4 | P5-10 |

## 3. 决策门（Sign-off 请求）

- **D-P5-01 修复时点**：P5 后续任务（建议 P5-03/P5-05 实现期一并处理 guard 写竞争）或独立
  修复任务；需人工裁决是否在 P5 内安排专项修复。P5-01 不越界修改。
- **P5 出口前提**：P5-11 出口需「至少一台 Android 设备完成 P5 新功能全链路」——届时 D-P5-01
  若未修复，设备验证结果须如实标注竞态影响范围，不伪造通过。
