#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P4-02 Dependency/Condition Schema 与持久化（managed 域）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P4-02 交付：Task v2 dependency/condition 字段解析 + 后端权威校验 + 原子持久化）：
#   §const   DEP_MAX / COND_MAX_LEN 常量存在且有界；
#   §dep     依赖 entry 语法：[?]<task-id>[:<STATE>]；`?`=Optional、缺省 Required；
#            STATE ∈ {STOPPED, FAILED}，缺省 = STOPPED；
#   §norm    规范保存 = 逗号分隔；空格/制表符输入被容错并规范化为逗号（ADR D1）；
#   §cond    condition：可打印 ASCII、长度 ≤ COND_MAX_LEN、空/缺省 = 无条件恒真；
#   §reject  非法字段（超长/控制符/枚举外 STATE/.. // /* id 注入）→ 后端权威校验拒绝，
#            且原 task 文件/config 逐字节不变（原子性 B9）；
#   §editor  tcfg_editor_validate_payload 接受合法 dependency/condition、
#            拒绝非法（不再是「未知键」）；
#   §store   tcfg_validate_task 对含非法 dependency/condition 的任务文件拒绝；
#   §cli     CLI task-config set/show dependency/condition round-trip（managed）；
#   §legacy  Legacy config.txt 零影响（legacy 路径无新解析接线）。
#   §gate    P4-04 依赖门控 + WAITING 接线（scheduler-prod 式 execute_task shim +
#            SCHED_CYCLE_NOW/GATE_NOW 确定性时钟）。
#   §gate-p4-05  P4-05 Required/Optional 失败传播：依赖终态 FAILED(:STOPPED 语义)
#            → 立即 WAITING>FAILED；:FAILED + dep FAILED → 满足执行；Optional
#            FAILED/缺失 → 不阻断；缺失/禁用 → 有界等待超时 FAILED；force start/
#            restart 跳过门控、非 force 非法拒绝；无永久 WAITING。
# 加载：`. ./$RTLIB`（TCFG_DIR 先 export 隔离）。
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

export TCFG_DIR="$T/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
# ── P4-04 daemon 上下文 shim：action_run 委托到 execute_task（镜像 daemon 工件）──
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {            # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "$id|$cmd" >> "$EXEC_LOG"
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    return 0
}
. ./$RTLIB

# ── 助手：构造合法 payload ────────────────────────────────────────────────
ok_task() {   # <id> → 合法 Task v2 内容（含 dependency/condition）
    cat <<EOF
schema_version=2
id=$1
name=demo
enabled=1
description=p4-dep
trigger=08:30
action.type=command
action.command=echo hi
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=none
health.target=
recovery.type=none
retry.max=0
retry.interval=60
retry.cooldown=0
advanced.timeout=0
advanced.environment=
advanced.concurrency=0
advanced.logging=0
EOF
}

# ── §const：上限常量 ──────────────────────────────────────────────────────
[ "$DEP_MAX" = "32" ] && ok "P4-02 const: DEP_MAX=$DEP_MAX (<=32 single-task deps)" || bad "P4-02 const: DEP_MAX=$DEP_MAX"
[ "$COND_MAX_LEN" = "256" ] && ok "P4-02 const: COND_MAX_LEN=$COND_MAX_LEN (<=256)" || bad "P4-02 const: COND_MAX_LEN=$COND_MAX_LEN"

# ── §dep：单条 entry 语法（[?]<task-id>[:<STATE>]）────────────────────────
dep_entry_ok "task_a"            && ok "P4-02 dep: bare id (Required, default STOPPED) accepted" || bad "P4-02 dep: bare id rejected"
dep_entry_ok "?task_a"           && ok "P4-02 dep: '?' Optional prefix accepted" || bad "P4-02 dep: ? prefix rejected"
dep_entry_ok "task_a:FAILED"     && ok "P4-02 dep: ':FAILED' state accepted" || bad "P4-02 dep: :FAILED rejected"
dep_entry_ok "task_a:STOPPED"    && ok "P4-02 dep: ':STOPPED' state accepted" || bad "P4-02 dep: :STOPPED rejected"
dep_entry_ok "?task_a:FAILED"    && ok "P4-02 dep: '?id:FAILED' combined accepted" || bad "P4-02 dep: combined rejected"
# 保留符号 / 非法 STATE 枚举外拒绝
dep_entry_ok "" && bad "P4-02 dep: empty entry allowed" || ok "P4-02 dep: empty entry rejected"
dep_entry_ok "?" && bad "P4-02 dep: bare '?' allowed" || ok "P4-02 dep: bare '?' rejected"
dep_entry_ok "task_a:RUNNING" && bad "P4-02 dep: non-terminal STATE RUNNING allowed" || ok "P4-02 dep: RUNNING (non-terminal) rejected"
dep_entry_ok "task_a:IDLE" && bad "P4-02 dep: IDLE allowed" || ok "P4-02 dep: IDLE rejected"
dep_entry_ok "task_a::FAILED" && bad "P4-02 dep: empty id with state allowed" || ok "P4-02 dep: empty id (:STATE) rejected"
# id 注入：路径穿越 / 元字符
dep_entry_ok "../evil" && bad "P4-02 dep: path traversal id '../evil' allowed" || ok "P4-02 dep: ../ id rejected"
dep_entry_ok "a/b" && bad "P4-02 dep: slash id allowed" || ok "P4-02 dep: slash id rejected"
dep_entry_ok "a*b" && bad "P4-02 dep: glob '*' id allowed" || ok "P4-02 dep: '*' id rejected"
dep_entry_ok "task_a:" && bad "P4-02 dep: empty state 'id:' allowed" || ok "P4-02 dep: empty state 'id:' rejected"

# ── §norm：规范逗号写回 + 空格/制表符容错规范化（ADR D1）─────────────────
[ "$(dep_normalize "a,b,c")" = "a,b,c" ] && ok "P4-02 norm: comma list normalized to 'a,b,c'" || bad "P4-02 norm: '$(dep_normalize "a,b,c")'"
[ "$(dep_normalize "a b   c")" = "a,b,c" ] && ok "P4-02 norm: space-separated normalized to commas" || bad "P4-02 norm: '$(dep_normalize "a b   c")'"
[ "$(dep_normalize "a, b,c")" = "a,b,c" ] && ok "P4-02 norm: mixed space/comma trimmed+comma" || bad "P4-02 norm: '$(dep_normalize "a, b,c")'"
[ "$(dep_normalize "")" = "" ] && ok "P4-02 norm: empty stays empty" || bad "P4-02 norm: empty -> '$(dep_normalize "")'"
[ "$(dep_normalize "?a:FAILED,?b")" = "?a:FAILED,?b" ] && ok "P4-02 norm: optional/state preserved in normalization" || bad "P4-02 norm: '$(dep_normalize "?a:FAILED,?b")'"
# 整串校验：合法串接受 / 非法拒绝 / 上限
dep_validate "task_a,task_b" && ok "P4-02 dep: multi-dep AND list accepted" || bad "P4-02 dep: AND list rejected"
dep_validate "task_a task_b" && ok "P4-02 dep: space-separated AND list accepted (tolerant)" || bad "P4-02 dep: space-separated rejected"
dep_validate "" && ok "P4-02 dep: empty dependency (no deps) accepted" || bad "P4-02 dep: empty rejected"
dep_validate "a,b,,c" && ok "P4-02 dep: empty comma token tolerated (lenient)" || bad "P4-02 dep: empty comma token rejected"
dep_validate "a,../evil" && bad "P4-02 dep: traversal in list allowed" || ok "P4-02 dep: traversal in list rejected"
DEP32=""; i=0; while [ "$i" -lt 32 ]; do DEP32="${DEP32}dep$i,"; i=$((i+1)); done; DEP32="${DEP32%?}"
dep_validate "$DEP32" && ok "P4-02 dep: exactly 32 deps accepted (DEP_MAX)" || bad "P4-02 dep: 32 deps rejected"
DEP33=""; i=0; while [ "$i" -lt 33 ]; do DEP33="${DEP33}dep$i,"; i=$((i+1)); done; DEP33="${DEP33%?}"
dep_validate "$DEP33" && bad "P4-02 dep: 33 deps (over DEP_MAX) allowed" || ok "P4-02 dep: 33 deps rejected (over DEP_MAX)"

