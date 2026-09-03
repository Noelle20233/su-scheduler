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
GOOD1=$(ok_task t_dep | sed 's#^id=.*#id=t_dep#')
DEP_GOOD=$(printf '%s\n' "dependency=?t_boot:FAILED,?t_daily" "$GOOD1")
if tcfg_editor_validate_payload "$DEP_GOOD"; then ok "P4-02 editor: legal dependency payload accepted"; else bad "P4-02 editor: legal dependency rejected"; fi
COND_GOOD=$(printf '%s\n' "condition=time.hour>=8" "$GOOD1")
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
printf '%s\n' "schema_version=2" "id=valid" "trigger=08:30" "dependency=a,b" "condition=x=y" > "$VALIDF"
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
cli_run cmd_task_config set "$C_ID" condition "time.hour>=8"
[ "$CLI_RC" -eq 0 ] && grep -q '^condition=time.hour>=8$' "$TCFG_DIR/$C_ID.task" \
    && ok "P4-02 cli: set condition persisted" || bad "P4-02 cli: set condition rc=$CLI_RC"
cli_run cmd_task_config show "$C_ID"
echo "$CLI_OUT" | grep -q '^dependency=?t_boot:FAILED,?t_daily$' && echo "$CLI_OUT" | grep -q '^condition=time.hour>=8$' \
    && ok "P4-02 cli: show round-trips dependency+condition" || bad "P4-02 cli: show mismatch"
# CLI set 非法 dependency → 拒绝且原文件逐字节不变（原子性 B9）
MD5B=$(md5sum "$TCFG_DIR/$C_ID.task" | cut -d' ' -f1)
cli_run cmd_task_config set "$C_ID" dependency "t_x:IDLE"
[ "$CLI_RC" -eq 0 ] && bad "P4-02 cli: set illegal dependency accepted" || ok "P4-02 cli: set illegal dependency rejected"
[ "$(md5sum "$TCFG_DIR/$C_ID.task" | cut -d' ' -f1)" = "$MD5B" ] \
    && ok "P4-02 cli: failed set left task byte-identical" || bad "P4-02 cli: task mutated on failed set"

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