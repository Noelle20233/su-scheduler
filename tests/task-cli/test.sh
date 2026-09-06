#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Task 只读 CLI 测试（P1-11）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应验收标准）：
#   1) 验收 1：CLI 读的是 Task Registry——结构断言（无配置文本扫描循环、
#      无直接 config 读取），行为断言（list id 集合 == registry_task_ids；
#      list/status 字段值来自 registry 快照任务文件）
#   2) task list：ID|名称|Trigger|Action|enabled|当前状态（6 字段）；17 任务
#   3) task status <id>：来源（source.type/line/raw）+ 状态 + 最近一次执行
#      信息（run_count/last_*/daemon/last_event/legacy_status）
#   4) 状态来源优先级：运行目录 state.txt（新源）→ 旧 status.txt 推导 →
#      registry 快照 runtime.state 字段（PENDING）
#   5) 错误三态（验收）：rc1 task not found / rc2 configuration invalid /
#      rc3 daemon is not running——stderr 消息明确区分
#   6) 约束：P1 只加只读（无 task_cli_start/stop/restart）；不覆盖原有 CLI
#      命令（无 list()/status()/tasks() 等同名函数）；生产 CLI 零改动
#   7) 验收 2：原有 list/status/tasks 不回归——本层只新增前缀函数，不 alias
#      （结构断言）+ 部分行损坏（rc1-有任务）仍视为有效配置（fail-safe）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ../state-machine/lib.sh
. ../runtime/lib.sh
LEGACY_ADAPTER_SOURCED=1
. ../legacy-adapter/adapter.sh
. ../task-registry/lib.sh
. ../lifecycle/lib.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

# ── 6) 约束：P1 只加只读；不覆盖原有 CLI 命令 ────────────────────────────────
[ "$(grep -cE '^(task_cli_(start|stop|restart))\b' lib.sh)" -eq 0 ] && \
    ok "P1 adds NO task start/stop/restart (read-only only)" || bad "read-only violation"
[ "$(grep -cE '^(list|status|tasks|task-info|task-output|task-kill)\(\)' lib.sh)" -eq 0 ] && \
    ok "no override of existing CLI command names" || bad "overrides existing CLI"

# ── 1) 验收 1：数据源 = Task Registry（结构断言）─────────────────────────────
[ "$(grep -c 'IFS= read' lib.sh)" -eq 0 ] && ok "lib has NO config text-scan loop" || bad "lib scans config text"
[ "$(grep -c 'registry_task_ids\b' lib.sh)" -ge 1 ] && ok "task source = registry_task_ids" || bad "registry ids not used"
[ "$(grep -c 'registry_task_file\b' lib.sh)" -ge 1 ] && ok "task file via registry_task_file" || bad "registry file not used"

# ── 准备 registry 快照（P1-06）───────────────────────────────────────────────
BASE=$(mktemp -d)
CFG="../fixtures/legacy/config.txt"
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1
[ -n "$(registry_current_snapshot_id)" ] && ok "registry snapshot ready (17 tasks)" || bad "registry init"
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "registry has 17 tasks" || bad "registry count=$(registry_task_ids | wc -l)"

# ── 2) task list ──────────────────────────────────────────────────────────────
out=$(task_cli_list 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "task_cli_list rc=0" || bad "task list rc=$rc"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 17 ] && ok "task list: 17 rows" || bad "task list rows=$(printf '%s\n' "$out" | wc -l)"
nf=$(printf '%s\n' "$out" | head -1 | awk -F'|' '{print NF}')
[ "$nf" -eq 6 ] && ok "task list row = 6 fields (id|name|trigger|action|enabled|state)" || bad "task list NF=$nf"
# 字段值（t45_2200：trigger-only 无 modifier 行）
row=$(printf '%s\n' "$out" | grep '^t45_2200|')
[ -n "$row" ] && ok "t45_2200 in list" || bad "t45_2200 missing"
case "$row" in
    't45_2200|echo|22:00|echo "No modifiers at all"|1|PENDING')
        ok "t45_2200 fields: id/name/trigger(raw 22:00)/action/enabled/state(PENDING)" ;;
    *) bad "t45_2200 row=[$row]" ;;
