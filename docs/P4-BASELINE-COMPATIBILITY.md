# Su Scheduler — P4 基线兼容性清单（P4-BASELINE-COMPATIBILITY）

> **任务**：P4-01 · P3 发布缺口与基线冻结（本文件为「P4 基线兼容性清单」交付物）
> **日期**：2026-09-04
> **基线**：Git `main` @ `a6fcc94`（P3-10 之后）+ P4-01 工作树（docs/tests 变更）。
> **用途**：P4（Dependency / Condition / 任务链）开发期间**必须持续保持兼容**的 P3
> 冻结契约清单。任何 P4 改动若破坏下表任一项 = 基线回归，禁止合入。
> **依据**：AGENTS §2 约束 C1–C5、docs/P4-DEPENDENCY-REQUIREMENTS.md NF-1..NF-8、
> docs/P3-HANDOVER.md §4/§7、docs/P3-ARCHITECTURE-DECISIONS.md D1–D6。

---

## 1. 校验方式约定

- 每一项给出：**冻结契约** + **守护测试/命令** + **回归判定**（出现 FAIL 即基线破坏）。
- 全量入口：`bash tests/run_tests.sh`（WSL/Linux，L1+L2+L4）；真机：
  `bash tests/p3-device/smoke.sh --with-device`（无设备时以 DEVICE_SKIPPED 明示，
  不冒充通过）。

---

## 2. 兼容性清单（P4 改动须逐项通过）

| # | 类别 | 冻结契约 | 守护测试 / 命令 | 回归判定 |
| :-- | :-- | :-- | :-- | :-- |
| B1 | 配置格式 | `config.txt` 行格式 `<trigger> <command>; : <modifiers>` 与全部已文档化触发格式（boot / HHMM / HH:MM / weekly / nweekly / monthly / nmonthly / yearly）**零变更**（AGENTS C4） | `tests/legacy/golden.sh` + `tests/cli/test.sh` + `tests/parsing/*`（T1 fixtures） | 全部 [PASS]；fixtures 与 golden 输出逐字一致 |
| B2 | 解析语义 | `parse_modifiers` / `extract_command` / heredoc（`<<EOF`）/ modifiers（--run-once-now/--delete/--notify*/--msg/--interactive/--termux）语义锁定，不做「应该怎样」式主观修正 | `tests/legacy/*`、`tests/parsing/*` | [PASS]；无生产解析函数改动 |
| B3 | Legacy 执行路径 | 旧 daemon 主循环时间匹配、boot 扫描、`execute_task`（SYSTEM/TERMUX/INTERACTIVE）**持续可运行**（C2），不得替换为第二执行器 | `tests/execution/action-run/test.sh`、`tests/trigger/test.sh`、`tests/p3-integration` item 4/6 | [PASS]；legacy 模式任务真实执行 |
| B4 | 模块版本一致性 | 模块 v1.6.8 的 8 处一致性（module.prop / build.sh / 两 bin / README / update.json / .su-scheduler-docs） | `tests/p1-build/build_check.sh` | PASS=26 FAIL=0 |
| B5 | Runtime 库 | `RUNTIME_LIB_VERSION`（现 1.24.0，P4-06 Condition 受限表达式引擎递增）存在且语义化版本格式；模块发布时打包的库版本与文档记录一致 | `tests/p3-integration`（dash -n + selfcheck）+ `docs/P4-RUNTIME-VERSION-CHECK.md` 方案 | [PASS]；daemon log `Runtime library loaded (v1.24.0)` |
| B6 | 单实例与生命周期 | daemon 单实例锁（/dev/.su_scheduler.lock）、crash-guard 降级/节流/优雅重置、重启残留 state_rehydrate | `tests/crashguard/test.sh`（41）、`tests/lifecycle-prod/test.sh`（27）、`tests/p2-integration` | [PASS]；无第二常驻循环（C5） |
| B7 | IPC 协议 | `REQ_ID\|OP\|PARAMS` 固定格式 + IPC_WHITELIST（19 op）+ base64 值 + 原子响应 + 6 类错误码；**`\|` 字段切分必须用 `cut`**（P3-10 D-IPC，mksh 兼容），禁止 `${var#*\|}`/`${var%%\|*}` | `tests/ipc/test.sh`（64）+ `tests/ipc/security.sh`（17）+ `tests/p3-integration` item 7/8/14 | [PASS]；真机 7/8/14 PASS（P4-01 复验） |
| B8 | WebUI 数据面 | 只读 Reader 输出统一 JSON、JSON 转义防注入、三态、有界日志；WebUI 不直执 Root | `tests/webui/read-only.test.sh`（24）+ `tests/webui/security.test.sh`（15） | [PASS] |
| B9 | Task Editor / 配置权威 | `tcfg_*` 原子写（tmp+mv）、payload id 一致性、失败旧配置逐字节不变、回滚 | `tests/config-v2/test.sh`（44）+ `tests/config-v2/validation.sh`（40）+ `tests/webui/editor.test.sh`（28） | [PASS] |
| B10 | Task 控制 | `tctl_*` 统一控制 API + TSM 强制、skip 策略、只杀本运行目录 pid | `tests/task-control/test.sh`（45） | [PASS] |
| B11 | 安全边界 | `secv_*` 输入/路径/权限门、App Action 规范 argv 拒绝注入、IPC 频率限制、资源上限 | `tests/security/fuzz.sh`（19）+ `tests/security/path-validation.sh`（9）+ `tests/security/permission.sh`（5）+ `tests/resource/stress.sh`（10） | [PASS] |
| B12 | service.sh | FBE 等待 + 既有看护循环**原样**（C5，不新增/增强 Watchdog） | `git diff`（service.sh 零改动）+ `tests/p1-device/smoke.sh`（真机 boot 链） | service.sh 无 diff；真机 daemon 开机 Alive |
| B13 | P1+ 禁止项 | 不实现 WebUI（P1 范畴已实现）/ 增强 Watchdog / Dependency（P4 才实现）/ DAG / 云同步 / 多设备（P4 禁止） | `git grep` 无占位目录/接口；本清单 §4 | 无新增占位 |
| B14 | 状态机 | P3 状态机 11 态 + TSM 允许边；WAITING 为 reserved 态（P4 才接线），P3 不得出现 WAITING 假实现 | `tests/state-machine/test.sh`（183） | [PASS]；`dependency=`/`condition=` 字段仍为空（P3 未实现） |

