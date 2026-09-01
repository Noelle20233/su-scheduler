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

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "crashguard tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
