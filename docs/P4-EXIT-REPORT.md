# Su Scheduler — P4 出口评审报告（P4-EXIT-REPORT）

> **任务**：P4-12 · P4 出口评审与发布准备（本报告为 P4 出口冻结终版）
> **前置**：P4-01..P4-11（全部交付物就绪）；`docs/P4-BASELINE-COMPATIBILITY.md`
> （B1–B14 冻结契约）、`docs/P4-DEPENDENCY-REQUIREMENTS.md`（NF-1..NF-8、§4 安全
> 边界）、`docs/architecture/dependency-schema.md`（ADR D1–D37）
> **版本**：模块 `v1.6.8`（不变）；Runtime 库 `1.28.0`（P4 出口）
> **日期**：2026-09-04（P4-10 初版）→ 2026-09-05（P4-12 冻结终版，含 P4-11 真机
> 验证与三缺陷修复）
> **入口**：`bash tests/run_tests.sh --with-device`（L1+L2+L4+L3，WSL 权威宿主 +
> 真机）+ `tests/p3-integration` / `tests/p4-dependency` / `tests/p1-build`
> **签核**：见 §8（人工签核栏）

---

## 0. 结论（TL;DR）

**P4（Dependency / Condition / WAITING 任务链）通过出口评审，可进入发布候选与
P5/P6 规划。P4-11/P4-12 完成真机全链路验证与出口冻结。**

- P4-01..P4-12 全部 TaskIndex 交付物齐备（§1 状态表），Runtime 库随功能递增至
  **1.28.0**，模块版本 `v1.6.8` 不变（D4 版本策略：内部实现线独立演进）。
- **8 项安全/资源/兼容性核查（§2）：7 项复核通过、1 项发现并修复生产缺陷**
  ——D34（依赖图邻接表切分使用 mksh `|`-in-pattern 参数展开，B7/NF-7 回归，
  P3-10 D-IPC 同源），已最小修复（`cut -d'|' -f2-`）+ FAIL→PASS 测试锁定。
- **B1–B14 冻结契约逐项复核（§3）：全部保持**——Legacy 配置/CLI/旧运行 ID 零
  影响，daemon 主循环结构未动（`while true` 恰 1），service.sh 零改动。
- **P4 范围边界（§4）**：DAG / 云同步 / 多设备 / 第二常驻循环 / 通用 Condition
  求值器零实现；无新增运行期外部依赖；无 `eval`/`sh -c` 拼接执行用户输入。
- **P4-11 真机验证（§5）**：同一台 KernelSU × Android 16 真机
  `run_tests.sh --with-device` **全绿**（宿主 3812 PASS / 0 FAIL + p1-device 11
  PASS + p3-device 28 PASS / 0 FAIL / 0 BLOCKED），并修复 3 个 Runtime 激活后暴露的
  真机缺陷（D-A mksh `(`-in-pattern / D-B cmd_stop pidof / D-C daemon 单实例保护，
  详见 `docs/P4-11.md` §3）。
- **P4-12 出口冻结（§5/§7）**：5 项验收命令全绿；出口条件逐项闭合；人工签核见 §8。

---

## 1. P4 阶段总览：TaskIndex 逐项状态

