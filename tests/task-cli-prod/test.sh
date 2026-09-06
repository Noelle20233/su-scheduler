#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — 生产 Task CLI 接入（P2-08）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-08 出口：新 CLI 可在真实设备上查看任务、状态和最近执行信息）：
#   1) 入口：lib §13 task_cli_attach / task_cli_resolve_id / task_cli_status_id
#      各恰 1 次定义；§5 registry_attach 恰 1 次（只读挂载）；CLI 含 task 分发、
#      cmd_task 与帮助行；cmd_task 含 RUNTIME_LOADED 门控。
#   2) 读取 Registry、不重新扫描配置：attach 只挂载快照（无 adapter/parse/
#      reload 调用）；快照建立后改写 config → attach+list 仍 17 行（不重扫）。
#   3) task list：17 任务、6 字段行（id|name|trigger|action|enabled|state）。
#   4) task status（稳定 Task ID）：task_cli_status_id … t45_2200 → rc0 +
#      id/source.line/state 字段；无 queried_id（规范 ID 直查）。
#   5) 旧运行 ID 查询：time_<HHMM>_<n>_<epoch> 运行目录 → §9 idmap 解析 →
#      queried_id + canonical_id=t45_2200 + id=t45_2200。
#   6) 三态错误明确区分：rc1 task not found / rc2 configuration invalid /
#      rc3 daemon is not running（stderr 消息各自明确）。
#   7) 旧 CLI 命令保留：dispatch 仍含 tasks/task-info/task-output/task-kill/
#      status/stop/restart；无 tasks()/list()/status() 同名函数覆盖。
#   8) 接线 + POSIX：CLI task 门控 + 帮助行；lib dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

# ── 1) 入口唯一 + 接线锚点 ─────────────────────────────────────────────────
n=$(grep -cE '^task_cli_(attach|resolve_id|status_id)' "$RTLIB")
[ "$n" -eq 3 ] && ok "P2-08 entry: §13 task_cli_attach/resolve_id/status_id defined (once each)" || bad "P2-08 entry: §13 defs count=$n (expect 3)"
n=$(grep -nE '^registry_attach' "$RTLIB" | grep -c 'registry_attach()')
[ "$n" -eq 1 ] && ok "P2-08 entry: §5 registry_attach defined once (read-only mount)" || bad "P2-08 entry: attach count=$n"
n=$(grep -c '^cmd_task()' "$CLI")
[ "$n" -eq 1 ] && ok "P2-08 entry: CLI cmd_task defined once" || bad "P2-08 entry: cmd_task count=$n"
grep -q 'task) shift; cmd_task' "$CLI" && ok "P2-08 entry: CLI dispatch has 'task' subcommand" || bad "P2-08 entry: dispatch line missing"
grep -q 'task {list | status' "$CLI" && ok "P2-08 entry: help line mentions task {list|status}" || bad "P2-08 entry: help line missing"
grep -q 'RUNTIME_LOADED' "$CLI" && ok "P2-08 entry: CLI keeps RUNTIME_LOADED gate (P2-02 contract)" || bad "P2-08 entry: RUNTIME_LOADED missing"

# ── 2) 读取 Registry、不重新扫描配置 ───────────────────────────────────────
attach_body=$(sed -n '/^registry_attach()/,/^}/p' "$RTLIB")
if printf '%s\n' "$attach_body" | grep -qE 'adapter|parse|reload|IFS= read'; then
    bad "P2-08 registry: registry_attach must NOT reparse config (no adapter/parse/reload)"
else
    ok "P2-08 registry: registry_attach is read-only mount (no adapter/parse/reload)"
fi
BASE="$T/base"
CFG="$T/config.txt"
cp tests/fixtures/legacy/config.txt "$CFG"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1
[ -n "$(registry_current_snapshot_id)" ] && ok "P2-08 registry: snapshot built (17 tasks)" || bad "P2-08 registry: init failed"
# 改写 config（模拟 daemon 已建快照后的配置漂移）→ attach 不得重扫
printf '09:00 echo drifted-config\n' > "$CFG"
task_cli_attach "$BASE" >/dev/null 2>&1
out=$(task_cli_list 2>/dev/null)
[ "$(printf '%s\n' "$out" | wc -l)" -eq 17 ] && ok "P2-08 registry: list still 17 rows after config rewrite (reads snapshot, not config)" || bad "P2-08 registry: rows=$(printf '%s\n' "$out" | wc -l) — config rescan!"

