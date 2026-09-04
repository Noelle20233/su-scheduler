#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# fuzz.sh — P3-08 输入安全（fuzz + 命令注入）验收
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 安全声明（对照 P3-08 验收）：
#   a) IPC 请求白名单：未知/超长/坏 base64/未知参数键 → invalid_request（rc 1）零副作用
#   b) Task ID 字符集：恶意 id（元字符/路径穿越）→ 拒绝（rc 1/3）零 exec、零写盘
#   c) App Action 参数校验：结构化 app spec 注入全拒（P2-10 复用）；脚本/命令多行拒
#   d) 请求大小限制：>IPC_REQ_MAX 超长请求 → invalid_request
#   e) 命令注入：START/CREATE/UPDATE 传 command= 注入 → 参数键白名单 / 校验拒绝，绝不执行注入串
# 期望：全部注入样例被拒绝；task-config 逐字节不变；EXEC_LOG 零新增。
# 加载：`. ./$RTLIB`（与既有 P3-04/05 security 套件同法）。
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

# ── daemon 上下文 shim（同 P3-04 security：execute_task 被拦截，记 EXEC_LOG）──
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"; mkdir -p "$d"
    echo "$id|$cmd|$tmx|$itr|$ns|$ne|$msg" >> "$EXEC_LOG"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"; echo "managed" > "$TCFG_DIR/MANAGED"
ipc_server_init "$BASE" >/dev/null 2>&1

poll() { ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1; }
drop_req() { printf '%s\n' "$2" > "$BASE/ipc/requests/$1.req"; }
req_rc()  { cat "$BASE/ipc/responses/$1.resp" 2>/dev/null | head -1 | cut -d'|' -f3; }
tc_snap() { find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

SNAP_A=$(tc_snap)
: > "$EXEC_LOG"

# ── a) IPC 请求白名单 / 格式 fuzz ─────────────────────────────────────────
# 先全部落盘，再一次性 poll（fuzz 请求都被拒绝 → 零副作用）
drop_req "f01" "f01|FROBNICATE|"
drop_req "f02" "|GET_TASKS|"
drop_req "f03" "a/b|GET_TASKS|"
drop_req "f04" "a b|GET_TASKS|"
drop_req "f05" "f05|GET_TASKS|id=\$(rm -rf /)"
drop_req "f06" "f06|GET_SUMMARY|evil=1"
drop_req "f07" "f07|GET_TASKS|id=x;y"
drop_req "f08" "f08|GET_TASK_STATUS|id="
big=$(printf 'A%.0s' $(seq 1 9000))
drop_req "f09" "f09|GET_TASKS|p=$(b64 "$big")"
poll
fuzz_rc_ok=1
check_rej() {   # <expect_rc> <desc> <rid>
    rc=$(req_rc "$3")
    case "$rc" in
        "$1") ok "P3-08 fuzz-a: $2 -> rc $1" ;;
        *) bad "P3-08 fuzz-a: $2 rc='$rc' (want $1)"; fuzz_rc_ok=0 ;;
    esac
}
# 未知 op
check_rej 1 "unknown op FROBNICATE" f01
# 空 req id
check_rej 1 "empty req_id"           f02
# req id 含非法字符
check_rej 1 "req_id with slash"       f03
check_rej 1 "req_id with space"       f04
# 坏 base64 参数值
check_rej 1 "bad base64 value"        f05
# 未知参数键
check_rej 1 "unknown param key"       f06
# 非 base64 字母表值
check_rej 1 "param value with ;"      f07
# 空参数值
check_rej 1 "empty param value"       f08
# 请求大小限制
check_rej 1 "request > IPC_REQ_MAX" f09

# ── b) Task ID 字符集 / 路径穿越 ───────────────────────────────────────────
# 路径穿越 id：`..`、`/`、反斜杠、空白、元字符 → 拒绝（rc 1 或 3）零 exec
rid=0
for t in "traversal ../x" "abs /etc" "backslash a\\\\b" "semicolon a;b" \
         "space a b" "shellcmd \$(id)" "pipe a|b" "amp a&b" "quote a\"b" "bracket a[b]"; do
    desc=${t%% *}; idstr=${t#* }
    rid=$((rid + 1))
    drop_req "fid$rid" "fid$rid|GET_TASK_DETAIL|id=$(b64 "$idstr")"
done
poll
idbad=0
for rid in $(seq 1 10); do
    rc=$(req_rc "fid$rid")
    case "$rc" in 1|3) ;; *) idbad=$((idbad + 1)) ;; esac
