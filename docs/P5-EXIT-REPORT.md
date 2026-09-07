# Su Scheduler — P5 出口评审报告（P5-EXIT-REPORT）

> **任务**：P5-11 · P5 综合回归与出口评审
> **前置**：P5-01..P5-10 全部完成；P5-CANDIDATES.md 缺陷状态
> **日期**：2026-09-07
> **版本**：模块 `v1.6.8`；Runtime 库 `1.30.0`（P5 出口）
> **设备**：KernelSU × Android 16（`adb-8934ffc4-`，Xiaomi 17 / pudding）
> **性质**：P5 出口评审——全量回归 + 约束审计 + 缺陷状态 + 设备矩阵 + P6 移交。

---

## 1. 回归结果（全绿）

### 1.1 宿主侧（WSL 原生）

| 验收命令 | 结果 |
| :-- | :-- |
| `bash tests/run_tests.sh` | **48 套件 / 2236 PASS / 0 FAIL / EXIT=0** |
| `bash tests/p3-integration/test.sh` | 49 PASS / 0 FAIL |
| `bash tests/p4-dependency/test.sh` | 220 PASS / 0 FAIL |
| `bash tests/p5-condition/test.sh` | 60 PASS / 0 FAIL |
| `bash tests/p5-trigger/test.sh` | 137 PASS / 0 FAIL |
| `bash tests/p1-build/build_check.sh` | 26 PASS / 0 FAIL / 0 SKIP |
| `dash -n system/bin/su-scheduler-runtime` | OK |

### 1.2 设备侧（KernelSU × Android 16）

| 套件 | PASS | FAIL | SKIP | BLOCKED |
| :-- | :-- | :-- | :-- | :-- |
| p1-device（legacy） | 11 | 0 | 2 | 0 |
| p3-device（managed） | 28 | 0 | 0 | 0 |

### 1.3 P3/P4 零回退

- p3-integration 49/0、p4-dependency 220/0、scheduler-prod 33/0、task-control 60/0、
  webui editor 41/0、legacy/golden 8/0——全部保持 P3/P4 出口水平。

---

## 2. P5 出口条件逐条判定

| # | 出口条件 | 判定 | 证据 |
| :-- | :-- | :-- | :-- |
| 1 | P3/P4 全部回归保持通过 | ✅ | §1.1/1.3（p3-integration 49、p4-dependency 220、全量 48 套件全绿） |
| 2 | P5 新增套件全绿 | ✅ | p5-condition 60/0、p5-trigger 137/0、p5-webui 64/0、p1-build 26/0 |
| 3 | Condition 扩展仍无任意 Shell 求值 | ✅ | 零 eval/sh -c（审计 §6）；cond_eval 纯谓词白名单 case 比对 |
| 4 | 新 Trigger 不影响 Legacy 路径 | ✅ | legacy_adapter_parse 零改动（C2/C4）；p1-device 11/0；新 Trigger 仅 Managed（B16） |
| 5 | WebUI 不产生 Root 直执路径 | ✅ | webroot 零 su -c/sh -c；UI 仅经 IPC 只读（审计 §6） |
| 6 | 原子保存、回滚和错误隔离保持有效 | ✅ | tcfg_apply_task/set_field tmp+mv 原子；失败逐字节不变（B9）；P5-04/07 原子性测试覆盖 |
| 7 | 至少一台 Android 设备完成 P5 新功能全链路 | ✅ | KernelSU×A16：新 Trigger 5 家族/Condition 运算符/WAITING/Retry/WebUI 刷新批量/重启恢复/升级回滚全过（P5-10） |
| 8 | 设备覆盖限制如实记录 | ✅ | 1/15 覆盖；14 格 ⏳ 发布限制（§5） |
| 9 | P5 出口报告和交接资料完成 | ✅ | 本文档 + P5-HANDOVER.md + 各 P5-nn 文档 + ADR |

---

## 3. 约束审计（C1–C5，详见审计报告）

