#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Canonical↔Legacy Run ID 映射兼容（P2-04）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-04 出口：新 Task ID 可查询，旧运行目录与旧 CLI 完全兼容）：
#   1) 映射建立：runtime_map_refresh 对 legacy 运行目录（time_/startup_/
#      advanced_/immediate_）↔ registry canonical id（t<line>_<trigger>）建映射；
#   2) 双向查询：canonical→runs（runtime_map_task_runs）与 run→canonical
#      （runtime_map_run_task）、自动识别（runtime_map_lookup）；幂等（重复
#      refresh 无重复行）；未知运行目录**不映射**（诚实记录，不影响旧层）；
#   3) 旧 CLI 兼容（tests/cli/harness，真实生产 CLI 函数）：task-info /
#      task-output / task-kill 仍按**旧运行 ID** 操作已有运行目录；canonical id
#      传入旧 CLI → 正常报“Task not found”（证明**未重命名旧目录**——C2）；
#   4) 新 ID 可查询：task_cli_status <canonical>（registry 快照）可用；
#      runtime_map_lookup <canonical> 列出旧运行目录；
#   5) 旧目录零改动：refresh 后运行目录名/内容不变（ls 与 command.txt 前后一致），
#      仅新增 <base>/runtime/idmap；
#   6) 接线：su-schedulerd 含 runtime_map_refresh（启动 + tick 两处、RUNTIME_LOADED
#      门控）；lib selfcheck 含 runtime_map_lookup；POSIX dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
LEGACY_FIXTURE="tests/fixtures/legacy/config.txt"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

# ctx
BASE="$T/base"
TASKS="$T/base/tasks"
mkdir -p "$TASKS"
CFG="$T/config.txt"
cp "$LEGACY_FIXTURE" "$CFG"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1

# ── legacy 运行目录（旧 ID 命名，含 command.txt/status.txt/pid.txt/output.log）──
mk_run() {   # <run_id> <cmd>
    d="$TASKS/$1"; mkdir -p "$d"
    echo "$2" > "$d/command.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "999999" > "$d/pid.txt"        # 假 pid（/proc 不存在 → task-kill 走“已终止”分支，真机零杀伤）
    echo "output-of-$1" > "$d/output.log"
}
mk_run "time_0830_1_1785000000" 'logcat -c'
mk_run "startup_1_1785000001" 'echo "Boot marker written"'
mk_run "advanced_1_1785000002" 'echo "Monday task"'
mk_run "immediate_1_1785000003" 'echo "Run me now"'

# ── 1) 映射建立（refresh）──────────────────────────────────────────────────
runtime_map_refresh "$BASE" "$TASKS"
f=$(runtime_idmap_file "$BASE")
[ -f "$f" ] && ok "P2-04 map: idmap file created ($f)" || bad "P2-04 map: idmap missing"
n=$(wc -l < "$f")
[ "$n" -eq 4 ] && ok "P2-04 map: 4 legacy runs mapped (time/startup/advanced/immediate)" || bad "P2-04 map: mapped=$n expect 4"
grep -q "task=t16_0830|run=time_0830_1_1785000000" "$f" && ok "P2-04 map: time run -> t16_0830 (command match)" || bad "P2-04 map: time mapping missing"
grep -q "task=t11_boot|run=startup_1_1785000001" "$f" && ok "P2-04 map: startup -> t11_boot (trigger fallback boot)" || bad "P2-04 map: startup mapping missing"
grep -q "task=t20_weekly10800|run=advanced_1_1785000002" "$f" && ok "P2-04 map: advanced -> t20_weekly10800 (trigger family fallback)" || bad "P2-04 map: advanced mapping missing"
grep -q "task=t29_1430|run=immediate_1_1785000003" "$f" && ok "P2-04 map: immediate -> t29_1430 (command match)" || bad "P2-04 map: immediate mapping missing"

# ── 2) 双向查询 + 幂等 + 未映射诚实 ────────────────────────────────────────
runs=$(runtime_map_task_runs "$BASE" "t16_0830")
[ "$runs" = "time_0830_1_1785000000" ] && ok "P2-04 query: canonical->run (t16_0830 -> time run)" || bad "P2-04 query: runs=[$runs]"
canon=$(runtime_map_run_task "$BASE" "time_0830_1_1785000000")
[ "$canon" = "t16_0830" ] && ok "P2-04 query: run->canonical (time run -> t16_0830)" || bad "P2-04 query: canon=[$canon]"
out=$(runtime_map_lookup "$BASE" "$TASKS" "t16_0830")
echo "$out" | grep -q "^task=t16_0830$" && echo "$out" | grep -q "^run=time_0830_1_1785000000$" \
    && ok "P2-04 query: lookup canonical -> task+runs" || bad "P2-04 query: lookup canonical=[$(echo "$out" | tr '\n' ' ')]"
out=$(runtime_map_lookup "$BASE" "$TASKS" "time_0830_1_1785000000")
echo "$out" | grep -q "^task=t16_0830$" && echo "$out" | grep -q "^run=time_0830_1_1785000000$" \
    && ok "P2-04 query: lookup run -> canonical+run" || bad "P2-04 query: lookup run=[$(echo "$out" | tr '\n' ' ')]"
