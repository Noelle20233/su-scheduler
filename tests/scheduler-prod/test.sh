#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Registry 正式调度接管（P3-03）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P3-03 出口：Registry 从 Shadow 提升为正式调度源，结束双轨状态）：
#   1) 双模式控制：managed（task-config/MANAGED）从 task-config 重建快照；
#      legacy（无标记）从 config.txt 重建（registry_reload，KEPT 回退）；
#   2) Managed 模式执行只来自 Registry：config.txt 中仅存的"外来任务"绝不执行
#      （不重扫 config.txt——P3-03 要求 6）；
#   3) Legacy 模式行为不变：scheduler_tick 经 registry（config.txt 投影）执行
#      到期任务，与既有 legacy 语义一致；
#   4) 同一 Task 一个调度周期至多执行一次（cycle 去重；分钟 token）；
#   5) 配置变更不产生重复执行：源指纹变化才 reload；同周期不重复执行；
#   6) Registry 损坏 → 继续使用最后有效快照（KEPT）；
#   7) 旧 CLI 查询/终止旧运行任务：执行落 tasks/<id>（canonical）+ idmap 双向
#      映射（runtime_map_refresh / runtime_map_run_task）；
#   8) 快照移除的运行任务仍被监督：task.v2 stash + supervisor_task_file 兜底；
#   9) 单任务错误隔离：坏任务不中止整个 tick（scheduler_tick 返回 0）；
#  10) 接线：daemon 主循环经 scheduler_tick（RUNTIME_LOADED=1）执行、
#      scheduler_boot 启动 boot、legacy config.txt 扫描降级为 fallback
#      （action_run/execute_task 各恰 4 处、while true 恰 1、RUNTIME_LOADED 门控）；
#  11) 审计日志：<base>/scheduler/audit.log 记录 reload/exec/boot/tick 来源。
# 加载：`. ./$RTLIB`；daemon 上下文用 execute_task shim（镜像 execute_task 工件
# 语义），使 action_run 走既有委托路径（与 P2-06 同法）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
DAEMON="system/bin/su-schedulerd"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── daemon 上下文 shim：action_run 委托到 execute_task（镜像 daemon 工件）──
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"      # 记录每次执行：<id>|<cmd>|<termux>|<interactive>|<ns>|<ne>|<msg>
execute_task() {            # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    ( echo "$cmd" > "$d/output.log" 2>&1 ) &
    echo $! > "$d/pid.txt"
    echo "$id|$cmd|$tmx|$itr|$ns|$ne|$msg" >> "$EXEC_LOG"
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    return 0
}
. ./$RTLIB

# D-P5-02：固定周期 token（SCHED_CYCLE_NOW，Runtime §20 既有的测试确定性注入；
# 生产缺省 = 真实分钟）。否则相邻两次 scheduler_tick 恰跨真实分钟边界时，cycle 去重
# token（sched_cycle_token）不同 → 0830 在 dedup/reload 段被二次执行 → 时间敏感
# flake（"dedup: 0830 count=2"，全量回归慢速环境复现）。断言意图（同周期不重复执行）
# 不变，仅固定确定性输入（与 P4-04 设计意图一致）。
export SCHED_CYCLE_NOW=202609040900

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"

# ── 1) 接线 + 入口（scheduler_tick / scheduler_boot / §20 原语定义）────────
fn_miss=0
for fn in scheduler_tick scheduler_boot sched_reload sched_snapshot_managed \
          sched_execute_one sched_cycle_mark sched_cycle_seen sched_source_mode; do
    type "$fn" >/dev/null 2>&1 || { bad "P3-03 entry: $fn missing"; fn_miss=1; }
done
[ "$fn_miss" -eq 0 ] && ok "P3-03 entry: §20 scheduler functions defined"
grep -q 'scheduler_tick' "$DAEMON" && ok "P3-03 wiring: daemon calls scheduler_tick (RUNTIME_LOADED=1 registry-driven)" || bad "P3-03 wiring: scheduler_tick missing in daemon"
grep -q 'scheduler_boot' "$DAEMON" && ok "P3-03 wiring: daemon calls scheduler_boot (startup boot via registry)" || bad "P3-03 wiring: scheduler_boot missing in daemon"
n=$(grep -c 'action_run' "$DAEMON")
[ "$n" -eq 4 ] && ok "P3-03 wiring: action_run still exactly 4x (legacy fallback, C2)" || bad "P3-03 wiring: action_run count=$n"
n=$(grep -cF 'execute_task "$task_id" "$cmd_to_run"' "$DAEMON")
[ "$n" -eq 4 ] && ok "P3-03 wiring: execute_task fallback 4x retained" || bad "P3-03 wiring: execute_task count=$n"
n=$(grep -c 'while true' "$DAEMON")
[ "$n" -eq 1 ] && ok "P3-03 wiring: single resident loop (while true=1)" || bad "P3-03 wiring: while true=$n"
grep -q 'scheduler_tick "\$DATA_DIR" "\$CONFIG_FILE" "\$TASKS_DIR" "\$current_time"' "$DAEMON" && ok "P3-03 wiring: main loop passes base/config/tasks/now to scheduler_tick" || bad "P3-03 wiring: scheduler_tick call signature"

