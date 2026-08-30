#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Task State Machine v2 状态机测试（P1-03）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例打印 [PASS]/[FAIL]；最终 exit 0（全绿）或非 0。
# 覆盖：
#   1) 11 个状态全部合法、垃圾状态非法
#   2) 穷举 11x11 全部转换对：允许集精确对应 lib 的 TSM_ALLOWED（非法一律拒绝）
#   3) transitions.tsv 表与 lib 单一事实源一致性（FROM>TO 集合、CAUSE 令牌）
#   4) cause 令牌合法性：合法集全部承认，垃圾 cause 被拒
#   5) 允许边上传未知 cause → 拒绝（rc=2）
#   6) daemon 重启再水合：执行态 → FAILED，其余不变
#   7) legacy 映射（status.txt / P1-02 runtime.state）→ v2
#   8) 一次性任务主路径：PENDING→STARTING→RUNNING→STOPPED / →FAILED
#   9) 非法转换被拒绝且记录日志（TSM_LOG=1 捕获 WARNING；TSM_LOG=0 静音）
#   10) DISABLED 进出（enable/disable）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ./lib.sh

PASS=0
FAIL=0
TSV="../../docs/architecture/task-state-machine-transitions.tsv"

ok()   { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

# helper: run transition with logging off, return rc
try()  { TSM_LOG=0 task_state_transition "$1" "$2" "${3:-}"; }

# ── 1) 状态合法性 ───────────────────────────────────────────────────────────
for s in $TSM_STATES; do
    task_state_is_valid "$s" && ok "state '$s' is valid" || bad "state '$s' should be valid"
done
task_state_is_valid GARBAGE && bad "GARBAGE should be invalid" || ok "GARBAGE is invalid"
task_state_is_valid success && bad "legacy 'success' value invalid in v2 (mapped, not canonical)" || ok "legacy 'success' is not a v2 state"

# ── 2) 穷举 11x11：允许 ⇔ TSM_ALLOWED ───────────────────────────────────────
for from in $TSM_STATES; do
    for to in $TSM_STATES; do
        expected=1
        case " $TSM_ALLOWED " in *" $from>$to "*) expected=0 ;; esac
        try "$from" "$to"
        rc=$?
        if { [ "$expected" -eq 0 ] && [ "$rc" -eq 0 ]; } || { [ "$expected" -eq 1 ] && [ "$rc" -ne 0 ]; }; then
            ok "exhaustive: $from>$to (expect $([ "$expected" -eq 0 ] && echo allowed || echo rejected))"
        else
            bad "exhaustive: $from>$to rc=$rc expect $([ "$expected" -eq 0 ] && echo allowed || echo rejected)"
        fi
    done
done

# ── 3) 表（TSV）与函数（TSM_ALLOWED）一致 ───────────────────────────────────
if [ -f "$TSV" ]; then
    awk -F'\t' '!/^#/ && NF>=2 {print $1">"$2}' "$TSV" | sort -u > /tmp/tsm.tsv.edges.$$
    tr ' ' '\n' <<< "$TSM_ALLOWED" | sed '/^$/d' | sort -u > /tmp/tsm.lib.edges.$$
    if diff -q /tmp/tsm.tsv.edges.$$ /tmp/tsm.lib.edges.$$ >/dev/null; then
        ok "transitions.tsv edges == lib TSM_ALLOWED ($(wc -l < /tmp/tsm.lib.edges.$$) edges)"
    else
        bad "transitions.tsv vs lib mismatch:"; diff /tmp/tsm.tsv.edges.$$ /tmp/tsm.lib.edges.$$ | head -10 >&2
    fi
    # CAUSE 令牌合法性
    awk -F'\t' '!/^#/ && NF>=3 {print $3}' "$TSV" | tr '|' '\n' | sed '/^$/d' | sort -u > /tmp/tsm.tsv.causes.$$
    causes_bad=0
    while read -r c; do
        [ -n "$c" ] || continue
        task_state_cause_is_valid "$c" || { causes_bad=1; echo "  bad cause token: $c" >&2; }
    done < /tmp/tsm.tsv.causes.$$
    [ "$causes_bad" -eq 0 ] && ok "all cause tokens in transitions.tsv are canonical" || bad "unknown cause token(s) in transitions.tsv"
    rm -f /tmp/tsm.tsv.edges.$$ /tmp/tsm.lib.edges.$$ /tmp/tsm.tsv.causes.$$
