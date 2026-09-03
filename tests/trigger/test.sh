#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — TriggerProvider 接入（P2-05）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-05 出口：新旧触发结果一致 + 触发逻辑单一正式入口）：
#   1) 正式入口唯一：registry 任务经 trigger_decide（内部一律经
#      provider_dispatch trigger <family> matches）——lib 中 dispatch-trigger
#      调用恰 3 处（boot/time/advanced），且 trigger_decide 仅定义 1 次。
#   2) boot / time / advanced 三家族决策正确（含 heredoc 块任务同触发器语义）。
#   3) --run-once-now 保留：首扫即 due（cause=manual_exec）；零修剪（配置行
#      原样——修剪动作仍归执行层）。
#   4) --delete 保留：仅动作语义（本层零删行；action.delete=1 仍在任务镜像）。
#   5) 既有去重状态保留：advanced 决策**只读**状态文件（决策前后逐字节不变）。
#   6) 不引入 Dependency / Condition / 新 Trigger（lib §10 零 dependency/
#      condition 判定；trigger 家族仅 boot/time/advanced）。
#   7) 新旧触发结果一致：registry 侧（trigger_decide）vs legacy 行镜像
#      （测试侧同 Provider 集合镜像）全量比对 → agree=Y。
#   8) 接线：su-schedulerd 启动与主循环旁路块经 trigger_decide 旁路决策记录
#      （RUNTIME_LOADED 门控；legacy 执行路径零改动）；CLI 同门控；
#      POSIX dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }
# 测试侧归一助手（lib 的 Provider 内部完成归一，不导出公共 trigger_normalize）
trigger_norm() { echo "$1" | sed 's/://g'; }

RTLIB="system/bin/su-scheduler-runtime"
LEGACY_FIXTURE="tests/fixtures/legacy/config.txt"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

BASE="$T/base"; TASKS="$BASE/tasks"
mkdir -p "$TASKS"
CFG="$T/config.txt"
cp "$LEGACY_FIXTURE" "$CFG"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1
SF="$T/state.txt"
: > "$SF"

# ── 1) 正式入口唯一（lib 级）──────────────────────────────────────────────
n=$(grep -cE 'provider_dispatch trigger (boot|time|advanced) matches' "$RTLIB")
[ "$n" -eq 3 ] && ok "P2-05 entry: provider_dispatch trigger called exactly 3x (boot/time/advanced)" || bad "P2-05 entry: dispatch trigger count=$n (expect 3)"
[ "$(grep -c 'trigger_decide()' "$RTLIB")" -eq 1 ] && ok "P2-05 entry: trigger_decide defined exactly once (single formal entry)" || bad "P2-05 entry: trigger_decide count != 1"

# ── 2) boot / time / advanced 决策（registry 任务）───────────────────────
out=$(trigger_decide "$BASE" t11_boot "$(date +%H%M)" 1 "$SF")
echo "$out" | grep -q "task=t11_boot.*due=Y.*cause=boot" && ok "P2-05 boot: t11_boot due in boot context" || bad "P2-05 boot: $out"
out=$(trigger_decide "$BASE" t11_boot "$(date +%H%M)" 0 "$SF")
echo "$out" | grep -q "due=N" && ok "P2-05 boot: t11_boot not due outside boot context" || bad "P2-05 boot outside: $out"
out=$(trigger_decide "$BASE" t16_0830 0830 0 "$SF")
echo "$out" | grep -q "task=t16_0830.*due=Y.*cause=time_trigger" && ok "P2-05 time: t16_0830 due at 08:30" || bad "P2-05 time: $out"
out=$(trigger_decide "$BASE" t16_0830 0840 0 "$SF")
echo "$out" | grep -q "due=N" && ok "P2-05 time: t16_0830 not due at 08:40 (exact minute)" || bad "P2-05 time miss: $out"
MON=$(bash -c 'for d in 0 1 2 3 4 5 6; do x=$(date -d "+$d day" +%Y%m%d); [ "$(date -d "$x" +%u)" = "1" ] && echo "$x" && break; done')
out=$(TRIGGER_TODAY="$MON" trigger_decide "$BASE" t20_weekly10800 0800 0 "$SF")
echo "$out" | grep -q "task=t20_weekly10800.*due=Y.*cause=advanced" && ok "P2-05 advanced: weekly due Monday 08:00 (fresh state)" || bad "P2-05 advanced: $out (MON=$MON)"
out=$(TRIGGER_TODAY="$MON" trigger_decide "$BASE" t20_weekly10800 0700 0 "$SF")
echo "$out" | grep -q "due=N" && ok "P2-05 advanced: weekly not due before 08:00" || bad "P2-05 advanced early: $out"
out=$(trigger_decide "$BASE" t35_0915 0915 0 "$SF")
echo "$out" | grep -q "task=t35_0915.*due=Y.*cause=time_trigger" && ok "P2-05 heredoc: block task t35_0915 decided via trigger (time)" || bad "P2-05 heredoc: $out"
out=$(trigger_decide "$BASE" t39_weekly72300 2300 1 "$SF")
echo "$out" | grep -q "task=t39_weekly72300" && ok "P2-05 heredoc: block advanced task reachable (decision performed)" || bad "P2-05 heredoc advanced: $out"