# ── 3) task list：17 任务 6 字段 ────────────────────────────────────────────
[ "$(printf '%s\n' "$out" | wc -l)" -eq 17 ] && ok "P2-08 list: 17 rows" || bad "P2-08 list: rows=$(printf '%s\n' "$out" | wc -l)"
nf=$(printf '%s\n' "$out" | head -1 | awk -F'|' '{print NF}')
[ "$nf" -eq 6 ] && ok "P2-08 list: row = 6 fields (id|name|trigger|action|enabled|state)" || bad "P2-08 list: NF=$nf"
printf '%s\n' "$out" | grep -q '^t45_2200|' && ok "P2-08 list: t45_2200 present" || bad "P2-08 list: t45_2200 missing"

# ── 4) task status（稳定 Task ID）──────────────────────────────────────────
sout=$(task_cli_status_id "$BASE" "$T/run" "" t45_2200 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "P2-08 status: canonical t45_2200 rc=0" || bad "P2-08 status: rc=$rc"
grep -q '^id=t45_2200$' <<< "$sout" && ok "P2-08 status: id=t45_2200" || bad "P2-08 status: id missing"
grep -q '^source.line=45$' <<< "$sout" && ok "P2-08 status: source.line=45" || bad "P2-08 status: source.line"
grep -q '^state=PENDING$' <<< "$sout" && ok "P2-08 status: state=PENDING (registry fallback, never ran)" || bad "P2-08 status: state=$(echo "$sout" | grep '^state=' )"
grep -q '^queried_id=' <<< "$sout" && bad "P2-08 status: canonical query must NOT emit queried_id" || ok "P2-08 status: no queried_id for canonical id"
# P4-09：legacy 快照任务新字段空值输出空（dependency= 无值、无 Gate 行）
grep -q '^dependency=$' <<< "$sout" \
    && ok "P4-09 status: legacy task dependency= empty (no value)" \
    || bad "P4-09 status: legacy dependency=[$(echo "$sout" | grep '^dependency=')]"
grep -q '^Gate:' <<< "$sout" && bad "P4-09 status: legacy task wrongly shows Gate" \
    || ok "P4-09 status: legacy task has no Gate line (not WAITING)"

# ── 5) 旧运行 ID 查询（§9 idmap 双向解析）─────────────────────────────────
RUN="$T/run"
mkdir -p "$RUN/time_2200_1_12345"
printf 'echo "No modifiers at all"\n' > "$RUN/time_2200_1_12345/command.txt"
sout=$(task_cli_status_id "$BASE" "$RUN" "" time_2200_1_12345 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "P2-08 legacy: run id time_2200_1_12345 rc=0" || bad "P2-08 legacy: rc=$rc out=$sout"
grep -q '^queried_id=time_2200_1_12345$' <<< "$sout" && ok "P2-08 legacy: queried_id echoed" || bad "P2-08 legacy: queried_id missing"
grep -q '^canonical_id=t45_2200$' <<< "$sout" && ok "P2-08 legacy: canonical_id=t45_2200 (idmap run→canonical)" || bad "P2-08 legacy: canonical_id missing"
grep -q '^id=t45_2200$' <<< "$sout" && ok "P2-08 legacy: status shows canonical id" || bad "P2-08 legacy: id missing"

# ── 5b) P4-09：managed 场景 task status 输出 dependency=/condition=/Gate ────
# 构造 managed task-config（dep_a + t_dep 带 dependency/condition），经
# sched_reload 重建快照后 task_cli_status_id 读取 task-config 字段（P4-09）。
MTC="$T/mtc"; mkdir -p "$MTC"; echo managed > "$MTC/MANAGED"
export TCFG_DIR="$MTC"
printf 'schema_version=2\nid=dep_a\ntrigger=23:59\naction.command=echo dep\n' > "$MTC/dep_a.task"
printf 'schema_version=2\nid=dep_b\ntrigger=23:58\naction.command=echo depb\n' > "$MTC/dep_b.task"
printf 'schema_version=2\nid=t_dep\ntrigger=08:30\ndependency=dep_a,?dep_b:FAILED\ncondition={{ time.hour == 8 }}\naction.command=echo hi\n' > "$MTC/t_dep.task"
printf 'schema_version=2\nid=t_empty\ntrigger=09:00\naction.command=echo x\n' > "$MTC/t_empty.task"
rm -f "$BASE/scheduler/source.md5"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_dep 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "P4-09 status: managed t_dep rc=0" || bad "P4-09 status: managed rc=$rc out=$sout"
grep -q '^dependency=dep_a,?dep_b:FAILED$' <<< "$sout" \
    && ok "P4-09 status: dependency= from task-config (optional/state kept)" \
    || bad "P4-09 status: dependency=[$(echo "$sout" | grep '^dependency=')]"
grep -q '^condition={{ time.hour == 8 }}$' <<< "$sout" \
    && ok "P4-09 status: condition= from task-config verbatim" || bad "P4-09 status: condition missing"
grep -q '^Gate:' <<< "$sout" && bad "P4-09 status: Gate leaked for non-WAITING managed task" \
    || ok "P4-09 status: no Gate line when not WAITING"
# 空值输出空：无 dependency/condition 键 → 输出空
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_empty 2>/dev/null)
grep -q '^dependency=$' <<< "$sout" && grep -q '^condition=$' <<< "$sout" \
    && ok "P4-09 status: empty dependency=/condition= for task without keys" \
    || bad "P4-09 status: t_empty dep=[$(echo "$sout" | grep '^dependency=')] cond=[$(echo "$sout" | grep '^condition=')]"
# Gate 行：WAITING 运行目录 → 门控状态行（WAITING + 原因）
mkdir -p "$RUN/t_dep"
printf 'WAITING\n' > "$RUN/t_dep/state.txt"
printf '2026-09-04 08:30:00|t_dep|gate_wait|WAITING|||dep unsat: dep_a\n' > "$RUN/t_dep/events.log"
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_dep 2>/dev/null)
grep -q '^Gate: WAITING (dep unsat: dep_a)$' <<< "$sout" \
    && ok "P4-09 status: Gate: WAITING (dep unsat: dep_a) emitted (run-dir gate event)" \
    || bad "P4-09 status: Gate=[$(echo "$sout" | grep '^Gate:')]"
