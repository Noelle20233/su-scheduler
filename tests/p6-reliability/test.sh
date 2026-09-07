#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P6-01 P5 基线复核与问题复现（tests/p6-reliability）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 本套件为 **P6-01 复现套件**：O-2/O-3/O-4 三个断言在**当前生产代码**上
# 应当 [FAIL]（证明缺陷存在、可复现），其余兼容性/性能/dash 断言 [PASS]。
# 套件不修改任何生产文件，只读 source Runtime 库（`. ./$RTLIB`，TCFG_DIR /
# TR_BASE 均以临时目录隔离）。
#
# 覆盖：
#   §O-2  主循环跳拍复现：scheduler_tick 以当前 HHMM 为 now，无「上次 tick」
#         追踪。构造 trigger=08:30 的精确分钟任务：tick(0829) 未执行 →
#         tick(0831) 跳过 0830 窗口。正确实现应补执行；当前实现不补 → [FAIL]。
#   §O-3  Cron trigger 含空格时 ID 派生复现：tcfg_new_id 只 sed 去冒号不去
#         空格 → `cron:0 8 * * *` 派生 ID 含空格/`*`，非合法路径字符集。
#         断言返回 ID 仅含 [A-Za-z0-9._-] → 当前实现 [FAIL]。
#   §O-4  IPC 错误详情丢失复现：VALIDATE_TASK 对字段级非法 payload 返回笼统
#         configuration_invalid "task invalid"，不透传具体字段与原因。
#         断言错误信息区分「缺 command / command 多行 / trigger 非法」→
#         当前实现对 trigger 非法仅回 "task invalid" → [FAIL]。
#   §compat  P6 兼容性基线：tcfg_validate_task 对合法 task、parse_modifiers /
#          extract_command 对 legacy 行仍按预期（标注来源 legacy/golden）。
#   §perf   P6 性能记录性基线：scheduler_tick 空 registry + 50 任务 registry
#          各跑 1 次，宽松上界（不设紧防误报）。
#   §posix  dash -n system/bin/su-scheduler-runtime。
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

# ═══════════════════════════════════════════════════════════════════════════
# 公共隔离上下文：TCFG_DIR + scheduler base（TR_BASE 由 sched_reload→attach 建立）
# ═══════════════════════════════════════════════════════════════════════════
export TCFG_DIR="$T/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"

SCHED_BASE="$T/base"; SCHED_CFG="$T/config.txt"; SCHED_TASKS="$T/tasks"
SCHED_SF="$SCHED_BASE/schedule_state.txt"
mkdir -p "$SCHED_TASKS" "$SCHED_BASE"
SCHED_EXEC_LOG="$T/exec.log"; : > "$SCHED_EXEC_LOG"
TASKS_DIR="$SCHED_TASKS"
execute_task() {   # 7 参 shim：id cmd ns ne msg itr tmx（镜像 daemon 工件）
    id=$1; cmd=$2
    d="$SCHED_TASKS/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    echo "$id|$cmd" >> "$SCHED_EXEC_LOG"
    return 0
}
. ./$RTLIB

# 创建 managed 任务 helper：<id> <trigger> <cmd>
mk_task() {
    tcfg_new_task "$1" "$2" "$3" >/dev/null 2>&1
}

