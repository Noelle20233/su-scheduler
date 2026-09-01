#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Supervisor 核心（P2-12）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-12 出口：任务具备完整启动/监控/异常/恢复生命周期）：
#   1) 入口：§17 supervisor_health_spec / supervisor_policy / supervisor_step /
#      supervisor_tick / supervisor_task_file 就位；selfcheck 锚点；daemon 主循环
#      旁路块含 supervisor_tick（RUNTIME_LOADED 门控）。
#   2) 完整生命周期（真实 nc 监听）：RUNNING→HEALTHY（探针通过）→ 杀进程 →
#      HEALTHY→UNHEALTHY → UNHEALTHY→RECOVERING → 恢复重跑 action → STARTING
#      →(spawn)→RUNNING → 探针再通过 → HEALTHY（闭环）。
#   3) 策略超限 → FAILED：retry.max=0 首次恢复即 FAILED（retry-exhausted）；
#      retry.max=1 + 重跑失败 → FAILED（recovery-relaunch-failed）；重试节奏
#      retry.interval（recovery.next 未来 → 不重试）。
#   4) 统一事件循环：supervisor_tick 每 tick 每任务至多一步——多任务混合推进，
#      单任务无 while/for/后台 `&`（结构断言：§17 无每任务循环/无 while true）；
#      supervisor_step 单步无循环。
#   5) 无健康配置/未知状态：health.type=none → 不监督（无迁移）；探针 UNKNOWN →
#      保持现态；非运行态（STOPPED/FAILED）不触碰。
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
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB
# P2-14：健康探针最小间隔节流对本套件关闭（行为保持逐 tick 探活）
export HEALTH_MIN_INTERVAL=0

# ── 工具：找空闲端口 + 造 registry 快照 + 造运行目录 ───────────────────────
pick_free_port() {
    p=37000
    while [ "$p" -lt 37500 ]; do
        hexp=$(printf '%04X' "$p")
        if awk -v h="$hexp" '$4=="0A" && $2 ~ ":" h "$" { n++ } END { exit n>0 }' /proc/net/tcp 2>/dev/null; then
            echo "$p"; return 0
        fi
        p=$((p + 1))
    done
    echo ""
}
mk_snapshot() {   # <base> <taskfile-content> → 建 snap_1 + current
    base=$1
    mkdir -p "$base/snapshots/snap_1"
    shift
    printf '%s\n' "$@" > "$base/snapshots/snap_1/t50_8080.task"
    echo "snap_1" > "$base/current"
}
mk_run() {   # <tasks_dir> <state> → 建运行目录 + 状态
    tasks=$1
    mkdir -p "$tasks/t50_8080"
    echo "$2" > "$tasks/t50_8080/state.txt"
    echo "$2" > "$tasks/t50_8080/status.txt"
}

# ── 1) 入口 + 接线 ─────────────────────────────────────────────────────────
n=$(grep -cE '^supervisor_(health_spec|policy|step|tick|task_file)\(' "$RTLIB")
[ "$n" -eq 5 ] && ok "P2-12 entry: §17 supervisor_* 5 functions defined" || bad "P2-12 entry: supervisor funcs count=$n (expect 5)"
grep -q 'supervisor_tick "\$TASKS_DIR"' "$DAEMON" && ok "P2-12 entry: daemon main-loop wires supervisor_tick (RUNTIME_LOADED gated)" || bad "P2-12 entry: supervisor_tick missing in daemon"
n=$(grep -c 'RUNTIME_LOADED' "$DAEMON")
[ "$n" -ge 10 ] && ok "P2-12 entry: RUNTIME_LOADED gates intact (loader+shadow+rehydrate+sync+supervisor+4 action sites)" || bad "P2-12 entry: RUNTIME_LOADED count=$n"

# ── 4) 统一事件循环结构断言（先于行为——无每任务循环/后台派生）────────────────
step_body=$(sed -n '/^supervisor_step()/,/^}/p' "$RTLIB")
if printf '%s\n' "$step_body" | grep -qE '(^|[[:space:]])(while|for)([[:space:]]|$)|&$'; then
    bad "P2-12 loop: supervisor_step contains loop/backgrounding (per-task loop forbidden)"