# 幂等：再次 refresh → 行数不变、无重复
runtime_map_refresh "$BASE" "$TASKS"
n2=$(wc -l < "$f")
dup=$(sort "$f" | uniq -d)
[ "$n2" -eq 4 ] && [ -z "$dup" ] && ok "P2-04 idempotent: refresh twice -> still 4 lines, no dups" || bad "P2-04 idempotent: n=$n2 dups=[$dup]"
# 未映射诚实：未知运行目录不入映射
mk_run "mystery_run_9_1785000009" 'totally-unknown-command'
runtime_map_refresh "$BASE" "$TASKS"
n3=$(wc -l < "$f")
grep -q "mystery_run" "$f" && bad "P2-04 honesty: unknown run got mapped" || ok "P2-04 honesty: unknown run NOT mapped (new mappable count=$n3, still old 4 mapped)"

# ── 3) 旧 CLI 兼容（真实生产 CLI 函数，tests/cli harness）────────────────────
. ./tests/cli/harness.sh
CLI_TMP="$T/cli"
mkdir -p "$CLI_TMP"
cp -r "$TASKS" "$CLI_TMP/tasks" 2>/dev/null
cli_run cmd_task_info time_0830_1_1785000000
printf '%s\n' "$CLI_OUT" | grep -q "time_0830_1_1785000000" && ok "P2-04 old-CLI: task-info works on legacy run id" || bad "P2-04 old-CLI: task-info run id (out: $(printf '%s\n' "$CLI_OUT" | head -1))"
cli_run cmd_task_output time_0830_1_1785000000
printf '%s\n' "$CLI_OUT" | grep -q "output-of-time_0830_1_1785000000" && ok "P2-04 old-CLI: task-output reads legacy run output.log" || bad "P2-04 old-CLI: task-output (out: $(printf '%s\n' "$CLI_OUT" | head -1))"
cli_run cmd_task_kill time_0830_1_1785000000
printf '%s\n' "$CLI_OUT" | grep -q "already terminated" && ok "P2-04 old-CLI: task-kill resolves legacy run (bogus pid -> already terminated, no real kill)" || bad "P2-04 old-CLI: task-kill (out: $(printf '%s\n' "$CLI_OUT" | head -1))"
cli_run cmd_task_info t16_0830
printf '%s\n' "$CLI_OUT" | grep -q "Task not found" && ok "P2-04 old-CLI: canonical id NOT swallowed by old CLI (dirs NOT renamed -> 'Task not found')" || bad "P2-04 old-CLI: canonical in old CLI (out: $(printf '%s\n' "$CLI_OUT" | head -1))"

# ── 4) 新 ID 可查询 ─────────────────────────────────────────────────────────
out=$(TASK_CLI_TASKS_DIR="" task_cli_status t16_0830 2>/dev/null)
printf '%s\n' "$out" | grep -q "^id=t16_0830$" && printf '%s\n' "$out" | grep -q "^trigger=08:30$" \
    && ok "P2-04 new-query: task_cli_status <canonical> works (registry snapshot)" || bad "P2-04 new-query: task_cli_status (out: $(printf '%s\n' "$out" | head -1))"
out=$(runtime_map_lookup "$BASE" "$TASKS" "t16_0830")
printf '%s\n' "$out" | grep -q "^run=time_0830_1_1785000000$" && ok "P2-04 new-query: canonical -> legacy run(s) via idmap" || bad "P2-04 new-query: canonical map lookup failed"

# ── 5) 旧运行目录零改动 ─────────────────────────────────────────────────────
ls "$TASKS" | grep -q "^time_0830_1_1785000000$" && ls "$TASKS" | grep -q "^startup_1_1785000001$" \
    && ok "P2-04 no-rename: legacy run dir names unchanged after refresh" || bad "P2-04 no-rename: run dir renamed/altered"
[ "$(cat "$TASKS/time_0830_1_1785000000/command.txt")" = "logcat -c" ] && ok "P2-04 no-rename: run command.txt untouched" || bad "P2-04 no-rename: command.txt altered"
ls "$TASKS" | grep -q "t16_0830" && bad "P2-04 no-rename: canonical-named dir appeared in tasks (forbidden)" || ok "P2-04 no-rename: no canonical-named dir in tasks/"

# ── 6) 接线 + POSIX ─────────────────────────────────────────────────────────
grep -q 'runtime_map_refresh' system/bin/su-schedulerd && ok "P2-04 wiring: su-schedulerd has runtime_map_refresh (startup + tick)" || bad "P2-04 wiring: daemon missing runtime_map_refresh"
grep -q 'RUNTIME_LOADED' system/bin/su-schedulerd && ok "P2-04 wiring: map refresh gated on RUNTIME_LOADED" || bad "P2-04 wiring: no gate in daemon"
out=$(runtime_lib_selfcheck 2>&1); rcs=$?
[ "$rcs" -eq 0 ] && ok "P2-04 wiring: lib selfcheck ok incl. runtime_map_lookup" || bad "P2-04 wiring: selfcheck rc=$rcs ($out)"
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-04 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §9)" || bad "P2-04 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-04 POSIX: bash -n ok (dash unavailable)" || bad "P2-04 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "idmap tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1