| Task | 内容 | Runtime 版本 | Commit | 门禁结果（WSL 权威 / 真机） |
| :-- | :-- | :-- | :-- | :-- |
| P4-01 | P3 发布缺口收口与 P4 基线冻结（D-IPC 真机复验、基线兼容清单、Runtime 版本检查 A/B） | 1.19.0（基线） | `edaf071` | WSL 基线 1631 PASS / 0 FAIL |
| P4-02 | Dependency/Condition Schema 解析 + 权威校验 + 原子持久化（§26 `dep_*`/`cond_*`，DEP_MAX/COND_MAX_LEN） | 1.20.0 | `ad555b8` | p4-dependency 52/0 |
| P4-03 | 依赖图校验与循环检测（未知/自依赖/环，覆盖 apply/set/import/snapshot） | 1.21.0 | `4abcd40` | p4-dependency 81/0 |
| P4-04 | WAITING 状态与依赖门控接入调度层（gate_wait/gate_ok/gate_fail、WAIT_MAX 有界） | 1.22.0 | `fadaf90` | p4-dependency 110/0 |
| P4-05 | Required/Optional 失败传播（终态不匹配立即 FAILED、缺失/禁用有界等待、force start 跳过门控） | 1.23.0 | `f866c21` | p4-dependency 134/0 |
| P4-06 | Condition 受限表达式引擎（白名单谓词、==/!=、三态语义、零 shell 求值） | 1.24.0 | `5574b64` | p4-dependency 157/0 |
| P4-07 | Supervisor/Recovery/Retry 联动（FAILED>WAITING 退避、gate.fail 不 auto-recovery、WAITING prune 豁免） | 1.25.0 | `539720d`（feat）+ `41b42b0`（test 日期敏感修复） | p4-dependency 194/0 |
| P4-08 | IPC 与 WebUI 依赖编辑器（复用 VALIDATE_TASK/EDIT_TASK，注入拒绝 + B9 原子性） | 1.26.0 | `bb22314` | webui editor 41/0、security 27/0 |
| P4-09 | CLI/日志可观测查询面（dependency=/Gate 行、detail 新字段、summary waiting 计数；只增键） | 1.27.0 | `44a431e` | p4-dependency 207/0 |
| P4-10 | 安全/资源/兼容性加固 + D34 mksh `|`-in-pattern 修复 + D35 WAITING 取舍 | 1.28.0 | `f5ff103`+`7bdfb32` | p4-dependency 218/0；全量 1900/0 |
| **P4-11** | **设备矩阵与综合回归**：真机全链路（KernelSU×Android16）+ D-A/D-B/D-C 三缺陷修复 | 1.28.0 | `284b337`+`e70383d` | `--with-device` 全绿：宿主 3812 + p1-device 11 + p3-device 28（见 §5） |
| **P4-12** | **出口评审与发布准备**（本报告 + P4-HANDOVER + P4-UPGRADE-ROLLBACK + 候选清单） | 1.28.0 | *本任务 commit* | 见 §5/§7 |

---

## 2. 安全与资源加固核查表（P4-10 · 8 项逐条）

