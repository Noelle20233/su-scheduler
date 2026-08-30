#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Action Runner 接线测试（P1-08）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应 P1-08 验收标准）：
#   1) 结构断言：接线层唯一的执行路径是 provider_dispatch（无 sh -c 拼接）
#      ——验收 1「Task Engine 不直接拼接执行命令」
#   2) 端到端：Canonical Task Registry 快照（P1-06）→ action_run_task
#      → 普通命令工件（output.log/status/exit_code/pid.txt）
#   3) 四模式接线：普通成功 / 普通失败(FAILED+exit_code) / Termux(mock helper
#      READY) / Interactive(FIFO + legacy 保真怪癖)
#   4) 无效任务（缺 action.command）→ 拒启、不崩
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ../../providers/lib.sh
. ../../providers/providers.sh
. ../../task-registry/lib.sh
LEGACY_ADAPTER_SOURCED=1
. ../../legacy-adapter/adapter.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

# ── 1) 结构断言：引擎/接线层不直接拼接执行命令（验收 1）────────────────────
[ "$(grep -c 'sh -c' lib.sh)" -eq 0 ] && ok "runner has NO direct 'sh -c' (engine never splices commands)" || bad "runner splices commands via sh -c"
[ "$(grep -c 'provider_dispatch action command start' lib.sh)" -eq 1 ] && \
    ok "runner's single execution path = provider_dispatch action command start" || \
    bad "runner provider_dispatch start count: $(grep -c 'provider_dispatch action command start' lib.sh)"
# 排除注释行后：代码不得直接引用解释器/二进制（唯一执行路径是 dispatch）
code=$(grep -vE '^[ \t]*#' lib.sh)
[ "$(printf '%s\n' "$code" | grep -cE '\b(sh|bash|exec|/system/bin/)\b')" -eq 0 ] && \
    ok "runner code references no interpreter/binary directly (dispatch only)" || \
    bad "runner code hard-codes interpreter"

# ── 2) 端到端：registry 快照 → runner → 普通命令工件 ───────────────────────
LEGACY="../../fixtures/legacy/config.txt"
BASE=$(mktemp -d)
ACT=$(mktemp -d)
export TPR_ACTION_DIR="$ACT"
registry_init "$BASE" "$LEGACY" >/dev/null 2>&1
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "registry snapshot built (17 tasks)" || bad "registry snapshot count=$(registry_task_ids | wc -l)"

f=$(registry_task_file t45_2200)
out=$(action_run_task "$f")
[ -n "$out" ] && ok "action_run_task(t45_2200) returned: $out" || bad "action_run_task failed"
rid=$(printf '%s\n' "$out" | sed -n 's/^id=\([^ ]*\).*/\1/p')
rpid=$(printf '%s\n' "$out" | sed -n 's/.* pid=\([^ ]*\).*/\1/p')
rdir=$(printf '%s\n' "$out" | sed -n 's/.* dir=\(.*\)/\1/p')
[ "$rid" = "t45_2200" ] && ok "runner id from registry task" || bad "runner id=$rid"
action_run_wait "$rdir" "$rid" "$rpid" && ok "runner wait: task finished" || bad "runner wait timed out"
[ -f "$rdir/status.txt" ] && [ "$(cat "$rdir/status.txt")" = "SUCCESS" ] && ok "runner -> SUCCESS" || bad "runner status=$(cat "$rdir/status.txt" 2>/dev/null)"
grep -q 'No modifiers at all' "$rdir/output.log" && ok "runner captured output.log" || bad "runner output.log content"
[ -f "$rdir/exit_code.txt" ] && [ "$(cat "$rdir/exit_code.txt")" = "0" ] && ok "runner exit_code=0" || bad "runner exit_code"
[ -f "$rdir/pid.txt" ] && ok "runner persisted pid.txt artifact (mirror daemon L486)" || bad "runner pid.txt missing"

# ── 3) 四模式接线（自定义配置快照） ────────────────────────────────────────
CFG=$(mktemp)
cat > "$CFG" <<'EOF'
11:00 echo "plain-ok"
11:01 exit 7
11:02 echo "tmx-ok"; : --termux
11:03 echo "hi-inter"; exit; : --interactive
EOF
rc=$(registry_reload "$CFG")
case "$rc" in
    snap_*) ok "custom config -> snapshot $rc (4 tasks)" ;;
    *) bad "custom config reload rc=$rc" ;;
esac
[ "$(registry_task_ids | wc -l)" -eq 4 ] && ok "4 tasks in snapshot" || bad "custom snapshot count=$(registry_task_ids | wc -l)"

