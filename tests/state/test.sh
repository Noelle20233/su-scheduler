#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — 统一状态与事件日志接入（P2-07）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-07 出口：状态机成为生产事实源；旧 CLI 仍可读取旧状态）：
#   1) 入口唯一：lib §12 state_log_event / state_health_allowed /
#      state_sync_one / state_sync_all / state_rehydrate_residual 各恰定义 1 次；
#      action_run 集成锚点（spawn → state.txt=RUNNING + events.log）存在。
#   2) 双写：state.txt（新）+ events.log（7 字段）与旧兼容工件并存——sync 后
#      status.txt/pid.txt/output.log/exit_code.txt 逐字节不变（旧 CLI 可读）。
#   3) 一次性任务成功 → STOPPED（不虚假 HEALTHY）：exit=0 → state.txt=STOPPED
#      + action_success 事件；直接写 HEALTHY 被拒（仅 builtin 时）。
#   4) Health 门槛：仅 builtin → state_health_allowed=1 + HEALTHY/UNHEALTHY
#      拒绝；注册真实 Health Provider → allowed + HEALTHY 可写（RUNNING→
#      HEALTHY 迁移合法）。
#   5) 非法状态转换非致命：FAILED→STOPPED 直写被拒（state.txt/events.log 不变，
#      返回 1 不中止）；混入 BOGUS 目录的 state_sync_all 仍完成其余目录。
#   6) 重启残留：status.txt=RUNNING/STARTING（无新源）与 ZOMBIE_CRASHED →
#      state.txt=FAILED + daemon_restart 事件；旧 status.txt 不动；已完成目录
#      不触碰。
#   7) 旧 CLI 兼容 + 新源优先：sync 后 runtime_current_state 从新源返回 STOPPED，
#      旧工件逐字节不变（可直接被旧 task-status/task-output 读取）。
#   8) 接线 + POSIX：daemon 含 state_rehydrate_residual/state_sync_all 门控旁路
#      与 RUNTIME_LOADED 门控；lib dash -n。
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
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

# ── 1) 入口唯一 + 集成锚点 ─────────────────────────────────────────────────
n=$(grep -cE '^state_(log_event|health_allowed|sync_one|sync_all|rehydrate_residual)' "$RTLIB")
[ "$n" -eq 5 ] && ok "P2-07 entry: 5 §12 functions each defined exactly once" || bad "P2-07 entry: §12 defs count=$n (expect 5)"
n=$(grep -c 'state_log_event "\$run_dir" "\$id" spawn RUNNING' "$RTLIB")
[ "$n" -ge 1 ] && ok "P2-07 entry: action_run spawn anchor wired (command + app paths, P2-10)" || bad "P2-07 entry: spawn anchor count=$n"

# ── 2) 双写：新源与旧兼容工件并存（sync 后旧工件逐字节不变）─────────────────
D="$T/dual/run_t100_0000"
mkdir -p "$D"
echo "echo legacy" > "$D/command.txt"
echo "SUCCESS" > "$D/status.txt"
echo "12345" > "$D/pid.txt"
echo "legacy output" > "$D/output.log"
echo "0" > "$D/exit_code.txt"
for a in status.txt pid.txt output.log exit_code.txt; do cp "$D/$a" "$T/$a.before"; done
state_sync_all "$T/dual" >/dev/null 2>&1
[ "$(cat "$D/state.txt" 2>/dev/null)" = "STOPPED" ] && ok "P2-07 dual: sync → state.txt=STOPPED (new source)" || bad "P2-07 dual: state=$(cat "$D/state.txt" 2>/dev/null)"
tail -1 "$D/events.log" 2>/dev/null | grep -q '|action_success|STOPPED|' && ok "P2-07 dual: events.log action_success→STOPPED (7-field line)" || bad "P2-07 dual: events.log tail=$(tail -1 "$D/events.log" 2>/dev/null)"
legacy_intact=0
for a in status.txt pid.txt output.log exit_code.txt; do
    cmp -s "$D/$a" "$T/$a.before" || { legacy_intact=1; bad "P2-07 dual: legacy artifact changed: $a"; }
done
[ "$legacy_intact" -eq 0 ] && ok "P2-07 dual: legacy artifacts byte-identical after sync (old CLI readable)" || true

