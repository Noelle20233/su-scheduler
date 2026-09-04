#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# security.test.sh — P3-05 WebUI 只读数据面（security 验收）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 安全声明（对照任务验收）：
#   a) WebUI 无直接 Root 执行调用：webroot 静态资源（HTML/JS）不含 su / sh -c /
#      eval / exec / /data/adb 直读特征；只读 op 全部零 exec（EXEC_LOG 不变）。
#   b) 注入不可达执行流：恶意 id/command/log 经 IPC 新只读 op → 仅数据被 JSON
#      转义返回；绝不执行、绝不写 config（task-config 快照 md5 不变）。
#   c) 日志中的 <script>、引号、换行不会造成 HTML/JS 注入：web_json_escape
#      统一 JSON 编码（< > & → \uXXXX；" \ → \" \\；控制符清除）；前端用
#      textContent 渲染，且 JS 不 eval。
#   d) malformed/未知 op → invalid_request（rc 1），零副作用。
#   e) 有界日志：日志读取按行数上限硬钳（task/daemon ≤500，events ≤200），
#      truncated 标志明确暴露截断状态。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── a) 静态资源无 Root 直执特征 ────────────────────────────────────────────
badpat=0
for pat in 'su -c' 'sh -c' 'eval(' 'new Function' 'child_process' '/data/adb' 'document.write' 'innerHTML'; do
    if grep -rq "$pat" webroot/ 2>/dev/null; then
        bad "P3-05 sec-a: webroot contains forbidden pattern: $pat"
        badpat=1
    fi
done
[ "$badpat" -eq 0 ] && ok "P3-05 sec-a: webroot HTML/JS has no Root-exec / eval / /data/adb patterns"

# JS 只用 textContent 渲染动态数据（不拼接 innerHTML）
if grep -rq 'textContent' webroot/app.js; then
    ok "P3-05 sec-a: app.js uses textContent (XSS-safe DOM)"
else
    bad "P3-05 sec-a: app.js missing textContent usage"
fi

# ── daemon 上下文 shim ────────────────────────────────────────────────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    echo "$id|$cmd|$tmx|$itr|$ns|$ne|$msg" >> "$EXEC_LOG"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
tcfg_new_task tsec "08:30" "echo safe" >/dev/null 2>&1
mkdir -p "$TASKS_DIR/tsec"
echo "RUNNING" > "$TASKS_DIR/tsec/state.txt"
printf 'ok-line-1\nok-line-2\n' > "$TASKS_DIR/tsec/output.log"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
ipc_server_init "$BASE" >/dev/null 2>&1
tc_snap() { find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1; }
SNAP_A=$(tc_snap)

poll() { ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1; }
drop_req() { printf '%s\n' "$2" > "$BASE/ipc/requests/$1.req"; }
req_rc()  { cat "$BASE/ipc/responses/$1.resp" 2>/dev/null | head -1 | cut -d'|' -f3; }

# ── b) 恶意 op/参数 → 零 exec、零 config 写 ───────────────────────────────
: > "$EXEC_LOG"
drop_req "m1" "m1|GET_TASK_DETAIL|id=$(ipc_b64enc 'x;touch '$T'/pwn')"
drop_req "m2" "m2|GET_TASK_EVENTS|id=$(ipc_b64enc '$(id)')&lines=$(ipc_b64enc '1;rm -rf /')"
drop_req "m3" "m3|GET_DAEMON_LOG|lines=$(ipc_b64enc '5;echo PWN')"
drop_req "m4" "m4|GET_SUMMARY|id=$(ipc_b64enc '..')"
drop_req "m5" "m5|GET_TASK_DETAIL|id=$(ipc_b64enc '<script>alert(1)</script>')"
poll
badcount=0
for rid in m1 m2 m3 m4 m5; do
    rc=$(req_rc "$rid")
    # m3/m4: daemon log/summary ignore bad keys? lines 非数字 → 归缺省；未知键 → invalid_request
    [ "$rc" = "0" ] || [ "$rc" = "1" ] || [ "$rc" = "3" ] || badcount=$((badcount + 1))
done
[ "$badcount" -eq 0 ] && ok "P3-05 sec-b: malicious ids/lines on read ops -> rc 0/1/3 (no crash, no exec)" || bad "P3-05 sec-b: $badcount unexpected rc"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-05 sec-b: ZERO Root actions executed by malicious read requests" || bad "P3-05 sec-b: exec leaked ($(wc -l < "$EXEC_LOG"))"
[ "$(tc_snap)" = "$SNAP_A" ] && ok "P3-05 sec-b: task-config byte-identical after malicious reads" || bad "P3-05 sec-b: task-config mutated"

