# Su Scheduler — P4 Dependency 需求输入（P4-DEPENDENCY-REQUIREMENTS）

> **任务**：P3-10 · P3 出口评审与发布准备（本文件为「P4 Dependency 需求输入」交付物）
> **性质**：P4（Dependency / Condition / 任务链）特性**需求输入文档**——只定义需求与
> 约束、接线点与验收建议，**不含实现**（P3 禁止提前实现 Dependency/Condition/DAG）。
> **上游**：`docs/P3-HANDOVER.md` §5、`docs/architecture/task-state-machine.md`、
> `docs/architecture/task-editor-schema.md`、`docs/architecture/registry-scheduling.md`
> **日期**：2026-09-03

---

## 0. 目的与范围

为 P4 的 **Dependency（任务间依赖/条件触发/链式执行）** 提供需求输入，明确：

1. P3 已冻结的**接线点**（不得破坏）；
2. P4 的功能需求与非功能约束；
3. 禁止事项（防止把 P3 未实现项做成占位）。

> 本文件是**输入**，不是 P4 设计与实现。P4 开工时须以此为准细化任务清单，并逐项
> 通过「先写 FAIL 测试 → 实现 → 全量回归」流程。

---

## 1. P3 已冻结的接线点（Dependency 的落点）

P3 已为 Dependency 预留以下结构，P4 必须**在其上接线**而非另起炉灶：

| 接线点 | 位置 | 现状 |
| :-- | :-- | :-- |
| **WAITING 状态** | `task-state-machine.md` §2（11 态之一）；TSM reserved 边 | 状态机已定义，**未接线执行逻辑** |
| **reserved 边（门控）** | `PENDING>WAITING`（time_trigger 被依赖/条件阻塞）、`WAITING>PENDING`（rearm 门控解除）、`WAITING>STARTING`（门控解除→启动）、`WAITING>FAILED`（依赖终态失败）、`FAILED>WAITING`（重试退避） | 已定义，未接线 |
| **schema `dependency=` 字段** | `task-info` 输出空字段；Task v2 schema 预留 | 字段声明为空，未定义解析语义 |
| **schema `condition=` 字段** | `task-info` 输出空字段 | 同上 |
| **Editor 表单** | `task-editor-schema.md`；Trigger 未实现项 disabled | 预留位置，未开放 |
| **Registry 调度决策** | `registry-scheduling.md`（`scheduler_tick` 决策执行） | 当前决策 = 触发→动作；P4 加门控层 |

---

## 2. 功能需求

### 2.1 Dependency（任务依赖）

- **FR-1 定义**：任务可声明 `dependency=<task-id>[:<state>]`，表示「仅当被依赖任务
  处于指定终态（或已执行成功）后才允许本任务执行」。
- **FR-2 门控语义**：触发匹配但依赖未满足 → 进入 **WAITING**（`PENDING>WAITING`
  reserved 边）；依赖满足 → `WAITING>STARTING`；依赖任务终态失败（如 FAILED）→
  `WAITING>FAILED`（或按策略跳过）。
- **FR-3 多依赖**：支持 `dependency=a,b,c`（AND 语义；OR/条件表达式归 Condition）。
- **FR-4 循环检测**：依赖图必须无环；检测到环 → 配置校验拒绝（`tcfg_validate_task`
  后端权威，rc 非 0），原配置逐字节不变（沿用 P3 原子性）。
- **FR-5 依赖任务不存在**：校验期拒绝（依赖指向未知 task id → 配置无效）。

### 2.2 Condition（执行条件表达式）

- **FR-6 定义**：任务可声明 `condition=<expr>`，触发匹配后先求值，为真才执行。
- **FR-7 表达式域**：建议有限表达式（如 `{{task.state(a)}}=HEALTHY`、时间/环境变量/
  文件存在性谓词），**不引入任意 Shell 求值**（安全边界，见 §4）。

### 2.3 链式执行 / 顺序

- **FR-8 链**：`dependency` 提供「完成后再启动」的链式执行基础；不实现通用 DAG 拓扑
  （除非 P4 显式立项）。

---

## 3. 非功能约束（硬性）