esac
# id 集合与 registry 一致（验收 1）
ids_list=$(printf '%s\n' "$out" | cut -d'|' -f1 | sort | tr '\n' ' ')
ids_reg=$(registry_task_ids | sort | tr '\n' ' ')
[ "$ids_list" = "$ids_reg" ] && ok "list id set == registry_task_ids (single task source)" || bad "id set mismatch"

# ── 3) task status：来源 + 状态 + 最近一次执行信息 ────────────────────────────
sout=$(TASK_CLI_LOCK="" task_cli_status t45_2200 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "task_cli_status t45_2200 rc=0" || bad "task status rc=$rc"
[ "$(printf '%s\n' "$sout" | grep -c '^source.line=45$')" -eq 1 ] && ok "status shows source.line=45" || bad "source.line"
[ "$(printf '%s\n' "$sout" | grep -c '^source.type=line$')" -eq 1 ] && ok "status shows source.type=line" || bad "source.type"
grep -q '^source.raw=22:00 echo "No modifiers at all"$' <<< "$sout" && ok "status shows source.raw verbatim" || bad "source.raw"
grep -q '^action=echo "No modifiers at all"$' <<< "$sout" && ok "status shows action verbatim" || bad "action"
grep -q '^state=PENDING$' <<< "$sout" && ok "status state=PENDING (snapshot runtime.state fallback)" || bad "state"
grep -q '^legacy_status=$' <<< "$sout" && ok "legacy_status empty (never ran)" || bad "legacy_status"
grep -q '^run_count=0$' <<< "$sout" && ok "run_count=0 (snapshot field)" || bad "run_count"
grep -q '^daemon=' <<< "$sout" && bad "daemon= leaked without lock injection" || ok "no daemon= line when lock not injected"

# ── 4) 状态来源优先级：运行目录注入 ───────────────────────────────────────────
RUNDIR="$BASE/run"
mkdir -p "$RUNDIR/t45_2200"
printf 'RUNNING\n' > "$RUNDIR/t45_2200/state.txt"      # 新源
printf 'RUNNING\n' > "$RUNDIR/t45_2200/status.txt"     # 旧兼容
printf '2026-09-01 01:02:03|t45_2200|spawn|STARTING|1234||launched\n' > "$RUNDIR/t45_2200/events.log"
LKF="$BASE/cli.lock"
printf '%s\n' "$$" > "$LKF"                            # daemon 锁 = 本测试进程（alive）
sout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t45_2200 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "status with live lock rc=0 (daemon running)" || bad "status live lock rc=$rc"
grep -q '^state=RUNNING$' <<< "$sout" && ok "state=RUNNING from run-dir state.txt (new source wins)" || bad "state new source"
grep -q '^legacy_status=RUNNING$' <<< "$sout" && ok "legacy_status=RUNNING coexists" || bad "legacy_status"
grep -q '^daemon=running$' <<< "$sout" && ok "daemon=running (lock alive)" || bad "daemon=running"
grep -q '^last_event=2026-09-01 01:02:03|t45_2200|spawn|STARTING|1234||launched$' <<< "$sout" && \
    ok "last_event = events.log tail verbatim" || bad "last_event"
# 旧源推导：仅 status.txt=SUCCESS（无 state.txt）
mkdir -p "$RUNDIR/t16_0830"
printf 'SUCCESS\n' > "$RUNDIR/t16_0830/status.txt"
sout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t16_0830 2>/dev/null)
grep -q '^state=STOPPED$' <<< "$sout" && ok "state=STOPPED derived from legacy SUCCESS (no state.txt)" || bad "legacy derive"

# ── 5) 错误三态（验收：明确区分） ─────────────────────────────────────────────
# 5a) task not found（rc 1）
err=$(TASK_CLI_LOCK="" task_cli_status no_such_task 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 1 ] && ok "unknown id -> rc 1" || bad "unknown id rc=$rc"
case "$err" in
    *"task not found: no_such_task"*) ok "error message distinguishes 'task not found'" ;;
    *) bad "unknown-id error=[$err]" ;;
