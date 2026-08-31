#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P1 集成回归（P1-12）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（P1-12 必须覆盖清单，跨层端到端复用既有 P1 层）：
#   1  Legacy 配置解析        —— legacy-adapter（17 任务 + source.line）
#   2  Task ID 稳定性         —— 同一配置两次解析 → id 集一致（无时间戳）
#   3  状态合法/非法转换      —— state-machine（合法边接受 / 非法边拒绝）
#   4  无效配置回退           —— task-registry（KEPT 保留最后有效快照）
#   5  hot reload             —— task-registry（追加行 → 全量新快照，无混合）
#   6  boot 任务              —— trigger-decision（boot 上下文 → cause=boot）
#   7  时间任务               —— trigger-decision（NOW 精确分钟匹配）
#   8  heredoc                —— legacy-adapter（block 重组 + source.type=block）
#   9  Termux 模式            —— providers（missing/READY/LOCKED 三态）
#   10 command/script 执行    —— action-run（普通成功/失败/脚本）
#   11 daemon lock & stale PID—— lifecycle（单实例/stale 恢复/僵尸清理）
#   12 CLI 只读查询           —— task-cli（list 6 字段 / status / 错误三态）
# （第 13 项「安装包构建」由 tests/p1-build/build_check.sh 承担，run_p1 聚合）
# 注意：本套件不重复各套件的全量断言，而是抽**代表性集成场景**验证跨层接线。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
# ── 跨层 source（顺序 = 依赖序；providers 内部 . ./lib.sh 失败被容忍，已先 source）─
. ../providers/lib.sh
{ . ../providers/providers.sh; } 2>/dev/null   # 内部容忍的冗余 `. ./lib.sh` stderr（lib 已先 source）静音
. ../state-machine/lib.sh
. ../runtime/lib.sh
LEGACY_ADAPTER_SOURCED=1
. ../legacy-adapter/adapter.sh
. ../task-registry/lib.sh
. ../scheduling/trigger-decision/lib.sh
. ../lifecycle/lib.sh
. ../execution/action-run/lib.sh
. ../task-cli/lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

LEGACY="../fixtures/legacy/config.txt"
BASE=$(mktemp -d)
BASE2=$(mktemp -d)

# 等任务终态（镜像执行层轮询：exit_code 出现 且 status 离开 RUNNING）——
# 避免子 shell finalize 与断言的竞态。
p1r_wait() {
    d=$1; i=0
    while [ "$i" -lt 30 ] && { [ ! -f "$d/exit_code.txt" ] || \
        [ "$(cat "$d/status.txt" 2>/dev/null)" = "RUNNING" ]; }; do
        sleep 1; i=$((i + 1))
    done
}

echo "── 1) Legacy 配置解析 ───────────────────────────────────────────────"
O1="$BASE/parse1"
TR_LOGGING=0 registry_init "$BASE" "$LEGACY" >/dev/null 2>&1
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "legacy config parses to 17 tasks" || bad "legacy count=$(registry_task_ids | wc -l)"
mf=$(registry_task_file t11_boot)
grep -q '^source.line=11$' "$mf" && ok "t11_boot source.line=11 preserved" || bad "t11_boot source.line"
grep -q '^trigger=boot$' "$mf" && ok "t11_boot trigger=boot" || bad "t11_boot trigger"

echo "── 2) Task ID 稳定性 ────────────────────────────────────────────────"
legacy_adapter_parse "$LEGACY" "$BASE2/parse_a" >/dev/null 2>&1
legacy_adapter_parse "$LEGACY" "$BASE2/parse_b" >/dev/null 2>&1
ids_a=$(ls "$BASE2/parse_a" | sort | tr '\n' ' ')
ids_b=$(ls "$BASE2/parse_b" | sort | tr '\n' ' ')
[ "$ids_a" = "$ids_b" ] && ok "same config twice -> identical task id set (no timestamps)" || bad "id set drifted"
[ "$(printf '%s' "$ids_a" | grep -cE '_[0-9]{10}[ _]')" -eq 0 ] && ok "no epoch timestamp embedded in ids" || bad "epoch in ids"
[ "$(printf '%s' "$ids_a" | grep -o 't[0-9]*_[a-z0-9]*' | wc -l)" -eq 17 ] && ok "id format t<line>_<trigger> (17 ids)" || bad "id format"

