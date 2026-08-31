#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Runtime State & Event Log 测试（P1-09）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应验收标准）：
#   1) 新状态来源与事件日志格式：state.txt / events.log、7 字段事件行、
#      权限（目录 0755、文件 0644）
#   2) 事件记录字段：timestamp|task_id|event|state|pid|exit_code|message
#      （message 内 | 归一为 ;，保持字段稳定）
#   3) 原子性：state.txt 无 .tmp 残留；事件行完整（append 单行）
#   4) 日志写入失败（只读/目录只读）→ 返回非 0 且**不中止任务执行**
#   5) 非法 state / 未知 event → 整体拒绝，不污染状态源（P1-03 原则）
#   6) 验收 2：新旧状态不互覆盖——旧工件（status.txt/output.log/
#      exit_code.txt/pid.txt）在整个流程中保持原样
#   7) 验收 1：现有 CLI 仍能查看旧任务结果——旧工件内容与 P1-08
#      action-run 产物一致并保持可读
#   8) 验收 3：daemon 重启后识别残留运行记录——scan_stale：运行态 +
#      死 pid → daemon_restart 事件 + state.txt=FAILED（task_state_rehydrate）、
#      旧 status.txt 不动；存活 pid / 非运行态不识别；新状态源缺失时从旧
#      status.txt 推导
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ../state-machine/lib.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

BASE=$(mktemp -d)
T="$BASE/task1"
mkdir -p "$T"

# ── 1) 新状态来源与文件命名/权限 ────────────────────────────────────────────
[ "$(runtime_state_file "$T")" = "$T/state.txt" ] && ok "state source file = <dir>/state.txt" || bad "state file path"
[ "$(runtime_events_file "$T")" = "$T/events.log" ] && ok "events file = <dir>/events.log" || bad "events file path"

# ── 6/7) 旧工件先置为 P1-08 产出（验收 1/2 基线）────────────────────────────
printf 'SUCCESS\n' > "$T/status.txt"
printf 'echo legacy-output-line\n' > "$T/output.log"
printf '0\n' > "$T/exit_code.txt"
printf '%s\n' "$$" > "$T/pid.txt"
printf 'echo legacy-output-line\n' > "$T/command.txt"

# 事件写入（会创建新文件）
RT_LOG=0 runtime_log_event "$T" task1 spawn STARTING "$$" "" "task starting" \
    && ok "log_event spawn STARTING accepted" || bad "log_event spawn"
RT_LOG=0 runtime_log_event "$T" task1 action_success STOPPED "$$" 0 "task done" \
    && ok "log_event action_success STOPPED accepted" || bad "log_event success"

# 新文件存在且权限正确
[ -f "$T/state.txt" ] && ok "state.txt created" || bad "state.txt missing"
[ -f "$T/events.log" ] && ok "events.log created" || bad "events.log missing"
perm_state=$(ls -l "$T/state.txt" | awk '{print $1}')
[ "$perm_state" = "-rw-r--r--" ] && ok "state.txt mode 0644 ($perm_state)" || bad "state.txt mode $perm_state"
perm_ev=$(ls -l "$T/events.log" | awk '{print $1}')
[ "$perm_ev" = "-rw-r--r--" ] && ok "events.log mode 0644 ($perm_ev)" || bad "events.log mode $perm_ev"
perm_dir=$(ls -ld "$T" | awk '{print $1}')
[ "$perm_dir" = "drwxr-xr-x" ] && ok "task dir mode 0755 ($perm_dir)" || bad "task dir mode $perm_dir"

# ── 2) 事件行格式：7 字段、字段内容、message 竖线归一 ───────────────────────
RT_LOG=0 runtime_log_event "$T" task1 manual_exec RUNNING 42 3 "msg-a|msg-b" \
    && ok "log_event manual_exec RUNNING accepted" || bad "log_event manual"
lines=$(wc -l < "$T/events.log")
[ "$lines" -eq 3 ] && ok "events.log appended 3 lines" || bad "events.log lines=$lines"
tail1=$(tail -1 "$T/events.log")
nf=$(printf '%s\n' "$tail1" | awk -F'|' '{print NF}')
[ "$nf" -eq 7 ] && ok "event line has 7 fields (NF=$nf)" || bad "event line NF=$nf (got: $tail1)"
case "$tail1" in
    *"|task1|manual_exec|RUNNING|42|3|msg-a;msg-b") ok "event fields: id/event/state/pid/exit_code/message (|->;)" ;;
    *) bad "event field content: $tail1" ;;
