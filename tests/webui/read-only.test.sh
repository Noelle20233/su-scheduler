#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# read-only.test.sh — P3-05 WebUI 只读数据面（read-only 验收）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖：
#   1) 静态资源：webroot/index.html、webroot/app.js、webroot/style.css 存在；
#      CLI 有 cmd_webui + WEBUI_READ_OPS + 帮助行 + dispatcher 接线。
#   2) Runtime Read Aggregator（§22）经真实 IPC 文件通道：
#      GET_SUMMARY / GET_TASK_DETAIL / GET_TASK_EVENTS / GET_DAEMON_LOG /
#      GET_TASK_LOG（meta 行 + truncated 标志）字段与计数正确；
#      JSON 转义正确处理 <script>/引号/换行（注入不可达执行流）。
#   3) 三态：空任务（0 任务）→ 计数全 0；损坏任务文件 → 单任务错误隔离
#      （task_not_found，不崩、不拖垮整体）；daemon 离线（无 daemon.pid）
#      → cmd_webui 返回 {"ok":false,"rc":6,"error":"daemon_unavailable"}。
#   4) CLI Reader：只读 op 白名单（拒绝写/控制 op）；成功 op 返回 JSON payload；
#      GET_TASK_LOG 经 web_task_log_to_json 归一为统一 JSON。
# 数据来源：一律只读 Registry 快照 + 运行目录工件 + daemon 日志（IPC 通道），
#   本测试不执行任何任务命令、不写 config（EXEC_LOG 必须保持 0 行）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── 1) 静态资源与 CLI 接线 ────────────────────────────────────────────────
for f in webroot/index.html webroot/app.js webroot/style.css; do
    [ -f "$f" ] && ok "P3-05 assets: $f present" || bad "P3-05 assets: $f missing"
done

grep -q '^WEBUI_READ_OPS=' "$CLI" && ok "P3-05 cli: WEBUI_READ_OPS defined" || bad "P3-05 cli: WEBUI_READ_OPS missing"
grep -q '^cmd_webui()' "$CLI" && ok "P3-05 cli: cmd_webui defined" || bad "P3-05 cli: cmd_webui missing"
grep -q 'webui) shift; cmd_webui' "$CLI" && ok "P3-05 cli: dispatcher has webui" || bad "P3-05 cli: dispatcher missing webui"
grep -q 'webui.*只读数据面' "$CLI" && ok "P3-05 cli: help line mentions webui" || bad "P3-05 cli: help line missing"

# 只读白名单：不允许任何写/控制 op
banned=""
for op in CREATE_TASK UPDATE_TASK DELETE_TASK ENABLE_TASK DISABLE_TASK START_TASK STOP_TASK RESTART_TASK VALIDATE_TASK; do
    grep -q " $op " <<< "$(sed -n '/^WEBUI_READ_OPS=/p' "$CLI")" && banned="$banned $op"
done
[ -z "$banned" ] && ok "P3-05 cli: WEBUI_READ_OPS has NO write/control ops" || bad "P3-05 cli: write/control ops in whitelist:$banned"

# ── daemon 上下文 shim（同 tests/ipc：execute_task 记录 EXEC_LOG）─────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {   # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    echo "$id|$cmd|$tmx|$itr|$ns|$ne|$msg" >> "$EXEC_LOG"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"

# ── 2) 只读聚合器经真实 IPC 文件通道 ──────────────────────────────────────
# 准备 registry 任务 + 运行目录工件（多状态覆盖 Dashboard 计数）
mk_task() {   # <id> <trigger> <command> <enabled>
    tcfg_new_task "$1" "$2" "$3" >/dev/null 2>&1
    if [ "$4" = "0" ]; then
        tcfg_set_field "$1" enabled 0 >/dev/null 2>&1
    fi
}
mk_task t_run "08:30" "echo run" 1
mk_task t_ok  "09:00" "echo ok" 1
mk_task t_fail "10:00" "echo fail" 1
mk_task t_off  "11:00" "echo off" 0
mk_task t_un   "12:00" "echo un" 1

