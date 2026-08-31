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