#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# editor.test.sh — P3-06 WebUI Task Editor（分步表单创建/编辑 Task v2）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（对照 P3-06 验收）：
#   §static  webroot 编辑器资源 + TASK_FORM_SCHEMA + 写白名单 WRITE_OPS + 路由接线；
#   §ipc     GET_TASK_EDIT / EDIT_TASK / VALIDATE_TASK(payload) 经真实 IPC 文件通道；
#   §save    合法 Task 保存并重新加载（EDIT_TASK → GET_TASK_EDIT 回读一致）；
#   §reject  非法 Task 无法保存（rc4 configuration_invalid，不写盘）；
#   §atomic  保存失败旧配置逐字节不变（md5 比对 + 无 tmp 残留）；
#   §no-dup  编辑不产生重复 ID（同 id 覆盖，任务计数不增）；
#   §app      App Action 注入全部拒绝（复用 P2-10 安全门）；
#   §supervisor Health/Recovery 配置可被 Supervisor 真实读取（supervisor_health_spec）。
# 数据来源：真实 daemon IPC 文件通道（同 P3-05/ipc 手法）+ 库函数级断言。
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

# ── §static：webroot 编辑器资源与接线 ───────────────────────────────────
for f in webroot/index.html webroot/app.js webroot/style.css; do
    [ -f "$f" ] && ok "P3-06 static: $f present" || bad "P3-06 static: $f missing"
done
grep -q 'data-view="editor"' webroot/index.html && ok "P3-06 static: editor nav present" || bad "P3-06 static: editor nav missing"
grep -q 'var TASK_FORM_SCHEMA' webroot/app.js && ok "P3-06 static: TASK_FORM_SCHEMA defined" || bad "P3-06 static: TASK_FORM_SCHEMA missing"
grep -q 'var WRITE_OPS' webroot/app.js && ok "P3-06 static: WRITE_OPS defined" || bad "P3-06 static: WRITE_OPS missing"
grep -q 'function renderEditor' webroot/app.js && ok "P3-06 static: renderEditor defined" || bad "P3-06 static: renderEditor missing"
grep -q 'EDIT_TASK' webroot/app.js && grep -q 'VALIDATE_TASK' webroot/app.js && grep -q 'GET_TASK_EDIT' webroot/app.js \
    && ok "P3-06 static: editor uses GET_TASK_EDIT/EDIT_TASK/VALIDATE_TASK" || bad "P3-06 static: editor op refs missing"
grep -q 'r.view === "editor"' webroot/app.js && ok "P3-06 static: editor route wired" || bad "P3-06 static: editor route missing"
grep -q '\.editor-steps' webroot/style.css && ok "P3-06 static: editor css present" || bad "P3-06 static: editor css missing"
grep -q 'function validateForm' webroot/app.js && ok "P3-06 static: frontend validateForm present" || bad "P3-06 static: validateForm missing"
# P4-08：Advanced 步骤开放 dependency/condition 编辑字段（Task v2 managed 域）
grep -q 'dependency:{ step: "Advanced"' webroot/app.js && grep -q 'condition:{ step: "Advanced"' webroot/app.js \
    && ok "P4-08 static: TASK_FORM_SCHEMA has dependency/condition in Advanced step" || bad "P4-08 static: dependency/condition schema fields missing"
grep -q '"dependency=" + (v.dependency' webroot/app.js && grep -q '"condition=" + (v.condition' webroot/app.js \
    && ok "P4-08 static: formToContent serializes dependency/condition keys" || bad "P4-08 static: formToContent dep/cond missing"
grep -q 'v.dependency = map.dependency' webroot/app.js && grep -q 'v.condition = map.condition' webroot/app.js \
    && ok "P4-08 static: taskContentToForm reads dependency/condition" || bad "P4-08 static: taskContentToForm dep/cond missing"
grep -q 'Dependency 格式非法' webroot/app.js && grep -q 'Condition 应形如' webroot/app.js \
    && ok "P4-08 static: validateForm frontend hints for dependency/condition" || bad "P4-08 static: validateForm dep/cond hints missing"

# ── daemon 上下文 shim（同 tests/ipc）───────────────────────────────────
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
resp_err() { printf '%s\n' "$1" | head -1 | cut -d'|' -f4; }

# 合法 payload 构造（完整 Task v2 字段覆盖全部步骤）
make_payload() {   # <id>
    cat <<EOF
schema_version=2
id=$1
name=Editor Demo
enabled=1
description=created via editor
trigger=weekly:1:0800
action.type=command
action.command=echo editor-task
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=process
health.target=su
recovery.type=restart
retry.max=3
retry.interval=30
retry.cooldown=60
advanced.timeout=120
advanced.environment=FOO=bar
advanced.concurrency=1
advanced.logging=500
EOF
}