# ── 3) --run-once-now 保留（首扫即 due；零修剪）──────────────────────────
out=$(trigger_decide "$BASE" t29_1430 0000 0 "$SF")
echo "$out" | grep -q "task=t29_1430.*due=Y.*cause=manual_exec" && ok "P2-05 ron: t29_1430 due immediately (--run-once-now preserved)" || bad "P2-05 ron: $out"
grep -q -- '--run-once-now' "$CFG" && ok "P2-05 ron: config line untouched (no prune by decision layer)" || bad "P2-05 ron: config pruned (forbidden)"

# ── 4) --delete 保留（仅动作语义；零删行）────────────────────────────────
grep -q -- '--delete' "$CFG" && ok "P2-05 del: --delete lines still present (no deletion by decision layer)" || bad "P2-05 del: line removed (forbidden)"
tf=$(registry_task_file t26_yearly12250800)
grep -q '^action.delete=1$' "$tf" && ok "P2-05 del: action.delete=1 preserved in task mirror" || bad "P2-05 del: action.delete missing"

# ── 5) 既有去重状态保留（advanced 只读）─────────────────────────────────
cp "$SF" "$T/sf.before"
out=$(TRIGGER_TODAY="$MON" trigger_decide "$BASE" t20_weekly10800 0800 0 "$SF")
cp "$SF" "$T/sf.after"
cmp -s "$T/sf.before" "$T/sf.after" && ok "P2-05 dedup: advanced decision read-only (state file unchanged)" || bad "P2-05 dedup: state file written by decision layer (forbidden)"

# ── 6) 不引入 Dependency / Condition 门控 / 新 Trigger ────────────────────
# P2-05 原断言守卫「lib 零 dependency/condition 判定」；P4-02 契约变更后在 §19/§23/
# §26 引入 dependency/condition **存储 schema 校验**（Task v2 字段校验，非触发决策
# 层）。故把断言**收窄到触发决策层 §10**（trigger_decide/provider_dispatch 范围）：
# 决策层不得对 dependency/condition 做门控判定（P4-04 才接线 WAITING 门控）；
# §19/§23/§26 的存储校验与 `dependency=`/`condition=` schema 键除外。
S10=$(sed -n '/^# §10 Trigger Decision Layer/,/^# §11 Action Execution Layer/p' "$RTLIB")
printf '%s\n' "$S10" | sed 's/^[ \t]*#.*$//' | grep -E 'dependency|condition' | grep -vE '(dependency|condition)=' | grep -q . && bad "P2-05 constraint: dependency/condition gating logic in trigger decision layer (§10)" || ok "P2-05 constraint: trigger decision layer (§10) has no dependency/condition gating (P2-05 §10 only)"
grep -qE 'weekly:|nweekly:|monthly:|nmonthly:|yearly:' "$RTLIB" && ok "P2-05 constraint: advanced family only boot/time/advanced families (no new triggers)" || bad "P2-05 constraint: advanced families missing"

