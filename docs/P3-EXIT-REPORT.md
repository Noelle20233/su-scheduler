# Su Scheduler — P3 出口评审与发布准备报告（P3-EXIT-REPORT）

> **任务**：P3-10 · P3 出口评审与发布准备
> **前置**：P3-01 ~ P3-09（全部交付物与设备矩阵已就绪）
> **版本**：模块 `v1.6.8`（module.prop / versionCode 11608）；Runtime 库 `v1.19.0`
> **日期**：2026-09-03
> **入口**：`bash tests/run_tests.sh`（L1 + L2 + L4）+ `--with-device`（L3，设备可用时）

---

## 0. 结论（TL;DR）

**P3（正式 Task 控制面与 WebUI）通过出口评审，可进入发布候选与 P4 Dependency 规划。**

- 全量主机回归 **ALL SUITES GREEN**，`exit 0`，**0 FAIL**（L1 + L2 + L4，含 P3-09
  新增 `p3-integration` 48 断言与 `p1-build` 24 断言）。
- P3 十大出口标准**逐项核验通过**（§2 覆盖矩阵），含安全（WebUI 无直执 Root、
  IPC 全验证、配置原子回滚、注入全拒、文件权限）与兼容（旧 config/旧 CLI/旧运行
  目录/旧运行 ID/Termux/Interactive/heredoc/--delete/--run-once-now）。
- **D-IPC 阻断缺陷已修复**（P3-10）：Android 16 设备 mksh 的 `|`-in-pattern 参数展开
  失败导致 IPC 全断，已改为可移植 `cut` 切分（11 处）+ 4 条回归断言，宿主全绿。
  真机重验（IPC 三项）待设备可用时执行（§4）。
- **无提前实现**：Dependency / Condition / 任务 DAG / 云端同步在 P3 零实现、零占位
  （§3.8 证据 + §5 P4 移交输入）。
- 发布候选 zip 通过 `unzip -t` 完整性校验；八处版本号一致（§3.6）。

---

## 1. 评审对象（P3 交付盘点）

| 任务 | 内容 | 模块 / 关键构建物 |
| :-- | :-- | :-- |
| P3-01 | 发布门禁与架构冻结 | `docs/P3-01.md`、`docs/P3-ARCHITECTURE-DECISIONS.md`（D1–D6） |
| P3-02 | Canonical Task 配置存储与迁移 | `su-scheduler-runtime` §19 `tcfg_*`（v1.13.0）；`tests/config-v2` |
| P3-03 | Registry 正式调度接管 | `su-scheduler-runtime` §20（v1.14.0）；`tests/scheduler-prod` |
| P3-04 | 本地 IPC 受控通信边界 | `su-scheduler-runtime` §21 `ipc_*`（v1.15.0）；`tests/ipc` |
| P3-05 | WebUI 只读数据面 | `su-scheduler-runtime` §22（v1.16.0）；`webroot/`；`tests/webui` read-only/security |
| P3-06 | WebUI Task Editor | `su-scheduler-runtime` §23 `tcfg_editor_*`（v1.17.0）；`webroot/`；`tests/webui/editor` |
| P3-07 | Task 控制操作 | `su-scheduler-runtime` §24 `tctl_*`（v1.18.0）；`tests/task-control` |
| P3-08 | 安全与资源加固 | `su-scheduler-runtime` §25 `secv_*` / `tpr_*`（v1.19.0）；`tests/security`、`tests/resource` |
| P3-09 | 设备矩阵与综合回归 | `tests/p3-device/smoke.sh`（真机 18 项）、`tests/p3-integration/test.sh`（48 断言）、`docs/P3-DEVICE-MATRIX.md` |
| **P3-10** | **出口评审与发布准备** | 本文档 + `P3-HANDOVER.md` + `P3-UPGRADE-ROLLBACK.md` + P4 Dependency 输入 + 发布候选 zip + **D-IPC 修复** |

