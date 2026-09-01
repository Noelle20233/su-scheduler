# Task v2 持久化格式（P3-02）—— task-config 存储规范

> **状态**：P3-02 冻结。关联：P1-02（Task Schema v2 字段规范）、
> `docs/architecture/config-authority.md`（权威规则 ADR）、`docs/P3-02.md`。

## 1. 存储布局

独立目录（**不复用运行目录 `tasks/`**），生产缺省：

```
/data/adb/su-scheduler/task-config/
  MANAGED                 标记文件（存在 = managed；内容任意，仅存在性有意义）
  manifest                元数据（mode/source/imported_at/count/promoted/skipped/backup）
  backup/config.txt.<ts>  导入前逐字节备份（回滚源）
  <id>.task               每任务一个 POSIX key=value Task v2 文件
```

- 测试/嵌入可用 `TCFG_DIR` 环境覆盖目录位置。
- 原子性：全部写经 `tmp+mv`；导入先写 staging 再幂等提升；MANAGED **最后写**。

## 2. 单任务文件格式

POSIX `key=value` 文本（无引号语义；值 = 首个 `=` 之后全部字符）。转义规则沿
P1-02 §6：反斜杠 → `\\`、真实换行 → 字面 `\n`（解码 lenient）。

```
# 注释行（元数据，可选）
schema_version=2
id=shizuku
name=Shizuku
enabled=1
trigger=boot
action.type=command
action.command=app:package:moe.shizuku.privileged.api
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=process
health.target=shizuku_server
recovery.type=restart
retry.max=5
retry.interval=30
source.type=line
source.line=11
source.raw=...
runtime.state=PENDING
runtime.run_count=0
```

- **必填**（`tcfg_validate_task` 断言）：`schema_version=2`、`id==文件名`、
  `trigger` 非空。其余键缺省即视为默认值（lenient）。
- 键 charset `[A-Za-z0-9._]`；id charset `[A-Za-z0-9_.-]`。
- 字段语义见 P1-02 §5（`enabled`/`trigger`/`action.*`/`health.*`/`recovery.*`/
  `retry.*`/`source.*`/`runtime.*`）；`action.type` 由 P3 引入
  （`command`=既有执行 / `app`=App Action，对应 P2-10 spec）。

## 3. 导入产物（legacy → v2）

- 导入复用 `legacy_adapter_parse`（P2-02 §2），生成与 P1-02 fixture 同构的
  `.task` 文件；legacy 怪癖照录（boot+`--delete`、heredoc 重构残留、yearly 格式、
  `--boot` 保留标志）。
- id = `t<line>_<trigger_norm>`（legacy 命名空间保留）；`source.*` 记录来源
  行号/原文/块范围。

## 4. 损坏配置回退（绝不退出、绝不清空）

| 场景 | 行为 |
| :-- | :-- |
| 任务文件非法（schema≠2 / id≠文件名 / trigger 空） | `tcfg_validate_task` 拒；读取侧 lenient（跳过该条目，其余不受影响） |
| 导入 config 损坏 / 零有效任务 | 导入 rc=1，清理 staging，config 逐字节不变，MANAGED 不写 |
| 导入 config 缺失 | rc=2，零副作用 |
| 原子写失败 | 清理 tmp，不留半成品 target |

## 5. 与 Registry / Runtime 目录的关系

| 存储 | 角色 | 数据 |
| :-- | :-- | :-- |
| `task-config/` | **配置权威**（managed） | Task v2 用户配置（WebUI/CLI 编辑） |
| `base/snapshots/` | Registry 只读快照 | legacy 投影 / 当前生效集（P2-03/05/07 旁路） |
| `base/tasks/` | 运行目录 | 进程/状态/输出工件（旧 CLI 读取；daemon 执行） |

三者职责隔离：task-config 管"做什么/何时"的权威；registry 管"当前生效集"的
只读快照；tasks/ 管"刚才发生了什么"的运行事实。