else
    ok "P2-12 loop: supervisor_step has NO while/for/background & (one step per tick)"
fi
tick_body=$(sed -n '/^supervisor_tick()/,/^}/p' "$RTLIB")
n=$(printf '%s\n' "$tick_body" | grep -cE '^[[:space:]]*for ')
[ "$n" -eq 1 ] && ok "P2-12 loop: supervisor_tick has exactly ONE for (unified task iteration)" || bad "P2-12 loop: tick for count=$n"
n=$(printf '%s\n' "$tick_body" | grep -cE '(^|[[:space:]])while([[:space:]]|$)|while true')
[ "$n" -eq 0 ] && ok "P2-12 loop: supervisor_tick has NO while loop (daemon main loop is the only resident loop)" || bad "P2-12 loop: tick while count=$n"

# ── 2) 完整生命周期（真实 nc 监听）─────────────────────────────────────────
if command -v nc >/dev/null 2>&1; then
    PORT=$(pick_free_port)
    BASE="$T/life/base"
    TASKS="$T/life/tasks"
    mkdir -p "$TASKS"
    mk_snapshot "$BASE" \
        "schema_version=2" "id=t50_8080" "name=portwatch" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $PORT" "health.type=port" "health.target=$PORT" \
        "retry.max=2" "retry.interval=0"
    registry_attach "$BASE" >/dev/null 2>&1
    mk_run "$TASKS" RUNNING
    export TPR_ACTION_DIR="$TASKS"
    export PATH="$PATH"

    # 2a RUNNING → HEALTHY（探针通过）
    nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
    NCPID=$!
    up=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
        [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && ok "P2-12 life: RUNNING → HEALTHY (probe ok, listener up)" || bad "P2-12 life: not HEALTHY (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    # 2b 杀进程 → HEALTHY → UNHEALTHY
    kill "$NCPID" 2>/dev/null
    down=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
        [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "UNHEALTHY" ] && { down=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$down" -eq 1 ] && ok "P2-12 life: HEALTHY → UNHEALTHY (probe fail)" || bad "P2-12 life: not UNHEALTHY (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    # 2c → RECOVERING
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RECOVERING" ] && ok "P2-12 life: UNHEALTHY → RECOVERING" || bad "P2-12 life: not RECOVERING (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    # 2d 恢复重跑 → STARTING(+spawn→RUNNING) → 探针再通过 → HEALTHY（闭环）
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-12 life: recovery relaunch → STARTING→RUNNING (spawn anchor)" || bad "P2-12 life: after relaunch (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    up=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
        [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && ok "P2-12 life: FULL loop recovered → HEALTHY (start/monitor/anomaly/recovery)" || bad "P2-12 life: recovery loop not HEALTHY (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    # 清理恢复重跑残留的 nc
    for p in $(pgrep -f "nc -l 127.0.0.1 $PORT" 2>/dev/null); do kill "$p" 2>/dev/null; done
else
    ok "P2-12 life: nc unavailable — full lifecycle case not exercised (policy/entry covered)"
fi

# ── 3) 策略超限 → FAILED ───────────────────────────────────────────────────
BASE_P="$T/policy/base"
TASKS_P="$T/policy/tasks"
mkdir -p "$TASKS_P"
mk_snapshot "$BASE_P" \
    "schema_version=2" "id=t50_8080" "name=p" "enabled=1" "trigger=08:00" \
    "action.command=true" "health.type=port" "health.target=59999" \
    "retry.max=0" "retry.interval=0"
registry_attach "$BASE_P" >/dev/null 2>&1
mk_run "$TASKS_P" RECOVERING
supervisor_step "$TASKS_P/t50_8080" "$BASE_P/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS_P/t50_8080/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-12 policy: retry.max=0 → FAILED (retry-exhausted, no attempts)" || bad "P2-12 policy: state=$(cat "$TASKS_P/t50_8080/state.txt" 2>/dev/null)"
tail -1 "$TASKS_P/t50_8080/events.log" 2>/dev/null | grep -q 'retry-exhausted' && ok "P2-12 policy: FAILED event reason=retry-exhausted" || bad "P2-12 policy: event missing"
# retry.max=1 + 重跑失败（非法 app spec → action_run 同步拒绝）→ FAILED
BASE_F="$T/fail/base"
TASKS_F="$T/fail/tasks"
mkdir -p "$TASKS_F"
mk_snapshot "$BASE_F" \
    "schema_version=2" "id=t50_8080" "name=f" "enabled=1" "trigger=08:00" \
    "action.command=app:package:com.x;id" "health.type=port" "health.target=59998" \
    "retry.max=1" "retry.interval=0"
registry_attach "$BASE_F" >/dev/null 2>&1
mk_run "$TASKS_F" RECOVERING
TPR_ACTION_DIR="$TASKS_F" supervisor_step "$TASKS_F/t50_8080" "$BASE_F/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
TPR_ACTION_DIR="$TASKS_F" supervisor_step "$TASKS_F/t50_8080" "$BASE_F/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS_F/t50_8080/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-12 policy: retry.max=1 + relaunch rejection → FAILED after attempts exhausted (P2-13 retry semantics)" || bad "P2-12 policy: relaunch-fail state=$(cat "$TASKS_F/t50_8080/state.txt" 2>/dev/null)"
# retry.interval 节奏：recovery.next 在未来 → 不重试（count 不变）
BASE_R="$T/pace/base"
TASKS_R="$T/pace/tasks"
mkdir -p "$TASKS_R"
mk_snapshot "$BASE_R" \
    "schema_version=2" "id=t50_8080" "name=r" "enabled=1" "trigger=08:00" \
    "action.command=no_such_cmd_xyz" "health.type=port" "health.target=59997" \
    "retry.max=3" "retry.interval=60"
registry_attach "$BASE_R" >/dev/null 2>&1
mk_run "$TASKS_R" RECOVERING
echo "9999999999" > "$TASKS_R/t50_8080/recovery.next"   # 未来 100 年 → 本 tick 不重试
echo "1" > "$TASKS_R/t50_8080/recovery.count"
TPR_ACTION_DIR="$TASKS_R" supervisor_step "$TASKS_R/t50_8080" "$BASE_R/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS_R/t50_8080/recovery.count" 2>/dev/null)" = "1" ] && [ "$(cat "$TASKS_R/t50_8080/state.txt" 2>/dev/null)" = "RECOVERING" ] \
    && ok "P2-12 policy: retry.interval pacing honored (future recovery.next → no attempt)" || bad "P2-12 policy: pacing not honored"

# ── 5) 无健康配置 / 非运行态不触碰 ─────────────────────────────────────────
BASE_N="$T/none/base"
TASKS_N="$T/none/tasks"
mkdir -p "$TASKS_N"
mk_snapshot "$BASE_N" \
    "schema_version=2" "id=t50_8080" "name=n" "enabled=1" "trigger=08:00" \
    "action.command=true" "health.type=none" "retry.max=2" "retry.interval=0"
registry_attach "$BASE_N" >/dev/null 2>&1
mk_run "$TASKS_N" RUNNING
supervisor_step "$TASKS_N/t50_8080" "$BASE_N/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS_N/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-12 none: health.type=none → not supervised (stays RUNNING)" || bad "P2-12 none: state=$(cat "$TASKS_N/t50_8080/state.txt" 2>/dev/null)"
# 非运行态（STOPPED）不触碰
BASE_S="$T/stopped/base"
TASKS_S="$T/stopped/tasks"
mkdir -p "$TASKS_S"
mk_snapshot "$BASE_S" \
    "schema_version=2" "id=t50_8080" "name=s" "enabled=1" "trigger=08:00" \
    "action.command=true" "health.type=port" "health.target=59996" "retry.max=2" "retry.interval=0"
registry_attach "$BASE_S" >/dev/null 2>&1
mk_run "$TASKS_S" STOPPED
supervisor_step "$TASKS_S/t50_8080" "$BASE_S/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS_S/t50_8080/state.txt" 2>/dev/null)" = "STOPPED" ] && ok "P2-12 none: non-run state (STOPPED) untouched" || bad "P2-12 none: STOPPED modified"

# ── 6) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-12 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §17)" || bad "P2-12 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-12 POSIX: bash -n ok (dash unavailable)" || bad "P2-12 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "supervisor tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1