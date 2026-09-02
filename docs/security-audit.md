# Su Scheduler — 安全审计清单（P3-08）

> 与 `docs/P3-08.md` 配套；本文是 P3-08 安全审计的**逐项核对表**，每项给出
> 机制、宿主/CI 验证与判定。全部项在 P3-08 验收中通过。

## 一、输入安全

| # | 项 | 机制 | 验证 |
| :-- | :--- | :--- | :--- |
| 1 | IPC 请求白名单 | `IPC_WHITELIST`（19 op）+ 每 op 参数键白名单；未知 op/键 → rc 1 | tests/ipc、tests/security/fuzz |
| 2 | Task ID 字符集 | `secv_id_ok`（^[A-Za-z0-9_.-]{1,128}$，无 `..`/`/`/`\`/空白/元字符）；id-bearing op dispatch 外层 + tctl_resolve 兜底 | tests/security/fuzz b、path b |
| 3 | App Action 参数校验 | `tpr_action_app_validate`（P2-10，固定 am 模板） | tests/security/fuzz c |
| 4 | 脚本路径校验 | 绝对路径且存在可读；相对/目录 → 拒 | tests/security/path f |
| 5 | 数值范围校验 | `secv_num_clamp`（日志 lines 钳制，防算术溢出） | tests/security/fuzz a、webui |
| 6 | 请求大小限制 | `IPC_REQ_MAX`（>4096 → rc 1） | tests/security/fuzz f09 |
| 7 | 日志查询行数限制 | `WEBUI_LOG_MAX`(500)/`WEBUI_EVENTS_MAX`(200) + 钳制 + truncated | tests/webui/security e |

## 二、文件安全

| # | 项 | 机制 | 验证 |
| :-- | :--- | :--- | :--- |
| 8 | 配置文件权限 | `secv_fix_perms` task-config 600 | tests/security/permission a/d |
| 9 | IPC 文件权限 | ipc 0700（root-only） | tests/ipc/security e、perm d |
| 10 | 任务目录权限 | 运行目录 700、文件 600 | tests/security/permission d |
| 11 | 原子写入 | tmp+mv（P3-02/06/21 既有） | tests/security/permission a/b |
| 12 | 临时文件清理 | `secv_sweep_tmp`（每次 poll：ipc tmp/沙箱 + task-config tmp） | tests/security/permission b |
| 13 | 符号链接风险 | `secv_nosymlink` / `secv_guard_task_dir` | tests/security/path c/d |
| 14 | 路径必须位于允许目录 | `secv_inside`（`..` 段拒绝） | tests/security/path a |
| 15 | 未授权文件无法被修改 | ipc 0700 + permission_denied（rc 2） | tests/security/permission c |

## 三、执行安全

| # | 项 | 机制 | 验证 |
| :-- | :--- | :--- | :--- |
| 16 | 不新增 eval | §25 全代码审计；webroot 无 Root 直执特征 | tests/webui/security a、fuzz e |
| 17 | 不允许 WebUI 直接调 sh -c | webroot 无 `sh -c`/`eval`/`/data/adb` 直读；IPC 零 exec | tests/webui/security a/b |
| 18 | 高级 Command 只能作为已保存 Task Action | START/STOP/RESTART 命令取自已校验任务文件；`command=` 参数键 → rc 1 | tests/security/fuzz e |
| 19 | Web 请求不能临时拼接 Root 命令 | IPC 固定格式 + base64 + 参数键白名单 | tests/ipc/security b |
| 20 | 每个 Action 必须有 timeout | `secv_effective_timeout`（advanced.timeout>0 且 ≤ TASK_RUNTIME_MAX）→ supervisor_step | tests/resource/stress（P2-14 超时护栏复用） |
| 21 | 命令注入全拒 | START/CREATE/UPDATE 多行/注入 → rc 1/4，绝不执行 | tests/security/fuzz e |

## 四、资源安全

| # | 项 | 机制 | 验证 |
| :-- | :--- | :--- | :--- |
| 22 | 日志最大字节数 | `runtime_limit_log` / `runtime_limit_task_log`（output.log/events.log ≤ TASK_LOG_MAX_BYTES） | tests/resource/stress b |
| 23 | 单 Task 日志数量 | `WEBUI_LOG_MAX` 行数 + 字节上限（双轨） | tests/webui/security e、stress b |
| 24 | Task 目录上限 | `runtime_prune_tasks`（TASK_DIRS_MAX，活跃豁免） | tests/resource/stress b |
| 25 | Registry 快照上限 | `runtime_prune_snapshots`（SNAP_MAX_KEEP，current 恒保） | tests/resource/stress b |
| 26 | 健康检查最小间隔 | `supervisor_health_due`（HEALTH_MIN_INTERVAL） | tests/crashguard |
| 27 | IPC 请求频率限制 | `secv_ipc_ratelimit`（窗口桶计数，超限 → rc 7） | tests/resource/stress d |
| 28 | WebUI 查询分页/行数限制 | `WEBUI_LOG_MAX/EVENTS_MAX` + truncated 标志 | tests/webui/security e |
| 29 | 100 Task 不产生 100 永久循环 | scheduler/supervisor 单 for 循环，无 per-task while/后台/线程（结构断言）+ 100 注册 | tests/resource/stress a |
| 30 | daemon CPU/内存无失控 | 真实 tick/supervisor 有界返回 | tests/resource/stress a/e |
| 31 | 单项校验失败不终止 daemon | 单任务错误隔离（rc 不 abort）+ tick errn 计数 | tests/resource/stress c |

## 判定

- 全项通过 = P3-08 验收通过；任一 [FAIL] → 任务门禁失败（AGENTS §4）。
- 宿主环境例外（Windows Git-Bash）：chmod 权限断言与 CRLF `dash -n` 为 P3-07
  记录的 pre-existing 宿主项（CI ubuntu-latest LF 全绿）；符号链接在无法产出真实
  链接的宿主显式 SKIP（逻辑由 `secv_nosymlink`/`secv_guard_task_dir` 覆盖）。