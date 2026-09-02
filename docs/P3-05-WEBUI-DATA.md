# Su Scheduler — WebUI 数据格式文档（P3-05 只读数据面）

> **用途**：KernelSU 原生 WebUI（`webroot/`）与主机验收（`su-scheduler webui`
> CLI Reader）共用的**唯一数据契约**。前端只经此 JSON Schema 读取 daemon 状态。
> **约束**：只读；数据全部来自 IPC（Runtime Read Aggregator，Runtime §22）；
> JS 不读数据目录、不调系统命令/动态求值；特殊字符由服务端统一 JSON 转义。

---

## 1. 读取入口

| 入口 | 说明 |
| :--- | :--- |
| `su-scheduler webui <OP> [key=value ...]` | CLI Reader（RUNTIME_LOADED 门控，只读白名单） |
| KernelSU WebUI Bridge | 生产部署：manager 侧执行同一 CLI Reader，结果回传页面 |

- 成功：stdout 输出**单行统一 JSON**（下为各 op Schema）。
- 失败：`{"ok":false,"rc":<rc>,"error":"<error>"}`
  - rc 6 → `daemon_unavailable`（前端显示 daemon 离线横幅）。
  - rc 3 → `task_not_found`（Task Detail 显示「任务不存在或配置无效」）。
  - rc 1 → `invalid_request`（参数键白名单拒绝，零副作用）。
- 所有 op 均为**只读**：零 exec、零 config 写、零副作用。

---

## 2. JSON 编码规则（特殊字符安全）

所有字符串值由 `web_json_escape` 编码（Runtime §22），保证日志中的 `<script>`、
引号、换行不会造成 HTML/JS 注入：

| 字符 | 编码 |
| :--- | :--- |
| `\` | `\\` |
| `"` | `\"` |
| tab / CR | `\t` / `\r` |
| `<` `>` `&` | `\u003c` `\u003e` `\u0026` |
| 多行值（内部换行） | 字面 `\n`（JSON 文档保持单行，无裸换行） |
| 其他 C0 控制符 | 清除 |

前端渲染一律使用 `textContent`，不拼接 innerHTML。

---

## 3. op 与 JSON Schema

### 3.1 GET_SUMMARY（Dashboard + Task List）

```
su-scheduler webui GET_SUMMARY
```

```json
{
  "ok": true,
  "daemon": "online",
  "mode": "managed",
  "counts": {
    "total": 5,
    "running": 1,
    "healthy": 1,
    "failed": 1,
    "disabled": 1,
    "unhealthy": 1,
    "unknown": 0
  },
  "tasks": [
    {
      "id": "t_run",
      "name": "echo",
      "status": "RUNNING",
      "trigger": "08:30",
      "action": "echo run",
      "enabled": "1",
      "health": "none",
      "last_run": "2026-09-02 08:30:01",
      "restart_count": 0,
      "has_run_dir": 1
    }
  ]
}
```

字段说明：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `counts.total` | int | 注册任务总数 |
| `counts.running` | int | 状态 ∈ STARTING/RUNNING |
| `counts.healthy` | int | 状态 == HEALTHY |
| `counts.failed` | int | 状态 == FAILED |
| `counts.disabled` | int | enabled == 0 |
| `counts.unhealthy` | int | 状态 == UNHEALTHY |
| `counts.unknown` | int | 其余状态 |
| `tasks[].health` | str | 健康族状态（HEALTHY/UNHEALTHY/UNKNOWN/RECOVERING）或 health.type（none/process/port） |
| `tasks[].last_run` | str | start_time.txt 或 runtime.last_start |
| `tasks[].restart_count` | int | 运行目录 recovery.count（缺省 0） |

### 3.2 GET_TASK_DETAIL（Task Detail）

```
su-scheduler webui GET_TASK_DETAIL id=<base64(task_id)>
```