---

## 3. P4 新增改动的最小侵入面（对照表）

P4 只允许在下述既有点上「叠加」，不得另起炉灶（依据 P4-DEPENDENCY-REQUIREMENTS §1）：

| 接线点 | P4 允许改动 | 冻结约束 |
| :-- | :-- | :-- |
| WAITING 状态机 reserved 边 | 接线 `PENDING>WAITING` / `WAITING>STARTING` / `WAITING>FAILED` 等 | 不新增状态；TSM 允许边表保持权威 |
| schema `dependency=`/`condition=` | 定义解析语义（校验期拒绝环/未知 id） | 不改变既有字段解析；Task v2 格式（key=value）不变 |
| Registry `scheduler_tick` 决策 | 触发匹配后插入门控层（依赖/条件满足才执行，否则 WAITING） | 不替换 TriggerProvider→ActionProvider 链路 |
| IPC 白名单 | 新增 op 或复用 VALIDATE_TASK 预览 | 走 P3-04 协议（base64 + 原子响应 + 错误码）；写 op 仅 Managed |
| WebUI 数据面 | GET_TASK_DETAIL/GET_SUMMARY 增加 WAITING 计数与依赖状态字段 | 统一 JSON 契约不破坏既有字段 |
| `tcfg_validate_task` | 依赖解析/循环检测（rc 非 0 拒绝 + 原配置逐字节不变） | 沿用 P3 原子性/回滚 |

---

## 4. 禁止触碰清单（P4 全期）

1. `service.sh` 既有看护循环原样（C5）。
2. Legacy `config.txt` 解析与执行路径不删、不改格式（C2/C4）。
3. 不引入运行期非 Android 标准依赖（Python/Node/busybox 硬依赖）（C3）。
4. 不在 WebUI 直执 Root 求值 Condition；Condition 表达式不引入任意 Shell 求值
   （无 `eval`/`sh -c` 拼接）（P4-DEPENDENCY-REQUIREMENTS §4）。
5. WAITING 必须**有界**（超时/上限 → `WAITING>FAILED`），禁止依赖永不满足时
   任务永久悬挂。
6. 不实现通用 DAG 拓扑、云端同步、多设备（P4 范围外）。

---

## 5. 基线与验证状态（P4-01 冻结时刻）

| 项 | 状态 |
| :-- | :-- |
| 宿主门禁（WSL） | ALL SUITES GREEN，1631 PASS / 0 FAIL |
| p3-integration | 48 PASS / 0 FAIL |
| p1-build | 26 PASS / 0 FAIL / 0 SKIP |
| 真机冒烟（KernelSU × Android 16） | 28 PASS / 0 FAIL / 0 BLOCKED |
| D-IPC 三项 | 7/8/14 PASS（不再 BLOCKED） |
| 设备矩阵 | KernelSU × Android 16 ✅；其余 14 格 ⏳ 发布限制（不伪造） |
