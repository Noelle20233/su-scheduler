# Su Scheduler — Canonical Task Registry（P1-06）

> **任务**：P1-06 · 实现 Canonical Task Registry
> **依赖**：P1-05（Legacy Config Adapter）
> **性质**：让 daemon 每轮使用**统一 Task 注册表**，而不是重复直接扫描 config.txt。
> 登记表（registry）是 P1 阶段**唯一**的任务数据源契约；daemon 接线（以登记表
> 替换逐分钟扫描）属后续任务，本任务提供实现与测试（`tests/task-registry/`）。
> **日期**：2026-08-30

---

## 目录

1. [目的与验收映射](#1-目的与验收映射)
2. [快照模型](#2-快照模型)
3. [目录布局与原子切换](#3-目录布局与原子切换)
4. [reload 逻辑与无效回退](#4-reload-逻辑与无效回退)
5. [防重复注册](#5-防重复注册)
6. [单一调度入口](#6-单一调度入口)
7. [API 速查与返回码](#7-api-速查与返回码)
8. [验收标准对照](#8-验收标准对照)
9. [非目标与接线说明](#9-非目标与接线说明)

---

## 1. 目的与验收映射

| 需求 | 验收标准 | 落实 |
| :--- | :--- | :--- |
| 配置读取后生成完整 Task 快照 | — | §2：reload = 一次完整解析 → 完整快照目录 |
| 任务按稳定 ID 索引 | — | §2/§3：快照内每任务 `<id>.task`（id 规则见 `docs/architecture/task-id-rules.md`） |
| 保留配置来源信息 | — | 每任务 `source.*`（行号/原文，adapter 产出）；manifest 记录 config 路径/parse_rc/task_count |
| 支持 hot reload | — | §4：`registry_reload <config>` 随时重解析并原子切换 |
| 新配置解析失败 → 保留最后一次有效快照 | **配置损坏不会导致所有任务消失** | §4 回退策略 + 测试 §4 |
| 不允许“部分新+部分旧”混合 | — | §3 原子切换 + 整快照替换 + 测试 §3/§5 |
| 同一 Task 不得在一次调度周期重复注册 | **配置修改不产生重复任务** | §5 提交前校验（id==文件名 且 快照内唯一）+ 整快照替换 |
| — | **daemon 只保留一个调度入口** | §6：所有消费者只经当前快照读任务；config.txt 只在 reload 内部被 adapter 读取 |

## 2. 快照模型

- **一次（重新）加载 = 一次完整解析**：`registry_reload <config>` 调 P1-05 adapter
  （`legacy_adapter_parse <config> <snapshot_dir>`），adapter 在**独立目录**产出全部
  `<id>.task` → 该目录即**完整 Task 快照**（快照内任务 = 该配置的全部任务，无增删
  部分）。
- **稳定 ID 索引**：每任务一个文件，文件名 = 任务 id（`t<行号>_<trigger_norm>`）；
  读取 API（`registry_has_task <id>` / `registry_task_file <id>` /
  `registry_task_ids`）一律按 id —— 与 id 规则文档一致（无时间戳、可复现）。
- **保留来源**：任务文件中的 `source.type/line/raw`（adapter 产出）；快照 manifest：
  ```
  snapshot=<id>
  config=<绝对/传入路径>
  parse_rc=<0|1>
  task_count=<N>
  ```
- **快照不可变**：提交后目录内容不再修改；历史快照保留（清理/保留策略属接线任务）。

## 3. 目录布局与原子切换

```
<base>/
  current                    ← 当前快照指针（单文件，内容 = 快照 id；tmp+mv 原子写）
  snapshots/
    snap_1/  manifest  t11_boot.task  …     ← 快照 1（不可变）
    snap_2/  manifest  …                   ← 快照 2
    …
```

- **原子切换**：新快照在 `snapshots/snap_<N>/`（`N` 确定性递增，无时间戳）构建（adapter
  直接写入该目录）；校验通过后写 `manifest`（tmp+mv）与 `current`（tmp+mv）。
  读者（`registry_task_ids` 等）总是通过 `current` 解析 → 要么看到**完整旧快照**，
  要么看到**完整新快照** —— 不存在“部分新+部分旧”的中间态（验收 3）。
- **失败不留残**：任何失败路径 `rm -rf` 未提交的快照目录；`current` 指针不动
  （tmp 清理 + mv 原子 → 读者不受影响）。

## 4. reload 逻辑与无效回退

`registry_reload <config>` 流程：

1. `config` 为空 → **HARD**（rc2，现状不动）；
2. `config` 文件不可读 → **回退**（rc1，保留现有快照；“任务不消失”验收 1）；
3. adapter 未加载（`legacy_adapter_parse` 不存在）→ **HARD**（rc2，现状不动）；
4. 完整解析到新快照目录；`parse_rc`、`task_count` 判定有效性：
   - `parse_rc=0` → 有效（含 0 任务：用户主动清空为合法快照）；
   - `parse_rc=1` 且 `task_count ≥ 1` → 有效（部分行失败已被 adapter 隔离 = **完整
     新子集**，非混合；`source.line` 等因行号平移整体更新）；
   - `parse_rc=1` 且 `task_count = 0`（整份损坏）→ **无效 → 回退**；
   - `parse_rc=2`（文件级失败）→ **无效 → 回退**；
5. 有效 → §5 校验 → 提交（manifest + current 原子切换）→ stdout 快照 id、rc0；
6. 无效 → **回退**：删未提交目录、指针不动 → stdout `KEPT`、rc1。

> 关键：回退**只作用于新快照**——现有快照与 `current` 指针不被触碰，任务不会
> 消失（验收 1）；“最后一次有效快照”即现役快照（首次加载失败则无快照可回退，
> 记录错误、current 不建立）。

## 5. 防重复注册

- **提交前校验** `_registry_snap_valid <snapshot_dir>`：对每任务文件断言
  `id` 字段 == 文件名、快照内 `id` 唯一；违规 → 快照无效 → 回退（**绝不让重复
  任务进入现役快照**）。
- **整快照替换**：配置修改（增/删/改行）→ adapter 全量重解析 → 新快照内每个 id
  至多一次（行号唯一 ⇒ id 唯一）→ “配置修改不产生重复任务”（验收 2）天然成立。
- adapter 本身（P1-05）已经保证单次解析内 id 唯一；registry 校验为第二道防线。

## 6. 单一调度入口

- **唯一数据源**：消费者读任务**只**经当前快照 API
  （`registry_task_ids` / `registry_task_file` / `registry_has_task`）；
  config.txt 文本**只**在 `registry_reload` 内部被 adapter 读取（lib 中
  `legacy_adapter_parse` 调用点唯一——测试断言）。
- **结构化断言**（测试 §7）：registry lib 内无 config 文本扫描循环
  （`IFS= read` 出现次数为 0）；adapter 实际调用点恰好 1 处。
- **接线说明**：未来 daemon 逐分钟扫描应改为 `registry_reload`（或仅在 mtime 变化
  时）+ 每轮从 `registry_task_ids` 迭代调度。这是“daemon 只保留一个调度入口”在
  daemon 侧的落地形式（C2：旧路径保留，直到接线任务显式替换并过回归）。

## 7. API 速查与返回码

| API | 说明 | 返回 |
| :--- | :--- | :--- |
| `registry_init <base> <config>` | 初始化基目录并做首次载入 | 首次载入同 reload |
| `registry_reload [<config>]` | 重解析并（原子）切换 / 回退 | stdout：`snap_<N>`（新提交）｜`KEPT`（回退）｜`HARD`（硬错误）；rc 0/1/2 |
| `registry_current_snapshot_id` | 当前快照 id | stdout |
| `registry_snapshot_dir` | 当前快照目录（读者唯一入口） | stdout |
| `registry_has_task <id>` | 任务是否存在 | 0/1 |
| `registry_task_file <id>` | 任务文件路径 | stdout / rc1 |
| `registry_task_ids` | 当前快照全部任务 id（排序，调度数据源） | stdout |
| `registry_manifest` | 当前 manifest | stdout |
| `_registry_snap_valid <dir>` | 快照校验（id==文件名、唯一） | 0/1（内部） |
| `registry_log <msg>` | 日志钩子（默认 stderr，`TR_LOGGING=0` 静音） | — |

返回码约定：reload **0**=新快照生效；**1**=解析失败/无效→回退（现有快照保留）；
**2**=硬错误（无 config 路径 / adapter 未加载）→ 现状不动。

## 8. 验收标准对照

| 验收标准 | 落实 | 证据 |
| :--- | :--- | :--- |
| 配置损坏不会导致所有任务消失 | §4 回退（缺失/不可读/全行损坏 → KEPT，现状保留） | 测试 §4a/§4b（16 任务仍在） |
| 配置修改不会创建重复任务 | §5 校验 + 整快照替换；增/删/改行后任务集唯一 | 测试 §3a/§3b/§5/§6、§4b |
| daemon 只保留一个调度入口 | §6：唯一数据源=当前快照；config 文本仅在 reload 内部 | 测试 §7 结构断言 |

外加：无混合状态（原子切换，测试 §3/§5 无旧 id 残留）、快照源信息保留
（manifest + source.*，测试 §1）、hot reload（测试 §2 重复 reload → 新快照、集合一致）。

## 9. 非目标与接线说明

- **不改 daemon**（C2）：registry 是契约与测试域实现；daemon 接线（用 registry
  替换逐分钟扫描、复用 adapter 函数）为后续任务，须保持既有行为并过全部回归
  （P1-01 基线 + P1-02..06 测试）。
- 快照清理/保留策略（多代快照累积）、跨配置 id 冲突后缀（`-N`）、并发写锁均
  **不在本任务**（已预留语义，见 id 规则 §5）。
- registry 不解析用户 JSON/YAML、不引入 jq/Python/Node（同一 P1 约束）。