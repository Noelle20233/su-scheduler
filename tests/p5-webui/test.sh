#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# p5-webui/test.sh — P5-06 WebUI 实时状态增强验收
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P5-06，前端为主 + 后端只增 2 键，B7/B8 约束）：
#   §backend-keys   GET_SUMMARY counts.recovering（RECOVERING 不再计入 unknown）；
#                    GET_TASK_DETAIL condition_state（空→ok / 真→ok / 假→unsat /
#                    非法→illegal）与 last_event（ts|event|state|msg 摘要 / 无事件空串）；
#                    只读零 exec。
#   §contract       既有 JSON 键全部仍在（只增键不删字段，B8）：counts 9 键 +
#                    detail 新字段与既有字段并存。
#   §frontend       静态断言 webroot/app.js 周期刷新（setInterval/startRefresh/
#                    stopRefresh）、错误保留（lastData/err-banner）、新字段 textContent
#                    渲染（dependency/condition/dependency_state/gate_state/
#                    condition_state/last_event/last_duration）、waiting/unhealthy/
#                    recovering 计数卡；禁 innerHTML/eval（D28 安全基线）。
#   §regression     read-only/security 关键断言不回归（只读白名单零写 op、
#                    JSON 转义防注入、前端无 Root 直执特征）。
# 前端行为（DOM）不经 shell 直接跑浏览器 → 用 grep 特征断言 + 后端 JSON 行为
# 断言双覆盖（P3-05 同风格）。
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

# ── daemon 上下文 shim（同 tests/webui/read-only.test.sh）────────────────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
: > "$EXEC_LOG"
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

# ── 准备：RUNNING / RECOVERING / WAITING 三任务（覆盖新计数族）───────────────
tcfg_new_task t_a   "08:30" "echo a"   >/dev/null 2>&1
tcfg_new_task t_rec "09:00" "echo rec" >/dev/null 2>&1
tcfg_new_task t_cond "10:00" "echo cond" >/dev/null 2>&1
for id in t_a t_rec t_cond; do mkdir -p "$TASKS_DIR/$id"; done
echo "RUNNING" > "$TASKS_DIR/t_a/state.txt"
echo "1001" > "$TASKS_DIR/t_a/pid.txt"
echo "RECOVERING" > "$TASKS_DIR/t_rec/state.txt"
echo "1002" > "$TASKS_DIR/t_rec/pid.txt"
echo "WAITING" > "$TASKS_DIR/t_cond/state.txt"
printf '2026-09-02 08:30:01|t_a|spawn|STARTING|1001||launched\n' > "$TASKS_DIR/t_a/events.log"
printf '2026-09-02 09:00:05|t_rec|recover|RECOVERING|1002||recovering\n' > "$TASKS_DIR/t_rec/events.log"

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