grep -q '^state=WAITING$' <<< "$sout" \
    && ok "P4-09 status: state=WAITING from run-dir state.txt" || bad "P4-09 status: state"
rm -f "$RUN/t_dep/state.txt" "$RUN/t_dep/events.log"
# 还原 legacy 快照（§6 三态测试依赖 t45_2200 存在 + stale-lock rc 3 路径；
# §2 曾把 $CFG 改写为 drifted-config，需先还原配置文件再重建快照）
unset TCFG_DIR || true
cp tests/fixtures/legacy/config.txt "$CFG"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1

# ── 6) 三态错误明确区分 ────────────────────────────────────────────────────
err=$(task_cli_status_id "$BASE" "$RUN" "" no_such_task 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 1 ] && ok "P2-08 err: task not found → rc 1" || bad "P2-08 err: rc=$rc"
case "$err" in *"task not found: no_such_task"*) ok "P2-08 err: message 'task not found: no_such_task'" ;; *) bad "P2-08 err: msg=[$err]" ;; esac
BASE_BAD="$T/base_bad"
mkdir -p "$BASE_BAD"
err=$(task_cli_status_id "$BASE_BAD" "$RUN" "" t45_2200 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 2 ] && ok "P2-08 err: no snapshot → rc 2 (configuration invalid)" || bad "P2-08 err: config-invalid rc=$rc"
case "$err" in *"configuration invalid"*) ok "P2-08 err: message 'configuration invalid'" ;; *) bad "P2-08 err: msg=[$err]" ;; esac
LKF="$T/stale.lock"
printf '99999999\n' > "$LKF"
err=$(task_cli_status_id "$BASE" "$RUN" "$LKF" t45_2200 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 3 ] && ok "P2-08 err: stale daemon lock → rc 3 (daemon is not running)" || bad "P2-08 err: daemon-down rc=$rc"
case "$err" in *"daemon is not running"*) ok "P2-08 err: message 'daemon is not running'" ;; *) bad "P2-08 err: msg=[$err]" ;; esac

# ── 7) 旧 CLI 命令保留（零覆盖）────────────────────────────────────────────
for cmd in tasks 'task-info' 'task-output' 'task-kill' status stop restart; do
    grep -q "${cmd})" "$CLI" || { bad "P2-08 old-cli: dispatch lost: $cmd"; old_ok=0; }
