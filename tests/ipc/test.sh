#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P3-04 本地 IPC 控制面（协议 + 行为）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖：
#   1) 入口/接线：§21 ipc_* 定义、selfcheck 注册、daemon 接线
#      （ipc_server_init/ipc_server_poll）、CLI ipc 子命令 + 帮助行
#   2) 传输：ipc_server_init 建 0700 目录 + daemon.pid；IPC_WHITELIST 12 操作
#   3) 协议：固定请求行 REQ_ID|OP|k=b64&…；响应首行 REQ_ID|OP|RC|ERROR；
#      非法/超长 → invalid_request（零副作用）
#   4) GET_TASKS / GET_TASK_STATUS / GET_TASK_LOG（registry + 旧运行态）
#   5) VALIDATE_TASK：合法 ok；缺 command/trigger → configuration_invalid
#   6) 写操作（CREATE/UPDATE/DELETE/ENABLE/DISABLE）：Managed 模式成功 +
#      reload 后 registry 可见；Legacy 模式 → configuration_invalid
#   7) START/STOP/RESTART（经 action_run→execute_task shim）：执行落 EXEC_LOG；
#      已运行不重复启动（dedup）；task_not_found 区分
#   8) 错误码可区分：invalid_request / permission_denied / task_not_found /
#      configuration_invalid / operation_timeout / daemon_unavailable
#   9) 响应原子性（无 .tmp 残留）
#  10) POSIX：库（含 §21）dash -n
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
DAEMON="system/bin/su-schedulerd"
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── daemon 上下文 shim：action_run 委托到 execute_task（镜像 P3-03 手法）──
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"      # 每次执行：<id>|<cmd>|<termux>|<interactive>|<ns>|<ne>|<msg>
execute_task() {            # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    ( echo "$cmd" > "$d/output.log" 2>&1 ) &
    echo $! > "$d/pid.txt"
    echo "$id|$cmd|$tmx|$itr|$ns|$ne|$msg" >> "$EXEC_LOG"
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"
rm -f "$TCFG_DIR/MANAGED"

# 辅助：直接把请求行写入 requests/ 并跑一轮服务端轮询 → 读取响应文件
send_req() {   # <req_id> <line>
    local rid="$1" line="$2"
    local rdir="$BASE/ipc/requests"
    mkdir -p "$rdir"
    printf '%s\n' "$line" > "$rdir/$rid.req"
    ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
    cat "$BASE/ipc/responses/$rid.resp" 2>/dev/null
}
resp_rc() {   # <resp content> → RC（首行第 3 字段）
    printf '%s\n' "$1" | head -1 | cut -d'|' -f3
}
resp_err() { printf '%s\n' "$1" | head -1 | cut -d'|' -f4; }

# ── 1) 入口 + 接线 ─────────────────────────────────────────────────────────
fn_miss=0
for fn in ipc_server_init ipc_server_poll ipc_parse ipc_params_valid ipc_param \
          ipc_respond ipc_dispatch ipc_op_get_tasks ipc_op_get_status \
          ipc_op_get_log ipc_op_validate ipc_op_create ipc_op_update \
          ipc_op_delete ipc_op_set_enabled ipc_op_start ipc_op_stop \
          ipc_op_restart ipc_client_send ipc_b64enc ipc_b64dec; do
    type "$fn" >/dev/null 2>&1 || { bad "P3-04 entry: $fn missing"; fn_miss=1; }
done
[ "$fn_miss" -eq 0 ] && ok "P3-04 entry: §21 ipc_* functions defined"

web_miss=0
for fn in ipc_op_get_summary ipc_op_get_task_detail ipc_op_get_task_events \
          ipc_op_get_daemon_log web_json_escape web_agg_summary web_task_detail \
          web_log_payload web_task_log_to_json; do
    type "$fn" >/dev/null 2>&1 || { bad "P3-05 entry: $fn missing"; web_miss=1; }
done
[ "$web_miss" -eq 0 ] && ok "P3-05 entry: §22 WebUI read-only aggregator functions defined"

sel=$(sed -n '/^runtime_lib_selfcheck()/,/^}/p' "$RTLIB")
sel_miss=0
for fn in ipc_server_init ipc_server_poll ipc_dispatch ipc_op_start ipc_client_send; do
    printf '%s\n' "$sel" | grep -q "$fn" || sel_miss=$((sel_miss + 1))
done
[ "$sel_miss" -eq 0 ] && ok "P3-04 entry: §21 funcs registered in runtime_lib_selfcheck" || bad "P3-04 entry: $sel_miss selfcheck misses"

grep -q 'ipc_server_init "\$DATA_DIR"' "$DAEMON" && ok "P3-04 wiring: daemon startup calls ipc_server_init" || bad "P3-04 wiring: ipc_server_init missing in daemon"
grep -q 'ipc_server_poll "\$DATA_DIR" "\$CONFIG_FILE" "\$TASKS_DIR"' "$DAEMON" && ok "P3-04 wiring: daemon main-loop polls ipc_server_poll (non-blocking)" || bad "P3-04 wiring: ipc_server_poll missing in daemon"
grep -q 'ipc) shift; cmd_ipc' "$CLI" && ok "P3-04 wiring: CLI dispatcher has ipc subcommand" || bad "P3-04 wiring: CLI ipc dispatcher missing"
grep -q '^cmd_ipc()' "$CLI" && ok "P3-04 wiring: CLI cmd_ipc defined" || bad "P3-04 wiring: cmd_ipc missing"
grep -q 'GET_TASKS|GET_TASK_STATUS' "$CLI" && ok "P3-04 wiring: CLI help lists IPC ops" || bad "P3-04 wiring: help line missing"
grep -q 'RUNTIME_LOADED' "$CLI" && ok "P3-04 wiring: CLI keeps RUNTIME_LOADED gate" || bad "P3-04 wiring: CLI gate missing"

# ── 2) 传输初始化 ──────────────────────────────────────────────────────────
rm -rf "$BASE/ipc"
ipc_server_init "$BASE" >/dev/null 2>&1
[ -d "$BASE/ipc/requests" ] && [ -d "$BASE/ipc/responses" ] && ok "P3-04 transport: ipc dirs created" || bad "P3-04 transport: dirs missing"
[ -f "$BASE/ipc/daemon.pid" ] && ok "P3-04 transport: daemon.pid marker written" || bad "P3-04 transport: daemon.pid missing"
pm=$(ls -ld "$BASE/ipc" | awk '{print $1}')
[ "$pm" = "drwx------" ] && ok "P3-04 transport: ipc dir perms $pm (root-only)" || bad "P3-04 transport: ipc perms=$pm"
n=$(echo "$IPC_WHITELIST" | wc -w)
[ "$n" -eq 19 ] && ok "P3-04/P3-05/P3-06/P3-07 transport: IPC_WHITELIST 19 ops (12 control + CHECK_TASK + 4 WebUI read-only + GET_TASK_EDIT/EDIT_TASK)" || bad "P3-04/P3-05/P3-06/P3-07 transport: whitelist count=$n"
grep -q 'GET_SUMMARY' <<< "$IPC_WHITELIST" && grep -q 'GET_TASK_DETAIL' <<< "$IPC_WHITELIST" \
  && grep -q 'GET_TASK_EVENTS' <<< "$IPC_WHITELIST" && grep -q 'GET_DAEMON_LOG' <<< "$IPC_WHITELIST" \
  && ok "P3-05 transport: WebUI read-only ops in whitelist (GET_SUMMARY/GET_TASK_DETAIL/GET_TASK_EVENTS/GET_DAEMON_LOG)" \
  || bad "P3-05 transport: WebUI read-only ops missing from whitelist"
grep -q 'CHECK_TASK' <<< "$IPC_WHITELIST" && ok "P3-07 transport: CHECK_TASK in whitelist" || bad "P3-07 transport: CHECK_TASK missing from whitelist"

# ── 3) 协议：固定格式 + 非法请求零副作用 ───────────────────────────────────
: > "$EXEC_LOG"
ipc_server_init "$BASE" >/dev/null 2>&1
r=$(send_req "t_good" "t_good|GET_TASKS|")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-04 proto: valid GET_TASKS -> rc 0 (no registry yet, empty list)" || bad "P3-04 proto: GET_TASKS rc=$(resp_rc "$r")"

# 非法请求：空/无 op/坏 req_id/未知 op/坏 base64/超长 → invalid_request 且零副作用
badline=""
for case_name in "empty" "nopipe" "badop" "badrid" "badb64" "oversize"; do
    case "$case_name" in
        empty)    line="" ;;
        nopipe)   line="GET_TASKS" ;;
        badop)    line="x1|FROBNICATE|" ;;
        badrid)   line="a b|GET_TASKS|" ;;
        badb64)   line="x2|GET_TASKS|id=!!notb64!!" ;;
        oversize) line="x3|GET_TASKS|p=$(printf 'a%.0s' $(seq 1 6000))" ;;
    esac
    printf '%s\n' "$line" > "$BASE/ipc/requests/${case_name}.req"
    ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
    rc=$(cat "$BASE/ipc/responses/${case_name}.resp" 2>/dev/null | head -1 | cut -d'|' -f3)
    [ "$rc" = "1" ] && ok "P3-04 proto: $case_name -> invalid_request (rc 1)" || bad "P3-04 proto: $case_name rc=${rc:-none}"
