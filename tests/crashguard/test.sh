#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Crash Loop 保护与资源保护（P2-14）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-14 出口：daemon 崩溃循环抑制 + 磁盘资源上限）：
#   1) 入口：§18 crash_guard_* / runtime_* / supervisor_health_due|mark /
#      supervisor_runtime_exceeded 定义；selfcheck 锚点；daemon 接线锚点
#      （crash_guard_enter 先于启动工作 / record_exit trap / 每 tick
#      runtime_protect + runtime_protect_tasks）。
#   2) 计数语义：首次进入 starts=1；优雅退出（record_exit）后再次进入
#      starts=2 且 exits=1；SIGKILL 模拟（无 record_exit）→ exits 补记 + crash_seq 递增。
#   3) 崩溃序列 → DEGRADED：连续异常进入达到 CRASH_THRESHOLD → rc 2，降级
#      快速退出不再登记 starts；crash_seq 反映连续异常次数。
#   4) 优雅退出重置：crash_record_exit 后再次进入 → crash_seq=0（不再降级）。
#   5) 节流：异常退出 + 立即重进（CRASH_MIN_START_INTERVAL 内）→ rc 3 且
#      starts 不变；优雅退出后不再节流（rc 0）。
#   6) 日志截断 runtime_limit_log：超限 → 保留尾部 max/2 字节；未超限不动。
#   7) 任务目录上限：TASK_DIRS_MAX 外非活跃目录删除；活跃（status=RUNNING
#      或 pid.txt 存活）豁免保留。
#   8) 快照上限：SNAP_MAX_KEEP 外删除，current 所指快照恒保留；runtime_protect
#      同时截断 su-scheduler.log / audit.log / shadow.log。
#   9) 健康探针最小间隔：HEALTH_MIN_INTERVAL 内不重复探活（health.last 节流）。
#  10) 运行超时护栏：TASK_RUNTIME_MAX 超时 → FAILED + 终止进程。
#  11) 真实链路（fake daemon 进程）：SIGKILL ×3 → 第 4 次启动降级快速退出
#      （rc 2，starts 不增）；优雅 TERM → last_clean=1 → 下次启动 rc 0 且
#      crash_seq 重置。
#  12) POSIX：lib dash -n。
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