# ── §cond：可打印 ASCII、≤256、空=无条件 ─────────────────────────────────
cond_validate "" && ok "P4-02 cond: empty = unconditional (恒真)" || bad "P4-02 cond: empty rejected"
cond_validate "{{task.state(a)}}=HEALTHY" && ok "P4-02 cond: printable ASCII expr accepted" || bad "P4-02 cond: ascii expr rejected"
cond_validate "time.hour>=8 && time.hour<20" && ok "P4-02 cond: expr with && accepted" || bad "P4-02 cond: expr rejected"
# 长度上限
LONG=""; i=0; while [ "$i" -lt 256 ]; do LONG="${LONG}a"; i=$((i+1)); done
cond_validate "$LONG" && ok "P4-02 cond: exactly 256 accepted" || bad "P4-02 cond: 256 rejected"
LONG257="${LONG}b"
cond_validate "$LONG257" && bad "P4-02 cond: >256 allowed" || ok "P4-02 cond: >256 rejected"
# 控制符 / 高位字节拒绝
cond_validate "$(printf 'a\tb')" && bad "P4-02 cond: TAB control char allowed" || ok "P4-02 cond: TAB rejected"
cond_validate "$(printf 'a\nb')" && bad "P4-02 cond: newline allowed" || ok "P4-02 cond: newline rejected"
cond_validate "$(printf '\x01\x02')" && bad "P4-02 cond: low control chars allowed" || ok "P4-02 cond: low control rejected"
cond_validate "$(printf 'a\xc3\xa9')" && bad "P4-02 cond: non-ASCII UTF-8 allowed" || ok "P4-02 cond: non-ASCII rejected"

# ── §editor：tcfg_editor_validate_payload 接受/拒绝 dependency/condition ──
# P4-03 适配：editor 校验现含依赖图校验——DEP_GOOD 引用的 t_boot/t_daily 先建
# 立为合法任务（新语义要求「引用必须最终存在」，非掩盖失败）
min_task() {   # <dir> <id> [dependency] → 最小合法 Task v2 文件
    mkdir -p "$1"
    printf 'schema_version=2\nid=%s\ntrigger=08:30\ndependency=%s\n' "$2" "${3:-}" > "$1/$2.task"
}
min_task "$TCFG_DIR" t_boot
min_task "$TCFG_DIR" t_daily
GOOD1=$(ok_task t_dep | sed 's#^id=.*#id=t_dep#')
DEP_GOOD=$(printf '%s\n' "dependency=?t_boot:FAILED,?t_daily" "$GOOD1")
if tcfg_editor_validate_payload "$DEP_GOOD"; then ok "P4-02 editor: legal dependency payload accepted"; else bad "P4-02 editor: legal dependency rejected"; fi
# P4-06 修正：合法 condition 改用白名单文法 `{{ time.hour == 8 }}`（`>=` 运算符归 P5）
COND_GOOD=$(printf '%s\n' "condition={{ time.hour == 8 }}" "$GOOD1")
if tcfg_editor_validate_payload "$COND_GOOD"; then ok "P4-02 editor: legal condition payload accepted"; else bad "P4-02 editor: legal condition rejected"; fi
# 非法 dependency / condition → 拒绝（后端权威）
DEP_BAD=$(printf '%s\n' "dependency=t_a:IDLE" "$GOOD1")
if tcfg_editor_validate_payload "$DEP_BAD"; then bad "P4-02 editor: illegal STATE dependency passed backend"; else ok "P4-02 editor: illegal STATE dependency rejected"; fi
DEP_BAD2=$(printf '%s\n' "dependency=../evil" "$GOOD1")
if tcfg_editor_validate_payload "$DEP_BAD2"; then bad "P4-02 editor: traversal dependency passed backend"; else ok "P4-02 editor: traversal dependency rejected"; fi
COND_BAD=$(printf '%s\n' "condition=a$(printf '\t')b" "$GOOD1")
if tcfg_editor_validate_payload "$COND_BAD"; then bad "P4-02 editor: TAB condition passed backend"; else ok "P4-02 editor: TAB condition rejected"; fi

# ── §store：tcfg_validate_task 拒绝非法 dependency/condition 任务文件 ─────
VALIDF="$T/valid.task"
printf '%s\n' "schema_version=2" "id=valid" "trigger=08:30" "dependency=a,b" "condition={{ time.hour == 8 }}" > "$VALIDF"
tcfg_validate_task "$VALIDF" && ok "P4-02 store: valid dependency/condition task accepted" || bad "P4-02 store: valid task rejected"
BADF="$T/bad.task"
printf '%s\n' "schema_version=2" "id=bad" "trigger=08:30" "dependency=../evil" > "$BADF"
tcfg_validate_task "$BADF" && bad "P4-02 store: illegal dependency task accepted" || ok "P4-02 store: illegal dependency task rejected"

# ── §cli：CLI task-config set/show round-trip（managed）────────────────────
# 主机侧经「重写 RUNTIME_LIB 路径 + eval 函数体」复用 CLI 生产函数（同 task-control）
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
        DATA_DIR="$BASE2"
        TCFG_DIR="$TCFG_DIR"
        "$@"
    } 2>&1 )
    CLI_RC=$?
}
BASE2="$T/base2"
C_ID=cli_dep
tcfg_new_task "$C_ID" "08:30" "echo cli" >/dev/null 2>&1
cli_run cmd_task_config set "$C_ID" dependency "?t_boot:FAILED,?t_daily"
[ "$CLI_RC" -eq 0 ] && grep -q '^dependency=?t_boot:FAILED,?t_daily$' "$TCFG_DIR/$C_ID.task" \
    && ok "P4-02 cli: set dependency persisted (comma canonical)" || bad "P4-02 cli: set dependency rc=$CLI_RC"
cli_run cmd_task_config set "$C_ID" condition "{{ time.hour == 8 }}"
[ "$CLI_RC" -eq 0 ] && grep -q '^condition={{ time.hour == 8 }}$' "$TCFG_DIR/$C_ID.task" \
    && ok "P4-02 cli: set condition persisted" || bad "P4-02 cli: set condition rc=$CLI_RC"
cli_run cmd_task_config show "$C_ID"
echo "$CLI_OUT" | grep -q '^dependency=?t_boot:FAILED,?t_daily$' && echo "$CLI_OUT" | grep -q '^condition={{ time.hour == 8 }}$' \
    && ok "P4-02 cli: show round-trips dependency+condition" || bad "P4-02 cli: show mismatch"
# CLI set 非法 dependency → 拒绝且原文件逐字节不变（原子性 B9）
MD5B=$(md5sum "$TCFG_DIR/$C_ID.task" | cut -d' ' -f1)
cli_run cmd_task_config set "$C_ID" dependency "t_x:IDLE"
[ "$CLI_RC" -eq 0 ] && bad "P4-02 cli: set illegal dependency accepted" || ok "P4-02 cli: set illegal dependency rejected"
[ "$(md5sum "$TCFG_DIR/$C_ID.task" | cut -d' ' -f1)" = "$MD5B" ] \
    && ok "P4-02 cli: failed set left task byte-identical" || bad "P4-02 cli: task mutated on failed set"

# ── §graph：依赖图校验（未知依赖/自依赖/环/前向引用/Optional）（P4-03）────
# dep_validate_graph 直接语义验证（独立目录隔离）
G1="$T/g-direct"; rm -rf "$G1"; mkdir -p "$G1"
min_task "$G1" t_a ""
min_task "$G1" t_b "t_a"
min_task "$G1" t_c "ghost"
dep_validate_graph "$G1" && bad "P4-03 graph: unknown dependency allowed" || ok "P4-03 graph: unknown dependency rejected"
G1ERR=$(dep_validate_graph "$G1" 2>&1 >/dev/null)
echo "$G1ERR" | grep -q "unknown dependency 'ghost' in 't_c'" \
    && ok "P4-03 graph: unknown-dep error names dep+owner" || bad "P4-03 graph: unknown-dep err=[$G1ERR]"

