#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — CommandActionProvider 接入（P2-06）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-06 出口：所有旧命令执行模式经统一 Action 入口运行）：
#   1) 正式入口唯一：lib §11 action_run 恰定义 1 次；`provider_dispatch
#      action command (start|prepare)` 恰 3 处（prepare×1 + start×2：委托/
#      镜像两分支）；action Provider 仅注册 1 个（command，P1-08 既有）。
#   2) Provider 委托既有 execute_task（daemon 上下文 shim）：7 参原样传递；
#      旧工件 status.txt / pid.txt / output.log / exit_code.txt / command.txt
#      原样产出（不建立第二套命令执行器）。
#   3) 镜像路径（非 daemon 上下文）：普通成功 / 普通失败 / Termux(mock) /
#      Interactive 四模式经 provider 分发，工件语义与 §3（P1-08）一致。
#   4) 不建立第二套执行器：command start 含委托分支（type execute_task）；
#      镜像执行助手仍为 §3 既有 4 个（finalize/smart/termux/interactive）。
#   5) 接线：su-schedulerd 4 处执行点经 action_run（RUNTIME_LOADED 门控），
#      legacy execute_task 调用原样保留（else 分支，C2）。
#   6) 工件保留一致性：委托路径与镜像路径产出同一工件集（4 类旧工件）。
#   7) POSIX：dash -n（dash 不可用则 bash -n）。
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
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── 1) 正式入口唯一（lib 级）───────────────────────────────────────────────
n=$(grep -cE '^action_run\(\)' "$RTLIB")
[ "$n" -eq 1 ] && ok "P2-06 entry: action_run defined exactly once (single formal action entry)" || bad "P2-06 entry: action_run count=$n (expect 1)"
n=$(grep -cE 'provider_dispatch action command (start|prepare)' "$RTLIB")
[ "$n" -eq 3 ] && ok "P2-06 entry: provider_dispatch action command called exactly 3x (prepare×1 + start×2)" || bad "P2-06 entry: dispatch-action count=$n (expect 3)"
n=$(grep -cE '^provider_register action ' "$RTLIB")
[ "$n" -eq 2 ] && ok "P2-06 entry: action providers = command + app (app added by P2-10)" || bad "P2-06 entry: action registrations=$n (expect 2: command + app)"

# ── 2) Provider 委托既有 execute_task（daemon 上下文：同 shell 注入）────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
. ./$RTLIB
# 模拟既有执行器（镜像 su-schedulerd execute_task 工件语义）
execute_task() {
    id=$1; cmd=$2; nstart=$3; nend=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    ( echo "$cmd" > "$d/output.log" 2>&1 ) &
    echo $! > "$d/pid.txt"
    sleep 0.2
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    echo "shim:$id:$tmx:$itr:$nstart:$nend:$msg" > "$d/shim.probe"
    return 0
}
out=$(action_run t99_0000 'echo p2-06-delegated' 1 0 1 1 'hello-msg')
grep -q 'id=t99_0000|mode=termux' <<< "$out" && ok "P2-06 delegation: action_run → provider → execute_task (mode=termux)" || bad "P2-06 delegation: out=$out"
probe="$TASKS_DIR/t99_0000/shim.probe"
[ -f "$probe" ] && grep -q '^shim:t99_0000:1:0:1:1:hello-msg$' "$probe" && ok "P2-06 delegation: 7 args forwarded to execute_task (termux=1 interactive=0 notify=1,1 msg=hello-msg)" || bad "P2-06 delegation: probe=$(cat "$probe" 2>/dev/null)"
art_miss=0
for art in status.txt pid.txt output.log exit_code.txt command.txt; do
    [ -f "$TASKS_DIR/t99_0000/$art" ] || { bad "P2-06 delegation: missing artifact $art"; art_miss=1; }
