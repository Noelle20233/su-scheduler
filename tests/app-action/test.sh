#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — App Action Provider（P2-10）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-10 出口：Shizuku/GKD 类应用可经结构化 Task 启动；参数全校验，
# 不允许 Web/CLI 拼接任意 Root Shell）：
#   1) 入口：§15 tpr_action_app_{parse,validate,prepare,start,status,stop,
#      restart,exec_app} 就位；`provider_register action app` 注册；action_run
#      app 分支（mode=app）先于 execute_task；selfcheck 锚点。
#   2) 校验：四操作合法 spec → 0；恶意/非法 spec（shell 元字符、注入、错误
#      结构）→ 1（一票否决，零执行）。
#   3) 解析字段：op/target/extras 正确切分。
#   4) 安全构建：mock am 捕获 argv——package/activity/service/broadcast(+extras)
#      的 am 调用为**固定模板 + 校验片段**（逐 argv 断言；broadcast 为
#      --es k v 对）；非法 spec 经 action_run → 拒启且 mock am 零调用。
#   5) 工件：start → status RUNNING → 执行完成 → output.log/exit_code/
#      SUCCESS|FAILED/end_time；command.txt=spec。
#   6) 路由回归：action_run 普通命令仍走 command 路径（mode=system，am 零调用）；
#      结构化 app spec 走 app 路径（mode=app）。
#   7) dispatch：provider_dispatch action app validate 0/1 正确。
#   8) POSIX：lib dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

# ── mock am：捕获 argv（证明 am 调用为固定模板 + 校验片段，无注入）──────────
AMLOG="$T/am.log"
MOCKBIN="$T/bin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/am" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$AMLOG"
echo "am-ok"
exit 0
EOF
chmod +x "$MOCKBIN/am"
export PATH="$MOCKBIN:$PATH"
ACT="$T/acts"
export TPR_ACTION_DIR="$ACT"

# ── 1) 入口：§15 函数 + 注册 + action_run 分支 ─────────────────────────────
n=$(grep -cE '^tpr_action_(app_(parse|validate|prepare|start|status|stop|restart)|exec_app)\(' "$RTLIB")
[ "$n" -eq 8 ] && ok "P2-10 entry: §15 tpr_action_app_* + exec_app 8 functions defined" || bad "P2-10 entry: app funcs count=$n (expect 8)"
grep -q 'provider_register action app' "$RTLIB" && ok "P2-10 entry: action>app provider registered" || bad "P2-10 entry: registration missing"
grep -q 'mode=app' "$RTLIB" && ok "P2-10 entry: action_run has app branch (mode=app)" || bad "P2-10 entry: action_run app branch missing"
# app 分支必须先于 execute_task 委托（daemon 上下文 app 任务不得落 shell 执行）
ar=$(sed -n '/^action_run()/,/^}/p' "$RTLIB")
al=$(printf '%s\n' "$ar" | grep -n 'mode=app' | head -1 | cut -d: -f1)
et=$(printf '%s\n' "$ar" | grep -n 'type execute_task' | head -1 | cut -d: -f1)
[ -n "$al" ] && [ -n "$et" ] && [ "$al" -lt "$et" ] && ok "P2-10 entry: app branch precedes execute_task delegation (inside action_run)" || bad "P2-10 entry: app branch after execute_task (forbidden)"

# ── 2) 校验矩阵 ────────────────────────────────────────────────────────────
ok_spec() {   # <spec> → PASS if valid
    provider_dispatch action app validate "$1" >/dev/null 2>&1 && ok "P2-10 valid: $1" || bad "P2-10 valid rejected: $1"
}
bad_spec() {   # <spec> → PASS if rejected
    provider_dispatch action app validate "$1" >/dev/null 2>&1 && bad "P2-10 injected accepted: $1" || ok "P2-10 rejected: $1"
}
ok_spec "app:package:com.example.app"
ok_spec "app:activity:com.example/.Main"
ok_spec "app:activity:com.example/.a.b.MainActivity"
ok_spec "app:activity:com.example/MainActivity"
ok_spec "app:service:com.example/.MyService"
ok_spec "app:broadcast:com.example.ACTION_GO"
ok_spec "app:broadcast:android.intent.action.BOOT_COMPLETED"
ok_spec "app:broadcast:com.example.ACTION_GO:msg=hello,count=2"
bad_spec "app:package:com.x;id"
bad_spec "app:package:com.x|sh"
bad_spec "app:package:com.x&touch /tmp/pwn"
bad_spec "app:package:com.x\$(id)"
bad_spec "app:package:com.x\`id\`"
bad_spec "app:package:com.x -n"
bad_spec "app:activity:-n/system/bin/sh"
bad_spec "app:activity:com.example/.Main\$Inner"
bad_spec "app:activity:com.x/"
bad_spec "app:package:com..x"
bad_spec "app:package:1com.x"
bad_spec "app:broadcast:1BAD"
bad_spec "app:hack:com.x"
bad_spec "app:package:"
bad_spec "app:"
bad_spec "app:package:com.x:extra=1"
bad_spec "app:service:com.x/.S:extra=1"
bad_spec "app:broadcast:A:msg=a b"
bad_spec "app:broadcast:A:msg=a;id"
bad_spec "app:broadcast:A:=v"
bad_spec "app:broadcast:A:k="

# ── 3) 解析字段 ────────────────────────────────────────────────────────────
tpr_action_app_parse "app:broadcast:com.x.ACTION:msg=hello,count=2" >/dev/null 2>&1
[ "$op" = "broadcast" ] && [ "$target" = "com.x.ACTION" ] && [ "$extras" = "msg=hello,count=2" ] \
    && ok "P2-10 parse: op/target/extras split correctly" || bad "P2-10 parse: op=$op target=$target extras=$extras"