| ID | 约束 | 来源 |
| :-- | :-- | :-- |
| **NF-1** | 不改变 `config.txt` 格式（C4）；Dependency 仅出现在 Task v2（managed）域 | C4 |
| **NF-2** | 不删除/替换既有 legacy 解析与执行路径（C2） | C2 |
| **NF-3** | 运行期仅 Android 标准工具（sh/sed/grep/awk/cut/date 等）；无 Python/Node/busybox 硬依赖 | C3 |
| **NF-4** | `service.sh` 看护原样，不新增第二常驻循环；依赖门控在既有 daemon 主循环内叠加 | C5 |
| **NF-5** | WebUI 不直执 Root；Dependency 配置经 IPC `EDIT_TASK`/`VALIDATE_TASK` 白名单路径 | P3 安全边界 |
| **NF-6** | 配置写入原子（tmp+mv）+ 可回滚；Dependency 非法 → 拒绝且原配置逐字节不变 | P3 §3.3/§3.8 |
| **NF-7** | IPC `|` 字段切分禁用 `${var#*|}`/`${var%%|*}`（mksh 兼容，P3-10 D-IPC 修复） | P3-DEVICE-MATRIX §3 |
| **NF-8** | 新增解析必须为可移植 POSIX；每次改动附 FAIL→PASS 回归测试 | AGENTS |

---

## 4. 安全边界（P4 必须延续并加强）

1. **不引入任意 Shell 求值**：Condition 表达式必须用受限解释器/白名单谓词求值，
   禁止 `eval`/`sh -c` 拼接用户表达式（防注入）。
2. **循环/未知依赖在配置校验期拒绝**，绝不允许运行时死循环或对不存在任务的悬挂等待。
3. **WAITING 需有界**：门控等待应有超时/上限（防止依赖永不满足时任务永久 WAITING），
   超出 → `WAITING>FAILED`（reserved 边已有）。
4. **依赖状态判定**只读既有 `state.txt`/Registry 快照（P3 数据面），不产生副作用。
5. 新增 IPC op（如 `VALIDATE_DEPENDENCY` 预览）须加白名单并走 P3-04 协议（base64 +
   原子响应 + 错误码）。

---

## 5. 与 P3 各层的关系（P4 改造面）

| P3 层 | P4 影响 |
| :-- | :-- |
| §19 `tcfg_*` 权威存储 | 扩展 schema 校验（`dependency=`/`condition=` 字段）；`tcfg_validate_task` 加依赖解析/循环检测 |
| §20 `scheduler_tick` 决策 | 触发匹配后插入**门控判定**：依赖/条件满足 → 执行；否则 → WAITING |
| §21 `ipc_*` | 增加/扩展 op 或复用 `VALIDATE_TASK` 做依赖预览；白名单更新 |
| §22 WebUI 只读数据面 | `GET_TASK_DETAIL`/`GET_SUMMARY` 增加 WAITING 计数与依赖状态字段 |
| §23 Editor | Advanced 分组开放 Dependency/Condition 字段（当前 disabled） |
| §24 `tctl_*` 控制 | WAITING 态下 start → 强制（跳过门控，`manual_exec` reserved 边）或按策略拒绝 |
| 状态机 | 接线 `PENDING>WAITING`/`WAITING>*` reserved 边（TSM 已定义，只需在调度层触发 cause） |

---

## 6. 建议验收（P4 立项时细化）

```bash
bash tests/run_tests.sh                       # 全量回归必须全绿（既有 P3 golden 不回退）
bash tests/p3-integration/test.sh             # 既有综合回归不回退
bash tests/p4-dependency/test.sh              # P4 新增套件（先 FAIL 后 PASS）
```

必测项：
1. 依赖满足 → `WAITING>STARTING` 执行；未满足 → 进入 WAITING；
2. 依赖任务终态失败 → 本任务 `WAITING>FAILED`；
3. 依赖环 / 依赖不存在 → 配置校验拒绝，原配置逐字节不变；
4. Condition 假 → 不执行（无副作用）；真 → 执行；
5. 注入尝试（`condition=…; rm -rf /`）→ 拒绝，零 exec；
6. mksh 兼容（`cut` 路径，无 `|`-in-pattern 展开）。

---

## 7. 禁止事项（P3 已声明，P4 亦然）

- 不实现通用 **DAG 拓扑调度**（除非显式立项）；不实现**云端同步/多设备**；
- 不新增第二常驻 daemon 循环（C5）；
- 不在 WebUI 直执 Root 求值 Condition（D3/安全边界）；
- 不把「预留字段/预留边」当作「已实现」在任何文档宣称（AGENTS 诚实原则）。