done
[ "${old_ok:-1}" = "1" ] && ok "P2-08 old-cli: legacy dispatch entries intact (tasks/task-info/task-output/task-kill/status/stop/restart)" || true
n=0
for name in tasks list status; do
    c=$(grep -c "^${name}()" "$CLI")
    n=$((n + c))
done
[ "$n" -eq 0 ] && ok "P2-08 old-cli: no function named tasks()/list()/status() (legacy command names not overridden)" || bad "P2-08 old-cli: name-override count=$n"
grep -q 'task-info) shift; cmd_task_info' "$CLI" && ok "P2-08 old-cli: task-info command untouched" || bad "P2-08 old-cli: task-info changed"

# ── 9) P5-08：task status 新字段 + task-info managed 域新标签 ───────────────
# 复用 §5b managed 构造（TCFG_DIR=$MTC 已含 dep_a/dep_b/t_dep/t_empty）；追加
# interval 任务 t_int 与 task.state 条件任务 t_cst（确定性求值，不依赖真实时钟）
export TCFG_DIR="$MTC"
printf 'schema_version=2\nid=t_int\ntrigger=interval:15\naction.command=echo x\n' > "$MTC/t_int.task"
printf 'schema_version=2\nid=t_cst\ntrigger=09:00\ndependency=dep_a\ncondition={{ task.state(dep_a) == STOPPED }}\naction.command=echo x\n' > "$MTC/t_cst.task"
rm -f "$BASE/scheduler/source.md5"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
# trigger_kind（interval）与 next_due（time，注入 TRIGGER_DECISION_NOW）
sout=$(TRIGGER_DECISION_NOW=0855 task_cli_status_id "$BASE" "$RUN" "" t_int 2>/dev/null)
grep -q '^trigger_kind=kind=interval;minutes=15$' <<< "$sout" \
    && ok "P5-08 status: trigger_kind=kind=interval;minutes=15 (managed)" \
    || bad "P5-08 status: trigger_kind=[$(echo "$sout" | grep '^trigger_kind=')]"
sout=$(TRIGGER_DECISION_NOW=0855 task_cli_status_id "$BASE" "$RUN" "" t_empty 2>/dev/null)
grep -q '^next_due=300$' <<< "$sout" \
    && ok "P5-08 status: next_due=300 for time 09:00 at 08:55 (managed)" \
    || bad "P5-08 status: next_due=[$(echo "$sout" | grep '^next_due=')]"
# last_trigger_cause：构造 scheduler/audit.log → 反向 grep 末条 op=exec
mkdir -p "$BASE/scheduler"
printf '2026-09-06 09:00:00|op=exec|task=t_empty|trigger=09:00|mode=managed|rc=0|ron=0|del=0|cause=time_trigger\n' >> "$BASE/scheduler/audit.log"
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_empty 2>/dev/null)
grep -q '^last_trigger_cause=time_trigger$' <<< "$sout" \
    && ok "P5-08 status: last_trigger_cause=time_trigger (audit reverse grep)" \
    || bad "P5-08 status: last_trigger_cause=[$(echo "$sout" | grep '^last_trigger_cause=')]"
# condition_state / dependency_state：dep_a STOPPED → ok/satisfied；FAILED → unsat/unsat
mkdir -p "$RUN/dep_a"
printf 'STOPPED\n' > "$RUN/dep_a/state.txt"
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_cst 2>/dev/null)
grep -q '^condition_state=ok$' <<< "$sout" && grep -q '^dependency_state=satisfied$' <<< "$sout" \
    && ok "P5-08 status: condition_state=ok + dependency_state=satisfied (dep_a STOPPED)" \
    || bad "P5-08 status: STOPPED case cond=[$(echo "$sout" | grep '^condition_state=')] dep=[$(echo "$sout" | grep '^dependency_state=')]"
printf 'FAILED\n' > "$RUN/dep_a/state.txt"
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_cst 2>/dev/null)
grep -q '^condition_state=unsat$' <<< "$sout" && grep -q '^dependency_state=unsat$' <<< "$sout" \
    && ok "P5-08 status: condition_state=unsat + dependency_state=unsat (dep_a FAILED)" \
    || bad "P5-08 status: FAILED case cond=[$(echo "$sout" | grep '^condition_state=')] dep=[$(echo "$sout" | grep '^dependency_state=')]"