# ── 工具：找空闲端口 + 造 registry 快照 + 造运行目录 ───────────────────────
pick_free_port() {
    p=37600
    while [ "$p" -lt 38100 ]; do
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

# ── 1) 入口 + 接线 ─────────────────────────────────────────────────────────
n=$(grep -cE '^crash_(guard_file|guard_enter|record_exit|read|write)\(' "$RTLIB")
[ "$n" -eq 5 ] && ok "P2-14 entry: §18 crash_guard_* 5 functions defined" || bad "P2-14 entry: crash_guard funcs count=$n (expect 5)"
n=$(grep -cE '^runtime_(protect|protect_tasks|prune_tasks|prune_snapshots|limit_log|dir_active)\(' "$RTLIB")
[ "$n" -eq 6 ] && ok "P2-14 entry: §18 runtime_* 6 functions defined" || bad "P2-14 entry: runtime funcs count=$n (expect 6)"
n=$(grep -cE '^supervisor_(health_due|health_mark|runtime_exceeded)\(' "$RTLIB")
[ "$n" -eq 3 ] && ok "P2-14 entry: §18 supervisor_health_due/mark + runtime_exceeded defined" || bad "P2-14 entry: supervisor gate funcs count=$n (expect 3)"
sel=$(sed -n '/^runtime_lib_selfcheck()/,/^}/p' "$RTLIB")
miss=0
for fn in crash_guard_enter crash_record_exit runtime_protect runtime_protect_tasks supervisor_health_due supervisor_runtime_exceeded; do
    printf '%s\n' "$sel" | grep -q "$fn" || miss=$((miss + 1))
done
[ "$miss" -eq 0 ] && ok "P2-14 entry: §18 helpers registered in runtime_lib_selfcheck" || bad "P2-14 entry: $miss selfcheck helpers missing"
grep -q 'crash_guard_enter "\$DATA_DIR"' "$DAEMON" && ok "P2-14 wiring: daemon calls crash_guard_enter before startup work" || bad "P2-14 wiring: crash_guard_enter missing in daemon"
grep -q "trap 'crash_record_exit \"\$DATA_DIR\" 0" "$DAEMON" && ok "P2-14 wiring: daemon installs crash_record_exit trap (TERM/INT/HUP)" || bad "P2-14 wiring: record_exit trap missing in daemon"
n=$(grep -c "trap '" "$DAEMON")
[ "$n" -eq 1 ] && ok "P2-14 wiring: single trap in daemon (record_exit; no legacy trap overwritten)" || bad "P2-14 wiring: trap count=$n (expect 1)"
grep -q 'runtime_protect "\$DATA_DIR"' "$DAEMON" && ok "P2-14 wiring: daemon per-tick runtime_protect (logs+snapshots)" || bad "P2-14 wiring: runtime_protect missing in daemon"
grep -q 'runtime_protect_tasks "\$TASKS_DIR"' "$DAEMON" && ok "P2-14 wiring: daemon per-tick runtime_protect_tasks (dir limit)" || bad "P2-14 wiring: runtime_protect_tasks missing in daemon"

# ── 2) 计数语义（首次 / 优雅退出 / SIGKILL 模拟）───────────────────────────
B1="$T/c1/base"
crash_guard_enter "$B1" >/dev/null 2>&1
g=$(crash_guard_file "$B1")
[ "$(crash_read "$g" starts)" = "1" ] && [ "$(crash_read "$g" exits)" = "0" ] \
    && ok "P2-14 count: first enter → starts=1 exits=0" || bad "P2-14 count: first enter starts=$(crash_read "$g" starts) exits=$(crash_read "$g" exits)"
crash_record_exit "$B1" 0 >/dev/null 2>&1
[ "$(crash_read "$g" exits)" = "1" ] && [ "$(crash_read "$g" last_clean)" = "1" ] \
    && ok "P2-14 count: record_exit → exits=1 last_clean=1" || bad "P2-14 count: record_exit exits=$(crash_read "$g" exits) clean=$(crash_read "$g" last_clean)"
crash_guard_enter "$B1" >/dev/null 2>&1
[ "$(crash_read "$g" starts)" = "2" ] && [ "$(crash_read "$g" exits)" = "1" ] \
    && ok "P2-14 count: clean exit → next enter starts=2 exits=1 (no extra count)" || bad "P2-14 count: after clean enter starts=$(crash_read "$g" starts) exits=$(crash_read "$g" exits)"
# SIGKILL 模拟：进入后不 record_exit 再次进入 → 无退出记录补记 exits + crash_seq 递增
B2="$T/c2/base"
export CRASH_MIN_START_INTERVAL=0    # 关闭节流，聚焦崩溃计数语义
export CRASH_THRESHOLD=100           # 高阈值，本组不触发降级
crash_guard_enter "$B2" >/dev/null 2>&1
crash_guard_enter "$B2" >/dev/null 2>&1
crash_guard_enter "$B2" >/dev/null 2>&1
g2=$(crash_guard_file "$B2")
[ "$(crash_read "$g2" starts)" = "3" ] && [ "$(crash_read "$g2" exits)" = "2" ] && [ "$(crash_read "$g2" crash_seq)" = "2" ] \
    && ok "P2-14 count: SIGKILL sim ×3 → starts=3 exits=2 crash_seq=2 (no-exit runs counted)" || bad "P2-14 count: SIGKILL sim starts=$(crash_read "$g2" starts) exits=$(crash_read "$g2" exits) seq=$(crash_read "$g2" crash_seq)"

# ── 3) 崩溃序列 → DEGRADED（阈值命中 → rc 2，不再登记 starts）──────────────
B3="$T/c3/base"
export CRASH_THRESHOLD=2
export CRASH_MIN_START_INTERVAL=0
crash_guard_enter "$B3" >/dev/null 2>&1
crash_guard_enter "$B3" >/dev/null 2>&1
g3=$(crash_guard_file "$B3")
[ "$(crash_read "$g3" starts)" = "2" ] && [ "$(crash_read "$g3" crash_seq)" = "1" ] \
    && ok "P2-14 degraded: pre-threshold starts=2 crash_seq=1" || bad "P2-14 degraded: pre-threshold starts=$(crash_read "$g3" starts) seq=$(crash_read "$g3" crash_seq)"
crash_guard_enter "$B3" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "P2-14 degraded: threshold hit → rc 2 (DEGRADED)" || bad "P2-14 degraded: threshold rc=$rc (expect 2)"
crash_guard_enter "$B3" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && [ "$(crash_read "$g3" starts)" = "2" ] \
    && ok "P2-14 degraded: degraded window → fast-exit rc 2, starts unchanged (no re-entry)" || bad "P2-14 degraded: in-window rc=$rc starts=$(crash_read "$g3" starts)"
[ "$(crash_read "$g3" crash_seq)" = "2" ] && ok "P2-14 degraded: crash_seq=2 persisted" || bad "P2-14 degraded: crash_seq=$(crash_read "$g3" crash_seq)"

# ── 4) 优雅退出重置 crash_seq（不降级）─────────────────────────────────────
B4="$T/c4/base"
export CRASH_MIN_START_INTERVAL=0
crash_guard_enter "$B4" >/dev/null 2>&1
crash_guard_enter "$B4" >/dev/null 2>&1
g4=$(crash_guard_file "$B4")
[ "$(crash_read "$g4" crash_seq)" = "1" ] && ok "P2-14 reset: abnormal ×2 → crash_seq=1" || bad "P2-14 reset: crash_seq=$(crash_read "$g4" crash_seq)"
crash_record_exit "$B4" 0 >/dev/null 2>&1
crash_guard_enter "$B4" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(crash_read "$g4" crash_seq)" = "0" ] \
    && ok "P2-14 reset: clean exit → next enter rc 0 crash_seq=0 (no degraded)" || bad "P2-14 reset: rc=$rc crash_seq=$(crash_read "$g4" crash_seq)"

# ── 5) 节流：异常退出 + 立即重进 → rc 3（starts 不变）；优雅后解除 ──────────
B5="$T/c5/base"
export CRASH_MIN_START_INTERVAL=10
export CRASH_THRESHOLD=100
crash_guard_enter "$B5" >/dev/null 2>&1
crash_guard_enter "$B5" >/dev/null 2>&1
rc=$?
g5=$(crash_guard_file "$B5")
[ "$rc" -eq 3 ] && [ "$(crash_read "$g5" starts)" = "1" ] \
    && ok "P2-14 throttle: abnormal + immediate re-enter → rc 3, starts unchanged" || bad "P2-14 throttle: rc=$rc starts=$(crash_read "$g5" starts)"
crash_record_exit "$B5" 0 >/dev/null 2>&1
crash_guard_enter "$B5" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(crash_read "$g5" starts)" = "2" ] \
    && ok "P2-14 throttle: clean exit → no throttle (rc 0), starts=2" || bad "P2-14 throttle: after clean rc=$rc starts=$(crash_read "$g5" starts)"

# ── 6) 日志截断 ─────────────────────────────────────────────────────────────
LB="$T/log"
mkdir -p "$LB"
head -c 1000 /dev/zero | tr '\0' 'x' > "$LB/big.log"
runtime_limit_log "$LB/big.log" 512
sz=$(wc -c < "$LB/big.log")
[ "$sz" -eq 256 ] && ok "P2-14 limit_log: >max truncated to max/2 (1000→256 bytes)" || bad "P2-14 limit_log: size=$sz (expect 256)"
printf 'hello\n' > "$LB/small.log"
runtime_limit_log "$LB/small.log" 512
[ "$(wc -c < "$LB/small.log")" -eq 6 ] && ok "P2-14 limit_log: ≤max untouched" || bad "P2-14 limit_log: small changed to $(wc -c < "$LB/small.log")"

# ── 7) 任务目录上限修剪（非活跃删除 / 活跃豁免）────────────────────────────
TD="$T/prune/tasks"
mkdir -p "$TD"
for d in d1 d2 d3 d4 d5; do mkdir -p "$TD/$d"; done
echo "RUNNING" > "$TD/d1/status.txt"   # 最旧且超上限但活跃 → 豁免（先写 marker 再 touch，避免改 mtime）
touch -t 202401010105 "$TD/d5"   # d5 最新 … d1 最旧
touch -t 202401010104 "$TD/d4"
touch -t 202401010103 "$TD/d3"
touch -t 202401010102 "$TD/d2"
touch -t 202401010101 "$TD/d1"
export TASK_DIRS_MAX=3
runtime_protect_tasks "$TD"
[ -d "$TD/d1" ] && [ ! -d "$TD/d2" ] && [ -d "$TD/d3" ] && [ -d "$TD/d4" ] && [ -d "$TD/d5" ] \
    && ok "P2-14 prune_tasks: 3 newest kept, inactive d2 removed, active d1 exempted" || bad "P2-14 prune_tasks: wrong survivor set (d1=$(test -d "$TD/d1" && echo y || echo n) d2=$(test -d "$TD/d2" && echo y || echo n))"
# pid 存活 → 活跃豁免
TD2="$T/prune2/tasks"
mkdir -p "$TD2"
for d in e1 e2 e3 e4; do mkdir -p "$TD2/$d"; done
echo "$$" > "$TD2/e4/pid.txt"          # 测试进程自身 pid → /proc 存活（先写 marker 再 touch）
touch -t 202401010104 "$TD2/e1"
touch -t 202401010103 "$TD2/e2"
touch -t 202401010102 "$TD2/e3"
touch -t 202401010101 "$TD2/e4"
export TASK_DIRS_MAX=2
runtime_protect_tasks "$TD2"
[ -d "$TD2/e4" ] && [ ! -d "$TD2/e3" ] && [ -d "$TD2/e1" ] && [ -d "$TD2/e2" ] \
    && ok "P2-14 prune_tasks: live pid dir exempted beyond max (e4 kept, e3 removed)" || bad "P2-14 prune_tasks: pid-active set wrong"

# ── 8) 快照上限修剪 + runtime_protect 日志截断 ─────────────────────────────
SB="$T/snap/base"
mkdir -p "$SB/snapshots"
for i in 1 2 3 4 5 6; do mkdir -p "$SB/snapshots/snap_$i"; done
touch -t 202401010106 "$SB/snapshots/snap_6"
touch -t 202401010105 "$SB/snapshots/snap_5"
touch -t 202401010104 "$SB/snapshots/snap_4"
touch -t 202401010103 "$SB/snapshots/snap_3"
touch -t 202401010102 "$SB/snapshots/snap_2"
touch -t 202401010101 "$SB/snapshots/snap_1"
echo "snap_4" > "$SB/current"
export SNAP_MAX_KEEP=3
export LOG_MAX_BYTES=1024
SP="$T/snap/logs"
mkdir -p "$SP/audit" "$SP/shadow"
head -c 2000 /dev/zero | tr '\0' 'x' > "$SP/su-scheduler.log"
head -c 2000 /dev/zero | tr '\0' 'x' > "$SP/audit/audit.log"
head -c 2000 /dev/zero | tr '\0' 'x' > "$SP/shadow/shadow.log"
runtime_protect "$SB"
[ -d "$SB/snapshots/snap_4" ] && [ -d "$SB/snapshots/snap_6" ] && [ -d "$SB/snapshots/snap_5" ] && [ -d "$SB/snapshots/snap_3" ] \
    && [ ! -d "$SB/snapshots/snap_1" ] && [ ! -d "$SB/snapshots/snap_2" ] \
    && ok "P2-14 prune_snapshots: current snap_4 + 3 newest kept, snap_1/2 removed" || bad "P2-14 prune_snapshots: wrong survivor set"
runtime_protect "$SP"
[ "$(wc -c < "$SP/su-scheduler.log")" -eq 512 ] && [ "$(wc -c < "$SP/audit/audit.log")" -eq 512 ] && [ "$(wc -c < "$SP/shadow/shadow.log")" -eq 512 ] \
    && ok "P2-14 protect: 3 logs truncated to max/2 (2000→512)" || bad "P2-14 protect: log truncation failed"

# ── 9) 健康探针最小间隔（supervisor_step 按 health.last 节流）──────────────
if command -v nc >/dev/null 2>&1; then
    PORT=$(pick_free_port)
    BASE_H="$T/health/base"
    TASKS_H="$T/health/tasks"
    mkdir -p "$TASKS_H"
    mk_snapshot "$BASE_H" \
        "schema_version=2" "id=t50_8080" "name=h" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $PORT" "health.type=port" "health.target=$PORT" \
        "retry.max=2" "retry.interval=0"
    registry_attach "$BASE_H" >/dev/null 2>&1
    mk_run "$TASKS_H" RUNNING
    export TPR_ACTION_DIR="$TASKS_H"
    export HEALTH_MIN_INTERVAL=30
    export TASK_RUNTIME_MAX=0    # 本组不测超时护栏
    RD_H="$TASKS_H/t50_8080"
    nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
    NCPID=$!
    supervisor_step "$RD_H" "$BASE_H/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$RD_H/state.txt" 2>/dev/null)" = "HEALTHY" ] && [ -f "$RD_H/health.last" ] \
        && ok "P2-14 health-interval: probe ok → HEALTHY + health.last written" || bad "P2-14 health-interval: state=$(cat "$RD_H/state.txt" 2>/dev/null)"
    kill "$NCPID" 2>/dev/null
    supervisor_step "$RD_H" "$BASE_H/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$RD_H/state.txt" 2>/dev/null)" = "HEALTHY" ] \
        && ok "P2-14 health-interval: within interval → probe skipped (stays HEALTHY)" || bad "P2-14 health-interval: re-probed too soon (state=$(cat "$RD_H/state.txt" 2>/dev/null))"
    echo "$(( $(date +%s) - 60 ))" > "$RD_H/health.last"   # 人为过期
    supervisor_step "$RD_H" "$BASE_H/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$RD_H/state.txt" 2>/dev/null)" = "UNHEALTHY" ] \
        && ok "P2-14 health-interval: interval elapsed → probe fail → UNHEALTHY" || bad "P2-14 health-interval: state=$(cat "$RD_H/state.txt" 2>/dev/null)"
