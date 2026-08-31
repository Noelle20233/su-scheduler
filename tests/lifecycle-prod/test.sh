#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — daemon 生命周期接入（P2-09）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-09 出口：重启/stop/restart/stale lock/看护 经真实链路验证）：
#   1) 入口：lib §14 lifecycle_startup_registry / lifecycle_startup_recover 各恰
#      1 次定义；daemon 接线锚点（lifecycle_startup_registry + runtime_scan_stale
#      + state_rehydrate_residual + RUNTIME_LOADED 门控）。
#   2) Registry 引导 + 最后有效快照：有效 config → 就绪；config 缺失（历史快照
#      在）→ attach 最后有效快照（不重扫配置）；无效 config → KEPT 保留最后有效。
#   3) 恢复序列（lifecycle_startup_recover）：stale PID（已死）→ state.txt=FAILED
#      + daemon_restart 事件；legacy status=RUNNING（无 pid）→ 物化 FAILED；
#      存活 pid → 保持 RUNNING；已完成目录不触碰；旧 status.txt 只读不动。
#   4) 真实链路（fake daemon 进程）：启动 → 锁存活 + 快照就绪 + 恢复执行；
#      lifecycle_stop → 进程退出 + 锁释放；lifecycle_restart → 新进程 + 重新上锁；
#      stale lock（死 pid）→ lifecycle_lock_acquire 回收（不重复实现锁逻辑）。
#   5) 不创建第二个常驻循环：daemon `while true` 恰 1 处（主循环唯一）；
#      service.sh 既有 60 秒看护循环原样（sleep 60 + LOCK_FILE + su-schedulerd），
#      P2-09 零引用（service.sh 未被本任务接线/改动）。
#   6) POSIX：lib dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
DAEMON="system/bin/su-schedulerd"
SVC="service.sh"
T=$(mktemp -d)
LKF="$T/daemon.lock"
cleanup() {
    if [ -f "$LKF" ]; then
        lp=$(cat "$LKF" 2>/dev/null)
        [ -n "$lp" ] && kill "$lp" 2>/dev/null
    fi
    rm -rf "$T"
}
trap 'cleanup' EXIT

. ./$RTLIB

# ── 1) 入口唯一 + daemon 接线锚点 ──────────────────────────────────────────
n=$(grep -cE '^lifecycle_startup_(registry|recover)' "$RTLIB")
[ "$n" -eq 2 ] && ok "P2-09 entry: §14 lifecycle_startup_registry/recover defined (once each)" || bad "P2-09 entry: §14 defs count=$n (expect 2)"
grep -q 'lifecycle_startup_registry' "$DAEMON" && ok "P2-09 entry: daemon wires lifecycle_startup_registry (startup block)" || bad "P2-09 entry: startup_registry missing in daemon"
grep -q 'runtime_scan_stale' "$DAEMON" && ok "P2-09 entry: daemon wires runtime_scan_stale (stale PID recovery)" || bad "P2-09 entry: runtime_scan_stale missing in daemon"
n=$(grep -c 'state_rehydrate_residual' "$DAEMON")
[ "$n" -eq 1 ] && ok "P2-09 entry: state_rehydrate_residual retained (P2-07 wiring intact)" || bad "P2-09 entry: rehydrate count=$n"
n=$(grep -c 'RUNTIME_LOADED' "$DAEMON")
[ "$n" -ge 9 ] && ok "P2-09 entry: RUNTIME_LOADED gates intact" || bad "P2-09 entry: RUNTIME_LOADED count=$n"

