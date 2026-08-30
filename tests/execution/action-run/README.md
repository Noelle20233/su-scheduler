# Action Runner — P1-08 接线层

> **任务**：P1-08 · 将现有命令执行接入 ActionProvider
> **依赖**：P1-04（Provider 契约）、P1-06（Task Registry）
> **位置**：`tests/execution/action-run/`（lib.sh 接线层 + test.sh 回归 + 本文档）

## 目的

把现有命令、脚本、Termux 与交互式执行逻辑**统一包装为 Action**，并证明：

1. **Task Engine 不直接拼接执行命令**（验收 1）——执行唯一入口是
   `provider_dispatch action command …`；接线层只负责「读任务动作字段 →
   dispatch → 记 PID」，自身不含 `sh -c` / 解释器 / 二进制硬编码（test.sh §1
   结构断言）。
2. **现有命令执行结果与改造前一致**（验收 2）——四模式逐分支镜像
   `su-schedulerd execute_task`（P1-01 §5 / P1-01 基线）：
   - 普通命令：`sh -c` → `output.log`（stdout+stderr 合并）→
     `exit_code.txt` + `end_time.txt` + `status.txt`(SUCCESS|FAILED)；
   - 脚本智能执行：文件检测 → `chmod +x` → `sh -c` → 126/127 时 bash/sh 回退；
   - Termux：`su-scheduler-termux status` READY→exec / LOCKED→`User 0 locked` /
     其他→`Termux not installed` / helper 缺失→`Termux helper missing`（均
     exit 1 优雅失败）；
   - Interactive：FIFO `task.in`/`task.out` + `sh -i`（legacy 保真：结束后
     **只写 exit_code.txt**，status 留 RUNNING、无 end_time/output.log）。
3. **Action 失败能返回 failure 和 exit_code**（验收 3）——非 0 退出 →
   `status.txt`=FAILED 且 `exit_code.txt`=实际退出码（test.sh 以 `exit 7`
   断言）。

## 调用约定

```sh
# source 链（顺序固定）
. tests/providers/providers.sh        # 含 tests/providers/lib.sh（注册表/分发）
. tests/task-registry/lib.sh          # registry API（registry_task_file 等）
. tests/execution/action-run/lib.sh   # 本接线层

out=$(action_run_task "$(registry_task_file <id>)")   # id=.. pid=.. dir=..
# 引擎式接收 PID：start 的 stdout 已落盘为 <dir>/pid.txt（镜像 daemon L486）
action_run_wait "$dir" "$id" "$pid"   # 等 exit_code.txt 或进程退
```

- `action_run_task` 读取任务文件（schema_version=2）的 `action.command` /
  `action.termux` / `action.interactive`，缺失 `action.command` → 拒启（rc 1，
  不崩）。
- 上下文变量沿用 providers 的 `TPR_ACTION_DIR` / `TPR_TERMUX_HELPER`。

## 测试

```bash
bash tests/execution/action-run/test.sh    # 全 [PASS] 且 exit 0
```

覆盖：结构断言（无命令拼接）、registry 快照 → 普通命令端到端、四模式接线、
失败返回 failure+exit_code、无效任务拒启。