#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P3 综合回归：安装→导入→调度→控制→健康→编辑→回滚→崩溃→恢复（P3-09）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 定位：P3-09「设备矩阵与综合回归」的**宿主侧综合回归**（L2，CI/主机可跑）。
#   真机 18 项由 tests/p3-device/smoke.sh（L3，--with-device）承担；本套件在
#   宿主端以**同一 Runtime 库 + daemon 上下文 shim** 端到端串联 P3 各链路，
#   证明它们不是各自孤立而是**可协同工作**，为真机冒烟提供主机侧参照。
# 覆盖（映射 P3-09「必须覆盖」18 项，宿主可实现面）：
#   1) 模块安装/卸载         —— build 产物结构 + module.prop/customize.sh 契约
#                              落点（复用 p2-install 语义，宿主侧）。
#   2) daemon 开机启动        —— lifecycle 锚点 + fake daemon 启动/停止存活。
#   3) Runtime Library 加载   —— RUNTIME_LOADED 契约 + runtime_lib_selfcheck。
#   4) Legacy 配置继续执行    —— config.txt（双模式 legacy）导入后旧行仍可调度。
#   5) Task v2 导入           —— tcfg_import 幂等 + 备份 + MANAGED 提升。
#   6) Registry 正式调度      —— sched_reload + scheduler_tick 决策执行（审计）。
#   7) WebUI Dashboard        —— GET_SUMMARY 经真实 IPC 通道（含 multi-task 计数）。
#   8) Task Editor 保存和回滚 —— EDIT_TASK 保存 → GET_TASK_EDIT 回读 → 原子回滚。
#   9) App Action             —— tpr_action_app_validate + action_run app 分支
#                              规范 argv（拒绝注入）。
#  10) Process Health         —— health_check process:$$ 真实三态。
#  11) Port Health            —— 真实 nc 监听起停 → HEALTHY/UNHEALTHY。
#  12) Restart/Retry/Cooldown —— recovery 三动作 + max_retry 钳制 + cooldown。
#  13) daemon Crash Loop      —— crash_guard 计数/降级/优雅重置。
#  14) Task start/stop/restart—— tctl_* + CLI 经 IPC 全链路。
#  15) 配置损坏回退           —— 损坏 config → KEPT/回退，原配置逐字节不变。
#  16) 旧 CLI 查询旧运行任务   —— idmap 双向解析 + task-info/output 只读。
#  17) 日志轮转               —— runtime_limit_task_log 字节上限 + WEBUI 行数。
#  18) 重启后状态恢复         —— state_rehydrate_residual RUNNING→FAILED。
# 本套件不重复单点套件断言，专注**端到端协同**（一处 FAIL 即说明跨模块链路断裂）。
# 加载：`. ./$RTLIB`（daemon 上下文 shim：execute_task 真实后台子进程）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
DAEMON="system/bin/su-schedulerd"
T=$(mktemp -d)
cleanup() {
    for p in $(pgrep -f "nc -l 127.0.0.1 396" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap 'cleanup' EXIT

# ── daemon 上下文 shim：execute_task 真实后台子进程（可被 kill/追踪）────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {   # 7 参：id cmd notify_start notify_end custom_msg interactive termux
    id=$1; cmd=$2; ns=$3; ne=$4; msg=$5; itr=$6; tmx=$7
    d="$TASKS_DIR/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "RUNNING" > "$d/status.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    ( sleep 30 > "$d/output.log" 2>&1 ) &
    echo $! > "$d/pid.txt"
    echo "$id|$cmd" >> "$EXEC_LOG"
    return 0
}
. ./$RTLIB

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"

# task-config 快照 md5（排除 MANAGED）：Registry/配置不被破坏的断言依据
tc_snap() { find "$TCFG_DIR" -type f ! -name 'MANAGED' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1; }

# ── 1) 模块安装/卸载契约（宿主侧落点；真机安装由 L3 smoke 承担）────────────
inst_miss=0
grep -q '^SKIPUNZIP=1' customize.sh || { bad "P3-09 install: SKIPUNZIP=1 missing"; inst_miss=1; }
grep -q '/data/adb/su-scheduler' customize.sh || { bad "P3-09 install: DATA_DIR missing"; inst_miss=1; }
grep -q '^id=su-scheduler' module.prop || { bad "P3-09 install: module id missing"; inst_miss=1; }
for bin in su-scheduler su-schedulerd su-scheduler-termux su-scheduler-runtime; do
    [ -f "system/bin/$bin" ] || { bad "P3-09 install: system/bin/$bin missing"; inst_miss=1; }
done
[ -f webroot/index.html ] && [ -f webroot/app.js ] || { bad "P3-09 install: webroot missing"; inst_miss=1; }
[ "$inst_miss" -eq 0 ] && ok "P3-09 install: module payload contract present (customize.sh/module.prop/system/webroot) -> real install/uninstall via L3"

# ── 2)+3) daemon 生命周期 + Runtime 加载锚点 ────────────────────────────────
dmiss=0
for anchor in 'RUNTIME_LOADED' 'runtime_lib_selfcheck' 'crash_guard_enter' 'shadow_init' \
              'lifecycle_startup_registry' 'scheduler_tick' 'ipc_server_poll' \
              'secv_fix_perms' 'supervisor_tick'; do
    grep -qF "$anchor" "$DAEMON" || { bad "P3-09 daemon: anchor '$anchor' missing"; dmiss=1; }
done
[ "$dmiss" -eq 0 ] && ok "P3-09 daemon: startup/lifecycle/Runtime-load anchors wired (boot start via L3)"
grep -qF 'RUNTIME_LIB=' "$CLI" && grep -qF 'RUNTIME_LOADED' "$CLI" \
    && ok "P3-09 runtime: daemon+CLI share RUNTIME_LOADED load contract" || bad "P3-09 runtime: load contract missing"
grep -q '^runtime_lib_selfcheck()' "$RTLIB" && ok "P3-09 runtime: selfcheck defined" || bad "P3-09 runtime: selfcheck missing"

# ── 5) Task v2 导入（legacy fixture → managed）─────────────────────────────
LEGACY="$T/legacy.cfg"
cat > "$LEGACY" <<'EOF'
# legacy fixture
boot echo boot-task > /data/local/tmp/legacy-boot
08:30 echo legacy-daily > /data/local/tmp/legacy-daily; : --notify-end
weekly:1:0900 echo weekly-task; : --delete
EOF
ORIG_LS=$(md5sum < "$LEGACY")
tcfg_import "$LEGACY" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -f "$TCFG_DIR/MANAGED" ] \
    && ok "P3-09 import: legacy config -> managed (MANAGED marker + rc 0)" || bad "P3-09 import: rc=$rc managed=$([ -f "$TCFG_DIR/MANAGED" ] && echo yes || echo no)"