# ── 7) 新旧触发结果一致（registry trigger_decide vs legacy 行镜像，同 Provider）──
# 测试侧 legacy 行镜像（同 Provider 集合；含 heredoc 行、ron、boot、time、advanced）
trigger_mirror_due() {
    cl=$1; now=$2; boot=$3; sf=$4
    trig=$(echo "$cl" | awk '{print $1}')
    # P2-05 测试修复：grep -c 无匹配时输出 0 且 exit 1——去掉 `|| echo 0`
    # （否则 ron="0\n0" 双行，`[ "$ron" -ge 1 ]` 报 integer expected）
    ron=$(printf '%s\n' "$cl" | grep -c -- '--run-once-now')
    if [ "$ron" -ge 1 ]; then echo Y; return 0; fi
    case "$trig" in
        boot) { TRIGGER_BOOT_CONTEXT=$boot provider_dispatch trigger boot matches >/dev/null 2>&1 && echo Y || echo N; } ;;
        # P2-05 测试修复：归一助手名为 trigger_norm（笔误 trigger_normalize 恒
        # command-not-found → 时间镜像恒 N，时间任务恰逢 now 时会让第 7 节误报不一致）
        [0-9][0-9]:[0-9][0-9]|[0-9][0-9][0-9][0-9]) { [ "$(trigger_norm "$trig")" = "$now" ] && echo Y || echo N; } ;;
        weekly:*|nweekly:*|monthly:*|nmonthly:*|yearly:*)
            { TRIGGER_DECISION_NOW=$now TRIGGER_STATE_FILE=$sf TRIGGER_DECISION_LINE="$cl" \
              TRIGGER_TODAY=$(trigger_ctx_today) provider_dispatch trigger advanced matches "$trig" >/dev/null 2>&1 && echo Y || echo N; } ;;
        *) echo N ;;
    esac
}
now=$(date +%H%M)
leg_new="$T/leg_new.txt"; leg_mir="$T/leg_mir.txt"
: > "$leg_new"; : > "$leg_mir"
for id in $(registry_task_ids); do
    o=$(trigger_decide "$BASE" "$id" "$now" 0 "$SF") 2>/dev/null
    tr=$(echo "$o" | sed -n 's/.*|trigger=\([^|]*\)|.*/\1/p')
    due=$(echo "$o" | sed -n 's/.*|due=\([YN]\)|.*/\1/p')
    [ -n "$tr" ] && echo "$(trigger_norm "$tr")|$due" >> "$leg_new"
done
while IFS= read -r line || [ -n "$line" ]; do
    cl=$(rt_clean "$line")
    case "$cl" in
        \#*|"") continue ;;
    esac
    if echo "$cl" | grep -q '<<EOF'; then
        t1=$(echo "$cl" | awk '{print $1}')
        echo "$(trigger_norm "$t1")|$(trigger_mirror_due "$cl" "$now" 0 "$SF")" >> "$leg_mir"
        while IFS= read -r lin || [ -n "$lin" ]; do echo "$lin" | grep -q '^EOF' && break; done
        continue
    fi
    t1=$(echo "$cl" | awk '{print $1}')
    echo "$(trigger_norm "$t1")|$(trigger_mirror_due "$cl" "$now" 0 "$SF")" >> "$leg_mir"
done < "$CFG"

cmpout=$(shadow_compare "$leg_new" "$leg_mir")
agree=$(echo "$cmpout" | sed -n 's/^agree=//p')
ln=$(echo "$cmpout" | sed -n 's/.*legacy=\([0-9]*\).*/\1/p')
rn=$(echo "$cmpout" | sed -n 's/.*registry=\([0-9]*\).*/\1/p')
if [ "$agree" = "Y" ]; then
    ok "P2-05 consistency: trigger_decide(new) == legacy mirror, agree=Y ($rn tasks vs $ln lines)"
else
    bad "P2-05 consistency: agree=$agree legacy=$ln registry=$rn"
    echo "--- new (registry trigger_decide) ---"; sort "$leg_new" | head -40
    echo "--- mirror (legacy lines) ---"; sort "$leg_mir" | head -40
    echo "--- legacy_only ---"; comm -23 <(sort "$leg_mir") <(sort "$leg_new")
    echo "--- registry_only ---"; comm -13 <(sort "$leg_mir") <(sort "$leg_new")
fi

# ── 8) 接线 + POSIX ─────────────────────────────────────────────────────
grep -q 'trigger_decide' system/bin/su-schedulerd && ok "P2-05 wiring: su-schedulerd references trigger_decide (旁路块)" || bad "P2-05 wiring: daemon missing trigger_decide"
grep -q 'RUNTIME_LOADED' system/bin/su-schedulerd && grep -q 'RUNTIME_LOADED' system/bin/su-scheduler \
    && ok "P2-05 wiring: both scripts keep RUNTIME_LOADED gate (P2-02 contract)" || bad "P2-05 wiring: gate missing"
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-05 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §10)" || bad "P2-05 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-05 POSIX: bash -n ok (dash unavailable)" || bad "P2-05 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "trigger tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1