# malformed/未知 op → invalid_request
drop_req "m6" "m6|FROBNICATE|"
drop_req "m7" "m7|GET_SUMMARY|lines=$()"
poll
[ "$(req_rc m6)" = "1" ] && ok "P3-05 sec-d: unknown op -> invalid_request" || bad "P3-05 sec-d: unknown op rc=$(req_rc m6)"
[ "$(req_rc m7)" = "1" ] && ok "P3-05 sec-d: malformed params -> invalid_request" || bad "P3-05 sec-d: malformed rc=$(req_rc m7)"

# ── c) <script>/引号/换行 JSON 转义（聚合器直接验证）──────────────────────
esc='<script>alert("x")</script>'
out=$(web_json_escape "$esc")
case "$out" in
    *'<script>'*) bad "P3-05 sec-c: <script> not escaped" ;;
    *) ok "P3-05 sec-c: <script> escaped to \u003c-script" ;;
esac
printf '%s' "$out" | grep -q '\\u003cscript\\u003e' && ok "P3-05 sec-c: \\u003c escape verified" || bad "P3-05 sec-c: \\u003c missing"

out2=$(web_json_escape 'say "hi" and \path')
printf '%s' "$out2" | grep -q '\\"' && printf '%s' "$out2" | grep -q '\\\\' \
    && ok "P3-05 sec-c: double-quote + backslash escaped" || bad "P3-05 sec-c: quote/backslash escape failed: $out2"

# 多行值：不产生裸换行（JSON 字符串内转义为 \n）
out3=$(web_json_escape $'a\nb\tc')
[ "$(printf '%s' "$out3" | awk 'END{print NR}')" -eq 1 ] && ok "P3-05 sec-c: multi-line value stays single-line (no raw newline breakout)" || bad "P3-05 sec-c: newline breakout: $out3"

# ── e) 有界日志 + truncated 标志 ──────────────────────────────────────────
seq 1 700 > "$TASKS_DIR/tsec/output.log"   # > WEBUI_LOG_MAX(500)
drop_req "b1" "b1|GET_TASK_LOG|id=$(ipc_b64enc tsec)&lines=$(ipc_b64enc 9999)"
poll
b1=$(cat "$BASE/ipc/responses/b1.resp")
printf '%s\n' "$b1" | grep -q '#truncated=1' && ok "P3-05 sec-e: task log >500 lines -> truncated flag set" || bad "P3-05 sec-e: truncation missing"
# 响应文件 = 首行(REQ_ID|OP|RC|ERROR) + meta 行 + 内容行；内容行 ≤ WEBUI_LOG_MAX(500)
total_lines=$(printf '%s\n' "$b1" | wc -l)
content_lines=$((total_lines - 2))
[ "$content_lines" -le 500 ] && ok "P3-05 sec-e: task log bounded (content $content_lines ≤ 500 lines)" || bad "P3-05 sec-e: unbounded log (content $content_lines)"

seq 1 300 > "$BASE/su-scheduler.log"
drop_req "b2" "b2|GET_DAEMON_LOG|lines=$(ipc_b64enc 9999)"
poll
printf '%s\n' "$(cat "$BASE/ipc/responses/b2.resp")" | grep -q '"total":300' \
    && ok "P3-05 sec-e: daemon log total counted" || bad "P3-05 sec-e: daemon log total missing"

seq 1 250 > "$TASKS_DIR/tsec/events.log"
drop_req "b3" "b3|GET_TASK_EVENTS|id=$(ipc_b64enc tsec)&lines=$(ipc_b64enc 9999)"
poll
printf '%s\n' "$(cat "$BASE/ipc/responses/b3.resp")" | grep -q '"truncated":1' \
    && ok "P3-05 sec-e: events >200 lines -> truncated flag" || bad "P3-05 sec-e: events truncation missing"

# ── P4-06 Condition 表达式注入：EDIT/VALIDATE 写路径校验期拒绝，零 exec、零 config 写 ──
# condition 是受限表达式；注入/未授权谓词 → EDIT_TASK rc 4（configuration_invalid），
# task-config 逐字节不变、EXEC_LOG 零新增（绝不进入 shell 求值）。
SNAP_C=$(tc_snap)
cond_edit="schema_version=2
id=tsec
trigger=08:30
action.type=command
action.command=echo safe
condition={{ task.state(x) = Y; rm -rf / }}
"
drop_req "c1" "c1|EDIT_TASK|id=$(ipc_b64enc tsec)&payload=$(ipc_b64enc "$cond_edit")"
poll
[ "$(req_rc c1)" = "4" ] && ok "P4-06 sec: EDIT_TASK condition injection -> configuration_invalid (rc 4)" \
    || bad "P4-06 sec: EDIT_TASK condition injection rc=$(req_rc c1)"
[ "$(tc_snap)" = "$SNAP_C" ] && ok "P4-06 sec: task-config byte-identical after condition injection edit" \
    || bad "P4-06 sec: task-config mutated by condition edit"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P4-06 sec: ZERO Root actions executed by condition injection edit" \
    || bad "P4-06 sec: condition edit executed ($(wc -l < "$EXEC_LOG"))"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "webui security tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