# ── §ipc + §save：合法 Task 保存并重新加载 ─────────────────────────────
PAYLOAD=$(make_payload task_edit1)
r=$(send_req "ed1" "ed1|EDIT_TASK|id=$(ipc_b64enc task_edit1)&payload=$(ipc_b64enc "$PAYLOAD")")
rc=$(resp_rc "$r")
[ "$rc" = "0" ] && ok "P3-06 save: EDIT_TASK legal task -> rc 0" || bad "P3-06 save: legal rc=$rc err=$(resp_err "$r")"
[ -f "$TCFG_DIR/task_edit1.task" ] && ok "P3-06 save: task file persisted" || bad "P3-06 save: file missing"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
registry_task_ids | grep -q task_edit1 && ok "P3-06 save: task visible after reload" || bad "P3-06 save: not in registry"
r=$(send_req "ed2" "ed2|GET_TASK_EDIT|id=$(ipc_b64enc task_edit1)")
rc=$(resp_rc "$r")
back=$(printf '%s\n' "$r" | tail -n +2)
dec=$(ipc_b64dec "$back")
[ "$rc" = "0" ] && printf '%s\n' "$dec" | grep -q '^name=Editor Demo$' \
    && printf '%s\n' "$dec" | grep -q '^health.type=process$' \
    && printf '%s\n' "$dec" | grep -q '^recovery.type=restart$' \
    && printf '%s\n' "$dec" | grep -q '^retry.max=3$' \
    && printf '%s\n' "$dec" | grep -q '^advanced.logging=500$' \
    && ok "P3-06 save: GET_TASK_EDIT round-trips full task" || bad "P3-06 save: round-trip mismatch rc=$rc"

# ── §reject：非法 Task 无法保存 ─────────────────────────────────────────
BAD1=$(printf 'schema_version=2\nid=task_bad\ntrigger=cron:60 * * * *\naction.type=command\naction.command=echo x\n')
r=$(send_req "re1" "re1|EDIT_TASK|id=$(ipc_b64enc task_bad)&payload=$(ipc_b64enc "$BAD1")")
rc=$(resp_rc "$r")
[ "$rc" = "4" ] && [ ! -f "$TCFG_DIR/task_bad.task" ] && ok "P3-06 reject: invalid trigger -> rc4, not persisted" || bad "P3-06 reject: rc=$rc"
BAD2=$(printf 'schema_version=2\nid=../../etc\ntrigger=boot\naction.type=command\naction.command=echo x\n')
r=$(send_req "re2" "re2|EDIT_TASK|id=$(ipc_b64enc '../../etc')&payload=$(ipc_b64enc "$BAD2")")
rc=$(resp_rc "$r")
# P3-08：路径穿越 id 现被 §25 secv_id_ok 在 dispatch 外层拒绝为 invalid_request（rc 1）
# 或后端校验拒绝（rc 4）——两种都是拒绝、绝不落盘（语义更严，最外层即拦截）。
[ "$rc" = "4" ] || [ "$rc" = "1" ] && [ ! -f "$TCFG_DIR/../../etc" ] && ok "P3-06 reject: path traversal id rejected (rc $rc, not persisted)" || bad "P3-06 reject: traversal rc=$rc"
BAD3=$(printf 'schema_version=2\nid=task_bad3\ntrigger=boot\naction.type=command\naction.command=echo x\nretry.max=999\n')
r=$(send_req "re3" "re3|EDIT_TASK|id=$(ipc_b64enc task_bad3)&payload=$(ipc_b64enc "$BAD3")")
rc=$(resp_rc "$r")
[ "$rc" = "4" ] && ok "P3-06 reject: out-of-range retry -> rc4" || bad "P3-06 reject: retry rc=$rc"
r=$(send_req "va1" "va1|VALIDATE_TASK|payload=$(ipc_b64enc "$PAYLOAD")")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-06 preview: VALIDATE_TASK legal payload -> rc 0" || bad "P3-06 preview: legal rc=$(resp_rc "$r")"
r=$(send_req "va2" "va2|VALIDATE_TASK|payload=$(ipc_b64enc "$BAD1")")
[ "$(resp_rc "$r")" = "4" ] && ok "P3-06 preview: VALIDATE_TASK illegal payload -> rc 4" || bad "P3-06 preview: illegal rc=$(resp_rc "$r")"