for id in t_run t_ok t_fail t_un; do
    mkdir -p "$TASKS_DIR/$id"
done
echo "RUNNING" > "$TASKS_DIR/t_run/state.txt"
echo "1001" > "$TASKS_DIR/t_run/pid.txt"
echo "0" > "$TASKS_DIR/t_run/exit_code.txt"
echo "2026-09-02 08:30:01" > "$TASKS_DIR/t_run/start_time.txt"
echo "HEALTHY" > "$TASKS_DIR/t_ok/state.txt"
echo "FAILED" > "$TASKS_DIR/t_fail/state.txt"
echo "UNHEALTHY" > "$TASKS_DIR/t_un/state.txt"
printf '2026-09-02 08:30:01|t_run|spawn|STARTING|1001||launched\n' > "$TASKS_DIR/t_run/events.log"

sched_reload "$BASE" "$CFG" >/dev/null 2>&1
ipc_server_init "$BASE" >/dev/null 2>&1

send_req() {   # <req_id> <line>
    local rid="$1" line="$2"
    local rdir="$BASE/ipc/requests"
    mkdir -p "$rdir"
    printf '%s\n' "$line" > "$rdir/$rid.req"
    ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
    cat "$BASE/ipc/responses/$rid.resp" 2>/dev/null
}
resp_rc() { printf '%s\n' "$1" | head -1 | cut -d'|' -f3; }

: > "$EXEC_LOG"
r=$(send_req "s1" "s1|GET_SUMMARY|")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"total":5' \
    && printf '%s\n' "$r" | grep -q '"running":1' \
    && printf '%s\n' "$r" | grep -q '"healthy":1' \
    && printf '%s\n' "$r" | grep -q '"failed":1' \
    && printf '%s\n' "$r" | grep -q '"disabled":1' \
    && printf '%s\n' "$r" | grep -q '"unhealthy":1' \
    && ok "P3-05 agg: GET_SUMMARY counts (total=5 run=1 health=1 fail=1 dis=1 unhealth=1)" \
    || bad "P3-05 agg: GET_SUMMARY rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

r=$(send_req "s2" "s2|GET_SUMMARY|")
printf '%s\n' "$r" | grep -q 't_run' && printf '%s\n' "$r" | grep -q '"mode":"managed"' \
    && ok "P3-05 agg: GET_SUMMARY tasks array + mode" || bad "P3-05 agg: tasks array/mode missing"

# P4-09：GET_SUMMARY counts 含 waiting 计数；WAITING 计入 waiting 而非 unknown
tcfg_new_task t_wait "12:30" "echo wait" >/dev/null 2>&1
mkdir -p "$TASKS_DIR/t_wait"
echo "WAITING" > "$TASKS_DIR/t_wait/state.txt"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "s3" "s3|GET_SUMMARY|")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"waiting":1' \
    && printf '%s\n' "$r" | grep -q '"total":6' \
    && ok "P4-09 agg: GET_SUMMARY counts include waiting (total=6, waiting=1)" \
    || bad "P4-09 agg: waiting count rc=$(resp_rc "$r") payload=$(printf '%s' "$r" | tail -n +2)"

