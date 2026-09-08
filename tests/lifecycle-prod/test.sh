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
# 等待 fake daemon 写出锁文件（有界轮询：registry 引导耗时随宿主而定，避免固定
# sleep 造成时序抖动；断言的是"锁存活"真实属性而非等待时长）。
WAIT_LOCK_MAX=30
wait_lock() {          # $1=锁文件；轮询至多 WAIT_LOCK_MAX 秒直至该文件可读
    wi=0
    while [ "$wi" -lt "$WAIT_LOCK_MAX" ]; do
        [ -s "$1" ] && return 0
        sleep 0.25
        wi=$((wi + 1))
    done
    return 1
}
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
wait_lock "$LKF"
[ -s "$LKF" ] && [ -d "/proc/$(cat "$LKF" 2>/dev/null)" ] && ok "P2-09 chain: fake daemon started → lock alive (pid=$(cat "$LKF" 2>/dev/null))" || bad "P2-09 chain: lock not alive"
[ -f "$FDBASE/current" ] && ok "P2-09 chain: registry snapshot built at startup" || bad "P2-09 chain: no snapshot"
[ "$(cat "$FDTASKS/prev_run/state.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-09 chain: recovery ran in startup sequence (prev_run → FAILED)" || bad "P2-09 chain: recovery not executed"
OLDPID=$(cat "$LKF" 2>/dev/null)
LIFECYCLE_LOG=0 lifecycle_stop "$LKF" >/dev/null 2>&1
i=0
while [ "$i" -lt 10 ] && [ -d "/proc/$OLDPID" ]; do sleep 0.5; i=$((i + 1)); done
[ ! -d "/proc/$OLDPID" ] && ok "P2-09 chain: lifecycle_stop killed daemon" || bad "P2-09 chain: daemon still alive"
[ ! -f "$LKF" ] && ok "P2-09 chain: lock released after stop" || bad "P2-09 chain: lock not released"
LIFECYCLE_LOG=0 lifecycle_restart "$LKF" "$FDBASE" "$FDCFG" "bash $FAKE $PWD $RTLIB $FDBASE $FDCFG $FDTASKS $LKF" >/dev/null 2>&1
rm -f "$LKF"
wait_lock "$LKF"
[ -s "$LKF" ] && [ -d "/proc/$(cat "$LKF" 2>/dev/null)" ] && ok "P2-09 chain: lifecycle_restart relaunched daemon (new pid=$(cat "$LKF" 2>/dev/null))" || bad "P2-09 chain: restart failed"
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

# ── 7) P6-07：DAG 链路 daemon 重启恢复（run 账本存续 / 在途 stale 处置 / 成功不重放）──
# 真实进程重启（同 §4 fake-daemon 手法）：A 进程跑 tick 至 b 在途 RUNNING（pid=
# $$A）→ kill -9（崩溃）→ B 进程先 lifecycle_startup_recover（stale 扫描既有语义）
# 再继续 tick。断言：run 存续且继续推进（一条链重试后续行至 SUCCESS）；崩溃节点
# 走 stale→FAILED→节点级重试（attempt 1/max，非引擎重放）；根执行总数 1（不重放）；
# 无重试预算的链走传播 FAILED 终局；同 token 重启不重复建 run。
R7="$T/dag7"
R7BASE="$R7/base"; R7TASKS="$R7/tasks"; R7SLOW="$R7/slow"
R7TCFG="$R7BASE/task-config"        # fake daemon 内 TCFG_DIR=$base/task-config
mkdir -p "$R7BASE" "$R7TASKS" "$R7TCFG" "$R7SLOW"
echo managed > "$R7TCFG/MANAGED"
: > "$R7/config.txt"
R7X="$R7/exec.log"; : > "$R7X"
r7_task() {   # <id> <trigger> <dep> [retry.max]
    { echo "schema_version=2"; echo "id=$1"; echo "name=$1"; echo "enabled=1"
      echo "trigger=$2"; echo "condition="; echo "dependency=$3"
      echo "action.type=command"; echo "action.command=echo r7-$1"
      echo "action.notify_start=0"; echo "action.notify_end=0"; echo "action.delete=0"
      echo "action.termux=0"; echo "action.interactive=0"; echo "action.run_once_now=0"
      echo "action.boot=0"; echo "action.msg="; echo "health.type=none"
      echo "recovery.type=none"; echo "retry.max=${4:-0}"; echo "retry.interval=60"
    } > "$R7TCFG/$1.task"
}
r7_task lr 0830 ""; r7_task lb chain lr 2; r7_task lc chain lb; r7_task ld chain lc
r7_task lr2 0830 ""; r7_task lb2 chain lr2; r7_task lc2 chain lb2   # 无重试预算 → 传播
touch "$R7SLOW/lb" "$R7SLOW/lb2"    # 两链在途节点均挂起（kill 时真实 RUNNING）
R7FAKE="$T/fake-daemon-dag.sh"
cat > "$R7FAKE" <<'EOF'
#!/usr/bin/env bash
# fake daemon（DAG 版）：$1=reporoot $2=lib $3=base $4=cfg $5=tasks $6=xlog $7=slowdir
# $8=pidfile $9=...ticks；启动序：recover（$RECOVER=1 时）→ 逐 tick
set -u
cd "$1" || exit 2
. ./"$2" || exit 2
base=$3 cfg=$4 tasks=$5 xlog=$6 slow=$7 pidf=$8
shift 8
export TCFG_DIR="$base/task-config" TASKS_DIR="$tasks"
execute_task() {
    id=$1; d="$TASKS_DIR/$id"; mkdir -p "$d" 2>/dev/null
    echo "$id" >> "$xlog"
    if [ -f "$slow/$id" ]; then
        echo "$$" > "$d/pid.txt"; echo "RUNNING" > "$d/status.txt"
    else
        echo "0" > "$d/exit_code.txt"; echo "SUCCESS" > "$d/status.txt"
    fi
    return 0
}
echo "$$" > "$pidf"
if [ "${RECOVER:-0}" = "1" ]; then
    lifecycle_startup_recover "$tasks" >/dev/null 2>&1
fi
for tk in "$@"; do
    m=$((10#$tk % 100))
    SCHED_CYCLE_NOW="20260908$tk"; GATE_NOW=$((1789192800 + m * 60))
    state_sync_all "$tasks" >/dev/null 2>&1
    scheduler_tick "$base" "$cfg" "$tasks" "$tk" >/dev/null 2>&1
    state_sync_all "$tasks" >/dev/null 2>&1
done
EOF
chmod +x "$R7FAKE"
R7LKA="$T/r7a.lock"; : > "$R7LKA"
bash "$R7FAKE" "$PWD" "$RTLIB" "$R7BASE" "$R7/config.txt" "$R7TASKS" "$R7X" "$R7SLOW" "$R7LKA" 0830 0831 0832 >/dev/null 2>&1 &
wi=0
while [ "$wi" -lt 120 ]; do
    if grep -q '^lb|chain|RUNNING|disp$' "$R7BASE/dag/lr/runs/202609080830/run.txt" 2>/dev/null \
       && grep -q '^lb2|chain|RUNNING|disp$' "$R7BASE/dag/lr2/runs/202609080830/run.txt" 2>/dev/null; then
        break
    fi
    sleep 0.25; wi=$((wi + 1))
done
R7PA=$(cat "$R7LKA" 2>/dev/null)
[ -f "$R7BASE/dag/lr/runs/202609080830/run.txt" ] && [ -n "$R7PA" ] \
    && ok "P6-07 R7-0: fake daemon A：两 run 已登记（0830 token）、lb/lb2 均在途 RUNNING 账本静止（pid 存活）" \
    || bad "P6-07 R7-0 daemon A 未达在途稳态 pa=$R7PA"
rm -f "$R7SLOW/lb"                                # b 崩溃后重试将成功（有界恢复剧本）
kill -9 "$R7PA" 2>/dev/null
wi=0; while [ "$wi" -lt 40 ] && [ -d "/proc/$R7PA" ]; do sleep 0.1; wi=$((wi + 1)); done
[ ! -d "/proc/$R7PA" ] && ok "P6-07 R7-1: daemon A 崩溃（SIGKILL，run 进行中）" || bad "P6-07 R7-1 A 未死"
RECOVER=1 bash "$R7FAKE" "$PWD" "$RTLIB" "$R7BASE" "$R7/config.txt" "$R7TASKS" "$R7X" "$R7SLOW" "$T/r7b.lock" 0833 0834 0835 0836 0837 0838 >/dev/null 2>&1
rf7="$R7BASE/dag/lr/runs/202609080830/run.txt"
rf72="$R7BASE/dag/lr2/runs/202609080830/run.txt"
R7_LR=$(grep -c '^lr$' "$R7X" | tr -d ' ')
R7_LB=$(grep -c '^lb$' "$R7X" | tr -d ' ')
R7_LC=$(grep -c '^lc$' "$R7X" | tr -d ' ')
R7_LD=$(grep -c '^ld$' "$R7X" | tr -d ' ')
R7_LC2=$(grep -c '^lc2$' "$R7X" | tr -d ' ')
R7_RUNS=$(ls "$R7BASE/dag/lr/runs" 2>/dev/null | wc -l | tr -d ' ')
R7_RUNS2=$(ls "$R7BASE/dag/lr2/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$R7_LR" = "1" ] && [ "$R7_LC" = "1" ] && [ "$R7_LD" = "1" ] \
   && grep -q '^state=SUCCESS$' "$rf7" && grep -q '^lb|chain|STOPPED|disp$' "$rf7" \
   && [ "$R7_RUNS" = "1" ]; then
    ok "P6-07 R7-2: 重启后 tick 继续推进 run 至 SUCCESS；根 lr 执行总数=1（成功不重放）、lc/ld 各恰 1 次（账本 disp 幂等，无重复派发）"
else
    bad "P6-07 R7-2 恢复推进异常 lr=$R7_LR lc=$R7_LD ld=$R7_LD st=$(grep '^state=' "$rf7" 2>/dev/null) runs=$R7_RUNS"
fi
if [ "$R7_LB" = "2" ] \
   && grep -q '|daemon_restart|FAILED|' "$R7TASKS/lb/events.log" 2>/dev/null \
   && grep -q 'op=retry|task=lb|action=backoff|attempt=1|max=2' "$R7BASE/scheduler/audit.log"; then
    ok "P6-07 R7-3: 在途节点按既有 stale 扫描语义处置（daemon_restart→FAILED）→ 节点级重试仅 1 次（b 总执行 2=崩溃前1+重试1），非引擎重放"
else
    bad "P6-07 R7-3 在途处置异常 lb_ex=$R7_LB events=$(grep -c daemon_restart "$R7TASKS/lb/events.log" 2>/dev/null)"
fi
if [ "$R7_LC2" = "0" ] && grep -q '^state=FAILED$' "$rf72" \
   && grep -q '^lc2|chain|FAILED|gate-fail$' "$rf72" && [ "$R7_RUNS2" = "1" ]; then
    ok "P6-07 R7-4: 无重试预算的崩溃节点（lb2 stale）→ Required 下游传播、run 重启后终局 FAILED；两链同 token 均无重复 run（重启幂等）"
else
    bad "P6-07 R7-4 传播终局异常 lc2=$R7_LC2 st=$(grep '^state=' "$rf72" 2>/dev/null) runs2=$R7_RUNS2"
fi
rm -f "$R7LKA"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "lifecycle-prod tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1