done
[ "$idbad" -eq 0 ] && ok "P3-08 fuzz-b: 10 malicious/char-set-bad ids all rejected (rc 1/3)" || bad "P3-08 fuzz-b: $idbad malicious ids not rejected"

# ── e) 命令注入（START/CREATE/UPDATE 带 command）─────────────────────────
# 建一个 registry 任务
mkid="task_fz_1"
[ -f "$TCFG_DIR/$mkid.task" ] || {
    tcfg_new_task "$mkid" "09:00" "echo safe" >/dev/null 2>&1
    sched_reload "$BASE" "$CFG" >/dev/null 2>&1
}
: > "$EXEC_LOG"
# START_TASK 带 command（参数键白名单应拒绝）→ 绝不执行注入串
evil=$(printf 'echo PWN > %s/pwn' "$T" | base64 | tr -d '\n')
drop_req "inj1" "inj1|START_TASK|id=$(b64 "$mkid")&command=$evil"
poll
rc=$(req_rc "inj1")
[ "$rc" = "1" ] && ok "P3-08 fuzz-e: START_TASK with command param -> invalid_request" || bad "P3-08 fuzz-e: START_TASK command rc=$rc"
[ ! -f "$T/pwn" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-08 fuzz-e: injected command never executed" || bad "P3-08 fuzz-e: injection executed (pwn/exec)"

# CREATE_TASK 命令含多行/注入 → 校验拒绝
drop_req "inj2" "inj2|CREATE_TASK|trigger=$(b64 '09:00')&command=$(b64 'echo ok
touch /pwn2')"
poll
rc=$(req_rc "inj2")
[ "$rc" = "4" ] && ok "P3-08 fuzz-e: CREATE_TASK multi-line command -> configuration_invalid" || bad "P3-08 fuzz-e: CREATE_TASK multiline rc=$rc"
[ ! -f /pwn2 ] && ok "P3-08 fuzz-e: CREATE_TASK injection not executed" || bad "P3-08 fuzz-e: CREATE_TASK executed"

# UPDATE_TASK 命令注入（合法 id 但命令含 `;rm`）→ 命令只取自已校验任务文件；更新后命令为注入串
#   —— UPDATE_TASK 允许改 command，但必须经单行校验；注入串含元字符在命令本体里仅作数据存储
#   （执行路径仍由 daemon 读取；这里验证 UPDATE 校验拒绝多行注入）
drop_req "inj3" "inj3|UPDATE_TASK|id=$(b64 "$mkid")&command=$(b64 'echo ok; rm -rf /')"
poll
rc=$(req_rc "inj3")
# 单行 `;` 命令是合法 command（daemon 才决定是否执行）；UPDATE 应接受单行 → rc 0
# 关键安全点：UPDATE 不允许多行注入（换行破坏 task 单行 key=value 存储）
[ "$rc" = "0" ] && ok "P3-08 fuzz-e: UPDATE_TASK single-line command accepted (stored as data, executed only by daemon)" || bad "P3-08 fuzz-e: UPDATE single-line rc=$rc"
drop_req "inj4" "inj4|UPDATE_TASK|id=$(b64 "$mkid")&command=$(b64 'echo ok
rm -rf /')"
poll
rc=$(req_rc "inj4")
[ "$rc" = "4" ] && ok "P3-08 fuzz-e: UPDATE_TASK multi-line command -> configuration_invalid (no task-file pollution)" || bad "P3-08 fuzz-e: UPDATE multiline rc=$rc"

# ── c) App Action 注入（复用 P2-10 结构化校验，经 VALIDATE_TASK payload）───
app_bad="schema_version=2
id=app_bad
trigger=09:00
action.type=app
action.command=app:package:com.foo;\$(id)
"
drop_req "app1" "app1|VALIDATE_TASK|payload=$(b64 "$app_bad")"
poll
rc=$(req_rc "app1")
[ "$rc" = "4" ] && ok "P3-08 fuzz-c: App Action shell-injection spec -> configuration_invalid" || bad "P3-08 fuzz-c: app injection rc=$rc"

# 脚本路径校验：相对路径 / 目录 → 拒
scr_bad="schema_version=2
id=scr_bad
trigger=09:00
action.type=script
action.command=./run.sh
"
drop_req "scr1" "scr1|VALIDATE_TASK|payload=$(b64 "$scr_bad")"
poll
rc=$(req_rc "scr1")
[ "$rc" = "4" ] && ok "P3-08 fuzz-c: script relative path -> configuration_invalid" || bad "P3-08 fuzz-c: script relative rc=$rc"

# ── P4-06 Condition 表达式注入：校验期拒绝，零副作用、零执行 ────────────
# condition 是受限表达式（{{ 谓词 }}）；注入串 / 未授权谓词 / 越界 / 穿越 → VALIDATE_TASK
# 拒绝（rc 4），且绝不进入 shell 求值路径（EXEC_LOG 零新增）。
cond_inj_cases=(
  "{{ task.state(x) = Y; rm -rf / }}"
  '$(id)'
  'x }; pwd'
  '{{ env.HOME == /root }}'
  '{{ time.hour == 99 }}'
  '{{ file.exists(/etc/passwd) }}'
  '{{ time.hour >= 8 }}'
  'sh -c id'
)
cid=0
for cexpr in "${cond_inj_cases[@]}"; do
    cid=$((cid + 1))
    cond_payload=$(printf 'schema_version=2\nid=cond_inj_%d\ntrigger=09:00\ncondition=%s\naction.command=echo ok\n' "$cid" "$cexpr")
    drop_req "cinj$cid" "cinj$cid|VALIDATE_TASK|payload=$(b64 "$cond_payload")"
done
SNAP_C=$(tc_snap)
poll
cbad=0
for cid in $(seq 1 ${#cond_inj_cases[@]}); do
    rc=$(req_rc "cinj$cid")
    [ "$rc" = "4" ] || cbad=$((cbad + 1))
done
[ "$cbad" -eq 0 ] && ok "P4-06 fuzz: ${#cond_inj_cases[@]} condition injection forms rejected (rc 4, no shell eval)" \
    || bad "P4-06 fuzz: $cbad condition injection forms NOT rejected"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P4-06 fuzz: ZERO Root actions executed by condition injection (no shell execution)" \
    || bad "P4-06 fuzz: condition injection executed ($(wc -l < "$EXEC_LOG"))"
[ "$(tc_snap)" = "$SNAP_C" ] && ok "P4-06 fuzz: task-config byte-identical after condition injection" \
    || bad "P4-06 fuzz: task-config mutated by condition injection"

# ── P4-08 Dependency 注入：VALIDATE_TASK/EDIT_TASK 校验期拒绝，零 exec ────
# 编辑器开放 dependency 后（P4-08）：恶意依赖（路径穿越/元字符/环）→ 后端权威
# 拒绝（rc 4），绝不写盘、绝不执行。走既有 VALIDATE_TASK/EDIT_TASK payload 路径。
dep_inj_cases=(
  '../etc/passwd'
  'a/b:c'
  'task_x; rm -rf /'
  '$(id)'
  'task_y:IDLE'
)
didx=0
for dexpr in "${dep_inj_cases[@]}"; do
    didx=$((didx + 1))
    dep_payload=$(printf 'schema_version=2\nid=dep_inj_%d\ntrigger=09:00\ncondition= dependency=%s\naction.command=echo ok\n' "$didx" "$dexpr")
    drop_req "dinj$didx" "dinj$didx|VALIDATE_TASK|payload=$(b64 "$dep_payload")"
done
SNAP_DEP=$(tc_snap)
poll
depbad=0
for didx in $(seq 1 ${#dep_inj_cases[@]}); do
    rc=$(req_rc "dinj$didx")
    [ "$rc" = "4" ] || depbad=$((depbad + 1))
done
[ "$depbad" -eq 0 ] && ok "P4-08 fuzz: ${#dep_inj_cases[@]} dependency injection forms rejected (rc 4)" \
    || bad "P4-08 fuzz: $depbad dependency injection forms NOT rejected"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P4-08 fuzz: ZERO Root actions executed by dependency injection" \
    || bad "P4-08 fuzz: dependency injection executed ($(wc -l < "$EXEC_LOG"))"
[ "$(tc_snap)" = "$SNAP_DEP" ] && ok "P4-08 fuzz: task-config byte-identical after dependency injection" \
    || bad "P4-08 fuzz: task-config mutated by dependency injection"

# ── 副作用：task-config 逐字节不变；EXEC_LOG 仅安全启动那一次（如有）───
# 前面所有恶意请求不应改 task-config（除 UPDATE 合法更新 command 外）
grep -q '^action.command=echo ok; rm -rf /$' "$TCFG_DIR/$mkid.task" 2>/dev/null \
    && ok "P3-08 fuzz: UPDATE persisted single-line command (by design, daemon-owned exec)" \
    || bad "P3-08 fuzz: UPDATE command not persisted"
# 恢复基线：把 mkid 命令改回 echo safe（证明仅 UPDATE 是唯一合法写）
tcfg_set_field "$mkid" action.command "echo safe" >/dev/null 2>&1

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "security fuzz tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1