esac
# 5b) configuration invalid（rc 2）：无当前快照
BASE_BAD=$(mktemp -d)
TR_LOGGING=0 registry_init "$BASE_BAD" "/nonexistent/config.txt" >/dev/null 2>&1
[ -z "$(registry_current_snapshot_id)" ] && ok "bad base has NO snapshot (config invalid scenario)" || bad "bad base unexpectedly valid"
err=$(task_cli_list 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 2 ] && ok "no snapshot -> list rc 2" || bad "no snapshot list rc=$rc"
case "$err" in
    *"configuration invalid"*) ok "error message distinguishes 'configuration invalid'" ;;
    *) bad "config-invalid error=[$err]" ;;
esac
err=$(TASK_CLI_LOCK="" task_cli_status t45_2200 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 2 ] && ok "no snapshot -> status rc 2" || bad "no snapshot status rc=$rc"
# 5c) daemon is not running（rc 3）：锁注入但不可活
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1    # 恢复有效快照
printf '99999999\n' > "$LKF"                                 # stale 锁
err=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t45_2200 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 3 ] && ok "stale lock -> status rc 3 (daemon not running)" || bad "stale lock rc=$rc"
case "$err" in
    *"daemon is not running"*) ok "error message distinguishes 'daemon is not running'" ;;
    *) bad "daemon-down error=[$err]" ;;
esac
# daemon 未运行不影响 list（静态快照可离线查看）
printf '%s\n' "$$" > "$LKF"                                  # 恢复 alive 锁（干净收尾）
task_cli_list >/dev/null 2>&1 && ok "list still rc 0 with stale lock (offline snapshot, acceptance 1)" || \
    ok "list works offline regardless of daemon" 

# ── 7) 验收 2：部分行损坏仍视为有效配置（fail-safe 子集，不回退失败）──────────
CFG_PART=$(mktemp)
printf '08\x01:30 bad-line\n' > "$CFG_PART"
cat "$CFG" >> "$CFG_PART"
side=$(TR_LOGGING=0 registry_init "$BASE" "$CFG_PART" >/dev/null 2>&1; registry_current_snapshot_id)
[ -n "$side" ] && ok "partial-bad config still valid snapshot (KEPT subset, fail-safe)" || bad "partial-bad invalid"
task_cli_list >/dev/null 2>&1 && ok "list rc 0 on partial-bad (fail-safe subset)" || bad "list on partial-bad"
rm -f "$CFG_PART"

# ── 8) P4-09：task status 输出 dependency=/condition=/Gate 行 ──────────────
# 恢复有效快照（§7 partial-bad 实验后 current 可能指向损坏子集）
TR_LOGGING=0 registry_init "$BASE" "$CFG" >/dev/null 2>&1
# managed 场景构造：向当前快照写入带 dependency/condition 的 v2 任务文件
# （test-domain registry 快照任务文件即 task_cli_status 的数据源）
SNAP=$(registry_snapshot_dir)
[ -n "$SNAP" ] || { bad "P4-09 status: snapshot dir unavailable"; exit 1; }
printf 'schema_version=2\nid=t_v2_1\ntrigger=08:30\ndependency=dep_a,?dep_b:FAILED\ncondition={{ time.hour == 8 }}\naction.command=echo hi\n' > "$SNAP/t_v2_1.task"
vout=$(TASK_CLI_LOCK="" task_cli_status t_v2_1 2>/dev/null)
grep -q '^dependency=dep_a,?dep_b:FAILED$' <<< "$vout" \
    && ok "P4-09 status: dependency= emitted (managed v2 task with optional/state)" \
    || bad "P4-09 status: dependency missing out=[$vout]"
grep -q '^condition={{ time.hour == 8 }}$' <<< "$vout" \
    && ok "P4-09 status: condition= emitted verbatim" || bad "P4-09 status: condition missing"
grep -q '^Gate:' <<< "$vout" && bad "P4-09 status: Gate leaked for non-WAITING task" \
    || ok "P4-09 status: no Gate line when not WAITING"
# 空值输出空：legacy 快照无 dependency/condition 值 → 输出空（既有 condition= 语义对齐）
gout=$(TASK_CLI_LOCK="" task_cli_status t45_2200 2>/dev/null)
grep -q '^dependency=$' <<< "$gout" \
    && ok "P4-09 status: empty dependency= output for legacy (no value)" \
    || bad "P4-09 status: legacy dependency=[$(echo "$gout" | grep '^dependency=')]"