# ── 2) Registry 引导 + 最后有效快照（KEPT / attach）────────────────────────
BASE="$T/base"
CFG="$T/config.txt"
cp tests/fixtures/legacy/config.txt "$CFG"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1
lifecycle_startup_registry "$BASE" "$CFG" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "P2-09 registry: valid config → snapshot ready (17 tasks)" || bad "P2-09 registry: valid config bootstrap failed"
# config 缺失 + 历史快照 → 挂载最后有效快照（模拟 shadow_init 失败后的回退）
BASE_M="$T/base_missing"
CFG_M="$T/config_missing.txt"
cp tests/fixtures/legacy/config.txt "$CFG_M"
TR_LOGGING=0 registry_init "$BASE_M" "$CFG_M" >/dev/null 2>&1
[ -n "$(registry_current_snapshot_id 2>/dev/null)" ] || { bad "P2-09 registry: pre-bootstrap snapshot missing"; exit 1; }
rm -f "$CFG_M"
TR_LOGGING=0 registry_init "$BASE_M" "$CFG_M" >/dev/null 2>&1   # 镜像 shadow_init：config 缺失 → 内存无快照
[ -z "${TASK_REGISTRY_SNAPSHOT:-}" ] && ok "P2-09 registry: config missing → no in-memory snapshot (mirror shadow_init failure)" || bad "P2-09 registry: memory snapshot unexpected"
lifecycle_startup_registry "$BASE_M" "$CFG_M" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "P2-09 registry: config missing → last valid snapshot served (disk current kept, no rescan)" || bad "P2-09 registry: last-valid bootstrap failed"
# 无效 config → KEPT 保留最后有效
BASE_K="$T/base_keep"
CFG_K="$T/config_keep.txt"
cp tests/fixtures/legacy/config.txt "$CFG_K"
TR_LOGGING=0 registry_init "$BASE_K" "$CFG_K" >/dev/null 2>&1
printf '08\x01:30 x\n' > "$CFG_K"
TR_LOGGING=0 registry_init "$BASE_K" "$CFG_K" >/dev/null 2>&1
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "P2-09 registry: invalid config → KEPT keeps last valid snapshot (17 tasks)" || bad "P2-09 registry: KEPT failed (ids=$(registry_task_ids | wc -l))"