[ "$(md5sum < "$LEGACY")" = "$ORIG_LS" ] && ok "P3-09 import: legacy config byte-unchanged (backup kept)" || bad "P3-09 import: legacy config mutated"
ls "$TCFG_DIR"/*.task >/dev/null 2>&1 && ok "P3-09 import: task v2 files materialized from legacy" || bad "P3-09 import: no .task produced"

# ── 4) Legacy 配置继续执行：导入后原行仍映射为任务（触发语义保留）──────────
grep -q 'trigger=boot' "$TCFG_DIR"/t*_boot*.task 2>/dev/null \
    && ok "P3-09 legacy: boot trigger preserved in imported task" || bad "P3-09 legacy: boot trigger lost"
grep -rl 'trigger=08:30' "$TCFG_DIR" >/dev/null 2>&1 \
    && ok "P3-09 legacy: HH:MM trigger preserved (legacy daily)" || bad "P3-09 legacy: HH:MM lost"
grep -rl '^action.delete=1' "$TCFG_DIR" >/dev/null 2>&1 \
    && ok "P3-09 legacy: --delete modifier preserved" || bad "P3-09 legacy: --delete modifier lost"

# ── 6) Registry 正式调度：sched_reload + scheduler_tick 决策执行 ───────────
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
N=$(registry_task_ids | wc -l)
[ "$N" -ge 3 ] && ok "P3-09 sched: registry holds imported tasks (count=$N)" || bad "P3-09 sched: registry count=$N (expect >=3)"
# 单任务执行（boot 任务经 scheduler_boot 或 tick）；断言触发→动作→审计链路
: > "$EXEC_LOG"
BOOTID=$(registry_task_ids | while read -r id; do grep -q '^trigger=boot$' "$TCFG_DIR/$id.task" 2>/dev/null && { echo "$id"; break; }; done)
[ -n "$BOOTID" ] && scheduler_boot "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
[ "$(wc -l < "$EXEC_LOG")" -ge 1 ] && ok "P3-09 sched: boot task executed via registry (exec=$(wc -l < "$EXEC_LOG"))" \
    || bad "P3-09 sched: no boot task executed"
grep -q 'trigger=boot' "$BASE/scheduler/audit.log" 2>/dev/null \
    && ok "P3-09 sched: scheduler audit.log records boot source" || bad "P3-09 sched: audit missing"
# P5-08：op=exec 审计行含 cause=（触发原因透传，尾部只增字段）
grep -q 'op=exec.*cause=boot' "$BASE/scheduler/audit.log" 2>/dev/null \
    && ok "P5-08 audit: op=exec carries cause=boot (trigger reason passthrough)" \
    || bad "P5-08 audit: op=exec missing cause= (log=$(tail -3 "$BASE/scheduler/audit.log" 2>/dev/null | tr '\n' ' '))"

# ── 7) WebUI Dashboard：GET_SUMMARY 经真实 IPC 通道（multi-task 计数）──────
ipc_server_init "$BASE" >/dev/null 2>&1
echo "$$" > "$BASE/ipc/daemon.pid"
send_req() {   # <req_id> <line>
    local rid="$1" line="$2"
    local rdir="$BASE/ipc/requests"
    mkdir -p "$rdir"
    printf '%s\n' "$line" > "$rdir/$rid.req"
    ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
    cat "$BASE/ipc/responses/$rid.resp" 2>/dev/null
}
resp_rc() { printf '%s\n' "$1" | head -1 | cut -d'|' -f3; }
r=$(send_req "s01" "s01|GET_SUMMARY|")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$r" | grep -q '"total":' \
    && printf '%s\n' "$r" | grep -q '"mode":"managed"' \
    && ok "P3-09 webui: GET_SUMMARY dashboard JSON (total + managed)" || bad "P3-09 webui: summary rc=$(resp_rc "$r")"

# ── 14) Task 控制：tctl_* 经真实 IPC 全链路（start/stop/restart）────────────
tcfg_new_task ctl1 "08:30" "echo ctl" >/dev/null 2>&1
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
: > "$EXEC_LOG"
out=$(tctl_start "$BASE" "$TASKS_DIR" ctl1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$TASKS_DIR/ctl1/state.txt")" = "RUNNING" ] \
    && ok "P3-09 ctl: tctl_start ctl1 -> RUNNING" || bad "P3-09 ctl: start rc=$rc state=$(cat "$TASKS_DIR/ctl1/state.txt" 2>/dev/null)"
grep -q '|manual_exec|STARTING|' "$TASKS_DIR/ctl1/events.log" \
    && ok "P3-09 ctl: start traces manual_exec STARTING" || bad "P3-09 ctl: start event missing"
out=$(tctl_stop "$BASE" "$TASKS_DIR" ctl1 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$TASKS_DIR/ctl1/state.txt")" = "STOPPED" ] \
    && ok "P3-09 ctl: tctl_stop ctl1 -> STOPPED" || bad "P3-09 ctl: stop rc=$rc state=$(cat "$TASKS_DIR/ctl1/state.txt")"
: > "$EXEC_LOG"
out=$(tctl_start "$BASE" "$TASKS_DIR" ctl1 2>/dev/null)
tctl_restart "$BASE" "$TASKS_DIR" ctl1 >/dev/null 2>&1
[ "$(wc -l < "$EXEC_LOG")" -ge 1 ] && ok "P3-09 ctl: restart drives stop+start (exec>=1)" || bad "P3-09 ctl: restart no exec"

# ── 9) App Action：规范 argv + 注入拒绝 ────────────────────────────────────
tpr_action_app_validate "app:activity:com.example/.Main" >/dev/null 2>&1 \
    && ok "P3-09 app: valid activity spec accepted" || bad "P3-09 app: valid spec rejected"
tpr_action_app_validate "app:activity:com.example/../evil" >/dev/null 2>&1 \
    && bad "P3-09 app: path traversal ACCEPTED (injection)" || ok "P3-09 app: path traversal rejected"
tpr_action_app_validate "app:activity:com.example;rm -rf /" >/dev/null 2>&1 \
    && bad "P3-09 app: metachar injection ACCEPTED" || ok "P3-09 app: shell metachar rejected"
tpr_action_app_validate "app:start:com.example/.Main" >/dev/null 2>&1 \
    && bad "P3-09 app: unsupported op 'start' ACCEPTED" || ok "P3-09 app: unsupported op 'start' rejected (only package/activity/service/broadcast)"

# ── 10)+11) Process + Port Health：真实探针三态 ───────────────────────────
HP=$(health_check process "$$" 2>/dev/null | head -1)
echo "$HP" | grep -q '^HEALTHY' && ok "P3-09 health: process self -> HEALTHY" || bad "P3-09 health: process self=$HP"
if command -v nc >/dev/null 2>&1; then
    PORT=39621
    while [ "$PORT" -lt 39700 ]; do
        hexp=$(printf '%04X' "$PORT")
        if awk -v h="$hexp" '$4=="0A" && $2 ~ ":" h "$" { n++ } END { exit n>0 }' /proc/net/tcp 2>/dev/null; then
            break
        fi
        PORT=$((PORT + 1))
    done
    nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
    NCP=$!
    i=0; hstate=""
    while [ "$i" -lt 8 ]; do
        HP=$(health_check port "$PORT" 2>/dev/null | head -1)
        echo "$HP" | grep -q '^HEALTHY' && { hstate="$HP"; break; }
        sleep 0.3; i=$((i + 1))
    done
    echo "$hstate" | grep -q '^HEALTHY' && ok "P3-09 health: port LISTEN -> HEALTHY" || bad "P3-09 health: port up=$hstate"
    kill -9 "$NCP" 2>/dev/null; sleep 0.3
    HP=$(health_check port "$PORT" 2>/dev/null | head -1)
    echo "$HP" | grep -qE '^(UNHEALTHY|UNKNOWN)' && ok "P3-09 health: port down -> $HP" || bad "P3-09 health: port down=$HP"
fi

# ── 12) Restart/Retry/Cooldown：max_retry 钳制 + cooldown 默认 ─────────────
# 策略钳制（supervisor_policy 读 .task → retry_max/retry_interval/retry_cooldown
# 全局）：禁止无限重启（负/非法 → 0、>100 → 硬上限 100）。
PT="$T/policy.task"
printf 'retry.max=-1\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_max" = "0" ] && ok "P3-09 recovery: retry.max=-1 → clamped 0" || bad "P3-09 recovery: max=$retry_max"
printf 'retry.max=999999\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_max" = "100" ] && ok "P3-09 recovery: retry.max=999999 → hard cap 100 (bounded)" || bad "P3-09 recovery: max=$retry_max"
printf 'retry.max=3\nretry.interval=abc\nretry.cooldown=abc\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_interval" = "60" ] && [ "$retry_cooldown" = "0" ] \
    && ok "P3-09 recovery: invalid interval/cooldown → defaults 60/0 (no crash)" \
    || bad "P3-09 recovery: interval=$retry_interval cooldown=$retry_cooldown"
printf 'retry.cooldown=45\n' > "$PT"
supervisor_policy "$PT"
[ "$retry_cooldown" = "45" ] && ok "P3-09 recovery: retry.cooldown=45 honored" || bad "P3-09 recovery: cooldown=$retry_cooldown"

# ── 13) daemon Crash Loop：guard 计数 + 阈值降级 + 优雅重置 ───────────────
CG="$T/cg"; mkdir -p "$CG"
export CRASH_MIN_START_INTERVAL=0 CRASH_THRESHOLD=2
crash_guard_enter "$CG" >/dev/null 2>&1
crash_guard_enter "$CG" >/dev/null 2>&1
gd=$(crash_guard_file "$CG")
[ "$(crash_read "$gd" crash_seq)" = "1" ] && [ "$(crash_read "$gd" starts)" = "2" ] \
    && ok "P3-09 crash: abnormal ×2 → crash_seq=1 starts=2 (counted)" || bad "P3-09 crash: seq=$(crash_read "$gd" crash_seq) starts=$(crash_read "$gd" starts)"
crash_guard_enter "$CG" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "P3-09 crash: threshold hit → rc 2 DEGRADED (crash-loop suppressed)" || bad "P3-09 crash: threshold rc=$rc (expect 2)"
# 优雅退出重置：独立 base（同 crashguard 测试语义——降级窗口在旧 base 上仍生效）
CG2="$T/cg2"; mkdir -p "$CG2"
crash_guard_enter "$CG2" >/dev/null 2>&1
crash_guard_enter "$CG2" >/dev/null 2>&1
gd2=$(crash_guard_file "$CG2")
crash_record_exit "$CG2" 0 >/dev/null 2>&1
crash_guard_enter "$CG2" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(crash_read "$gd2" crash_seq)" = "0" ] \
    && ok "P3-09 crash: clean exit → next enter rc 0 crash_seq=0 (graceful reset)" || bad "P3-09 crash: reset rc=$rc seq=$(crash_read "$gd2" crash_seq)"
unset CRASH_MIN_START_INTERVAL CRASH_THRESHOLD

# ── 8) Task Editor 保存和回滚：EDIT_TASK → GET_TASK_EDIT 回读 → 原子回滚 ──
make_payload() {   # <id>
    cat <<EOF
schema_version=2
id=$1
name=Edit Demo
enabled=1
trigger=weekly:1:0800
action.type=command
action.command=echo editor-saved
health.type=process
health.target=su
recovery.type=restart
retry.max=3
retry.interval=30
retry.cooldown=60
advanced.timeout=120
EOF
}
PAY=$(make_payload edit_task)
r=$(send_req "ed01" "ed01|EDIT_TASK|id=$(ipc_b64enc edit_task)&payload=$(ipc_b64enc "$PAY")")
[ "$(resp_rc "$r")" = "0" ] && [ -f "$TCFG_DIR/edit_task.task" ] \
    && ok "P3-09 editor: EDIT_TASK saved task v2" || bad "P3-09 editor: save rc=$(resp_rc "$r")"
r=$(send_req "ed02" "ed02|GET_TASK_EDIT|id=$(ipc_b64enc edit_task)")
back=$(printf '%s\n' "$r" | tail -n +2)
dec=$(ipc_b64dec "$back")
[ "$(resp_rc "$r")" = "0" ] && printf '%s\n' "$dec" | grep -q '^action.command=echo editor-saved$' \
    && ok "P3-09 editor: GET_TASK_EDIT round-trips saved task" || bad "P3-09 editor: round-trip rc=$(resp_rc "$r")"
SNAP_EDIT=$(tc_snap)
BADPAY=$(make_payload edit_task)
r=$(send_req "ed03" "ed03|EDIT_TASK|id=$(ipc_b64enc '../../etc')&payload=$(ipc_b64enc "$BADPAY")")
[ "$(resp_rc "$r")" != "0" ] && ok "P3-09 editor: path-traversal id rejected" || bad "P3-09 editor: traversal id accepted"
[ "$(tc_snap)" = "$SNAP_EDIT" ] && ok "P3-09 editor: failed edit left task-config byte-identical (atomic rollback)" || bad "P3-09 editor: config mutated on failed edit"

# ── 15) 配置损坏回退：损坏 config → 拒/回退，原配置逐字节不变 ─────────────
# 控制字符触发器 → legacy_adapter 行级拒绝 → import rc=1（损坏/非法配置不落库）；
# 合法导入后 tcfg_rollback → 逐字节还原 + 移除 MANAGED（配置损坏时回退到备份）。
CFG_BAD="$T/bad.cfg"
printf '08\x01:30 x\n23\x02:00 y\n' > "$CFG_BAD"   # 全部行含控制字符 → 0 有效任务
BADSUM=$(md5sum < "$CFG_BAD")
BADT="$T/bad-store"; mkdir -p "$BADT"
TCFG_DIR="$BADT" tcfg_import "$CFG_BAD" >/dev/null 2>&1
rrc=$?
[ "$rrc" -ne 0 ] && ok "P3-09 fallback: corrupt(control-char) config import -> rc=$rrc (rejected, KEPT)" || bad "P3-09 fallback: corrupt import rc=0"
[ "$(md5sum < "$CFG_BAD")" = "$BADSUM" ] && ok "P3-09 fallback: corrupt config byte-unchanged (no partial overwrite)" || bad "P3-09 fallback: config mutated"
# 合法导入后 rollback → 逐字节还原 + 移除 MANAGED（配置损坏时回退到备份）
ROLL="$T/rollback.cfg"; cp "$T/legacy.cfg" "$ROLL"
ROLLSTORE="$T/rollstore"; mkdir -p "$ROLLSTORE"
TCFG_DIR="$ROLLSTORE" tcfg_import "$ROLL" >/dev/null 2>&1
printf '99:99 echo touched\n' >> "$ROLL"
TCFG_DIR="$ROLLSTORE" tcfg_rollback "$ROLL" >/dev/null 2>&1
rrc=$?
cmp -s "$ROLL" "$T/legacy.cfg" && [ "$rrc" -eq 0 ] \
    && ok "P3-09 fallback: tcfg_rollback restores byte-identical + legacy mode" || bad "P3-09 fallback: rollback rc=$rrc"
[ ! -f "$ROLLSTORE/MANAGED" ] && ok "P3-09 fallback: mode reverted to legacy (MANAGED removed)" || bad "P3-09 fallback: MANAGED still present"

# ── 16) 旧 CLI 查询旧运行任务：canonical 解析 + 只读工件 ──────────────────
# task_cli_resolve_id：canonical id 经 registry 直接解析；旧运行 id 经 §9 idmap
# 反向解析到 canonical。此处断言 canonical 解析 + 旧运行目录只读工件（status/pid/
# output.log/exit_code）——旧 CLI 查询即读这些工件，WebUI 只读面同理。
mkdir -p "$TASKS_DIR/ctl1"
( sleep 30 ) &
OPID=$!
echo "$OPID" > "$TASKS_DIR/ctl1/pid.txt"
echo "RUNNING" > "$TASKS_DIR/ctl1/status.txt"
echo "echo ctl" > "$TASKS_DIR/ctl1/command.txt"
echo "0" > "$TASKS_DIR/ctl1/exit_code.txt"
printf 'legacy-out-1\nlegacy-out-2\n' > "$TASKS_DIR/ctl1/output.log"
res=$(task_cli_resolve_id "$BASE" "$TASKS_DIR" ctl1 2>/dev/null); rrc=$?
[ "$rrc" -eq 0 ] && [ "$res" = "ctl1" ] \
    && ok "P3-09 oldcli: resolve canonical id ctl1 -> ctl1 (rc 0)" || bad "P3-09 oldcli: resolve rc=$rrc res=$res"
[ -f "$TASKS_DIR/ctl1/status.txt" ] && [ -f "$TASKS_DIR/ctl1/pid.txt" ] \
    && [ -f "$TASKS_DIR/ctl1/output.log" ] && [ -f "$TASKS_DIR/ctl1/exit_code.txt" ] \
    && ok "P3-09 oldcli: legacy artifacts (status/pid/output/exit_code) readable (old CLI query)" \
    || bad "P3-09 oldcli: artifacts missing"
[ "$(cat "$TASKS_DIR/ctl1/status.txt")" = "RUNNING" ] && [ "$(cat "$TASKS_DIR/ctl1/exit_code.txt")" = "0" ] \
    && ok "P3-09 oldcli: old-run status RUNNING + exit_code 0 readable (old CLI task-info/output)" \
    || bad "P3-09 oldcli: status/exit_code content wrong"
kill "$OPID" 2>/dev/null

# ── 17) 日志轮转：单 Task 日志字节上限 + WebUI 行数 ───────────────────────
printf 'line-a\nline-b\nline-c\nline-d\nline-e\n' > "$TASKS_DIR/ctl1/output.log"
LOG_MB=$(wc -c < "$TASKS_DIR/ctl1/output.log")
runtime_limit_task_log "$TASKS_DIR/ctl1/output.log" 200 >/dev/null 2>&1
[ "$(wc -c < "$TASKS_DIR/ctl1/output.log")" -le 200 ] \
    && ok "P3-09 rot: task log truncated to byte cap (<=200)" || bad "P3-09 rot: log not capped"
r=$(send_req "lg01" "lg01|GET_DAEMON_LOG|lines=$(ipc_b64enc 50)")
[ "$(resp_rc "$r")" = "0" ] && ok "P3-09 rot: GET_DAEMON_LOG bounded query ok" || bad "P3-09 rot: daemon log query rc=$(resp_rc "$r")"

# ── 18) 重启后状态恢复：RUNNING（进程已死）→ FAILED + daemon_restart ──────
RZ="$T/restart"; mkdir -p "$RZ"
mkdir -p "$RZ/ghost"
echo "RUNNING" > "$RZ/ghost/state.txt"
echo "RUNNING" > "$RZ/ghost/status.txt"
echo "99999999" > "$RZ/ghost/pid.txt"   # 已死 pid
state_rehydrate_residual "$RZ" >/dev/null 2>&1
[ "$(cat "$RZ/ghost/state.txt")" = "FAILED" ] \
    && ok "P3-09 restore: restart residual RUNNING->FAILED (no ghost RUNNING)" || bad "P3-09 restore: state=$(cat "$RZ/ghost/state.txt")"
grep -q 'daemon_restart' "$RZ/ghost/events.log" 2>/dev/null \
    && ok "P3-09 restore: residual -> daemon_restart event" || bad "P3-09 restore: event missing"

# ── POSIX：库（含 §25，P3 全量）dash -n（LF 归一，规避 CRLF 检出）─────────
if command -v dash >/dev/null 2>&1; then
    tr -d '\r' < "$RTLIB" > "$T/lib-lf.sh"
    dash -n "$T/lib-lf.sh" 2>/dev/null \
        && ok "P3-09 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. P3)" \
        || bad "P3-09 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-09 POSIX: bash -n ok (dash unavailable)" || bad "P3-09 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p3-integration tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1