# ── §O-2 主循环跳拍（精确 HHMM 任务被跳过，不补执行）──────────────────────
# 复现思路（docs/P6-01.md O-2）：
#   scheduler_tick 每次以当前 HHMM 作为 now，只执行 now 命中的精确时间任务。
#   无「上次 tick」追踪。若单次循环跨越 0830→0831（>60s），0830 窗口的精确
#   任务被跳过。正确实现应在 0831 tick 补执行一次（catch-up）；当前实现不补。
O2_T="$T/o2"
mkdir -p "$O2_T/tasks" "$O2_T/base"
: > "$O2_T/exec.log"
O2_TASKS_DIR="$O2_T/tasks"
O2_EXEC="$O2_T/exec.log"
o2_exec() {   # 独立 shim，日志写 O2_EXEC
    id=$1; cmd=$2
    d="$O2_TASKS_DIR/$id"; mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    echo "$id|$cmd" >> "$O2_EXEC"
    return 0
}
(
    export TCFG_DIR="$O2_T/tsks"
    mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
    TASKS_DIR="$O2_TASKS_DIR"
    # 用独立的 execute_task：子 shell 内重定义，隔离于主 shim
    execute_task() { o2_exec "$@"; }
    . "$PWD/$RTLIB"
    tcfg_new_task o2t 0830 "echo o2-run" >/dev/null 2>&1
    : > "$O2_EXEC"
    # tick 1：0829（0830 前一刻）→ 不应执行
    SCHED_CYCLE_NOW=202609060829 scheduler_tick "$O2_T/base" "$O2_T/config.txt" "$O2_T/tasks" "0829" >/dev/null 2>&1
    c1=$(grep -c '^o2t|' "$O2_EXEC" 2>/dev/null || true)
    # tick 2：0831（跨过 0830 窗口）→ 正确实现应补执行（catch-up）
    SCHED_CYCLE_NOW=202609060831 scheduler_tick "$O2_T/base" "$O2_T/config.txt" "$O2_T/tasks" "0831" >/dev/null 2>&1
    c2=$(grep -c '^o2t|' "$O2_EXEC" 2>/dev/null || true)
    # 断言：跨窗口后任务被补执行。当前实现 c2=0 → FAIL（证明跳拍缺陷）
    if [ "$c1" -eq 0 ] && [ "$c2" -eq 1 ]; then
        echo "O2_CATCHUP=OK c1=$c1 c2=$c2"
    else
        echo "O2_CATCHUP=SKIP c1=$c1 c2=$c2"
    fi
) > "$O2_T/out.txt" 2>&1
O2RES=$(grep -o 'O2_CATCHUP=[A-Z]*' "$O2_T/out.txt" | head -1)
# 断言「应补执行」：当前代码跳拍（SKIP）→ 该断言 [FAIL]（复现 O-2）。
if [ "$O2RES" = "O2_CATCHUP=OK" ]; then
    ok "P6-01 O-2: 跨分钟跳拍后精确任务被补执行（此 PASS 说明缺陷未被复现）"
else
    bad "P6-01 O-2: 跨分钟跳拍后精确任务未被补执行（复现 O-2，当前代码跳拍）"
fi

# ── §O-3 Cron trigger 含空格时 ID 派生非法路径字符 ─────────────────────────
# 复现思路（docs/P6-01.md O-3）：tcfg_new_id 只 `sed 's/://g'` 不去空格 →
# `cron:0 8 * * *` 派生 `task_cron0 8 * * *_1`（含空格/`*`），作文件路径非法。
# 断言返回 ID 仅含 [A-Za-z0-9._-]（无空格/`*`/`/`），可复现（同输入同 ID）。
O3_T="$T/o3"
mkdir -p "$O3_T/tsks"
(
    export TCFG_DIR="$O3_T/tsks"
    . "$PWD/$RTLIB"
    id1=$(tcfg_new_id "cron:0 8 * * *")
    id2=$(tcfg_new_id "cron:0 8 * * *")
    # 非法路径字符检查：空格 / `*` / `/`
    case "$id1" in
        *[!A-Za-z0-9._-]*) badchars=yes ;;
        *) badchars=no ;;
    esac
    if [ "$badchars" = "no" ] && [ "$id1" = "$id2" ]; then
        echo "O3_ID_OK id1=$id1 id2=$id2"
    else
        echo "O3_ID_BAD id1=$id1 id2=$id2 badchars=$badchars"
    fi
) > "$O3_T/out.txt" 2>&1
O3RES=$(grep -o 'O3_ID_[A-Z]*' "$O3_T/out.txt" | head -1)
# 断言「ID 仅含合法路径字符」：当前实现派生含空格/`*`（BAD）→ [FAIL]（复现 O-3）。
if [ "$O3RES" = "O3_ID_OK" ]; then
    ok "P6-01 O-3: tcfg_new_id cron ID 仅含合法路径字符（此 PASS 说明缺陷未被复现）"
else
    bad "P6-01 O-3: tcfg_new_id cron ID 含非法路径字符（复现 O-3，当前代码行为）"
fi
O3LINE=$(grep -o 'id1=[^ ]*' "$O3_T/out.txt" | head -1)
echo "    O-3 派生 ID：$O3LINE（含空格或星号即非法路径字符）"