| # | 核查项 | 守护测试 / 命令 | 结果 | 证据（file:line） |
| :-- | :-- | :-- | :-- | :-- |
| 1 | **依赖数量上限**：单任务 dependency ≤ `DEP_MAX=32`，复核校验覆盖所有写路径（editor/apply/set/import/snapshot） | `tests/p4-dependency` §const/§dep/§editor/§store/§cli + §hard-p4-10（editor/apply/set 33 条目拒绝 + 原子性） | **PASS** | 常量 `system/bin/su-scheduler-runtime:5133`；`dep_validate` L5170-5184；写路径接线 L2689/L2867/L4599/L2760/L3005 |
| 2 | **条件表达式长度上限**：`COND_MAX_LEN=256`，存储层与文法层一致；超长拒绝 + 原子性 | `tests/p4-dependency` §cond（256/257 边界）+ §hard-p4-10（set 257 拒绝 + 逐字节不变） | **PASS** | `cond_validate` L5187-5194；`cond_grammar_ok` L5279-5343；写路径先 cond_validate 后 grammar（L2691/L2869/L4601） |
| 3 | **WAITING 数量与等待时间上限**：`WAIT_MAX=86400` 有界终态 + `retry.max≤100` 钳制 + WAITING prune 豁免；WAITING 数量不设显式上限（D35 取舍） | `tests/p4-dependency` §gate-D（超时 FAILED）+ §retry-p4-07 R5（prune 豁免）+ §hard-p4-10（WAIT_MAX 常量 + rty_policy 钳制）；`tests/resource/stress` | **PASS（D35 成文）** | `WAIT_MAX` L3152；超时分支 L3465-3474；`rty_policy` 钳制 L3211；`runtime_dir_active` WAITING 豁免 L2517-2518；取舍见 dependency-schema.md ADR D35 |
| 4 | **无路径穿越与控制字符注入**：dependency id / condition 表达式 / file.exists 路径 / gate 原因字符串全部过 `secv_id_ok`/`conde_charset_ok`/`conde_path_in`/`web_json_str` 转义；fuzz/path-validation/security 断言零 exec 零 config 写 | `tests/security/fuzz.sh`（dep 5 形态 + cond 8 形态注入 → rc 4 零 exec 零写）+ `tests/security/path-validation.sh` + `tests/webui/security.test.sh` | **PASS** | `dep_entry_ok`→`tcfg_editor_id_ok` L5165；`cond_grammar_ok` id L5298 / charset L5329 / path L5330-5337；`web_json_escape` L4198-4214；obs_gate_state 输出经 web_task_detail `web_json_str` 转义 L4375-4377 |
| 5 | **Android 兼容**：POSIX sh（dash/sh -n 通过）；IPC 字段切分全用 `cut -d'|'`（B7/NF-7）；无 `${var//}` 等 mksh 不支持写法 | `dash -n system/bin/su-scheduler-runtime` / `sh -n su-scheduler` / `sh -n su-schedulerd`；`tests/p4-dependency` §POSIX + §hard-p4-10（零 `|`-pattern 静态断言 + cut 审计）；`tests/ipc/test.sh` §3b（D-IPC） | **⚠️→PASS（D34 修复）** | **修复**：`depg_targets` 切分 L5518/L5552 → L5520/L5555（`cut -d'|' -f2-`）；全仓 grep 零 `${var#*|}`/`${var%%|*}`/`${var//}`（修复后） |
| 6 | **不新增第二常驻 daemon 循环**：daemon 外层 `while true` 恰 1；P4 门控/退避/复查叠加在既有 `scheduler_tick`/`supervisor_tick` 内 | `tests/scheduler-prod` §1（`while true`==1 断言）；`tests/resource/stress.sh` §a（scheduler/supervisor 单 for 循环结构断言） | **PASS** | `system/bin/su-schedulerd:691`（唯一 `while true`）；P4 接线均位于 `scheduler_tick`（L3564-3615）/`supervisor_tick`（L2345）内 |
| 7 | **Legacy 不受影响**：legacy config.txt 解析/执行路径零改动（C2/C4）；旧运行 ID 映射不变；Legacy CLI 行为不变 | `tests/legacy/golden.sh` + `tests/legacy-adapter/test.sh` + `tests/cli/test.sh` + `tests/p4-dependency` §legacy（daemon/legacy 解析函数零 dependency/condition 引用） | **PASS** | daemon legacy fallback 主循环 L718-836（未动）；`sched_source_mode` legacy 分支保持 |
| 8 | **无新增运行期外部依赖 / 无 eval / sh -c / $(...) 拼接执行用户输入**（P4-06 已禁，复核 P4 新增代码） | grep 审计（`eval`/`sh -c`/`$(`拼接）；`tests/p4-dependency` §cond-p4-06 R（注入拒） | **PASS** | P4 新增代码（§20/§20b/§22/§26/§26b）零 eval；cond 引擎纯字符串解析（L5278-5405）；既有 `sh -c` 仅 legacy `action_run`（L577/L590，P2 基线非 P4 新增） |

**加固结论**：**有生产改动（1 处 D34 最小修复）**，其余 7 项复核通过无需改动；
WAITING 数量上限经 D35 裁决「不设显式上限」（理由见 ADR D35 与 docs/P4-10.md §5）。

---

## 3. 兼容性复核（B1–B14 冻结契约逐项）