| 约束 | 结论 | 证据 |
| :-- | :-- | :-- |
| C1 最小 diff、不重构 | ✅ | 生产 3 文件净增 792 / 删 111；删除均为版本串/代码移动/局部替换/注释重格式化；无整函数重写 |
| C2 不删旧解析/执行路径 | ✅ | 20 项旧函数全部存在；主循环恰 1（L737）；legacy_adapter_parse 活跃调用并被结构断言强制 |
| C3 无新增外部依赖 | ✅ | 新命令全为标准 toybox（getprop/date/awk/sed 等）；零 python/node/perl/curl |
| C4 不改变 config.txt 格式 | ✅ | legacy 解析零改动；golden 全绿 |
| C5 不提前实现 P1+ / P5 禁止项 | ✅ | IPC 19 op（无新增）；无 WebSocket；service.sh 零改动；无通用 DAG；无 Python/Node |

---

## 4. 缺陷状态（P5-CANDIDATES.md 同步）

| ID | 状态 |
| :-- | :-- |
| D-P5-01（crash-guard 竞态残留） | ✅ 已修复（仲裁前置 + trap 前置 + §18 eval/记录加固） |
| D-P5-02（宿主回归挂起） | ✅ 已修复（测试卫生：孤儿进程/超时护栏） |
| D-P5-03（supervisor O(N×M) IPC 饥饿） | ✅ 已修复（idmap 刷新下沉主循环） |
| D-P5-04（device 套件 SUITE_TIMEOUT） | ✅ 已修复（run_suite 第 2 参覆盖，900s） |
| D-P5-05（p3-device item14/18 时序） | ✅ 已修复（item18 清 guard + item14 防御重试，真机 3 轮全绿） |
| O-1（p1-device guard×watchdog 竞态） | ✅ 已修复（各 restart 前清 guard，真机验证 11/0） |
| O-2（主循环跳拍无 catch-up） | ⏳ 登记（P6 候选，非阻断） |
| O-3（cron trigger `task-config new` ID 派生） | ⏳ 登记（后续任务） |
| O-4（EDIT_TASK 错误透传） | ⏳ 登记（后续任务） |

---

## 5. 设备矩阵（1/15 覆盖）

| 管理器 | Android 12 | 13 | 14 | 15 | 16 |
| :-- | :-- | :-- | :-- | :-- | :-- |
| KernelSU | ⏳ | ⏳ | ⏳ | ⏳ | ✅ |
| Magisk | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| APatch | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

- **已覆盖**：KernelSU × Android 16（P5 新功能全链路 + 升级回滚）。
- **未覆盖 14 格**：发布限制（无真机/模拟器），如实记录不伪造。P5 出口放行需人工裁决
  （同 P0 D3 流程：设备验证缺失项明确标注）。

---

## 6. 版本一致性（六处）

`build.sh`/`module.prop`/两个 bin/`README.md`/`update.json` 全部 `v1.6.8`/`11608` 一致
（p1-build 26/0 持续锁定）；Runtime 库 `1.30.0` 为独立内部版本线。

---

## 7. 出口判定

**P5 满足出口条件 1–9**（设备覆盖限制如实记录，14 格 ⏳ 需人工签核放行）。

**P5 交付内容**：
- Condition 运算符扩展（`<`/`>`/`<=`/`>=`/`contains`，D38–D40，零 Shell 求值）
- 新 Trigger 家族（oneshot/delay/interval/cron/boot_completed，D41–D45，仅 Managed）
- WebUI 实时状态/依赖视图/批量操作（只增键 B8，零新 IPC op B7）
- CLI 与审计增强（next_due 真计算、cause 透传、批量查询）
- 资源安全加固（cron 列表/批量上限、mksh 兼容断言）
- 设备发布验证（KernelSU×A16 全链路）
- P6 候选需求清单（docs/P5-HANDOVER.md §5）

**下一步**：打 P5 基线 tag（建议 `p5-baseline-v1.6.8-runtime1.30.0`），进入 P6。