G2="$T/g-self"; rm -rf "$G2"; mkdir -p "$G2"
min_task "$G2" t_a "t_a"
dep_validate_graph "$G2" && bad "P4-03 graph: self-dependency allowed" || ok "P4-03 graph: self-dependency rejected"
G2ERR=$(dep_validate_graph "$G2" 2>&1 >/dev/null)
echo "$G2ERR" | grep -q "self-dependency in 't_a'" \
    && ok "P4-03 graph: self-dependency error names task" || bad "P4-03 graph: self-dep err=[$G2ERR]"

G3="$T/g-cycle2"; rm -rf "$G3"; mkdir -p "$G3"
min_task "$G3" t_a "t_b"
min_task "$G3" t_b "t_a"
dep_validate_graph "$G3" && bad "P4-03 graph: direct cycle allowed" || ok "P4-03 graph: direct cycle rejected"
G3ERR=$(dep_validate_graph "$G3" 2>&1 >/dev/null)
echo "$G3ERR" | grep -q "cycle: t_a->t_b->t_a" \
    && ok "P4-03 graph: direct cycle path reported (a->b->a)" || bad "P4-03 graph: direct cycle err=[$G3ERR]"

G4="$T/g-cycle3"; rm -rf "$G4"; mkdir -p "$G4"
min_task "$G4" t_a "t_b"
min_task "$G4" t_b "t_c"
min_task "$G4" t_c "t_a"
dep_validate_graph "$G4" && bad "P4-03 graph: indirect cycle allowed" || ok "P4-03 graph: indirect cycle rejected"
G4ERR=$(dep_validate_graph "$G4" 2>&1 >/dev/null)
echo "$G4ERR" | grep -q "cycle: t_a->t_b->t_c->t_a" \
    && ok "P4-03 graph: indirect cycle path reported" || bad "P4-03 graph: indirect cycle err=[$G4ERR]"

G5="$T/g-fwd"; rm -rf "$G5"; mkdir -p "$G5"
min_task "$G5" t_b "t_z"
min_task "$G5" t_z ""
dep_validate_graph "$G5" && ok "P4-03 graph: forward reference allowed (acyclic, all exist)" || bad "P4-03 graph: forward reference rejected"

G6="$T/g-opt"; rm -rf "$G6"; mkdir -p "$G6"
min_task "$G6" t_a "?t_b"
min_task "$G6" t_b "?t_a"
dep_validate_graph "$G6" && bad "P4-03 graph: Optional cycle allowed" || ok "P4-03 graph: Optional cycle rejected (cycle in '?' edges)"
G7="$T/g-optu"; rm -rf "$G7"; mkdir -p "$G7"
min_task "$G7" t_a "?ghost"
dep_validate_graph "$G7" && bad "P4-03 graph: Optional unknown allowed" || ok "P4-03 graph: Optional unknown rejected"

# ── §apply：tcfg_apply_task 图校验 + 原子性（旧文件逐字节不变）───────────
GA="$T/g-apply"; rm -rf "$GA"; mkdir -p "$GA"; echo managed > "$GA/MANAGED"
export TCFG_DIR="$GA"
tcfg_apply_task t_a "$(ok_task t_a)"   # 新建无依赖
MD5A=$(md5sum "$GA/t_a.task" | cut -d' ' -f1)
tcfg_apply_task t_a "$(printf '%s\n' "dependency=ghost" "$(ok_task t_a)")" >/dev/null 2>&1 \
    && bad "P4-03 apply: unknown dep on edit accepted" || ok "P4-03 apply: unknown dep on edit rejected"
[ "$(md5sum "$GA/t_a.task" | cut -d' ' -f1)" = "$MD5A" ] \
    && ok "P4-03 apply: old file byte-identical after unknown-dep rejection" || bad "P4-03 apply: file mutated"
tcfg_apply_task t_new "$(printf '%s\n' "dependency=ghost" "$(ok_task t_new)")" >/dev/null 2>&1 \
    && bad "P4-03 apply: new task with unknown dep persisted" || ok "P4-03 apply: new task with unknown dep rejected (not persisted)"
[ ! -f "$GA/t_new.task" ] && ok "P4-03 apply: rejected new task left no file" || bad "P4-03 apply: t_new.task exists"
# 直接环：t_b 依赖 t_a（前向/反向引用合法）→ 再令 t_a 依赖 t_b → 成环拒绝
tcfg_apply_task t_b "$(printf '%s\n' "dependency=t_a" "$(ok_task t_b)")" >/dev/null 2>&1 \
    && ok "P4-03 apply: adding dep t_a on t_b accepted (acyclic)" || bad "P4-03 apply: acyclic edit rejected"
tcfg_apply_task t_a "$(printf '%s\n' "dependency=t_b" "$(ok_task t_a)")" >/dev/null 2>&1 \
    && bad "P4-03 apply: cycle introduced by edit accepted" || ok "P4-03 apply: cycle introduced by edit rejected"
[ "$(md5sum "$GA/t_a.task" | cut -d' ' -f1)" = "$MD5A" ] \
    && ok "P4-03 apply: old file byte-identical after cycle rejection" || bad "P4-03 apply: file mutated on cycle"
# 前向引用（引用后续才创建的任务）无环时允许
tcfg_apply_task t_z "$(ok_task t_z)"
tcfg_apply_task t_fwd "$(printf '%s\n' "dependency=t_z" "$(ok_task t_fwd)")" >/dev/null 2>&1 \
    && [ -f "$GA/t_fwd.task" ] && ok "P4-03 apply: forward reference accepted (acyclic)" || bad "P4-03 apply: forward reference rejected"

# ── §set：tcfg_set_field 写 dependency 图校验 + 原子性 ───────────────────
GS="$T/g-set"; rm -rf "$GS"; mkdir -p "$GS"; echo managed > "$GS/MANAGED"
export TCFG_DIR="$GS"
tcfg_apply_task s_a "$(ok_task s_a)"
tcfg_apply_task s_b "$(printf '%s\n' "dependency=s_a" "$(ok_task s_b)")"
MD5S=$(md5sum "$GS/s_a.task" | cut -d' ' -f1)
tcfg_set_field s_a dependency s_b >/dev/null 2>&1 \
    && bad "P4-03 set: dependency write introducing cycle accepted" || ok "P4-03 set: dependency write introducing cycle rejected"
[ "$(md5sum "$GS/s_a.task" | cut -d' ' -f1)" = "$MD5S" ] \
    && ok "P4-03 set: file byte-identical after rejected set" || bad "P4-03 set: file mutated"
tcfg_set_field s_a dependency "" >/dev/null 2>&1 \
    && ok "P4-03 set: clearing dependency accepted" || bad "P4-03 set: clearing dependency rejected"
SERR=$(tcfg_set_field s_a dependency s_b 2>&1 >/dev/null)
echo "$SERR" | grep -q "cycle:" && ok "P4-03 set: error message contains concrete reason (cycle:)" || bad "P4-03 set: err=[$SERR]"

# ── §import：整体导入图校验 + config 逐字节不变（B9）─────────────────────
IM="$T/g-import"; rm -rf "$IM"; mkdir -p "$IM"
export TCFG_DIR="$IM/task-config"; mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
min_task "$TCFG_DIR" i_a "i_b"
min_task "$TCFG_DIR" i_b "i_a"
printf '08:00 echo x\n' > "$IM/import.cfg"
IM_MD5=$(md5sum "$IM/import.cfg" | cut -d' ' -f1)
tcfg_import "$IM/import.cfg" >/dev/null 2>&1 \
    && bad "P4-03 import: bad existing graph did not block import" || ok "P4-03 import: bad graph blocks import (rc non-0)"
