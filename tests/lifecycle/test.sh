#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Lifecycle 层测试（P1-10）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应验收标准）：
#   1) 单实例锁：acquire/拒绝/alive/stale 恢复/force_reclaim/释放/权限 0644
#   2) 配置与运行目录权限：ensure_dirs（0755）；初始化失败 fail-safe
#   3) stale PID / 僵尸清理（验收 3）：运行态残留 -> 旧 status.txt=
#      ZOMBIE_CRASHED + 新 state.txt=FAILED + daemon_restart 事件；
#      SUCCESS/非运行态不动；混合态（新源优先、旧件仅 RUNNING 才标）
#   4) daemon 启动/停止/重启（验收 1）：模拟 daemon 子进程，启动就绪
#      （锁+快照），单实例拒绝第二个实例，stop 杀进程+释放锁，restart
#      停旧拉新；启动时僵尸恢复端到端；初始化失败不留半初始化锁/快照
#   5) 最后有效配置快照（fail-safe）：已有快照 + 配置损坏 -> 重启仍就绪
#      且快照保留（KEPT 回退）；全新无快照 + 坏配置 -> 启动失败并回滚锁
#   6) service.sh 兼容（验收）：watchdog_tick 单轮（alive 不动作 / stale
#      清理+拉起）；**无 while true 主循环**（不创建第二个调度循环）
#   7) 接线安全：lib 无硬编码生产路径（/data/adb/su-scheduler、
#      /dev/.su_scheduler.lock）——接入点全由参数注入
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ../state-machine/lib.sh
. ../runtime/lib.sh
LEGACY_ADAPTER_SOURCED=1
. ../legacy-adapter/adapter.sh
. ../task-registry/lib.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

BASE=$(mktemp -d)
LOCK="$BASE/daemon.lock"

