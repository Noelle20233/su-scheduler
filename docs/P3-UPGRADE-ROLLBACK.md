# Su Scheduler — P3 升级与回滚操作手册（P3-UPGRADE-ROLLBACK）

> **任务**：P3-10 · P3 出口评审与发布准备（本文件为「升级与回滚」交付物）
> **前置**：P3-EXIT-REPORT、P3-HANDOVER、P2-EXIT-REPORT
> **性质**：**命令级操作手册**（设备端安装/卸载 + 宿主端发布校验）；原则与影响面见
> `docs/P3-HANDOVER.md` §8。
> **核心前提**：P3 模块版本仍为 `v1.6.8`（与 P2 出口相同）——发布候选 zip 是**同一
> 模块版本**的新构建（内容含 P3 Runtime §19–25 与 webroot/）。升级 = 安装新 zip；
> 回滚 = 卸载/重装旧版。数据保险库在卸载时保留（P3-DEVICE-MATRIX §2.1）。
> **日期**：2026-09-03

---

## 目录

1. [影响面与前提](#1-影响面与前提)
2. [升级（发布候选安装）](#2-升级发布候选安装)
3. [回滚（卸载 / 重装旧版）](#3-回滚卸载--重装旧版)
4. [升级-回滚循环](#4-升级-回滚循环)
5. [故障排查](#5-故障排查)

---

## 1. 影响面与前提

| 对象 | 升级后 | 回滚后 |
| :-- | :-- | :-- |
| `system/bin/su-scheduler-runtime` | 含 §19–25 + **D-IPC cut 修复** | 旧版 |
| `system/bin/su-schedulerd` / `su-scheduler` | P3 兼容接线（legacy 不变） | 旧版 |
| `system/bin/su-scheduler-termux` | 原样（P0 未动） | 原样 |
| `webroot/`（index.html/app.js/style.css） | P3 WebUI | 旧版（若旧版无则移除） |
| `service.sh` | 原样（P0/P3 零改动，C5） | 原样 |
| `customize.sh` / `build.sh` | 纳入 webroot 打包 | 旧版 |
| `module.prop` / `update.json` | 仍 `v1.6.8`（未 bump） | 仍 `v1.6.8` |
| `/data/adb/su-scheduler`（数据保险库） | 保留（升级不删） | 保留（卸载不删） |
| `/sdcard/Documents/su-scheduler/config.txt` | 保留（旧配置兼容） | 保留 |

**前提校验（升级前必跑）**：

```bash
# 宿主门禁（WSL / Linux CI；Windows Git-Bash 有 pre-existing 环境限制）
bash tests/run_tests.sh                # 期望：ALL SUITES GREEN，0 FAIL
bash tests/p1-build/build_check.sh     # 期望：构建 + unzip -t + 八处版本一致全 [PASS]
bash tests/p3-integration/test.sh      # 期望：48 PASS / 0 FAIL
```

## 2. 升级（发布候选安装）

```bash
# 1) 宿主构建发布候选 zip（LF 工作树）
bash build.sh                          # 产出 su-scheduler-v1.6.8.zip
unzip -t su-scheduler-v1.6.8.zip | grep -c 'No errors detected'   # 期望 1

# 2) 推送 / 拉取到设备
adb push su-scheduler-v1.6.8.zip /data/local/tmp/

# 3) 按管理器安装（KernelSU 示例；Magisk/APatch 用对应刷入）
adb shell "su -c '/data/adb/ksu/bin/ksud module install /data/local/tmp/su-scheduler-v1.6.8.zip'"

# 4) 重启激活（FBE 解锁后 service.sh 拉起 daemon）
adb reboot
# 等 FBE 解锁后：
adb shell "su -c 'su-scheduler status'"    # 期望：Alive
adb shell "su -c 'su-scheduler task-config status'"   # 期望：mode=legacy（若未导入 managed）

# 5) 设备冒烟（有授权设备时；IPC 项依赖 D-IPC 修复后的真机重验）
bash tests/run_tests.sh --with-device
# 期望：p1-device 全 PASS；p3-device 全 PASS / 0 FAIL / 0 BLOCKED（D-IPC 修复后）
# （若设备不可用 → DEVICE_SKIPPED 明示，不得以宿主结果冒充）
```

**升级后数据兼容**：

- 既有 `config.txt` 行（legacy 模式）继续执行（旧 CLI add/list/remove 等零改动）。
- 用户可执行 `su-scheduler task-config import <cfg>` 将旧配置提升为 Task v2（managed
  模式）→ Registry 正式调度；`tcfg_rollback` 可随时回到 legacy。
- 旧任务运行目录 / 旧运行 ID 只读工件（status/pid/output/exit_code）继续可查询。

## 3. 回滚（卸载 / 重装旧版）

**两个等价路径**：

```bash
# 路径 A：卸载模块（保留数据保险库 + config.txt）
adb shell "su -c '/data/adb/ksu/bin/ksud module uninstall su-scheduler'"   # KernelSU
#   Magisk：Magisk 应用 → 模块 → 卸载；APatch：对应管理器移除
adb reboot

# 路径 B：重装旧版发布 zip（覆盖当前构建，保留数据）
adb push su-scheduler-vX.Y.Z.zip /data/local/tmp/
adb shell "su -c '/data/adb/ksu/bin/ksud module install /data/local/tmp/su-scheduler-vX.Y.Z.zip'"
adb reboot
```

**回滚后核对**：

```bash
adb shell "su -c 'su-scheduler status'"                 # Alive
adb shell "su -c 'ls /data/adb/su-scheduler'"           # 数据保险库保留
adb shell "su -c 'cat /sdcard/Documents/su-scheduler/config.txt'"   # 旧配置保留
# 若回滚到旧版（无 webroot/P3），su-scheduler webui 子命令应优雅报"不支持/未找到"，
# 且 daemon 调度（legacy）不受影响。
```

> **回滚低风险原因**：P3 全部生产改动叠加于 `su-scheduler-runtime`（新增 §）与兼容
> 接线；legacy 解析/执行路径未删除（C2）、`service.sh` 零改动、config 格式零变更（C4）。
> 卸载/重装不触碰 `/data/adb/su-scheduler` 与 `config.txt`。

## 4. 升级-回滚循环

```bash
# 任意次循环：升级 → 验证 → 回滚 → 验证，均无迁移负担
# 升级：安装新 zip → 重启 → status Alive + 冒烟
# 回滚：ksud module uninstall / 重装旧版 → 重启 → status Alive + 数据保留
```

- 升级/回滚**不改变 config 数据**（数据保险库与 config.txt 独立于模块目录）；验证的是
  模块功能（WebUI/IPC/Registry）而非数据迁移。

## 5. 故障排查

| 现象 | 原因与处置 |
| :-- | :-- |
| 升级后 `su-scheduler webui GET_SUMMARY` 返回 `malformed/invalid_request` | 若为旧版本模块（未含 D-IPC 修复）在 Android 16 mksh 上触发——升级到含 P3-10 修复的 zip；若修复后仍现，按 `docs/P3-DEVICE-MATRIX.md` §3 复查（真机重验） |
| `task-config import` 失败（rc≠0） | 配置含损坏/控制字符行 → 行级拒绝 + 原配置逐字节不变（`tests/p3-integration` §15 语义）；用 `tcfg_rollback` 还原 |
| `config.txt` 在 managed 导入后执行异常 | 回退到 legacy：`su-scheduler task-config rollback`；daemon 自动切回 legacy 扫描（C2 fallback） |
| 卸载后 config.txt 丢失 | **异常**（卸载本应保留数据保险库与 config.txt）；从备份恢复（如有）；`ksud module uninstall` 不应删 `/sdcard/Documents/su-scheduler/` |
| 回滚旧版后出现 `webroot` 遗留 | 旧版无 webroot 属正常；删除旧目录即可，不影响调度语义 |
| 宿主 `run_tests.sh` 在 Windows Git-Bash 不全绿 | pre-existing 环境限制（缺 zip/pgrep、MSYS dash、chmod 语义）；用 WSL Ubuntu 或 Linux CI 跑 |