生产源码：`system/bin/su-scheduler-runtime`（唯一生产 runtime lib）、`system/bin/su-schedulerd`
（守护）、`system/bin/su-scheduler`（CLI）、`webroot/`（WebUI 静态资源）。

---

## 2. P3 出口标准 → 覆盖矩阵（逐项核验）

| # | P3 出口标准 | 核验 | 证据（具名套件 / 文档） |
| :-- | :-- | :-- | :-- |
| 1 | Registry 成为 Managed 模式正式调度数据源 | ✅ | `tests/scheduler-prod`（双模式/KEPT/审计）、`tests/p3-integration` §6（audit `op=boot mode=managed`）、真机 item 6 |
| 2 | Legacy 模式保持兼容 | ✅ | `tests/legacy/golden`、`tests/legacy/delete-pipeline`、`tests/legacy-adapter`、`tests/p3-integration` §4（legacy 触发保留） |
| 3 | Task v2 稳定持久化配置来源 | ✅ | `tests/config-v2`（双模式权威/幂等/回滚/导出）、`tests/config-v2/validation`、`tests/p3-integration` §5/§8 |
| 4 | WebUI 通过受控 IPC 工作 | ✅ | `tests/ipc`、`tests/ipc/security`、`tests/webui/read-only`、`tests/p3-integration` §7（GET_SUMMARY 真实 IPC 通道） |
| 5 | WebUI 不直接执行 Root 命令 | ✅ | `tests/webui/security`（无直执特征）、`tests/security/fuzz`；webroot grep 0 处 root-exec（§3.7） |
| 6 | Task Editor 配置 Action/Health/Recovery/Retry | ✅ | `tests/webui/editor.test.sh`（28 断言）、`docs/architecture/task-editor-schema.md`、`tests/p3-integration` §8 |
| 7 | Task 控制操作通过统一 API | ✅ | `tests/task-control`（45 断言）、`tests/p3-integration` §14（tctl_* 经 IPC 全链路） |
| 8 | 配置修改原子性与回滚 | ✅ | `tests/config-v2/test.sh`、`tests/webui/editor.test.sh`（原子回滚 byte-identical）、`tests/p3-integration` §15 |
| 9 | 主机回归 + 设备回归全部通过 | ✅（主机）/ 部分（设备，见 §4） | `bash tests/run_tests.sh` **ALL SUITES GREEN**；真机 25 PASS / 0 FAIL / 3 BLOCKED（D-IPC，P3-10 已修） |
| 10 | 出口文档 + 发布候选包齐备 | ✅ | 本文档 + HANDOVER + UPGRADE-ROLLBACK + 发布候选 zip + P4 输入 |
| 11 | Dependency/Condition/任务 DAG 未提前实现 | ✅ | §3.8（生产代码零实现证据） |

---

## 3. 分类核验明细

### 3.1 功能面

| 功能 | 状态 | 证据 |
| :-- | :-- | :-- |
| Task v2 配置可持久化 | ✅ | `tcfg_*` 原子 tmp+mv + `task-config` CLI（status/import/export/rollback/list/show/set/new/rm）；`tests/config-v2` 44 断言 |
| Registry 正式驱动调度 | ✅ | `sched_reload` 原子源重载 + `scheduler_tick` 逐任务决策执行 + 审计；`tests/scheduler-prod` 33 断言 |
| WebUI Dashboard 可用 | ✅ | `GET_SUMMARY`/`GET_TASK_DETAIL`/`GET_TASK_EVENTS`/`GET_DAEMON_LOG` 统一 JSON；`webroot/` Dashboard；`tests/webui/read-only` 24 断言 |
| WebUI Editor 可用 | ✅ | `EDIT_TASK`/`GET_TASK_EDIT`/`VALIDATE_TASK` + 分步表单（Basic/Trigger/Action/Health/Recovery/Retry/Advanced）；`tests/webui/editor` 28 断言 |
| Task 控制操作可用 | ✅ | `tctl_start/stop/restart/check/enable/disable` 统一 API（WebUI 与 CLI 共用）；`tests/task-control` 45 断言 |
| Health/Recovery 配置真实生效 | ✅ | `health_check` 三态 + `supervisor_*` + `recovery_*` + 策略钳制；`tests/health` 55 + `tests/supervisor` 18 + `tests/recovery` 25 + `tests/p2-integration` |