# ── 3) 一次性任务成功 → STOPPED，不虚假 HEALTHY ─────────────────────────────
[ "$(cat "$D/state.txt" 2>/dev/null)" = "STOPPED" ] && ok "P2-07 oneshot: success → STOPPED (not HEALTHY)" || bad "P2-07 oneshot: state=$(cat "$D/state.txt" 2>/dev/null)"
ev_before=$(wc -l < "$D/events.log" 2>/dev/null || echo 0)
state_log_event "$D" run_t100_0000 action_success HEALTHY >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "P2-07 oneshot: direct HEALTHY write rejected (builtin-only health)" || bad "P2-07 oneshot: HEALTHY accepted (forbidden)"
[ "$(cat "$D/state.txt" 2>/dev/null)" = "STOPPED" ] && ok "P2-07 oneshot: state.txt unchanged after HEALTHY rejection" || bad "P2-07 oneshot: state polluted=$(cat "$D/state.txt" 2>/dev/null)"
[ "$(wc -l < "$D/events.log" 2>/dev/null || echo 0)" -eq "$ev_before" ] && ok "P2-07 oneshot: events.log unchanged after HEALTHY rejection" || bad "P2-07 oneshot: events polluted"

# ── 4) Health 门槛：只有真实 Health Provider 接入才允许 HEALTHY ────────────
state_health_allowed >/dev/null 2>&1
[ $? -ne 0 ] && ok "P2-07 health: health_allowed=1 with builtin-only (gated)" || bad "P2-07 health: allowed with builtin-only (forbidden)"
state_log_event "$D" run_t100_0000 supervisor UNHEALTHY >/dev/null 2>&1
[ $? -ne 0 ] && ok "P2-07 health: UNHEALTHY also gated (health family)" || bad "P2-07 health: UNHEALTHY accepted (forbidden)"
D2="$T/health/run_t101_0001"
mkdir -p "$D2"
echo "RUNNING" > "$D2/state.txt"
echo "RUNNING" > "$D2/status.txt"
provider_register health real tpr_health_real >/dev/null 2>&1
state_health_allowed >/dev/null 2>&1
[ $? -eq 0 ] && ok "P2-07 health: real health provider registered → allowed" || bad "P2-07 health: still gated after real registration"
state_log_event "$D2" run_t101_0001 supervisor HEALTHY >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(cat "$D2/state.txt" 2>/dev/null)" = "HEALTHY" ] && ok "P2-07 health: HEALTHY writable after real provider (RUNNING→HEALTHY legal)" || bad "P2-07 health: HEALTHY write failed (state=$(cat "$D2/state.txt" 2>/dev/null))"