# ── 3) 恢复序列（lifecycle_startup_recover）────────────────────────────────
RZ="$T/recover"
mkdir -p "$RZ"
mkdir -p "$RZ/stale_a" "$RZ/legacy_b" "$RZ/alive_c" "$RZ/done_d"
echo "RUNNING" > "$RZ/stale_a/state.txt"
echo "RUNNING" > "$RZ/stale_a/status.txt"
echo "99999999" > "$RZ/stale_a/pid.txt"
echo "RUNNING" > "$RZ/legacy_b/status.txt"          # 无 state.txt / 无 pid.txt
echo "RUNNING" > "$RZ/alive_c/state.txt"
echo "$$" > "$RZ/alive_c/pid.txt"                    # 存活 pid；无 status.txt（rehydrate 跳过）
echo "SUCCESS" > "$RZ/done_d/status.txt"
echo "0" > "$RZ/done_d/exit_code.txt"
cp "$RZ/stale_a/status.txt" "$T/stale_a.status.before"
lifecycle_startup_recover "$RZ" >/dev/null 2>&1
[ "$(cat "$RZ/stale_a/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-09 recover: stale PID → state.txt=FAILED" || bad "P2-09 recover: stale_a state=$(cat "$RZ/stale_a/state.txt" 2>/dev/null)"
tail -1 "$RZ/stale_a/events.log" 2>/dev/null | grep -q '|daemon_restart|FAILED|' && ok "P2-09 recover: stale_a events.log daemon_restart→FAILED" || bad "P2-09 recover: stale_a event missing"
cmp -s "$RZ/stale_a/status.txt" "$T/stale_a.status.before" && ok "P2-09 recover: stale_a legacy status.txt untouched" || bad "P2-09 recover: legacy status modified"
[ "$(cat "$RZ/legacy_b/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-09 recover: legacy RUNNING (no pid) → FAILED materialized" || bad "P2-09 recover: legacy_b state=$(cat "$RZ/legacy_b/state.txt" 2>/dev/null)"
[ "$(cat "$RZ/alive_c/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-09 recover: alive PID kept RUNNING (no false recovery)" || bad "P2-09 recover: alive_c state=$(cat "$RZ/alive_c/state.txt" 2>/dev/null)"
[ -f "$RZ/done_d/state.txt" ] && bad "P2-09 recover: completed dir touched" || ok "P2-09 recover: completed dir untouched"

# ── 4) 真实链路：fake daemon 启动/stop/restart/stale lock ──────────────────
FAKE="$T/fake-daemon.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# 模拟 daemon 启动链：加载 lib（路径经 $2 传入，保持路径隔离门禁语义）→
# Registry 引导 → 恢复序列 → 写锁 → 常驻
set -u
cd "$1" || { echo "fake: cd fail" >&2; exit 2; }
. ./"$2" || { echo "fake: lib fail" >&2; exit 2; }
base="$3"; config="$4"; tasks="$5"; lock="$6"
echo "fake: start (base=$base)" >&2
lifecycle_startup_registry "$base" "$config" || { echo "fake: registry rc=$?" >&2; exit 2; }
echo "fake: registry ok" >&2
lifecycle_startup_recover "$tasks" || { echo "fake: recover rc=$?" >&2; exit 2; }
echo "$$" > "$lock"
echo "fake: lock written" >&2
sleep 30 &
wait $!
EOF
chmod +x "$FAKE"
FDBASE="$T/chain/base"
FDCFG="$T/chain/config.txt"
FDTASKS="$T/chain/tasks"
mkdir -p "$FDTASKS"
cp tests/fixtures/legacy/config.txt "$FDCFG"
mkdir -p "$FDTASKS/prev_run"
echo "RUNNING" > "$FDTASKS/prev_run/status.txt"
LIFECYCLE_LOG=0 bash "$FAKE" "$PWD" "$RTLIB" "$FDBASE" "$FDCFG" "$FDTASKS" "$LKF" >"$T/fake.log" 2>&1 &
sleep 2
[ -f "$LKF" ] && [ -d "/proc/$(cat "$LKF" 2>/dev/null)" ] && ok "P2-09 chain: fake daemon started → lock alive (pid=$(cat "$LKF" 2>/dev/null))" || bad "P2-09 chain: lock not alive"
[ -f "$FDBASE/current" ] && ok "P2-09 chain: registry snapshot built at startup" || bad "P2-09 chain: no snapshot"
[ "$(cat "$FDTASKS/prev_run/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-09 chain: recovery ran in startup sequence (prev_run → FAILED)" || bad "P2-09 chain: recovery not executed"
OLDPID=$(cat "$LKF" 2>/dev/null)
LIFECYCLE_LOG=0 lifecycle_stop "$LKF" >/dev/null 2>&1
i=0
while [ "$i" -lt 10 ] && [ -d "/proc/$OLDPID" ]; do sleep 0.5; i=$((i + 1)); done
[ ! -d "/proc/$OLDPID" ] && ok "P2-09 chain: lifecycle_stop killed daemon" || bad "P2-09 chain: daemon still alive"
[ ! -f "$LKF" ] && ok "P2-09 chain: lock released after stop" || bad "P2-09 chain: lock not released"
LIFECYCLE_LOG=0 lifecycle_restart "$LKF" "$FDBASE" "$FDCFG" "bash $FAKE $PWD $RTLIB $FDBASE $FDCFG $FDTASKS $LKF" >/dev/null 2>&1
sleep 2
[ -f "$LKF" ] && [ -d "/proc/$(cat "$LKF" 2>/dev/null)" ] && ok "P2-09 chain: lifecycle_restart relaunched daemon (new pid=$(cat "$LKF" 2>/dev/null))" || bad "P2-09 chain: restart failed"
[ "$(cat "$LKF" 2>/dev/null)" != "$OLDPID" ] && ok "P2-09 chain: new daemon re-locked with fresh pid" || bad "P2-09 chain: same pid after restart"
kill "$(cat "$LKF" 2>/dev/null)" 2>/dev/null
rm -f "$LKF"
printf '99999999\n' > "$LKF"
LIFECYCLE_LOG=0 lifecycle_lock_acquire "$LKF" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(cat "$LKF" 2>/dev/null)" = "$$" ] && ok "P2-09 chain: stale lock reclaimed by lifecycle_lock_acquire (no duplicate lock logic)" || bad "P2-09 chain: stale lock not reclaimed"
rm -f "$LKF"

# ── 5) 不创建第二个常驻循环 + service.sh 既有 60 秒看护原样 ─────────────────
n=$(grep -c 'while true' "$DAEMON")
[ "$n" -eq 1 ] && ok "P2-09 loop: daemon has exactly ONE resident loop (while true)" || bad "P2-09 loop: while true count=$n (expect 1)"
grep -q 'sleep 60' "$SVC" && grep -q 'LOCK_FILE' "$SVC" && grep -q 'su-schedulerd' "$SVC" && ok "P2-09 service: service.sh keeps existing 60s watchdog loop (sleep 60 + lock check + daemon relaunch)" || bad "P2-09 service: watchdog missing/changed"
n=$(grep -c 'lifecycle' "$SVC")
[ "$n" -eq 0 ] && ok "P2-09 service: service.sh untouched by P2-09 (no lifecycle wiring; watchdog only wired after logic stable)" || bad "P2-09 service: service.sh references lifecycle (forbidden)"

# ── 6) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-09 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §14)" || bad "P2-09 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-09 POSIX: bash -n ok (dash unavailable)" || bad "P2-09 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "lifecycle-prod tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1