# Termux mock helper（READY；exec 转发给 bash）
MOCK_TERMUX="$ACT/su-scheduler-termux"
printf '#!/usr/bin/env bash\nif [ "$1" = status ]; then echo READY; elif [ "$1" = exec ]; then shift; bash -c "$*"; fi\n' > "$MOCK_TERMUX"
chmod +x "$MOCK_TERMUX"
export TPR_TERMUX_HELPER="$MOCK_TERMUX"

# 分类运行 snapshot 中全部 4 个任务并按其动作字段断言
for tid in $(registry_task_ids); do
    tf=$(registry_task_file "$tid")
    cmd=$(grep '^action.command=' "$tf" | head -1 | cut -d= -f2-)
    tmx=$(grep '^action.termux=' "$tf" | head -1 | cut -d= -f2)
    itr=$(grep '^action.interactive=' "$tf" | head -1 | cut -d= -f2)
    out=$(action_run_task "$tf")
    [ -n "$out" ] || { bad "runner failed for $tid: [$cmd]"; continue; }
    rid=$(printf '%s\n' "$out" | sed -n 's/^id=\([^ ]*\).*/\1/p')
    rpid=$(printf '%s\n' "$out" | sed -n 's/.* pid=\([^ ]*\).*/\1/p')
    rdir=$(printf '%s\n' "$out" | sed -n 's/.* dir=\(.*\)/\1/p')
    case "$cmd|$tmx|$itr" in
        'echo "plain-ok"|0|0')
            action_run_wait "$rdir" "$rid" "$rpid"
            [ "$(cat "$rdir/status.txt")" = "SUCCESS" ] && ok "plain via runner: SUCCESS" || bad "plain status=$(cat "$rdir/status.txt" 2>/dev/null)"
            grep -q 'plain-ok' "$rdir/output.log" && ok "plain output.log" || bad "plain output.log" ;;
        'exit 7|0|0')
            action_run_wait "$rdir" "$rid" "$rpid"
            [ "$(cat "$rdir/status.txt")" = "FAILED" ] && ok "fail via runner: FAILED" || bad "fail status=$(cat "$rdir/status.txt" 2>/dev/null)"
            [ "$(cat "$rdir/exit_code.txt")" = "7" ] && ok "fail exit_code=7 (failure + exit_code returned)" || bad "fail exit_code=$(cat "$rdir/exit_code.txt" 2>/dev/null)" ;;
        'echo "tmx-ok"|1|0')
            action_run_wait "$rdir" "$rid" "$rpid"
            [ "$(cat "$rdir/status.txt")" = "SUCCESS" ] && ok "termux via runner (mock READY): SUCCESS" || bad "termux status=$(cat "$rdir/status.txt" 2>/dev/null)"
            grep -q 'tmx-ok' "$rdir/output.log" && ok "termux output.log via helper exec" || bad "termux output.log" ;;
        'echo "hi-inter"; exit|0|1')
            action_run_wait "$rdir" "$rid" "$rpid"
            [ -f "$rdir/task.out" ] && grep -q 'hi-inter' "$rdir/task.out" && ok "interactive task.out has output" || bad "interactive task.out"
            [ "$(cat "$rdir/exit_code.txt")" = "0" ] && ok "interactive exit_code=0" || bad "interactive exit_code"
            [ "$(cat "$rdir/status.txt")" = "RUNNING" ] && ok "interactive status stays RUNNING (legacy mirror)" || bad "interactive status=$(cat "$rdir/status.txt" 2>/dev/null)"
            [ -f "$rdir/end_time.txt" ] && bad "interactive end_time should NOT exist" || ok "interactive no end_time (legacy mirror)" ;;
        *) bad "runner unexpected task: [$cmd|$tmx|$itr]" ;;
    esac
done

# ── 4) 无效任务：缺 action.command → 拒启、不崩 ─────────────────────────────
BADT=$(mktemp -d)
printf 'schema_version=2\nid=tbad\nenabled=1\n' > "$BADT/tbad.task"
out=$(action_run_task "$BADT/tbad.task" 2>/dev/null)
[ -z "$out" ] && ok "runner rejects task without action.command (no crash)" || bad "runner accepted no-command task: $out"
rm -rf "$BADT"

# ── 汇总 ────────────────────────────────────────────────────────────────────
rm -rf "$BASE" "$ACT" "$CFG"
echo "──────────────────────────────────────────────────────────────────────"
echo "action-run tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1