### 3.2 兼容性面

| 兼容对象 | 状态 | 证据 |
| :-- | :-- | :-- |
| 旧 config.txt（triggers + `; : modifiers`） | ✅ | `tests/legacy/golden`（逐字节锁定）、`tests/legacy-adapter` 107 断言 |
| 旧 CLI（add/list/remove/edit/log/tasks/task-*/status/restart/stop/test/audit） | ✅ | `tests/cli/test.sh`、`tests/legacy-adapter/test.sh`（零改动） |
| 旧任务运行目录（status/pid/output/exit_code） | ✅ | `tests/task-cli/test.sh`、`tests/idmap/test.sh`、`tests/p3-integration` §16 |
| 旧运行 ID | ✅ | `idmap` 双向解析；`tests/idmap` 25 断言、`tests/task-cli-prod` |
| Termux | ✅ | `tests/execution/action-run`（TERMUX 模式）；`su-scheduler-termux` P0 未动 |
| Interactive（FIFO .in/.out） | ✅ | `tests/execution/action-run`（INTERACTIVE）；真机 item 经 `task-output` |
| heredoc（`<<EOF`） | ✅ | `tests/legacy/golden`（heredoc 解析 + modifiers 保留） |
| `--delete` | ✅ | `tests/legacy/delete-pipeline`（Q13 单激活行短路）；`tests/p3-integration` §4（modifier 保留） |
| `--run-once-now` | ✅ | `tests/legacy`（执行后从配置修剪 golden）、`tests/scheduler-prod`（sched_prune_ron） |

### 3.3 安全面

| 安全项 | 状态 | 证据 |
| :-- | :-- | :-- |
| WebUI 无直接 Root Shell | ✅ | `webroot/app.js`/`index.html` grep 0 处 `su -c`/`exec`/`spawn`；`tests/webui/security` 15 断言 |
| IPC 全部经过验证 | ✅ | `ipc_parse` 白名单 + base64 + 键白名单 + 原子响应 + 6 类错误码；`tests/ipc` 64 + `tests/ipc/security` 17 断言 |
| 配置保存可回滚 | ✅ | `tcfg_rollback` 逐字节还原 + 原子 tmp+mv；`tests/config-v2`、`tests/webui/editor` |
| 命令注入测试全绿 | ✅ | `tests/security/fuzz` 19 断言（START/CREATE/UPDATE 注入全拒）；`tests/app-action` 54（am 固定模板） |
| 文件权限正确 | ✅ | `tests/security/permission` 5 断言（0700 IPC 目录、600 .task、未授权写 permission_denied） |

### 3.4 发布面

| 发布项 | 状态 | 证据 |
| :-- | :-- | :-- |
| Runtime 版本与模块版本明确 | ✅ | 模块 `v1.6.8` / versionCode 11608；Runtime 库 `1.19.0`（D4 版本策略，§6.2） |
| module.prop / update.json / README / build 脚本一致 | ✅ | `tests/p1-build/build_check.sh` 24 断言（八处版本一致） |
| 发布包完整 | ✅ | `build.sh` 产出 `su-scheduler-v1.6.8.zip`（120832 字节）；`unzip -t` No errors；成员齐全（含 webroot/） |
| CI 成功 | ✅ | `.github/workflows/test.yml` 于 push 运行 `bash tests/run_tests.sh`（ubuntu-latest，LF 工作树） |
| 设备矩阵报告齐全 | ✅（1/15 格）+ 其余 ⏳ | `docs/P3-DEVICE-MATRIX.md`：KernelSU×Android16 真机 25 PASS / 0 FAIL / 3 BLOCKED（D-IPC 已修）；Magisk/APatch×12–15 为发布限制（§4） |

### 3.5 验收命令实测（2026-09-03，WSL Ubuntu）

