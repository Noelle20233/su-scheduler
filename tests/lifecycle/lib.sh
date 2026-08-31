#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Lifecycle 层（P1-10）— 安全接入 daemon / service 生命周期
# ═══════════════════════════════════════════════════════════════════════════
# 作用：把新的 Task 基础（P1-06 Canonical Task Registry + P1-09 Runtime
# State/Event）封装为 daemon / service.sh 可安全接入的生命周期原语，**保留
# 可恢复性**。本层镜像现有 daemon 的真实语义（su-schedulerd L544-602 /
# service.sh L51-78），但作为独立函数库提供，daemon 接线时零改造接入。
#
# 依赖（使用前须按序 source）：
#   tests/state-machine/lib.sh          # TSM 状态集合/rehydrate/legacy 映射
#   tests/runtime/lib.sh                # state.txt / events.log / current_state
#   tests/legacy-adapter/adapter.sh     # LEGACY_ADAPTER_SOURCED=1（先置）
#   tests/task-registry/lib.sh          # registry_init/reload（最后有效快照）
#
# 镜像语义（逐项对应验收）：
#   - 单实例锁：/dev/.su_scheduler.lock（echo $$）；看护判定 /proc/<pid>
#     （service.sh L60-65）；stale 恢复 + 强接管（daemon L546-562）。
#   - stale PID / 僵尸清理：启动时对所有「运行态」任务：旧 status.txt ->
#     ZOMBIE_CRASHED（daemon L564-573），新 state.txt -> FAILED + 事件
#     （P1-09 rehydrate，验收 3）。**不删除现有 daemon 自保能力**。
#   - 启动初始化：ensure_dirs（tasks/audit 0755）→ 锁 → 僵尸清理 →
#     registry 最后有效快照（P1-06 KEPT 回退，fail-safe）。
#   - service.sh 兼容：watchdog_tick 为**单轮**看护检查（不创建第二个调度
#     循环；循环仍由 service.sh 既有 60s 看护承担）。
#   - 失败语义：初始化失败返回非 0 且**不留半初始化状态**（锁/目录回滚），
#     不因新模块失败无限重启（看护方仅一轮一判）。
#
# 上下文变量：LIFECYCLE_LOCK_WAIT（强接管前等待秒数，缺省 5，镜像 daemon
#   L546 wait window；测试注入 0 立即接管）。
# ═══════════════════════════════════════════════════════════════════════════
set -u

lifecycle_log() {
    [ "${LIFECYCLE_LOG:-1}" = "1" ] && echo "[lifecycle] $1" >&2
}

# ── 目录初始化（镜像 daemon L41-45：建数据/任务/审计目录）────────────────────
# 权限：目录 0755（P1-01 §3）。失败返回非 0（fail-safe：失败即中止启动）。
lifecycle_ensure_dirs() {
    base=$1
    [ -n "$base" ] || { lifecycle_log "ERROR ensure_dirs: base required"; return 1; }
    for d in "$base" "$base/tasks" "$base/audit"; do
        if ! mkdir -p "$d" 2>/dev/null; then
            lifecycle_log "ERROR ensure_dirs: cannot mkdir $d"
            return 1
        fi
        if ! chmod 755 "$d" 2>/dev/null; then
            lifecycle_log "ERROR ensure_dirs: cannot chmod $d"
            return 1
        fi
    done
    return 0
}

# ── 锁：读 pid ───────────────────────────────────────────────────────────────
lifecycle_lock_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null; }

# ── 锁：存活判定（镜像 service.sh L60-65）──────────────────────────────────
# 0=存活（锁存在 + pid 非空 + /proc/<pid> 可见）；1=无锁 或 stale。
lifecycle_lock_alive() {
    pid=$(lifecycle_lock_pid "$1")
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0
    return 1
}