done
[ "$art_miss" -eq 0 ] && ok "P2-06 delegation: legacy artifacts preserved (status/pid/output/exit_code/command)" || true
[ "$(cat "$TASKS_DIR/t99_0000/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "P2-06 delegation: status.txt lifecycle RUNNING→SUCCESS by executor" || bad "P2-06 delegation: status=$(cat "$TASKS_DIR/t99_0000/status.txt" 2>/dev/null)"
[ "$(cat "$TASKS_DIR/t99_0000/exit_code.txt" 2>/dev/null)" = "0" ] && ok "P2-06 delegation: exit_code.txt=0" || bad "P2-06 delegation: exit_code read failed"

# ── 3) 镜像路径（非 daemon 上下文：无 execute_task 的干净子 shell）───────────
ACT="$T/acts"
mkdir -p "$ACT"
export TPR_ACTION_DIR="$ACT"
mirror_run() {   # <id> <cmd> [termux] [interactive] → echo action_run 行 + RC 行
    bash -c '
        set -u
        RTLIB="system/bin/su-scheduler-runtime"
        . ./"$RTLIB"
        export ACTION_LOG=0
        action_run "$1" "$2" "${3:-0}" "${4:-0}"
        echo "RC=$?"
    ' _ "$1" "$2" "${3:-0}" "${4:-0}"
}
mirror_wait() {   # <dir> → 0 when exit_code.txt present
    d=$1
    i=0
    while [ "$i" -lt 30 ]; do
        [ -f "$d/exit_code.txt" ] && return 0
        sleep 0.3
        i=$((i + 1))
    done
    return 1
}

out=$(mirror_run mir-ok 'echo p2-06-mirror-ok')
rc=$(echo "$out" | sed -n 's/^RC=//p')
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
[ "$rc" = "0" ] && ok "P2-06 mirror: action_run rc=0 (mirror path start ok)" || bad "P2-06 mirror: rc=$rc out=$out"
[ -n "$mdir" ] || { bad "P2-06 mirror: no dir in out"; exit 1; }
grep -q 'id=mir-ok'   <<< "$out" && ok "P2-06 mirror: id echoed"   || bad "P2-06 mirror: id missing in out"
grep -q 'mode=system' <<< "$out" && ok "P2-06 mirror: mode=system" || bad "P2-06 mirror: mode missing in out"
mirror_wait "$mdir" && ok "P2-06 mirror: plain task finished" || bad "P2-06 mirror: wait timeout"
[ "$(cat "$mdir/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "P2-06 mirror: status.txt=SUCCESS" || bad "P2-06 mirror: status=$(cat "$mdir/status.txt" 2>/dev/null)"
grep -q 'p2-06-mirror-ok' "$mdir/output.log" 2>/dev/null && ok "P2-06 mirror: output.log captured" || bad "P2-06 mirror: output.log"
[ "$(cat "$mdir/exit_code.txt" 2>/dev/null)" = "0" ] && ok "P2-06 mirror: exit_code.txt=0" || bad "P2-06 mirror: exit_code"
[ -f "$mdir/pid.txt" ] && ok "P2-06 mirror: pid.txt artifact" || bad "P2-06 mirror: pid.txt missing"

out=$(mirror_run mir-fail 'exit 7')
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
mirror_wait "$mdir"
[ "$(cat "$mdir/status.txt" 2>/dev/null)" = "FAILED" ] && ok "P2-06 mirror: failure → FAILED status" || bad "P2-06 mirror: fail status=$(cat "$mdir/status.txt" 2>/dev/null)"
[ "$(cat "$mdir/exit_code.txt" 2>/dev/null)" = "7" ] && ok "P2-06 mirror: failure → exit_code.txt=7" || bad "P2-06 mirror: fail exit_code=$(cat "$mdir/exit_code.txt" 2>/dev/null)"

MOCK="$T/su-scheduler-termux"
printf '#!/usr/bin/env bash\nif [ "$1" = "status" ]; then echo READY; elif [ "$1" = "exec" ]; then shift; bash -c "$*"; fi\n' > "$MOCK"
chmod +x "$MOCK"
export TPR_TERMUX_HELPER="$MOCK"
out=$(mirror_run mir-tmx 'echo p2-06-tmx-ok' 1 0)
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
grep -q 'mode=termux' <<< "$out" && ok "P2-06 mirror: termux mode via provider" || bad "P2-06 mirror: termux mode missing"
mirror_wait "$mdir"
[ "$(cat "$mdir/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "P2-06 mirror: termux(mock READY) → SUCCESS" || bad "P2-06 mirror: termux status=$(cat "$mdir/status.txt" 2>/dev/null)"
grep -q 'p2-06-tmx-ok' "$mdir/output.log" 2>/dev/null && ok "P2-06 mirror: termux output.log via helper exec" || bad "P2-06 mirror: termux output.log"

out=$(mirror_run mir-int 'echo p2-06-int-ok; exit' 0 1)
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
grep -q 'mode=interactive' <<< "$out" && ok "P2-06 mirror: interactive mode via provider" || bad "P2-06 mirror: interactive mode missing"
mirror_wait "$mdir"
[ -f "$mdir/task.out" ] && grep -q 'p2-06-int-ok' "$mdir/task.out" 2>/dev/null && ok "P2-06 mirror: interactive task.out has output" || bad "P2-06 mirror: interactive task.out"
[ "$(cat "$mdir/exit_code.txt" 2>/dev/null)" = "0" ] && ok "P2-06 mirror: interactive exit_code=0" || bad "P2-06 mirror: interactive exit_code=$(cat "$mdir/exit_code.txt" 2>/dev/null)"
[ "$(cat "$mdir/status.txt" 2>/dev/null)" = "RUNNING" ] && ok "P2-06 mirror: interactive status stays RUNNING (legacy quirk)" || bad "P2-06 mirror: interactive status=$(cat "$mdir/status.txt" 2>/dev/null)"
[ -f "$mdir/end_time.txt" ] && bad "P2-06 mirror: interactive end_time should NOT exist" || ok "P2-06 mirror: interactive no end_time (legacy quirk)"

# ── 4) 不建立第二套命令执行器 ───────────────────────────────────────────────
code=$(grep -vE '^[ \t]*#' "$RTLIB")
printf '%s\n' "$code" | grep -q 'type execute_task >/dev/null 2>&1' && ok "P2-06 no-second-executor: command start contains delegation branch (type execute_task)" || bad "P2-06 no-second-executor: delegation branch missing"
n=$(printf '%s\n' "$code" | grep -cE '^tpr_action_exec_(finalize|smart|termux|interactive)\(\)')
[ "$n" -eq 4 ] && ok "P2-06 no-second-executor: command mirror exec helpers = §3 existing 4 (finalize/smart/termux/interactive); app exec (P2-10) is an am-argv template, not a shell command engine" || bad "P2-06 no-second-executor: helper count=$n (expect 4)"

# ── 5) 接线：daemon 4 处执行点经 action_run（RUNTIME_LOADED 门控）──────────
n=$(grep -c 'action_run' "$DAEMON")
[ "$n" -eq 4 ] && ok "P2-06 wiring: su-schedulerd calls action_run exactly 4x (boot/run-once-now/advanced/time)" || bad "P2-06 wiring: action_run count=$n (expect 4)"
n=$(grep -cF 'execute_task "$task_id" "$cmd_to_run"' "$DAEMON")
[ "$n" -eq 4 ] && ok "P2-06 wiring: 4 legacy execute_task calls retained (else fallback, C2)" || bad "P2-06 wiring: legacy call count=$n (expect 4)"
n=$(grep -c 'RUNTIME_LOADED' "$DAEMON")
[ "$n" -ge 7 ] && ok "P2-06 wiring: RUNTIME_LOADED gate present at loader+shadow+4 action sites" || bad "P2-06 wiring: RUNTIME_LOADED count=$n"

# ── 6) 工件保留一致性：委托路径与镜像路径产出同一工件集 ─────────────────────
ok_art() {   # <dir> → 0 if status/pid/output/exit_code all present
    d=$1
    for a in status.txt pid.txt output.log exit_code.txt; do
        [ -f "$d/$a" ] || return 1
    done
    return 0
}
if ok_art "$TASKS_DIR/t99_0000" && ok_art "$ACT/mir-ok"; then
    ok "P2-06 consistency: delegation & mirror paths both produce status/pid/output/exit_code artifact set"
else
    bad "P2-06 consistency: artifact set mismatch (delegation=$(ok_art "$TASKS_DIR/t99_0000" && echo ok || echo missing) mirror=$(ok_art "$ACT/mir-ok" && echo ok || echo missing))"
fi

# ── 7) POSIX（dash -n，dash 不可用则 bash -n）───────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-06 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §11)" || bad "P2-06 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-06 POSIX: bash -n ok (dash unavailable)" || bad "P2-06 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "action tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1