else
    ok "P2-14 health-interval: nc unavailable — not exercised (helper funcs covered)"
fi

# ── 10) 运行超时护栏（TASK_RUNTIME_MAX → FAILED + 终止进程）─────────────────
if command -v nc >/dev/null 2>&1; then
    BASE_C="$T/cap/base"
    TASKS_C="$T/cap/tasks"
    mkdir -p "$TASKS_C"
    mk_snapshot "$BASE_C" \
        "schema_version=2" "id=t50_8080" "name=c" "enabled=1" "trigger=08:00" \
        "action.command=true" "health.type=port" "health.target=59995" \
        "retry.max=2" "retry.interval=0"
    registry_attach "$BASE_C" >/dev/null 2>&1
    mk_run "$TASKS_C" RUNNING
    export TPR_ACTION_DIR="$TASKS_C"
    export TASK_RUNTIME_MAX=60
    export HEALTH_MIN_INTERVAL=0    # 不干扰超时判定
    RD_C="$TASKS_C/t50_8080"
    sleep 300 &
    CPID=$!
    echo "$CPID" > "$RD_C/pid.txt"
    echo "$(( $(date +%s) - 120 ))" > "$RD_C/supervisor.since"   # 超时 60s 已过 120s
    supervisor_step "$RD_C" "$BASE_C/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$RD_C/state.txt" 2>/dev/null)" = "FAILED" ] \
        && ok "P2-14 runtime-cap: exceeded → FAILED (runtime-limit exceeded)" || bad "P2-14 runtime-cap: state=$(cat "$RD_C/state.txt" 2>/dev/null)"
    tail -1 "$RD_C/events.log" 2>/dev/null | grep -q 'runtime-limit exceeded' \
        && ok "P2-14 runtime-cap: FAILED event message 'runtime-limit exceeded'" || bad "P2-14 runtime-cap: event missing"
    [ ! -d "/proc/$CPID" ] 2>/dev/null && ok "P2-14 runtime-cap: overrun process terminated" || bad "P2-14 runtime-cap: pid still alive"
    kill "$CPID" 2>/dev/null
