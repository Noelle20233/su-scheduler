# Lifecycle 层 — P1-10

> **任务**：P1-10 · 安全接入 daemon 和 service 生命周期
> **依赖**：P1-06（Canonical Task Registry）、P1-09（Runtime State & Event Log）
> **位置**：`tests/lifecycle/`（lib.sh 生命周期原语 + test.sh 回归 + 本文档）

## 目标

把新的 Task 基础安全接入 daemon / `service.sh` 生命周期，**保留可恢复性**，
同时**不删除现有 daemon 自保能力**。本层镜像 `su-schedulerd` 启动序列
（L544-602）与 `service.sh` 看护判定（L51-78），全部封装为参数注入的独立
函数——daemon 接线时零生产改动。

## 覆盖范围（对应任务重点）

| 重点 | 原语 | 镜像语义 |
| :--- | :--- | :--- |
| 单实例锁 | `lifecycle_lock_acquire` / `_alive` / `_release` / `_force_reclaim` | `/dev/.su_scheduler.lock`（echo $$）；看护判定 `/proc/<pid>`（service.sh L60-65）；stale 恢复 + 等待窗强接管（daemon L546-562） |
| stale PID 清理 | `lifecycle_cleanup_zombies` | 启动时对所有「运行态」任务：旧 `status.txt`→`ZOMBIE_CRASHED`（daemon L564-573）+ 新 `state.txt`→`FAILED` + `daemon_restart` 事件（P1-09 再水合） |
| daemon 启动初始化 | `lifecycle_start` | ensure_dirs（0755）→ 锁 → 僵尸清理 → registry 最后有效快照 |
| 异常退出任务恢复 | 同 `cleanup_zombies` | 崩溃后旧任务**不永久 RUNNING**（新旧源都恢复） |
| service.sh 启动逻辑 | `lifecycle_watchdog_tick` | 单轮看护（alive 不动作 / stale 清锁+拉起）；**循环仍由 service.sh 60s 看护承担**——不创建第二个调度循环 |
| 目录/权限 | `lifecycle_ensure_dirs` | `$base`/`tasks`/`audit` 0755（P1-01 §3）；失败即中止 |
| 最后有效配置快照 | `lifecycle_start`（registry KEPT） | 配置损坏且已有快照 → 仍就绪（保留旧快照）；全新无快照 + 坏配置 → 拒绝启动 |
| 停止/重启 | `lifecycle_stop` / `lifecycle_restart` | CLI stop（kill + 释放锁）/ CLI restart（stop → sleep 1 → nohup 新 daemon） |

## 安全/失败语义

- **单实例**：活锁拒绝第二个 `lifecycle_start`（不抢跑双实例）。
- **fail-safe**：初始化失败返回非 0 且**不留半初始化状态**（锁已释放、无残留
  快照目录）——不因新模块失败无限快速重启（看护方仅一轮一判 + 既有 60s 节奏）。
- **任务执行失败不终止 daemon**：执行归 P1-08（FAILED 落工件）与 P1-09（事件
  落 state.txt/events.log），生命周期层不介入执行，锁/快照不受影响。
- **不硬编码生产路径**：所有路径经参数注入（lib 无 `/data/adb/...`、
  `/dev/.su_scheduler.lock`）——接线零冲突。
- **兼容保留**：旧 `status.txt` 与 CLI 读取语义不变；`service.sh` 看护循环
  不改；僵尸标记行为与 daemon 现在完全一致。

## 测试

```bash
bash tests/lifecycle/test.sh    # 全 [PASS] 且 exit 0
```

覆盖：锁全套（acquire/拒绝/stale/强接管/释放/0644）、目录权限与 fail-safe、
僵尸清理（旧+新源、混合态、不碰已完成任务）、daemon 启动/单实例拒绝/停止/
重启（模拟 daemon 子进程）、启动时崩溃恢复端到端、最后有效快照回退、
看护单轮 + 无 while-true 结构断言、无硬编码生产路径。