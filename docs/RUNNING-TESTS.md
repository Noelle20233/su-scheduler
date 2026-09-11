# 回归测试运行环境与性能指南

> 本文件记录 Su Scheduler P0 回归测试（`tests/run_tests.sh`）的**正确运行环境**、
> 已实测的性能对照，以及排查"测试卡死/超时"的步骤，防止后续任务重蹈覆辙。
>
> 结论速览：**全量回归一律在 Linux/macOS 或 WSL 原生文件系统内跑；Windows 只用于 `--lint-only`。**

---

## 1. 为什么 Windows 上这么慢

`tests/` 下的测试与 `system/bin/su-scheduler-runtime` 运行时库大量使用 POSIX 管道
（`printf | cut | tr`、`grep | head | cut`、`awk`、`sed` 等）。每条管道都要派发若干个子进程。

实测单条 `printf | cut | tr` 管道 ×100 次的耗时（2026-09-04）：

| 运行环境 | 100 次耗时 | 单次派发 |
| :--- | :--- | :--- |
| Windows Git-Bash | 4350ms | ~43ms |
| WSL + `/mnt/d`（9p 挂载） | — | ~8-10ms（有额外文件系统开销） |
| WSL + `~/`（原生文件系统） | 385ms | ~3.8ms |

→ **Windows 与 WSL 原生存在约 11 倍的子进程派发差距。** 测试是子进程密集型的，
因此整体耗时会按同样量级放大。

---

## 2. 实测对照（`tests/p4-dependency/test.sh` 全量）

| 运行环境 | 耗时 | 结果 |
| :--- | :--- | :--- |
| Windows Git-Bash | >185s（命令超时被杀） | 107 PASS，未完 |
| WSL + `/mnt/d`（9p 挂载） | ~63s | 141 PASS，全量跑完 |
| WSL + `~/`（原生文件系统） | ~43s | 141 PASS，全量跑完 |

其他套件在 Windows Git-Bash 上的单套件实测（2026-09-04）：

| 套件 | 耗时 |
| :--- | :--- |
| `tests/legacy/golden.sh` | ~26.5s |
| `tests/legacy-adapter/test.sh` | ~59s |
| `tests/providers/test.sh` | ~16s |
| `tests/cli/test.sh` | ~4s |
| `tests/state-machine/test.sh` | ~2s |

`run_tests.sh` 串行执行 33+ 个套件（约 50+ 次 `run_suite`），在 Windows 上累积必然
达到数十分钟级，超过常见命令超时上限，导致任务被反复重试。

---

## 3. 硬性规则

1. **全量回归一律在 Linux/macOS 或 WSL 原生文件系统内跑。**
   把仓库放 `~/su-scheduler`（WSL 原生文件系统），**不要**放 9p 挂载的 `/mnt/*`
   （`/mnt/d` 仍有额外开销，见 §2 对照）。
2. **Windows 上只用 `tests/run_tests.sh --lint-only` 做快速语法检查。**
3. 若必须在 Windows 上跑：
   - **不要一次跑全部套件**——会整体超时；
   - 改为按单套件逐个跑并单独设超时：
     ```bash
     # 手动模拟 run_tests.sh 的 run_suite 逻辑
     out=$(bash tests/<suite>/test.sh 2>&1); rc=$?; echo "$out" | grep '\[FAIL\]'; echo "rc=$rc"
     ```
4. 排查慢/疑似卡死时：
   - **勿用 `bash -x` 直接叠在超时命令上**——`-x` 会再放大 5-10 倍，易被误判为死循环；
   - 先确认进程 CPU 占用：**满载 = 慢（子进程雪崩）而非卡死**；
   - 或观察是否仍有 `[PASS]` 持续产出（有产出 = 仍在推进，只是慢）。
5. 用 WSL 跑完后若暴露 `[FAIL]`，按 AGENTS.md §10「测试不可作弊」逐条核查，
   **禁止改测试掩盖**。注意：Windows 上往往因超时根本没跑到后半段，
   WSL 全量跑完才会"现形"出更多 FAIL。

---

## 4. 迁移到 WSL 的操作要点

```bash
# 在 WSL 内 clone 一份作为唯一工作副本（避免与 /mnt/d 双副本漂移）
cd ~
git clone /mnt/d/Code/github/su-scheduler  su-scheduler   # 或 clone 远端
cd ~/su-scheduler

# 全量回归
bash tests/run_tests.sh

# 快速语法检查
bash tests/run_tests.sh --lint-only
```

- 编辑文件可留在 Windows（用 `\\wsl$\<Distro>\home\<user>\su-scheduler` 访问），
  但**跑测试在 WSL 内**。
- 若 Windows 上改了代码，先在 WSL 内 `git pull`/`rsync` 同步，再跑测试，避免对不上。

---

## 5. 已知的迁移副作用

WSL 全量跑完后暴露的 FAIL，多为以下两类，须人工核查：
- **环境差异类**：`md5sum`、`/proc`、`date` 等行为在 Linux 与 Android 宿主不同；
- **测试自身 bug 类**：Windows 上因超时从未执行到后半段，迁移后才首次执行。

这些都不是性能问题，按 AGENTS.md 门禁与「测试不可作弊」规则处理即可。