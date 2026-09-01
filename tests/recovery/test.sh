#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Recovery / Retry / Cooldown（P2-13）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-13 出口：Shizuku/GKD/Node/Python/Rust 服务场景自动恢复）：
#   1) 入口：§17 supervisor_recover / supervisor_stop_task 就位；selfcheck 锚点。
#   2) 策略钳制（禁止无限重启）：retry.max 非法/负值 → 0、>100 → 100（硬上限）；
#      retry.interval / retry.cooldown 非法 → 缺省 60/0。
#   3) 恢复动作（真实 nc）：
#      restart  — 停既有进程（TERM→KILL）→ 重跑 action → 恢复 → HEALTHY（旧进程必死）；
#      stopstart — 优雅停（TERM）→ 重跑 → HEALTHY；
#      start    — 直接重跑（默认语义，P2-12 回归）；
#      script   — 执行 recovery.script（绝对路径）→ 恢复 → HEALTHY。
#   4) max_retry：retry.max=2 + 恢复持续失败 → 恰好 2 次尝试后 FAILED
#      （retry-exhausted；无第 3 次——重启次数受限）。
#   5) 基础 cooldown：FAILED 后 cooldown_until 写入（未来）；cooldown 内重标
#      RUNNING 被跳过（不监督）；到期后恢复监督 → HEALTHY。
#   6) 无 action 且非 script → FAILED（no-action-for-recovery）+ cooldown。
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
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB
# P2-14：健康探针最小间隔节流对恢复闭环逐 tick 探活不产生扰动
export HEALTH_MIN_INTERVAL=0

pick_free_port() {
    p=38000
    while [ "$p" -lt 38500 ]; do
        hexp=$(printf '%04X' "$p")
        if awk -v h="$hexp" '$4=="0A" && $2 ~ ":" h "$" { n++ } END { exit n>0 }' /proc/net/tcp 2>/dev/null; then
            echo "$p"; return 0
        fi
        p=$((p + 1))
    done
    echo ""
}
mk_snapshot() {   # <base> <taskfile-lines...>
    base=$1
    mkdir -p "$base/snapshots/snap_1"
    shift
    printf '%s\n' "$@" > "$base/snapshots/snap_1/t50_8080.task"
    echo "snap_1" > "$base/current"
}
mk_run() {   # <tasks_dir> <state>
    tasks=$1
    mkdir -p "$tasks/t50_8080"
    echo "$2" > "$tasks/t50_8080/state.txt"
    echo "$2" > "$tasks/t50_8080/status.txt"
}

# ── 1) 入口 ────────────────────────────────────────────────────────────────
n=$(grep -cE '^supervisor_(recover|stop_task)\(' "$RTLIB")
[ "$n" -eq 2 ] && ok "P2-13 entry: supervisor_recover + supervisor_stop_task defined" || bad "P2-13 entry: recover funcs count=$n (expect 2)"
grep -q 'supervisor_recover' "$RTLIB" && grep -q 'recovery.cooldown_until' "$RTLIB" && ok "P2-13 entry: recovery dispatch + cooldown artifact wired" || bad "P2-13 entry: cooldown/recover missing"

# ── 2) 策略钳制（禁止无限重启）──────────────────────────────────────────────
PT="$T/policy.task"
printf 'retry.max=-1\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_max" = "0" ] && ok "P2-13 policy: retry.max=-1 → clamped 0" || bad "P2-13 policy: max=$retry_max"
printf 'retry.max=abc\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_max" = "0" ] && ok "P2-13 policy: retry.max=abc → clamped 0" || bad "P2-13 policy: max=$retry_max"
printf 'retry.max=999999\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_max" = "100" ] && ok "P2-13 policy: retry.max=999999 → hard cap 100 (bounded)" || bad "P2-13 policy: max=$retry_max"
printf 'retry.max=3\nretry.interval=abc\nretry.cooldown=abc\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_interval" = "60" ] && [ "$retry_cooldown" = "0" ] && ok "P2-13 policy: invalid interval/cooldown → defaults 60/0" || bad "P2-13 policy: interval=$retry_interval cooldown=$retry_cooldown"
printf 'retry.cooldown=45\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_cooldown" = "45" ] && ok "P2-13 policy: retry.cooldown=45 honored" || bad "P2-13 policy: cooldown=$retry_cooldown"

