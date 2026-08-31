# Su Scheduler — P1 升级与回滚操作手册（P1-13）

> **任务**：P1-13 · 补充架构、升级与回滚文档（本手册为「P1 升级和回滚说明」交付物）
> **依赖**：P1-01（基线 v1.6.8 @ `3fe7631`）、P1-12（回归装订）、P1-13 交接总览
> **性质**：**命令级操作手册**；原则与影响面见 `docs/P1-HANDOVER.md` §7/§8。
> **核心前提**：P1 阶段**从未改动生产文件**（`system/bin/*`、`service.sh`、
> `customize.sh`、`build.sh`、`module.prop`、`update.json`）——升级与回滚因此
> **零迁移、零风险**。若发现 P1 提交碰过生产文件，视为违规，先回滚再重审。
> **日期**：2026-09-01

---

## 目录

1. [影响面与前提](#1-影响面与前提)
2. [升级（采用 P1 层）](#2-升级采用-p1-层)
3. [回滚（回到 v1.6.8 基线）](#3-回滚回到-v168-基线)
4. [升级-回滚循环](#4-升级-回滚循环)
5. [故障排查](#5-故障排查)

---

## 1. 影响面与前提

| 对象 | P1 期间是否改动 | 升级后 | 回滚后 |
| :--- | :--- | :--- | :--- |
| `system/bin/su-scheduler` | 否 | 原样 | 原样 |
| `system/bin/su-schedulerd` | 否 | 原样 | 原样 |
| `system/bin/su-scheduler-termux` | 否 | 原样 | 原样 |
| `system/bin/.su-scheduler-docs` | 否（P1-12 构建演练后已还原） | 原样 | 原样 |
| `service.sh` | 否 | 原样 | 原样 |
| `customize.sh` | 否 | 原样 | 原样 |
| `build.sh` | 否 | 原样 | 原样 |
| `module.prop` / `update.json` | 否 | 原样 | 原样 |
| `README.md` | **是**（仅追加 P1-13 兼容性章节，既有章节未动） | 含追加章节 | 移除追加章节后与基线一致 |
| `tests/`（P1 新增全部） | **是**（P1-01..P1-12 新增） | 在 | 删除 |
| `docs/`（P1 新增/补充） | **是**（新增架构文档 + 既有 4 份头部注记） | 在 | 删除/还原（注记删除需还原原头部） |
| 运行期 | 无关（P1 层未接线生产；`state.txt`/`events.log` 只在测试/层目录生成） | 生产无新文件 | 生产无影响 |

**前提校验（升级/回滚前必跑）**：

```bash
# 生产文件与基线逐字节一致（应为空输出）
git diff 3fe7631 -- system/ service.sh customize.sh build.sh module.prop update.json

# P1 回归现状（升级前：应全绿；回滚后：应不适用或全绿）
bash tests/run_p1.sh
```

## 2. 升级（采用 P1 层）

P1 层 = 测试域实现 + 文档。升级 = **合入 P1 提交**（无迁移、无配置改动）。

```bash
# 1) 合入（fetch/merge/rebase 视发布流程；P1 提交均为 [P1-0n]/[P1-1n] 前缀）
git merge --ff-only origin/main          # 或由发布者决定

# 2) 语法与回归闸（P1-12 出口标准）
bash tests/run_p1.sh                    # 期望：11 套，无 [FAIL]，exit 0
bash tests/_run_all.sh                  # 期望：10 套全绿（既有聚合入口）

# 3) 构建校验（第 13 项；CRLF 检出下构建执行段会明示 [SKIP]，版本六处仍校验）
bash tests/p1-build/build_check.sh

# 4) 设备冒烟（有 KernelSU 设备/授权 adb 时）
bash tests/run_p1.sh --with-device      # 无设备 → DEVICE_SKIPPED 明示

# 5) 可选：单层抽查（某一层独立验证）
bash tests/lifecycle/test.sh
bash tests/task-cli/test.sh
```

**升级后使用**（只读验证/观察 P1 任务模型）：

```bash
# 在测试域内 source 接线（顺序见各 lib 头部注释），例如只读 CLI：
cd tests/task-cli
. ../state-machine/lib.sh; . ../runtime/lib.sh
LEGACY_ADAPTER_SOURCED=1; . ../legacy-adapter/adapter.sh
. ../task-registry/lib.sh; . ../lifecycle/lib.sh; . ./lib.sh
TR_LOGGING=0 registry_init "$BASE" "$CFG"    # 建快照
task_cli_list                                  # task list 等价
task_cli_status t45_2200                       # task status 等价
```

## 3. 回滚（回到 v1.6.8 基线）

**两个等价路径**（推荐 A——保留文档历史可审计；B 适用于要彻底清场）：

```bash
# 路径 A：git revert（保留撤销记录，历史仍可查）
git revert 3fe7631..HEAD                 # 按提交序逆序撤销 P1-01..P1-13
# 或只撤销整组：
git revert --no-commit <p1-13-hash> <p1-12-hash> ... <p1-01-hash>

# 路径 B：基线重置到 v1.6.8（删除全部 P1 痕迹；先备份未提交工作）
git reset --hard 3fe7631
```

**回滚后核对**（应全部通过）：

```bash
# 1) 生产文件与基线一致（空输出）
git diff 3fe7631 -- system/ service.sh customize.sh build.sh module.prop update.json

# 2) P1 层已移除（tests/、docs/ 无 P1 文件；README 无追加章节）
git ls-files tests/ docs/ | head        # 应有为空或仅基线阶段文件（P1 前无 tests/、docs/）
git grep -c 'P1-' README.md             # 应为 0（追加章节已移除）

# 3) 原有功能可用（旧 CLI/daemon 冒烟走既有方式；构建照常）
bash build.sh && unzip -t su-scheduler-v1.6.8.zip | grep -c 'No errors detected'
```

> **回滚零风险的原因**：P1 从无生产接线（无 shim/钩子/同名覆盖/写回 config），
> 新旧文件零同名冲突（`state.txt`/`events.log` 是新增名）。回滚后运行期目录中
> 若存在测试遗留的 `state.txt` 等，属测试临时目录残留（各 test.sh 尾部 `rm -rf`
> 已清理；CI 无残留），删除即可，不影响生产语义。

## 4. 升级-回滚循环

```bash
# 任意次循环：升级 → 验证 → 回滚 → 验证，均无迁移负担
git checkout 3fe7631            # 回滚
bash tests/build_check.sh       # 回滚后按需
git checkout main               # 再升级
bash tests/run_p1.sh            # 全绿
```

- 升级/回滚**不改变任何运行期行为路径**（daemon 主循环、service.sh 看护、
  config.txt 解析 = v1.6.8 原样）——循环验证的是「文档与层存在与否」，
  不是「生产行为切换」。

## 5. 故障排查

| 现象 | 原因与处置 |
| :--- | :--- |
| 升级后 `run_p1.sh` 出现 `[FAIL]` | 某 P1 层回归未过 → 该任务门禁失败：定位套件（输出前 10 条 FAIL），按该层文档修正；**不得**改测试掩盖（AGENTS §3.2），先在 `tests/_run_all.sh` 单套复现 |
| CRLF 检出下构建校验 `[SKIP]` | P1-01 §1 已记录基线事实（`core.autocrlf=true` 检出不可发布）；在 LF 工作树（CI ubuntu）或 `git -c core.autocrlf=false` 检出下跑完整构建 |
| 设备冒烟 `DEVICE_SKIPPED` | 无 adb/无授权设备（P0 D3：设备验证缺失按人工裁决）；脚本就绪，接入设备后直接跑 |
| 回滚后 README 残留 `P1-` 字样 | 追加章节未移除 → `git revert` 遗漏；用 `git status`/`git grep P1- README.md` 核对后补齐 |
| 回滚后发现生产文件被改 | **违规**（P1 提交本不得碰生产）：停止回滚，先 `git diff 3fe7631 -- system/ ...` 定位改动提交，评审其是否应保留（可能为 P2 已接线，非 P1 范围） |
| P1 文档宣称 Watchdog/WebUI/Dependency 已完成 | **文档违规**：P1-13 明确三者未实现（`docs/P1-HANDOVER.md` §5）；纠正措辞为「接口预留」 |