# ── §atomic：保存失败旧配置不变 ─────────────────────────────────────────
MD5_BEFORE=$(md5sum "$TCFG_DIR/task_edit1.task" | cut -d' ' -f1)
BAD_EDIT=$(printf 'schema_version=2\nid=task_edit1\ntrigger=delay\naction.type=command\naction.command=echo x\n')
r=$(send_req "at1" "at1|EDIT_TASK|id=$(ipc_b64enc task_edit1)&payload=$(ipc_b64enc "$BAD_EDIT")")
rc=$(resp_rc "$r")
[ "$rc" = "4" ] && ok "P3-06 atomic: invalid edit -> rc4" || bad "P3-06 atomic: rc=$rc"
[ "$(md5sum "$TCFG_DIR/task_edit1.task" | cut -d' ' -f1)" = "$MD5_BEFORE" ] && ok "P3-06 atomic: old config byte-identical after failed edit" || bad "P3-06 atomic: config changed"
ls "$TCFG_DIR"/*.tmp.* >/dev/null 2>&1 && bad "P3-06 atomic: tmp leftover" || ok "P3-06 atomic: no tmp leftover"

# ── §no-dup：编辑不产生重复 ID ──────────────────────────────────────────
COUNT_BEFORE=$(tcfg_task_ids | grep -c '^task_edit1$' || true)
PAYLOAD2=$(printf '%s\n' "$PAYLOAD" | sed 's/^name=.*/name=Renamed/')
r=$(send_req "nd1" "nd1|EDIT_TASK|id=$(ipc_b64enc task_edit1)&payload=$(ipc_b64enc "$PAYLOAD2")")
rc=$(resp_rc "$r")
COUNT_AFTER=$(tcfg_task_ids | grep -c '^task_edit1$' || true)
[ "$rc" = "0" ] && [ "$COUNT_AFTER" = "$COUNT_BEFORE" ] && [ "$COUNT_AFTER" -eq 1 ] \
    && ok "P3-06 no-dup: editing same id keeps single task (no duplicate)" || bad "P3-06 no-dup: count before=$COUNT_BEFORE after=$COUNT_AFTER rc=$rc"
grep -q '^name=Renamed$' "$TCFG_DIR/task_edit1.task" && ok "P3-06 no-dup: edit persisted (name updated)" || bad "P3-06 no-dup: edit not persisted"

# ── §app：App Action 注入全部拒绝 ───────────────────────────────────────
badcount=0
for evil in \
    'app:package:moe.shizuku.privileged.api;rm -rf /' \
    'app:package:com.x" ; su -c id' \
    'app:broadcast:A:msg=x;sh -c id' \
    'app:activity:com.x/.Main$(id)'; do
    INJ_PAYLOAD=$(printf 'schema_version=2\nid=task_inj\ntrigger=boot\naction.type=app\naction.command=%s\n' "$evil")
    rid="app_$(printf '%s' "$evil" | md5sum | cut -c1-6)"
    r=$(send_req "$rid" "$rid|EDIT_TASK|id=$(ipc_b64enc task_inj)&payload=$(ipc_b64enc "$INJ_PAYLOAD")")
    rc=$(resp_rc "$r")
    [ "$rc" = "4" ] || badcount=$((badcount + 1))
done
[ "$badcount" -eq 0 ] && [ ! -f "$TCFG_DIR/task_inj.task" ] \
    && ok "P3-06 app: App Action injection all rejected, task not persisted" || bad "P3-06 app: injection not rejected ($badcount)"

# ── P4-08 §depcond：Dependency/Condition 经既有 EDIT_TASK/VALIDATE_TASK 生效 ──
# 后端权威校验已在 P4-02/03/06 就绪（tcfg_editor_validate_payload：dep 语法 +
# 图校验 + condition 文法）；P4-08 只验证「编辑器开放 → 经既有 IPC payload 路径
# 保存/预览」全链路 + 非法回滚原子性（B9）。
# 先建被依赖任务（task_dep1）——图校验要求依赖引用必须存在（P4-03 D6）。
DEPPAYLOAD=$(printf '%s\n' "$PAYLOAD" | sed 's/^id=.*/id=task_dep1/')
r=$(send_req "dp0" "dp0|EDIT_TASK|id=$(ipc_b64enc task_dep1)&payload=$(ipc_b64enc "$DEPPAYLOAD")")
[ "$(resp_rc "$r")" = "0" ] && ok "P4-08 depcond: seed dependency target task_dep1" || bad "P4-08 depcond: seed rc=$(resp_rc "$r")"