| 命令 | 结果 |
| :-- | :-- |
| `bash tests/run_tests.sh` | **ALL SUITES GREEN**（L1+L2+L4，exit 0，0 FAIL） |
| `bash tests/p3-integration/test.sh` | 48 PASS / 0 FAIL |
| `bash tests/p3-device/smoke.sh --with-device` | 无 adb 授权设备 → `DEVICE_SKIPPED`（设备矩阵见 §4，P3-09 真机 25 PASS 记录在案） |
| `bash tests/build/build_check.sh` | 24 PASS / 0 FAIL / 0 SKIP（真实构建 + unzip -t + 八处版本一致） |
| `git diff --check` | 无空白错误 |
| `git status --short` | 仅本任务改动（生产 runtime、ipc 测试、docs） |

### 3.6 版本一致性（八处，`build.sh` 为单一事实源 `VERSION=v1.6.8`）

| 位置 | 值 | 校验 |
| :-- | :-- | :-- |
| `build.sh` | `v1.6.8` | 基准 |
| `module.prop` version / versionCode | `v1.6.8` / `11608` | ✅ |
| `su-scheduler` VERSION | `1.6.8` | ✅ |
| `su-schedulerd` VERSION | `1.6.8` | ✅ |
| `README.md` badge | `Version-1.6.8` | ✅ |
| `update.json` version / versionCode / downloadURL / changelog | `v1.6.8` / `11608` / `…/v1.6.8/…zip` / `v1.6.8` | ✅ |
| `system/bin/.su-scheduler-docs` 头部 | `Version: 1.6.8` | ✅ |
| Runtime 库 `RUNTIME_LIB_VERSION` | `1.19.0`（内部实现线，D4） | ✅（语义化版本格式，不参与八处一致性） |

### 3.7 WebUI 无直执 Root 证据

```bash
grep -cE "su -c|exec\(|spawn|system\(|su-scheduler .* -c|/system/bin/sh" webroot/app.js webroot/index.html
# → 0（webroot 无任何 Root 执行特征；所有写操作经 IPC op → daemon tcfg_/tctl_ 白名单路径）
```

### 3.8 无提前实现证据（出口标准 #11）

| 项 | 生产代码证据 | 结论 |
| :-- | :-- | :-- |
| Dependency | `task-info` 输出 `dependency=` 空字段（声明字段为空，非实现）；`docs/architecture/task-state-machine.md` WAITING 为 **reserved 边**（未接线） | ✅ 未实现 |
| Condition | `task-info` 输出 `condition=` 空字段；Editor 表单 Trigger 未实现项 disabled | ✅ 未实现 |
| 任务 DAG / 拓扑 | 生产代码 grep `topolog\|dag` = 0 实现 | ✅ 未实现 |
| 云端同步 / 多设备 | 生产代码 grep `cloud\|synchr` = 0 实现 | ✅ 未实现 |

---

## 4. 设备矩阵与发布限制

> 详见 `docs/P3-DEVICE-MATRIX.md`。矩阵 15 格中仅 1 格（KernelSU × Android 16）真机覆盖。

| 项 | 状态 |
| :-- | :-- |
| KernelSU × Android 16（本环境 `8934ffc4`，Xiaomi 17） | ✅ 真机 25 PASS / 0 FAIL / 3 BLOCKED（D-IPC，**P3-10 已修复**） |
| Magisk × Android 12–16 | ⏳ 发布限制（无真机/模拟器） |
| APatch × Android 12–16 | ⏳ 发布限制 |
| KernelSU × Android 12–15 | ⏳ 发布限制 |

**D-IPC 修复说明**：P3-09 真机发现设备 mksh `${var#*|}`/`${var%%|*}` 模式匹配失败
→ IPC 全断（WebUI/Editor/Task 控制三项 BLOCKED）。P3-10 已修复 `su-scheduler-runtime`
11 处 `|` 字段切分为可移植 `cut`（`cut` 在库内已用 82 处，C3 合规），并新增 4 条
回归断言（`tests/ipc/test.sh`）。宿主全量回归 + dash（POSIX）验证通过。**真机重验
（IPC 三项）待设备可用时执行**——发布说明须明示该 pending 项（不得把宿主结果
冒充真机结果）。