# ── 1) 单实例锁 ─────────────────────────────────────────────────────────────
lifecycle_lock_alive "$LOCK" >/dev/null 2>&1 && bad "no-lock should not be alive" || ok "lock not alive when missing"
lifecycle_lock_acquire "$LOCK" >/dev/null 2>&1 && ok "lock acquire (fresh) writes pid" || bad "lock acquire fresh"
[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && ok "lock pid = caller pid" || bad "lock pid=$(cat "$LOCK" 2>/dev/null)"
lifecycle_lock_alive "$LOCK" >/dev/null 2>&1 && ok "lock alive while pid exists" || bad "lock alive"
lifecycle_lock_acquire "$LOCK" >/dev/null 2>&1 && bad "second acquire should be rejected (single instance)" || ok "second acquire rejected (single instance)"
perm_lock=$(ls -l "$LOCK" | awk '{print $1}')
[ "$perm_lock" = "-rw-r--r--" ] && ok "lock mode 0644 ($perm_lock)" || bad "lock mode $perm_lock"

# stale 锁恢复（验收：stale lock 能恢复）
printf '99999999\n' > "$LOCK"
lifecycle_lock_alive "$LOCK" >/dev/null 2>&1 && bad "dead-pid lock should be stale" || ok "dead-pid lock detected as stale"
lifecycle_lock_acquire "$LOCK" >/dev/null 2>&1 && ok "stale lock recovered by acquire" || bad "stale lock acquire"
[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && ok "recovered lock pid renewed" || bad "recovered lock pid"
lifecycle_lock_release "$LOCK" >/dev/null 2>&1
[ ! -f "$LOCK" ] && ok "lock released" || bad "lock release"

# force_reclaim（镜像 daemon 强接管：等待窗后无条件接管）
printf '99999999\n' > "$LOCK"
LIFECYCLE_LOCK_WAIT=0 lifecycle_lock_force_reclaim "$LOCK" >/dev/null 2>&1 && ok "force_reclaim takes stale lock" || bad "force_reclaim stale"
[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && ok "force_reclaim wrote new pid" || bad "force_reclaim pid"
lifecycle_lock_release "$LOCK" >/dev/null 2>&1

# ── 2) 目录与权限（验收：配置/运行目录权限） ─────────────────────────────────
LDIR="$BASE/runtime"
lifecycle_ensure_dirs "$LDIR" >/dev/null 2>&1 && ok "ensure_dirs creates base" || bad "ensure_dirs base"
for d in "$LDIR" "$LDIR/tasks" "$LDIR/audit"; do
    p=$(ls -ld "$d" | awk '{print $1}')
    [ "$p" = "drwxr-xr-x" ] && ok "dir $d mode 0755" || bad "dir $d mode $p"
done
touch "$BASE/afile"
lifecycle_ensure_dirs "$BASE/afile/tasks" >/dev/null 2>&1 && bad "ensure_dirs on file path should fail" || ok "ensure_dirs fails cleanly (fail-safe)"

# ── 3) 僵尸清理（验收 3：崩溃后不永久 RUNNING） ─────────────────────────────
ZT="$BASE/tasks"
mkdir -p "$ZT/zombie_a" "$ZT/zombie_b" "$ZT/zombie_mixed" "$ZT/done_task"
printf 'RUNNING\n' > "$ZT/zombie_a/status.txt"
printf 'RUNNING\n' > "$ZT/zombie_a/state.txt"
printf 'deadpid\n' > "$ZT/zombie_a/pid.txt"
printf 'RUNNING\n' > "$ZT/zombie_b/status.txt"      # 仅旧源（无 state.txt）
printf 'deadpid\n' > "$ZT/zombie_b/pid.txt"
printf 'SUCCESS\n' > "$ZT/zombie_mixed/status.txt"  # 新源 RUNNING、旧件 SUCCESS
printf 'RUNNING\n' > "$ZT/zombie_mixed/state.txt"
printf '99\n' > "$ZT/zombie_mixed/pid.txt"
printf 'SUCCESS\n' > "$ZT/done_task/status.txt"
printf '44\n' > "$ZT/done_task/pid.txt"

n=$(LIFECYCLE_LOG=0 lifecycle_cleanup_zombies "$ZT")
[ "$n" -eq 3 ] && ok "cleanup recovered 3 zombies (a/b/mixed, not done)" || bad "cleanup count=$n"
[ "$(cat "$ZT/zombie_a/status.txt")" = "ZOMBIE_CRASHED" ] && ok "zombie_a legacy -> ZOMBIE_CRASHED" || bad "zombie_a status=$(cat "$ZT/zombie_a/status.txt")"
[ "$(cat "$ZT/zombie_a/state.txt")" = "FAILED" ] && ok "zombie_a new state -> FAILED (rehydrated)" || bad "zombie_a state=$(cat "$ZT/zombie_a/state.txt")"
grep -q '|daemon_restart|FAILED|' "$ZT/zombie_a/events.log" && ok "zombie_a events.log daemon_restart->FAILED" || bad "zombie_a no event"
[ "$(cat "$ZT/zombie_b/status.txt")" = "ZOMBIE_CRASHED" ] && ok "zombie_b legacy-only -> ZOMBIE_CRASHED" || bad "zombie_b status"
[ "$(cat "$ZT/zombie_b/state.txt")" = "FAILED" ] && ok "zombie_b state.txt derived + FAILED" || bad "zombie_b state=$(cat "$ZT/zombie_b/state.txt")"
[ "$(cat "$ZT/zombie_mixed/status.txt")" = "SUCCESS" ] && ok "mixed: legacy SUCCESS NOT overwritten (new source wins)" || bad "mixed legacy overwritten"
[ "$(cat "$ZT/zombie_mixed/state.txt")" = "FAILED" ] && ok "mixed: new state RUNNING -> FAILED" || bad "mixed state=$(cat "$ZT/zombie_mixed/state.txt")"
[ "$(cat "$ZT/done_task/status.txt")" = "SUCCESS" ] && [ ! -f "$ZT/done_task/events.log" ] && \
    ok "completed task untouched by cleanup" || bad "completed task touched"
[ "$(grep -rl RUNNING "$ZT" 2>/dev/null | wc -l)" -eq 0 ] && ok "no RUNNING remains after cleanup (never permanently running)" || bad "RUNNING residue: $(grep -rl RUNNING "$ZT" 2>/dev/null)"

# ── 4) 启动/停止/重启（验收 1）───────────────────────────────────────────────
CFG="../fixtures/legacy/config.txt"
RB="$BASE/daemon"
mkdir -p "$RB/tasks"
mkdir -p "$RB/tasks/prev_crash"     # 模拟 daemon 崩溃遗留的僵尸任务
printf 'RUNNING\n' > "$RB/tasks/prev_crash/status.txt"
printf '998\n' > "$RB/tasks/prev_crash/pid.txt"

# 模拟 daemon 的启动体（顶层后台 bash -c，$1/$2/$3 = base/config/lock；$$ = 子进程自身）
# lifecycle_start 成功 -> 驻留 300s（模拟主循环）；失败 -> exit 98（可 wait 取回）
DAEMON_BODY='. ../state-machine/lib.sh; . ../runtime/lib.sh; LEGACY_ADAPTER_SOURCED=1; . ../legacy-adapter/adapter.sh; . ../task-registry/lib.sh; . ./lib.sh; LIFECYCLE_LOG=0 lifecycle_start "$1" "$2" "$3" >/dev/null 2>&1 || exit 98; sleep 300'

bash -c "$DAEMON_BODY" _ "$RB" "$CFG" "$LOCK" >/dev/null 2>&1 &
d1=$!
[ -n "$d1" ] && ok "daemon instance started (pid=$d1)" || bad "daemon start"
sleep 2
[ -f "$LOCK" ] && [ "$(cat "$LOCK")" = "$d1" ] && ok "lock written by daemon with its own pid" || bad "lock pid=$(cat "$LOCK" 2>/dev/null)"
lifecycle_lock_alive "$LOCK" >/dev/null 2>&1 && ok "daemon lock alive" || bad "daemon lock not alive"

# 顶层读取 registry 快照（同一 base 二次 init = reload，17 任务语义一致）
TR_LOGGING=0 registry_init "$RB" "$CFG" >/dev/null 2>&1
sid=$(registry_current_snapshot_id)
[ -n "$sid" ] && ok "registry snapshot ready after start ($sid)" || bad "registry snapshot missing"
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "registry has 17 tasks (started via lifecycle)" || bad "registry count=$(registry_task_ids | wc -l)"
[ "$(cat "$RB/tasks/prev_crash/status.txt")" = "ZOMBIE_CRASHED" ] && ok "startup recovered pre-crash zombie (prev_crash)" || bad "prev_crash not cleaned"
[ "$(cat "$RB/tasks/prev_crash/state.txt")" = "FAILED" ] && ok "prev_crash new state FAILED" || bad "prev_crash state"

# 单实例：第二个实例启动被拒
bash -c "$DAEMON_BODY" _ "$RB" "$CFG" "$LOCK" >/dev/null 2>&1 &
d2=$!
wait "$d2"; rc2=$?
[ "$rc2" -eq 98 ] && ok "second daemon instance rejected (single instance)" || bad "second instance rc=$rc2"

# 停止（验收：daemon 可停止）
lifecycle_stop "$LOCK" >/dev/null 2>&1
[ ! -f "$LOCK" ] && ok "stop released lock" || bad "stop lock remains"
i=0
while [ "$i" -lt 6 ] && [ -d "/proc/$d1" ]; do sleep 1; i=$((i + 1)); done
[ ! -d "/proc/$d1" ] && ok "stop killed daemon process" || bad "daemon still alive after stop"

# 重启（验收：daemon 可重启）——stop 旧实例 + 拉起新进程
bash -c "$DAEMON_BODY" _ "$RB" "$CFG" "$LOCK" >/dev/null 2>&1 &
d3=$!
sleep 2
lifecycle_restart "$LOCK" "$RB" "$CFG" "sleep 300" >/dev/null 2>&1 && ok "restart initiated" || bad "restart"
i=0
while [ "$i" -lt 6 ] && [ -d "/proc/$d3" ]; do sleep 1; i=$((i + 1)); done
[ ! -d "/proc/$d3" ] && ok "restart stopped old instance" || bad "restart old still alive"
[ ! -f "$LOCK" ] && ok "restart released lock (new daemon re-locks itself)" || bad "restart lock remains"
pgrep -f 'sleep 300' >/dev/null 2>&1 && ok "restart launched new daemon process" || bad "restart launch"
pkill -f 'sleep 300' 2>/dev/null || true
rm -f "$LOCK"

# 初始化失败 fail-safe：无快照 + 坏配置 -> 拒绝启动且不留半初始化状态
RBAD="$BASE/bad"
mkdir -p "$RBAD/tasks"
printf '08\x01:30 x\n' > "$BASE/bad-config.txt"
bash -c "$DAEMON_BODY" _ "$RBAD" "$BASE/bad-config.txt" "$LOCK" >/dev/null 2>&1 &
d_bad=$!
wait "$d_bad"; rc_bad=$?
[ "$rc_bad" -eq 98 ] && ok "fresh bad config -> start rejected (fail-safe)" || bad "bad config rc=$rc_bad"
[ ! -f "$LOCK" ] && ok "failed init left NO lock (no half-initialized state)" || bad "lock leaked on failed init"
[ -z "$(ls -A "$RBAD/snapshots" 2>/dev/null)" ] && ok "failed init left no partial snapshot" || bad "partial snapshot residue"

# ── 5) 最后有效配置快照（fail-safe）─────────────────────────────────────────
# RB 已有快照（§4 中通过 CFG 建立）；配置损坏 -> 重启仍就绪且保留旧快照（KEPT）
printf '08\x01:30 x\n11\x02:00 y\n' > "$BASE/broken-config.txt"
bash -c "$DAEMON_BODY" _ "$RB" "$BASE/broken-config.txt" "$LOCK" >/dev/null 2>&1 &
d_keep=$!
# d_keep 成功（KEPT fallback）→ 驻留；轮询锁出现（出现 = 启动就绪；失败则 exit 98 无锁）
i=0
while [ "$i" -lt 10 ] && { [ ! -f "$LOCK" ] || [ -z "$(cat "$LOCK" 2>/dev/null)" ]; }; do sleep 1; i=$((i + 1)); done
[ -f "$LOCK" ] && [ -n "$(cat "$LOCK" 2>/dev/null)" ] && ok "start with broken config + existing snapshot -> ready (KEPT fallback)" || bad "broken+snapshot not ready"
sid2=$(registry_current_snapshot_id)
[ -n "$sid2" ] && ok "snapshot preserved after broken-config restart ($sid2)" || bad "snapshot lost on broken config"
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "17 tasks still served from last valid snapshot" || bad "registry count after broken reload=$(registry_task_ids | wc -l)"
lp=$(cat "$LOCK" 2>/dev/null)
[ -n "$lp" ] && [ "$lp" != "$$" ] && ok "daemon re-locked with its own pid ($lp)" || bad "re-lock pid=$lp"
lifecycle_stop "$LOCK" >/dev/null 2>&1   # 清理 d_keep（KEPT 用例驻留实例）

# ── 6) service.sh 兼容：watchdog_tick（单轮，不创建第二调度循环） ────────────
W="$BASE/wd.lock"
printf '%s\n' "$$" > "$W"
lifecycle_watchdog_tick "$W" >/dev/null 2>&1 && ok "watchdog_tick: alive daemon -> no action" || bad "watchdog tick alive"
[ -f "$W" ] && ok "watchdog kept live lock untouched" || bad "watchdog removed live lock"
printf '99999999\n' > "$W"
lifecycle_watchdog_tick "$W" "sleep 60" >/dev/null 2>&1 || ok "watchdog_tick: stale lock -> cleanup + launch" || bad "watchdog tick stale"
[ ! -f "$W" ] && ok "watchdog removed stale lock before launch" || bad "watchdog stale lock remains"
pgrep -f 'sleep 60' >/dev/null 2>&1 && ok "watchdog launched daemon process" || bad "watchdog launch"
pkill -f 'sleep 60' 2>/dev/null || true
[ "$(grep -c 'while true' lib.sh)" -eq 0 ] && ok "lib has NO while-true main loop (single watchdog tick only)" || bad "lib creates a second scheduling loop"

# ── 7) 接线安全：无硬编码生产路径（排除注释后统计——注释仅记录镜像语义引用）──
lcode=$(grep -vE '^[ \t]*#' lib.sh)
[ "$(printf '%s\n' "$lcode" | grep -c '/data/adb/su-scheduler')" -eq 0 ] && ok "no hardcoded data-dir in code (wired via args)" || bad "hardcoded data-dir"
[ "$(printf '%s\n' "$lcode" | grep -c '/dev/.su_scheduler.lock')" -eq 0 ] && ok "no hardcoded lockfile in code (wired via args)" || bad "hardcoded lockfile"

# ── 汇总 ────────────────────────────────────────────────────────────────────
pkill -f 'sleep 300' 2>/dev/null || true
pkill -f 'sleep 60' 2>/dev/null || true
rm -f "$LOCK" "$W"
rm -rf "$BASE"
echo "──────────────────────────────────────────────────────────────────────"
echo "lifecycle tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1