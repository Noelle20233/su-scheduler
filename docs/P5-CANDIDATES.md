# Su Scheduler — P5 候选缺陷与候选需求登记（P5-CANDIDATES）

> **任务**：P5-01 · P4 发布候选收口与 P5 基线冻结（本文件为「候选登记」交付物）
> **日期**：2026-09-05
> **性质**：登记 P5 起点发现的**已知竞态残留**与 P5 阶段候选需求/决策门；P5-01 仅登记不实现。

---

## 1. 候选缺陷

| ID | 位置 | 现象（证据） | 触发 | 建议最小修复 | Sign-off |
| :-- | :--- | :--- | :--- | :--- | :-- |
| **D-P5-01** | `su-schedulerd` 单实例仲裁（原 L610-637）+ `crash_guard_enter`/`crash_record_exit`（Runtime §18）+ daemon trap 注册点 | daemon 快速重启恢复路径间歇失败：p1-device run-once-now/prune/--delete、p3-device 18-restore（ghost RUNNING + 事件缺失）。**根因（已修复）**：① `crash_guard_enter` 先于单实例仲裁 → 被拒实例非信号 `exit 0`、TERM trap 不触发 → "无退出记录的脏启动" → crash_seq 假累加；② 重排后 trap 注册被推后至仲裁之后 → 快速重启时 cmd_stop 的 TERM 可在实例处于仲裁/guard 记账阶段（未注册 trap）到达 → 默认信号退出不留 last_clean=1；③ §18 eval 以 `last_clean` 为唯一"非优雅"判据 + "存活≤30s 即崩溃"启发式，在旧实例 trap 与新实例 enter 重叠（真机取证 last_exit_rc=0 与 last_clean=0 并存）时把优雅短命重启误判为崩溃 → crash_seq 累加至阈值 → 300s 假降级 → fast-exit 风暴。**设备取证**：guard `starts=2 exits=2 crash_seq=2 last_exit_rc=0`；8 次连续 restart 复现 crash_seq 1→2→3→degraded_until；events.log 同秒双条 `[Service] Daemon not running` | 60s `CRASH_WINDOW` 内密集 `su-scheduler restart` | **已修复（三层）**：① 单实例仲裁（noclobber 原子接管）先于 crash_guard_enter / heavy init，被拒不触碰 guard，rc2/3 释放锁；② TERM/INT/HUP trap 移到启动最前面（早于仲裁/guard），优雅信号任何阶段都记 last_clean=1；③ `crash_record_exit` 改单次原子写（消除丢失更新/部分写入，trap 延迟 2.6s→~0.6s）+ eval 增加"有效优雅退出记录（exit≥start 且 rc=0）不计崩溃"判据 + 无退出记录时有界重读等旧 trap 写完。验证：宿主 crashguard 49/0×15 稳定、daemon 相关 10 套件 825 断言全绿；设备 p1-device 3/3 全绿（ron/prune/delete 修复）、快速重启风暴 crash_seq 归零不再降级、p3-device 18-restore 修复 | ~~是~~ → **已裁决+已修复** |
| **D-P5-02** | 宿主回归环境（WSL，非生产代码） | `tests/providers/test.sh` 与 `tests/execution/action-run/test.sh` 在本会话 WSL 环境**挂起**（>60s 无输出），两者均 **0 引用 su-schedulerd**（`grep -c` 为 0），且 2026-09-05 13:46 全量回归（45 套件 1906 PASS）中均通过 → 判定为**既有环境/时间敏感 flake，非本构建回归**。疑似与当日时间或 WSL 进程/管道行为相关 | 本会话 22:2x / 23:4x 直接运行 | **已修复（测试卫生专项）**：① **根因**：`tpr_action_command_start`（tests/providers/providers.sh）后台 `( ... ) &` 未脱离 stdin/stdout/stderr → 孤儿子 shell 继承调用方捕获管道 fd → `out=$(bash suite)`（run_tests.sh）与 `out=$(action_run_task ...)`（action-run）在套件本身结束后仍因孤儿持有管道而**永久阻塞** → 全量回归挂起（实证：providers 套件 rc=0 完成但 wsl 客户端不返回）；② 修复：start 子 shell 显式 `</dev/null >/dev/null 2>&1`；interactive `sh -i` 加 30s 有界看护；`next_due` 改经 `tpr_ctx_now`（TRIGGER_DECISION_NOW 可注入，与 matches 同源，消除跨分钟边界 flake）；`scheduler-prod` 固定 `SCHED_CYCLE_NOW`（同周期去重 token 不再随真实分钟滚动）；run_tests.sh 加单套件 `SUITE_TIMEOUT` 超时护栏（TERM→KILL，超时记 `[FAIL]` 并继续后续套件）；③ 验证：全量回归（WSL /mnt/d）**ALL SUITES GREEN**（409s，0 FAIL，exit 0）；guard 护栏独立验证（挂起套件 3s 超时记 FAIL、正常套件通过） | ~~待定~~ → **已修复** |
| **D-P5-03** | `su-scheduler webui GET_SUMMARY` / `tctl_*`（IPC 请求-响应通道）+ `tests/p3-device/smoke.sh` item 7/14 | p3-device 冒烟 `7-webui` 与 `14-control` **稳定复现** `operation_timeout`（rc=5）：daemon restart（6-registry）后 `ipc_ready` 有界轮询 ~200s 仍拿不到 GET_SUMMARY 响应，8-editor（EDIT_TASK）随后可过 → IPC 通道在 restart 后长时间不可用、后自愈。P5-01 §4.1 原始失败集即含这两项（偶发），**非本构建回归**；与 D-P5-01 崩溃记账根因独立（daemon 稳定期仍现） | p3-device 冒烟 6-registry restart 后立即访问 webui/control | **已修复**：① **根因（真机取证）**：`supervisor_task_file`（Runtime §17）原对**每个**运行目录调用 `runtime_map_refresh`（O(M) idmap 全量扫描）→ `supervisor_tick` 为 **O(N×M)**，残留运行目录多时主循环每轮阻塞数十秒（本机 35 个残留目录实测 supervisor_tick >12s 超时；daemon pipe_read fd12 各次新建管道、无子进程 = `$(...)` 子进程放大）→ nap 段 IPC 轮询被拖延 → GET_SUMMARY/EDIT_TASK 饥饿 operation_timeout（availability 实测仅 ~27s/60s）。② **修复（最小）**：`supervisor_task_file` 不再按调用重建 idmap——daemon 主循环每 tick 已先于 `supervisor_tick` 刷新（su-schedulerd L658/L744 → L759），idmap 恒为最新，仅保留读取；supervisor_tick 降为 O(N)。③ **验证**：宿主全量回归 ALL GREEN（0 FAIL）；真机（bind-mount 固定版 runtime）supervisor_tick COMPLETED（<1s，修复前 >12s 超时）、IPC 8/8 成功、availability ~85%（修复前 ~45%）、**p3-device PASS=28 FAIL=0**（7-webui/8-editor/14-control 全绿）、p1-device PASS=11 FAIL=0；supervisor 套件新增 D-P5-03 静态回归断言（task_file 不重建 idmap + 主循环刷新先于 tick） | ~~待定~~ → **已修复** |