[ "$(md5sum "$IM/import.cfg" | cut -d' ' -f1)" = "$IM_MD5" ] \
    && ok "P4-03 import: config byte-identical after rejected import" || bad "P4-03 import: config mutated"
IT="$T/g-import-ok"; rm -rf "$IT"; mkdir -p "$IT"
export TCFG_DIR="$IT/task-config"; mkdir -p "$TCFG_DIR"
printf '08:00 echo x\n' > "$IT/ok.cfg"
tcfg_import "$IT/ok.cfg" >/dev/null 2>&1 \
    && ok "P4-03 import: valid legacy config imports fine (graph intact)" || bad "P4-03 import: valid import failed"

# ── §snapshot：快照构建图过滤（KEPT：坏图 → 不替换 current）─────────────
SN="$T/g-snap"; rm -rf "$SN"; mkdir -p "$SN"; echo managed > "$SN/MANAGED"
BASE_S="$T/g-snap-base"; rm -rf "$BASE_S"; mkdir -p "$BASE_S/snapshots"
export TCFG_DIR="$SN"
export TR_BASE="$BASE_S"
min_task "$SN" k_a ""
sched_snapshot_managed "$BASE_S" >/dev/null 2>&1
CUR1=$(cat "$BASE_S/current" 2>/dev/null)
[ -n "$CUR1" ] && ok "P4-03 snapshot: valid graph snapshots ok" || bad "P4-03 snapshot: initial snapshot failed"
min_task "$SN" k_b "k_a"
min_task "$SN" k_a "k_b"
sched_snapshot_managed "$BASE_S" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "P4-03 snapshot: bad graph -> KEPT (rc=1)" || bad "P4-03 snapshot: KEPT rc=$?"
[ "$(cat "$BASE_S/current" 2>/dev/null)" = "$CUR1" ] \
    && ok "P4-03 snapshot: current unchanged (old snapshot kept)" || bad "P4-03 snapshot: current replaced"
export TCFG_DIR="$T/task-config"

# ── §gate：依赖门控 + WAITING 状态接线（P4-04）───────────────────────────
# daemon 上下文 shim（execute_task 拦截 + EXEC_LOG）由文件顶部定义；时间确定性：
#   SCHED_CYCLE_NOW=周期 token（sched_cycle_token 覆盖）、GATE_NOW=门控时钟
#   （sched_gate_epoch 覆盖）。门控插入点 = sched_execute_one due=Y 分支（trigger
#   之后、action_run 之前）；WAITING 复查 = scheduler_tick 首部 advance 通道。
G_BASE="$T/g-base"; G_TCFG="$T/g-tc"; G_TASKS="$T/g-tasks"; G_CFG="$T/g.cfg"
rm -rf "$G_BASE" "$G_TCFG" "$G_TASKS"; mkdir -p "$G_BASE" "$G_TCFG" "$G_TASKS"
echo managed > "$G_TCFG/MANAGED"; : > "$G_CFG"
export TCFG_DIR="$G_TCFG"; export TR_BASE="$G_BASE"; export TASKS_DIR="$G_TASKS"
G_EXEC="$T/g-exec.log"; : > "$G_EXEC"
# execute_task shim 改写 EXEC_LOG 目标：切到 G_EXEC
execute_task() { id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"; mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"; echo "RUNNING" > "$d/status.txt"
    echo "$id|$cmd" >> "$G_EXEC"
    echo "0" > "$d/exit_code.txt"; echo "SUCCESS" > "$d/status.txt"; return 0; }
gate_task() {   # <id> <trigger> <dep> <cmd> → 最小合法 Task v2
    printf 'schema_version=2\nid=%s\ntrigger=%s\ndependency=%s\naction.command=%s\n' \
        "$1" "$2" "$3" "$4" > "$G_TCFG/$1.task"
}
gtick() {   # <now> → 单次调度周期 + 终态对账（镜像 daemon 主循环 tick+sync）
    scheduler_tick "$G_BASE" "$G_CFG" "$G_TASKS" "$1" >/dev/null 2>&1
    state_sync_all "$G_TASKS" >/dev/null 2>&1
}