r=$(send_req "d1" "d1|GET_TASK_DETAIL|id=$(ipc_b64enc t_run)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"id":"t_run"' \
    && printf '%s\n' "$r" | grep -q '"status":"RUNNING"' \
    && printf '%s\n' "$r" | grep -q '"pid":"1001"' \
    && printf '%s\n' "$r" | grep -q '"restart_count":0' \
    && printf '%s\n' "$r" | grep -q '"has_run_dir":1' \
    && ok "P3-05 agg: GET_TASK_DETAIL full fields" || bad "P3-05 agg: detail payload=$(printf '%s' "$r" | tail -n +2)"

# P4-09：GET_TASK_DETAIL 含 dependency/condition/dependency_state/gate_state，
# 且既有字段全部保留（只增键不删改，B8 统一 JSON 契约）
r=$(send_req "d9" "d9|GET_TASK_DETAIL|id=$(ipc_b64enc t_run)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] \
    && printf '%s\n' "$r" | grep -q '"id":"t_run"' \
    && printf '%s\n' "$r" | grep -q '"status":"RUNNING"' \
    && printf '%s\n' "$r" | grep -q '"health":{"type":"none"' \
    && printf '%s\n' "$r" | grep -q '"has_run_dir":1' \
    && printf '%s\n' "$r" | grep -q '"dependency":""' \
    && printf '%s\n' "$r" | grep -q '"condition":""' \
    && printf '%s\n' "$r" | grep -q '"dependency_state":"ok"' \
    && printf '%s\n' "$r" | grep -q '"gate_state":""' \
    && ok "P4-09 agg: GET_TASK_DETAIL new fields present + existing keys intact" \
    || bad "P4-09 agg: detail fields payload=$(printf '%s' "$r" | tail -n +2)"

# P4-09：有 dependency 的 WAITING 任务 → dependency_state=waiting + gate_state 含原因
tcfg_set_field t_run dependency "t_ok" >/dev/null 2>&1
mkdir -p "$TASKS_DIR/t_run"
echo "WAITING" > "$TASKS_DIR/t_run/state.txt"
printf '2026-09-02 08:30:01|t_run|gate_wait|WAITING|||dep unsat: t_ok\n' >> "$TASKS_DIR/t_run/events.log"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "d10" "d10|GET_TASK_DETAIL|id=$(ipc_b64enc t_run)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] \
    && printf '%s\n' "$r" | grep -q '"dependency":"t_ok"' \
    && printf '%s\n' "$r" | grep -q '"dependency_state":"waiting"' \
    && printf '%s\n' "$r" | grep -q '"gate_state":"WAITING (dep unsat: t_ok)"' \
    && printf '%s\n' "$r" | grep -q '"status":"WAITING"' \
    && ok "P4-09 agg: WAITING task detail shows dependency_state=waiting + gate_state reason" \
    || bad "P4-09 agg: WAITING detail payload=$(printf '%s' "$r" | tail -n +2)"
# 还原 t_run 状态与依赖（避免影响后续 §3/§4 用例；events.log 重置为既有首行
# 以免污染下方「events 2 行 → truncated」断言）
rm -f "$TASKS_DIR/t_run/state.txt"
printf '2026-09-02 08:30:01|t_run|spawn|STARTING|1001||launched\n' > "$TASKS_DIR/t_run/events.log"
tcfg_set_field t_run dependency "" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1

r=$(send_req "d2" "d2|GET_TASK_DETAIL|id=$(ipc_b64enc nope)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-05 agg: GET_TASK_DETAIL unknown -> task_not_found" || bad "P3-05 agg: unknown rc=$(resp_rc "$r")"

# events：2 行，lines=1 → truncated=1
printf '2026-09-02 08:31:01|t_run|action_success|STOPPED|1001|0|done\n' >> "$TASKS_DIR/t_run/events.log"
r=$(send_req "e1" "e1|GET_TASK_EVENTS|id=$(ipc_b64enc t_run)&lines=$(ipc_b64enc 1)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"total":2' \
    && printf '%s\n' "$r" | grep -q '"truncated":1' \
    && ok "P3-05 agg: GET_TASK_EVENTS bounded + truncated flag" || bad "P3-05 agg: events payload=$(printf '%s' "$r" | tail -n +2)"

# daemon log：5 行，lines=3 → truncated=1
printf 'd1\nd2\nd3\nd4\nd5\n' > "$BASE/su-scheduler.log"
r=$(send_req "dl1" "dl1|GET_DAEMON_LOG|lines=$(ipc_b64enc 3)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"total":5' \
    && printf '%s\n' "$r" | grep -q '"truncated":1' \
    && printf '%s\n' "$r" | grep -q '"returned":3' \
    && ok "P3-05 agg: GET_DAEMON_LOG bounded + truncated flag" || bad "P3-05 agg: daemon log payload=$(printf '%s' "$r" | tail -n +2)"

# GET_TASK_LOG：meta 行 + truncated
printf 'o1\no2\no3\n' > "$TASKS_DIR/t_run/output.log"
r=$(send_req "tl1" "tl1|GET_TASK_LOG|id=$(ipc_b64enc t_run)&lines=$(ipc_b64enc 2)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '#truncated=1|total=3|lines=2' \
    && ok "P3-05 agg: GET_TASK_LOG meta line + truncated" || bad "P3-05 agg: task log payload=$(printf '%s' "$r" | tail -n +2)"

# 只读操作零 exec
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-05 agg: all read ops had ZERO exec side effects" || bad "P3-05 agg: exec leaked ($(wc -l < "$EXEC_LOG"))"

# ── 3) 特殊字符：JSON 转义防注入 ─────────────────────────────────────────
evil='<script>alert("x")</script> & "quoted" \backslash'
printf 'echo %s\n' "$evil" > "$TASKS_DIR/t_run/command.txt"
tcfg_set_field t_run action.command "$evil" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "x1" "x1|GET_TASK_DETAIL|id=$(ipc_b64enc t_run)")
payload=$(printf '%s\n' "$r" | tail -n +2)
case "$payload" in
    *'<script>'*) bad "P3-05 esc: raw <script> leaked into JSON payload" ;;
    *'alert("x")'*) bad "P3-05 esc: raw JS executed inside payload" ;;
    *) ok "P3-05 esc: <script>/quotes not present raw in JSON payload" ;;
esac
printf '%s\n' "$payload" | grep -q '\\u003cscript\\u003e' && ok "P3-05 esc: < escaped as \\u003c" || bad "P3-05 esc: \\u003c missing"
printf '%s\n' "$payload" | grep -q '\\"' && ok "P3-05 esc: double-quote escaped" || bad "P3-05 esc: quote not escaped"

# 换行：log 多行内容经 web_task_log_to_json → 单行 JSON（每行独立转义为数组元素，
# JSON 文档内无裸换行 → 换行不可能在 JSON 字符串上下文中断言/注出）
printf 'multi\nline\nlog\n' > "$TASKS_DIR/t_run/output.log"
r=$(send_req "x2" "x2|GET_TASK_LOG|id=$(ipc_b64enc t_run)&lines=$(ipc_b64enc 5)")
pl=$(printf '%s\n' "$r" | tail -n +2)
json=$(web_task_log_to_json "$pl")
nl_in_json=$(printf '%s' "$json" | awk 'END{print NR}')
# JSON 必须为单行（无裸换行）；且三个 log 行都作为数组元素转义
[ "$nl_in_json" -eq 1 ] && printf '%s\n' "$json" | grep -q '"multi"' \
    && printf '%s\n' "$json" | grep -q '"line"' && printf '%s\n' "$json" | grep -q '"log"' \
    && ok "P3-05 esc: multi-line log -> single-line JSON (each line escaped element, no raw newline breakout)" \
    || bad "P3-05 esc: newline breakout (lines=$nl_in_json json=$json)"

# ── 4) 三态：空任务 / 损坏任务 / daemon 离线 ──────────────────────────────
# 空任务：全新空 registry（legacy 空 config.txt → 0 任务快照）
BASE_EMPTY="$T/base_empty"; CFG_EMPTY="$T/config_empty.txt"
mkdir -p "$BASE_EMPTY"
: > "$CFG_EMPTY"
unset TCFG_DIR || true
registry_init "$BASE_EMPTY" "$CFG_EMPTY" >/dev/null 2>&1
ipc_server_init "$BASE_EMPTY" >/dev/null 2>&1
mkdir -p "$BASE_EMPTY/ipc/requests"
printf '%s\n' "em1|GET_SUMMARY|" > "$BASE_EMPTY/ipc/requests/em1.req"
ipc_server_poll "$BASE_EMPTY" "$CFG_EMPTY" "$TASKS_DIR" >/dev/null 2>&1
r=$(cat "$BASE_EMPTY/ipc/responses/em1.resp" 2>/dev/null)
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"total":0' \
    && ok "P3-05 states: empty task set -> total 0" || bad "P3-05 states: empty summary rc=$(resp_rc "$r") payload=$(printf '%s' "$r" | tail -n +2)"

# 损坏任务：写入非法 task 文件（schema 缺 id）→ GET_TASK_DETAIL 单任务隔离
export TCFG_DIR="$BASE/task-config"   # 回到主 base
printf 'schema_version=2\nname=broken\n' > "$TCFG_DIR/broken.task" 2>/dev/null
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "br1" "br1|GET_TASK_DETAIL|id=$(ipc_b64enc broken)")
[ "$(resp_rc "$r")" = "3" ] && ok "P3-05 states: corrupted task -> task_not_found (isolated, no crash)" || bad "P3-05 states: corrupt task rc=$(resp_rc "$r")"

# daemon 离线：无 daemon.pid → cmd_webui 返回 daemon_unavailable JSON
# 经宿主友好的 CLI 函数体 runner（RUNTIME_LIB 指向仓库路径，使 RUNTIME_LOADED=1；
# 与 production 同一 cmd_webui 代码路径——仅路径替换为宿主可加载）。
ROOT="$(pwd)"
cli_body() {
    sed '/^# 🚦 Main Dispatcher/,$d' "$CLI" \
      | tr -d '\r' \
      | sed '/^unset /d; /^export PATH=/d' \
      | sed "s#RUNTIME_LIB=\"/system/bin/su-scheduler-runtime\"#RUNTIME_LIB=\"$ROOT/system/bin/su-scheduler-runtime\"#"
}
cli_webui_run() {   # <args...> → CLI_OUT / CLI_RC（DATA_DIR 指向无 daemon.pid 的空 base）
    local tmp="$T/cli"
    mkdir -p "$tmp/tasks" "$tmp/shells"
    CLI_OUT=$( {
        set +u
        eval "$(cli_body)"
        CONFIG_FILE="$tmp/config.txt"
        LOG_FILE="$tmp/su-scheduler.log"
        TASKS_DIR="$tmp/tasks"
        SHELLS_DIR="$tmp/shells"
        DATA_DIR="$tmp/data"     # 离线：无 ipc/daemon.pid
        "$@"
    } 2>&1 )
    CLI_RC=$?
}
cli_webui_run cmd_webui GET_SUMMARY
[ "$CLI_RC" -ne 0 ] && printf '%s\n' "$CLI_OUT" | grep -q '"ok":false' \
    && printf '%s\n' "$CLI_OUT" | grep -q 'daemon_unavailable' \
    && ok "P3-05 cli: cmd_webui offline -> {\"ok\":false,...daemon_unavailable} (rc=$CLI_RC)" \
    || bad "P3-05 cli: offline rc=$CLI_RC out=$CLI_OUT"

# 只读白名单拒绝写 op
cli_webui_run cmd_webui START_TASK id=whatever
[ "$CLI_RC" -ne 0 ] && printf '%s\n' "$CLI_OUT" | grep -q 'read-only' \
    && ok "P3-05 cli: cmd_webui rejects control op (START_TASK)" || bad "P3-05 cli: write op not rejected (rc=$CLI_RC out=$CLI_OUT)"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "webui read-only tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
