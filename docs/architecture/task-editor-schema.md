# Su Scheduler — Task v2 表单 schema 与错误提示规范（P3-06 / P4-08）

> **配套**：docs/P3-06.md（执行记录）；webroot/app.js 的 TASK_FORM_SCHEMA 为实现镜像。
> **状态**：P3-06 冻结；P4-08 在 Advanced 步骤开放 dependency/condition（经既有
> VALIDATE_TASK/EDIT_TASK payload 路径，后端权威）。字段/枚举/范围与 Runtime §23
> （tcfg_editor_*）一致。

## 1. 分步编辑步骤与字段

| 步骤 | 字段 | 类型 | 缺省 | 约束 |
| :--- | :--- | :--- | :--- | :--- |
| Basic | id | text | 自动 | [A-Za-z0-9_.-]；无 ..//（路径穿越拒绝）；必填 |
| Basic | name | text | 命令首词 | ≤64；必填 |
| Basic | enabled | bool | 1 | 0/1 |
| Basic | description | text | 空 | ≤256 |
| Trigger | triggerType | select | time | boot/time/weekly/nweekly/monthly/nmonthly/yearly（已实现）；boot_completed/delay/interval/cron/oneshot（未实现 → 禁用） |
| Trigger | time | text | — | HH:MM（^[0-2][0-9]:[0-5][0-9]$） |
| Trigger | weeklyDOW / weeklyTime | text | 1 / 0000 | ^[1-7]$ / ^[0-9]{4}$ |
| Trigger | nweeklyN | text | 1 | ^[0-9]+$ 且 1..52 |
| Trigger | monthlyDay / monthlyTime | text | 1 / 0000 | ^[0-9]+$ 且 1..31 / ^[0-9]{4}$ |
| Trigger | nmonthlyN / nmonthlyDay / nmonthlyTime | text | 1/1/0000 | N 1..12；day 1..31；time HHMM |
| Trigger | yearlyTime | text | 01010000 | ^[0-9]{8}$（MMDDHHMM 或 MM:DD:HHMM） |
| Action | actionType | select | command | command / app |
| Action | command | textarea | — | action.type=command；非空；单行（无未转义真实换行） |
| Action | appOp | select | package | package/activity/broadcast/service |
| Action | appTarget | text | — | 复用 P2-10 结构化校验（包名/组件/意图动作正则） |
| Health | healthType | select | none | none/process/port |
| Health | healthTarget | text | — | process=进程名/PID；port=1..65535（复用 P2-11） |
| Recovery | recoveryType | select | none | none/restart/start/stopstart/script |
| Recovery | recoveryScript | text | — | recovery.type=script 时须绝对路径且可读 |
| Retry | retryMax | text | 0 | 0..100 |
| Retry | retryInterval | text | 60 | 0..86400 |
| Retry | retryCooldown | text | 0 | 0..86400 |
| Advanced | timeout | text | 0 | 0..86400 |
| Advanced | environment | text | 空 | K=V,K=V；安全字符集 [A-Za-z0-9_=,.:/+-] |
| Advanced | concurrency | text | 0 | 0..100 |
| Advanced | logging | text | 0 | 0..1000000 |
| Advanced | dependency | text | 空 | **P4-08**：`[?]<task-id>[:STATE]` 逗号/空格分隔；≤32 条（DEP_MAX）；id 过 tcfg_editor_id_ok（禁 `..`/`/`/`*`）；STATE ∈ {STOPPED, FAILED}（缺省 STOPPED）；前端即时提示 + **后端权威**（语法 + 图校验/未知 id/环，P4-02/03） |
| Advanced | condition | text | 空 | **P4-08**：`{{ 谓词 }}` 白名单表达式（task.state/time.hour/time.minute/time.wday/env.<CONFIG_FILE\|DATA_DIR\|TASKS_DIR>/file.exists，运算符 ==/!=）；≤256（COND_MAX_LEN）；前端即时提示 + **后端权威**（cond_validate + cond_grammar_ok，P4-06） |

## 2. 序列化（表单 → Task v2 文件）

前端按固定键序输出 POSIX key=value 文本（无引号语义）：

```
schema_version=2
id=<id>
name=<name>
enabled=<0|1>
description=<desc>
trigger=<trigger>
action.type=<command|app>
action.command=<cmd|app:op:target>
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=<none|process|port>
health.target=<target>
recovery.type=<none|restart|start|stopstart|script>
recovery.script=<path>
retry.max=<n>
retry.interval=<n>
retry.cooldown=<n>
advanced.timeout=<n>
advanced.environment=<K=V,K=V>
advanced.concurrency=<n>
advanced.logging=<n>
dependency=<[?]<task-id>[:STATE]>,...   # P4-08（Advanced 步骤输入；空 = 无依赖）
condition=<{{ 谓词 }}>                 # P4-08（Advanced 步骤输入；空 = 恒真）
```

## 3. 后端校验矩阵（权威，前端不构成安全边界）

tcfg_editor_validate_payload 逐字段校验；任何失败 → 不写盘 + stderr 错误。

