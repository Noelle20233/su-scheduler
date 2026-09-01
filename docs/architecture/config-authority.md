# 配置权威规则 ADR（P3-02）

> **状态**：已接受（P3-02 冻结）
> **作者/日期**：P3-02 · 2026-09-01
> **关联**：`docs/P3-02.md`（执行记录）、`docs/architecture/task-config-store.md`
> （持久化格式）、P1-02（Task Schema v2）、P2-03/04（Registry/ID 映射）

## 问题

WebUI 编辑的内容需要持久化来源，同时 legacy `config.txt`（旧 daemon/旧 CLI 的
唯一配置源）必须继续兼容。需要明确：**legacy 配置与 Task v2 谁是权威**，以及
导入/编辑/回滚/冲突/ID 的规则。

## 决策（D1–D9）

### D1 双模式判定（单一事实源）

- 权威模式由 `task-config/MANAGED` 标记文件的**存在性**唯一判定：
  - 存在 → **managed**：`task-config/` 是权威配置源；
  - 不存在 → **legacy**：`config.txt` 是唯一配置源。
- 判定函数 `tcfg_mode()`/`tcfg_is_managed()`；**口诀：有标记读 task-config，
  无标记读 config.txt**。

### D2 默认 legacy（旧用户零变化）

- 未显式导入则永远处于 legacy：daemon/CLI 行为、config.txt 语义完全不变。
- WebUI 未打开/未导入的用户：task-config/ 目录不存在或惰性，零影响。

### D3 迁移仅由显式导入触发

- legacy → managed 的唯一入口是显式导入（WebUI「导入旧任务」或 CLI
  `task-config import`）。**绝无自动/隐式迁移**。
- 导入把当前 config.txt 逐字节备份到 `backup/config.txt.<ts>` 后，才进入
  managed——这是「不静默覆盖用户配置」的硬保证。

### D4 导入永不改写 config.txt

- 导入全程只读 config.txt（仅 `cp` 到备份）；任何失败（config 缺失/损坏/
  零有效任务/写失败）都**不触碰 config.txt**，保证「导入失败原配置逐字节不变」。

### D5 删除 / 禁用 / 重命名的迁移规则

| 操作 | Managed 语义 | Legacy 语义 |
| :-- | :-- | :-- |
| 删除 Task | `rm task-config/<id>.task`（文件级；不影响运行目录 tasks/） | 无此概念（config.txt 编辑走旧 remove） |
| 禁用 Task | `enabled=0`（保留条目与历史，调度跳过——字段语义见 P1-02 §5） | 无（legacy 无停用） |
| 重命名 | 改 `name=`（id 是稳定身份，不变） | 无 |
| 编辑 | `set <id> <key> <value>` 原子改字段 | config.txt 编辑走旧 edit |

### D6 冲突处理（legacy 与 v2 同时存在）

- 权威 = D1 标记判定，**不存在"双向合并"**：
  - managed：task-config 为准；config.txt 只是备份/导出，不反向覆盖；
  - legacy：config.txt 为准；task-config 惰性（存在但不被消费）。
- 重复导入：已存在 id **跳过**（幂等）；用户 managed 编辑过的条目不被旧
  config 覆盖（no silent overwrite）。

### D7 Task ID 兼容与新建

- 导入任务保留 `t<line>_<trigger>`（与 P2-04 idmap 双向解析兼容，旧运行 ID
  查询不破坏）。
- 新建任务用 `task_<trigger_norm>_<n>`（`tcfg_new_id`），与 legacy
  `t<line>_` 命名空间隔离，杜绝撞名。
- id charset `[A-Za-z0-9_.-]`（`tcfg_new_task` 校验）。

### D8 写入失败与回滚

- 所有写经 `tmp+mv` 原子；失败清理 tmp，**不留半成品**（含导入 staging）。
- 导入失败不写 MANAGED 标记 → 中断/失败不产生半管理态（无标记 = legacy）。
- `tcfg_rollback`：最新备份 `cp` 回 config（逐字节还原）+ `rm MANAGED` →
  回到 legacy；task-config 文件保留为惰性（不误删）。

### D9 不变量（P3 全阶段）

1. daemon 调度路径 / service.sh 零改动（P3-01 D1：legacy 调度仍是执行入口）；
2. config.txt 行格式零变更（C4）；
3. WebUI 写侧经 `task-config` CLI / `tcfg_*` 原语，Web 端永不直执 Root Shell。

## 后果

- 正向：WebUI/CLI 编辑有独立、可回滚、幂等的持久化来源；旧用户零变化。
- 代价：managed 模式下 config.txt 与 task-config 可能漂移（有意为之——
  以 MANAGED 标记明确权威，不做隐性合并）；需要文档与 manifest 可追溯。
- 回退：`tcfg_rollback` 一键还原 legacy；若实现有缺陷，移除 MANAGED 即回到
  纯 legacy，不损失 config.txt 备份。

## 附：决策记录

- 2026-09-01：P3-02 建立本 ADR（D1–D9 冻结）。
