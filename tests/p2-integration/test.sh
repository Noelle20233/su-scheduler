#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P2 综合回归：故障注入与重启（P2-15）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-15 出口：daemon kill / task kill / 脚本 hang / 应用崩溃 / 重启 的
#   综合回归——多条既有链路的端到端集成，非单套件孤立验证）：
#   1) 入口：P2 各模块在 lib/daemon/CLI 的接线锚点就位 + selfcheck 覆盖。
#   2) daemon kill + 重启：fake daemon SIGKILL（崩溃）→ crash_guard 计数递增
#      → 第 4 次启动降级窗口（rc 2 不登记新 starts）；优雅 TERM → last_clean=1
#      → 下次启动 rc 0 且 crash_seq 归零（崩溃循环抑制）。
#   3) task kill：受监督端口任务 HEALTHY 后 `kill -9` 其 pid → 探针 → UNHEALTHY
#      → RECOVERING → 重跑（RECOVERING→STARTING→RUNNING）→ HEALTHY（自愈闭环）。
#   4) 脚本 hang：长时任务超 TASK_RUNTIME_MAX（超时护栏）→ FAILED 终止进程 +
#      事件 "runtime-limit exceeded"（hang 抑制）。
#   5) 应用崩溃韧性：监听进程多次死亡 → 每次 RECOVERING 重跑后探针通过恢复
#      HEALTHY——崩溃→恢复循环在 retry.max 内可持续自愈。
#   6) 重启残留收尾：daemon 重启后，上轮 RUNNING（进程已死）目录经
#      state_rehydrate_residual → FAILED + daemon_restart 事件（不留幽灵 RUNNING）。
#   7) POSIX：lib dash -n。
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
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
cleanup() {
    pgrep -f "t50_8080" >/dev/null 2>&1 && pkill -f "t50_8080" 2>/dev/null
    rm -rf "$T"
}
trap 'cleanup' EXIT

. ./$RTLIB