esac
ts1=$(printf '%s\n' "$tail1" | cut -d'|' -f1)
case "$ts1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ok "event timestamp format: $ts1" ;;
    *) bad "event timestamp format: $ts1" ;;
esac

# state.txt 为最新状态（最后写入的 RUNNING）
[ "$(cat "$T/state.txt")" = "RUNNING" ] && ok "state.txt = latest state RUNNING" || bad "state.txt=$(cat "$T/state.txt")"

# 当前状态读取（新源优先）
[ "$(runtime_current_state "$T")" = "RUNNING" ] && ok "runtime_current_state from state.txt" || bad "current state"

# ── 3) 原子性：无 .tmp 残留 ────────────────────────────────────────────────
[ "$(find "$T" -name '*.tmp' | wc -l)" -eq 0 ] && ok "no .tmp leftovers (atomic tmp+mv)" || bad ".tmp leftovers"

# ── 5) 非法 state / 未知 event 拒绝（不污染状态源） ─────────────────────────
before_lines=$(wc -l < "$T/events.log")
RT_LOG=0 runtime_log_event "$T" task1 spawn BOGUS_STATE 1 "" "bad" \
    && bad "illegal state BOGUS_STATE should be rejected" || ok "illegal state rejected"
RT_LOG=0 runtime_log_event "$T" task1 fly RUNNING 1 "" "unknown event" \
    && bad "unknown event 'fly' should be rejected" || ok "unknown event rejected"
[ "$(wc -l < "$T/events.log")" -eq "$before_lines" ] && ok "rejections wrote nothing to events.log" || bad "rejection leaked event line"
[ "$(cat "$T/state.txt")" = "RUNNING" ] && ok "rejections left state.txt unchanged" || bad "state.txt polluted by rejection"

# ── 4) 日志写入失败不中止任务执行 ──────────────────────────────────────────
# events.log 只读 → 第一步（append）失败 → rc 2；随后用例继续执行（未中止）
chmod 444 "$T/events.log"
RT_LOG=0 runtime_log_event "$T" task1 timeout STOPPING "" 9 "rot log" >/dev/null 2>&1
rc=$?
chmod 644 "$T/events.log"
[ "$rc" -ne 0 ] && ok "append failure -> rc=$rc (non-zero)" || bad "append failure should be non-zero"
# 上文已证明未中止（本用例之后的断言均继续执行）；显式再验一次恢复后可写
RT_LOG=0 runtime_log_event "$T" task1 timeout STOPPING "" 9 "recovered log" \
    && ok "log_event works again after permission restore (execution not aborted)" || bad "log_event after restore"
# 目录只读 → state 写入（tmp+mv）失败 → rc 2；事件该行仍已追加（先事件后状态）
ev_before=$(wc -l < "$T/events.log")
chmod 555 "$T"
RT_LOG=0 runtime_log_event "$T" task1 daemon_restart FAILED "" 1 "perm dir" >/dev/null 2>&1
rc2=$?
chmod 755 "$T"
[ "$rc2" -ne 0 ] && ok "state write failure -> rc=$rc2 (non-zero)" || bad "state write failure should be non-zero"
[ "$(wc -l < "$T/events.log")" -gt "$ev_before" ] && ok "event line recorded before state failure (order: event then state)" || bad "event order on state failure"
rm -f "$T/state.txt.tmp"

# ── 6) 验收 2：新旧状态不互覆盖（旧工件全程未变） ──────────────────────────
[ "$(cat "$T/status.txt")" = "SUCCESS" ] && ok "legacy status.txt untouched (new/old never overwrite)" || bad "status.txt modified"
[ "$(cat "$T/output.log")" = "echo legacy-output-line" ] && ok "legacy output.log untouched" || bad "output.log modified"
[ "$(cat "$T/exit_code.txt")" = "0" ] && ok "legacy exit_code.txt untouched" || bad "exit_code.txt modified"
[ "$(cat "$T/pid.txt")" = "$$" ] && ok "legacy pid.txt untouched" || bad "pid.txt modified"
[ "$(cat "$T/state.txt")" != "$(cat "$T/status.txt")" ] && ok "state.txt/status.txt coexist with distinct values (no overwrite)" || bad "state and status identical (overlap?)"

# ── 7) 验收 1：现有 CLI 仍能查看旧任务结果 ─────────────────────────────────
# CLI（task-info/task-output）读取的就是 status.txt/output.log/exit_code.txt
# —— 上面已断言原样保留；此处再模拟"CLI 视角"可读性
[ -r "$T/status.txt" ] && [ -r "$T/output.log" ] && [ -r "$T/exit_code.txt" ] \
    && ok "legacy artifacts remain readable (CLI view preserved)" || bad "legacy artifacts unreadable"