echo "── 3) 状态合法/非法转换 ──────────────────────────────────────────────"
TSM_LOG=0 task_state_transition PENDING STARTING time_trigger && ok "PENDING->STARTING(time_trigger) allowed" || bad "PENDING->STARTING rejected"
TSM_LOG=0 task_state_transition RUNNING STOPPED action_success && ok "RUNNING->STOPPED(action_success) allowed" || bad "RUNNING->STOPPED rejected"
TSM_LOG=0 task_state_transition RUNNING RUNNING xx && bad "RUNNING->RUNNING should be illegal" || ok "RUNNING->RUNNING rejected (illegal)"
TSM_LOG=0 task_state_transition STOPPED STARTING xx && bad "STOPPED->STARTING should be illegal" || ok "STOPPED->STARTING rejected (illegal)"

echo "── 4) 无效配置回退 ──────────────────────────────────────────────────"
TR_LOGGING=0 registry_init "$BASE2" "$LEGACY" >/dev/null 2>&1   # 先建有效快照（KEPT 回退前提）
CFG_BAD=$(mktemp)
printf '08\x01:30 x\n23\x02:00 y\n' > "$CFG_BAD"
rc=$(TR_LOGGING=0 registry_init "$BASE2" "$CFG_BAD" >/dev/null 2>&1; registry_current_snapshot_id)
[ -n "$rc" ] && ok "broken config reload -> KEPT (snapshot $rc retained)" || bad "broken config lost snapshot"
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "17 tasks survive invalid config (fail-safe fallback)" || bad "tasks vanished on invalid config"
rm -f "$CFG_BAD"

echo "── 5) hot reload ────────────────────────────────────────────────────"
CFG_ADD=$(mktemp)
cat "$LEGACY" > "$CFG_ADD"
printf '\n23:00 echo "added-on-reload"\n' >> "$CFG_ADD"
rc=$(TR_LOGGING=0 registry_init "$BASE2" "$CFG_ADD" >/dev/null 2>&1; registry_current_snapshot_id)
[ -n "$rc" ] && ok "added line -> new snapshot $rc (hot reload)" || bad "hot reload failed"
[ "$(registry_task_ids | wc -l)" -eq 18 ] && ok "18 tasks after reload (append, no mix)" || bad "reload count=$(registry_task_ids | wc -l)"
registry_has_task t45_2200 && ok "old tasks retained in new snapshot (no partial mix)" || bad "old task lost on reload"
registry_has_task t46_2300 && ok "new task t46_2300 present (single snapshot)" || bad "t46_2300 missing"
rm -f "$CFG_ADD"

echo "── 6) boot 任务 ─────────────────────────────────────────────────────"
SF=$(mktemp)
MON=$(date -d 'monday' +%Y%m%d 2>/dev/null || date +%Y%m%d)
TR_LOGGING=0 registry_init "$BASE" "$LEGACY" >/dev/null 2>&1   # 决策层数据源（17 任务）
out=$(TRIGGER_BOOT_CONTEXT=1 TRIGGER_DECISION_NOW=0830 TRIGGER_TODAY=$MON \
    TRIGGER_STATE_FILE="$SF" trigger_decision_cycle)
case "$out" in
    *"cause=boot"*) ok "boot context -> boot tasks decided (cause=boot)" ;;
    *) bad "no boot decision: $out" ;;
esac
out2=$(TRIGGER_BOOT_CONTEXT=0 TRIGGER_DECISION_NOW=0830 TRIGGER_TODAY=$MON \
    TRIGGER_STATE_FILE="$SF" trigger_decision_cycle)
case "$out2" in
    *"cause=boot"*) bad "boot fired without boot context" ;;
    *) ok "no boot decision outside boot context" ;;
esac