# ── 2) 双模式：legacy（无 MANAGED）从 config.txt 建 registry ───────────────
cat > "$CFG" <<'EOF'
08:30 echo legacy-time-0830
12:00 echo legacy-time-1200
EOF
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"
rm -f "$TCFG_DIR/MANAGED"
registry_init "$BASE" "$CFG" >/dev/null 2>&1
[ "$(sched_source_mode "$BASE")" = "legacy" ] && ok "P3-03 mode: no MANAGED -> legacy source" || bad "P3-03 mode: expected legacy got $(sched_source_mode "$BASE")"

# ── 3) legacy 调度：0830 到期 → 执行恰一次；1200 未到期不执行 ──────────────
: > "$EXEC_LOG"
scheduler_tick "$BASE" "$CFG" "$TASKS_DIR" "0830"
grep -q '|echo legacy-time-0830|' "$EXEC_LOG" && ok "P3-03 legacy: 0830 task executed via registry (TriggerProvider->ActionProvider)" || bad "P3-03 legacy: exec log=$(cat "$EXEC_LOG")"
grep -q 'legacy-time-1200' "$EXEC_LOG" && bad "P3-03 legacy: 1200 executed early" || ok "P3-03 legacy: 1200 not due at 0830 (TriggerProvider decides)"
[ "$(wc -l < "$EXEC_LOG")" -eq 1 ] && ok "P3-03 legacy: exactly 1 execution in cycle" || bad "P3-03 legacy: exec count=$(wc -l < "$EXEC_LOG")"

# ── 4) 同一 Task 一个调度周期至多一次（同分钟再 tick → 不重复执行）──────────
scheduler_tick "$BASE" "$CFG" "$TASKS_DIR" "0830"
[ "$(grep -c 'legacy-time-0830' "$EXEC_LOG")" -eq 1 ] && ok "P3-03 dedup: same task not re-executed in same cycle" || bad "P3-03 dedup: 0830 count=$(grep -c 'legacy-time-0830' "$EXEC_LOG")"

# ── 5) 配置变更 → 原子 reload；已执行任务不重复、新任务执行一次 ─────────────
printf '\n08:31 echo legacy-time-0831\n' >> "$CFG"
scheduler_tick "$BASE" "$CFG" "$TASKS_DIR" "0831"
grep -q '|echo legacy-time-0831|' "$EXEC_LOG" && ok "P3-03 reload: new task executed after config change (atomic reload)" || bad "P3-03 reload: 0831 not executed (log=$(cat "$EXEC_LOG"))"
[ "$(grep -c 'legacy-time-0830' "$EXEC_LOG")" -eq 1 ] && ok "P3-03 reload: already-executed 0830 not duplicated" || bad "P3-03 reload: 0830 duplicated"

# ── 6) Registry 损坏 → 继续使用最后有效快照（KEPT）────────────────────────
printf '08\x01:30 x\n' > "$T/bad.cfg"     # 控制字符 → 解析无效
: > "$EXEC_LOG"
sched_reload "$BASE" "$T/bad.cfg" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "P3-03 corrupt: reload of corrupt source returns KEPT/err ($rc)" || ok "P3-03 corrupt: reload rc=$rc"
cur=$(cat "$BASE/current" 2>/dev/null)
[ -n "$cur" ] && [ "$(ls "$BASE/snapshots/$cur"/*.task 2>/dev/null | wc -l)" -ge 3 ] && ok "P3-03 corrupt: last valid snapshot retained (current=$cur)" || bad "P3-03 corrupt: no valid snapshot"
[ "$(registry_task_ids | wc -l)" -ge 3 ] && ok "P3-03 corrupt: registry_task_ids still lists last-valid tasks" || bad "P3-03 corrupt: registry list empty"

# ── 7) Managed 模式：只从 Registry 执行（不重扫 config.txt）────────────────
MCFG="$BASE/managed.cfg"
printf '09:00 echo managed-only\n' > "$MCFG"     # config.txt 外来任务
export TCFG_DIR="$BASE/task-config"
rm -rf "$TCFG_DIR"; mkdir -p "$TCFG_DIR"
echo "managed" > "$TCFG_DIR/MANAGED"
printf 'schema_version=2\nid=mtask_0900\nname=managed\ntrigger=09:00\naction.command=echo managed-task-exec\naction.termux=0\naction.interactive=0\naction.notify_start=0\naction.notify_end=0\naction.msg=\nhealth.type=none\nrecovery.type=none\nretry.max=0\nretry.interval=60\nsource.type=line\nsource.line=1\n' > "$TCFG_DIR/mtask_0900.task"
[ "$(sched_source_mode "$BASE")" = "managed" ] && ok "P3-03 managed: MANAGED marker -> managed source" || bad "P3-03 managed: mode=$(sched_source_mode "$BASE")"
: > "$EXEC_LOG"
scheduler_tick "$BASE" "$MCFG" "$TASKS_DIR" "0900"
grep -q '^mtask_0900|echo managed-task-exec|' "$EXEC_LOG" && ok "P3-03 managed: registry task executed (only source)" || bad "P3-03 managed: mtask not executed (log=$(cat "$EXEC_LOG"))"
grep -q 'managed-only' "$EXEC_LOG" && bad "P3-03 managed: config.txt foreign task executed (forbidden)" || ok "P3-03 managed: config.txt-only task NOT executed (execution only from Registry)"
[ "$(registry_task_ids | grep -c 'mtask_0900')" -eq 1 ] && ok "P3-03 managed: registry snapshot holds managed task" || bad "P3-03 managed: snapshot missing mtask"