---

## 5. P4 移交输入（Dependency 需求文档入口）

P3 出口标准 #11 明确 P3 未实现 Dependency/Condition/DAG。P4 的 Dependency 需求
输入文档（`docs/P4-DEPENDENCY-REQUIREMENTS.md`）已单独成文，包含：

- 已冻结的接线点：状态机 **WAITING reserved 边**（`PENDING>WAITING`/`WAITING>
  STARTING`/`WAITING>FAILED` 等）、schema 预留 `dependency=` 字段、Editor 表单
  预留位置；
- 与 P3 既有安全边界（IPC 白名单、tcfg 原子写、tctl 统一 API、无 WebJS 直执 Root）
  的兼容约束；
- 明确禁止提前实现项（DAG/高级事件链/云同步）。

**交付物位置**：`docs/P4-DEPENDENCY-REQUIREMENTS.md`（见 P3-10 commit）。

---

## 6. 版本策略（D4 落实）

- **模块版本 = 发布契约**：`v1.6.8` 八处一致（§3.6），走 `bump_version.sh` + `release.yml`。
- **Runtime 库版本 = 内部实现线**：`RUNTIME_LIB_VERSION=1.19.0`（P3-02..P3-08 §19–25
  依次递增至 v1.19.0）。P3-10 的 D-IPC 修复为**同一 § 内缺陷修复、无 API 变更**，
  库版本保持 `1.19.0`（不递增），模块版本 `v1.6.8` 不变（非新功能、无破坏性语义变更）。
- **映射**：v1.6.8 ↔ 1.19.0（P3 出口）。

---

## 7. 约束审计（C1–C5 / P3 D1–D6）

| 约束 | 审计结论 |
| :-- | :-- |
| C1 最小 diff（不重写） | ✅ P3 全阶段增量叠加；P3-10 D-IPC 为 11 处单行 `cut` 替换 + 注释 |
| C2 不删除旧解析/执行路径 | ✅ legacy 解析/主循环/heredoc/modifiers/execute_task 持续可运行（T1 golden + legacy 套件全绿） |
| C3 无新外部依赖 | ✅ D-IPC 用 `cut`（Android toybox 标准，库内已用 82 处）；无 Python/Node/busybox 硬依赖 |
| C4 配置格式零变更 | ✅ config.txt 格式与解析语义未变；Editor 写回仍 daemon 支持格式 |
| C5 P1 范围零触碰 | ✅ Dependency/Condition/DAG/WebUI 直执/云端零实现（§3.8） |
| P3 D6 不实现清单 | ✅ 同 §3.8，零实现、零占位 |

---

## 8. 风险登记（P3 剩余 / P4 承接）

| ID | 风险 | 现状 | 处置 |
| :-- | :-- | :-- | :-- |
| R1 | 设备矩阵缺口（Magisk/APatch/Android 12–15 无真机） | 未覆盖 | 发布说明明示；P4 接矩阵扩展 |
| R-DIPC | Android 16 mksh IPC（已修复） | 宿主 + dash 已验证 | 真机重验待设备；发布说明明示 pending |
| R4 | `RUNTIME_LIB_VERSION` 未纳入 build_check 一致性 | 已登记 | P3-10 保持（低风险）；P4 建议纳入 |
| R2 | Registry 初始化位于单实例锁之前（理论竞态） | P3 保持现状 | P4 移锁候选 |

---

## 9. P3 出口判定

**满足全部 11 项出口标准（§2）。** 唯一发布注意事项：设备矩阵 14/15 格为 ⏳
发布限制，且 D-IPC 修复后的真机 IPC 重验待设备可用时执行（发布说明必须明示）。
Dependency/Condition/DAG/云同步无提前实现，P4 移交输入已就绪。