echo "── 7) 时间任务 ─────────────────────────────────────────────────────"
out3=$(TRIGGER_BOOT_CONTEXT=0 TRIGGER_DECISION_NOW=0830 TRIGGER_TODAY=$MON \
    TRIGGER_STATE_FILE="$SF" trigger_decision_cycle)
case "$out3" in
    *"id=t16_0830 cause=time_trigger"*) ok "0830 task matched at NOW=0830 (minute-exact)" ;;
    *) bad "time_trigger miss: $out3" ;;
esac
out4=$(TRIGGER_BOOT_CONTEXT=0 TRIGGER_DECISION_NOW=0840 TRIGGER_TODAY=$MON \
    TRIGGER_STATE_FILE="$SF" trigger_decision_cycle)
case "$out4" in
    *"id=t16_0830 "*) bad "0830 fired at 0840 (should be exact match)" ;;
    *) ok "0830 not fired at 0840 (minute-exact preserved)" ;;
esac
rm -f "$SF"

echo "── 8) heredoc ───────────────────────────────────────────────────────"
hf=$(registry_task_file t35_0915)
grep -q '^source.type=block$' "$hf" && ok "heredoc task source.type=block" || bad "t35 source.type"
grep -q '^action.command=.*python' "$hf" && ok "heredoc action.command carries reconstruction residue (legacy mirror)" || bad "t35 action.command"
grep -q '^trigger=09:15$' "$hf" && ok "heredoc trigger preserved (09:15)" || bad "t35 trigger"

