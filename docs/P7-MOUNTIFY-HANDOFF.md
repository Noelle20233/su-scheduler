# P7-01 — Mountify 兼容：挂载职责移交（决策与取证）

> 日期：2026-09-11 ｜ 基线：v1.6.8 / Runtime 1.32.0（P6-12 出口后首项）
> 关联：`customize.sh` PHASE 3.5、`service.sh` Phase 2、`su-schedulerd`
> `runtime_drift_check`、`tests/p7-mountify/`、`tests/p7-device/`

## 1. 决策记录（人工裁决）

| # | 决策 | 内容 |
|---|------|------|
| D-P7-01 | **无条件删 skip 标记** | 不写 `skip_mount`/`skip_mountify`，模块不退出宿主挂载系统。理由（裁决人）：KSU 即使未装元模块，其自身 magic mount 亦完整可用；装了 Mountify（metamode）则由它接管。两种情况都不需要我方 opt-out。 |
| D-P7-02 | **移交拷贝语义，放弃 live-edit** | Mountify 接管后我方文件是"每开机重刷的拷贝"；统一以**重启为生效语义**（忠实"转移"目标）。原 P7-01-a 自 bind（含幂等/stub/回退链）整体废弃移除。 |
| D-P7-03 | **保留两项配套** | ① customize.sh 对 5 个文件 `chcon u:object_r:system_file:s0`（KSU bind 携带源 inode 标签、Mountify 镜像源上下文，源标签正确是唯一可靠修复点）；② daemon `runtime_drift_check` 版本漂移 WARN（仅日志，零行为改动）。 |

## 2. Mountify 权威语义（真机取证，非文档转述）

来源：设备 `8934ffc4`/`192.168.2.156:38001`（KernelSU，`u:r:ksu`）`/data/adb/modules/mountify/metamount.sh`：

- L191：模块含 `skip_mountify` → 跳过（Magisk 非 metamode 信号）；
- L199-200：**metamodule 模式**（`$MODDIR/metamount.sh` 存在，即 KSU/APatch）尊重模块自带 `skip_mount` → 跳过；
- L207-208：非 metamode 挂载后由 Mountify 自行 `touch skip_mount`（宿主卸载时 uninstall.sh L11 回收）；
- L308-311：`mountify_mounts=1` 仅挂 `modules.txt` 所列；`=2`（本机现值）挂所有含 `system/` 的模块；
- 设备现值：`FAKE_MOUNT_NAME="6nfqmuo8wn"`（随机化伪装名）、`use_ext4_sparse=0`（tmpfs 模式）。

**结论**：我方不写标记 → `mountify_mounts=2` 下 Mountify 必挂我方；`mountify_mounts=1` 时由用户自行将 `su-scheduler` 加入其 `modules.txt`（他模块配置，我方不代改）。

## 3. 设备现状取证（为何必须移交而非自 bind）

- `/system` 为 **erofs ro**（`/dev/block/dm-*`，`seclabel`）→ 单文件 bind 无法自建缺失目标（stub `touch` 必败）——P7-01-a 在此类设备上永远走回退，自 bind 无生存空间；
- `/proc/mounts` 无 `/system/bin` 条目，而 `/system/bin/su-scheduler*` 存在且 **`u:object_r:shell_data_file:s0`**（termux 除外）→ 系历史热修**手工拷贝**（与模块目录 inode 不同：`507943` vs `441392`），非任何挂载系统产物；
- 佐证：root shell 命名空间看不到 Mountify 挂载 ≠ 未挂载（zygisk 卸载视图遮蔽；
  实为 overlay 接管+暂存 detach，见 §8），终态验证以 `tests/p7-device/smoke.sh`
  5-mountify（overlay 签名）/6-converged（cmp 逐字节）断言为准。

## 4. 挂载归属决策表（移交后）