# ── 5) 非法状态转换非致命（不破主循环）─────────────────────────────────────
D3="$T/illegal/run_t102_0002"
mkdir -p "$D3"
echo "FAILED" > "$D3/state.txt"
echo "FAILED" > "$D3/status.txt"
echo "1" > "$D3/exit_code.txt"
ev_before=0
[ -f "$D3/events.log" ] && ev_before=$(wc -l < "$D3/events.log")
state_log_event "$D3" run_t102_0002 action_success STOPPED >/dev/null 2>&1
[ $? -ne 0 ] && ok "P2-07 illegal: FAILED→STOPPED direct write rejected (TSM edge)" || bad "P2-07 illegal: FAILED→STOPPED accepted"
[ "$(cat "$D3/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-07 illegal: state.txt unchanged after illegal transition" || bad "P2-07 illegal: state=$(cat "$D3/state.txt" 2>/dev/null)"
ev_after=0
[ -f "$D3/events.log" ] && ev_after=$(wc -l < "$D3/events.log")
[ "$ev_after" -eq "$ev_before" ] && ok "P2-07 illegal: events.log unchanged after illegal transition" || bad "P2-07 illegal: events polluted"
# 混入 BOGUS 目录：sync_all 仍处理其余目录，不中止
MIX="$T/mixed"
mkdir -p "$MIX"
for mk in a b c; do mkdir -p "$MIX/$mk"; done
echo "RUNNING" > "$MIX/a/state.txt"; echo "0" > "$MIX/a/exit_code.txt"; echo "SUCCESS" > "$MIX/a/status.txt"
echo "BOGUS"  > "$MIX/b/state.txt";  echo "0" > "$MIX/b/exit_code.txt"
echo "RUNNING" > "$MIX/c/state.txt"; echo "7" > "$MIX/c/exit_code.txt"; echo "FAILED" > "$MIX/c/status.txt"
state_sync_all "$MIX" >/dev/null 2>&1
sync_rc=$?
[ "$sync_rc" -le 1 ] && ok "P2-07 illegal: state_sync_all completed despite BOGUS dir (rc=$sync_rc)" || bad "P2-07 illegal: sync_all aborted rc=$sync_rc"
[ "$(cat "$MIX/a/state.txt" 2>/dev/null)" = "STOPPED" ] && ok "P2-07 illegal: valid dir a → STOPPED (processed after bogus)" || bad "P2-07 illegal: dir a state=$(cat "$MIX/a/state.txt" 2>/dev/null)"
[ "$(cat "$MIX/b/state.txt" 2>/dev/null)" = "BOGUS" ] && ok "P2-07 illegal: bogus dir untouched (BOGUS)" || bad "P2-07 illegal: bogus dir modified"
[ "$(cat "$MIX/c/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-07 illegal: valid dir c → FAILED (exit 7)" || bad "P2-07 illegal: dir c state=$(cat "$MIX/c/state.txt" 2>/dev/null)"

# ── 6) 重启残留再水合（新源 FAILED + daemon_restart 事件；旧工件不动）────────
RZ="$T/restart"
mkdir -p "$RZ"
mkdir -p "$RZ/a" "$RZ/b" "$RZ/c" "$RZ/done"
echo "RUNNING" > "$RZ/a/status.txt"
echo "STARTING" > "$RZ/b/status.txt"
echo "STARTING" > "$RZ/c/state.txt"; echo "STARTING" > "$RZ/c/status.txt"
echo "SUCCESS" > "$RZ/done/status.txt"; echo "0" > "$RZ/done/exit_code.txt"
cp "$RZ/a/status.txt" "$T/a.before"
state_rehydrate_residual "$RZ" >/dev/null 2>&1
[ "$(cat "$RZ/a/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-07 restart: legacy RUNNING (no state.txt) → FAILED + new source materialized" || bad "P2-07 restart: a state=$(cat "$RZ/a/state.txt" 2>/dev/null)"
tail -1 "$RZ/a/events.log" 2>/dev/null | grep -q '|daemon_restart|FAILED|' && ok "P2-07 restart: a events.log daemon_restart→FAILED" || bad "P2-07 restart: a events=$(tail -1 "$RZ/a/events.log" 2>/dev/null)"
cmp -s "$RZ/a/status.txt" "$T/a.before" && ok "P2-07 restart: a legacy status.txt unchanged (old CLI readable)" || bad "P2-07 restart: a status.txt modified"
[ "$(cat "$RZ/b/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-07 restart: legacy STARTING → FAILED" || bad "P2-07 restart: b state=$(cat "$RZ/b/state.txt" 2>/dev/null)"
[ "$(cat "$RZ/c/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-07 restart: new STARTING → FAILED (state-machine rehydrate)" || bad "P2-07 restart: c state=$(cat "$RZ/c/state.txt" 2>/dev/null)"
[ -f "$RZ/done/state.txt" ] && bad "P2-07 restart: completed dir touched by rehydrate" || ok "P2-07 restart: completed dir untouched"

# ── 7) 旧 CLI 兼容 + 新源优先（状态机成为事实源）────────────────────────────
[ "$(runtime_current_state "$D")" = "STOPPED" ] && ok "P2-07 truth: runtime_current_state = STOPPED from new source (state.txt wins)" || bad "P2-07 truth: current=$(runtime_current_state "$D")"
[ "$(cat "$D/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "P2-07 truth: legacy status.txt still SUCCESS (old CLI reads it as before)" || bad "P2-07 truth: legacy status corrupted"
for a in pid.txt output.log exit_code.txt; do
    [ -f "$D/$a" ] || { bad "P2-07 truth: legacy artifact missing $a"; legacy_miss=1; }
done
[ "${legacy_miss:-0}" = "1" ] || ok "P2-07 truth: pid/output/exit_code artifacts intact for old task-output/task-kill"

# ── 8) 接线 + POSIX ────────────────────────────────────────────────────────
n=$(grep -c 'state_rehydrate_residual' "$DAEMON")
[ "$n" -eq 1 ] && ok "P2-07 wiring: daemon startup rehydrate bypass (RUNTIME_LOADED gated)" || bad "P2-07 wiring: rehydrate count=$n"
n=$(grep -c 'state_sync_all' "$DAEMON")
[ "$n" -eq 1 ] && ok "P2-07 wiring: daemon main-loop sync bypass (RUNTIME_LOADED gated)" || bad "P2-07 wiring: sync count=$n"
n=$(grep -c 'RUNTIME_LOADED' "$DAEMON")
[ "$n" -ge 9 ] && ok "P2-07 wiring: RUNTIME_LOADED gates intact (loader+shadow+rehydrate+sync+4 action sites)" || bad "P2-07 wiring: RUNTIME_LOADED count=$n"
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-07 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §12)" || bad "P2-07 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-07 POSIX: bash -n ok (dash unavailable)" || bad "P2-07 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "state tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1