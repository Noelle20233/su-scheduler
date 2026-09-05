# Su Scheduler — P4 升级与回滚验证记录（P4-UPGRADE-ROLLBACK）

> **任务**：P4-12 · P4 出口评审与发布准备（本文件为「构建产物和升级回滚验证记录」交付物）
> **前置**：P4-EXIT-REPORT、P4-HANDOVER、P3-UPGRADE-ROLLBACK.md（命令级手册）
> **性质**：P4 的**验证记录**（在 P3 手册命令级基础上，记录 P4-11/P4-12 真机实测的
> 升级/回滚证据 + P4 特有数据兼容注意点）。P4 模块版本仍为 `v1.6.8`（D4 策略：内部
> Runtime 线 1.19.0 → 1.28.0 独立演进），升级 = 安装新 zip（同模块版本新构建），
> 回滚 = 卸载 / 重装旧版。
> **日期**：2026-09-05（P4-11 安装验证 + P4-12 出口复验）

---

## 目录

1. [P4 构建产物](#1-p4-构建产物)
2. [升级验证（真机实测）](#2-升级验证真机实测)
3. [回滚验证（真机实测）](#3-回滚验证真机实测)
4. [P4 特有数据兼容注意点](#4-p4-特有数据兼容注意点)
5. [升级-回滚循环](#5-升级-回滚循环)

---

## 1. P4 构建产物

```bash
# WSL（LF 工作树）构建发布候选
bash build.sh                          # 产出 su-scheduler-v1.6.8.zip
unzip -t su-scheduler-v1.6.8.zip | grep -c 'No errors detected'   # 期望 1
```

- **P4-12 出口复验**：`tests/p1-build/build_check.sh` → **26 PASS / 0 FAIL / 0 SKIP**
  （CRLF=0：完整构建 + `unzip -t` 完整性 + 八处版本一致 + Runtime 版本一致性
  A/B）。zip 含 `module.prop`/`service.sh`/`customize.sh`/`system/bin/`（4 bin）/
  `webroot/`（index.html/app.js/style.css）。
- 构建产物字节：`139448 bytes`（P4-11 构建，含 P4 全功能 + D-A/D-B/D-C 修复）。
- **版本面**：模块 `v1.6.8`（module.prop/update.json/README/build.sh/两 bin/docs
  头部八处一致）；Runtime 库 `1.28.0`（内部实现线，打包内与源文件一致）。

## 2. 升级验证（真机实测）

> 本机已有已授权 root 真机（KernelSU × Android 16，`8934ffc4`）。P4-11 期间完成
> 两次完整「安装 → 重启激活 → 全量冒烟」循环（初始安装 + 缺陷修复后重装）。

```bash
# 1) 推送发布候选
adb push su-scheduler-v1.6.8.zip /data/local/tmp/ss-mod.zip

# 2) KernelSU 安装
adb shell "su -c '/data/adb/ksu/bin/ksud module install /data/local/tmp/ss-mod.zip'"
#  → "Module installed successfully!"（modules_update → 重启激活）

# 3) 重启激活（FBE 解锁后 service.sh 拉起 daemon）
adb reboot
adb shell "su -c 'su-scheduler status'"          # → Alive（单实例）
adb shell "su -c 'grep -m1 Runtime /data/adb/su-scheduler/su-scheduler.log'"
#  → "Runtime library loaded (v1.28.0)"（P4-11 D-A 修复后，P4 功能可用）

# 4) 全量冒烟（P4-12 出口复验，2026-09-05）
bash tests/run_tests.sh --with-device
#  → ALL SUITES GREEN / EXIT=0
#    host 3812 PASS / 0 FAIL；p1-device 11 PASS / 0 FAIL / 2 SKIP；
#    p3-device 28 PASS / 0 FAIL / 0 BLOCKED（259s）
```

- **升级后数据兼容（实测）**：升级前/后 `/data/adb/su-scheduler/`（数据保险库）与
  `/sdcard/Documents/su-scheduler/config.txt` 保留；legacy 配置继续执行
  （p1-device 4/5/6/16 PASS）；managed 模式 `task-config import` 可用（p3-device
  5/6/8 PASS）；IPC/WebUI/控制真实可达（7/8/14 PASS）。

## 3. 回滚验证（真机实测）

- **路径 A（卸载）**：`ksud module uninstall su-scheduler` → 重启 → 模块目录移除、
  `/system/bin/su-scheduler*` 不可见；数据保险库与 `config.txt` 保留（P3-09 矩阵
  §2 已实测）。
- **路径 B（重装旧版）**：覆盖安装旧版 zip（同路径，见 P3-UPGRADE-ROLLBACK §3）。
- **P4-12 说明**：P4 生产改动全部叠加于 `su-scheduler-runtime`（新增 §20b/§26/
  §26b）+ `su-scheduler`/`su-schedulerd` 兼容修复 + `webroot/`；legacy 解析/执行
  路径未删除（C2）、`service.sh` 零改动（C5）、config 格式零变更（C4）。卸载/重装
  不触碰数据保险库与 config.txt → **回滚零数据迁移负担**。

## 4. P4 特有数据兼容注意点

| 对象 | 升级到 P4（Runtime 1.28.0）后 | 回滚到旧版后 |
| :-- | :-- | :-- |
| `task-config/*.task`（managed，含 `dependency=`/`condition=` 键） | 由 P4 Runtime 调度；无效依赖/条件在写盘前拒绝（图校验/文法白名单，P4-02/03/06） | 旧版若无 P4 解析 → 未知键被忽略或任务 KEPT（P3-02 KEPT 语义）；`tcfg_rollback` 回 legacy |
| `config.txt`（legacy） | 零改动继续执行；`dependency=`/`condition=` 仅 Task v2 managed 域 | 不变 |
| WAITING 运行目录（`state.txt=WAITING` + `gate.wait_start`） | P4 调度保留/推进（D13/D35） | 回滚后旧版无 WAITING 语义 → 残留目录按既有 rehydrate 规则处理 |
| `/data/adb/su-scheduler`（数据保险库） | 保留 | 保留 |

- **升级无迁移负担**：legacy 配置零改动；managed 模式可选导入；旧运行 ID 只读工件
  保持可查询（B3/B11）。

## 5. 升级-回滚循环

- 任意次循环（升级 → 验证 → 回滚 → 验证）均无迁移负担：升级/回滚不改变 config
  数据（数据保险库与 config.txt 独立于模块目录）。
- P4-11 实测：初始安装（Runtime 加载失败暴露 D-A）→ 修复重装（Runtime 1.28.0
  加载成功 + 28 PASS）→ 本任务复验（全绿）——同一模块目录反复覆盖安装，数据
  保险库全程保留，证明升级路径可重复。

---

## 附：与本任务其他交付物的一致性

- 命令级手册仍以 `docs/P3-UPGRADE-ROLLBACK.md` 为准；本文件记录 P4 特有验证证据与
  数据兼容注意点，不回写 P3 手册。
- 出口评审与 P5/P6 移交范围见 `docs/P4-EXIT-REPORT.md` 与 `docs/P4-HANDOVER.md`。