| 字段 | 非法例 | 处理 |
| :--- | :--- | :--- |
| schema_version | ≠2 | 拒绝 |
| id | ../x、a/b、含 / | 拒绝（路径穿越） |
| name/description | >64/>256 | 拒绝 |
| enabled | 非 0/1 | 拒绝 |
| trigger | boot_completed/delay/interval/cron/oneshot | 拒绝（未实现） |
| action | 未知 type；app spec 注入（含 ; 等）| 拒绝（app 复用 P2-10） |
| recovery.script | 相对路径/不存在/不可读 | 拒绝 |
| retry.* / advanced.* | 超范围/非数字 | 拒绝 |
| advanced.environment | 含 ;/&/空格 | 拒绝 |
| dependency | 语法非法 / 未知 id / 自依赖 / 环 / 超 32 条 | **后端权威拒绝**（P4-02/03；rc 4 信封 `configuration_invalid`；写盘前拒绝，B9） |
| condition | 非可打印/超 256 / 文法外（非白名单谓词、`>=` 等运算符、注入串） | **后端权威拒绝**（P4-06 cond_grammar_ok；rc 4 信封；写盘前拒绝，B9） |
| source.*/runtime.* | — | 只读保留（忽略编辑） |
| 未知键 | 编辑器 schema 外 | 拒绝 |

## 4. 保存/取消/回滚流程

1. **前端校验**（validateForm）→ 即时错误提示（非安全边界）。
2. **校验预览**：VALIDATE_TASK payload=<b64(content)> → 后端全字段校验，
   {"ok":true} 或 {"ok":false,"rc":4,"error":"task invalid"}。
3. **保存**：EDIT_TASK id=<b64> payload=<b64> → 后端 tcfg_apply_task
   （校验 → tmp+mv 原子写）→ sched_reload。
4. **回滚**：保存失败（rc 1/2/4）时旧 task 文件逐字节不变（原子写保证）；
   前端显示「保存失败（旧配置未变）」。
5. **取消**：丢弃表单，返回 Task List（零副作用）。

## 5. 错误提示规范

### 5.1 IPC 响应（统一信封）

| 场景 | 响应 | rc |
| :--- | :--- | :--- |
| 保存成功 | id|EDIT_TASK|0|ok + saved <id> | 0 |
| 校验失败 | id|EDIT_TASK|4|configuration_invalid + task invalid (config unchanged) | 4 |
| 非 Managed | 4 configuration_invalid + 提示先 import | 4 |
| 缺 id/payload | 1 invalid_request | 1 |
| 任务不存在（GET_TASK_EDIT） | 3 task_not_found | 3 |
| daemon 离线 | 6 daemon_unavailable | 6 |

### 5.2 前端错误提示

| 场景 | 提示 |
| :--- | :--- |
| 前端校验失败 | 「前端校验：<逐条错误>」 |
| 后端校验失败 | 「后端校验失败：rc=<n> <error>」 |
| 保存成功 | 「已保存 ✓（旧配置保持原子，失败时自动回滚）」 |
| 保存失败 | 「保存失败（旧配置未变）：rc=<n> <error>」 |
| 读取任务失败 | 「读取任务失败：<error>」 |
| dependency 前端提示（非安全边界） | 「Dependency 格式非法（[?]<task-id>[:STATE]，逗号/空格分隔）」 / 「Dependency 含非法 task-id（仅 [A-Za-z0-9_.-]，禁路径穿越）：<entry>」 |
| condition 前端提示（非安全边界） | 「Condition 含非法字符（仅可打印 ASCII，无 ; $ 反引号 \| > < 注入）」 / 「Condition 应形如 {{ 谓词 }}（白名单谓词，如 {{ time.hour == 8 }}）」 |

### 5.3 后端校验错误（stderr）

统一 [editor] ERROR: <字段> <原因>；如：

```
[editor] ERROR: invalid id '../x' (charset/path-traversal)
[editor] ERROR: trigger 'cron:...' not implemented
[editor] ERROR: invalid action type='app' command='app:package:x;rm'
[editor] ERROR: retry.max must be 0-100
[editor] ERROR: advanced.logging must be 0-1000000
[editor] ERROR: dependency syntax invalid (got 't_a:IDLE'; expect '[?]<task-id>[:STATE]', ',' or space separated, <= 32 entries)
[editor] ERROR: dependency unknown dependency 'ghost_dep' in 't_a'   # P4-03 图校验
[editor] ERROR: dependency cycle: t_a->t_b->t_a                     # P4-03 图校验
[editor] ERROR: condition expression illegal (got '{{ time.hour >= 8 }}'; whitelisted predicates only: task.state/time.hour/time.minute/time.wday/env.<CONFIG_FILE|DATA_DIR|TASKS_DIR>/file.exists, ops ==/!=)   # P4-06
```

## 6. 安全模型

- 前端校验不是安全边界：后端 tcfg_editor_validate_payload 独立实现并权威。
- App Action 全校验复用 P2-10（固定 am 模板 + 校验片段，拒绝 shell 注入）。
- recovery script 必须绝对路径且存在可读（否则拒绝）。
- 保存原子化：先校验后 tmp+mv；任何失败不留半成品、不覆盖旧配置。
- 编辑不产生重复 ID：ID 为 task-config 文件主键，按 id 覆盖。
- 只读保留 source.*/runtime.*：编辑无法篡改运行/来源事实。