# ── 锁：获取（单实例；活锁拒绝——不抢跑第二个实例）──────────────────────────
# 0=已获取（写入 $$）；1=拒绝（已有存活实例）。
lifecycle_lock_acquire() {
    lock=$1
    if lifecycle_lock_alive "$lock"; then
        lifecycle_log "WARNING lock_acquire: daemon already alive (pid=$(lifecycle_lock_pid "$lock")) — rejected"
        return 1
    fi
    if [ -f "$lock" ]; then
        # stale 锁：清理后再写（验收：stale lock 能恢复）
        lifecycle_log "INFO lock_acquire: stale lock removed (pid=$(cat "$lock" 2>/dev/null))"
        rm -f "$lock" 2>/dev/null || { lifecycle_log "ERROR lock_acquire: cannot rm stale lock"; return 2; }
    fi
    if ! echo "$$" > "$lock" 2>/dev/null; then
        lifecycle_log "ERROR lock_acquire: cannot write $lock"
        return 2
    fi
    return 0
}

# ── 锁：强接管（镜像 daemon L546-562：等待窗内轮询，超时无条件 rm + 写）────
# 返回 0=已接管（pid=$$）。
lifecycle_lock_force_reclaim() {
    lock=$1
    wait_s=${LIFECYCLE_LOCK_WAIT:-5}
    i=0
    while [ "$i" -lt "$wait_s" ]; do
        lifecycle_lock_alive "$lock" || break
        sleep 1
        i=$((i + 1))
    done
    # 等待窗结束（无论是否仍 alive）→ 无条件接管（镜像 daemon L561-562）
    if [ -f "$lock" ]; then
        lifecycle_log "INFO lock_force: reclaiming lock (old pid=$(cat "$lock" 2>/dev/null))"
        rm -f "$lock" 2>/dev/null || { lifecycle_log "ERROR lock_force: cannot rm lock"; return 2; }
    fi
    if ! echo "$$" > "$lock" 2>/dev/null; then
        lifecycle_log "ERROR lock_force: cannot write $lock"
        return 2
    fi
    return 0
}

# ── 锁：释放（镜像 CLI stop / daemon 退出）──────────────────────────────────
lifecycle_lock_release() {
    rm -f "$1" 2>/dev/null
    return 0
}