# ── 4) 安全构建：mock am 逐 argv 断言 + 注入零调用 ─────────────────────────
am_start_lines=0
run_app() {   # <id> <spec> → action_run（镜像路径）并等待完成
    am_start_lines=$(wc -l < "$AMLOG")
    out=$(action_run "$1" "$2" 2>/dev/null) || { echo "run-failed:$?"; return 1; }
    echo "$out"
}
wait_dir() {   # <dir> → 0 when exit_code.txt present
    d=$1; i=0
    while [ "$i" -lt 30 ]; do [ -f "$d/exit_code.txt" ] && return 0; sleep 0.3; i=$((i + 1)); done
    return 1
}
expect_am() {   # <expected-args...>：比较最近一次 am 调用的完整 argv（逐行合并）
    exp="$1"
    n2=$(wc -l < "$AMLOG")
    got=$(sed -n "$((am_start_lines + 1)),${n2}p" "$AMLOG" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    am_start_lines=$n2
    [ "$got" = "$exp" ] && ok "P2-10 am: $exp" || bad "P2-10 am: got=[$got] expect=[$exp]"
}

: > "$AMLOG"
out=$(run_app t1 "app:package:com.example.app")
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
[ -n "$mdir" ] || { bad "P2-10 am: no dir for package"; exit 1; }
wait_dir "$mdir"
expect_am "start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.example.app"

out=$(run_app t2 "app:activity:com.example/.Main")
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
wait_dir "$mdir"
expect_am "start -n com.example/.Main"

out=$(run_app t3 "app:service:com.example/.MyService")
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
wait_dir "$mdir"
expect_am "startservice -n com.example/.MyService"

out=$(run_app t4 "app:broadcast:com.example.ACTION_GO")
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
wait_dir "$mdir"
expect_am "broadcast -a com.example.ACTION_GO"

out=$(run_app t5 "app:broadcast:com.example.ACTION_GO:msg=hello,count=2")
mdir=$(echo "$out" | sed -n 's/.*dir=\(.*\)$/\1/p')
wait_dir "$mdir"
expect_am "broadcast -a com.example.ACTION_GO --es msg hello --es count 2"

# ── 5) 工件（旧兼容语义）───────────────────────────────────────────────────
[ "$(cat "$mdir/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "P2-10 artifacts: status.txt=SUCCESS" || bad "P2-10 artifacts: status=$(cat "$mdir/status.txt" 2>/dev/null)"
[ "$(cat "$mdir/exit_code.txt" 2>/dev/null)" = "0" ] && ok "P2-10 artifacts: exit_code.txt=0" || bad "P2-10 artifacts: exit_code=$(cat "$mdir/exit_code.txt" 2>/dev/null)"
grep -q 'am-ok' "$mdir/output.log" 2>/dev/null && ok "P2-10 artifacts: output.log captured" || bad "P2-10 artifacts: output.log"
[ -f "$mdir/end_time.txt" ] && ok "P2-10 artifacts: end_time.txt" || bad "P2-10 artifacts: end_time missing"
[ "$(cat "$mdir/command.txt" 2>/dev/null)" = "app:broadcast:com.example.ACTION_GO:msg=hello,count=2" ] && ok "P2-10 artifacts: command.txt holds structured spec" || bad "P2-10 artifacts: command.txt"

# ── 6) 路由回归：普通命令仍走 command 路径（am 零调用）─────────────────────
am_before=$(wc -l < "$AMLOG")
out=$(action_run t6 "echo plain-command" 2>/dev/null)
grep -q 'mode=system' <<< "$out" && ok "P2-10 routing: plain command → mode=system (command path preserved)" || bad "P2-10 routing: out=$out"
[ "$(wc -l < "$AMLOG")" -eq "$am_before" ] && ok "P2-10 routing: plain command did NOT invoke am (no app routing leak)" || bad "P2-10 routing: am called for plain command"
grep -q 'mode=app' <<< "$(run_app t7 'app:package:com.example.other')" && ok "P2-10 routing: app spec → mode=app (app path)" || bad "P2-10 routing: app spec not routed to app"

# ── 7) 注入经 action_run 拒启 + am 零调用 ──────────────────────────────────
am_before=$(wc -l < "$AMLOG")
for evil in "app:package:com.x;id" "app:broadcast:A:msg=x|sh" "app:package:com.x\$(id)"; do
    run_app t8 "$evil" >/dev/null 2>&1 && bad "P2-10 inject: action_run accepted: $evil" || ok "P2-10 inject: action_run rejected: $evil"
done
[ "$(wc -l < "$AMLOG")" -eq "$am_before" ] && ok "P2-10 inject: zero am invocations for malicious specs (no root shell concatenation)" || bad "P2-10 inject: am invoked for malicious spec"

# ── 8) dispatch 语义 ───────────────────────────────────────────────────────
provider_dispatch action app validate "app:package:com.ok" >/dev/null 2>&1
[ $? -eq 0 ] && ok "P2-10 dispatch: provider_dispatch action app validate (valid) → 0" || bad "P2-10 dispatch: valid rejected"
provider_dispatch action app validate "app:package:com.ok;id" >/dev/null 2>&1
[ $? -eq 1 ] && ok "P2-10 dispatch: provider_dispatch action app validate (inject) → 1" || bad "P2-10 dispatch: inject accepted"

# ── 9) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-10 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §15)" || bad "P2-10 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-10 POSIX: bash -n ok (dash unavailable)" || bad "P2-10 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "app-action tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1