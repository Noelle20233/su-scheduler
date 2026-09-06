#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P3-07 Task 控制操作（WebUI 与 CLI 共用同一控制 API）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P3-07 出口）：
#   1) 入口/接线：§24 tctl_* 定义 + selfcheck 注册；CLI task 控制子命令
#      （enable/disable/start/stop/restart/check/logs）+ 帮助行；IPC 白名单
#      CHECK_TASK（19 op）。
#   2) 状态机强制：start 经 PENDING→STARTING→RUNNING（manual_exec+spawn 可追踪）；
#      stop 经 RUNNING→STOPPING→STOPPED；FAILED/STOPPED 重武装→PENDING；非法操作
#      （STOPPING 中 start）→ 错误且 state.txt 不变（不强行写状态文件）。
#   3) 并发 start skip 策略：已 RUNNING/STARTING → 不重复启动（exec 保持 1）。
#   4) stop 不误杀其他任务：只杀本运行目录 pid。
#   5) 旧运行 ID 控制旧运行目录（§9 idmap 解析）。
#   6) check 立即健康检查：三态行 + probe 事件（不改 state.txt）；无 health →
#      no_health_configured。
#   7) logs 查询任务日志；enable/disable 修改配置状态（仅 managed）+ reload。
#   8) CLI 子命令经 IPC 全链路（同一控制 API）：cmd_task start/stop/check/logs
#      走 fake daemon 轮询 → §24 tctl_* → 可追踪输出。
#   9) 操作失败不破坏 Registry / 旧工件：非法 op 前后 task-config md5 不变、
#      status.txt/pid.txt/output.log 逐字节不变。
#  10) POSIX：库（含 §24）dash -n（LF 归一，规避 CRLF 检出）。
# 加载：`. ./$RTLIB`（daemon 上下文 shim：execute_task 记录 EXEC_LOG）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
DAEMON="system/bin/su-schedulerd"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── daemon 上下文 shim：execute_task 真实后台子进程（可被 kill / 追踪）──────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"      # 每次执行：<id>|<cmd>
execute_task() {            # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    # 真实可观察子进程（sleep 挂起 → stop 可 kill）
    ( sleep 30 > "$d/output.log" 2>&1 ) &
    echo $! > "$d/pid.txt"
    echo "$id|$cmd" >> "$EXEC_LOG"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"

# task-config 快照 md5（排除 MANAGED 标记）：Registry/配置不被破坏的断言依据
tc_snap() { find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1; }

# ── 1) 入口 + 接线 ─────────────────────────────────────────────────────────
fn_miss=0
for fn in tctl_resolve tctl_state tctl_start tctl_stop tctl_restart tctl_check \
          tctl_logs tctl_set_enabled ipc_op_check; do
    type "$fn" >/dev/null 2>&1 || { bad "P3-07 entry: $fn missing"; fn_miss=1; }
done
[ "$fn_miss" -eq 0 ] && ok "P3-07 entry: §24 tctl_* + ipc_op_check defined"

sel=$(sed -n '/^runtime_lib_selfcheck()/,/^}/p' "$RTLIB")
sel_miss=0
for fn in tctl_start tctl_stop tctl_restart tctl_check tctl_logs tctl_set_enabled ipc_op_check; do
    printf '%s\n' "$sel" | grep -q "$fn" || sel_miss=$((sel_miss + 1))
done
[ "$sel_miss" -eq 0 ] && ok "P3-07 entry: §24 funcs registered in runtime_lib_selfcheck" || bad "P3-07 entry: $sel_miss selfcheck misses"

grep -q 'CHECK_TASK' <<< "$IPC_WHITELIST" && [ "$(echo "$IPC_WHITELIST" | wc -w)" -eq 19 ] \
    && ok "P3-07 entry: IPC_WHITELIST 19 ops incl. CHECK_TASK" || bad "P3-07 entry: whitelist=$(echo "$IPC_WHITELIST" | wc -w) (expect 19)"

sub_miss=0
for sub in enable disable start stop restart check logs; do
    grep -q "cmd_task_${sub}()" "$CLI" || { bad "P3-07 entry: CLI cmd_task_$sub missing"; sub_miss=1; }
    grep -q "${sub}) shift; cmd_task_${sub}" "$CLI" || { bad "P3-07 entry: CLI dispatch task $sub missing"; sub_miss=1; }
done
[ "$sub_miss" -eq 0 ] && ok "P3-07 entry: CLI task enable/disable/start/stop/restart/check/logs wired"
grep -q 'task {list | status' "$CLI" && ok "P3-07 entry: help line keeps task {list|status} (P2-08 contract)" || bad "P3-07 entry: help line regressed"
for old in 'task-info' 'task-output' 'task-kill' 'tasks) cmd_tasks' 'status) cmd_status' 'stop) cmd_stop' 'restart) cmd_restart'; do
    grep -q "$old" "$CLI" || { bad "P3-07 entry: legacy CLI dispatch lost: $old"; old_miss=1; }
done
[ "${old_miss:-0}" -eq 0 ] && ok "P3-07 entry: legacy CLI commands intact (task-info/task-output/task-kill/tasks/status/stop/restart)"

# ── 准备：managed 任务 t1（可运行）+ t2（对照，验证 stop 不误杀）────────────
tcfg_new_task t1 "08:30" "echo hello" >/dev/null 2>&1
tcfg_new_task t2 "09:00" "echo other" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
SNAP0=$(tc_snap)

# ── 2) 状态机：start PENDING→STARTING→RUNNING（可追踪）─────────────────────
: > "$EXEC_LOG"
out=$(tctl_start "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q '^started t1$' \
    && ok "P3-07 start: tctl_start t1 -> started (rc 0)" || bad "P3-07 start: rc=$rc out=$out"
[ "$(cat "$TASKS_DIR/t1/state.txt" 2>/dev/null)" = "RUNNING" ] \
    && ok "P3-07 start: state.txt=RUNNING (TSM PENDING→STARTING→RUNNING)" || bad "P3-07 start: state=$(cat "$TASKS_DIR/t1/state.txt" 2>/dev/null)"
grep -q '|manual_exec|STARTING|' "$TASKS_DIR/t1/events.log" \
    && grep -q '|spawn|RUNNING|' "$TASKS_DIR/t1/events.log" \
    && ok "P3-07 start: events.log traces manual_exec STARTING + spawn RUNNING" \
    || bad "P3-07 start: events=$(cat "$TASKS_DIR/t1/events.log" 2>/dev/null | tr '\n' ';')"
[ "$(wc -l < "$EXEC_LOG")" -eq 1 ] && ok "P3-07 start: exactly 1 exec" || bad "P3-07 start: exec=$(wc -l < "$EXEC_LOG")"

# ── 3) 并发 start skip 策略 ────────────────────────────────────────────────
out=$(tctl_start "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && echo "$out" | grep -q '^skip already RUNNING' \
    && ok "P3-07 skip: concurrent start while RUNNING -> skip (rc 2)" || bad "P3-07 skip: rc=$rc out=$out"
[ "$(wc -l < "$EXEC_LOG")" -eq 1 ] && ok "P3-07 skip: no duplicate exec on concurrent start" || bad "P3-07 skip: exec=$(wc -l < "$EXEC_LOG")"

# ── 4) stop：RUNNING→STOPPING→STOPPED；不误杀其他任务 ─────────────────────
: > "$EXEC_LOG"
tctl_start "$BASE" "$TASKS_DIR" t2 >/dev/null 2>&1
P2=$(cat "$TASKS_DIR/t2/pid.txt")
out=$(tctl_stop "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q '^stopped t1$' \
    && ok "P3-07 stop: tctl_stop t1 -> stopped (rc 0)" || bad "P3-07 stop: rc=$rc out=$out"
[ "$(cat "$TASKS_DIR/t1/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P3-07 stop: state.txt=STOPPED (TSM RUNNING→STOPPING→STOPPED)" || bad "P3-07 stop: state=$(cat "$TASKS_DIR/t1/state.txt")"
grep -q '|stop_request|STOPPING|' "$TASKS_DIR/t1/events.log" \
    && grep -q '|stop_request|STOPPED|' "$TASKS_DIR/t1/events.log" \
    && ok "P3-07 stop: events.log traces stop_request STOPPING + STOPPED" \
    || bad "P3-07 stop: events=$(cat "$TASKS_DIR/t1/events.log" | tr '\n' ';')"
[ -d "/proc/$P2" ] && ok "P3-07 stop: t2 process still alive after t1 stop (no cross-kill)" \
    || bad "P3-07 stop: t2 pid $P2 died — stop killed another task!"
tctl_stop "$BASE" "$TASKS_DIR" t2 >/dev/null 2>&1

# stop 非运行任务 → not_running（不写状态）
SNAP_STOP=$(tc_snap)
out=$(tctl_stop "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'not_running' \
    && ok "P3-07 stop: stop already-stopped -> not_running (no state write)" || bad "P3-07 stop: rc=$rc out=$out"
[ "$(cat "$TASKS_DIR/t1/state.txt")" = "STOPPED" ] && ok "P3-07 stop: state still STOPPED after no-op" || bad "P3-07 stop: state mutated"

# ── 5) 重武装：FAILED/STOPPED → PENDING → STARTING → RUNNING ──────────────
printf 'FAILED\n' > "$TASKS_DIR/t2/state.txt"
out=$(tctl_start "$BASE" "$TASKS_DIR" t2 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && grep -q '|rearm|PENDING|' "$TASKS_DIR/t2/events.log" \
    && [ "$(cat "$TASKS_DIR/t2/state.txt")" = "RUNNING" ] \
    && ok "P3-07 rearm: FAILED -> PENDING (rearm) -> STARTING -> RUNNING" \
    || bad "P3-07 rearm: rc=$rc state=$(cat "$TASKS_DIR/t2/state.txt") events=$(cat "$TASKS_DIR/t2/events.log" | tr '\n' ';')"
tctl_stop "$BASE" "$TASKS_DIR" t2 >/dev/null 2>&1

# ── 5b) HEALTHY → STOPPING → STOPPED（TSM 允许边）─────────────────────────
tcfg_set_field t1 health.type process >/dev/null 2>&1
tcfg_set_field t1 health.target "$$" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
tctl_start "$BASE" "$TASKS_DIR" t1 >/dev/null 2>&1
state_log_event "$TASKS_DIR/t1" t1 supervisor HEALTHY "" "" "probe ok" >/dev/null 2>&1
out=$(tctl_stop "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$TASKS_DIR/t1/state.txt")" = "STOPPED" ] \
    && ok "P3-07 stop-healthy: HEALTHY -> STOPPING -> STOPPED (TSM edge)" \
    || bad "P3-07 stop-healthy: rc=$rc state=$(cat "$TASKS_DIR/t1/state.txt")"

# ── 6) 非法操作：STOPPING 中 start → 错误且 state.txt 不变 ────────────────
mkdir -p "$TASKS_DIR/t3"
printf 'STOPPING\n' > "$TASKS_DIR/t3/state.txt"
printf 'echo x\n' > "$TASKS_DIR/t3/command.txt"
tcfg_new_task t3 "10:00" "echo x" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
SNAP_ILLEGAL=$(tc_snap)
out=$(tctl_start "$BASE" "$TASKS_DIR" t3 2>/dev/null); rc=$?
[ "$rc" -eq 3 ] && echo "$out" | grep -q 'illegal' \
    && ok "P3-07 illegal: start while STOPPING -> error (rc 3)" || bad "P3-07 illegal: rc=$rc out=$out"
[ "$(cat "$TASKS_DIR/t3/state.txt")" = "STOPPING" ] \
    && ok "P3-07 illegal: state.txt NOT force-written (still STOPPING)" \
    || bad "P3-07 illegal: state.txt mutated to $(cat "$TASKS_DIR/t3/state.txt")"
[ "$(tc_snap)" = "$SNAP_ILLEGAL" ] && ok "P3-07 illegal: task-config md5 unchanged (registry not corrupted)" \
    || bad "P3-07 illegal: task-config mutated"

# ── 7) 旧运行 ID 控制旧运行目录（§9 idmap）────────────────────────────────
mkdir -p "$TASKS_DIR/time_2200_1_12345"
( sleep 30 ) &
OPID=$!
echo "$OPID" > "$TASKS_DIR/time_2200_1_12345/pid.txt"
echo "RUNNING" > "$TASKS_DIR/time_2200_1_12345/status.txt"
echo "echo hello" > "$TASKS_DIR/time_2200_1_12345/command.txt"   # 与 t1 命令一致 → idmap 主键
res=$(tctl_resolve "$BASE" "$TASKS_DIR" time_2200_1_12345); rrc=$?
[ "$rrc" -eq 0 ] && echo "$res" | grep -q '^t1|' \
    && ok "P3-07 oldrun: resolve old run id -> canonical t1 + old run dir" || bad "P3-07 oldrun: resolve rc=$rrc res=$res"
out=$(tctl_stop "$BASE" "$TASKS_DIR" time_2200_1_12345 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ ! -d "/proc/$OPID" ] \
    && [ "$(cat "$TASKS_DIR/time_2200_1_12345/state.txt")" = "STOPPED" ] \
    && ok "P3-07 oldrun: stop old run id killed THAT run dir only (state STOPPED)" \
    || bad "P3-07 oldrun: rc=$rc oldpid-alive=$([ -d /proc/$OPID ] && echo yes || echo no)"
printf 'old-log-1\nold-log-2\n' > "$TASKS_DIR/time_2200_1_12345/output.log"
out=$(tctl_logs "$BASE" "$TASKS_DIR" time_2200_1_12345 2 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'old-log-2' \
    && ok "P3-07 oldrun: logs via old run id reads THAT run dir" || bad "P3-07 oldrun: logs rc=$rc out=$out"

# ── 8) check：立即健康检查（probe 事件，不改 state.txt）───────────────────
# t2 无 health 配置 → no_health_configured；t1 已在 §5b 配 process:$$ → 真实探针
out=$(tctl_check "$BASE" "$TASKS_DIR" t2 2>/dev/null); rc=$?
[ "$rc" -eq 5 ] && echo "$out" | grep -q 'no_health_configured' \
    && ok "P3-07 check: no-health -> no_health_configured (rc 5)" || bad "P3-07 check: rc=$rc out=$out"
STATE_BEFORE=$(cat "$TASKS_DIR/t1/state.txt")
out=$(tctl_check "$BASE" "$TASKS_DIR" t1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -qE '^(HEALTHY|UNHEALTHY|UNKNOWN)\|reason=' \
    && ok "P3-07 check: real health probe returns three-state line (rc $rc)" || bad "P3-07 check: rc=$rc out=$out"
grep -q '|probe|' "$TASKS_DIR/t1/events.log" \
    && ok "P3-07 check: probe event appended to events.log" || bad "P3-07 check: probe event missing"
[ "$(cat "$TASKS_DIR/t1/state.txt")" = "$STATE_BEFORE" ] \
    && ok "P3-07 check: state.txt unchanged by check (no illegal transition)" || bad "P3-07 check: state mutated"

# ── 9) logs：查询任务日志 ─────────────────────────────────────────────────
printf 'log-line-1\nlog-line-2\nlog-line-3\n' > "$TASKS_DIR/t1/output.log"
out=$(tctl_logs "$BASE" "$TASKS_DIR" t1 2 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'log-line-2' \
    && printf '%s\n' "$out" | grep -q 'log-line-3' \
    && ok "P3-07 logs: tctl_logs tails last N lines" || bad "P3-07 logs: rc=$rc out=$out"
out=$(tctl_logs "$BASE" "$TASKS_DIR" ghost 2>/dev/null); rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q 'task_not_found' \
    && ok "P3-07 logs: unknown id -> task_not_found" || bad "P3-07 logs: rc=$rc out=$out"

# ── 10) enable/disable：修改配置状态（仅 managed）+ reload 可见 ───────────
out=$(tctl_set_enabled "$BASE" "$CFG" "$TASKS_DIR" t1 0 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'enabled=0 t1' \
    && grep -q '^enabled=0$' "$TCFG_DIR/t1.task" \
    && ok "P3-07 enable: disable -> enabled=0 in config" || bad "P3-07 enable: rc=$rc out=$out"
tctl_set_enabled "$BASE" "$CFG" "$TASKS_DIR" t1 1 >/dev/null 2>&1
grep -q '^enabled=1$' "$TCFG_DIR/t1.task" && ok "P3-07 enable: enable -> enabled=1" || bad "P3-07 enable: re-enable failed"
# legacy 模式拒绝（config.txt 不被 WebUI/CLI 触碰）
export TCFG_DIR="$BASE/task-config-legacy"
mkdir -p "$TCFG_DIR"; rm -f "$TCFG_DIR/MANAGED"
out=$(tctl_set_enabled "$BASE" "$CFG" "$TASKS_DIR" t1 0 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && echo "$out" | grep -q 'managed' \
    && ok "P3-07 enable: legacy mode -> error (write ops require managed)" || bad "P3-07 enable: legacy rc=$rc out=$out"
unset TCFG_DIR || true

# ── 11) 旧工件不被破坏：status.txt/pid.txt 非法 op 前后逐字节不变 ─────────
OLD_STATUS=$(cat "$TASKS_DIR/t1/status.txt" 2>/dev/null)
OLD_PID=$(cat "$TASKS_DIR/t1/pid.txt" 2>/dev/null)
# 非法 op（STOPPING 中 start，rc 3）已在上文执行；再执行一次确保零副作用
out=$(tctl_start "$BASE" "$TASKS_DIR" t3 2>/dev/null)
[ "$(cat "$TASKS_DIR/t1/status.txt" 2>/dev/null)" = "$OLD_STATUS" ] \
    && [ "$(cat "$TASKS_DIR/t1/pid.txt" 2>/dev/null)" = "$OLD_PID" ] \
    && ok "P3-07 artifacts: old artifacts byte-identical after failed op" || bad "P3-07 artifacts: legacy artifacts mutated"

# ── 12) CLI 子命令经 IPC 全链路（同一控制 API）────────────────────────────
# fake daemon 轮询循环：客户端 CLI → req 落盘 → 后台 poll → daemon §24 tctl_*
export TCFG_DIR="$BASE/task-config"   # 回到 managed 权威存储（§10 legacy 实验已还原）
ipc_server_init "$BASE" >/dev/null 2>&1
echo "$$" > "$BASE/ipc/daemon.pid"
( while :; do ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1; sleep 0.1; done ) &
DLOOP=$!
ROOT="$(pwd)"
cli_body() {
    sed '/^# 🚦 Main Dispatcher/,$d' "$CLI" \
      | tr -d '\r' \
      | sed '/^unset /d; /^export PATH=/d' \
      | sed "s#RUNTIME_LIB=\"/system/bin/su-scheduler-runtime\"#RUNTIME_LIB=\"$ROOT/system/bin/su-scheduler-runtime\"#"
}
cli_run() {   # <args...> → CLI_OUT / CLI_RC
    local tmp="$T/cli"
    mkdir -p "$tmp/tasks" "$tmp/shells"
    CLI_OUT=$( {
        set +u
        eval "$(cli_body)"
        CONFIG_FILE="$tmp/config.txt"
        LOG_FILE="$tmp/su-scheduler.log"
        TASKS_DIR="$tmp/tasks"
        SHELLS_DIR="$tmp/shells"
        DATA_DIR="$BASE"
        TCFG_DIR="$BASE/task-config"
        "$@"
    } 2>&1 )
    CLI_RC=$?
}

# CLI task start（经 IPC → daemon → tctl_start → execute_task 落真实 TASKS_DIR）
: > "$EXEC_LOG"
cli_run cmd_task start t1
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 'started t1' \
    && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-07 cli: task start t1 -> started (via IPC, exec in daemon TASKS_DIR)" \
    || bad "P3-07 cli: task start rc=$CLI_RC out=$CLI_OUT exec=$(wc -l < "$EXEC_LOG")"

# CLI task stop
cli_run cmd_task stop t1
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 'stopped t1' \
    && ok "P3-07 cli: task stop t1 -> stopped (via IPC)" || bad "P3-07 cli: task stop rc=$CLI_RC out=$CLI_OUT"

# CLI task check（无 health 的 t2 → no_health_configured）
cli_run cmd_task check t2
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 'no_health_configured' \
    && ok "P3-07 cli: task check t2 -> no_health_configured (via IPC)" || bad "P3-07 cli: task check rc=$CLI_RC out=$CLI_OUT"

# CLI task logs
printf 'cli-log-1\ncli-log-2\n' > "$TASKS_DIR/t1/output.log"
cli_run cmd_task logs t1 1
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 'cli-log-2' \
    && ok "P3-07 cli: task logs t1 -> tail via IPC (GET_TASK_LOG)" || bad "P3-07 cli: task logs rc=$CLI_RC out=$CLI_OUT"

# CLI task enable/disable（managed，经 IPC）
cli_run cmd_task disable t2
[ "$CLI_RC" -eq 0 ] && grep -q '^enabled=0$' "$TCFG_DIR/t2.task" \
    && ok "P3-07 cli: task disable t2 -> enabled=0 (via IPC)" || bad "P3-07 cli: task disable rc=$CLI_RC out=$CLI_OUT"
cli_run cmd_task enable t2
[ "$CLI_RC" -eq 0 ] && grep -q '^enabled=1$' "$TCFG_DIR/t2.task" \
    && ok "P3-07 cli: task enable t2 -> enabled=1 (via IPC)" || bad "P3-07 cli: task enable rc=$CLI_RC out=$CLI_OUT"

# CLI task restart（stop + start，可追踪）
: > "$EXEC_LOG"
cli_run cmd_task restart t2
[ "$CLI_RC" -eq 0 ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-07 cli: task restart t2 -> stop+start via IPC (1 exec)" || bad "P3-07 cli: task restart rc=$CLI_RC out=$CLI_OUT exec=$(wc -l < "$EXEC_LOG")"

# CLI task status（既有命令仍可用；无真实 daemon lock → 文档化 rc 3 错误路径）
cli_run cmd_task status t1
[ "$CLI_RC" -eq 3 ] && echo "$CLI_OUT" | grep -q 'daemon is not running' \
    && ok "P3-07 cli: task status t1 -> documented rc 3 daemon-not-running (old CLI intact)" \
    || bad "P3-07 cli: task status rc=$CLI_RC out=$CLI_OUT"

# ── 13) 批量控制（P5-07）：多 id 循环 + 逐任务输出 + 聚合退出码 + 部分失败不破坏配置 ──
tcfg_new_task t_b1 "12:00" "echo b1" >/dev/null 2>&1
tcfg_new_task t_b2 "13:00" "echo b2" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1

# 批量 start：逐任务 `<id>: started <id>` + rc 0 + 每任务 1 exec
: > "$EXEC_LOG"
cli_run cmd_task start t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 't_b1: started t_b1' \
    && echo "$CLI_OUT" | grep -q 't_b2: started t_b2' \
    && [ "$(wc -l < "$EXEC_LOG")" -eq 2 ] \
    && ok "P5-07 batch: start t_b1 t_b2 -> per-task 'id: started' + rc 0 + 2 exec" \
    || bad "P5-07 batch: start rc=$CLI_RC out=$CLI_OUT exec=$(wc -l < "$EXEC_LOG")"

# 批量 stop：逐任务 `<id>: stopped <id>`
cli_run cmd_task stop t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 't_b1: stopped t_b1' \
    && echo "$CLI_OUT" | grep -q 't_b2: stopped t_b2' \
    && ok "P5-07 batch: stop t_b1 t_b2 -> per-task 'id: stopped' + rc 0" \
    || bad "P5-07 batch: stop rc=$CLI_RC out=$CLI_OUT"

# 批量 restart：每任务 stop+force-start → 2 exec
: > "$EXEC_LOG"
cli_run cmd_task restart t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && [ "$(wc -l < "$EXEC_LOG")" -eq 2 ] \
    && ok "P5-07 batch: restart t_b1 t_b2 -> 2 exec + rc 0" \
    || bad "P5-07 batch: restart rc=$CLI_RC exec=$(wc -l < "$EXEC_LOG")"

# 批量 check（无 health → no_health_configured，tctl rc 5 → IPC rc 0 ok）
cli_run cmd_task check t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q 't_b1: no_health_configured t_b1' \
    && echo "$CLI_OUT" | grep -q 't_b2: no_health_configured t_b2' \
    && ok "P5-07 batch: check t_b1 t_b2 -> per-task no_health_configured + rc 0" \
    || bad "P5-07 batch: check rc=$CLI_RC out=$CLI_OUT"

# 批量 disable/enable（managed 配置原子写）
cli_run cmd_task disable t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && grep -q '^enabled=0$' "$TCFG_DIR/t_b1.task" \
    && grep -q '^enabled=0$' "$TCFG_DIR/t_b2.task" \
    && ok "P5-07 batch: disable t_b1 t_b2 -> both enabled=0 in config" \
    || bad "P5-07 batch: disable rc=$CLI_RC"
cli_run cmd_task enable t_b1 t_b2
[ "$CLI_RC" -eq 0 ] && grep -q '^enabled=1$' "$TCFG_DIR/t_b1.task" \
    && grep -q '^enabled=1$' "$TCFG_DIR/t_b2.task" \
    && ok "P5-07 batch: enable t_b1 t_b2 -> both enabled=1 in config" \
    || bad "P5-07 batch: enable rc=$CLI_RC"

# 部分失败（不存在 id ghost）：成功任务正常执行、失败任务报错、聚合 rc 1 + FAILED 清单
tctl_stop "$BASE" "$TASKS_DIR" t_b1 >/dev/null 2>&1
tctl_stop "$BASE" "$TASKS_DIR" t_b2 >/dev/null 2>&1
SNAP_B=$(tc_snap)
: > "$EXEC_LOG"
cli_run cmd_task start t_b1 ghost t_b2
[ "$CLI_RC" -eq 1 ] && echo "$CLI_OUT" | grep -q 't_b1: started t_b1' \
    && echo "$CLI_OUT" | grep -q 'ghost: ERROR:' \
    && echo "$CLI_OUT" | grep -q 't_b2: started t_b2' \
    && echo "$CLI_OUT" | grep -q 'FAILED: ghost' \
    && [ "$(wc -l < "$EXEC_LOG")" -eq 2 ] \
    && ok "P5-07 batch: partial failure (ghost) -> per-task results + FAILED list + rc 1" \
    || bad "P5-07 batch: partial rc=$CLI_RC out=$CLI_OUT exec=$(wc -l < "$EXEC_LOG")"
[ "$(tc_snap)" = "$SNAP_B" ] && ok "P5-07 batch: config byte-identical after partial failure (B19)" \
    || bad "P5-07 batch: config mutated after partial failure"
[ "$(cat "$TASKS_DIR/t_b1/state.txt" 2>/dev/null)" = "RUNNING" ] \
    && ok "P5-07 batch: other task t_b1 executed normally (state RUNNING)" \
    || bad "P5-07 batch: t_b1 state=$(cat "$TASKS_DIR/t_b1/state.txt" 2>/dev/null)"

# 批量与单任务行为一致：单 id 保持既有格式（无 `<id>: ` 前缀）
cli_run cmd_task stop t_b1
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q '^stopped t_b1$' \
    && ok "P5-07 batch: single-id stop keeps legacy format (no prefix)" \
    || bad "P5-07 batch: single-id rc=$CLI_RC out=$CLI_OUT"

# ── 13b) P5-09 §batch-limit：批量 id 数量上限（task_ctl_multi 入口先拒，零 IPC）──
# 用 mock task_ctl_send（计数写文件）验证：>50 id 在**任何 IPC 调用前**拒绝
# （零 send、零 exec、配置逐字节不变）；恰好 50 id 通过守卫并 50 次 send。
# （SIGSTOP 停 poller 会让 ≤50 边界每个 send 等满 IPC 超时——改用 mock 保持确定性且快。）
cli_run_mock() {   # <args...> → CLI_OUT/CLI_RC + $T/mock.cnt（task_ctl_send 调用次数）
    local tmp="$T/cli"
    mkdir -p "$tmp/tasks" "$tmp/shells"
    : > "$T/mock.cnt"
    CLI_OUT=$( {
        set +u
        eval "$(cli_body)"
        CONFIG_FILE="$tmp/config.txt"
        LOG_FILE="$tmp/su-scheduler.log"
        TASKS_DIR="$tmp/tasks"
        SHELLS_DIR="$tmp/shells"
        DATA_DIR="$BASE"
        TCFG_DIR="$BASE/task-config"
        task_ctl_send() { n=$(cat "$T/mock.cnt" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/mock.cnt"; echo "started $2"; return 0; }
        "$@"
    } 2>&1 )
    CLI_RC=$?
}
: > "$EXEC_LOG"
SNAP_BL=$(tc_snap)
IDS51=""
i=1; while [ "$i" -le 51 ]; do IDS51="$IDS51 id_$i"; i=$((i + 1)); done
cli_run_mock cmd_task start $IDS51
[ "$CLI_RC" -eq 1 ] && echo "$CLI_OUT" | grep -q 'batch limit 50' \
    && ok "P5-09 batch-limit: 51 ids -> rc 1 + 'batch limit 50' (rejected before IPC)" \
    || bad "P5-09 batch-limit: rc=$CLI_RC out=$CLI_OUT"
[ "$(cat "$T/mock.cnt" 2>/dev/null)" = "" ] && ok "P5-09 batch-limit: ZERO IPC send (guard fired first)" \
    || bad "P5-09 batch-limit: IPC send leaked ($(cat "$T/mock.cnt" 2>/dev/null))"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P5-09 batch-limit: ZERO exec" \
    || bad "P5-09 batch-limit: exec leaked ($(wc -l < "$EXEC_LOG"))"
[ "$(tc_snap)" = "$SNAP_BL" ] && ok "P5-09 batch-limit: task-config byte-identical" \
    || bad "P5-09 batch-limit: config mutated"
# 恰好 50 id 通过守卫（边界 = `<=50`），50 次 send 全成功 rc 0
IDS50=${IDS51% *}
cli_run_mock cmd_task start $IDS50
[ "$CLI_RC" -eq 0 ] && [ "$(cat "$T/mock.cnt" 2>/dev/null)" = "50" ] \
    && [ "$(printf '%s\n' "$CLI_OUT" | grep -c '^id_[0-9]*: started id_')" -eq 50 ] \
    && ok "P5-09 batch-limit: 50 ids pass the guard -> 50 sends + rc 0 (boundary = <=50)" \
    || bad "P5-09 batch-limit: 50-id boundary rc=$CLI_RC cnt=$(cat "$T/mock.cnt" 2>/dev/null)"

kill "$DLOOP" 2>/dev/null
wait "$DLOOP" 2>/dev/null

# ── 13) POSIX：库（含 §24）dash -n（LF 归一）──────────────────────────────
if command -v dash >/dev/null 2>&1; then
    tr -d '\r' < "$RTLIB" > "$T/lib-lf.sh"
    dash -n "$T/lib-lf.sh" 2>/dev/null && ok "P3-07 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §24)" || bad "P3-07 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-07 POSIX: bash -n ok (dash unavailable)" || bad "P3-07 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "task-control tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