| # | 冻结契约 | 守护测试 | 结果 | P4-10 复核 |
| :-- | :-- | :-- | :-- | :-- |
| B1 | config.txt 行格式与全部触发器零变更（C4） | legacy/golden + cli + parsing | PASS | 未触碰 fixtures/解析；golden 全绿 |
| B2 | parse_modifiers/extract_command/heredoc/modifiers 语义锁定 | legacy/* + parsing | PASS | 解析函数本体零改动（§legacy 断言） |
| B3 | Legacy 执行路径（主循环/execute_task）持续可运行（C2） | execution/action-run + trigger + p3-integration | PASS | daemon legacy fallback 分支未动 |
| B4 | 模块 v1.6.8 八处一致性 | p1-build/build_check | PASS | 本任务未动模块版本文件 |
| B5 | Runtime 库版本存在且语义化；打包一致 | p3-integration（dash -n + selfcheck）+ P4-RUNTIME-VERSION-CHECK + p4-dependency §hard 版本断言 | **PASS（1.28.0）** | 1.27.0 → 1.28.0 全仓活引用同步 |
| B6 | daemon 单实例/生命周期/crash-guard；无第二常驻循环 | crashguard + lifecycle-prod + p2-integration | PASS | `while true`==1 保持 |
| B7 | IPC 固定格式 + 白名单 + base64 + cut 切分（禁 `${var#*|}`/`${var%%|*}`） | ipc/test + ipc/security + p3-integration | **PASS（D34 补漏）** | **复核发现图校验切分回归点并修复**（§2 item 5） |
| B8 | WebUI 只读 JSON 转义防注入、只增键不删改 | webui/read-only + security | PASS | 新字段经 web_json_str 转义（§2 item 4） |
| B9 | tcfg 原子写 + 失败旧配置逐字节不变 + 回滚 | config-v2/test + validation + webui/editor | PASS | §hard-p4-10 新增 DEP_MAX/COND_MAX_LEN 写路径原子性断言 |
| B10 | tctl 统一控制 + TSM 强制 + 只杀本运行目录 pid | task-control | PASS | WAITING 控制行为固化（P4-09 D33）未改 |
| B11 | secv_* 输入/路径/权限门 + IPC 频率限制 + 资源上限 | security/fuzz + path-validation + permission + resource/stress | PASS | 注入全拒零 exec 零写（§2 item 4/8） |
| B12 | service.sh FBE + 既有看护循环原样（C5） | git diff（零改动）+ p1-device/smoke | PASS | service.sh 零 diff |
| B13 | P1+ 禁止项（DAG/云同步/多设备）零实现 | git grep | PASS | §4 边界审计 |
| B14 | 状态机 11 态 + TSM 允许边；WAITING reserved 接线 | state-machine | PASS | TSM 未动；WAITING 有界语义复核（D35） |

---

## 4. P4 范围边界审计（C1–C5 / 禁止项自查）

| 审计项 | 结论 | 证据 |
| :-- | :-- | :-- |
| C1 最小 diff、不重写 | ✅ | P4 全阶段增量叠加；P4-10 生产 diff = 2 处单行切分替换 + 版本号 |
| C2 不删旧解析/执行路径 | ✅ | legacy 解析/主循环/heredoc/modifiers/execute_task 全保留；daemon 文件 P4 零改动 |
| C3 无新增运行期外部依赖 | ✅ | 仅 toybox 标准工具；P4-10 修复用 `cut`（库内既有 80+ 处）；无 Python/Node/busybox 硬依赖 |
| C4 配置格式零变更 | ✅ | config.txt 零改动；`dependency=`/`condition=` 仅 Task v2 managed 域 |
| C5 不提前实现 P1/P5 | ✅ | service.sh 零改动；不新增 Watchdog；不实现 DAG/云同步/多设备；无 WebUI 直执 Root |
| 第二常驻 daemon 循环 | ✅ | `while true`==1（scheduler-prod 断言）；P4 逻辑叠加在既有 tick |
| DAG / 云同步 / 多设备 | ✅ | git grep 无占位目录/接口/实现 |
| eval / sh -c / 拼接执行用户输入 | ✅ | P4 新增代码零 eval；cond 引擎纯字符串解析 |
| 新 IPC op | ✅ | IPC_WHITELIST 仍 19（P4 全程未加） |
| 模块版本 | ✅ | v1.6.8 不变（D4：内部实现线独立） |

---

## 5. 回归结果（P4-12 出口冻结）

### 5.1 全量 WSL 门禁（权威宿主）

> **P4-12 出口复验（2026-09-05，WSL 权威宿主 ~/su-scheduler 原生文件系统）**：
> `bash tests/run_tests.sh` → **ALL SUITES GREEN**，**PASS=3812 / FAIL=0**，exit 0
> （45 套件，L1+L2+L4）。P4-01 基线 1631 → P4-12 出口 3812（P4 全期净增
> 2181 断言，0 失败）。trace log：`tests/results/run_tests-20260905-124936.log`。

| 套件 | 结果（WSL 权威） | 备注 |
| :-- | :-- | :-- |
| 全量 run_tests.sh | **3812 PASS / 0 FAIL**（45 套件全绿，exit 0） | L1+L2+L4，含 p4-dependency 219 / p3-integration 48 / cli 29 / build 26 |
| p3-integration（独立） | **48 PASS / 0 FAIL** | P3 综合回归 |
| p4-dependency（独立） | **219 PASS / 0 FAIL** | P4 核心（P4-10 基线 218 + P4-11 mksh 断言 1） |
| p1-build/build_check（独立） | **26 PASS / 0 FAIL / 0 SKIP** | 构建 + unzip -t + 八处一致 + Runtime A/B |

### 5.2 真机设备冒烟（P4-11/P4-12 权威）

> **P4-12 出口复验（2026-09-05）**：`bash tests/run_tests.sh --with-device` →
> **ALL SUITES GREEN / EXIT=0**（47 套件全绿）。trace log：
> `tests/results/run_tests-20260905-125433.log` + 设备
> `tests/results/device-8934ffc4-20260905-130756.log`（259s）。

| 设备冒烟 | 结果 | 备注 |
| :-- | :-- | :-- |
| `tests/p1-device/smoke.sh` | **11 PASS / 0 FAIL / 2 SKIP** | Legacy 回归（boot/时间任务/run-once-now/--delete/旧 CLI） |
| `tests/p3-device/smoke.sh --with-device` | **28 PASS / 0 FAIL / 0 BLOCKED** | 18 项全链路（安装/daemon/Runtime 1.28.0/Registry/IPC 7/8/14/Health/CrashLoop/恢复） |

### 5.3 设备矩阵（如实记录）

- **KernelSU × Android 16（`8934ffc4`，Xiaomi 17）**：✅ 全链路真机验证（§5.2）。
- **未覆盖**：Magisk × Android 12–16、APatch × Android 12–16、KernelSU × 12–15
  ——无真机/模拟器 → **发布限制**（不伪造通过，见 `docs/P3-DEVICE-MATRIX.md` §4）。
- P4 必测场景映射见 `docs/P4-11.md` §2（依赖满足/未满足、WAITING→STARTING、
  Required/Optional 失败、环/未知拒绝、Condition 真/假、daemon 重启恢复、
  WebUI 编辑校验控制、Legacy 回归）。

---

## 6. 遗留问题与 P5/P6 移交清单（诚实原则）

> 完整的 P5/P6 候选需求清单见 `docs/P4-HANDOVER.md` §5。下表为出口遗留状态。

| 项 | 状态 | 说明 / 理由 | P5/P6 建议 |
| :-- | :-- | :-- | :-- |
| 全量 WSL 门禁最终数字 | ✅ 已回填（P4-12） | **3812 PASS / 0 FAIL**（WSL 权威宿主，§5.1） | 无需跟进 |
| L3 设备冒烟（p3-device / Dependency 门控真机链路） | ✅ 已真机验证（P4-11/P4-12） | 同一台 KernelSU × Android 16 真机：宿主 3812 PASS + p1-device 11 PASS + p3-device 28 PASS / 0 FAIL / 0 BLOCKED（含 Runtime 1.28.0 断言与 D-A/D-B/D-C 三缺陷修复，见 `docs/P4-11.md`） | 无（发布限制仍为 Magisk/APatch × Android 12–16 与 KernelSU × 12–15，见 P3-DEVICE-MATRIX §4） |
| WAITING 显式数量上限 | 已裁决不设（D35） | WAIT_MAX 有界终态 + registry 有界 + prune 豁免有终态保证 | 若「注册任务无上限/自动生成依赖链」进入 P5，按 D35 重估 |
| Condition 运算符扩展（`<`/`>`/`>=`/`<=`/`contains`） | 明确不在 P4 范围（ADR D19） | P4-06 只做 `==`/`!=` | P5 候选（P4-HANDOVER §5） |
| 通用 DAG / 云同步 / 多设备 | 零实现（P4 边界） | ADR D7/D4、需求 §7 | P5/P6 候选（不提前实现） |
| mksh 兼容面 | 已修复（D34/D36/D37） | `|`/`(`/`)` in-pattern 参数展开在 Android 16 mksh 不可靠（三次真机确认） | P5+ 新增代码一律 `cut` 切分（ADRR D37） |
| P4-09 遗留：obs_gate_state 事件原因内联长度上限 | 复核通过（消息来源受控：枚举原因/工件，且 JSON 侧 web_json_str 转义） | — | 无需跟进（如需可做长度截断增强） |

---

## 7. P4 出口判定

**满足 P4 出口全部条件（P4-12 冻结）**：
1. P4-01..P4-12 全部 TaskIndex 交付物齐备（§1）；
2. 8 项安全/资源/兼容性核查通过（§2，含 D34 修复与 FAIL→PASS 证据）；
3. B1–B14 冻结契约全保持（§3）；
4. C1–C5 / 禁止项审计通过（§4）；
5. **5 项验收命令全绿（§5）**：
   - `bash tests/run_tests.sh` → **3812 PASS / 0 FAIL**（L1+L2+L4，45 套件）；
   - `bash tests/run_tests.sh --with-device` → **ALL SUITES GREEN**（47 套件；
     p1-device 11 PASS；p3-device 28 PASS / 0 FAIL / 0 BLOCKED）；
   - `bash tests/p3-integration/test.sh` → **48 PASS / 0 FAIL**；
   - `bash tests/p4-dependency/test.sh` → **219 PASS / 0 FAIL**；
   - `bash tests/p1-build/build_check.sh` → **26 PASS / 0 FAIL / 0 SKIP**。
6. 配置格式零变更、Legacy 零影响、无新依赖、无第二常驻循环；
7. **至少一台 Android 设备完成全链路**（KernelSU × Android 16）；设备限制与未覆盖
   矩阵如实记录（§5.3 / P3-DEVICE-MATRIX §4）。

---

## 8. 交付物清单与人工签核

### 8.1 交付物

| 交付物 | 路径 | 状态 |
| :-- | :-- | :-- |
| P4 出口评审报告（本文件） | `docs/P4-EXIT-REPORT.md` | ✅（P4-12 冻结终版） |
| P4 交接资料 | `docs/P4-HANDOVER.md` | ✅（P5/P6 移交范围 + 候选需求清单） |
| Dependency/Condition schema 与 ADR | `docs/architecture/dependency-schema.md` | ✅（D1–D37，含 P4-11 增补） |
| P4 综合测试报告 | 本文件 §5（含全量数字） | ✅ |
| 设备矩阵报告 | `docs/P3-DEVICE-MATRIX.md` + `docs/P4-11.md` | ✅ |
| 构建产物和升级回滚验证记录 | `docs/P4-UPGRADE-ROLLBACK.md` | ✅（P4 真机实测） |
| 下一阶段候选需求清单 | `docs/P4-HANDOVER.md` §5 | ✅ |

### 8.2 人工签核

> P4 出口须经人工签核（AGENTS §7 决策门）。以下由评审人填写：

| 评审项 | 结论（评审人勾选/填写） |
| :-- | :-- |
| 5 项验收命令结果核验 | ☐ 通过 / ☐ 不通过（见 §5 trace log） |
| 设备矩阵如实记录（未覆盖平台标记发布限制） | ☐ 通过 / ☐ 不通过 |
| 出口条件逐项闭合（§7） | ☐ 通过 / ☐ 不通过 |
| 遗留问题与候选清单（§6 / P4-HANDOVER §5）可接受 | ☐ 通过 / ☐ 不通过 |
| **最终签核** | ☐ 放行发布候选 / ☐ 打回（理由：______） |

- 签核人：____________　日期：____________
- 评审意见：____________________________________________________