# ── §O-4 IPC VALIDATE_TASK 错误详情丢失 ────────────────────────────────────
# 复现思路（docs/P6-01.md O-4）：VALIDATE_TASK 对字段级非法 payload（P3-06
# payload 通道，经 tcfg_editor_validate_payload 全字段校验）返回 configuration_
# invalid。trigger 非法（oneshot:2460）仅回笼统 "task invalid"，不透传具体字段
# 与校验原因（缺哪个字段/哪个字段非法）。断言：trigger-非法错误信息应能区分
# 字段/原因（≠ "task invalid" 且与「缺 command」不同）→ 当前实现 [FAIL]。
O4_T="$T/o4"; mkdir -p "$O4_T/base"
(
    export TCFG_DIR="$O4_T/tsks"; mkdir -p "$TCFG_DIR"
    . "$PWD/$RTLIB"
    ipc_server_init "$O4_T/base" >/dev/null 2>&1
    # ① 缺 command（trigger+command 通道）→ 已有较具体的 "trigger+command required"
    ipc_op_validate "$O4_T/base" "v_nocmd" "trigger=$(ipc_b64enc '09:00')"
    err1=$(cat "$O4_T/base/ipc/responses/v_nocmd.resp" 2>/dev/null | head -1 | cut -d'|' -f4)
    # ② trigger 非法（payload 通道）→ 经 tcfg_editor_validate_payload 失败 → 期望能
    #   识别「trigger 字段 / oneshot:2460 非法」；当前仅回笼统 "task invalid"
    BAD_PAYLOAD=$(printf 'schema_version=2\nid=validate_1\ntrigger=oneshot:2460\naction.type=command\naction.command=echo x\n')
    ipc_op_validate "$O4_T/base" "v_badtrig" "payload=$(ipc_b64enc "$BAD_PAYLOAD")"
    r2=$(cat "$O4_T/base/ipc/responses/v_badtrig.resp" 2>/dev/null | head -1)
    err2=$(printf '%s' "$r2" | cut -d'|' -f4); rc2=$(printf '%s' "$r2" | cut -d'|' -f3)
    # 断言：trigger-非法错误原因应区分于缺 command，且不是笼统 "task invalid"
    if [ "$rc2" = "4" ] && [ "$err2" != "task invalid" ] && [ "$err2" != "$err1" ]; then
        echo "O4_DETAIL_OK err1=$err1 err2=$err2 rc2=$rc2"
    else
        echo "O4_DETAIL_BAD err1=$err1 err2=$err2 rc2=$rc2"
    fi
) > "$O4_T/out.txt" 2>&1
O4RES=$(grep -o 'O4_DETAIL_[A-Z]*' "$O4_T/out.txt" | head -1)
O4LINE=$(grep -o 'err2=[^ ]*' "$O4_T/out.txt" | head -1)
# 断言「错误原因能区分字段」：当前 trigger-非法仅回笼统 "task invalid"（BAD）
# → [FAIL]（复现 O-4）。
if [ "$O4RES" = "O4_DETAIL_OK" ]; then
    ok "P6-01 O-4: VALIDATE_TASK 错误原因能区分字段（此 PASS 说明缺陷未被复现）"
else
    bad "P6-01 O-4: VALIDATE_TASK 错误原因笼统（复现 O-4，当前代码行为）"
fi
echo "    O-4 trigger-非法错误信息：$O4LINE"

# ── §compat P6 兼容性基线（标注来源 legacy/golden）────────────────────────
# tcfg_validate_task 对合法 managed task 通过（来源：p4-dependency / p5-trigger §persist）
tcfg_new_task p6c1 08:30 "echo compat-ok" >/dev/null 2>&1
tcfg_validate_task "$(tcfg_task_file p6c1)" \
    && ok "P6-01 compat: tcfg_validate_task accepts valid managed task (src: p4/p5 §persist)" \
    || bad "P6-01 compat: tcfg_validate_task rejected valid task"
[ "$(tcfg_get "$(tcfg_task_file p6c1)" trigger)" = "08:30" ] \
    && ok "P6-01 compat: trigger line persisted verbatim (08:30)" \
    || bad "P6-01 compat: trigger field lost"

# parse_modifiers / extract_command（legacy 行解析，来源：legacy/golden + T1）
# 两函数位于 daemon（su-schedulerd），按 legacy/golden 的 derive 手法切出再 source。
LEGACY_D="$T/legacyfns"; mkdir -p "$LEGACY_D"
sed -n '/^parse_modifiers()/,/^}/p' "$DAEMON" > "$LEGACY_D/fns.sh"
sed -n '/^extract_command()/,/^}/p' "$DAEMON" >> "$LEGACY_D/fns.sh"
if grep -q '^parse_modifiers()' "$LEGACY_D/fns.sh" && grep -q '^extract_command()' "$LEGACY_D/fns.sh"; then
    # shellcheck disable=SC1090
    . "$LEGACY_D/fns.sh"
    extract_command "08:30 echo hi; : --notify-start --msg=\"hello world\"" >/dev/null 2>&1
    c=$(extract_command "08:30 echo hi; : --notify-start --msg=\"hello world\"")
    [ "$c" = "echo hi" ] \
        && ok "P6-01 compat: extract_command strips modifiers (src: legacy/golden)" \
        || bad "P6-01 compat: extract_command got '$c'"
    parse_modifiers "08:30 echo hi; : --run-once-now --delete --termux" >/dev/null 2>&1
    [ "$run_once_now" = "1" ] && [ "$delete_after" = "1" ] && [ "$use_termux" = "1" ] \
        && ok "P6-01 compat: parse_modifiers sets ron/delete/termux (src: legacy/golden)" \
        || bad "P6-01 compat: parse_modifiers flags ron=$run_once_now del=$delete_after tmx=$use_termux"
