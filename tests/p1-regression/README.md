# P1 集成回归 — P1-12

> **任务**：P1-12 · 建立 P1 自动化与设备回归测试
> **依赖**：P1-01 ~ P1-11（本套件复用全部 P1 层做跨层端到端）
> **位置**：`tests/p1-regression/`（12 项集成断言）+ `tests/p1-build/`（构建校验，第 13 项）+ `tests/p1-device/`（设备冒烟）+ `tests/run_p1.sh`（P1 出口回归入口）+ 本文档
> **判定**（AGENTS §4）：输出中无 `[FAIL]` 且 exit 0；`[SKIP]` 仅限环境受限项（CRLF 检出构建 / 无设备），且**明示**（等价 P0 L3 `--skip-device` 语义）。

## 覆盖矩阵（13 项 ↔ 套件）

| # | P1-12 必须覆盖 | 回归套件 | 断言要点 |
| :-- | :--- | :--- | :--- |
| 1 | Legacy 配置解析 | legacy-adapter / p1-regression §1 | 17 任务、source.line 保留、trigger 原样 |
| 2 | Task ID 稳定性 | p1-regression §2 | 同一配置两次解析 → id 集一致、无时间戳、t<line>_<trigger> |
| 3 | 状态合法/非法转换 | state-machine / p1-regression §3 | 合法边接受、非法边拒绝 |
| 4 | 无效配置回退 | task-registry / p1-regression §4 | 坏配置 reload → KEPT 保留最后有效快照、任务不消失 |
| 5 | hot reload | task-registry / p1-regression §5 | 追加行 → 全量新快照、旧任务保留、无混合、无重复 |
| 6 | boot 任务 | trigger-decision / p1-regression §6 | boot 上下文 → cause=boot；上下文外不触发 |
| 7 | 时间任务 | trigger-decision / p1-regression §7 | NOW 精确分钟匹配；错分钟不命中 |
| 8 | heredoc | legacy-adapter / p1-regression §8 | source.type=block、重构残留、trigger 保留 |
| 9 | Termux 模式 | providers / p1-regression §9 | helper 缺失/READY/LOCKED，优雅失败不崩溃 |
| 10 | command/script 执行 | action-run / p1-regression §10 | 普通成功/失败(FAILED+exit_code)/脚本执行、output.log |
| 11 | daemon lock & stale PID | lifecycle / p1-regression §11 | 单实例、stale 恢复、僵尸清理（ZOMBIE_CRASHED+FAILED） |
| 12 | CLI 只读查询 | task-cli / p1-regression §12 | list 6 字段、status key=value、错误三态 rc1/2/3 |
| 13 | 安装包构建 | `tests/p1-build/build_check.sh` | build.sh → zip、unzip -t、六处版本一致、工作树还原 |

## 环境说明（P1-12 测试环境三档）

| 档 | 环境 | 说明 |
| :-- | :--- | :--- |
| 主机单元/模拟 | 当前（Git-Bash，POSIX sh/bash） | 11 套全绿（无 [FAIL]）——**行为断言**，不只是 `sh -n` |
| 构建（第 13 项） | 仓库构建 | `build_check.sh`：CRLF 检出（`core.autocrlf=true`）下构建执行**明示 [SKIP]**（P1-01 §1 记录"CRLF 检出不可发布"），六处版本一致照常校验；CI（LF 工作树）为完整构建闸 |
| 真实设备（KernelSU） | adb | `tests/p1-device/smoke.sh` 就绪（10 用例，P0 T3 语义 + P1 只读 CLI）；本地无 adb → `DEVICE_SKIPPED` 明示，不计失败；**至少一台 KernelSU 设备**为 P1-12 验收的设备档，缺失时按 P0 D3 例外流程人工裁决 |

## 入口

```bash
bash tests/run_p1.sh                    # P1 出口回归：9 套 + p1-regression + build_check
bash tests/run_p1.sh --with-device      # 追加设备冒烟（无设备 → DEVICE_SKIPPED）
bash tests/p1-regression/test.sh        # 单独跑 12 项集成
bash tests/p1-build/build_check.sh      # 单独跑构建校验
bash tests/p1-device/smoke.sh [--skip-device]  # 设备冒烟脚本
```

## 验收对照

| P1-12 验收 | 落实 |
| :--- | :--- |
| 所有 P1 回归测试通过 | `run_p1.sh` 11 套全绿（无 [FAIL]，exit 0）；`_run_all.sh` 聚合 9 套既有 + p1-regression |
| 不能只以 Shell 语法检查通过作为完成标准 | 全部为**行为/集成断言**（解析、状态机、回退、触发、执行、锁、CLI、构建）；`bash -n` 只是其中一环 |