rm -f "$RUN/dep_a/state.txt"
# 空 condition / 空 dependency → ok
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_empty 2>/dev/null)
grep -q '^condition_state=ok$' <<< "$sout" && grep -q '^dependency_state=ok$' <<< "$sout" \
    && ok "P5-08 status: empty condition/dependency -> ok (managed)" \
    || bad "P5-08 status: empty cond/dep=[$(echo "$sout" | grep -E '^(condition_state|dependency_state)=' | tr '\n' ' ')]"
# 兼容红线：canonical 查询无 queried_id（P2-08 L81 语义保持）
sout=$(task_cli_status_id "$BASE" "$RUN" "" t_dep 2>/dev/null)
grep -q '^queried_id=' <<< "$sout" && bad "P5-08 redline: canonical query emits queried_id" \
    || ok "P5-08 redline: canonical query no queried_id (kept)"
# task-info managed 域新标签（CLI body source + 强制 RUNTIME_LOADED=1 + 覆盖路径）
CLI_BODY=$(sed '/^# 🚦 Main Dispatcher/,$d' "$CLI" | tr -d '\r' | sed '/^unset /d; /^export PATH=/d')
cli_info_managed() {   # <id> → CLI_OUT
    CLI_OUT=$( {
        set +u
        . ./$RTLIB 2>/dev/null || true
        eval "$CLI_BODY"
        RUNTIME_LOADED=1
        DATA_DIR="$BASE"
        TASKS_DIR="$RUN"
        SHELLS_DIR="$T/shells"
        TCFG_DIR="$MTC"
        cmd_task_info "$1"
    } 2>&1 )
}
mkdir -p "$RUN/t_empty"
printf 'echo x\n' > "$RUN/t_empty/command.txt"
printf 'SUCCESS\n' > "$RUN/t_empty/status.txt"
TRIGGER_DECISION_NOW=0855 cli_info_managed t_empty
printf '%s\n' "$CLI_OUT" | grep -qE 'Trigger:.*kind=time;time=0900' \
    && ok "P5-08 task-info: Trigger: kind=time;time=0900 (managed)" \
    || bad "P5-08 task-info: Trigger line missing out=[$(printf '%s\n' "$CLI_OUT" | grep -E 'Trigger|Next|Cause|State' | tr '\n' ' ')]"
printf '%s\n' "$CLI_OUT" | grep -qE 'Next Due:.*300s' \
    && ok "P5-08 task-info: Next Due: 300s (managed)" \
    || bad "P5-08 task-info: Next Due line missing"
printf '%s\n' "$CLI_OUT" | grep -qE 'Dependency State:.*ok' \
    && ok "P5-08 task-info: Dependency State: ok (managed)" \
    || bad "P5-08 task-info: Dependency State line missing"
printf '%s\n' "$CLI_OUT" | grep -qE 'Condition State:.*ok' \
    && ok "P5-08 task-info: Condition State: ok (managed)" \
    || bad "P5-08 task-info: Condition State line missing"
# legacy 域 task-info 不显示新字段（RUNTIME_LOADED=0 经 cli harness；既有输出零改动）
. ./tests/cli/harness.sh
CLI_TMP="$T/cli"; mkdir -p "$CLI_TMP/tasks/t_empty" "$CLI_TMP/shells"
printf 'echo x\n' > "$CLI_TMP/tasks/t_empty/command.txt"
printf 'SUCCESS\n' > "$CLI_TMP/tasks/t_empty/status.txt"
cli_run cmd_task_info t_empty
printf '%s\n' "$CLI_OUT" | grep -q 'kind=time' && bad "P5-08 task-info: legacy domain shows Trigger line" \
    || ok "P5-08 task-info: legacy domain no new labels (RUNTIME_LOADED=0, C2 intact)"

# ── 8) 接线 + POSIX ────────────────────────────────────────────────────────
grep -q 'cmd_task_list()' "$CLI" && grep -q 'task_cli_attach "$DATA_DIR"' "$CLI" && ok "P2-08 wiring: task list reads registry via attach (no config rescan)" || bad "P2-08 wiring: task list attach missing"
grep -q 'task_cli_status_id "$DATA_DIR"' "$CLI" && ok "P2-08 wiring: task status routes via §13 status_id" || bad "P2-08 wiring: status_id missing in CLI"
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-08 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §13)" || bad "P2-08 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-08 POSIX: bash -n ok (dash unavailable)" || bad "P2-08 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "task-cli-prod tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1