else
    bad "P6-01 compat: failed to extract parse_modifiers/extract_command from daemon"
fi

# ── §perf P6 性能记录性基线（宽松上界，防误报）─────────────────────────────
# 测量 scheduler_tick 的**调度决策**开销（非执行开销）：全部任务 trigger=08:30，
# 在 09:00（永不命中）tick → 零执行，纯迭代 trigger_decide。首 tick 预热建快照
# （未计时），再计时一次（快照未变 → sched_reload 指纹短路，纯决策循环）。
PERF_BASE="$T/perf"; PERF_CFG="$T/perf-config.txt"; PERF_TASKS_DIR="$T/perf-tasks"
mkdir -p "$PERF_BASE" "$PERF_TASKS_DIR"
(
    export TCFG_DIR="$T/perf-tsks"; mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
    . "$PWD/$RTLIB"
    TASKS_DIR="$PERF_TASKS_DIR"
    # 空 registry：预热 + 计时
    SCHED_CYCLE_NOW=202609060900 scheduler_tick "$PERF_BASE" "$PERF_CFG" "$PERF_TASKS_DIR" "0900" >/dev/null 2>&1
    t0=$(date +%s%N)
    SCHED_CYCLE_NOW=202609060900 scheduler_tick "$PERF_BASE" "$PERF_CFG" "$PERF_TASKS_DIR" "0900" >/dev/null 2>&1
    t1=$(date +%s%N)
    # 50 任务（trigger=08:30，09:00 永不命中→零执行）
    i=1
    while [ "$i" -le 50 ]; do
        tcfg_new_task "p6p$i" 08:30 "echo task-$i" >/dev/null 2>&1
        i=$((i + 1))
    done
    # 预热：建快照（未计时）
    SCHED_CYCLE_NOW=202609060900 scheduler_tick "$PERF_BASE" "$PERF_CFG" "$PERF_TASKS_DIR" "0900" >/dev/null 2>&1
    t2=$(date +%s%N)
    SCHED_CYCLE_NOW=202609060900 scheduler_tick "$PERF_BASE" "$PERF_CFG" "$PERF_TASKS_DIR" "0900" >/dev/null 2>&1
    t3=$(date +%s%N)
    empty_ms=$(( (t1 - t0) / 1000000 ))
    full_ms=$(( (t3 - t2) / 1000000 ))
    echo "PERF empty_ms=$empty_ms full_ms=$full_ms"
) > "$T/perf/out.txt" 2>&1
PERFLINE=$(grep -o 'PERF empty_ms=[0-9]* full_ms=[0-9]*' "$T/perf/out.txt" | head -1)
EMPTY_MS=$(printf '%s' "$PERFLINE" | sed 's/.*empty_ms=\([0-9]*\).*/\1/')
FULL_MS=$(printf '%s' "$PERFLINE" | sed 's/.*full_ms=\([0-9]*\).*/\1/')
if [ -n "$EMPTY_MS" ] && [ "$EMPTY_MS" -le 2000 ] && [ -n "$FULL_MS" ] && [ "$FULL_MS" -le 2000 ]; then
    ok "P6-01 perf: scheduler_tick empty=${EMPTY_MS}ms / 50-task=${FULL_MS}ms (<=2000ms loose bound)"
else
    bad "P6-01 perf: scheduler_tick $PERFLINE (empty/full over loose bound)"
fi

# ── §posix dash -n ────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P6-01 POSIX: dash -n ok (runtime)" || bad "P6-01 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P6-01 POSIX: bash -n ok (dash unavailable)" || bad "P6-01 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p6-reliability tests: PASS=$PASS FAIL=$FAIL  (O-2/O-3/O-4 FAIL 属预期复现)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1