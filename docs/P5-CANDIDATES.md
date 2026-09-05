# Su Scheduler — P5 候选缺陷与候选需求登记（P5-CANDIDATES）

> **任务**：P5-01 · P4 发布候选收口与 P5 基线冻结（本文件为「候选登记」交付物）
> **日期**：2026-09-05
> **性质**：登记 P5 起点发现的**已知竞态残留**与 P5 阶段候选需求/决策门；P5-01 仅登记不实现。

---

## 1. 候选缺陷

| ID | 位置 | 现象（证据） | 触发 | 建议最小修复 | Sign-off |
| :-- | :--- | :--- | :--- | :--- | :-- |
| **D-P5-01** | `su-schedulerd` 单实例仲裁（原 L610-637）+ `crash_guard_enter`（原 L75 调用点） | daemon 快速重启恢复路径间歇失败：p1-device run-once-now/prune/--delete、p3-device 18-restore（ghost RUNNING + 事件缺失）、偶发 14-control/7-webui `operation_timeout`。**根因（已修复）**：`crash_guard_enter` 先于单实例仲裁执行 → watchdog 与 CLI 同时拉起实例时，被拒实例以非信号 `exit 0` 结束、TERM trap 不触发 → 留下"无退出记录的脏启动"（last_start + last_clean=0 无 last_exit）→ 下一实例判为崩溃 → crash_seq 假累加 → 300s 假降级 → fast-exit 风暴。**设备取证**：guard `starts=2 exits=2 crash_seq=2 last_exit_rc=0`（两次优雅退出被计为 2 次崩溃）；events.log 同秒双条 `[Service] Daemon not running`（≥2 个 watchdog 循环）；当日 8711 条 | 60s `CRASH_WINDOW` 内密集 `su-scheduler restart` | **已修复**：仲裁（noclobber 原子接管，`set -C : >`）先于 crash_guard_enter / heavy init；被拒/竞态落败实例在触碰 guard 前退出；rc2/3 早退释放已占锁；空锁让位轮询不立即 rm。`service.sh`/Runtime §18 函数零改动 | ~~是~~ → **已裁决+已修复**（P0 最小修复） |
| **D-P5-02** | 宿主回归环境（WSL，非生产代码） | `tests/providers/test.sh` 与 `tests/execution/action-run/test.sh` 在本会话 WSL 环境**挂起**（>60s 无输出），两者均 **0 引用 su-schedulerd**（`grep -c` 为 0），且 2026-09-05 13:46 全量回归（45 套件 1906 PASS）中均通过 → 判定为**既有环境/时间敏感 flake，非本构建回归**。疑似与当日时间（providers nweekly 用例，P4-06 已注日期敏感）或 WSL 进程/管道行为相关 | 本会话 22:2x / 23:4x 直接运行 | 复跑定位 + 时间/环境隔离修复；D-P5-01 修复的回归验证改为"daemon 相关 8 套件 + state-machine + p4-dependency 共 662 断言全绿" | 待定（非本任务范围） |

> **判定**：D-P5-01 为 **P4-11（284b337）已知同类竞态残留，非本构建回归**，已于本次 P0
> 最小修复关闭（见 §1 行内"已修复"说明）；D-P5-02 为独立的环境层候选缺陷，不影响
> D-P5-01 修复结论。

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