# ── 3) 恢复动作（真实 nc）──────────────────────────────────────────────────
if command -v nc >/dev/null 2>&1; then
    # restart：旧进程必死 + 重跑 → 恢复
    P1=$(pick_free_port)
    BASE="$T/restart/base"; TASKS="$T/restart/tasks"
    mkdir -p "$TASKS"
    mk_snapshot "$BASE" \
        "schema_version=2" "id=t50_8080" "name=r" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $P1" "health.type=port" "health.target=$P1" \
        "recovery.type=restart" "retry.max=2" "retry.interval=0"
    registry_attach "$BASE" >/dev/null 2>&1
    mk_run "$TASKS" RECOVERING
    nc -l 127.0.0.1 "$P1" >/dev/null 2>&1 &
    OLDPID=$!
    echo "$OLDPID" > "$TASKS/t50_8080/pid.txt"
    export TPR_ACTION_DIR="$TASKS"
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ ! -d "/proc/$OLDPID" ] && ok "P2-13 restart: old task process killed (TERM→KILL)" || bad "P2-13 restart: old pid still alive"
    [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-13 restart: relaunched → RUNNING" || bad "P2-13 restart: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
    up=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
        [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && ok "P2-13 restart: Restart Action recovered → HEALTHY" || bad "P2-13 restart: not HEALTHY (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    for p in $(pgrep -f "nc -l 127.0.0.1 $P1" 2>/dev/null); do kill "$p" 2>/dev/null; done

    # stopstart：优雅停 → 重跑 → 恢复
    P2=$(pick_free_port)
    BASE="$T/ss/base"; TASKS="$T/ss/tasks"
    mkdir -p "$TASKS"
    mk_snapshot "$BASE" \
        "schema_version=2" "id=t50_8080" "name=s" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $P2" "health.type=port" "health.target=$P2" \
        "recovery.type=stopstart" "retry.max=2" "retry.interval=0"
    registry_attach "$BASE" >/dev/null 2>&1
    mk_run "$TASKS" RECOVERING
    nc -l 127.0.0.1 "$P2" >/dev/null 2>&1 &
    OLDPID=$!
    echo "$OLDPID" > "$TASKS/t50_8080/pid.txt"
    TPR_ACTION_DIR="$TASKS"
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ ! -d "/proc/$OLDPID" ] && ok "P2-13 stopstart: stopped then relaunched" || bad "P2-13 stopstart: old pid alive"
    [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-13 stopstart: → RUNNING" || bad "P2-13 stopstart: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
    for p in $(pgrep -f "nc -l 127.0.0.1 $P2" 2>/dev/null); do kill "$p" 2>/dev/null; done

    # script：Execute Script → 恢复
    P3=$(pick_free_port)
    BASE="$T/script/base"; TASKS="$T/script/tasks"
    mkdir -p "$TASKS"
    SCR="$T/recover.sh"
    cat > "$SCR" <<EOF
#!/usr/bin/env bash
echo "recovered at \$(date)" >> "$T/script/marker.log"
nc -l 127.0.0.1 $P3 >/dev/null 2>&1 &
exit 0
EOF
    chmod +x "$SCR"
    mk_snapshot "$BASE" \
        "schema_version=2" "id=t50_8080" "name=sc" "enabled=1" "trigger=08:00" \
        "action.command=" "health.type=port" "health.target=$P3" \
        "recovery.type=script" "recovery.script=$SCR" "retry.max=2" "retry.interval=0"
    registry_attach "$BASE" >/dev/null 2>&1
    mk_run "$TASKS" RECOVERING
    TPR_ACTION_DIR="$TASKS"
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ -f "$T/script/marker.log" ] && ok "P2-13 script: recovery script executed" || bad "P2-13 script: script not run"
    up=0; i=0
    while [ "$i" -lt 10 ]; do
        supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
        [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && ok "P2-13 script: Execute Script recovery → HEALTHY" || bad "P2-13 script: not HEALTHY (state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null))"
    for p in $(pgrep -f "nc -l 127.0.0.1 $P3" 2>/dev/null); do kill "$p" 2>/dev/null; done

    # start（默认语义，P2-12 回归）
    P4=$(pick_free_port)
    BASE="$T/start/base"; TASKS="$T/start/tasks"
    mkdir -p "$TASKS"
    mk_snapshot "$BASE" \
        "schema_version=2" "id=t50_8080" "name=st" "enabled=1" "trigger=08:00" \
        "action.command=nc -l 127.0.0.1 $P4" "health.type=port" "health.target=$P4" \
        "recovery.type=start" "retry.max=2" "retry.interval=0"
    registry_attach "$BASE" >/dev/null 2>&1
    mk_run "$TASKS" RECOVERING
    TPR_ACTION_DIR="$TASKS"
    supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
    [ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-13 start: Start Action (default semantics) → RUNNING" || bad "P2-13 start: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
    for p in $(pgrep -f "nc -l 127.0.0.1 $P4" 2>/dev/null); do kill "$p" 2>/dev/null; done
else
    ok "P2-13 recovery: nc unavailable — real recovery-action cases not exercised (policy/cooldown covered)"
fi

# ── 4) max_retry：恰 2 次尝试后 FAILED（重启次数受限）────────────────────────
BASE="$T/mr/base"; TASKS="$T/mr/tasks"
mkdir -p "$TASKS"
SCRF="$T/fail.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SCRF"
chmod +x "$SCRF"
mk_snapshot "$BASE" \
    "schema_version=2" "id=t50_8080" "name=mr" "enabled=1" "trigger=08:00" \
    "action.command=" "health.type=port" "health.target=59995" \
    "recovery.type=script" "recovery.script=$SCRF" "retry.max=2" "retry.interval=0"
registry_attach "$BASE" >/dev/null 2>&1
mk_run "$TASKS" RECOVERING
TPR_ACTION_DIR="$TASKS"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/recovery.count" 2>/dev/null)" = "1" ] && ok "P2-13 max_retry: attempt 1 made (count=1)" || bad "P2-13 max_retry: count=$(cat "$TASKS/t50_8080/recovery.count" 2>/dev/null)"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/recovery.count" 2>/dev/null)" = "2" ] && ok "P2-13 max_retry: attempt 2 made (count=2)" || bad "P2-13 max_retry: count=$(cat "$TASKS/t50_8080/recovery.count" 2>/dev/null)"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-13 max_retry: exceeded → FAILED (no 3rd attempt — bounded)" || bad "P2-13 max_retry: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
tail -1 "$TASKS/t50_8080/events.log" 2>/dev/null | grep -q 'retry-exhausted' && ok "P2-13 max_retry: event retry-exhausted (max=2)" || bad "P2-13 max_retry: event missing"

# ── 5) 基础 cooldown ───────────────────────────────────────────────────────
P5=$(pick_free_port)
BASE="$T/cd/base"; TASKS="$T/cd/tasks"
mkdir -p "$TASKS"
mk_snapshot "$BASE" \
    "schema_version=2" "id=t50_8080" "name=cd" "enabled=1" "trigger=08:00" \
    "action.command=nc -l 127.0.0.1 $P5" "health.type=port" "health.target=$P5" \
    "recovery.type=start" "retry.max=0" "retry.interval=0" "retry.cooldown=60"
registry_attach "$BASE" >/dev/null 2>&1
mk_run "$TASKS" RECOVERING
TPR_ACTION_DIR="$TASKS"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-13 cooldown: retry.max=0 → FAILED" || bad "P2-13 cooldown: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
cdu=$(cat "$TASKS/t50_8080/recovery.cooldown_until" 2>/dev/null)
[ -n "$cdu" ] && [ "$cdu" -gt "$(date +%s)" ] && ok "P2-13 cooldown: cooldown_until written in future ($cdu)" || bad "P2-13 cooldown: cooldown_until=[$cdu]"
# cooldown 内重标 RUNNING → 被跳过（不监督）
nc -l 127.0.0.1 "$P5" >/dev/null 2>&1 &
NCPID=$!
echo RUNNING > "$TASKS/t50_8080/state.txt"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-13 cooldown: re-marked RUNNING skipped during cooldown (no supervision)" || bad "P2-13 cooldown: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
# 到期后恢复监督 → HEALTHY
echo "$(( $(date +%s) - 10 ))" > "$TASKS/t50_8080/recovery.cooldown_until"
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "HEALTHY" ] && ok "P2-13 cooldown: expired → supervision resumed → HEALTHY" || bad "P2-13 cooldown: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"
kill "$NCPID" 2>/dev/null

# ── 6) 无 action 且非 script → FAILED（no-action-for-recovery）+ cooldown ──
BASE="$T/na/base"; TASKS="$T/na/tasks"
mkdir -p "$TASKS"
mk_snapshot "$BASE" \
    "schema_version=2" "id=t50_8080" "name=na" "enabled=1" "trigger=08:00" \
    "action.command=" "health.type=port" "health.target=59994" \
    "recovery.type=none" "retry.max=2" "retry.interval=0" "retry.cooldown=30"
registry_attach "$BASE" >/dev/null 2>&1
mk_run "$TASKS" RECOVERING
supervisor_step "$TASKS/t50_8080" "$BASE/snapshots/snap_1/t50_8080.task" >/dev/null 2>&1
[ "$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)" = "FAILED" ] && [ -f "$TASKS/t50_8080/recovery.cooldown_until" ] \
    && ok "P2-13 no-action: no action + non-script → FAILED (no-action-for-recovery) + cooldown" || bad "P2-13 no-action: state=$(cat "$TASKS/t50_8080/state.txt" 2>/dev/null)"

# ── 7) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-13 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §17 P2-13)" || bad "P2-13 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-13 POSIX: bash -n ok (dash unavailable)" || bad "P2-13 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "recovery tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1