```json
{
  "ok": true,
  "task": {
    "id": "t_run",
    "name": "echo",
    "status": "RUNNING",
    "trigger": "08:30",
    "action": "echo run",
    "enabled": "1",
    "health": { "type": "none", "target": "" },
    "recovery": { "type": "none", "max": 0, "interval": 60 },
    "pid": "1001",
    "last_exit": "0",
    "last_start": "2026-09-02 08:30:01",
    "last_end": "",
    "restart_count": 0,
    "run_count": 0,
    "source": { "type": "", "line": "", "raw": "" },
    "has_run_dir": 1
  }
}
```

字段来源：task-config / Registry 快照字段（name/trigger/action/enabled/health.*/
recovery.*/retry.*/source.*/runtime.run_count）+ 运行目录工件（pid.txt/
exit_code.txt/start_time.txt/end_time.txt/recovery.count/state.txt→status）。

### 3.3 GET_TASK_EVENTS（运行历史 / 最近事件）

```
su-scheduler webui GET_TASK_EVENTS id=<base64(task_id)> lines=<base64(N)>
```

```json
{
  "ok": true,
  "task": "t_run",
  "total": 2,
  "returned": 1,
  "truncated": 1,
  "lines": [
    "2026-09-02 08:31:01|t_run|action_success|STOPPED|1001|0|done"
  ]
}
```

- `total`：events.log 总行数；`returned`：本次返回行数；`truncated=1` ⇔
  `returned < total`（**明确提示日志已截断**）。
- `lines`：7 字段事件行 `ts|task_id|event|state|pid|exit_code|msg` 原样（JSON 转义）。
- 有界：`lines` 钳至 ≤200。

### 3.4 GET_DAEMON_LOG（daemon 主日志）

```
su-scheduler webui GET_DAEMON_LOG lines=<base64(N)>
```

```json
{
  "ok": true,
  "total": 300,
  "returned": 100,
  "truncated": 1,
  "lines": ["[2026-09-02 01:06:24] hello daemon log", "…"]
}
```

- 来源：`$DATA_DIR/su-scheduler.log`；有界 `lines` ≤500；`truncated` 同 §3.3。

### 3.5 GET_TASK_LOG（task output.log）

```
su-scheduler webui GET_TASK_LOG id=<base64(task_id)> lines=<base64(N)>
```

CLI Reader 经 `web_task_log_to_json` 归一为与 §3.4 相同 JSON Schema
（`{"ok":true,"total":…,"returned":…,"truncated":…,"lines":[…]}`）；
服务端原始载荷为「meta 行 + 内容行」：

```
#truncated=<0|1>|total=<N>|lines=<M>
<output.log 尾部 M 行>
```

- 无输出时：`#truncated=0|total=0|lines=0` + `(no output yet)`。
- 有界：≤500 行。

---

## 4. 错误 JSON（统一）

| 场景 | 输出 | rc |
| :--- | :--- | :--- |
| daemon 未运行 | `{"ok":false,"rc":6,"error":"daemon_unavailable"}` | 6 |
| 任务不存在 / 配置无效 | `{"ok":false,"rc":3,"error":"task_not_found"}` | 3 |
| 缺 id / 参数键白名单拒绝 | `{"ok":false,"rc":1,"error":"invalid_request"}` | 1 |
| 权限 / 超时 / 其他 | `{"ok":false,"rc":N,"error":"<error>"}` | N |

---

## 5. 前端安全契约

1. JS 只经 `read(op, params)` 适配器获取数据（生产 = KernelSU WebUI Bridge →
   `su-scheduler webui`；主机/开发 = `./api?op=...`）。
2. 页面**不**：读取数据目录、调用系统命令、使用动态代码求值、document.write、
   拼接 innerHTML。
3. 动态内容一律 `textContent` 渲染 → `<script>`/引号/换行只会作为文本显示。

---

## 6. 版本与命名空间

- Runtime 库版本 `RUNTIME_LIB_VERSION=1.16.0`（§22 新增）。
- 新 IPC op 白名单计数：12（P3-04）+ 4（P3-05 只读）= **16**。
- 函数前缀：`web_`（函数）/ `webv_`（内部全局）；注册进 `runtime_lib_selfcheck`。