# 合法 payload（dependency 引用已存在任务 + condition 白名单文法）→ 预览合法、保存成功
DC=$(printf '%s\n' "$PAYLOAD" | sed 's/^id=.*/id=task_dc/; s/^advanced.logging=.*/dependency=task_dep1/; s/^description=.*/condition={{ time.hour == 8 }}/')
r=$(send_req "dp1" "dp1|VALIDATE_TASK|payload=$(ipc_b64enc "$DC")")
[ "$(resp_rc "$r")" = "0" ] && ok "P4-08 depcond: VALIDATE_TASK legal dep+cond payload -> rc 0" || bad "P4-08 depcond: validate rc=$(resp_rc "$r")"
r=$(send_req "dp2" "dp2|EDIT_TASK|id=$(ipc_b64enc task_dc)&payload=$(ipc_b64enc "$DC")")
[ "$(resp_rc "$r")" = "0" ] && ok "P4-08 depcond: EDIT_TASK legal dep+cond -> saved" || bad "P4-08 depcond: save rc=$(resp_rc "$r")"
grep -q '^dependency=task_dep1$' "$TCFG_DIR/task_dc.task" && grep -q '^condition={{ time.hour == 8 }}$' "$TCFG_DIR/task_dc.task" \
    && ok "P4-08 depcond: dependency/condition persisted to task-config" || bad "P4-08 depcond: persisted fields missing"
r=$(send_req "dp3" "dp3|GET_TASK_EDIT|id=$(ipc_b64enc task_dc)")
backdc=$(printf '%s\n' "$r" | tail -n +2)
printf '%s\n' "$(ipc_b64dec "$backdc")" | grep -q '^dependency=task_dep1$' \
    && printf '%s\n' "$(ipc_b64dec "$backdc")" | grep -q '^condition={{ time.hour == 8 }}$' \
    && ok "P4-08 depcond: GET_TASK_EDIT round-trips dependency/condition" || bad "P4-08 depcond: round-trip missing dep/cond"

# 非法 payload → rc 4 + task-config 逐字节不变（原子性 B9）
SNAP_DC=$(find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
# 1) 未知依赖 id
UNK=$(printf '%s\n' "$DC" | sed 's/^dependency=.*/dependency=ghost_dep/')
r=$(send_req "dp4" "dp4|EDIT_TASK|id=$(ipc_b64enc task_dc)&payload=$(ipc_b64enc "$UNK")")
[ "$(resp_rc "$r")" = "4" ] && ok "P4-08 depcond: unknown dependency -> configuration_invalid (rc 4)" || bad "P4-08 depcond: unknown-dep rc=$(resp_rc "$r")"
# 2) 依赖环（task_dep1 → task_dc → task_dep1）
CYC=$(printf '%s\n' "$DEPPAYLOAD" | sed 's/^advanced.logging=.*/dependency=task_dc/')
r=$(send_req "dp5" "dp5|EDIT_TASK|id=$(ipc_b64enc task_dep1)&payload=$(ipc_b64enc "$CYC")")
[ "$(resp_rc "$r")" = "4" ] && ok "P4-08 depcond: dependency cycle -> configuration_invalid (rc 4)" || bad "P4-08 depcond: cycle rc=$(resp_rc "$r")"
# 3) 非法 condition 文法（P5-03 反转：`>=` 已合法 → 改用越界数值 hour>=24，仍非法）
CONDBAD=$(printf '%s\n' "$DC" | sed 's/^condition=.*/condition={{ time.hour >= 24 }}/')
r=$(send_req "dp6" "dp6|EDIT_TASK|id=$(ipc_b64enc task_dc)&payload=$(ipc_b64enc "$CONDBAD")")
[ "$(resp_rc "$r")" = "4" ] && ok "P4-08 depcond: illegal condition grammar -> configuration_invalid (rc 4)" || bad "P4-08 depcond: cond rc=$(resp_rc "$r")"
# 原子性：全部失败编辑后 task-config 快照逐字节一致
[ "$(find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1)" = "$SNAP_DC" ] \
    && ok "P4-08 depcond: task-config byte-identical after failed dep/cond edits (B9)" || bad "P4-08 depcond: task-config mutated"

# ── §supervisor：Health/Recovery 可被 Supervisor 真实读取 ───────────────
spec=$(supervisor_health_spec "$TCFG_DIR/task_edit1.task")
[ "$spec" = "process:su" ] && ok "P3-06 supervisor: health spec read from saved task (process:su)" || bad "P3-06 supervisor: spec='$spec'"
grep -q '^recovery.type=restart$' "$TCFG_DIR/task_edit1.task" \
    && ok "P3-06 supervisor: recovery.type=restart persisted" || bad "P3-06 supervisor: recovery missing"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "webui editor tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