echo "── 9) Termux 模式 ───────────────────────────────────────────────────"
ACT=$(mktemp -d)
export TPR_ACTION_DIR="$ACT"
d9=$(TPR_LOG=0 provider_dispatch action command prepare tmx1 'echo t' )
TPR_TERMUX_HELPER="$ACT/nonexistent-helper" TPR_LOG=0 provider_dispatch action command start tmx1 'echo t' 1 0 > "$ACT/tmx1.pid" 2>/dev/null
p1r_wait "$d9"
[ "$(cat "$d9/status.txt" 2>/dev/null)" = "FAILED" ] && ok "termux helper missing -> FAILED (graceful)" || bad "termux missing status=$(cat "$d9/status.txt" 2>/dev/null)"
grep -q 'Termux helper missing' "$d9/output.log" 2>/dev/null && ok "termux missing error message" || bad "termux missing output"
MOCK="$ACT/su-scheduler-termux"
printf '#!/usr/bin/env bash\n[ "$1" = status ] && echo READY\n[ "$1" = exec ] && shift && bash -c "$*"\n' > "$MOCK"
chmod +x "$MOCK"
d9b=$(TPR_LOG=0 provider_dispatch action command prepare tmx2 'echo tmx-ok')
TPR_TERMUX_HELPER="$MOCK" TPR_LOG=0 provider_dispatch action command start tmx2 'echo tmx-ok' 1 0 > "$ACT/tmx2.pid" 2>/dev/null
p1r_wait "$d9b"
[ "$(cat "$d9b/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "termux READY -> exec, SUCCESS" || bad "termux READY status=$(cat "$d9b/status.txt" 2>/dev/null)"
grep -q 'tmx-ok' "$d9b/output.log" 2>/dev/null && ok "termux exec output captured" || bad "termux exec output"

echo "── 10) command/script 执行 ──────────────────────────────────────────"
RUNDIR="$BASE/run"
export TPR_ACTION_DIR="$RUNDIR"
# 普通成功
d10=$(TPR_LOG=0 provider_dispatch action command prepare c1 'echo plain-ok')
TPR_LOG=0 provider_dispatch action command start c1 'echo plain-ok' > "$RUNDIR/c1.pid" 2>/dev/null
p1r_wait "$d10"
[ "$(cat "$d10/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "plain command -> SUCCESS" || bad "plain status"
[ "$(cat "$d10/exit_code.txt" 2>/dev/null)" = "0" ] && ok "plain exit_code=0" || bad "plain exit"
# 失败
d10b=$(TPR_LOG=0 provider_dispatch action command prepare c2 'exit 7')
TPR_LOG=0 provider_dispatch action command start c2 'exit 7' > "$RUNDIR/c2.pid" 2>/dev/null
p1r_wait "$d10b"
[ "$(cat "$d10b/status.txt" 2>/dev/null)" = "FAILED" ] && ok "failing command -> FAILED" || bad "fail status"
[ "$(cat "$d10b/exit_code.txt" 2>/dev/null)" = "7" ] && ok "fail exit_code=7 returned" || bad "fail exit"
# 脚本执行
SCR="$RUNDIR/script.sh"
printf '#!/usr/bin/env bash\necho script-ran\n' > "$SCR"
d10c=$(TPR_LOG=0 provider_dispatch action command prepare c3 "$SCR")
TPR_LOG=0 provider_dispatch action command start c3 "$SCR" > "$RUNDIR/c3.pid" 2>/dev/null
p1r_wait "$d10c"
[ "$(cat "$d10c/status.txt" 2>/dev/null)" = "SUCCESS" ] && ok "script file -> SUCCESS" || bad "script status"
grep -q 'script-ran' "$d10c/output.log" 2>/dev/null && ok "script output captured" || bad "script output"

echo "── 11) daemon lock & stale PID ──────────────────────────────────────"
L11="$BASE/life.lock"
lifecycle_lock_acquire "$L11" >/dev/null 2>&1 && ok "lock acquired" || bad "lock acquire"
lifecycle_lock_acquire "$L11" >/dev/null 2>&1 && bad "second acquire should reject" || ok "single instance enforced"
printf '99999999\n' > "$L11"
lifecycle_lock_acquire "$L11" >/dev/null 2>&1 && ok "stale lock recovered" || bad "stale recover"
ZT="$BASE/ztasks"
mkdir -p "$ZT/zombie1"
printf 'RUNNING\n' > "$ZT/zombie1/status.txt"
printf '9999\n' > "$ZT/zombie1/pid.txt"
n=$(LIFECYCLE_LOG=0 lifecycle_cleanup_zombies "$ZT")
[ "$n" -eq 1 ] && ok "stale-PID cleanup recovered 1 zombie" || bad "zombie count=$n"
[ "$(cat "$ZT/zombie1/status.txt" 2>/dev/null)" = "ZOMBIE_CRASHED" ] && ok "legacy status -> ZOMBIE_CRASHED (daemon mirror)" || bad "zombie legacy status"
[ "$(cat "$ZT/zombie1/state.txt" 2>/dev/null)" = "FAILED" ] && ok "new state -> FAILED (rehydrated)" || bad "zombie new state"
lifecycle_lock_release "$L11" >/dev/null 2>&1

echo "── 12) CLI 只读查询 ────────────────────────────────────────────────"
out12=$(TASK_CLI_TASKS_DIR="" task_cli_list 2>/dev/null)
[ "$(printf '%s\n' "$out12" | wc -l)" -eq 17 ] && ok "task list: 17 rows from registry" || bad "task list rows"
row=$(printf '%s\n' "$out12" | grep '^t45_2200|')
case "$row" in
    't45_2200|echo|22:00|echo "No modifiers at all"|1|PENDING') ok "task list 6 fields (id/name/trigger/action/enabled/state)" ;;
    *) bad "task list row=[$row]" ;;
esac
sout=$(TASK_CLI_TASKS_DIR="" task_cli_status t11_boot 2>/dev/null)
grep -q '^source.line=11$' <<< "$sout" && ok "task status shows source.line=11" || bad "status source.line"
grep -q '^state=PENDING$' <<< "$sout" && ok "task status shows current state (PENDING fallback)" || bad "status state"
TASK_CLI_TASKS_DIR="" task_cli_status nosuch123 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] && ok "unknown id -> rc 1 (task not found)" || bad "unknown id rc=$rc"

# ── 汇总 ────────────────────────────────────────────────────────────────────
rm -rf "$BASE" "$BASE2" "$ACT" "$RUNDIR"
echo "──────────────────────────────────────────────────────────────────────"
echo "p1-regression tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1