else
    ok "P2-14 runtime-cap: nc unavailable — not exercised (helper funcs covered)"
fi

# ── 11) 真实链路：fake daemon SIGKILL ×3 → 第 4 次降级快速退出 ──────────────
FAKE="$T/fake-daemon.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# 模拟 daemon 加载段：加载 lib（路径经 $2 传入，保持路径隔离门禁语义）→
# crash_guard_enter → 装 record_exit trap → 常驻
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
FD="$T/fd/base"
mkdir -p "$FD"
export CRASH_MIN_START_INTERVAL=0    # 关节流聚焦崩溃序列（连续快速重启合法）
export CRASH_THRESHOLD=3
launch_fd() {   # <tag> → 等待进入完成（rc 或子进程已写），回显 rc
    n=$1
    bash "$FAKE" "$PWD" "$RTLIB" "$FD" "$T/rc.$n" "$T/pid.$n" "$T/cp.$n" >/dev/null 2>&1 &
    i=0; r=""
    while [ "$i" -lt 50 ]; do
        r=$(cat "$T/rc.$n" 2>/dev/null)
        if [ -n "$r" ]; then
            if [ "$r" != "0" ] || [ -s "$T/cp.$n" ]; then break; fi
        fi
        sleep 0.1; i=$((i + 1))
    done
    echo "$r"
}
# 第 1~3 次启动常驻后被 SIGKILL（模拟崩溃）→ 第 4 次启动降级快速退出
r1=$(launch_fd a)
P1=$(cat "$T/pid.a" 2>/dev/null); C1=$(cat "$T/cp.a" 2>/dev/null)
kill -9 "$P1" 2>/dev/null; kill -9 "$C1" 2>/dev/null; sleep 0.3
r2=$(launch_fd b)
P2=$(cat "$T/pid.b" 2>/dev/null); C2=$(cat "$T/cp.b" 2>/dev/null)
kill -9 "$P2" 2>/dev/null; kill -9 "$C2" 2>/dev/null; sleep 0.3
r3=$(launch_fd c)
P3=$(cat "$T/pid.c" 2>/dev/null); C3=$(cat "$T/cp.c" 2>/dev/null)
kill -9 "$P3" 2>/dev/null; kill -9 "$C3" 2>/dev/null; sleep 0.3
[ "$r1" = "0" ] && [ "$r2" = "0" ] && [ "$r3" = "0" ] \
    && ok "P2-14 chain: launches 1–3 entered normally (rc 0) before SIGKILL" || bad "P2-14 chain: early rc r1=$r1 r2=$r2 r3=$r3"