# ── 僵尸清理（镜像 daemon L564-573 + P1-09 再水合）───────────────────────────
# 启动时对每个「运行态」任务（新 state.txt 或旧 status.txt 推导均为执行态）：
#   - 旧兼容：status.txt 含 RUNNING → ZOMBIE_CRASHED（daemon L568-570）；
#   - 新统一源：runtime_log_event（event=daemon_restart, state=rehydrate 后
#     FAILED）+ state.txt 原子更新（P1-09）——旧任务不永久标记为运行中（验收 3）。
# **不查 pid 死活**（镜像 daemon：新实例视角下不存在活动任务）。
# stdout：恢复的任务数（一行）；0 表示无残留。
lifecycle_cleanup_zombies() {
    tasks_dir=$1
    [ -d "$tasks_dir" ] || { lifecycle_log "INFO cleanup: no tasks dir $tasks_dir"; echo 0; return 0; }
    n=0
    for p in "$tasks_dir"/*; do
        [ -d "$p" ] || continue
        cur=$(runtime_current_state "$p")
        case "$cur" in
            STARTING|RUNNING|HEALTHY|UNHEALTHY|RECOVERING|STOPPING) ;;
            *) continue ;;
        esac
        id=$(basename "$p")
        old_state=$(cat "$p/status.txt" 2>/dev/null)
        pid_rec=$(cat "$p/pid.txt" 2>/dev/null)
        # 旧兼容标记（仅当旧文件为运行态；镜像 daemon grep -q RUNNING）
        case "$old_state" in
            *RUNNING*) echo "ZOMBIE_CRASHED" > "$p/status.txt" 2>/dev/null ;;
        esac
        # 新统一源：events.log + state.txt（task_state_rehydrate 执行态 -> FAILED）
        newstate=$(task_state_rehydrate "$cur")
        runtime_log_event "$p" "$id" daemon_restart "$newstate" "$pid_rec" "" \
            "zombie cleanup at startup (legacy status.txt -> ZOMBIE_CRASHED)" >/dev/null 2>&1
        lifecycle_log "INFO cleanup: recovered zombie task $id ($cur -> $newstate)"
        n=$((n + 1))
    done
    echo "$n"
    return 0
}

# ── 启动初始化（镜像 daemon 启动序列，接线层入口）───────────────────────────
# lifecycle_start <base> <config> <lockfile>：
#   ensure_dirs → lock_acquire（单实例）→ cleanup_zombies → registry 快照。
# 返回 0=就绪（锁已写 $$）；1=拒绝（已有实例）；2=初始化失败（已回滚锁，
#   不留半初始化状态——fail-safe，可安全重试，不无限重启）。
lifecycle_start() {
    base=$1; config=$2; lock=$3
    [ -n "$base" ] && [ -n "$config" ] && [ -n "$lock" ] || {
        lifecycle_log "ERROR start: base/config/lock required"
        return 2
    }
    # 1) 目录（失败即中止，不碰锁）
    lifecycle_ensure_dirs "$base" || return 2
    # 2) 单实例锁（活锁拒绝；stale 自动恢复）
    lifecycle_lock_acquire "$lock" || return 1
    # 3) 任务目录僵尸恢复（旧记录不永久 RUNNING，验收 3）
    lifecycle_cleanup_zombies "$base/tasks" >/dev/null 2>&1
    # 4) Canonical Task Registry：成功 = 存在**当前快照**（含 KEPT 回退——最后
    #    有效快照保留仍视为就绪，fail-safe）；无快照（首次解析失败/硬错误）→ 失败。
    registry_init "$base" "$config" >/dev/null 2>&1
    if [ -n "$(registry_current_snapshot_id 2>/dev/null)" ]; then
        lifecycle_log "INFO start: ready (base=$base snapshot=$(registry_current_snapshot_id 2>/dev/null))"
        return 0
    fi
    lifecycle_log "ERROR start: registry init failed for $config (no valid snapshot fallback)"
    lifecycle_lock_release "$lock"   # fail-safe：不留半初始化锁
    return 2
}

# ── 停止（镜像 CLI stop：kill 锁内 daemon 进程 + 释放锁）─────────────────────
# 返回 0=已停止（进程已死或锁已释放）。
lifecycle_stop() {
    lock=$1
    pid=$(lifecycle_lock_pid "$lock")
    if [ -n "$pid" ] && [ -d "/proc/$pid" ] 2>/dev/null; then
        kill "$pid" 2>/dev/null
        i=0
        while [ "$i" -lt 5 ]; do
            [ -d "/proc/$pid" ] 2>/dev/null || break
            sleep 1
            i=$((i + 1))
        done
    fi
    lifecycle_lock_release "$lock"
    return 0
}

# ── 重启（镜像 CLI restart L883-890：stop → sleep 1 → nohup 新 daemon）───────
# 新 daemon 进程由调用方命令拉起，**自行**执行 lifecycle_start（写锁 +
# 快照/僵尸恢复）；本函数不写锁（避免"当前进程冒认 daemon"）。
# lifecycle_restart <lock> <base> <config> <daemon_cmd>
lifecycle_restart() {
    lock=$1; base=$2; config=$3; daemon_cmd=${4:-}
    lifecycle_stop "$lock"
    sleep 1
    if [ -n "$daemon_cmd" ]; then
        nohup $daemon_cmd >/dev/null 2>&1 &
        lifecycle_log "INFO restart: launched '$daemon_cmd' (new daemon re-locks itself)"
        return 0
    fi
    lifecycle_log "ERROR restart: no daemon_cmd given"
    return 2
}

# ── 看护单轮（镜像 service.sh L56-76，**非循环**）───────────────────────────
# lifecycle_watchdog_tick <lockfile> [daemon_cmd]：
#   lock alive → 0（不动作）；无锁/死锁 → 清 stale 锁 + nohup 拉起 daemon_cmd
#   → 1（已拉起）。只做一轮判定；循环仍由 service.sh 既有 60s 看护承担
#   （约束：不创建第二个独立调度循环）。
lifecycle_watchdog_tick() {
    lock=$1; daemon_cmd=${2:-}
    if lifecycle_lock_alive "$lock"; then
        return 0
    fi
    lifecycle_log "WARNING watchdog_tick: daemon not running — cleaning stale lock and (re)starting"
    rm -f "$lock" 2>/dev/null
    if [ -n "$daemon_cmd" ]; then
        nohup $daemon_cmd >/dev/null 2>&1 &
        lifecycle_log "INFO watchdog_tick: launched '$daemon_cmd'"
    else
        lifecycle_log "INFO watchdog_tick: no daemon_cmd given — handover to caller"
    fi
    return 1
}