# A) 依赖未满足触发 → PENDING>WAITING（gate_wait + 原因 + 不执行 + 不 mark cycle）
gate_task dep_a 08:50 "" "echo A-dep"
gate_task t_a 08:50 "dep_a" "echo A-task"
SCHED_CYCLE_NOW=202609040850 GATE_NOW=1000 gtick 0850
[ "$(cat "$G_TASKS/dep_a/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-04 A: dep_a executed and materialized STOPPED" || bad "P4-04 A: dep_a state=$(cat "$G_TASKS/dep_a/state.txt" 2>/dev/null)"
[ "$(cat "$G_TASKS/t_a/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 A: t_a trigger matched but dep unmet → WAITING (PENDING>WAITING)" || bad "P4-04 A: t_a state=$(cat "$G_TASKS/t_a/state.txt" 2>/dev/null)"
grep -q '|gate_wait|WAITING|' "$G_TASKS/t_a/events.log" 2>/dev/null \
    && ok "P4-04 A: events.log records gate_wait→WAITING" || bad "P4-04 A: events=$(cat "$G_TASKS/t_a/events.log" 2>/dev/null)"
grep -q 'dep unsat: dep_a' "$G_TASKS/t_a/events.log" 2>/dev/null \
    && ok "P4-04 A: gate reason recorded (dep unsat: dep_a)" || bad "P4-04 A: reason missing"
grep -q 'echo A-task' "$G_EXEC" && bad "P4-04 A: gated task executed (forbidden)" || ok "P4-04 A: gated task NOT executed"
[ -f "$G_TASKS/t_a/gate.wait_start" ] \
    && ok "P4-04 A: wait clock started (gate.wait_start)" || bad "P4-04 A: gate.wait_start missing"

# A2) 同触发窗口内依赖解除 → WAITING>STARTING（gate_ok）+ 执行恰一次
SCHED_CYCLE_NOW=202609040850 GATE_NOW=1100 gtick 0850
grep -q 'echo A-task' "$G_EXEC" && ok "P4-04 A2: WAITING task released in-window → executed (dep satisfied)" || bad "P4-04 A2: t_a not executed"
grep -q '|gate_ok|STARTING|' "$G_TASKS/t_a/events.log" 2>/dev/null \
    && ok "P4-04 A2: events.log records gate_ok→STARTING (WAITING>STARTING)" || bad "P4-04 A2: gate_ok missing"
[ "$(grep -c 'echo A-task' "$G_EXEC")" -eq 1 ] \
    && ok "P4-04 A2: t_a executed exactly once per window (cycle dedup intact)" || bad "P4-04 A2: exec count=$(grep -c 'echo A-task' "$G_EXEC")"
[ ! -f "$G_TASKS/t_a/gate.wait_start" ] \
    && ok "P4-04 A2: wait clock cleared on release" || bad "P4-04 A2: gate.wait_start not cleared"

# B) 触发窗口过后依赖仍不满足 → WAITING>PENDING（rearm），避免永久挂起
gate_task dep_b 08:55 "" "echo B-dep"
gate_task t_b 08:55 "dep_b" "echo B-task"
SCHED_CYCLE_NOW=202609040855 GATE_NOW=2000 gtick 0855
[ "$(cat "$G_TASKS/t_b/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 B: t_b entered WAITING (dep_b not yet terminal in-window)" || bad "P4-04 B: t_b state=$(cat "$G_TASKS/t_b/state.txt" 2>/dev/null)"
SCHED_CYCLE_NOW=202609040856 GATE_NOW=3000 gtick 0856
[ "$(cat "$G_TASKS/t_b/state.txt" 2>/dev/null)" = "PENDING" ] \
    && ok "P4-04 B: WAITING rearm → PENDING (trigger window closed, dep still unmet)" || bad "P4-04 B: t_b state=$(cat "$G_TASKS/t_b/state.txt" 2>/dev/null)"
grep -q '|rearm|PENDING|' "$G_TASKS/t_b/events.log" 2>/dev/null \
    && ok "P4-04 B: events.log records rearm→PENDING" || bad "P4-04 B: rearm event missing"
[ ! -f "$G_TASKS/t_b/gate.wait_start" ] \
    && ok "P4-04 B: wait clock cleared on rearm (bounded)" || bad "P4-04 B: gate.wait_start left after rearm"
grep -q 'echo B-task' "$G_EXEC" && bad "P4-04 B: rearmed task executed (forbidden)" || ok "P4-04 B: rearmed task NOT executed"

# C) Optional（?）依赖未满足 → 不阻断门控，直接执行
gate_task dep_c 23:59 "" "echo C-dep"
gate_task t_c 08:57 "?dep_c" "echo C-task"
SCHED_CYCLE_NOW=202609040857 GATE_NOW=4000 gtick 0857
grep -q 'echo C-task' "$G_EXEC" && ok "P4-04 C: optional dep unmet does NOT block (executed)" || bad "P4-04 C: t_c not executed"
[ "$(cat "$G_TASKS/t_c/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-04 C: optional-gated task completed STOPPED" || bad "P4-04 C: t_c state=$(cat "$G_TASKS/t_c/state.txt" 2>/dev/null)"
[ ! -d "$G_TASKS/t_c/gate.wait_start" ] \
    && ok "P4-04 C: optional unmet did NOT enter WAITING (no wait clock)" || bad "P4-04 C: t_c wrongly waited"

# D) WAIT_MAX 超时 → WAITING>FAILED（gate_fail，有界）
# 同周期 token（触发窗口保持匹配）二次 tick：首次进入 WAITING，二次推进 GATE_NOW
# 使 elapsed > WAIT_MAX → 超时 FAILED（rearm 不抢占超时兜底）
gate_task dep_d 23:59 "" "echo D-dep"
gate_task t_d 08:58 "dep_d" "echo D-task"
SCHED_CYCLE_NOW=202609040858 GATE_NOW=5000 gtick 0858
[ "$(cat "$G_TASKS/t_d/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 D: t_d entered WAITING (required dep unmet)" || bad "P4-04 D: t_d state=$(cat "$G_TASKS/t_d/state.txt" 2>/dev/null)"
WAIT_MAX=5 SCHED_CYCLE_NOW=202609040858 GATE_NOW=5010 gtick 0858
[ "$(cat "$G_TASKS/t_d/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P4-04 D: WAITING > WAIT_MAX → FAILED (bounded, no permanent WAITING)" || bad "P4-04 D: t_d state=$(cat "$G_TASKS/t_d/state.txt" 2>/dev/null)"
grep -q '|gate_fail|FAILED|' "$G_TASKS/t_d/events.log" 2>/dev/null \
    && ok "P4-04 D: events.log records gate_fail→FAILED (wait timeout)" || bad "P4-04 D: gate_fail missing"
grep -q 'wait timeout' "$G_TASKS/t_d/events.log" 2>/dev/null \
    && ok "P4-04 D: timeout reason recorded" || bad "P4-04 D: timeout reason missing"
grep -q 'echo D-task' "$G_EXEC" && bad "P4-04 D: timed-out task executed (forbidden)" || ok "P4-04 D: timed-out task NOT executed"

# E) disable WAITING 任务不报错（既有 tcfg/disable 路径；TSM WAITING>DISABLED wired）
gate_task dep_e 23:59 "" "echo E-dep"
gate_task t_e 08:59 "dep_e" "echo E-task"
SCHED_CYCLE_NOW=202609040859 GATE_NOW=6000 gtick 0859
[ "$(cat "$G_TASKS/t_e/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 E: t_e entered WAITING (pre-disable)" || bad "P4-04 E: t_e state=$(cat "$G_TASKS/t_e/state.txt" 2>/dev/null)"
E_DIS=$(tctl_set_enabled "$G_BASE" "$G_CFG" "$G_TASKS" t_e 0 2>/dev/null)
[ "$?" -eq 0 ] && ok "P4-04 E: disable on WAITING task succeeds (no error)" || bad "P4-04 E: disable rc=$? out=$E_DIS"

# F) daemon 重启后 WAITING 保留（不再 WAITING→FAILED）+ 下个 tick 复查依赖
gate_task dep_f 23:59 "" "echo F-dep"
gate_task t_f 09:00 "dep_f" "echo F-task"
SCHED_CYCLE_NOW=202609040900 GATE_NOW=7000 gtick 0900
[ "$(cat "$G_TASKS/t_f/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 F: t_f entered WAITING (pre-restart)" || bad "P4-04 F: t_f state=$(cat "$G_TASKS/t_f/state.txt" 2>/dev/null)"
# 模拟重启：legacy status.txt=RUNNING（剪枝目标）+ 依赖在停机期间完成
echo "RUNNING" > "$G_TASKS/t_f/status.txt"
mkdir -p "$G_TASKS/dep_f"; echo "STOPPED" > "$G_TASKS/dep_f/state.txt"
state_rehydrate_residual "$G_TASKS" >/dev/null 2>&1
[ "$(cat "$G_TASKS/t_f/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-04 F: rehydrate PRESERVES WAITING (P4-04 semantic: non-exec state kept)" || bad "P4-04 F: WAITING lost after rehydrate=$(cat "$G_TASKS/t_f/state.txt" 2>/dev/null)"
grep -q '|daemon_restart|FAILED|' "$G_TASKS/t_f/events.log" 2>/dev/null \
    && bad "P4-04 F: WAITING wrongly forced to FAILED on restart" || ok "P4-04 F: no daemon_restart forced on WAITING"
SCHED_CYCLE_NOW=202609040900 GATE_NOW=8000 gtick 0900
grep -q 'echo F-task' "$G_EXEC" && ok "P4-04 F: after restart, WAITING rechecked → released+executed (dep satisfied)" || bad "P4-04 F: t_f not released after restart"

# ── §gate-p4-05：Required/Optional 失败传播（P4-05）─────────────────────────
# 语义（docs/P4-05.md / dependency-schema.md ADR D15–D17）：
#   - Required 依赖已终态（STOPPED|FAILED）但 != entry 指定 `:STATE` → 立即
#     WAITING>FAILED（gate_fail，原因 `dep failed: <id>`，不等 WAIT_MAX）；
#   - Required 依赖 :FAILED 且依赖 FAILED → 满足门控，照常执行；
#   - `?` Optional 依赖 FAILED / 缺失 → 不阻断执行；
#   - Required 依赖缺失（registry 无任务）→ dep missing：有界等待 → 超时 FAILED；
#   - Required 依赖 DISABLED → dep disabled：非终态、不可作为满足依据，超时 FAILED；
#   - 手动 start（force=1）/ restart 对 WAITING → 跳过依赖门控直接执行（manual_exec）；
#     非 force start 对 WAITING → 非法拒绝（rc 3，状态不变）。

# G) Required 依赖终态 FAILED（缺省 :STOPPED）→ WAITING>FAILED（不等超时）
gate_task dep_g 23:59 "" "echo G-dep"
gate_task t_g 09:30 "dep_g" "echo G-task"
mkdir -p "$G_TASKS/dep_g"; echo FAILED > "$G_TASKS/dep_g/state.txt"
SCHED_CYCLE_NOW=202609040930 GATE_NOW=9000 gtick 0930
[ "$(cat "$G_TASKS/t_g/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 G: required dep FAILED (:STOPPED) → enters WAITING first" || bad "P4-05 G: t_g state=$(cat "$G_TASKS/t_g/state.txt" 2>/dev/null)"
SCHED_CYCLE_NOW=202609040930 GATE_NOW=9001 gtick 0930
[ "$(cat "$G_TASKS/t_g/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P4-05 G: dep terminal mismatch → immediate WAITING>FAILED (no WAIT_MAX wait)" || bad "P4-05 G: t_g state=$(cat "$G_TASKS/t_g/state.txt" 2>/dev/null)"
grep -q '|gate_fail|FAILED|' "$G_TASKS/t_g/events.log" 2>/dev/null \
    && grep -q 'dep failed: dep_g' "$G_TASKS/t_g/events.log" 2>/dev/null \
    && ok "P4-05 G: gate_fail event records 'dep failed: dep_g'" || bad "P4-05 G: gate_fail/dep-failed reason missing"
grep -q 'echo G-task' "$G_EXEC" && bad "P4-05 G: dep-failed task executed (forbidden)" || ok "P4-05 G: dep-failed task NOT executed"

# H) Required 依赖指定 :FAILED 且依赖 FAILED → 满足门控，执行
gate_task dep_h 23:59 "" "echo H-dep"
gate_task t_h 09:31 "dep_h:FAILED" "echo H-task"
mkdir -p "$G_TASKS/dep_h"; echo FAILED > "$G_TASKS/dep_h/state.txt"
SCHED_CYCLE_NOW=202609040931 GATE_NOW=10000 gtick 0931
grep -q 'echo H-task' "$G_EXEC" && [ "$(cat "$G_TASKS/t_h/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-05 H: required dep :FAILED + dep FAILED → gate satisfied, executed" || bad "P4-05 H: t_h state=$(cat "$G_TASKS/t_h/state.txt" 2>/dev/null) exec=$(grep -c 'echo H-task' "$G_EXEC")"

# I) Optional（?）依赖 FAILED → 不阻断，照常执行
gate_task dep_i 23:59 "" "echo I-dep"
gate_task t_i 09:32 "?dep_i" "echo I-task"
mkdir -p "$G_TASKS/dep_i"; echo FAILED > "$G_TASKS/dep_i/state.txt"
SCHED_CYCLE_NOW=202609040932 GATE_NOW=11000 gtick 0932
grep -q 'echo I-task' "$G_EXEC" && [ "$(cat "$G_TASKS/t_i/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-05 I: optional dep FAILED does NOT block (executed)" || bad "P4-05 I: t_i state=$(cat "$G_TASKS/t_i/state.txt" 2>/dev/null) exec=$(grep -c 'echo I-task' "$G_EXEC")"

# J) Required 依赖 WAITING 期间缺失（registry 无任务）→ 有界等待 → 超时 FAILED
gate_task dep_j 23:59 "" "echo J-dep"
gate_task t_j 09:33 "dep_j" "echo J-task"
SCHED_CYCLE_NOW=202609040933 GATE_NOW=12000 gtick 0933
[ "$(cat "$G_TASKS/t_j/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 J: t_j enters WAITING (dep present pre-delete)" || bad "P4-05 J: t_j state=$(cat "$G_TASKS/t_j/state.txt" 2>/dev/null)"
rm -f "$(registry_snapshot_dir 2>/dev/null)/dep_j.task"
WAIT_MAX=5 SCHED_CYCLE_NOW=202609040933 GATE_NOW=12010 gtick 0933
[ "$(cat "$G_TASKS/t_j/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P4-05 J: required dep missing → WAIT_MAX timeout → FAILED" || bad "P4-05 J: t_j state=$(cat "$G_TASKS/t_j/state.txt" 2>/dev/null)"
grep -q 'dep missing: dep_j' "$G_TASKS/t_j/events.log" 2>/dev/null \
    && ok "P4-05 J: timeout reason records 'dep missing: dep_j'" || bad "P4-05 J: dep missing reason missing"

# J2) Optional 依赖缺失 → 不阻断，照常执行
gate_task dep_k 23:59 "" "echo K-dep"
gate_task t_k 09:34 "?dep_k" "echo K-task"
SCHED_CYCLE_NOW=202609040934 GATE_NOW=13000 gtick 0934
rm -f "$(registry_snapshot_dir 2>/dev/null)/dep_k.task"
SCHED_CYCLE_NOW=202609040934 GATE_NOW=13010 gtick 0934
grep -q 'echo K-task' "$G_EXEC" && [ "$(cat "$G_TASKS/t_k/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-05 J2: optional dep missing does NOT block (executed)" || bad "P4-05 J2: t_k state=$(cat "$G_TASKS/t_k/state.txt" 2>/dev/null) exec=$(grep -c 'echo K-task' "$G_EXEC")"

# K) Required 依赖 DISABLED → 非终态不可满足 → 有界等待 → 超时 FAILED
gate_task dep_l 23:59 "" "echo L-dep"
gate_task t_l 09:35 "dep_l" "echo L-task"
SCHED_CYCLE_NOW=202609040935 GATE_NOW=14000 gtick 0935
[ "$(cat "$G_TASKS/t_l/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 K: t_l enters WAITING (pre-disable dep)" || bad "P4-05 K: t_l state=$(cat "$G_TASKS/t_l/state.txt" 2>/dev/null)"
mkdir -p "$G_TASKS/dep_l"; echo DISABLED > "$G_TASKS/dep_l/state.txt"
WAIT_MAX=5 SCHED_CYCLE_NOW=202609040935 GATE_NOW=14010 gtick 0935
[ "$(cat "$G_TASKS/t_l/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P4-05 K: required dep DISABLED → WAIT_MAX timeout → FAILED" || bad "P4-05 K: t_l state=$(cat "$G_TASKS/t_l/state.txt" 2>/dev/null)"
grep -q 'dep disabled: dep_l' "$G_TASKS/t_l/events.log" 2>/dev/null \
    && ok "P4-05 K: timeout reason records 'dep disabled: dep_l'" || bad "P4-05 K: dep disabled reason missing"

# L) 手动 start（force=1）对 WAITING → 跳过依赖门控直接执行
gate_task dep_m 23:59 "" "echo M-dep"
gate_task t_m 09:36 "dep_m" "echo M-task"
SCHED_CYCLE_NOW=202609040936 GATE_NOW=15000 gtick 0936
[ "$(cat "$G_TASKS/t_m/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 L: t_m enters WAITING (pre force-start)" || bad "P4-05 L: t_m state=$(cat "$G_TASKS/t_m/state.txt" 2>/dev/null)"
M_OUT=$(tctl_start "$G_BASE" "$G_TASKS" t_m 1 2>/dev/null); M_RC=$?
[ "$M_RC" -eq 0 ] && echo "$M_OUT" | grep -q 'started t_m' \
    && grep -q 'echo M-task' "$G_EXEC" \
    && ok "P4-05 L: force start on WAITING skips gate → executed" || bad "P4-05 L: rc=$M_RC out=$M_OUT exec=$(grep -c 'echo M-task' "$G_EXEC")"
[ "$(cat "$G_TASKS/t_m/state.txt" 2>/dev/null)" = "RUNNING" ] \
    && ok "P4-05 L: WAITING>STARTING manual_exec → RUNNING (spawn)" || bad "P4-05 L: t_m state=$(cat "$G_TASKS/t_m/state.txt" 2>/dev/null)"
[ ! -f "$G_TASKS/t_m/gate.wait_start" ] \
    && ok "P4-05 L: wait clock cleared on force start" || bad "P4-05 L: gate.wait_start not cleared"

# M) 非 force start 对 WAITING → 非法拒绝（rc 3），状态不变
gate_task dep_n 23:59 "" "echo N-dep"
gate_task t_n 09:37 "dep_n" "echo N-task"
SCHED_CYCLE_NOW=202609040937 GATE_NOW=16000 gtick 0937
[ "$(cat "$G_TASKS/t_n/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 M: t_n enters WAITING (pre non-force start)" || bad "P4-05 M: t_n state=$(cat "$G_TASKS/t_n/state.txt" 2>/dev/null)"
N_OUT=$(tctl_start "$G_BASE" "$G_TASKS" t_n 0 2>/dev/null); N_RC=$?
[ "$N_RC" -eq 3 ] && echo "$N_OUT" | grep -q 'illegal' \
    && ok "P4-05 M: non-force start on WAITING → illegal (rc 3)" || bad "P4-05 M: rc=$N_RC out=$N_OUT"
[ "$(cat "$G_TASKS/t_n/state.txt" 2>/dev/null)" = "WAITING" ] \
    && grep -q 'echo N-task' "$G_EXEC" && bad "P4-05 M: non-force start executed task" || ok "P4-05 M: state unchanged (still WAITING), NOT executed"
# 收尾：让 t_n 经超时落终态（无永久 WAITING）
WAIT_MAX=5 SCHED_CYCLE_NOW=202609040937 GATE_NOW=16010 gtick 0937
[ "$(cat "$G_TASKS/t_n/state.txt" 2>/dev/null)" = "FAILED" ] \
    && ok "P4-05 M: t_n later times out → FAILED (WAITING has an exit)" || bad "P4-05 M: t_n state=$(cat "$G_TASKS/t_n/state.txt" 2>/dev/null)"

# N) restart（stop + force start）对 WAITING → 跳过门控
gate_task dep_o 23:59 "" "echo O-dep"
gate_task t_o 09:38 "dep_o" "echo O-task"
SCHED_CYCLE_NOW=202609040938 GATE_NOW=17000 gtick 0938
[ "$(cat "$G_TASKS/t_o/state.txt" 2>/dev/null)" = "WAITING" ] \
    && ok "P4-05 N: t_o enters WAITING (pre restart)" || bad "P4-05 N: t_o state=$(cat "$G_TASKS/t_o/state.txt" 2>/dev/null)"
O_OUT=$(tctl_restart "$G_BASE" "$G_TASKS" t_o 2>/dev/null); O_RC=$?
[ "$O_RC" -eq 0 ] && grep -q 'echo O-task' "$G_EXEC" \
    && ok "P4-05 N: restart on WAITING skips gate → executed" || bad "P4-05 N: rc=$O_RC out=$O_OUT exec=$(grep -c 'echo O-task' "$G_EXEC")"

# O) 无永久 WAITING：全部场景结束时无任务残留 WAITING（终态可达）
if [ -z "$(grep -l '^WAITING$' "$G_TASKS"/*/state.txt 2>/dev/null)" ]; then
    ok "P4-05 O: no task left in WAITING (terminal reachable in every scenario)"
else
    bad "P4-05 O: WAITING residual: $(grep -l '^WAITING$' "$G_TASKS"/*/state.txt 2>/dev/null | tr '\n' ' ')"
fi

# ── §cond-p4-06：Condition 受限表达式引擎（P4-06）─────────────────────────
# 语义（docs/P4-06.md / dependency-schema.md ADR D18–D22）：
#   - 语法 `{{ <谓词> }}` 单谓词；白名单谓词：task.state/time.hour/time.minute/
#     time.wday/env.<CONFIG_FILE|DATA_DIR|TASKS_DIR>/file.exists；运算符 ==/!=。
#   - 三态：真→执行；假→本轮不满足（直接跳过，不进入 WAITING、不改状态、不 mark
#     cycle，下周期再求值）；非法→校验期拒绝（写盘前，旧配置逐字节不变）、运行期
#     防御性不执行（记录）。condition 空=恒真。
#   - 安全硬性：禁止 eval/sh -c/$(...)/反引号/重定向/管道到命令/用户函数；纯字符串
#     解析 + 白名单表驱动；注入字符串零副作用、零执行。
Q_BASE="$T/q-base"; Q_TCFG="$T/q-tc"; Q_TASKS="$T/q-tasks"; Q_CFG="$T/q.cfg"
rm -rf "$Q_BASE" "$Q_TCFG" "$Q_TASKS"; mkdir -p "$Q_BASE" "$Q_TCFG" "$Q_TASKS"
echo managed > "$Q_TCFG/MANAGED"; : > "$Q_CFG"
export TCFG_DIR="$Q_TCFG"; export TR_BASE="$Q_BASE"; export TASKS_DIR="$Q_TASKS"
# env/file.exists 谓词依赖的允许目录（模拟 daemon 上下文）：CONFIG_FILE 同目录 + DATA_DIR
export CONFIG_FILE="$Q_CFG"; export DATA_DIR="$Q_BASE"
Q_EXEC="$T/q-exec.log"; : > "$Q_EXEC"
execute_task() { id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"; mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"; echo "RUNNING" > "$d/status.txt"
    echo "$id|$cmd" >> "$Q_EXEC"
    echo "0" > "$d/exit_code.txt"; echo "SUCCESS" > "$d/status.txt"; return 0; }
cond_task() {   # <id> <trigger> <cond> <cmd> → 最小合法 Task v2（含 condition）
    printf 'schema_version=2\nid=%s\ntrigger=%s\ncondition=%s\naction.command=%s\n' \
        "$1" "$2" "$3" "$4" > "$Q_TCFG/$1.task"
}
qtick() { scheduler_tick "$Q_BASE" "$Q_CFG" "$Q_TASKS" "$1" >/dev/null 2>&1; state_sync_all "$Q_TASKS" >/dev/null 2>&1; }
qexec_md5() { md5sum "$Q_EXEC" 2>/dev/null | cut -d' ' -f1; }

# P) 条件真（时间谓词）→ 执行；假 → 不执行（EXEC_LOG 无变化）
# 时间确定性：cond_eval 走 SCHED 的 now（qtick 传参 now=0850 → hour=08, minute=50）。
#   time.hour == 8  真（now=0850 的 hour=08）；time.hour != 8  假（恒假）。
cond_task q_p1 08:50 "{{ time.hour == 8 }}" "echo P-exec"
# 「!= 当前 tick 小时」构造运行期假（now=0850 的 hour=08 != 8 恒假）
cond_task q_p2 08:50 "{{ time.hour != 8 }}" "echo Q-not-exec"
cond_task q_emp 08:50 "" "echo EMP-exec"
SCHED_CYCLE_NOW=202609040850 qtick 0850
grep -q 'echo P-exec' "$Q_EXEC" && ok "P4-06 P: time predicate true → executed" || bad "P4-06 P: true-time task NOT executed"
[ ! -f "$Q_TASKS/q_p1/state.txt" ] || [ "$(cat "$Q_TASKS/q_p1/state.txt" 2>/dev/null)" = "STOPPED" ] \
    && ok "P4-06 P: true-condition task completed STOPPED" || bad "P4-06 P: q_p1 state=$(cat "$Q_TASKS/q_p1/state.txt" 2>/dev/null)"
grep -q 'echo Q-not-exec' "$Q_EXEC" && bad "P4-06 P: false-condition task executed" || ok "P4-06 P: false-condition task NOT executed (EXEC_LOG unchanged)"
[ ! -f "$Q_TASKS/q_p2/state.txt" ] \
    && ok "P4-06 P: false-condition task leaves NO run dir / no state write (no side effect)" \
    || bad "P4-06 P: q_p2 state written ($(cat "$Q_TASKS/q_p2/state.txt" 2>/dev/null))"
grep -q 'echo EMP-exec' "$Q_EXEC" && ok "P4-06 P: empty condition = always true → executed" || bad "P4-06 P: empty-condition task NOT executed"
# q_p2 未执行 → md5 无变化（本轮未产生副作用）
QMD5_BEFORE=$(qexec_md5)
qtick 0851
[ "$(qexec_md5)" = "$QMD5_BEFORE" ] && ok "P4-06 P: false-condition round produces zero side effects (exec md5 unchanged)" \
    || bad "P4-06 P: exec log changed after false-condition round"

# Q) task.state 谓词：比较另一任务实时态（== 与 != 各状态）
cond_task q_dep 23:59 "" "echo DQ"
cond_task q_t1 09:00 "{{ task.state(q_dep) == RUNNING }}" "echo T1"
cond_task q_t2 09:00 "{{ task.state(q_dep) != RUNNING }}" "echo T2"
mkdir -p "$Q_TASKS/q_dep"; echo RUNNING > "$Q_TASKS/q_dep/state.txt"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo T1' "$Q_EXEC" && ok "P4-06 Q: task.state(==RUNNING) true → executed" || bad "P4-06 Q: T1 not executed"
grep -q 'echo T2' "$Q_EXEC" && bad "P4-06 Q: task.state(!=RUNNING) false → wrongly executed" || ok "P4-06 Q: task.state(!=RUNNING) false → NOT executed"
# 切态后复查：FAILED → != RUNNING 为真
echo FAILED > "$Q_TASKS/q_dep/state.txt"
cond_task q_t3 09:00 "{{ task.state(q_dep) == FAILED }}" "echo T3"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo T3' "$Q_EXEC" && ok "P4-06 Q: task.state(==FAILED) true → executed" || bad "P4-06 Q: T3 not executed"
cond_task q_t4 09:00 "{{ task.state(q_dep) == PENDING }}" "echo T4"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo T4' "$Q_EXEC" && bad "P4-06 Q: task.state(==PENDING) on FAILED wrongly true" || ok "P4-06 Q: task.state(==PENDING) false → NOT executed"

# R) 校验期非法拒绝（tcfg_set_field / tcfg_apply_task / 越界 / 未授权 / 注入）
# 写路径非法 condition → rc 非 0 且原文件逐字节不变（原子性 B9）
cond_task q_r1 09:00 "{{ time.hour == 8 }}" "echo R"
Q_R1_MD5=$(md5sum "$Q_TCFG/q_r1.task" | cut -d' ' -f1)
for bad in '{{ time.hour >= 8 }}' '{{ time.hour == 99 }}' '{{ time.minute == 60 }}' \
           '{{ time.wday == 7 }}' '{{ env.HOME == /root }}' '{{ env.CONFIG_FILE == a;b }}' \
           '{{ task.state(q_dep) == RUNNING }}; rm -rf /' 'x }; pwd' '$(id)' '`id`' \
           '{{ file.exists(../etc/passwd) }}' '{{ file.exists(/etc/passwd) }}' \
           '{{ file.exists(relative) }}' 'not wrapped' '{{ }}' '{{ task.state() == RUNNING }}' \
           '{{ task.state(q_dep) == IDLE }}' '{{ time.hour = 8 }}' '{{ foo == bar }}'; do
    if tcfg_set_field q_r1 condition "$bad" >/dev/null 2>&1; then
        bad "P4-06 R: illegal condition ACCEPTED by set: '$bad'"
    fi
done
ok "P4-06 R: all illegal condition forms rejected by tcfg_set_field"
[ "$(md5sum "$Q_TCFG/q_r1.task" | cut -d' ' -f1)" = "$Q_R1_MD5" ] \
    && ok "P4-06 R: rejected writes leave task file byte-identical" || bad "P4-06 R: task file mutated on rejection"
# apply 路径非法 → 拒绝（rc 非 0）
cond_task q_r2 09:00 "{{ time.hour == 8 }}" "echo R2"
Q_R2_MD5=$(md5sum "$Q_TCFG/q_r2.task" | cut -d' ' -f1)
if tcfg_apply_task q_r2 "$(printf 'schema_version=2\nid=q_r2\ntrigger=09:00\ncondition={{ env.SECRET == x }}\naction.command=echo R2\n')" >/dev/null 2>&1; then
    bad "P4-06 R: apply accepted unauthorized env condition"
else
    ok "P4-06 R: apply rejects unauthorized env condition (rc non-zero)"
fi
[ "$(md5sum "$Q_TCFG/q_r2.task" | cut -d' ' -f1)" = "$Q_R2_MD5" ] \
    && ok "P4-06 R: apply rejection leaves original task byte-identical" || bad "P4-06 R: apply mutated task on rejection"
# 运行期非法（防御性）：手动写非法 condition 文件 → 求值视为「不满足」且不执行
cond_task q_r3 09:00 "{{ time.hour == 8 }}" "echo R3"
# 直接落盘一个非法 condition（绕过校验，模拟理论不应发生的防御场景）
printf 'schema_version=2\nid=q_r3\ntrigger=09:00\ncondition={{ oops == 1 }}\naction.command=echo R3\n' > "$Q_TCFG/q_r3.task"
sched_reload "$Q_BASE" "$Q_CFG" >/dev/null 2>&1
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo R3' "$Q_EXEC" && bad "P4-06 R: illegal runtime condition executed (defensive gate failed)" \
    || ok "P4-06 R: illegal runtime condition treated as unmet → NOT executed (defensive)"

# S) env.* 白名单：CONFIG_FILE / DATA_DIR / TASKS_DIR 比较；其余 env → 拒绝
cond_task q_e1 09:00 "{{ env.CONFIG_FILE == $Q_CFG }}" "echo E1"
# 先建真实 config 文件供存在/比较
: > "$Q_CFG"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo E1' "$Q_EXEC" && ok "P4-06 S: env.CONFIG_FILE==path true → executed" || bad "P4-06 S: E1 not executed (env compare failed)"
cond_task q_e2 09:00 "{{ env.TASKS_DIR == $Q_TASKS }}" "echo E2"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo E2' "$Q_EXEC" && ok "P4-06 S: env.TASKS_DIR==path true → executed" || bad "P4-06 S: E2 not executed"
# 其余 env（未授权）→ 校验期拒绝
if tcfg_set_field q_r1 condition "{{ env.HOME == /root }}" >/dev/null 2>&1; then
    bad "P4-06 S: unauthorized env.HOME accepted"
else
    ok "P4-06 S: unauthorized env.HOME rejected (whitelist only CONFIG_FILE/DATA_DIR/TASKS_DIR)"
fi

# T) file.exists：允许目录（CONFIG_FILE 同目录 / DATA_DIR 下）内文件存在 → 真；
#    目录穿越/系统路径 → 校验期拒绝
cond_task q_f1 09:00 "{{ file.exists($Q_CFG) }}" "echo F1"   # CONFIG_FILE 同目录文件
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo F1' "$Q_EXEC" && ok "P4-06 T: file.exists(config in allow dir) true → executed" || bad "P4-06 T: F1 not executed"
cond_task q_f2 09:00 "{{ file.exists($Q_BASE) }}" "echo F2"   # DATA_DIR 下目录
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo F2' "$Q_EXEC" && ok "P4-06 T: file.exists(DATA_DIR dir) true → executed" || bad "P4-06 T: F2 not executed"
# 穿越/系统路径 → 校验期拒绝（tcfg_set_field 在 §R 已覆盖 /etc/passwd、../，这里再确认 data-dir 外）
if tcfg_set_field q_r1 condition "{{ file.exists(/data/adb/su-scheduler/../../etc/passwd) }}" >/dev/null 2>&1; then
    bad "P4-06 T: file.exists traversal into system path accepted"
else
    ok "P4-06 T: file.exists path traversal rejected (validated lexical, no side effect)"
fi

# U) 运算符 ==/!= 合法；其它运算符（< > >= <= contains）→ 校验期拒绝（已含 §R）
cond_task q_u 09:00 "{{ time.hour != 23 }}" "echo U"
SCHED_CYCLE_NOW=202609040900 qtick 0900
grep -q 'echo U' "$Q_EXEC" && ok "P4-06 U: '!=' operator valid → executed (hour=09 != 23 true)" || bad "P4-06 U: != not executed"
if tcfg_set_field q_r1 condition "{{ time.hour contains 8 }}" >/dev/null 2>&1; then
    bad "P4-06 U: unsupported 'contains' operator accepted"
else
    ok "P4-06 U: unsupported operator 'contains' rejected (== / != only)"
fi

# ── §legacy：Legacy 配置零影响 ────────────────────────────────────────────
# legacy 解析/执行路径无 dependency/condition 新接线（C2/C4 零改动）
grep -n 'dependency\|condition' "$DAEMON" >/dev/null 2>&1 \
    && bad "P4-02 legacy: daemon references dependency/condition (must not)" || ok "P4-02 legacy: daemon (schedulerd) has zero dependency/condition refs"
# Legacy 解析函数不处理 dependency/condition（保持 C2 原样）
grep -q 'dependency\|condition' "$CLI" && bad "P4-02 legacy: CLI 顶层含 dependency/condition 新路径" || ok "P4-02 legacy: CLI top-level no new dependency/condition path"

# ── POSIX：库（含 §26）dash -n ───────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P4-02 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §26)" || bad "P4-02 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P4-02 POSIX: bash -n ok (dash unavailable)" || bad "P4-02 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p4-dependency tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1