r4=$(launch_fd d)
[ "$r4" = "2" ] && ok "P2-14 chain: 3×SIGKILL → 4th launch DEGRADED (rc 2)" || bad "P2-14 chain: 4th rc=$r4 (expect 2)"
g=$(crash_guard_file "$FD")
[ "$(crash_read "$g" starts)" = "3" ] && ok "P2-14 chain: degraded fast-exit did NOT record a start (starts=3)" || bad "P2-14 chain: starts=$(crash_read "$g" starts)"
[ "$(crash_read "$g" crash_seq)" = "3" ] && ok "P2-14 chain: crash_seq=3 persisted" || bad "P2-14 chain: crash_seq=$(crash_read "$g" crash_seq)"
# 优雅 TERM（独立 base）：trap 记 last_clean=1 → 下次启动 rc 0 且 crash_seq 重置
FD2="$T/fd2/base"
mkdir -p "$FD2"
FD2REP="$T/fd2"
launch_fd2() {   # <tag> → 回显 rc（独立 base）
    n=$1
    bash "$FAKE" "$PWD" "$RTLIB" "$FD2" "$FD2REP/rc.$n" "$FD2REP/pid.$n" "$FD2REP/cp.$n" >/dev/null 2>&1 &
    i=0; r=""
    while [ "$i" -lt 50 ]; do
        r=$(cat "$FD2REP/rc.$n" 2>/dev/null)
        if [ -n "$r" ]; then
            if [ "$r" != "0" ] || [ -s "$FD2REP/cp.$n" ]; then break; fi
        fi
        sleep 0.1; i=$((i + 1))
    done
    echo "$r"
}
r5=$(launch_fd2 e)
P5=$(cat "$FD2REP/pid.e" 2>/dev/null); C5=$(cat "$FD2REP/cp.e" 2>/dev/null)
kill -TERM "$P5" 2>/dev/null
i=0
while [ "$i" -lt 30 ] && [ -d "/proc/$P5" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -9 "$C5" 2>/dev/null
[ "$r5" = "0" ] && [ ! -d "/proc/$P5" ] 2>/dev/null \
    && ok "P2-14 chain: TERM → daemon exited via trap" || bad "P2-14 chain: TERM exit failed (r5=$r5)"
g2=$(crash_guard_file "$FD2")
[ "$(crash_read "$g2" last_clean)" = "1" ] && ok "P2-14 chain: TERM → last_clean=1 recorded" || bad "P2-14 chain: last_clean=$(crash_read "$g2" last_clean)"
r6=$(launch_fd2 f)
P6=$(cat "$FD2REP/pid.f" 2>/dev/null); C6=$(cat "$FD2REP/cp.f" 2>/dev/null)
kill -TERM "$P6" 2>/dev/null
i=0
while [ "$i" -lt 30 ] && [ -d "/proc/$P6" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -9 "$C6" 2>/dev/null
[ "$r6" = "0" ] && [ "$(crash_read "$g2" crash_seq)" = "0" ] \
    && ok "P2-14 chain: clean exit → next start rc 0, crash_seq reset (no false degraded)" || bad "P2-14 chain: after clean r6=$r6 crash_seq=$(crash_read "$g2" crash_seq)"

# ── 12) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-14 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §18)" || bad "P2-14 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-14 POSIX: bash -n ok (dash unavailable)" || bad "P2-14 POSIX: bash -n failed"
fi

# ── 13) D-P5-01：仲裁先于 guard —— 被拒/并发实例不污染 daemon.guard ────────
# 根因（设备取证）：daemon 中 crash_guard_enter（登记 last_start/last_clean=0）
# 先于单实例仲裁执行 → watchdog 与 CLI 同时拉起实例时，被拒实例以**非信号退出**
# （exit 0）结束、TERM trap 不触发 → 留下"无退出记录的脏启动"→ 下一实例 eval
# 判为崩溃 → crash_seq 假累加 → 假降级 → 重启风暴。修复：仲裁（noclobber 原子
# 接管）先于 crash_guard_enter。此处用 fake daemon 模型化新启动序并断言：
#   ① 存活实例持有锁时，重复启动被拒且**不触碰 guard**（starts/last_clean 不变）；
#   ② 优雅 TERM 后再次启动 → crash_seq=0（无假崩溃计数）；
#   ③ 并发双启动 → 仅一方接管，guard 只记 1 次 starts。
FAKE3="$T/fake-daemon-arb.sh"
cat > "$FAKE3" <<'EOF'
#!/usr/bin/env bash
# 模拟 D-P5-01 新启动序：单实例仲裁（noclobber 原子接管）→ crash_guard_enter
#   → 装 record_exit trap → 常驻。args: $1=cd dir $2=lib $3=base $4=lock
#   $5=rcfile $6=pidfile $7=cpidfile
set -u
cd "$1" || exit 2
. ./"$2" || exit 2
base="$3"; lock="$4"; rcfile="$5"; pidfile="$6"; cpidfile="$7"
# 单实例仲裁：存活锁持有者 → 拒绝（不触碰 guard）；接管前不 rm 锁文件
# （否则会删掉并发实例刚创建的空锁导致双实例都通过，D-P5-01）；空锁让位轮询。
if ( set -C; : > "$lock" ) 2>/dev/null; then
    echo "$$" > "$lock"
else
    NPID=$(cat "$lock" 2>/dev/null)
    _c=0
    while [ -z "$NPID" ] && [ "$_c" -lt 3 ]; do
        sleep 1; _c=$((_c + 1)); NPID=$(cat "$lock" 2>/dev/null)
    done
    if [ -n "$NPID" ] && [ -d "/proc/$NPID" ]; then
        echo "refused" > "$rcfile"
        exit 0
    fi
    rm -f "$lock" 2>/dev/null
    ( set -C; : > "$lock" ) 2>/dev/null || { echo "refused" > "$rcfile"; exit 0; }
    echo "$$" > "$lock"
fi
crash_guard_enter "$base" >/dev/null 2>&1
rc=$?
echo "$rc" > "$rcfile"
[ "$rc" -ne 0 ] && { rm -f "$lock" 2>/dev/null; exit "$rc"; }
echo "$$" > "$pidfile"
trap 'crash_record_exit "$base" 0 >/dev/null 2>&1; exit 0' TERM INT HUP
sleep 30 &
echo "$!" > "$cpidfile"
wait
EOF
chmod +x "$FAKE3"
ARB="$T/arb/base"; mkdir -p "$ARB"
ARBLOCK="$T/arb.lock"
export CRASH_MIN_START_INTERVAL=0
export CRASH_THRESHOLD=3
launch_arb() {   # <tag> → 等待 rc（refused / rc 值）/ pid 就绪，回显 rc
    n=$1
    bash "$FAKE3" "$PWD" "$RTLIB" "$ARB" "$ARBLOCK" "$T/arb.rc.$n" "$T/arb.pid.$n" "$T/arb.cp.$n" >/dev/null 2>&1 &
    i=0; r=""
    while [ "$i" -lt 150 ]; do
        r=$(cat "$T/arb.rc.$n" 2>/dev/null)
        if [ -n "$r" ]; then
            if [ "$r" = "refused" ] || [ "$r" != "0" ] || [ -s "$T/arb.pid.$n" ]; then break; fi
        fi
        sleep 0.1; i=$((i + 1))
    done
    echo "$r"
}
rm -f "$ARBLOCK" "$(crash_guard_file "$ARB")" "$T"/arb.rc.* "$T"/arb.pid.* "$T"/arb.cp.*
# ① 实例 A 接管并登记 start；存活期间重复实例 B 被拒且不触碰 guard
rA=$(launch_arb a)
PA=$(cat "$T/arb.pid.a" 2>/dev/null)
g=$(crash_guard_file "$ARB")
[ "$rA" = "0" ] && [ "$(crash_read "$g" starts)" = "1" ] \
    && ok "D-P5-01 arb: winner A entered guard (starts=1)" || bad "D-P5-01 arb: A rA=$rA starts=$(crash_read "$g" starts)"
rB=$(launch_arb b)
[ "$rB" = "refused" ] && ok "D-P5-01 arb: duplicate B refused (single-instance)" || bad "D-P5-01 arb: B rB=$rB (expect refused)"
[ "$(crash_read "$g" starts)" = "1" ] && ok "D-P5-01 arb: refused B did NOT touch guard (starts=1)" || bad "D-P5-01 arb: starts=$(crash_read "$g" starts)"
# ② 优雅 TERM A → 新实例 C 启动 → crash_seq=0（无假崩溃计数）
kill -TERM "$PA" 2>/dev/null
i=0; while [ "$i" -lt 30 ] && [ -d "/proc/$PA" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
rC=$(launch_arb c)
PC=$(cat "$T/arb.pid.c" 2>/dev/null); CC=$(cat "$T/arb.cp.c" 2>/dev/null)
[ "$rC" = "0" ] && [ "$(crash_read "$g" crash_seq)" = "0" ] \
    && ok "D-P5-01 arb: after clean TERM + C start, crash_seq=0 (no false crash)" || bad "D-P5-01 arb: rC=$rC crash_seq=$(crash_read "$g" crash_seq)"
kill -TERM "$PC" 2>/dev/null
i=0; while [ "$i" -lt 30 ] && [ -d "/proc/$PC" ] 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -9 "$CC" "$PA" 2>/dev/null
# ③ 并发双启动：仅一方接管，guard 只记 1 次 starts
rm -f "$ARBLOCK" "$(crash_guard_file "$ARB")" "$T"/arb.rc.* "$T"/arb.pid.* "$T"/arb.cp.*
bash "$FAKE3" "$PWD" "$RTLIB" "$ARB" "$ARBLOCK" "$T/arb.rc.x" "$T/arb.pid.x" "$T/arb.cp.x" >/dev/null 2>&1 &
bash "$FAKE3" "$PWD" "$RTLIB" "$ARB" "$ARBLOCK" "$T/arb.rc.y" "$T/arb.pid.y" "$T/arb.cp.y" >/dev/null 2>&1 &
  i=0
  while [ "$i" -lt 150 ]; do
    rx=$(cat "$T/arb.rc.x" 2>/dev/null); ry=$(cat "$T/arb.rc.y" 2>/dev/null)
    { [ -n "$rx" ] && [ -n "$ry" ]; } && break
    sleep 0.1; i=$((i + 1))
  done
{ printf '%s\n' "$rx" "$ry" | grep -q '^0$'; } \
    && { printf '%s\n' "$rx" "$ry" | grep -q 'refused'; } \
    && ok "D-P5-01 arb: concurrent dual-launch → one winner + one refused" || bad "D-P5-01 arb: rx=$rx ry=$ry"
g2=$(crash_guard_file "$ARB")
[ "$(crash_read "$g2" starts)" = "1" ] && ok "D-P5-01 arb: concurrent guard records exactly 1 start" || bad "D-P5-01 arb: starts=$(crash_read "$g2" starts)"
kill -9 "$(cat "$T/arb.pid.x" 2>/dev/null)" "$(cat "$T/arb.pid.y" 2>/dev/null)" \
        "$(cat "$T/arb.cp.x" 2>/dev/null)" "$(cat "$T/arb.cp.y" 2>/dev/null)" 2>/dev/null

# ── 14) D-P5-01 静态断言：daemon 启动序 = 仲裁 → guard（防回归）──────────────
# 修复后 crash_guard_enter 调用必须位于单实例仲裁（LOCK_STILL_ACTIVE /
# refusing to start）与原子接管（set -C）之后——否则被拒实例先写 guard 再
# exit 0 → 假崩溃记录（D-P5-01 根因，防回退到旧序）。
guard_ln=$(grep -n 'crash_guard_enter "\$DATA_DIR"' "$DAEMON" | head -1 | cut -d: -f1)
refuse_ln=$(grep -n 'refusing to start (single-instance)' "$DAEMON" | head -1 | cut -d: -f1)
lock_ln=$(grep -n 'LOCK_STILL_ACTIVE' "$DAEMON" | head -1 | cut -d: -f1)
claim_ln=$(grep -n 'set -C' "$DAEMON" | head -1 | cut -d: -f1)
[ -n "$guard_ln" ] && [ -n "$refuse_ln" ] && [ -n "$lock_ln" ] \
    && [ "$guard_ln" -gt "$refuse_ln" ] && [ "$guard_ln" -gt "$lock_ln" ] \
    && ok "D-P5-01 order: crash_guard_enter (L$guard_ln) after single-instance arbitration (refuse L$refuse_ln / lock L$lock_ln)" \
    || bad "D-P5-01 order: guard_ln=$guard_ln refuse_ln=$refuse_ln lock_ln=$lock_ln (expect guard after arbitration)"
[ -n "$claim_ln" ] && ok "D-P5-01 order: noclobber atomic claim present (set -C L$claim_ln)" \
    || bad "D-P5-01 order: set -C atomic claim missing"

# ── 15) P6-07：Crash Loop × 节点级 Retry × 链不重放 联动（有界收敛，无死循环）──
# 检查项6：链节点 action 进程反复崩溃（shim 以 exit_code=1 建模）→ P4-07 退避
# 钳制（exec = 1+retry.max；retry.count 不超上限）× 链引擎（D51 传播 / D-06 不
# 自动重放 / 超时后滚）× guard（降级窗口内引擎零活动）三者联动有限步收敛。
# harness 与 tests/p6-dag §engine 同源（execute_task shim + SCHED_CYCLE_NOW/GATE_NOW
# 确定性时钟 + etick=sync→tick→sync）。
CG_N=0
execute_task() {           # 7 参 daemon 上下文委托；CG_FAILDIR 下恒失败 exit 1
    cg_id=$1; cg_d="$CG_TASKS/$cg_id"; mkdir -p "$cg_d" 2>/dev/null
    echo "$cg_id" >> "$CG_EXEC"
    if [ -f "$CG_FAILDIR/$cg_id" ]; then
        echo "1" > "$cg_d/exit_code.txt"; echo "FAILED" > "$cg_d/status.txt"
    elif [ -f "$CG_SLOWDIR/$cg_id" ]; then
        echo "RUNNING" > "$cg_d/status.txt"
    else
        echo "0" > "$cg_d/exit_code.txt"; echo "SUCCESS" > "$cg_d/status.txt"
    fi
    return 0
}
cg_new() {
    CG_N=$((CG_N + 1))
    CG_DIR="$T/cg$CG_N"; CG_BASE="$CG_DIR/base"; CG_TASKS="$CG_DIR/tasks"
    CG_TCFG="$CG_DIR/tcfg"; CG_FAILDIR="$CG_DIR/fail"; CG_SLOWDIR="$CG_DIR/slow"
    mkdir -p "$CG_BASE" "$CG_TASKS" "$CG_TCFG" "$CG_FAILDIR" "$CG_SLOWDIR"
    echo managed > "$CG_TCFG/MANAGED"
    export TCFG_DIR="$CG_TCFG"
    # 重挂 registry（前序 §2/§8 段已置 TR_BASE；sched_ensure_base 仅空时 attach）
    TR_BASE=""; TR_CONFIG_PATH=""; TASK_REGISTRY_SNAPSHOT=""
    CG_CFG="$CG_DIR/config.txt"; : > "$CG_CFG"
    CG_EXEC="$CG_DIR/exec.log"; : > "$CG_EXEC"
    CG_SEQ=0; CG_EPOCH=1789192800
    DAG_CHAIN_NODES_MAX=32; DAG_CHAIN_EDGES_MAX=128; DAG_CHAIN_DEPTH_MAX=16
    DAG_RUNS_MAX=8; DAG_PARALLEL_MAX=4; DAG_RUN_TIMEOUT=86400; DAG_RUNS_KEEP=8
    WAIT_MAX=86400
}
cg_task() {                # <id> <trigger> <dep> [retry.max]
    { echo "schema_version=2"; echo "id=$1"; echo "name=$1"; echo "enabled=1"
      echo "trigger=$2"; echo "condition="; echo "dependency=$3"
      echo "action.type=command"; echo "action.command=echo cg-$1"
      echo "action.notify_start=0"; echo "action.notify_end=0"; echo "action.delete=0"
      echo "action.termux=0"; echo "action.interactive=0"; echo "action.run_once_now=0"
      echo "action.boot=0"; echo "action.msg="; echo "health.type=none"
      echo "recovery.type=none"; echo "retry.max=${4:-0}"; echo "retry.interval=60"
    } > "$CG_TCFG/$1.task"
}
cgetick() {
    CG_SEQ=$((CG_SEQ + 1)); SCHED_CYCLE_NOW="20260908$1"; GATE_NOW=$((CG_EPOCH + CG_SEQ * 60))
    state_sync_all "$CG_TASKS" >/dev/null 2>&1
    scheduler_tick "$CG_BASE" "$CG_CFG" "$CG_TASKS" "$1" >/dev/null 2>&1
    state_sync_all "$CG_TASKS" >/dev/null 2>&1
    SCHED_CYCLE_NOW=""; GATE_NOW=""
}

cg_new   # G1：单节点崩溃循环——retry 钳制（1+max 次）、传播不接退避、链零重放、有限步收敛
cg_task cg1r 0830 ""
cg_task cg1b chain cg1r 2          # 崩溃-重试-崩溃-重试-崩溃（共 3 次执行）后终局
cg_task cg1c chain cg1b 3          # 传播失败：retry.max=3 亦不接退避（D25/D53）
touch "$CG_FAILDIR/cg1b"
cgetick 0830                                # 根执行并 mark
CG_G1_N=0
while [ "$CG_G1_N" -lt 8 ]; do
    CG_G1_N=$((CG_G1_N + 1))
    cgetick "083$CG_G1_N"
    grep -q '^state=FAILED$' "$CG_BASE/dag/cg1r/runs/202609080830/run.txt" 2>/dev/null && break
done
rf1="$CG_BASE/dag/cg1r/runs/202609080830/run.txt"
CG_B_EX=$(grep -c '^cg1b$' "$CG_EXEC" | tr -d ' ')
CG_C_EX=$(grep -c '^cg1c$' "$CG_EXEC" | tr -d ' ')
CG_A1=$(grep -c 'op=retry|task=cg1b|action=backoff|attempt=1|max=2' "$CG_BASE/scheduler/audit.log" | tr -d ' ')
CG_A2=$(grep -c 'op=retry|task=cg1b|action=backoff|attempt=2|max=2' "$CG_BASE/scheduler/audit.log" | tr -d ' ')
CG_A3=$(grep -c 'attempt=3|max=2' "$CG_BASE/scheduler/audit.log" | tr -d ' ')
if [ "$CG_B_EX" = "3" ] && [ "$CG_A1" = "1" ] && [ "$CG_A2" = "1" ] && [ "$CG_A3" = "0" ] \
   && [ "$CG_C_EX" = "0" ] && [ -f "$CG_TASKS/cg1c/gate.fail" ] && [ ! -f "$CG_TASKS/cg1c/retry.until" ] \
   && grep -q '^state=FAILED$' "$rf1" \
   && [ "$(ls "$CG_BASE/dag/cg1r/runs" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "P6-07 G1: 崩溃循环 × retry 钳制（b 恰 1+2 次执行、backoff 仅 attempt=1,2 各一次、无 attempt≥3）× 传播不接退避（c 零执行无 until）× 链零重放（run 恒 1）× ≤$CG_G1_N tick 收敛 FAILED（检查项6）"
else
    bad "P6-07 G1 联动异常 b=$CG_B_EX a1=$CG_A1 a2=$CG_A2 a3=$CG_A3 c=$CG_C_EX st=$(grep '^state=' "$rf1" 2>/dev/null) ticks=$CG_G1_N"
fi
# 终局后再多跑 4 tick：不得复活（无无限链式触发；FAILED 粘滞）
cgetick 0839; cgetick 0840; cgetick 0841; cgetick 0842
CG_B2=$(grep -c '^cg1b$' "$CG_EXEC" | tr -d ' ')
CG_RUNS2=$(ls "$CG_BASE/dag/cg1r/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$CG_B2" = "3" ] && [ "$CG_RUNS2" = "1" ] && grep -q '^state=FAILED$' "$rf1"; then
    ok "P6-07 G1b: 收敛后 4 tick 零复活（b 执行数/run 数/run 态全粘滞，无死循环，检查项6）"
else
    bad "P6-07 G1b 粘滞破坏 b=$CG_B2 runs=$CG_RUNS2"
fi

cg_new   # G2：环外最坏图（深度 6 长梯全节点崩溃、各带 retry.max=1）——有限步收敛
cg_task cg2r 0830 ""
CG2_PREV=cg2r; CG2_I=1
while [ "$CG2_I" -le 6 ]; do
    CG2_CUR=$(printf 'cg2n%d' "$CG2_I")
    cg_task "$CG2_CUR" chain "$CG2_PREV" 1
    touch "$CG_FAILDIR/$CG2_CUR"
    CG2_PREV=$CG2_CUR; CG2_I=$((CG2_I + 1))
done
cgetick 0830                                # 根执行并 mark
CG_G2_N=1
while [ "$CG_G2_N" -le 14 ]; do
    cgetick "$(printf '08%02d' $((30 + CG_G2_N)))"
    grep -q '^state=FAILED$' "$CG_BASE/dag/cg2r/runs/202609080830/run.txt" 2>/dev/null && break
    CG_G2_N=$((CG_G2_N + 1))
done
rf2="$CG_BASE/dag/cg2r/runs/202609080830/run.txt"
CG2_EXEC_MAX=0; CG2_K=1
while [ "$CG2_K" -le 6 ]; do
    CG2_CNT=$(grep -c "^cg2n$CG2_K$" "$CG_EXEC" | tr -d ' ')
    [ "$CG2_CNT" -gt "$CG2_EXEC_MAX" ] && CG2_EXEC_MAX=$CG2_CNT
    CG2_K=$((CG2_K + 1))
done
CG2_NONTERM=$(awk -F'|' 'NR>5 && ($3=="PENDING"||$3=="RUNNING") {n++} END{print n+0}' "$rf2" 2>/dev/null)
if grep -q '^state=FAILED$' "$rf2" && [ "$CG2_EXEC_MAX" -le 2 ] && [ "$CG2_NONTERM" = "0" ] \
   && [ "$(ls "$CG_BASE/dag/cg2r/runs" | wc -l | tr -d ' ')" = "1" ]; then
    ok "P6-07 G2: 长梯全崩溃 ≤$CG_G2_N tick 收敛 FAILED（单节点执行≤$CG2_EXEC_MAX≤1+max、无永久 waiting/在途、run 数 1，检查项6）"
else
    bad "P6-07 G2 收敛异常 st=$(grep '^state=' "$rf2" 2>/dev/null) maxexec=$CG2_EXEC_MAX nonterm=$CG2_NONTERM ticks=$CG_G2_N"
fi

cg_new   # G3：daemon Crash Loop guard × 活跃 run——降级窗口引擎零活动，恢复后账本前滚完成
export CRASH_THRESHOLD=2 CRASH_MIN_START_INTERVAL=0 CRASH_COOLDOWN=300
cg_task cg3r 0830 ""
cg_task cg3b chain cg3r
cg_task cg3c chain cg3b
touch "$CG_SLOWDIR/cg3b"
cgetick 0830; cgetick 0831                 # run 登记，b 在途
rf3="$CG_BASE/dag/cg3r/runs/202609080830/run.txt"
CG3_MD_A=$(md5sum "$rf3" | cut -d' ' -f1)
CG3_EX_A=$(wc -l < "$CG_EXEC" | tr -d ' ')
crash_guard_enter "$CG_BASE" >/dev/null 2>&1
crash_guard_enter "$CG_BASE" >/dev/null 2>&1
CG3_RC=0
crash_guard_enter "$CG_BASE" >/dev/null 2>&1 || CG3_RC=$?
CG3_RC2=0
crash_guard_enter "$CG_BASE" >/dev/null 2>&1 || CG3_RC2=$?
CG3_MD_B=$(md5sum "$rf3" | cut -d' ' -f1)
CG3_EX_B=$(wc -l < "$CG_EXEC" | tr -d ' ')
if [ "$CG3_RC" = "2" ] && [ "$CG3_RC2" = "2" ] \
   && [ "$CG3_MD_A" = "$CG3_MD_B" ] && [ "$CG3_EX_A" = "$CG3_EX_B" ]; then
    ok "P6-07 G3: 崩溃序列达阈值 → rc2 降级且窗口内快速退出；降级期间 run.txt 逐字节静止、零派发（引擎仅 tick 驱动，检查项6）"
else
    bad "P6-07 G3 降级窗口越界 rc=$CG3_RC/$CG3_RC2 md=$CG3_MD_A/$CG3_MD_B ex=$CG3_EX_A/$CG3_EX_B"
fi
# 窗口过期恢复（有界模拟：直接回写 degraded_until，同 §5 时序操控手法）
g3f=$(crash_guard_file "$CG_BASE")
crash_write "$g3f" degraded_until 1
CG3_RC=0
crash_guard_enter "$CG_BASE" >/dev/null 2>&1 || CG3_RC=$?
crash_record_exit "$CG_BASE" 0 >/dev/null 2>&1
rm -f "$CG_SLOWDIR/cg3b"; echo 0 > "$CG_TASKS/cg3b/exit_code.txt"
cgetick 0832; cgetick 0833; cgetick 0834
CG3_B_EX=$(grep -c '^cg3b$' "$CG_EXEC" | tr -d ' ')
if [ "$CG3_RC" = "0" ] && grep -q '^state=SUCCESS$' "$rf3" && [ "$CG3_B_EX" = "1" ]; then
    ok "P6-07 G3b: guard 放行恢复后 tick 继续推进 run 至 SUCCESS；b 总执行仍 1 次（账本 disp 幂等，无重启重放，检查项6/7）"
else
    bad "P6-07 G3b 恢复异常 rc=$CG3_RC st=$(grep '^state=' "$rf3" 2>/dev/null) b=$CG3_B_EX"
fi
unset CRASH_THRESHOLD CRASH_MIN_START_INTERVAL CRASH_COOLDOWN

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "crashguard tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