# ── 8) 旧 CLI 查询/终止旧运行任务：执行落 tasks/<id> + idmap 双向映射 ───────
[ -d "$TASKS_DIR/mtask_0900" ] && [ -f "$TASKS_DIR/mtask_0900/pid.txt" ] && ok "P3-03 oldcli: run dir tasks/mtask_0900 created (canonical id)" || bad "P3-03 oldcli: run dir missing"
runtime_map_refresh "$BASE" "$TASKS_DIR" >/dev/null 2>&1
canon=$(runtime_map_run_task "$BASE" "mtask_0900")
[ -n "$canon" ] && ok "P3-03 oldcli: idmap run->canonical resolves ($canon)" || bad "P3-03 oldcli: run->canonical empty"
[ -n "$(runtime_map_task_runs "$BASE" "mtask_0900")" ] && ok "P3-03 oldcli: idmap canonical->run resolves" || bad "P3-03 oldcli: canonical->run empty"

# ── 9) 快照移除的运行任务仍被监督（task.v2 + supervisor_task_file 兜底）────
RID="mtask_0900"
[ -f "$TASKS_DIR/$RID/task.v2" ] && ok "P3-03 supervise: task.v2 stashed in run dir at exec" || bad "P3-03 supervise: task.v2 missing"
tf=$(registry_task_file "$RID" 2>/dev/null); [ -n "$tf" ] && rm -f "$tf"
echo "RUNNING" > "$TASKS_DIR/$RID/state.txt"
tf2=$(supervisor_task_file "$BASE" "$TASKS_DIR" "$RID")
[ -n "$tf2" ] && ok "P3-03 supervise: supervisor_task_file resolves removed task via task.v2 ($(basename "$tf2"))" || bad "P3-03 supervise: removed task unresolvable"
[ "$tf2" = "$TASKS_DIR/$RID/task.v2" ] && ok "P3-03 supervise: fallback = run-dir task.v2" || bad "P3-03 supervise: fallback not task.v2"

# ── 10) 单任务错误隔离：坏任务不中止整个 tick ─────────────────────────────
BADBASE="$T/badbase"; BADCFG="$T/badbase.cfg"
mkdir -p "$BADBASE"
printf '12:34 echo good-task\nbogus-trigger echo bad-task\n' > "$BADCFG"   # 第二行非法触发器
export TCFG_DIR="$BADBASE/task-config"
rm -rf "$TCFG_DIR"; mkdir -p "$TCFG_DIR"
rm -f "$TCFG_DIR/MANAGED"
TR_LOGGING=0 registry_init "$BADBASE" "$BADCFG" >/dev/null 2>&1
: > "$EXEC_LOG"
scheduler_tick "$BADBASE" "$BADCFG" "$TASKS_DIR" "1234"
rct=$?
[ "$rct" -eq 0 ] && ok "P3-03 isolate: tick returns 0 even with bad task present" || bad "P3-03 isolate: tick rc=$rct"
grep -q '|echo good-task|' "$EXEC_LOG" && ok "P3-03 isolate: valid task still executed despite bad neighbor" || bad "P3-03 isolate: valid task skipped (log=$(cat "$EXEC_LOG"))"
grep -q 'bad-task' "$EXEC_LOG" && bad "P3-03 isolate: bogus-trigger executed (forbidden)" || ok "P3-03 isolate: bogus-trigger rejected by TriggerProvider, tick continues"

# ── 11) 调度来源审计日志 ───────────────────────────────────────────────────
AUDIT="$BASE/scheduler/audit.log"
[ -f "$AUDIT" ] && grep -q 'op=reload' "$AUDIT" && grep -q 'op=exec' "$AUDIT" && ok "P3-03 audit: scheduler/audit.log records reload+exec" || bad "P3-03 audit: audit log missing ops"
grep -q 'op=tick' "$AUDIT" && ok "P3-03 audit: tick summary recorded (mode/source)" || bad "P3-03 audit: tick line missing"

# ── 12) POSIX：库（含 §20）dash -n（或 bash -n 兜底）──────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-03 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §20)" || bad "P3-03 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-03 POSIX: bash -n ok (dash unavailable)" || bad "P3-03 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "scheduler-prod tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
