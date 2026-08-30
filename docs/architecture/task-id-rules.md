# Su Scheduler — Task ID 规则（P1-05）

> **任务**：P1-05 交付物之一（Task ID 规则文档）
> **配套**：`docs/architecture/task-schema-v2.md`（Schema）、`tests/legacy-adapter/adapter.sh`
> **背景**：v2 内部 Task 的 `id` 必须**稳定、可复现、不含单次执行时间戳**；
> legacy 旧任务 id（`startup_<N>_<epoch>`、`time_<HHMM>_<N>_<epoch>`、`immediate_…`、
> `advanced_…`——P1-01 §5）**不得**用于 v2（时间戳导致重复加载 id 漂移）。
> **日期**：2026-08-30

---

## 1. ID 派生规则（规范）

```
id = t<source.line>_<trigger_norm>

其中：
  source.line   = 旧配置中该任务行的原始物理行号（heredoc 块 = 头行号）
  trigger_norm  = 触发器去冒号（与 daemon 匹配比较同语义，P1-01 §4.2）
```

示例（P1-01 legacy fixture，`tests/fixtures/legacy/config.txt`）：

| 任务行（行号） | trigger | id |
| :--- | :--- | :--- |
| 行 11 `boot …` | `boot` | `t11_boot` |
| 行 16 `08:30 …` | `08:30` | `t16_0830` |
| 行 20 `weekly:1:0800 …` | `weekly:1:0800` | `t20_weekly10800` |
| 行 26 `yearly:12:25:0800 …` | `yearly:12:25:0800` | `t26_yearly12250800` |
| 块 35-37 `09:15 python <<EOF …` | `09:15` | `t35_0915` |
| 行 45 `22:00 …`（末行无换行） | `22:00` | `t45_2200` |

## 2. 性质与保证

| 性质 | 规则 | 验收对应 |
| :--- | :--- | :--- |
| **无时间戳** | id 只含 `行号 + trigger_norm`；**禁止** epoch/秒数/日期成分（legacy `_<epoch>` 后缀被拒） | “Task ID 不得使用单次执行时间戳” |
| **可复现** | id 是 (行号, trigger) 的纯函数 → 同一配置**每次解析 id 逐字节一致** | “同一配置重复加载时，Task ID 必须保持一致” |
| **保留行号** | `source.line` 记录原始物理行号；id 前缀 `t<行号>` 直接可溯源 | “保留原始行号” |
| **快照范围稳定** | id 锚定“该快照中的行号”。配置行被增删 → 后续行号平移 → 这些行的 id 变化（**预期、已文档化**）；未平移行 id 不变 | 审计用 `source.raw` 复核实际内容 |
| **charset** | `t` + 数字 + 去冒号后的 trigger（`[A-Za-z0-9_]`）→ id 匹配 `^t[0-9]+_[A-Za-z0-9_]+$`，无空格/控制符 | 校验规则（P1-02 validation） |

## 3. 命名解析

- `t`：task 前缀（与 legacy 目录 `tasks/<task_id>` 的“task”概念同义，避免歧义）。
- `<行号>`：`source.line` 的**头行**（单行 = 该行；heredoc 块 = 头行；范围见 §4）。
- `<trigger_norm>`：**去冒号**（`weekly:1:0800`→`weekly10800`；`boot`→`boot`；
  `08:30`→`0830`）。去冒号与 daemon 时间匹配归一（L650）同规则 → 直观可读且
  **不做**语义判定（yearly 文档/实现格式差异 Q9 原样进入 id：`t26_yearly12250800`）。

## 4. heredoc 块的行号

- 块任务的 `source.line` = `头行-EOF行`（如 `35-37`）；**id 只用头行**（`t35_0915`）。
- **无 EOF 终止符**的块：范围到文件尾；**末尾无换行行不被内层 read 消费**
  （daemon 内层 heredoc read 无换行 guard，P1-01 §4.4 镜像语义）→ 该行不进入
  块体、不进入块范围端点（示例 `tests/legacy-adapter/fixtures/config-valid-extras.txt`）。

## 5. 多文件 / 未来扩展

- 单配置文件（现状）内行号唯一 → id 唯一。
- 未来多配置（不同 `config.txt` 来源）：同名不同文件 → id 冲突。规则：**预留**
  后缀方案 `t<N>_<norm>_<seq>`（seq = 冲突序号，见 P1-02 validation “重复 → 先见者
  保留，后者隔离”）；**不在本任务接线**（当前无多配置输入）。
- 用户显式指定 id / name：P1 配置格式不变（C4）→ id/name 恒为派生值（P1-02 §7）。

## 6. 与旧任务 id 的关系（迁移）

| legacy 任务 id（P1-01 §5） | 是否可用于 v2 | 说明 |
| :--- | :--- | :--- |
| `startup_<N>_<epoch>` | **否** | 含 epoch → 违反稳定性 |
| `time_<HHMM>_<N>_<epoch>` | **否** | 同上 |
| `immediate_<N>_<epoch>` / `advanced_<N>_<epoch>` | **否** | 同上 |
| v2 `t<行号>_<norm>` | **是（规范）** | 本文档 §1 |

迁移对照：v2 任务 ↔ legacy 执行事实（`tasks/<旧 id>/`）的关联**不**靠 id 字符串，
而靠 `source.line`/`source.raw` 与 `runtime.last_*`（接线任务决定），确保旧执行
历史可审计且不再污染新 id 命名空间。

## 7. 验收对照

| 验收要求 | 落实 |
| :--- | :--- |
| 保留原始行号 | §1/§4：`source.line`（单行号 / 块范围）由 adapter 记录，id 前缀可溯源 |
| 生成稳定 Task ID | §2 纯函数派生；`bash tests/legacy-adapter/test.sh` 断言重复解析 id 逐字节一致 |
| ID 不使用单次执行时间戳 | §1/§2 禁止 epoch；测试断言 id 无 `_<epoch>` 后缀 |
| 同一配置重复加载 ID 一致 | §2 可复现 + 测试（107 项全绿，含确定性用例） |
| 解析失败返回明确错误，不产生半成品 | adapter：rc 0/1/2 + stderr 错误 + 原子写（tmp+mv）+ 出错行不产出任务（P1-05 test §8） |

## 8. 规则不可变承诺

- 任何后续任务**不得**：给 id 加时间戳/随机数/计数器（除非 §5 冲突后缀场景）；
  不得改变 trigger_norm 去冒号规则；不得把 heredoc 块 id 改绑到非头行。
- 变更 id 规则 = 同时更新：本文档、`tests/legacy-adapter/adapter.sh` 的
  `legacy_adapter_task_id`、P1-02 样例生成器、相关测试——四处一致（测试断言
  adapter 与样例一致）。