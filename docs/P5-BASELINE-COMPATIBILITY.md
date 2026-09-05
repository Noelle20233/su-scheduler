# Su Scheduler — P5 兼容性基线清单（P5-BASELINE-COMPATIBILITY）

> **任务**：P5-01 · P4 发布候选收口与 P5 基线冻结（本文件为「兼容性基线」交付物）
> **前置**：P4-BASELINE-COMPATIBILITY.md（B1–B14，P4-01 冻结）
> **日期**：2026-09-05
> **版本**：模块 `v1.6.8`（不变）；Runtime 库 `1.28.0`（P4 出口，P5 起点）
> **基线提交**：`f6f428e`（P4-12 出口冻结终版）之后，工作树含 P5-01 docs 改动

---

## 1. 目的与范围

P5（V0.5）聚焦调度能力与操作体验增强：扩展受限 Condition 表达式、增加新型 Trigger、
完善 WebUI 实时状态/依赖视图/批量操作、补齐发布设备验证。本清单冻结 P5 的兼容性契约，
任何 P5 实现不得破坏下列任一条。

**P5 明确不做**：通用 DAG 调度、云同步、多设备管理、多用户体系、增强 Watchdog。

## 2. P4 基线复核（P5-01 实测）

| 项 | 期望 | 实测 | 结果 |
| :-- | :-- | :-- | :-- |
| Runtime 库版本 | 1.28.0 | `su-scheduler-runtime:33 RUNTIME_LIB_VERSION="1.28.0"` | ✅ |
| 模块版本 / versionCode | v1.6.8 / 11608 | 六处一致（build.sh、两个 bin、module.prop、README、update.json） | ✅ |
| 宿主全量回归 | 0 FAIL | 45 suites / 1906 PASS / 0 FAIL / 0 SKIP | ✅ |
| p3-integration | 0 FAIL | 48 PASS / 0 FAIL | ✅ |
| p4-dependency | 0 FAIL | 219 PASS / 0 FAIL | ✅ |
| p1-build | 0 FAIL | 26 PASS / 0 FAIL / 0 SKIP | ✅ |
| 设备侧（KernelSU×Android16） | 全绿 | 功能面全绿；daemon 快速重启恢复路径命中已知竞态残留 D-P5-01（非回归） | ⚠️ 见 §5 |
| 升级回滚记录 | 存在 | `docs/P4-UPGRADE-ROLLBACK.md`（107 行，P4 实测）完整 | ✅ |

## 3. P5 兼容性契约（B15–B21，P5-01 冻结）

| ID | 契约 | 细则 |
| :-- | :-- | :-- |
| **B15** | Runtime 库 `1.28.0` 线；Condition 扩展仅改 `cond_grammar_ok`/`cond_eval` 及必要辅助函数 | 不重写整个解释器；三态返回值（0 真 / 1 假 / 2 非法）不变 |
| **B16** | 新 Trigger 仅 Managed（Task v2）模式 | Legacy `config.txt` 只读兼容，禁止直接改格式；旧 Task 配置逐字节兼容 |
| **B17** | 既有 `==`/`!=` Condition 语义不变 | 新增 `<`/`>`/`<=`/`>=`/`contains` 不引入 `eval`/`sh -c`/外部解释器/反引号/`$(`/重定向/管道到命令 |
| **B18** | IPC 白名单 op 数量、键白名单、base64、原子响应、只增键不删改 | WebUI 增强继续复用既有 IPC，不引入 WebSocket；WebUI 不直接执行 Root |
| **B19** | 原子保存、回滚、错误隔离保持有效 | 失败保存不改变旧配置逐字节；批量操作失败可部分报告但不破坏配置 |
| **B20** | 不新增第二常驻循环 | daemon 主循环周期与 P3-03 锚点不变（外层 while true 仍恰 1、调度周期仍按分钟推进） |
| **B21** | 设备矩阵「1 覆盖 + 14 未覆盖」如实登记 | 未覆盖平台不得标记为通过；每个实际覆盖平台单独记录 |

## 4. 设备矩阵现状（P5-01 登记）

| 管理器 | Android 12 | 13 | 14 | 15 | 16 |
| :-- | :-- | :-- | :-- | :-- | :-- |
| KernelSU | ⏳ | ⏳ | ⏳ | ⏳ | ✅ `8934ffc4` |
| Magisk | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| APatch | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

- **已覆盖**：KernelSU × Android 16（Xiaomi 17 / `pudding` / `25113PN0EC`，ksud 3.3.0）——
  boot/registry/WebUI/editor/app/health/control/fallback 等功能面全 PASS；daemon 快速重启
  恢复路径受已知竞态残留 D-P5-01 影响（见 §5）。
- **未覆盖 14 格**（P5-10 优先级排序）：KernelSU×A12/A13/A14/A15（4）、Magisk×A16（1）、
  APatch×A16（1）、Magisk×A12/A13/A14/A15（4）、APatch×A12/A13/A14/A15（4）——均为
  ⏳ 发布限制（无真机/模拟器），**不伪造通过**。

## 5. 已知竞态残留（D-P5-01，非回归）

- **现象**：KernelSU×Android16 上 daemon 快速重启恢复路径间歇失败——p1-device
  run-once-now/prune/--delete（legacy 修剪管道）与 p3-device 18-restore（ghost RUNNING +
  事件缺失）、偶发 14-control/7-webui `operation_timeout`。
- **根因**：`crash_guard_enter` 与旧 daemon TERM trap（`crash_record_exit`）对 `daemon.guard`
  文件的写竞争（无串行化）；60s 窗口内密集 restart → crash_seq 累加 → 300s 降级窗口内
  fast-exit（不跑 main loop/不执行 ron/不修剪/不再水合）→ watchdog 反复拉起 → 崩溃循环。
- **与 P4-11（284b337）关系**：同源残留。P4-11 只修 CLI 侧（等待退出、严格单实例），未关闭
  guard 写竞争与降级期 watchdog 风暴侧；设备 daemon 与仓库 HEAD 逐字节一致，非本构建回归。
- **处置**：登记 `docs/P5-CANDIDATES.md`；修复方向（guard 写竞争串行化 / trap 完成后才允许
  下一实例接管）由 P5 后续任务或决策门裁决，P5-01 不越界修改。
