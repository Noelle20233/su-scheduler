# Trigger Decision 层（P1-07）

旧调度能力经统一 TriggerProvider 运行：每轮从 **Canonical Task Registry（P1-06）**
快照取任务，按触发器前缀选 Provider，只判断「是否执行」，输出决策（id + cause）。

## 组成与数据流

```
config.txt ─(P1-05 adapter)─> Registry 快照 ─(trigger_decision_cycle)─> TriggerProvider ─> 决策行
                                   ▲                                     (matches/只判断)
                                   └────────────（唯一任务数据源；无直接 config 扫描）
```

- `trigger_decision_cycle`：每轮遍历 `registry_task_ids`（当前快照），对每个任务按
  触发器前缀分发到 boot / time / advanced Provider 的 `matches`；命中则输出
  `id=<id> cause=<cause>` 一行。**只决策**，不执行、不写任务状态。
- 副作用归决策层：advanced 命中后 `trigger_decision_mark` 写入去重键（与 daemon
  "检查+记录同轮完成"等价）→ 同一周期内不重触发。

## 语义镜像（P1-01 §5，验收"现有 cron 行为不变"）

| 语义 | 实现 |
| :--- | :--- |
| 分钟级 | time 匹配 = `NOW == 触发归一`（`TRIGGER_DECISION_NOW` 注入可测；缺省 `date +%H%M`）——每轮一个 NOW = 每分钟一轮 |
| boot 启动 | `TRIGGER_BOOT_CONTEXT=1` 的轮：boot 任务决策；**同时**该轮对时间任务做当前分钟匹配（镜像 daemon 启动后首个主循环迭代） |
| `--boot` | 标志保留在任务（`action.boot=1`），**不**额外触发 boot（daemon Q10 镜像——`boot` Provider 只响应 `trigger=boot`）；时间匹配仍正常 |
| `--delete` | 标志保留（`action.delete=1`），决策层不删除任务（删除属接线层/daemon 语义） |
| `--run-once-now` | 任何任务带该标志 → 本轮立即决策（`cause=run-once-now`），标志保留（修剪属接线层） |
| advanced | weekly/nweekly/monthly/nmonthly/yearly 镜像 daemon `should_run_advanced_schedule`：日/星期匹配 + 时间>=目标 + 状态文件去重键**读取**；命中后 mark 写键 → 周期内不重触发 |
| 未知触发器 | 无对应 Provider → 不决策（daemon 不匹配即不执行） |

## 验收对应

1. **旧配置经 TriggerProvider 触发**：boot/time/advanced 各家族走对应 Provider
   （`trigger_decision_provider` 选择，测试 §1/§2）。
2. **Provider 只判断是否执行**：advanced `matches` 只读状态文件（测试断言匹配前
   状态文件不存在/空、匹配不写键——§2/§3）；决策副作用（mark 写键）在决策层。
3. **Provider 不负责进程健康/恢复**：触发 Provider 区段无 `kill`/`/proc`/后台
   `&`（测试 §8 区段断言）；决策库无 health/recovery 字样。
4. **现有 cron 行为不变**：轮语义按 P1-01 §5 逐条镜像（上表），`--boot`/`--delete`/
   `--run-once-now` 标志保留且决策不额外/提前消耗；minute 轮由 NOW 注入确定性测试。

## 运行

```bash
bash tests/scheduling/trigger-decision/test.sh   # 期望：全 [PASS]，exit 0
bash tests/_run_all.sh                            # 全 P1 套件聚合回归
```

> 依赖顺序（source）：`providers/lib.sh` → `providers/providers.sh` →
> `task-registry/lib.sh` → `legacy-adapter/adapter.sh` → 本 `lib.sh`。