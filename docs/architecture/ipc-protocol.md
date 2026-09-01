# 本地 IPC 控制面协议 ADR（P3-04）：WebUI ↔ daemon 受控通信边界

> **状态**：已接受（P3-04 冻结）
> **作者/日期**：P3-04 · 2026-09-01
> **关联**：`docs/P3-04.md`（执行记录）、P3-02（config-authority ADR）、
> P3-03（registry-scheduling ADR）、P2-06/07/12/13（Action/State/Supervisor）

## 问题

WebUI（浏览器侧）需要控制 daemon（启停任务、查状态、改配置），但**禁止** WebUI
JavaScript 直接执行 shell，也禁止把任意 shell 字符串当作控制指令传入 daemon。
需要一个受控、可验证、可区分错误、非阻塞、防注入的本地 IPC 边界。

## 决策（D1–D12）

### D1 传输：文件请求/响应通道（拒绝 FIFO 的理由）

- **采用** `$DATA_DIR/ipc/`（chmod 700，root-only）下的请求文件 + 响应文件：
  - `ipc/requests/<req_id>.req` — 客户端原子写（tmp+mv），单行请求；
  - `ipc/responses/<req_id>.resp` — daemon 原子写回（tmp+mv）；
  - `ipc/daemon.pid` — daemon 存活标记（客户端判 daemon_unavailable）。
- **不采用 FIFO**：POSIX sh 无法便携地非阻塞读取空 FIFO（read 阻塞；需
  O_NONBLOCK/select/timeout 等非 POSIX 手段），会违反「IPC 超时不阻塞 daemon」。
  文件通道在 Android toybox 与宿主机行为一致、可逐字节断言，且等价满足「如果
  使用 FIFO，必须」的全部条款（daemon 创建 / 0700 / 固定格式 / 长度受限 /
  白名单 / 唯一 ID / 原子响应）。

### D2 请求行格式（固定、限长）

单行 ≤ 4096 字节：

```
REQ_ID|OP|k1=b64&k2=b64
```

- `REQ_ID`：`^[A-Za-z0-9._-]{1,64}$`，客户端生成，每请求唯一；
- `OP`：12 个白名单操作之一（见 D6）；
- 参数：`&` 分隔 `key=base64value`；键 `[A-Za-z0-9._-]+`；**值一律 base64**
  （字母表无 Shell 元字符）——请求体在解析层不可能携带可被解释的元字符。

### D3 响应文件格式（原子）

首行 + 载荷行：

```
REQ_ID|OP|RC|ERROR
<payload line 1>
<payload line 2>
```

写回 = `printf > tmp && mv tmp resp`（原子；无半写可见）。

### D4 错误码（可区分）

| rc | error | 语义 |
| :-- | :--- | :--- |
| 0 | ok | 成功 |
| 1 | invalid_request | 格式/未知 op/坏 base64/未知参数键/超长 |
| 2 | permission_denied | 请求目录不可写 |
| 3 | task_not_found | 引用未知任务 id |
| 4 | configuration_invalid | 写操作在 legacy / VALIDATE 失败 / 命令缺省或多行 |
| 5 | operation_timeout | 客户端等待超时 |
| 6 | daemon_unavailable | daemon.pid 缺失或进程已死 |

### D5 安全边界（服务端绝不 eval）

- 服务端只做：固定格式解析 + 字符集/长度校验 + 白名单校验 + base64 解码为数据。
- **绝不把请求内容交给 shell 解释/执行**；任何校验失败 → 只写 invalid_request
  响应，零副作用（不启动、不写任务、不触发 Root action）。
- `ipc_has_newline` 拒绝多行命令（task 文件按单行 key=value 存储，防污染）。

### D6 操作白名单（12 op）与参数键白名单