| 环境 | 谁挂载 /system/bin/* | 更新生效 |
|------|---------------------|----------|
| KSU/APatch + Mountify（metamode） | Mountify 暂存+拷贝 | 重启（1 次，无收敛窗——全新安装首启即挂） |
| KSU/APatch/Magisk 无 Mountify | 宿主 magic mount | 重启 |
| 均未挂载（极早期/禁用态） | 无人挂载：daemon 经 `$MODDIR` 回退直跑（既有 C2 路径），CLI 暂不在 PATH | — |

版本漂移窗口（重装模块未重启）由 `runtime_drift_check` 在
`/data/adb/su-scheduler/su-scheduler.log` 记 WARNING：
`🧪 Runtime version drift: mounted vX != module-dir vY (reboot to propagate update)`。

## 5. 改动面

| 文件 | 改动 |
|------|------|
| `customize.sh` | PHASE 3.5 = chcon 标签（skip 标记删除，D-P7-01/03） |
| `service.sh` | 无挂载逻辑；Phase 2 注释声明委托；MODDIR 回退原样（C2） |
| `system/bin/su-schedulerd` | `runtime_drift_check` 定义+调用（加载块后，仅日志） |
| `tests/p7-mountify/test.sh` | 静态：skip 零出现/无 mount 命令行/回退在位/漂移函数接线；行为：drift 四态单测（21 断言） |
| `tests/p7-device/smoke.sh` | L3 六项：无标记/文件在位/system_file/CLI/Mountify overlay 签名/副本 cmp 收敛（陈旧态 SKIP 不谎报） |
| `tests/run_tests.sh` | 注册与描述更新 |
| `README.md` | Mounting 小节重写 |

**零改动**：zip 布局（`system/` 原样）、`build.sh`、`module.prop`、`update.json`、
CLI 27 处 `/system/bin` 硬编码、全部解析/执行路径（C1/C2/C4）。

## 6. 验收状态

- [x] 宿主全量回归 L1+L2+L4：ALL GREEN（含 p7-mountify 21/0）
- [x] **设备矩阵（2026-09-11 完成，25113PN0EC / Android 16 / KernelSU + Mountify）**：
      flash 新构建（`ksud module install` + 1 次重启）→ p7-device **8/0/0**；
      接管取证见 §8；drift 注入/还原模拟通过；legacy 回归 p1-device **11/0/2**、
      p3-device **28/0/0**（220s）。详见 §8。

## 7. 候选缺陷登记（本次验证暴露，非 P7-01 引入，未顺手修复）

**D-P7-02（既有偶发，测试基建）**：`tests/task-control/test.sh` P5-07 batch 块
（L327-371）间歇性全块 FAIL（9 项），首个 `start` 即 `t_b1: task_not_found (rc=3)`，
此后 disable/enable 均 rc=1——`tcfg_new_task` 落盘后、fake-daemon 注册表首次
消费前的刷新时序竞态（与 D-P5-03 idmap-refresh 家族同源；`state_sync_all`/
`runtime_map_refresh` 的 tick 驱动可见性窗口）。

证据（WSL 原生 fs，连跑同套件）：

| 树状态 | 尝试 | FAIL |
|--------|------|------|
| 含 P7-01 改动 | 3 连跑 | 0, 0, 9 |
| **基线 daemon（git stash 掉 su-schedulerd 改动）** | 5 连跑 | 0, 0, 7, 0, 0 |
| 含 P7-01 改动 | 6 连跑 | attempt2 即 9 |
| 全量 run_tests（10:08、10:54 两轮） | 2 | 全绿 |

对照组证明与 P7-01 生产改动**无关**（基线同样复现）。处置：登记，移交后续
测试基建任务（批内先做一次显式 registry 刷新/有界轮询等 `t_b1` 可见再发命令）。
本任务出口标准按"全量回归出现该签名 FAIL 时可单套件复验转绿"执行。

## 8. 接管真机取证（2026-09-11，flash+单次重启后）

- **接管签名（重要修正）**：`/proc/mounts` 出现
  `KSU /system/bin overlay ro, lowerdir=/mnt/vendor/<FAKE>/bin:/system/bin`
  ——Mountify 用伪装设备名 "KSU" 的 **OverlayFS** 接管，且挂载后即 **detach 其
  暂存 tmpfs**（连 `nsenter -t 1 -m` 的 init 命名空间都看不到 `<FAKE>` 目录）。
  ⇒ §3 中"以暂存区 glob 为断言"的设想**不成立**；正确签名 = `/system/bin`
  条目 fstype 为 `overlay`（宿主原生 magic mount 只做 bind/tmpfs，不做
  overlay）。`tests/p7-device/smoke.sh` 5-mountify 已按此签名断言（PASS）。
- **拷贝语义坐实**：挂载副本 inode `137:16390`（overlay 设备）≠ 模块源
  `65080:514394`，内容与模块源逐字节一致（6-converged cmp SAME）。
- **标签传播**：`/system/bin/su-scheduler*` 全部 `u:object_r:system_file:s0`
  （安装期 chcon → Mountify 镜像源标签；§3 的 shell_data_file 脏标签消失）。
- **drift 语义验证**：不重启、sed 提升模块目录 runtime 版本号 →
  `su-scheduler restart` → 日志恰新增
  `🧪 Runtime version drift: mounted v1.32.0 != module-dir v99.99.99-driftsim
  (reboot to propagate update)`；还原文件再 restart → 静默。设备已还原一致态。
- **运维备注**：本次为保活网络 adb 设置过 `persist.adb.tcp.port=5555` 与
  `service.adb.tcp.port=5555`（重启后 adb 仍在 5555）。不需要可清除：
  `setprop persist.adb.tcp.port ""` + `resetprop -d persist.adb.tcp.port`。
