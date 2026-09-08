# Su Scheduler — Trigger Schema v2（P5-04 ADR D41–D45）

> **任务**：P5-04 · 新 Trigger Schema 与持久化
> **状态**：已接受（P5-04 冻结）。在既有 Task v2 `trigger=` 字段（boot/time/advanced 家族）
> 之上**新增** 5 个 Trigger 家族；仅 Managed（Task v2）模式；Legacy `config.txt` 只读兼容
> （B16）。
> **配套实现**：Runtime `tcfg_editor_trigger_ok`（L4544 扩展）+ 新辅助函数；调度接线在
> P5-05（`trigger_decide`/Provider），本 ADR 只冻结 schema。
> **参考**：docs/P5-04.md；docs/architecture/task-schema-v2.md；provider-contracts.md。

---

## D41 新 Trigger 家族格式（冻结）

`trigger=` 字段沿用「冒号前缀家族名 + 参数」紧凑格式（同 `weekly:`/`nmonthly:`），
值存原文，**不新增存储字段**（派生字段不存储契约不变，读取时现算）。

| 家族 | `trigger=` 格式 | 参数校验 | 语义 |
| :-- | :-- | :-- | :-- |
| `oneshot` | `oneshot:<HHMM>` | 4 位数字，HH<24、MM<60 | 一次性定时，到点执行后自动移除（等价持久 delete） |
| `delay` | `delay:<MIN>` | 纯数字 1–1440 | 相对延迟，创建/启用后 MIN 分钟执行一次 |
| `interval` | `interval:<MIN>` | 纯数字 1–1440 | 每 MIN 分钟执行一次 |
| `cron` | `cron:<m> <h> <dom> <mon> <dow>` | 5 段，见 D42 | 标准 cron 语法（分钟级） |
| `boot_completed` | `boot_completed` | 无参数精确匹配 | boot 完成后触发一次（区分 boot=模块加载期） |

- **时区**：系统本地时区（与既有 Provider 一致）。
- **精度**：分钟级（与 `scheduler_tick` 周期一致）；interval/delay 单位分钟；秒级不在 P5 范围。

## D42 cron 字段校验规则（冻结）

`cron:<min> <hour> <dom> <mon> <dow>` 五段空格分隔。每段允许 `*` / `*/<step>` /
`a,b,c` 逗号列表 / 单个纯数字；数值范围 min 0-59、hour 0-23、dom 1-31、mon 1-12、
dow 0-6。`*/0` 拒绝（除零）。任何非法字符/段数不足/越界 → 校验期拒绝（写盘前，
旧配置逐字节不变，B9 原子性）。

## D43 与 run-once-now / `--delete` 关系（冻结）

- `action.run_once_now` / `action.delete` 语义不变（决策短路 + 执行后修剪）。
- oneshot 家族默认等效「执行即删」；oneshot 触发器 + `action.delete=0` 时由 P5-05 决策
  （建议：oneshot 执行后置 delete=1，保证一次性语义）。
- 既有 time/advanced 家族不受影响。

## D44 与 Dependency / Condition 顺序（冻结）

- 触发决策（`trigger_decide`）→ 依赖门控（`sched_gate_check`）→ 条件门控（`sched_cond_check`）
  → 执行（`action_run`）。新 Trigger 只产出 `due=Y`，顺序不变。
- interval/cron 周期性触发 + 依赖未满足 → WAITING（不 mark cycle），解除后同窗口至多执行一次。

## D45 Legacy 只读兼容（冻结）

- 新家族仅 Managed（Task v2），经 `tcfg_new_task`/`tcfg_apply_task` 创建。
- `legacy_adapter_parse`、`sched_remove_task`/`sched_prune_ron` legacy 分支零改动（B16）。
- Legacy 配置逐字节兼容由 `tests/legacy/golden.sh` 持续锁定。

## 8. 交叉引用：候选第 6 家族 `chain`（P6-05，追加不重写）

- P6-05 DAG 裁决（`docs/architecture/dag-schema-v1.md` **D47**，**DRAFT 待人工批准**）提案
  新增裸关键字家族 `trigger=chain`：链内节点**无自主时间触发**，仅由链引擎在依赖边 frontier
  满足时释放执行；`trigger_decide` 对该族恒 `due=N`（P6-06 接线）。
- **边界沿用本文 D41/D45**：仅 Managed（B16）、`legacy_adapter_parse` 零触碰、经
  `tcfg_editor_trigger_ok` 白名单创建。批准前 `tcfg_editor_trigger_ok` **不含** `chain`
  （创建路径自然拒绝，零占位实现）。
- 根（链入口）= 本文 D41 全家族任一既有触发器，家族语义零变化（D44 顺序不变）。