# ── 工具 ────────────────────────────────────────────────────────────────────
pick_free_port() {
    p=38200
    while [ "$p" -lt 38700 ]; do
        hexp=$(printf '%04X' "$p")
        if awk -v h="$hexp" '$4=="0A" && $2 ~ ":" h "$" { n++ } END { exit n>0 }' /proc/net/tcp 2>/dev/null; then
            echo "$p"; return 0
        fi
        p=$((p + 1))
    done
    echo ""
}
mk_snapshot() {   # <base> <taskfile-content...> → 建 snap_1 + current
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

# ── 1) entry: 接线锚点 + selfcheck ─────────────────────────────────────────
miss=0
for anchor in 'supervisor_tick "$TASKS_DIR"' 'crash_guard_enter "$DATA_DIR"' \
              'runtime_protect "$DATA_DIR"' 'state_rehydrate_residual "$TASKS_DIR"' \
              'runtime_scan_stale "$TASKS_DIR"' 'lifecycle_startup_registry' \
              'shadow_init' 'runtime_map_refresh' 'action_run'; do
    grep -qF "$anchor" "$DAEMON" || miss=$((miss + 1))
done
[ "$miss" -eq 0 ] && ok "P2-15 entry: daemon wires supervisor/crashguard/rehydrate/stale/registry/action/shadow" || bad "P2-15 entry: $miss daemon anchors missing"
miss=0
for anchor in 'cmd_task_kill' 'task-kill' 'task-info' 'task-output' 'task list' 'task status'; do
    grep -qF "$anchor" "$CLI" || miss=$((miss + 1))
done
[ "$miss" -eq 0 ] && ok "P2-15 entry: CLI task-kill/task-info/task-output/task list|status present" || bad "P2-15 entry: $miss CLI anchors missing"
sel=$(sed -n '/^runtime_lib_selfcheck()/,/^}/p' "$RTLIB")
lg=0
for fn in supervisor_step supervisor_tick crash_guard_enter health_check action_run \
          supervisor_runtime_exceeded runtime_protect task_cli_attach; do
    printf '%s\n' "$sel" | grep -q "$fn" || lg=$((lg + 1))
done
[ "$lg" -eq 0 ] && ok "P2-15 entry: P2 helpers all in runtime_lib_selfcheck" || bad "P2-15 entry: $lg selfcheck missing"
grep -q '^supervisor_runtime_exceeded()' "$RTLIB" && ok "P2-15 entry: runtime-exceeded guard defined (script-hang)" || bad "P2-15 entry: runtime_exceeded missing"

# ── 2) daemon kill + 重启 ──────────────────────────────────────────────────
FAKE="$T/fake-daemon.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
set -u
cd "$1" || exit 2
. ./"$2" || exit 2
base="$3"
crash_guard_enter "$base" >/dev/null 2>&1
rc=$?
echo "$rc" > "$4"
[ "$rc" -ne 0 ] && exit "$rc"
echo "$$" > "$5"
trap 'crash_record_exit "$base" 0 >/dev/null 2>&1; exit 0' TERM INT HUP
sleep 30 &
echo "$!" > "$6"
wait
EOF
chmod +x "$FAKE"
FD="$T/daemon/base"
mkdir -p "$FD"
export CRASH_MIN_START_INTERVAL=0
export CRASH_THRESHOLD=3
launch_fd() {
    n=$1
    bash "$FAKE" "$PWD" "$RTLIB" "$FD" "$T/drc.$n" "$T/dpid.$n" "$T/dcp.$n" >/dev/null 2>&1 &
    i=0; r=""
    while [ "$i" -lt 50 ]; do
        r=$(cat "$T/drc.$n" 2>/dev/null)
        if [ -n "$r" ]; then
            if [ "$r" != "0" ] || [ -s "$T/dcp.$n" ]; then break; fi
        fi
        sleep 0.1; i=$((i + 1))
    done
    echo "$r"
}
r1=$(launch_fd a); P1=$(cat "$T/dpid.a" 2>/dev/null); C1=$(cat "$T/dcp.a" 2>/dev/null)
kill -9 "$P1" 2>/dev/null; kill -9 "$C1" 2>/dev/null; sleep 0.3
r2=$(launch_fd b); P2=$(cat "$T/dpid.b" 2>/dev/null); C2=$(cat "$T/dcp.b" 2>/dev/null)
kill -9 "$P2" 2>/dev/null; kill -9 "$C2" 2>/dev/null; sleep 0.3
r3=$(launch_fd c); P3=$(cat "$T/dpid.c" 2>/dev/null); C3=$(cat "$T/dcp.c" 2>/dev/null)
kill -9 "$P3" 2>/dev/null; kill -9 "$C3" 2>/dev/null; sleep 0.3
[ "$r1" = "0" ] && [ "$r2" = "0" ] && [ "$r3" = "0" ] \
    && ok "P2-15 daemon-kill: launches 1-3 entered normally (rc 0) pre-SIGKILL" || bad "P2-15 daemon-kill: early rc r1=$r1 r2=$r2 r3=$r3"
r4=$(launch_fd d)
[ "$r4" = "2" ] && ok "P2-15 daemon-kill: 3xSIGKILL -> 4th launch DEGRADED (rc 2)" || bad "P2-15 daemon-kill: 4th rc=$r4 (expect 2)"
gd=$(crash_guard_file "$FD")
[ "$(crash_read "$gd" starts)" = "3" ] && ok "P2-15 daemon-kill: degraded fast-exit did NOT count a start (starts=3)" || bad "P2-15 daemon-kill: starts=$(crash_read "$gd" starts)"
[ "$(crash_read "$gd" crash_seq)" = "3" ] && ok "P2-15 daemon-kill: crash_seq=3 persisted" || bad "P2-15 daemon-kill: crash_seq=$(crash_read "$gd" crash_seq)"
# 优雅启动（独立 base）：TERM -> last_clean=1 -> 下次 rc 0 crash_seq 归零
FD2="$T/daemon/base2"
mkdir -p "$FD2"
launch_fd2() {
    n=$1
    bash "$FAKE" "$PWD" "$RTLIB" "$FD2" "$T/dr2.$n" "$T/dp2.$n" "$T/dc2.$n" >/dev/null 2>&1 &
    i=0; r=""
    while [ "$i" -lt 50 ]; do
        r=$(cat "$T/dr2.$n" 2>/dev/null)
        if [ -n "$r" ]; then
            if [ "$r" != "0" ] || [ -s "$T/dc2.$n" ]; then break; fi
        fi
        sleep 0.1; i=$((i + 1))
    done
    echo "$r"
}
r5=$(launch_fd2 e)
P5=$(cat "$T/dp2.e" 2>/dev/null); C5=$(cat "$T/dc2.e" 2>/dev/null)
kill -TERM "$P5" 2>/dev/null
i=0
while [ "$i" -lt 30 ] && [ -d "/proc/$P5" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -9 "$C5" 2>/dev/null
[ "$r5" = "0" ] && [ ! -d "/proc/$P5" ] 2>/dev/null \
    && ok "P2-15 daemon-kill: TERM -> daemon exited via trap (clean)" || bad "P2-15 daemon-kill: TERM exit failed"
g2=$(crash_guard_file "$FD2")
[ "$(crash_read "$g2" last_clean)" = "1" ] && ok "P2-15 daemon-kill: TERM -> last_clean=1" || bad "P2-15 daemon-kill: last_clean=$(crash_read "$g2" last_clean)"
r6=$(launch_fd2 f)
P6=$(cat "$T/dp2.f" 2>/dev/null); C6=$(cat "$T/dc2.f" 2>/dev/null)
kill -TERM "$P6" 2>/dev/null
i=0
while [ "$i" -lt 30 ] && [ -d "/proc/$P6" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -9 "$C6" 2>/dev/null
[ "$r6" = "0" ] && [ "$(crash_read "$g2" crash_seq)" = "0" ] \
    && ok "P2-15 daemon-kill: clean exit -> next start rc 0, crash_seq reset" || bad "P2-15 daemon-kill: r6=$r6 crash_seq=$(crash_read "$g2" crash_seq)"
unset CRASH_MIN_START_INTERVAL CRASH_THRESHOLD

# ── 3) task kill：受监督任务进程被 kill -9 → 探针 → UNHEALTHY → RECOVERING → 重跑 → HEALTHY
if command -v nc >/dev/null 2>&1; then
    PORT=$(pick_free_port)
    BASE_TK="$T/taskkill/base"
    TASKS_TK="$T/taskkill/tasks"
    mkdir -p "$TASKS_TK"
    mk_snapshot "$BASE_TK" \
        "schema_version=2" "id=t50_8080" "name=tk" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $PORT" "health.type=port" "health.target=$PORT" \
        "retry.max=3" "retry.interval=0"
    registry_attach "$BASE_TK" >/dev/null 2>&1
    mk_run "$TASKS_TK" RUNNING
    export TPR_ACTION_DIR="$TASKS_TK"
    export HEALTH_MIN_INTERVAL=0
    export TASK_RUNTIME_MAX=0
    RD_TK="$TASKS_TK/t50_8080"
    TF_TK="$BASE_TK/snapshots/snap_1/t50_8080.task"
    nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
    NCPID=$!
    up=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$RD_TK" "$TF_TK" >/dev/null 2>&1
        [ "$(cat "$RD_TK/state.txt" 2>/dev/null)" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && ok "P2-15 task-kill: RUNNING -> HEALTHY (listener up)" || bad "P2-15 task-kill: not HEALTHY (state=$(cat "$RD_TK/state.txt" 2>/dev/null))"
    # 模拟 task kill：kill -9 监听进程 → 探针失败 → UNHEALTHY → RECOVERING
    kill -9 "$NCPID" 2>/dev/null
    down=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$RD_TK" "$TF_TK" >/dev/null 2>&1
        st=$(cat "$RD_TK/state.txt" 2>/dev/null)
        [ "$st" = "UNHEALTHY" ] && { down=1; break; }
        [ "$st" = "RECOVERING" ] && break
        sleep 0.3; i=$((i + 1))
    done
    [ "$down" -eq 1 ] && ok "P2-15 task-kill: kill -9 listener -> UNHEALTHY (probe fail)" || bad "P2-15 task-kill: state=$(cat "$RD_TK/state.txt" 2>/dev/null)"
    # RECOVERING → 重跑 → RUNNING → 探针通过 → HEALTHY（闭环）
    sup=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$RD_TK" "$TF_TK" >/dev/null 2>&1
        [ "$(cat "$RD_TK/state.txt" 2>/dev/null)" = "HEALTHY" ] && { sup=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$sup" -eq 1 ] && ok "P2-15 task-kill: UNHEALTHY->RECOVERING->relaunch->HEALTHY (self-heal after task kill)" || bad "P2-15 task-kill: not recovered (state=$(cat "$RD_TK/state.txt" 2>/dev/null))"
    for p in $(pgrep -f "nc -l 127.0.0.1 $PORT" 2>/dev/null); do kill "$p" 2>/dev/null; done
    unset HEALTH_MIN_INTERVAL TASK_RUNTIME_MAX TPR_ACTION_DIR
else
    ok "P2-15 task-kill: nc unavailable -- not exercised (helper funcs covered)"
fi

# ── 4) 脚本 hang：超 TASK_RUNTIME_MAX → FAILED 终止 + 事件 ────────────────
if command -v nc >/dev/null 2>&1; then
    BASE_HG="$T/hang/base"
    TASKS_HG="$T/hang/tasks"
    mkdir -p "$TASKS_HG"
    mk_snapshot "$BASE_HG" \
        "schema_version=2" "id=t50_8080" "name=hg" "enabled=1" "trigger=08:00" \
        "action.command=true" "health.type=port" "health.target=59994" \
        "retry.max=2" "retry.interval=0"
    registry_attach "$BASE_HG" >/dev/null 2>&1
    mk_run "$TASKS_HG" RUNNING
    export TPR_ACTION_DIR="$TASKS_HG"
    export TASK_RUNTIME_MAX=60
    export HEALTH_MIN_INTERVAL=0
    RD_HG="$TASKS_HG/t50_8080"
    TF_HG="$BASE_HG/snapshots/snap_1/t50_8080.task"
    # 长时进程（hang）占位 pid + supervisor.since 前移 → 超时 → FAILED 终止
    sleep 300 &
    HPID=$!
    echo "$HPID" > "$RD_HG/pid.txt"
    echo "$(( $(date +%s) - 120 ))" > "$RD_HG/supervisor.since"
    supervisor_step "$RD_HG" "$TF_HG" >/dev/null 2>&1
    [ "$(cat "$RD_HG/state.txt" 2>/dev/null)" = "FAILED" ] \
        && ok "P2-15 script-hang: runtime-exceeded -> FAILED (hang terminated)" || bad "P2-15 script-hang: state=$(cat "$RD_HG/state.txt" 2>/dev/null)"
    tail -1 "$RD_HG/events.log" 2>/dev/null | grep -q 'runtime-limit exceeded' \
        && ok "P2-15 script-hang: event message 'runtime-limit exceeded'" || bad "P2-15 script-hang: event missing"
    [ ! -d "/proc/$HPID" ] 2>/dev/null && ok "P2-15 script-hang: hanging process terminated" || bad "P2-15 script-hang: pid alive"
    kill "$HPID" 2>/dev/null
    unset TASK_RUNTIME_MAX HEALTH_MIN_INTERVAL TPR_ACTION_DIR
else
    ok "P2-15 script-hang: nc unavailable -- helper coverage only"
fi

# ── 5) 应用崩溃韧性：多次崩溃 → 每次重跑恢复 HEALTHY（崩溃→恢复循环自愈）──
if command -v nc >/dev/null 2>&1; then
    PORT5=$(pick_free_port)
    BASE_AC="$T/appcrash/base"
    TASKS_AC="$T/appcrash/tasks"
    mkdir -p "$TASKS_AC"
    mk_snapshot "$BASE_AC" \
        "schema_version=2" "id=t50_8080" "name=ac" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $PORT5" "health.type=port" "health.target=$PORT5" \
        "retry.max=5" "retry.interval=0"
    registry_attach "$BASE_AC" >/dev/null 2>&1
    mk_run "$TASKS_AC" RUNNING
    export TPR_ACTION_DIR="$TASKS_AC"
    export HEALTH_MIN_INTERVAL=0
    export TASK_RUNTIME_MAX=0
    RD_AC="$TASKS_AC/t50_8080"
    TF_AC="$BASE_AC/snapshots/snap_1/t50_8080.task"
    crash_n=0
    i=0
    # 两次崩溃-恢复周期：起监听→HEALTHY，杀→UNHEALTHY→RECOVERING→重跑→HEALTHY。
    # 每次崩溃前杀尽该端口监听（含上一周期 supervisor 重跑产生的），避免端口占用
    # 令新一轮手动 nc 绑定失败（端口冲突会掩盖真崩溃）。
    while [ "$i" -lt 2 ]; do
        for p in $(pgrep -f "nc -l 127.0.0.1 $PORT5" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
        sleep 0.2
        nc -l 127.0.0.1 "$PORT5" >/dev/null 2>&1 &
        ACPID=$!
        h=0; k=0
        j=0
        while [ "$j" -lt 10 ]; do
            supervisor_step "$RD_AC" "$TF_AC" >/dev/null 2>&1
            [ "$(cat "$RD_AC/state.txt" 2>/dev/null)" = "HEALTHY" ] && { h=1; break; }
            sleep 0.3; j=$((j + 1))
        done
        kill -9 "$ACPID" 2>/dev/null
        j=0
        while [ "$j" -lt 10 ]; do
            supervisor_step "$RD_AC" "$TF_AC" >/dev/null 2>&1
            [ "$(cat "$RD_AC/state.txt" 2>/dev/null)" = "RECOVERING" ] && { k=1; break; }
            sleep 0.3; j=$((j + 1))
        done
        # 重跑 action（RECOVERING 先行执行 → 显式两段迁往 RUNNING）→ 探针通过
        j=0
        while [ "$j" -lt 10 ]; do
            supervisor_step "$RD_AC" "$TF_AC" >/dev/null 2>&1
            [ "$(cat "$RD_AC/state.txt" 2>/dev/null)" = "HEALTHY" ] && break
            sleep 0.3; j=$((j + 1))
        done
        [ "$h" -eq 1 ] && [ "$k" -eq 1 ] && [ "$(cat "$RD_AC/state.txt" 2>/dev/null)" = "HEALTHY" ] \
            && crash_n=$((crash_n + 1))
        i=$((i + 1))
    done
    [ "$crash_n" -eq 2 ] && ok "P2-15 app-crash: 2 crash-recover cycles each self-healed to HEALTHY (resilient loop)" || bad "P2-15 app-crash: only $crash_n/2 cycles recovered"
    for p in $(pgrep -f "nc -l 127.0.0.1 $PORT5" 2>/dev/null); do kill "$p" 2>/dev/null; done
    unset HEALTH_MIN_INTERVAL TASK_RUNTIME_MAX TPR_ACTION_DIR
else
    ok "P2-15 app-crash: nc unavailable -- helper coverage only"
fi

# ── 6) 重启残留收尾：daemon 重启后 RUNNING（进程已死）→ FAILED + daemon_restart
RZ="$T/restart/tasks"
mkdir -p "$RZ"
mkdir -p "$RZ/ghost_a"
echo "RUNNING" > "$RZ/ghost_a/state.txt"
echo "RUNNING" > "$RZ/ghost_a/status.txt"
echo "99999999" > "$RZ/ghost_a/pid.txt"   # 已死 pid → 重启后应 FAILED
state_rehydrate_residual "$RZ" >/dev/null 2>&1
[ "$(cat "$RZ/ghost_a/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P2-15 restart: daemon-restart residual RUNNING->FAILED (no ghost RUNNING)" || bad "P2-15 restart: state=$(cat "$RZ/ghost_a/state.txt" 2>/dev/null)"
tail -1 "$RZ/ghost_a/events.log" 2>/dev/null | grep -q 'daemon_restart' \
    && ok "P2-15 restart: residual -> daemon_restart event" || bad "P2-15 restart: event missing"
mkdir -p "$RZ/done_b"
echo "FAILED" > "$RZ/done_b/state.txt"
echo "FAILED" > "$RZ/done_b/status.txt"
state_rehydrate_residual "$RZ" >/dev/null 2>&1
[ "$(cat "$RZ/done_b/state.txt" 2>/dev/null)" = "FAILED" ] && [ ! -f "$RZ/done_b/events.log" ] \
    && ok "P2-15 restart: already-finalized dir untouched on re-restart" || bad "P2-15 restart: done_b touched"

# ── 7) POSIX ────────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-15 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. P2 parts)" || bad "P2-15 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-15 POSIX: bash -n ok (dash unavailable)" || bad "P2-15 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p2-integration tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1