else
    bad "transitions.tsv missing: $TSV"
fi

# ── 4) cause 令牌合法性 ─────────────────────────────────────────────────────
for c in $TSM_CAUSES; do
    task_state_cause_is_valid "$c" && ok "cause '$c' valid" || bad "cause '$c' should be valid"
done
task_state_cause_is_valid NOPE && bad "cause NOPE should be invalid" || ok "cause NOPE invalid"

# ── 5) 允许边 + 未知 cause → rc 2 ───────────────────────────────────────────
TSM_LOG=0 task_state_transition RUNNING STOPPED NOPE
[ $? -eq 2 ] && ok "allowed edge RUNNING>STOPPED with unknown cause rejected (rc=2)" || bad "unknown cause on allowed edge should yield rc=2"

# ── 6) daemon 重启再水合 ────────────────────────────────────────────────────
for s in STARTING RUNNING HEALTHY UNHEALTHY RECOVERING STOPPING; do
    [ "$(task_state_rehydrate "$s")" = FAILED ] && ok "rehydrate: $s -> FAILED" || bad "rehydrate: $s should become FAILED"
done
for s in DISABLED PENDING WAITING FAILED STOPPED; do
    [ "$(task_state_rehydrate "$s")" = "$s" ] && ok "rehydrate: $s unchanged" || bad "rehydrate: $s should stay $s"
done

# ── 7) legacy 映射 ──────────────────────────────────────────────────────────
check_legacy() { # $1=legacy, $2=expected v2
    got=$(task_state_from_legacy "$1")
    [ "$got" = "$2" ] && ok "legacy '$1' -> $2" || bad "legacy '$1' -> $got (expect $2)"
}
check_legacy RUNNING RUNNING
check_legacy SUCCESS STOPPED
check_legacy FAILED FAILED
check_legacy ZOMBIE_CRASHED FAILED
check_legacy idle PENDING
check_legacy running RUNNING
check_legacy success STOPPED
check_legacy failed FAILED
check_legacy zombie FAILED
check_legacy invalid DISABLED
check_legacy disabled DISABLED

# ── 8) legacy 一次性任务主路径 ──────────────────────────────────────────────
try PENDING STARTING time_trigger && try STARTING RUNNING spawn && try RUNNING STOPPED action_success \
    && ok "one-shot success path: PENDING>STARTING>RUNNING>STOPPED" \
    || bad "one-shot success path failed"
try PENDING STARTING manual_exec && try STARTING RUNNING spawn && try RUNNING FAILED action_failure \
    && ok "one-shot failure path: PENDING>STARTING>RUNNING>FAILED" \
    || bad "one-shot failure path failed"

# ── 9) 非法转换拒绝 + 日志记录 ──────────────────────────────────────────────
TSM_LOG=1 err=$(task_state_transition RUNNING PENDING 2>&1 >/dev/null)
rc=$?
[ "$rc" -ne 0 ] && ok "illegal RUNNING>PENDING rejected (rc=$rc)" || bad "illegal RUNNING>PENDING should be rejected"
case "$err" in *ILLEGAL*) ok "illegal transition logged with ILLEGAL marker" ;; *) bad "illegal transition not logged: $err" ;; esac

TSM_LOG=1 err2=$(task_state_transition STOPPED RUNNING 2>&1 >/dev/null)
[ "$rc" -ne 0 ] || true   # (rejected path already asserted above)
case "$err2" in *ILLEGAL*) ok "STOPPED>RUNNING logged as ILLEGAL (must rearm via PENDING)" ;; *) bad "STOPPED>RUNNING log missing" ;; esac

TSM_LOG=0 out=$(task_state_transition RUNNING PENDING 2>&1)
[ -z "$out" ] && ok "TSM_LOG=0 silences logging" || bad "TSM_LOG=0 should silence (got: $out)"

# ── 10) DISABLED 进出（enable/disable） ─────────────────────────────────────
try DISABLED PENDING enable && ok "DISABLED>PENDING via enable" || bad "DISABLED>PENDING failed"
try PENDING DISABLED disable && ok "PENDING>DISABLED via disable" || bad "PENDING>DISABLED failed"
[ "$(task_state_rehydrate DISABLED)" = DISABLED ] && ok "DISABLED survives restart" || bad "DISABLED rehydrate"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "state-machine tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1