# 直写文件字段（绕过后端校验，模拟损坏/旧配置——obs_cond_state 防御面）
set_file_field() {   # <file> <key> <value>
    local f=$1 key=$2 val=$3
    if grep -q "^$key=" "$f" 2>/dev/null; then
        grep -v "^$key=" "$f" > "$f.tmp.$$" 2>/dev/null
    else
        cp "$f" "$f.tmp.$$" 2>/dev/null
    fi
    printf '%s=%s\n' "$key" "$val" >> "$f.tmp.$$" 2>/dev/null
    mv "$f.tmp.$$" "$f" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# §backend-keys
# ═══════════════════════════════════════════════════════════════════════════
r=$(send_req "s1" "s1|GET_SUMMARY|")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"recovering":1' \
    && ok "P5-06 agg: GET_SUMMARY counts recovering=1" \
    || bad "P5-06 agg: recovering rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"unknown":0' \
    && ok "P5-06 agg: RECOVERING NOT counted in unknown (unknown=0)" \
    || bad "P5-06 agg: unknown count rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"waiting":1' \
    && ok "P5-06 agg: GET_SUMMARY counts waiting=1 (WAITING intact)" \
    || bad "P5-06 agg: waiting rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"total":3' \
    && ok "P5-06 agg: GET_SUMMARY total=3" \
    || bad "P5-06 agg: total rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

# detail 基础：condition 空 → condition_state ok；last_event 存在（ts|event|state|msg）
r=$(send_req "d1" "d1|GET_TASK_DETAIL|id=$(ipc_b64enc t_a)")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"condition_state":"ok"' \
    && ok "P5-06 agg: detail condition_state=ok (empty condition = always true)" \
    || bad "P5-06 agg: condition_state(empty) rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"last_event":"2026-09-02 08:30:01|spawn|STARTING|launched"' \
    && ok "P5-06 agg: detail last_event = ts|event|state|msg summary" \
    || bad "P5-06 agg: last_event rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"dependency_state":"ok"' \
    && ok "P5-06 agg: detail dependency_state=ok intact" \
    || bad "P5-06 agg: dependency_state rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"
[ "$rc" = "0" ] && printf '%s\n' "$r" | grep -q '"gate_state":""' \
    && ok "P5-06 agg: detail gate_state empty for non-WAITING intact" \
    || bad "P5-06 agg: gate_state rc=$rc payload=$(printf '%s' "$r" | tail -n +2)"

# 合法恒真 condition → ok
tcfg_set_field t_cond condition "{{ time.hour >= 0 }}" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "d2" "d2|GET_TASK_DETAIL|id=$(ipc_b64enc t_cond)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"condition_state":"ok"' \
    && ok "P5-06 agg: condition_state=ok for always-true condition" \
    || bad "P5-06 agg: condition_state(true) payload=$(printf '%s' "$r" | tail -n +2)"

# 合法恒假 condition → unsat
tcfg_set_field t_cond condition "{{ time.hour < 0 }}" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "d3" "d3|GET_TASK_DETAIL|id=$(ipc_b64enc t_cond)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"condition_state":"unsat"' \
    && ok "P5-06 agg: condition_state=unsat for always-false condition" \
    || bad "P5-06 agg: condition_state(false) payload=$(printf '%s' "$r" | tail -n +2)"

# 非法 condition（未知谓词，直写 registry 快照文件模拟损坏配置）→ illegal（防御）
# 注意：直写 task-config 源会被 sched_snapshot_managed 校验拒绝（KEPT 旧快照），
# 因此直接改 registry 快照任务文件——obs_cond_state 防御面正是针对这类运行期坏值。
SNAP_TF=$(registry_task_file t_cond 2>/dev/null)
set_file_field "$SNAP_TF" condition "{{ foo == 1 }}"
r=$(send_req "d4" "d4|GET_TASK_DETAIL|id=$(ipc_b64enc t_cond)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"condition_state":"illegal"' \
    && ok "P5-06 agg: condition_state=illegal (defensive, unknown predicate)" \
    || bad "P5-06 agg: condition_state(illegal) payload=$(printf '%s' "$r" | tail -n +2)"

# 无事件任务 → last_event 空串
tcfg_new_task t_noev "11:00" "echo noev" >/dev/null 2>&1
mkdir -p "$TASKS_DIR/t_noev"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
r=$(send_req "d5" "d5|GET_TASK_DETAIL|id=$(ipc_b64enc t_noev)")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"last_event":""' \
    && ok "P5-06 agg: last_event empty when no events.log" \
    || bad "P5-06 agg: last_event(empty) payload=$(printf '%s' "$r" | tail -n +2)"

# 只读聚合零 exec
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P5-06 agg: all read ops ZERO exec side effects" || bad "P5-06 agg: exec leaked ($(wc -l < "$EXEC_LOG"))"

# ═══════════════════════════════════════════════════════════════════════════
# §contract（只增键不删字段，B8）
# ═══════════════════════════════════════════════════════════════════════════
r=$(send_req "c1" "c1|GET_SUMMARY|")
payload=$(printf '%s\n' "$r" | tail -n +2)
missing=0
for k in '"total":' '"running":' '"healthy":' '"failed":' '"disabled":' '"unhealthy":' '"unknown":' '"waiting":' '"recovering":'; do
    printf '%s' "$payload" | grep -q "$k" || { missing=$((missing + 1)); echo "  missing counts key: $k"; }
done
[ "$missing" -eq 0 ] && ok "P5-06 contract: GET_SUMMARY counts has all 9 keys (only-add, no removal)" \
    || bad "P5-06 contract: $missing counts keys missing"

r=$(send_req "c2" "c2|GET_TASK_DETAIL|id=$(ipc_b64enc t_a)")
payload=$(printf '%s\n' "$r" | tail -n +2)
missing=0
for k in '"id":"t_a"' '"status":"RUNNING"' '"pid":"1001"' '"has_run_dir":1' \
         '"dependency":' '"condition":' '"dependency_state":' '"gate_state":' \
         '"condition_state":' '"last_event":' '"health":{"type":"none"'; do
    printf '%s' "$payload" | grep -q "$k" || { missing=$((missing + 1)); echo "  missing detail key: $k"; }
done
[ "$missing" -eq 0 ] && ok "P5-06 contract: GET_TASK_DETAIL existing + new fields coexist" \
    || bad "P5-06 contract: $missing detail keys missing"

printf '%s\n' "$r" | grep -q '"source":' && ok "P5-06 contract: detail source object intact" \
    || bad "P5-06 contract: source object missing"

# ═══════════════════════════════════════════════════════════════════════════
# §dep-view（P5-07）— GET_SUMMARY tasks[].dependency + dep_errors（B8 只增键）
# ═══════════════════════════════════════════════════════════════════════════
tcfg_new_task t_da "14:00" "echo da" >/dev/null 2>&1
tcfg_new_task t_db "15:00" "echo db" >/dev/null 2>&1
tcfg_new_task t_dc "16:00" "echo dc" >/dev/null 2>&1
tcfg_set_field t_da dependency "t_db,?t_dc" >/dev/null 2>&1   # 必选 t_db + 可选(?)t_dc
sched_reload "$BASE" "$CFG" >/dev/null 2>&1

r=$(send_req "dp1" "dp1|GET_SUMMARY|")
rc=$(resp_rc "$r")
payload=$(printf '%s\n' "$r" | tail -n +2)
[ "$rc" = "0" ] && printf '%s' "$payload" | grep -q '"dependency":"t_db,?t_dc"' \
    && ok "P5-07 dep: GET_SUMMARY tasks[] carries dependency raw string (incl. optional ?)" \
    || bad "P5-07 dep: dependency key rc=$rc payload=$payload"
[ "$rc" = "0" ] && printf '%s' "$payload" | grep -q '"dep_errors":\[\]' \
    && ok "P5-07 dep: dep_errors empty array when dependency graph valid" \
    || bad "P5-07 dep: dep_errors(valid) rc=$rc payload=$payload"
printf '%s' "$payload" | grep -q '"tasks":' && printf '%s' "$payload" | grep -q '"counts":' \
    && ok "P5-07 dep: existing GET_SUMMARY keys coexist with dep_errors (B8)" \
    || bad "P5-07 dep: B8 contract broken"

# 直写 task-config 注入环/未知依赖（绕过后端写路径校验，模拟损坏配置）→ dep_errors 报告
set_file_field "$TCFG_DIR/t_db.task" dependency "t_da"      # 环：t_da->t_db->t_da
set_file_field "$TCFG_DIR/t_dc.task" dependency "ghost"     # 未知依赖 ghost
r=$(send_req "dp2" "dp2|GET_SUMMARY|")
rc=$(resp_rc "$r")
payload=$(printf '%s\n' "$r" | tail -n +2)
[ "$rc" = "0" ] && printf '%s' "$payload" | grep -q "unknown dependency 'ghost' in 't_dc'" \
    && printf '%s' "$payload" | grep -q 'cycle:' \
    && ok "P5-07 dep: dep_errors reports unknown dependency + cycle (read-only)" \
    || bad "P5-07 dep: dep_errors(invalid) rc=$rc payload=$payload"
# dep_errors 读取只读：零 exec、task-config 不被改写（仅测试自身 set_file_field 的注入）
grep -q "dependency=t_da" "$TCFG_DIR/t_db.task" && grep -q "dependency=ghost" "$TCFG_DIR/t_dc.task" \
    && ok "P5-07 dep: injected files intact (dep_errors is read-only)" \
    || bad "P5-07 dep: task-config mutated by read"

# 前端依赖视图静态断言（P5-07 §dep-view）
grep -q '依赖关系' webroot/app.js && ok "P5-07 dep: app.js 依赖关系 view" || bad "P5-07 dep: 依赖关系 missing"
grep -q '正向依赖' webroot/app.js && ok "P5-07 dep: forward-dep list" || bad "P5-07 dep: 正向依赖 missing"
grep -q '反向依赖' webroot/app.js && ok "P5-07 dep: reverse-dep list" || bad "P5-07 dep: 反向依赖 missing"
grep -q 'dep-badge' webroot/app.js && grep -q 'optional' webroot/app.js \
    && ok "P5-07 dep: Required/Optional dep-badge (optional mark)" || bad "P5-07 dep: dep-badge/optional missing"
grep -q 'dep_errors' webroot/app.js && ok "P5-07 dep: app.js renders dep_errors (textContent)" \
    || bad "P5-07 dep: dep_errors rendering missing"
grep -q '"依赖"' webroot/app.js && ok "P5-07 dep: task table has 依赖 column" || bad "P5-07 dep: 依赖 column missing"
grep -q '\.dep-badge.optional' webroot/style.css && ok "P5-07 dep: .dep-badge.optional style" \
    || bad "P5-07 dep: .dep-badge.optional style missing"
grep -q '\.dep-error' webroot/style.css && ok "P5-07 dep: .dep-error style" || bad "P5-07 dep: .dep-error style missing"

# ═══════════════════════════════════════════════════════════════════════════
# §batch-ui（P5-07）— 批量 UI 复用既有 WRITE_OPS（B7 不新增 op）
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'batchBar' webroot/app.js && ok "P5-07 batch-ui: batch bar helper" || bad "P5-07 batch-ui: batchBar missing"
grep -q 'batch-cb' webroot/app.js && ok "P5-07 batch-ui: per-row checkbox (batch-cb)" || bad "P5-07 batch-ui: batch-cb missing"
grep -q 'batch-btn' webroot/app.js && ok "P5-07 batch-ui: batch action buttons" || bad "P5-07 batch-ui: batch-btn missing"
grep -q 'write(op, { id: id })' webroot/app.js \
    && ok "P5-07 batch-ui: batch loops call write(op,{id}) — reuses existing WRITE_OPS (B7)" \
    || bad "P5-07 batch-ui: batch write loop missing"
bb_miss=0
for op in START_TASK STOP_TASK RESTART_TASK CHECK_TASK ENABLE_TASK DISABLE_TASK; do
    grep -q "$op" webroot/app.js || { bb_miss=$((bb_miss + 1)); echo "  missing batch op: $op"; }
done
[ "$bb_miss" -eq 0 ] && ok "P5-07 batch-ui: batch buttons use the existing 6 control ops (no new op)" \
    || bad "P5-07 batch-ui: $bb_miss control ops missing"
grep -q 'var WRITE_OPS' webroot/app.js && ok "P5-07 batch-ui: WRITE_OPS constant intact" \
    || bad "P5-07 batch-ui: WRITE_OPS regressed"
grep -q 'batch-results' webroot/app.js && ok "P5-07 batch-ui: aggregated [{id,rc,error}] results render" \
    || bad "P5-07 batch-ui: batch-results missing"
grep -q '\.batch-btn' webroot/style.css && ok "P5-07 batch-ui: .batch-btn style" || bad "P5-07 batch-ui: .batch-btn style missing"

# ═══════════════════════════════════════════════════════════════════════════
# §frontend（静态特征断言；行为经 grep + 后端 JSON 双覆盖）
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'setInterval' webroot/app.js && ok "P5-06 front: app.js uses setInterval (periodic refresh)" \
    || bad "P5-06 front: setInterval missing"
grep -q 'startRefresh' webroot/app.js && ok "P5-06 front: startRefresh defined" || bad "P5-06 front: startRefresh missing"
grep -q 'stopRefresh' webroot/app.js && ok "P5-06 front: stopRefresh defined (hashchange cleanup)" \
    || bad "P5-06 front: stopRefresh missing"
grep -q 'lastData' webroot/app.js && ok "P5-06 front: lastData cache present (error-retain feature)" \
    || bad "P5-06 front: lastData missing"
grep -q 'err-banner' webroot/app.js && ok "P5-06 front: err-banner overlay present (error retains last data)" \
    || bad "P5-06 front: err-banner missing"
grep -q '刷新失败（上次数据已过期）' webroot/app.js && ok "P5-06 front: stale-data label on refresh failure" \
    || bad "P5-06 front: stale-data label missing"
grep -q 'refresh-indicator' webroot/app.js && ok "P5-06 front: refresh indicator present" || bad "P5-06 front: refresh indicator missing"
for k in dependency condition dependency_state gate_state condition_state last_event; do
    grep -q "kv(\"$k\"" webroot/app.js && ok "P5-06 front: kv renders $k via textContent" \
        || bad "P5-06 front: kv $k missing"
done
grep -q 'last_duration' webroot/app.js && ok "P5-06 front: last_duration rendered" || bad "P5-06 front: last_duration missing"
grep -q 'counts.waiting' webroot/app.js && ok "P5-06 front: waiting count card" || bad "P5-06 front: waiting card missing"
grep -q 'counts.unhealthy' webroot/app.js && ok "P5-06 front: unhealthy count card" || bad "P5-06 front: unhealthy card missing"
grep -q 'counts.recovering' webroot/app.js && ok "P5-06 front: recovering count card" || bad "P5-06 front: recovering card missing"
grep -q 'st-"' webroot/app.js && ok "P5-06 front: status card uses dynamic st-<status> class (WAITING/RECOVERING highlight)" \
    || bad "P5-06 front: status class not dynamic"
grep -q '\.st-WAITING' webroot/style.css && ok "P5-06 front: .st-WAITING style" || bad "P5-06 front: .st-WAITING style missing"
grep -q '\.st-RECOVERING' webroot/style.css && ok "P5-06 front: .st-RECOVERING style" || bad "P5-06 front: .st-RECOVERING style missing"
grep -q '\.err-banner' webroot/style.css && ok "P5-06 front: .err-banner style" || bad "P5-06 front: .err-banner style missing"
grep -q '\.refresh-indicator' webroot/style.css && ok "P5-06 front: .refresh-indicator style" || bad "P5-06 front: .refresh-indicator style missing"

# 安全：禁 innerHTML / eval / document.write / Root 直执（D28 + P5-09 复核基线）
fbad=0
for pat in 'innerHTML' 'eval(' 'document.write' 'su -c' 'sh -c' '/data/adb' 'new Function'; do
    grep -q "$pat" webroot/app.js && { echo "  forbidden pattern in app.js: $pat"; fbad=1; }
done
[ "$fbad" -eq 0 ] && ok "P5-06 front: app.js free of innerHTML/eval/Root-exec patterns (textContent only)" \
    || bad "P5-06 front: forbidden pattern detected in app.js"

# ═══════════════════════════════════════════════════════════════════════════
# §regression（read-only/security 关键断言不回归）
# ═══════════════════════════════════════════════════════════════════════════
banned=""
for op in CREATE_TASK UPDATE_TASK DELETE_TASK ENABLE_TASK DISABLE_TASK START_TASK STOP_TASK RESTART_TASK VALIDATE_TASK; do
    grep -q " $op " <<< "$(sed -n '/^WEBUI_READ_OPS=/p' "$CLI")" && banned="$banned $op"
done
[ -z "$banned" ] && ok "P5-06 regr: WEBUI_READ_OPS still has NO write/control ops (B7)" \
    || bad "P5-06 regr: write ops in whitelist:$banned"

out=$(web_json_escape '<script>alert("x")</script>')
case "$out" in
    *'<script>'*) bad "P5-06 regr: <script> not escaped" ;;
    *) ok "P5-06 regr: web_json_escape still escapes <script>" ;;
esac

# 恶意 id 只读请求零 exec（security §b 关键断言）
: > "$EXEC_LOG"
r=$(send_req "m1" "m1|GET_TASK_DETAIL|id=$(ipc_b64enc 'x;touch '$T'/pwn')")
[ "$(resp_rc "$r")" = "3" ] || [ "$(resp_rc "$r")" = "1" ] \
    && ok "P5-06 regr: malicious id on detail -> rc 3/1 (no crash)" \
    || bad "P5-06 regr: malicious id rc=$(resp_rc "$r")"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P5-06 regr: malicious read ZERO exec" \
    || bad "P5-06 regr: malicious read exec leaked ($(wc -l < "$EXEC_LOG"))"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p5-webui tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