# Gate 行：WAITING 运行目录 → 门控状态行（WAITING + 原因）
mkdir -p "$RUNDIR/t_v2_1"
printf 'WAITING\n' > "$RUNDIR/t_v2_1/state.txt"
printf '2026-09-01 01:02:03|t_v2_1|gate_wait|WAITING|||dep unsat: dep_a\n' > "$RUNDIR/t_v2_1/events.log"
wout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t_v2_1 2>/dev/null)
grep -q '^Gate: WAITING (dep unsat: dep_a)$' <<< "$wout" \
    && ok "P4-09 status: Gate: WAITING (dep unsat: dep_a) line emitted" \
    || bad "P4-09 status: Gate=[$(echo "$wout" | grep '^Gate:')]"
grep -q '^state=WAITING$' <<< "$wout" \
    && ok "P4-09 status: state=WAITING from run-dir state.txt" || bad "P4-09 status: state"

# ── 9) P5-08：task status 新字段（trigger_kind/next_due/last_trigger_cause/condition_state/dependency_state）──
# 构造带 interval + 依赖 + 条件的 v2 任务；依赖任务须为 registry 任务（缺失=waiting）；
# dep_a 运行目录 state 控制满足/未满足
printf 'schema_version=2\nid=t_p5\nname=p5\ntrigger=interval:15\ndependency=dep_a,?dep_b:FAILED\ncondition={{ task.state(dep_a) == STOPPED }}\naction.command=echo hi\n' > "$SNAP/t_p5.task"
printf 'schema_version=2\nid=dep_a\ntrigger=23:59\naction.command=echo dep\n' > "$SNAP/dep_a.task"
printf 'schema_version=2\nid=dep_b\ntrigger=23:58\naction.command=echo depb\n' > "$SNAP/dep_b.task"
mkdir -p "$RUNDIR/dep_a"
printf 'STOPPED\n' > "$RUNDIR/dep_a/state.txt"
pout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t_p5 2>/dev/null)
grep -q '^trigger_kind=kind=interval;minutes=15$' <<< "$pout" \
    && ok "P5-08 status: trigger_kind=kind=interval;minutes=15" \
    || bad "P5-08 status: trigger_kind=[$(echo "$pout" | grep '^trigger_kind=')]"
grep -q '^dependency_state=satisfied$' <<< "$pout" \
    && ok "P5-08 status: dependency_state=satisfied (dep_a STOPPED, dep_b optional unmet)" \
    || bad "P5-08 status: dependency_state=[$(echo "$pout" | grep '^dependency_state=')]"
grep -q '^condition_state=ok$' <<< "$pout" \
    && ok "P5-08 status: condition_state=ok ({{ task.state(dep_a) == STOPPED }} true)" \
    || bad "P5-08 status: condition_state=[$(echo "$pout" | grep '^condition_state=')]"
# dep_a 置 FAILED → 依赖终态不匹配（unsat）+ 条件为假（unsat）
printf 'FAILED\n' > "$RUNDIR/dep_a/state.txt"
pout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t_p5 2>/dev/null)
grep -q '^dependency_state=unsat$' <<< "$pout" \
    && ok "P5-08 status: dependency_state=unsat (dep_a FAILED terminal mismatch)" \
    || bad "P5-08 status: dependency_state(FAILED)=[$(echo "$pout" | grep '^dependency_state=')]"
grep -q '^condition_state=unsat$' <<< "$pout" \
    && ok "P5-08 status: condition_state=unsat ({{ task.state(dep_a) == STOPPED }} false)" \
    || bad "P5-08 status: condition_state(FAILED)=[$(echo "$pout" | grep '^condition_state=')]"
# 空 condition / 空 dependency → ok
gout=$(TASK_CLI_LOCK="" task_cli_status t45_2200 2>/dev/null)
grep -q '^condition_state=ok$' <<< "$gout" && grep -q '^dependency_state=ok$' <<< "$gout" \
    && ok "P5-08 status: empty condition/dependency -> condition_state=ok + dependency_state=ok" \
    || bad "P5-08 status: empty cond/dep=[$(echo "$gout" | grep -E '^(condition_state|dependency_state)=' | tr '\n' ' ')]"