done
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-04 proto: malformed requests had ZERO side effects (no exec)" || bad "P3-04 proto: exec happened on malformed ($(wc -l < "$EXEC_LOG"))"

# ── 4) GET_*（registry 就绪后）─────────────────────────────────────────────
cat > "$CFG" <<'EOF'
08:30 echo legacy-task-a
12:00 echo legacy-task-b
EOF
export TCFG_DIR="$BASE/task-config"
rm -rf "$TCFG_DIR"; mkdir -p "$TCFG_DIR"; rm -f "$TCFG_DIR/MANAGED"
registry_init "$BASE" "$CFG" >/dev/null 2>&1

r=$(send_req "g_tasks" "g_tasks|GET_TASKS|")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q 't1_0830|' && printf '%s\n' "$r" | grep -q 't2_1200|' \
    && ok "P3-04 get: GET_TASKS lists registry tasks" || bad "P3-04 get: GET_TASKS payload=$(printf '%s' "$r" | tail -n +2 | tr '\n' ';')"

r=$(send_req "g_st" "g_st|GET_TASK_STATUS|id=$(ipc_b64enc t1_0830)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '^command=echo legacy-task-a$' \
    && ok "P3-04 get: GET_TASK_STATUS returns task fields" || bad "P3-04 get: status rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

r=$(send_req "g_st_miss" "g_st_miss|GET_TASK_STATUS|id=$(ipc_b64enc nope)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-04 get: GET_TASK_STATUS unknown -> task_not_found" || bad "P3-04 get: unknown rc=$(resp_rc "$r")"

r=$(send_req "g_log_miss" "g_log_miss|GET_TASK_LOG|id=$(ipc_b64enc nope)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-04 get: GET_TASK_LOG unknown -> task_not_found" || bad "P3-04 get: log unknown rc=$(resp_rc "$r")"

r=$(send_req "g_log" "g_log|GET_TASK_LOG|id=$(ipc_b64enc t1_0830)")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-04 get: GET_TASK_LOG no-output -> rc 0" || bad "P3-04 get: log rc=$(resp_rc "$r")"

# ── 4b) P3-05 WebUI 只读 op（GET_SUMMARY/GET_TASK_DETAIL/GET_TASK_EVENTS/GET_DAEMON_LOG）──
: > "$EXEC_LOG"   # 只读操作必须零 exec
r=$(send_req "w_sum" "w_sum|GET_SUMMARY|")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"total":2' && printf '%s\n' "$r" | grep -q 't1_0830' \
    && ok "P3-05 read: GET_SUMMARY returns totals+tasks JSON" || bad "P3-05 read: GET_SUMMARY rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

r=$(send_req "w_det" "w_det|GET_TASK_DETAIL|id=$(ipc_b64enc t1_0830)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"ok":true' && printf '%s\n' "$r" | grep -q '"task"' \
    && ok "P3-05 read: GET_TASK_DETAIL returns detail JSON" || bad "P3-05 read: detail rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

r=$(send_req "w_det_miss" "w_det_miss|GET_TASK_DETAIL|id=$(ipc_b64enc nope)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-05 read: GET_TASK_DETAIL unknown -> task_not_found" || bad "P3-05 read: detail unknown rc=$(resp_rc "$r")"

r=$(send_req "w_ev" "w_ev|GET_TASK_EVENTS|id=$(ipc_b64enc t1_0830)&lines=$(ipc_b64enc 5)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"lines":\[' \
    && ok "P3-05 read: GET_TASK_EVENTS returns events JSON" || bad "P3-05 read: events rc=$(resp_rc "$r")"

r=$(send_req "w_dlog" "w_dlog|GET_DAEMON_LOG|lines=$(ipc_b64enc 5)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"truncated":' \
    && ok "P3-05 read: GET_DAEMON_LOG returns daemon log JSON" || bad "P3-05 read: daemon log rc=$(resp_rc "$r")"

# 新只读 op 注入（元字符）→ 零 exec
# P3-08：注入 id（含 `;`/空格）现被 §25 secv_id_ok 拒绝为 invalid_request（rc 1）
# 或 task_not_found（rc 3）——两种都是拒绝、零副作用；语义更严（合法 id 字符集门）。
r=$(send_req "w_inj" "w_inj|GET_TASK_DETAIL|id=$(ipc_b64enc 'a;touch pwn')")
rc_inj=$(resp_rc "$r")
[ "$rc_inj" = "3" ] || [ "$rc_inj" = "1" ] && ok "P3-05 read: malicious id rejected (rc $rc_inj, zero side-effect)" || bad "P3-05 read: malicious id rc=$rc_inj"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-05 read: WebUI read-only ops had ZERO exec side effects" || bad "P3-05 read: exec leaked ($(wc -l < "$EXEC_LOG"))"

# ── 5) VALIDATE_TASK ───────────────────────────────────────────────────────
v="command=$(ipc_b64enc 'echo hi')&trigger=$(ipc_b64enc '09:00')"
r=$(send_req "v_ok" "v_ok|VALIDATE_TASK|$v")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-04 validate: valid task -> ok" || bad "P3-04 validate: valid rc=$(resp_rc "$r")"

r=$(send_req "v_nocmd" "v_nocmd|VALIDATE_TASK|trigger=$(ipc_b64enc '09:00')")
[ "$(resp_rc "$r")" = "4" ] && ok "P3-04 validate: missing command -> configuration_invalid" || bad "P3-04 validate: nocmd rc=$(resp_rc "$r")"

# ── 6) 写操作：Managed 模式成功 / Legacy 拒绝 ─────────────────────────────
# legacy（无 MANAGED）：写操作 → configuration_invalid
r=$(send_req "w_legacy" "w_legacy|CREATE_TASK|trigger=$(ipc_b64enc '09:00')&command=$(ipc_b64enc 'echo x')")
[ "$(resp_rc "$r")" = "4" ] && ok "P3-04 write: CREATE_TASK in legacy -> configuration_invalid" || bad "P3-04 write: legacy create rc=$(resp_rc "$r")"

# 切 managed：写操作全链路
echo "managed" > "$TCFG_DIR/MANAGED"
r=$(send_req "c1" "c1|CREATE_TASK|name=$(ipc_b64enc 'web task')&trigger=$(ipc_b64enc '09:30')&command=$(ipc_b64enc 'echo web-created')")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q 'created' && ok "P3-04 write: CREATE_TASK managed -> ok" || bad "P3-04 write: create rc=$rc $(printf '%s' "$r" | tail -n +2)"
newid=$(printf '%s\n' "$r" | sed -n '2p' | sed 's/^created //')
[ -n "$newid" ] && [ -f "$TCFG_DIR/$newid.task" ] && ok "P3-04 write: task file written ($newid)" || bad "P3-04 write: task file missing"

# reload 后 registry 可见（sched_reload 已内置于 op）
r=$(send_req "g_after" "g_after|GET_TASKS|")
printf '%s\n' "$r" | grep -q "$newid" && ok "P3-04 write: created task visible in registry (reload)" || bad "P3-04 write: registry missing $newid"

# UPDATE_TASK
r=$(send_req "u1" "u1|UPDATE_TASK|id=$(ipc_b64enc "$newid")&command=$(ipc_b64enc 'echo web-updated')")
[ "$(resp_rc "$r")" = "0" ] && grep -q 'action.command=echo web-updated' "$TCFG_DIR/$newid.task" \
    && ok "P3-04 write: UPDATE_TASK updates command" || bad "P3-04 write: update failed rc=$(resp_rc "$r")"

# ENABLE/DISABLE
r=$(send_req "d1" "d1|DISABLE_TASK|id=$(ipc_b64enc "$newid")")
[ "$(resp_rc "$r")" = "0" ] && grep -q '^enabled=0$' "$TCFG_DIR/$newid.task" && ok "P3-04 write: DISABLE_TASK sets enabled=0" || bad "P3-04 write: disable rc=$(resp_rc "$r")"
r=$(send_req "e1" "e1|ENABLE_TASK|id=$(ipc_b64enc "$newid")")
[ "$(resp_rc "$r")" = "0" ] && grep -q '^enabled=1$' "$TCFG_DIR/$newid.task" && ok "P3-04 write: ENABLE_TASK sets enabled=1" || bad "P3-04 write: enable rc=$(resp_rc "$r")"

# DELETE_TASK
r=$(send_req "del1" "del1|DELETE_TASK|id=$(ipc_b64enc "$newid")")
[ "$(resp_rc "$r")" = "0" ] && [ ! -f "$TCFG_DIR/$newid.task" ] && ok "P3-04 write: DELETE_TASK removes task" || bad "P3-04 write: delete rc=$(resp_rc "$r")"

# UPDATE/DELETE 未知 id → task_not_found
r=$(send_req "u_miss" "u_miss|UPDATE_TASK|id=$(ipc_b64enc ghost)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-04 write: UPDATE unknown -> task_not_found" || bad "P3-04 write: update ghost rc=$(resp_rc "$r")"

# ── 7) START/STOP/RESTART（dedup：已运行不重复启动）────────────────────────
# 重建一个 registry 任务（legacy 回退前先建 managed 任务）
echo "managed" > "$TCFG_DIR/MANAGED"
r=$(send_req "c2" "c2|CREATE_TASK|name=$(ipc_b64enc 'runnable')&trigger=$(ipc_b64enc '10:00')&command=$(ipc_b64enc 'echo run-me')")
rid2=$(printf '%s\n' "$r" | sed -n '2p' | sed 's/^created //')
[ -n "$rid2" ] || rid2="task_1000_1"

: > "$EXEC_LOG"
r=$(send_req "s1" "s1|START_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] && ok "P3-04 start: START_TASK executes once" || bad "P3-04 start: rc=$(resp_rc "$r") exec=$(wc -l < "$EXEC_LOG")"

r=$(send_req "s2" "s2|START_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-04 start: START_TASK already-running -> no duplicate start (dedup)" || bad "P3-04 start: dedup failed exec=$(wc -l < "$EXEC_LOG")"

r=$(send_req "s_miss" "s_miss|START_TASK|id=$(ipc_b64enc ghost)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-04 start: START unknown -> task_not_found" || bad "P3-04 start: ghost rc=$(resp_rc "$r")"

r=$(send_req "st1" "st1|STOP_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-04 stop: STOP_TASK ok" || bad "P3-04 stop: rc=$(resp_rc "$r")"

r=$(send_req "rs1" "rs1|RESTART_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 2 ] \
    && ok "P3-04 restart: RESTART_TASK stops+starts (2nd exec)" || bad "P3-04 restart: rc=$(resp_rc "$r") exec=$(wc -l < "$EXEC_LOG")"

# ── 7b) P3-07 CHECK_TASK（立即健康检查；无 health 配置 → ok 明示）─────────
r=$(send_req "c1x" "c1x|CHECK_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q 'no_health_configured' \
    && ok "P3-07 check: CHECK_TASK no-health -> rc 0 with no_health_configured" \
    || bad "P3-07 check: no-health rc=$(resp_rc "$r") payload=$(printf '%s' "$r" | tail -n +2)"
r=$(send_req "c2x" "c2x|CHECK_TASK|id=$(ipc_b64enc ghost)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-07 check: CHECK_TASK unknown -> task_not_found" || bad "P3-07 check: ghost rc=$(resp_rc "$r")"
r=$(send_req "c3x" "c3x|CHECK_TASK|")
[ "$(resp_rc "$r")" = "1" ] && ok "P3-07 check: CHECK_TASK missing id -> invalid_request" || bad "P3-07 check: no-id rc=$(resp_rc "$r")"
# 有 health 配置 → 真实探针三态行（process:$$ = 本 shell 存活）
tcfg_set_field "$rid2" health.type process >/dev/null 2>&1
tcfg_set_field "$rid2" health.target "$$" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "c4x" "c4x|CHECK_TASK|id=$(ipc_b64enc "$rid2")")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q 'HEALTHY|reason=' \
    && ok "P3-07 check: CHECK_TASK runs real health probe (HEALTHY line)" \
    || bad "P3-07 check: probe rc=$(resp_rc "$r") payload=$(printf '%s' "$r" | tail -n +2)"

# ── 8) 错误码可区分（客户端路径）───────────────────────────────────────────
# daemon_unavailable：无 daemon.pid
rm -f "$BASE/ipc/daemon.pid"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
[ "$rc" -eq 6 ] && echo "$out" | grep -q daemon_unavailable && ok "P3-04 err: daemon stopped -> daemon_unavailable (rc 6)" || bad "P3-04 err: unavailable rc=$rc out=$out"

# permission_denied：daemon.pid 存活（本 shell）但 requests 目录不可写
echo "$$" > "$BASE/ipc/daemon.pid"
chmod 500 "$BASE/ipc/requests"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
chmod 700 "$BASE/ipc/requests"
[ "$rc" -eq 2 ] && echo "$out" | grep -q permission_denied && ok "P3-04 err: unwritable req dir -> permission_denied (rc 2)" || bad "P3-04 err: perm rc=$rc out=$out"

# operation_timeout：daemon.pid 存活但不跑服务端轮询
rm -f "$BASE/ipc/requests"/*.req 2>/dev/null
echo "$$" > "$BASE/ipc/daemon.pid"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
[ "$rc" -eq 5 ] && echo "$out" | grep -q operation_timeout && ok "P3-04 err: no server -> operation_timeout (rc 5)" || bad "P3-04 err: timeout rc=$rc out=$out"

# ── 9) 响应原子性：无 .tmp 残留 ───────────────────────────────────────────
ipc_server_init "$BASE" >/dev/null 2>&1
send_req "atom" "atom|GET_TASKS|" >/dev/null
left=$(ls "$BASE/ipc/responses/" | grep -c '\.tmp$' || true)
[ "$left" -eq 0 ] && ok "P3-04 atomic: no response .tmp leftovers" || bad "P3-04 atomic: $left .tmp leftovers"

# ── 10) POSIX：库（含 §21）dash -n ─────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-04 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §21)" || bad "P3-04 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-04 POSIX: bash -n ok (dash unavailable)" || bad "P3-04 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "ipc tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