# ── 8) 验收 3：daemon 重启后识别残留运行记录 ───────────────────────────────
TASKS="$BASE/tasks"
mkdir -p "$TASKS"
# 8a) 残留 A：旧 status.txt=RUNNING + 死 pid + 无 state.txt → 从旧推导识别
A="$TASKS/stale_a"; mkdir -p "$A"
printf 'RUNNING\n' > "$A/status.txt"
printf 'deadpid-not-a-number\n' > "$A/pid.txt"
# 8b) 残留 B：新 state.txt=RUNNING + 死 pid（同时旧 status.txt=RUNNING）
B="$TASKS/stale_b"; mkdir -p "$B"
printf 'RUNNING\n' > "$B/status.txt"
printf 'RUNNING\n' > "$B/state.txt"
printf '99999999\n' > "$B/pid.txt"
# 8c) 非残留：存活 pid（当前 shell $$）→ 不识别
C="$TASKS/alive"; mkdir -p "$C"
printf 'RUNNING\n' > "$C/status.txt"
printf 'RUNNING\n' > "$C/state.txt"
printf '%s\n' "$$" > "$C/pid.txt"
# 8d) 非残留：status SUCCESS（非运行态）→ 不识别
D="$TASKS/done"; mkdir -p "$D"
printf 'SUCCESS\n' > "$D/status.txt"
printf '%s\n' "$$" > "$D/pid.txt"
# 8e) 残留 E：新 state.txt=STARTING（执行态）+ 死 pid
E="$TASKS/stale_e"; mkdir -p "$E"
printf 'RUNNING\n' > "$E/status.txt"
printf 'STARTING\n' > "$E/state.txt"
printf '77777777\n' > "$E/pid.txt"

ids=$(RT_LOG=0 runtime_scan_stale "$TASKS")
# ids 是换行分隔（每行一个 id），case 用无包围空格的子串匹配
case " $ids " in
    *"stale_a"*) ok "scan identified stale_a (legacy-only source, derived)" ;;
    *) bad "stale_a not identified: [$ids]" ;;
esac
case " $ids " in
    *"stale_b"*) ok "scan identified stale_b (new state source)" ;;
    *) bad "stale_b not identified" ;;
esac
case " $ids " in
    *"stale_e"*) ok "scan identified stale_e (STARTING rehydrated)" ;;
    *) bad "stale_e not identified" ;;
esac
case " $ids " in
    *"alive"*) bad "alive task wrongly identified as stale" ;;
    *) ok "scan skipped alive task (pid $$ exists)" ;;
esac
case " $ids " in
    *"done"*) bad "completed task (SUCCESS) wrongly identified" ;;
    *) ok "scan skipped completed task" ;;
esac

# 残留识别后的状态/事件（仅新源更新；旧 status.txt 不动）
[ "$(cat "$B/state.txt")" = "FAILED" ] && ok "stale_b state.txt -> FAILED (rehydrated)" || bad "stale_b state=$(cat "$B/state.txt")"
[ "$(cat "$B/status.txt")" = "RUNNING" ] && ok "stale_b legacy status.txt stays RUNNING (no overwrite)" || bad "stale_b status.txt changed"
grep -q '|daemon_restart|FAILED|' "$B/events.log" && ok "stale_b events.log records daemon_restart -> FAILED" || bad "stale_b no daemon_restart event"
[ "$(cat "$A/state.txt")" = "FAILED" ] && ok "stale_a state.txt created as FAILED (derived from legacy RUNNING)" || bad "stale_a state=$(cat "$A/state.txt")"
grep -q '|daemon_restart|FAILED|' "$A/events.log" && ok "stale_a events.log records daemon_restart" || bad "stale_a no event"
[ "$(cat "$A/status.txt")" = "RUNNING" ] && ok "stale_a legacy status.txt untouched" || bad "stale_a status.txt modified"
[ "$(cat "$E/state.txt")" = "FAILED" ] && ok "stale_e STARTING -> FAILED (rehydrate)" || bad "stale_e state=$(cat "$E/state.txt")"
[ "$(cat "$C/state.txt")" = "RUNNING" ] && ok "alive task state.txt kept RUNNING (not rehydrated)" || bad "alive state changed"
[ -f "$D/events.log" ] && bad "done task should have no events.log" || ok "completed task untouched by scan"

# ── 汇总 ────────────────────────────────────────────────────────────────────
rm -rf "$BASE"
echo "──────────────────────────────────────────────────────────────────────"
echo "runtime tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1