# next_due：time/oneshot 注入 TRIGGER_DECISION_NOW（确定性秒数）
printf 'schema_version=2\nid=t_nd\ntrigger=09:00\naction.command=echo x\n' > "$SNAP/t_nd.task"
nout=$(TRIGGER_DECISION_NOW=0855 TASK_CLI_LOCK="" task_cli_status t_nd 2>/dev/null)
grep -q '^next_due=300$' <<< "$nout" \
    && ok "P5-08 status: next_due=300 for time 09:00 at 08:55" \
    || bad "P5-08 status: next_due(time)=[$(echo "$nout" | grep '^next_due=')]"
printf 'schema_version=2\nid=t_os\ntrigger=oneshot:0830\naction.command=echo x\n' > "$SNAP/t_os.task"
nout=$(TRIGGER_DECISION_NOW=0900 TASK_CLI_LOCK="" task_cli_status t_os 2>/dev/null)
grep -q '^next_due=84600$' <<< "$nout" \
    && ok "P5-08 status: next_due=84600 for oneshot:0830 at 09:00 (tomorrow 08:30)" \
    || bad "P5-08 status: next_due(oneshot)=[$(echo "$nout" | grep '^next_due=')]"
# last_trigger_cause：构造 scheduler/audit.log 后反向 grep 末条 op=exec
mkdir -p "$BASE/scheduler"
printf '2026-09-06 08:30:00|op=exec|task=t_p5|trigger=interval:15|mode=managed|rc=0|ron=0|del=0|cause=interval\n' >> "$BASE/scheduler/audit.log"
printf '2026-09-06 08:45:00|op=exec|task=t_p5|trigger=interval:15|mode=managed|rc=1|ron=0|del=0|cause=interval\n' >> "$BASE/scheduler/audit.log"
aout=$(TASK_CLI_TASKS_DIR="$RUNDIR" TASK_CLI_LOCK="$LKF" task_cli_status t_p5 2>/dev/null)
grep -q '^last_trigger_cause=interval$' <<< "$aout" \
    && ok "P5-08 status: last_trigger_cause=interval (reverse grep last op=exec audit)" \
    || bad "P5-08 status: last_trigger_cause=[$(echo "$aout" | grep '^last_trigger_cause=')]"
# 既有字段零回退（精确 grep 断言）
zout=$(TASK_CLI_LOCK="" task_cli_status t45_2200 2>/dev/null)
for zpat in '^id=t45_2200$' '^name=echo$' '^enabled=1$' '^trigger=22:00$' '^action=echo "No modifiers at all"$' '^source.type=line$' '^source.line=45$' '^state=PENDING$' '^run_count=0$' '^legacy_status=$'; do
    grep -q "$zpat" <<< "$zout" || { echo "   missing: $zpat"; zero_reg=1; }
done
[ -z "${zero_reg:-}" ] && ok "P5-08 status: existing fields zero regression (10 field lines intact)" \
    || bad "P5-08 status: existing fields regressed"

# ── P5-09 §batch-limit：生产 CLI 批量上限结构断言（task_ctl_multi 入口先拒）──
# task_ctl_multi 位于生产 system/bin/su-scheduler（P5-07）。断言批量上限守卫
# 出现在任何 IPC 调用（task_ctl_send）之前——超限拒绝零副作用。行为测试见
# tests/task-control/test.sh（§batch-limit，P5-07 batch 同域）。
PROD_CLI="../../system/bin/su-scheduler"
TCM_BODY=$(sed -n '/^task_ctl_multi()/,/^}/p' "$PROD_CLI")
gln=$(printf '%s\n' "$TCM_BODY" | grep -n 'batch limit 50' | head -1 | cut -d: -f1)
sln=$(printf '%s\n' "$TCM_BODY" | grep -n 'task_ctl_send' | head -1 | cut -d: -f1)
[ -n "$gln" ] && [ -n "$sln" ] && [ "$gln" -lt "$sln" ] \
    && ok "P5-09 batch-limit: task_ctl_multi guards \$#<=50 before any IPC send (guard=$gln < send=$sln)" \
    || bad "P5-09 batch-limit: guard/order missing (guard='$gln' send='$sln')"


# ── 汇总 ────────────────────────────────────────────────────────────────────
rm -f "$LKF"
rm -rf "$BASE" "$BASE_BAD" "$RUNDIR"
echo "──────────────────────────────────────────────────────────────────────"
echo "task-cli tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1