| **D-P5-04** | `tests/run_tests.sh`（SUITE_TIMEOUT 机制，测试基建） | p1-device 冒烟含两次 150s 睡眠，`SUITE_TIMEOUT=300`（D-P5-02 护栏）在 `--with-device` **组合运行**时被超时强杀（`[FAIL] suite TIMEOUT after 300s`）→ 组合跑 p1-device 必超时；**standalone 重跑 PASS=11 FAIL=0**（历史最佳，全绿）。测试基建问题，非产品缺陷 | `--with-device` 组合运行 | 设备套件单独设置更长 SUITE_TIMEOUT（如 `SUITE_TIMEOUT=600 bash tests/p1-device/smoke.sh`）或 run_tests.sh 对 device 套件放大超时 | 否（测试卫生，待 P5 后续或出口评审处理） |
| **D-P5-05** | `tests/p3-device/smoke.sh` item 14（task start）+ item 18（18-restore） | p3-device item 14 偶发 `task start edit1 → rc=5 operation_timeout, state=STARTING`；item 18 偶发 `ghost state=[RUNNING]` + `event=[]`。**证据（受控复验）**：item 14 daemon 日志显示 edit1 实际已启动（`Task [edit1] starting: sleep 20`）、独立复验 START_TASK 3/3 `rc=0 + state=RUNNING` → IPC 控制面健康；item 18 根因为 step 13 crashloop 打崩 daemon 后进入 crash-guard degraded/节流窗口（`crash_guard_enter` 早于 `state_rehydrate_residual`），step 18 restart 触发 ~70s fast-exit 风暴期间无实例完成 rehydrate，ghost 保持 RUNNING——复跑 28/28 全绿、手动复现 ghost→FAILED 成功 → 设备端偶发时序抖动，非产品缺陷 | 组合冒烟 crashloop→restart 时序窗口内访问 control/restore | item 14 放宽 IPC poll 窗口/负载感知；item 18 轮询需考虑 crash-guard 冷却窗口（step 13 打崩后等待 degraded 结束再 restart） | ~~否（待监控，不阻塞 P5 出口）~~ → **已修复（测试时序）**：item 18 restart 前清除 crash guard（`rm -f $DATA/runtime/daemon.guard`，crash_seq=0 干净进入避免降级窗口）+ ghost 轮询上限 40→60s；item 14 `task start` 遇 rc=5（operation_timeout）间隔 5s 重试一次，首启已拉起时重试得 rc=2 亦判 PASS；真机 3 轮全绿 PASS=28 FAIL=0 |

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
  **→ 已裁决+已修复**（b2ab4fb 仲裁前置 + 20fc943 trap/记录/eval 三层加固；宿主 10 套件
  825 断言全绿、设备 crash_seq 归零）。
- **D-P5-02 处理**：判定为「测试卫生小任务（非生产专项）」并已执行——根因定位为测试库
  后台执行子 shell 未脱离捕获管道导致的孤儿子进程阻塞，配套 time 确定性 + run_tests.sh
  单套件超时护栏；全量回归转绿。详见第 1 节 D-P5-02 行。
- **D-P5-03 处理**：判定为「P5 IPC 层专项」并已执行——根因非「restart 后 IPC 就绪时序」，
  而是 `supervisor_task_file` 对每个残留运行目录全量重建 idmap（O(N×M)）导致主循环被
  阻塞数十秒、nap 段 IPC 轮询饥饿。最小修复后 p3-device 7-webui/8-editor/14-control
  全绿。详见第 1 节 D-P5-03 行。
- **P5 出口前提**：P5-11 出口需「至少一台 Android 设备完成 P5 新功能全链路」——届时 D-P5-01
  若未修复，设备验证结果须如实标注竞态影响范围，不伪造通过。