| OP | 允许参数键 | 说明 |
| :--- | :--- | :--- |
| GET_TASKS | （无） | 列出 registry 任务 `id|name|trigger|enabled|state` |
| GET_TASK_STATUS | id | 任务字段 key=value |
| GET_TASK_LOG | id lines | run dir output.log 尾部（≤500 行） |
| VALIDATE_TASK | name trigger command enabled termux interactive notify_start notify_end msg | 临时文件校验，不持久化 |
| CREATE_TASK | id name trigger command enabled termux interactive notify_start notify_end msg | **仅 managed**；写 task-config + reload |
| UPDATE_TASK | id name trigger command enabled termux interactive notify_start notify_end msg | **仅 managed**；原子更新 + 校验 + reload |
| DELETE_TASK | id | **仅 managed**；移除 + reload |
| ENABLE_TASK / DISABLE_TASK | id | **仅 managed**；enabled=1/0 + reload |
| START_TASK / STOP_TASK / RESTART_TASK | id | 命令取自已校验任务文件；**请求不可注入命令** |

未知参数键 → invalid_request（例：`START_TASK` 带 `command=` → 拒绝）。

### D7 写操作仅 managed（config.txt 不被 WebUI 触碰）

legacy 模式 config.txt 是用户手工权威，行级改写风险大；P3-02 已把 task-config
立为 canonical Task 存储。因此 CREATE/UPDATE/DELETE/ENABLE/DISABLE 仅 managed；
legacy → configuration_invalid（提示先 `task-config import`）。只读/控制 op
（GET_*/START/STOP/RESTART）在两种模式均可（经 Registry 快照 + 运行态）。

### D8 START/STOP/RESTART 语义

- **START_TASK**：仅取 id → 解析 canonical（registry 或 idmap）→ 从任务文件读
  `action.command` 及 modifier 字段 → `action_run`（统一 ActionProvider 入口，
  落 execute_task）。已 RUNNING/STARTING → ok「already ...」**不重复启动**。
- **STOP_TASK**：`supervisor_stop_task <run_dir> force=1`（TERM→KILL）。
- **RESTART_TASK**：停（force）+ 强启（跳过 running 检查）。

### D9 重复请求幂等（不重复启动）

- 同 req_id：响应文件已存在 → 服务端丢弃新请求（不重处理）。
- 不同 req_id 但任务已运行：START 前置状态检查 → 不重复启动。
- 双保险覆盖「重复请求不会重复启动任务」。

### D10 非阻塞与超时（daemon 不被 IPC 阻塞）

- daemon 主循环 nap 段改为「逐秒逼近下一分钟 + 每秒 `ipc_server_poll`」；外层
  `while true` 仍恰 1 处、调度周期仍以分钟推进（P3-03 锚点不变）。
- `ipc_server_poll` 单轮有界（IPC_POLL_MAX=64 请求），纯目录扫描，永不阻塞。
- 客户端 `ipc_client_send` 有界等待（默认 5s，`SU_SCHEDULER_IPC_TIMEOUT` 可调）
  → 超时返回 rc 5 operation_timeout。

### D11 权限模型（未授权路径无法修改 Task）

- `ipc/` 及子目录 `chmod 700`（root-only）：非 root 进程无法写入请求。
- 客户端写请求前检查 `[ -w requests ]` → 不可写即 rc 2 permission_denied。
- daemon 停止（无 daemon.pid / 死 pid）→ rc 6 daemon_unavailable。

### D12 命名空间与版本

- 新函数一律 `ipc_` 前缀、内部全局 `ipcv_` 前缀（防覆盖调用方全局，同 P3-03
  教训）；全部注册进 `runtime_lib_selfcheck`。
- `RUNTIME_LIB_VERSION` 1.14.0 → **1.15.0**（新增 §21）。

## 客户端入口

`su-scheduler ipc <OP> [key=value ...]`（CLI 子命令，RUNTIME_LOADED 门控）：

```sh
su-scheduler ipc GET_TASKS
su-scheduler ipc GET_TASK_STATUS id=task_0930_1
su-scheduler ipc START_TASK id=task_0930_1
su-scheduler ipc CREATE_TASK trigger=09:30 command="echo hi"
```

客户端把所有 value 用 `ipc_b64enc` 编码后落盘请求；响应打印到 stdout；退出码 =
rc（0/1/2/3/4/5/6）。WebUI 后端后续只经此客户端与 daemon 交互，浏览器 JS 永不
直接执行 shell。
