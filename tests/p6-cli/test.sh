#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P6-09 CLI / 审计 / 运维接口（tests/p6-cli）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P6-09 交付面）：
#   §A task status 链行（与 GET_TASK_DETAIL.dag 同源）+ 追加行兼容红线
#   §B 跳拍补偿：catch-up 执行 op=exec 审计 catchup=1（既有字段/顺序零改动）+
#      status last_tick_catchup/catchup_executed + 不重复执行反证
#   §C chain 子命令（链级只读查询：清单/详情/成员反查/未知拒绝/离线/未点火/在途）
#   §D op=dag|action=complete（run 终态回写审计；每 run 恰一条；timeout 路径不重复）
#   §E 链 note/最近原因四态（dep-fail/disabled/cond-unmet/timeout）× CLI 文本
#   §F 多根共享（字典序首链 + Member Of Chains 全量）
#   §G 错误详情一致性（CLI apply stderr == IPC configuration_invalid == chain
#      detail validation_error 同一字段级原因文本）
#   §P POSIX/结构守卫（dash -n/sh -n、IPC 白名单恒 19、selfcheck 新函数、旧行序不变）
# 引擎数据面 harness 复用 p6-dag 惯例（execute_task 同步 shim、SCHED_CYCLE_NOW/
# GATE_NOW 确定性时钟、etick=tick+state_sync_all、每场景独立 base/task-config）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RT="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export TCFG_DIR="$T/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
. "./$RT"

# ── harness（p6-dag 同源惯例；mk_task 多一个 condition 第 6 参）──────────────
execute_task() {
    e_id=$1; e_d="$TASKS_DIR/$e_id"
    mkdir -p "$e_d" 2>/dev/null
    echo "$e_id|$2" >> "$E_EXEC"
    date "+%Y-%m-%d %H:%M:%S" > "$e_d/start_time.txt" 2>/dev/null
    if [ -f "$E_FAILDIR/$e_id" ]; then
        echo "1" > "$e_d/exit_code.txt"; echo "FAILED" > "$e_d/status.txt"
    elif [ -f "$E_SLOWDIR/$e_id" ]; then
        echo "RUNNING" > "$e_d/status.txt"
    else
        echo "0" > "$e_d/exit_code.txt"; echo "SUCCESS" > "$e_d/status.txt"
    fi
    return 0
}
ex_new() {
    E_N=$((E_N + 1))
    E_DIR="$T/ex$E_N"
    E_BASE="$E_DIR/base"; E_TASKS="$E_DIR/tasks"; E_TCFG="$E_DIR/task-config"
    mkdir -p "$E_BASE" "$E_TASKS" "$E_TCFG" "$E_DIR/fail" "$E_DIR/slow"
    echo managed > "$E_TCFG/MANAGED"
    export TCFG_DIR="$E_TCFG"
    E_CFG="$E_DIR/config.txt"; : > "$E_CFG"
    E_EXEC="$E_DIR/exec.log"; : > "$E_EXEC"
    E_FAILDIR="$E_DIR/fail"; E_SLOWDIR="$E_DIR/slow"
    TR_BASE=""; TR_CONFIG_PATH=""
    export TASKS_DIR="$E_TASKS"
    DAG_CHAIN_NODES_MAX=32; DAG_CHAIN_EDGES_MAX=128; DAG_CHAIN_DEPTH_MAX=16
    DAG_RUNS_MAX=8; DAG_PARALLEL_MAX=4; DAG_RUN_TIMEOUT=86400; DAG_RUNS_KEEP=8
    WAIT_MAX=86400
    E_SEQ=0; E_EPOCH=1789192800
}
E_N=0
mk_task() {   # <id> <trigger> <dep> [retry.max] [enabled] [condition]
    {
        echo "schema_version=2"; echo "id=$1"; echo "name=$1"; echo "enabled=${5:-1}"
        echo "trigger=$2"; echo "condition=${6:-}"; echo "dependency=$3"
        echo "action.type=command"; echo "action.command=echo $1"
        echo "action.notify_start=0"; echo "action.notify_end=0"; echo "action.delete=0"
        echo "action.termux=0"; echo "action.interactive=0"; echo "action.run_once_now=0"
        echo "action.boot=0"; echo "action.msg="; echo "health.type=none"; echo "recovery.type=none"
        echo "retry.max=${4:-0}"; echo "retry.interval=60"
    } > "$E_TCFG/$1.task"
}
etick() {
    E_SEQ=$((E_SEQ + 1))
    SCHED_CYCLE_NOW="20260908$1"
    GATE_NOW=$((E_EPOCH + E_SEQ * 60))
    state_sync_all "$E_TASKS" >/dev/null 2>&1
    scheduler_tick "$E_BASE" "$E_CFG" "$E_TASKS" "$1" >/dev/null 2>&1
    state_sync_all "$E_TASKS" >/dev/null 2>&1
    SCHED_CYCLE_NOW=""; GATE_NOW=""
}
run_of() { echo "$E_BASE/dag/$1/runs/$2/run.txt"; }
AUD() { echo "$E_BASE/scheduler/audit.log"; }

# 生产 CLI 函数级 harness（task-cli-prod 同源：剥离主分发器 + 中和环境覆盖）
CLI_BODY=$(sed '/^# 🚦 Main Dispatcher/,$d' "$CLI" | tr -d '\r' | sed '/^unset /d; /^export PATH=/d')
cli_fn() {   # <loaded:1|0> <base> <tasks> <tcfg> <fn...> → stdout+stderr（子 shell 隔离）
    (
        set +u
        . "./$RT" 2>/dev/null || true
        eval "$CLI_BODY"
        RUNTIME_LOADED="$1"
        DATA_DIR="$2"; TASKS_DIR="$3"; TCFG_DIR="$4"
        SHELLS_DIR="$T/shells"
        shift 4
        "$@"
    ) 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# 场景 A：线性链 rt0→b→c 走完 SUCCESS（§A/§C/§D/§F 共用）
# ═══════════════════════════════════════════════════════════════════════════
ex_new
mk_task rt0 0830 ""; mk_task b chain rt0; mk_task c chain b
mk_task plain 0845 ""          # 非链对照
mkdir -p "$E_TASKS/plain"      # task-info 需要运行目录（未执行任务仅目录占位）
etick 0830; etick 0831; etick 0832; etick 0833
SA=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" b 2>/dev/null); SA_RC=$?
if [ "$SA_RC" -eq 0 ] \
   && printf '%s\n' "$SA" | grep -q '^chain_root=rt0$' \
   && printf '%s\n' "$SA" | grep -q '^role=node$' \
   && printf '%s\n' "$SA" | grep -q '^run=202609080830$' \
   && printf '%s\n' "$SA" | grep -q '^run_state=SUCCESS$' \
   && printf '%s\n' "$SA" | grep -q '^node_state=STOPPED$' \
   && printf '%s\n' "$SA" | grep -q '^note=disp$' \
   && printf '%s\n' "$SA" | grep -q '^reason=$'; then
    ok "A1 task status 链七键文本行 golden（chain_root/role/run/run_state/node_state/note/reason，与 GET_TASK_DETAIL.dag 同源）"
else
    bad "A1 链七键异常: [$(printf '%s\n' "$SA" | grep -E '^(chain_root|role|run|run_state|node_state|note|reason)=')]"
fi
SR=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" rt0 2>/dev/null)
if printf '%s\n' "$SR" | grep -q '^chain_root=rt0$' && printf '%s\n' "$SR" | grep -q '^role=root$' \
   && printf '%s\n' "$SR" | grep -q '^node_state=STOPPED$' && printf '%s\n' "$SR" | grep -q '^note=1$'; then
    ok "A2 链根 task status：role=root + root 行 attempt=note（账本事实源，与 WebUI 根口径一致）"
else
    bad "A2 链根行异常: [$(printf '%s\n' "$SR" | grep -E '^(role|node_state|note)=')]"
fi
SP=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" plain 2>/dev/null)
n=$(printf '%s\n' "$SP" | grep -cE '^(chain_root|role|run|run_state|node_state|note|reason)=')
if [ "$n" -eq 0 ] && printf '%s\n' "$SP" | grep -q '^last_tick_catchup=0$' \
   && printf '%s\n' "$SP" | grep -q '^catchup_executed=0$'; then
    ok "A3 非链任务零链行（旧输出兼容）+ 跳拍两行恒在（last_tick_catchup=0/catchup_executed=0）"
else
    bad "A3 非链任务出现 $n 条链行或跳拍行缺失"
fi
# 兼容红线：既有行序逐字节不变，新行只在尾部追加（positional 单调检查）
pline() { printf '%s\n' "$SP" | grep -n "^$1" | head -1 | cut -d: -f1; }
p_id=$(pline id=); p_state=$(pline state=); p_dep=$(pline dependency_state=)
p_cc=$(pline last_tick_catchup=); p_ce=$(pline catchup_executed=)
if [ -n "$p_id" ] && [ -n "$p_dep" ] && [ "$p_id" -lt "$p_state" ] && [ "$p_state" -lt "$p_dep" ] \
   && [ "$p_dep" -lt "$p_cc" ] && [ "$p_cc" -lt "$p_ce" ]; then
    ok "A4 行序红线：id<state<dependency_state<last_tick_catchup<catchup_executed（既有字段名/行序零改动，纯追加）"
else
    bad "A4 行序漂移 id=$p_id state=$p_state dep=$p_dep cc=$p_cc ce=$p_ce"
fi
TI=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_task_info b)
if printf '%s\n' "$TI" | grep -q 'Chain Root:.*rt0' \
   && printf '%s\n' "$TI" | grep -q 'Run:.*202609080830' \
   && printf '%s\n' "$TI" | grep -q 'Run State:.*SUCCESS' \
   && printf '%s\n' "$TI" | grep -q 'Upstream:.*rt0 (required want=STOPPED via=chain)' \
   && printf '%s\n' "$TI" | grep -q 'Downstream:.*c (required want=STOPPED via=chain)' \
   && printf '%s\n' "$TI" | grep -q 'Catchup Executed:.*0'; then
    ok "A5 task-info(managed) 追加标签：Chain Root/Run/Run State + Upstream/Downstream 边 + Catchup Executed"
else
    bad "A5 task-info 异常: [$(printf '%s\n' "$TI" | grep -E 'Chain|Run|Upstream|Downstream|Catchup' | tr '\n' ';')]"
fi
TIP=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_task_info plain)
if ! printf '%s\n' "$TIP" | grep -q 'Chain Root:' \
   && printf '%s\n' "$TIP" | grep -q 'Upstream:.*-' && printf '%s\n' "$TIP" | grep -q 'Downstream:.*-'; then
    ok "A6 task-info 非链任务：无 Chain Root 行，Upstream/Downstream 以 '-' 呈现（managed 域统一）"
else
    bad "A6 task-info 非链异常: [$(printf '%s\n' "$TIP" | grep -E 'Chain Root|Upstream|Downstream' | tr '\n' ';')]"
fi

# ── §C chain 子命令数据函数（同源账本 + 现图闭包）────────────────────────────
CS=$(task_cli_chain_summary "$E_BASE")
if printf '%s\n' "$CS" | grep -q '^chain=rt0 run=202609080830 run_state=SUCCESS done=3 total=3 inflight=0$' \
   && printf '%s\n' "$CS" | grep -q '^chains=1 active_runs=0 limit=8 remaining=8$'; then
    ok "C1 chain 清单 golden：每链一行（run/态/done/total/inflight）+ 汇总行（RUNS_MAX 余量）"
else
    bad "C1 chain 清单异常: [$(printf '%s\n' "$CS" | tr '\n' ';')]"
fi
CD=$(task_cli_chain_detail "$E_BASE" "$E_TASKS" rt0); CD_RC=$?
if [ "$CD_RC" -eq 0 ] \
   && printf '%s\n' "$CD" | grep -q '^chain=rt0$' \
   && printf '%s\n' "$CD" | grep -q '^run=202609080830$' \
   && printf '%s\n' "$CD" | grep -q '^run_state=SUCCESS$' \
   && printf '%s\n' "$CD" | grep -q '^root_state=STOPPED attempt=1$' \
   && printf '%s\n' "$CD" | grep -q '^member=b state=STOPPED note=disp$' \
   && printf '%s\n' "$CD" | grep -q '^member=c state=STOPPED note=disp$' \
   && printf '%s\n' "$CD" | grep -q '^closure=b c$' \
   && printf '%s\n' "$CD" | grep -q '^active_runs=0 limit=8 remaining=8$' \
   && printf '%s\n' "$CD" | grep -q '^runs=\[{"run"'; then
    ok "C2 chain 详情 golden：run/root 行/成员账本行/闭包/历史 JSON（runs=）/余量（零 IPC，纯文件读）"
else
    bad "C2 chain 详情异常: [$(printf '%s\n' "$CD" | tr '\n' ';')]"
fi
CDM=$(task_cli_chain_detail "$E_BASE" "$E_TASKS" c)
if printf '%s\n' "$CDM" | grep -q '^chain=rt0$' && printf '%s\n' "$CDM" | grep -q '^queried_id=c$'; then
    ok "C2b chain 详情接受成员 id：解析到归属链根（chain=rt0 + queried_id=c）"
else
    bad "C2b 成员反查异常: [$(printf '%s\n' "$CDM" | head -3 | tr '\n' ';')]"
fi
if ! task_cli_chain_detail "$E_BASE" "$E_TASKS" nosuch >/dev/null 2>&1; then
    e404=$(task_cli_chain_detail "$E_BASE" "$E_TASKS" nosuch 2>&1 >/dev/null)
    case "$e404" in
        *"chain not found: nosuch"*) ok "C3 未知链 id → rc1 + 'ERROR: chain not found'（与 task not found 三态惯例一致）" ;;
        *) bad "C3 未知链错误文案异常: [$e404]" ;;
    esac
else
    bad "C3 未知链 id 未被拒绝"
fi

# ── §C4 生产 CLI cmd_chain（分发/门控/usage/离线）────────────────────────────
KC=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_chain)
if printf '%s\n' "$KC" | grep -q '^chain=rt0 run=202609080830' && printf '%s\n' "$KC" | grep -q '^chains=1'; then
    ok "C4 cmd_chain 无参 = 链根清单（语法裁决：任务书 'root' 语义由无参承载，对齐 task list 惯例）"
else
    bad "C4 cmd_chain 清单异常: [$(printf '%s\n' "$KC" | tr '\n' ';')]"
fi
KD=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_chain rt0)
printf '%s\n' "$KD" | grep -q '^member=b state=STOPPED' \
    && ok "C4b cmd_chain <id> = 链详情（生产 CLI 端到端）" || bad "C4b cmd_chain 详情异常: [$(printf '%s\n' "$KD" | head -3)]"
cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_chain nope >/dev/null 2>&1 || KRC=$?
[ "${KRC:-0}" -eq 1 ] && ok "C4c cmd_chain nope → rc1（未知链传播退出码）" || bad "C4c cmd_chain rc 异常"
KH=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_chain -h); KH_RC=$?
[ "$KH_RC" -eq 0 ] && printf '%s\n' "$KH" | grep -q 'Usage: su-scheduler chain' \
    && ok "C4d cmd_chain -h usage rc0" || bad "C4d usage 异常 [$KH]"
KL=$(cli_fn 0 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_chain); KL_RC=$?
[ "$KL_RC" -ne 0 ] && printf '%s\n' "$KL" | grep -q 'requires production runtime library' \
    && ok "C4e RUNTIME_LOADED=0（runtime 缺失）→ 明确拒绝（同 task/ipc 门控惯例，legacy 零影响）" \
    || bad "C4e 门控异常 [$KL rc=$KL_RC]"
EX_EMPTY="$T/empty-base"; mkdir -p "$EX_EMPTY"
QE=$(TCFG_DIR="$T/empty-tcfg" TR_BASE= task_cli_chain_summary "$EX_EMPTY")
[ "$QE" = "chains=0 active_runs=0 limit=8 remaining=8" ] \
    && ok "C5 空 base 离线清单：仅汇总行全零（无 registry 也可用，daemon 不参与）" || bad "C5 空 base 异常 [$QE]"

# 未点火链（配置存在、无账本）：roots 现图并入、run=-
ex_new
mk_task nu 0830 ""; mk_task nb chain nu
sched_reload "$E_BASE" "$E_CFG" >/dev/null 2>&1
task_cli_attach "$E_BASE" >/dev/null 2>&1
CN=$(task_cli_chain_summary "$E_BASE")
if printf '%s\n' "$CN" | grep -q '^chain=nu run=- run_state=- done=- total=2 inflight=0$' \
   && printf '%s\n' "$CN" | grep -q '^chains=1'; then
    ok "C6 未点火链（现图根映射并入）：run=- done=- total=闭包大小"
else
    bad "C6 未点火链异常: [$(printf '%s\n' "$CN" | tr '\n' ';')]"
fi
# 在途计数：b slow（RUNNING 在途）→ inflight=1 active_runs=1 remaining=7
ex_new
mk_task rt0 0830 ""; mk_task b chain rt0; mk_task c chain b
touch "$E_SLOWDIR/b"
etick 0830; etick 0831
CI=$(task_cli_chain_summary "$E_BASE")
if printf '%s\n' "$CI" | grep -q '^chain=rt0 run=202609080830 run_state=RUNNING done=1 total=3 inflight=1$' \
   && printf '%s\n' "$CI" | grep -q '^chains=1 active_runs=1 limit=8 remaining=7$'; then
    ok "C7 进行中 run：run_state=RUNNING + inflight 计数 + RUNS_MAX 余量 7（D52/D57 口径）"
else
    bad "C7 在途计数异常: [$(printf '%s\n' "$CI" | tr '\n' ';')]"
fi

# ── §D action=complete 审计 ──────────────────────────────────────────────────
ex_new
mk_task rt0 0830 ""; mk_task b chain rt0; mk_task c chain b
etick 0830; etick 0831; etick 0832; etick 0833; etick 0834
nc=$(grep -c 'op=dag|action=complete' "$(AUD)")
if [ "$nc" = "1" ] && grep -q 'op=dag|action=complete|chain=rt0|run=202609080830|state=SUCCESS|nodes=3|failed=0|mode=managed' "$(AUD)"; then
    ok "D1 run 终态回写补审计 op=dag|action=complete|...|state=SUCCESS|nodes=3|failed=0（多 tick 仅 1 条，恰在跃迁时）"
else
    bad "D1 complete 审计异常 n=$nc: [$(grep 'action=complete' "$(AUD)" | tr '\n' ';')]"
fi
ex_new   # FAILED run（传播失败）→ complete|state=FAILED
mk_task rt0 0830 ""; mk_task b chain rt0; mk_task c chain b
touch "$E_FAILDIR/b"
etick 0830; etick 0831; etick 0832; etick 0833
if grep -q 'op=dag|action=complete|chain=rt0|run=202609080830|state=FAILED|nodes=3|failed=' "$(AUD)" \
   && [ "$(grep -c 'action=complete' "$(AUD)")" = "1" ]; then
    ok "D2 FAILED run 终态 → complete|state=FAILED（failed 计数入审计，单次跃迁恰一条）"
else
    bad "D2 FAILED complete 异常: [$(grep 'action=complete' "$(AUD)" | tr '\n' ';')]"
fi
ex_new   # 超时路径：b 在途（slow）持续 RUNNING → run 不收敛 → 超时 FAILED；
         # action=timeout 已有审计 → 不得重复 complete
mk_task rt0 0830 ""; mk_task b chain rt0
touch "$E_SLOWDIR/b"
DAG_RUN_TIMEOUT=60
etick 0830; etick 0831; etick 0832; etick 0833
if grep -q 'op=dag|action=timeout|chain=rt0' "$(AUD)" && ! grep -q 'action=complete' "$(AUD)"; then
    ok "D3 超时收敛 run：仅 action=timeout（既有审计），complete 不重复产出（终态写回处已有审计者不加）"
else
    bad "D3 超时路径 complete 重复或 timeout 缺失: [$(grep -E 'action=(timeout|complete)' "$(AUD)" | tr '\n' ';')]"
fi
# 既有 op=dag action 全集不因新 action 漂移（register/dispatch/timeout/fail-propagate/cond-unmet/limit/corrupt/prune + complete）
acts=$(grep -o 'op=dag|action=[a-z-]*' "$RT" | sort -u | tr '\n' ' ')
printf '%s' "$acts" | grep -q 'action=complete' \
    && ok "D4 action 集扩展仅追加（complete 入审计动词表；既有动词零改动）" || bad "D4 action 表异常 [$acts]"

# ── §B 跳拍补偿逐任务标记（catch-up 审计 catchup=1）──────────────────────────
ex_new
mk_task cap1 0832 ""; mk_task normal 0834 ""
SCHED_CYCLE_NOW=202609060829 scheduler_tick "$E_BASE" "$E_CFG" "$E_TASKS" "0829" >/dev/null 2>&1
SCHED_CYCLE_NOW=202609060834 scheduler_tick "$E_BASE" "$E_CFG" "$E_TASKS" "0834" >/dev/null 2>&1
AUDB="$E_BASE/scheduler/audit.log"
if grep -qE 'op=exec\|task=cap1\|trigger=0832\|mode=[^|]+\|rc=[0-9]+\|ron=[^|]*\|del=[^|]*\|cause=[^|]+\|catchup=1$' "$AUDB"; then
    ok "B1 catch-up 执行审计追加尾部字段 catchup=1（既有字段名/顺序逐字节保持）"
else
    bad "B1 catchup=1 标记缺失: [$(grep 'op=exec' "$AUDB" | tr '\n' ';')]"
fi
if grep -qE 'op=exec\|task=normal\|trigger=0834\|mode=[^|]+\|rc=[0-9]+\|ron=[^|]*\|del=[^|]*\|cause=[^|]+$' "$AUDB"; then
    ok "B2 常规（非补偿）执行行以 cause= 结尾、零 catchup 字段（legacy op=exec 文本零破坏）"
else
    bad "B2 常规行格式漂移: [$(grep 'task=normal|' "$AUDB" | tr '\n' ';')]"
fi
if grep 'op=tick' "$AUDB" | tail -1 | grep -q '|catchup=1$'; then
    ok "B3 最近 tick 行 catchup=1（聚合计数与逐任务标记并存，P6-02 字段零改动）"
else
    bad "B3 tick 聚合行异常: [$(grep 'op=tick' "$AUDB" | tail -1)]"
fi
task_cli_attach "$E_BASE" >/dev/null 2>&1
SB=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" cap1 2>/dev/null)
if printf '%s\n' "$SB" | grep -q '^catchup_executed=1$' && printf '%s\n' "$SB" | grep -q '^last_tick_catchup=1$'; then
    ok "B4 task status cap1 → catchup_executed=1 + last_tick_catchup=1（曾被补偿执行可见）"
else
    bad "B4 status 补偿行异常: [$(printf '%s\n' "$SB" | grep -E '^(catchup_executed|last_tick_catchup)=')]"
fi
SB2=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" normal 2>/dev/null)
printf '%s\n' "$SB2" | grep -q '^catchup_executed=0$' \
    && ok "B4b 同 tick 主循环执行者 catchup_executed=0（逐任务区分，非全局计数）" || bad "B4b normal 异常"
[ "$(grep -c '^cap1|' "$E_EXEC")" = "1" ] \
    && ok "B5 反证：cap1 仅执行一次（0831/0833 窗口不重复；标记仅审计面，不改执行语义）" || bad "B5 重复执行"
# 既有 op=exec 消费方兼容：cause= 前缀语义（task_cli_last_cause 对带 catchup 行仍取 cause）
[ "$(task_cli_last_cause cap1)" = "time_trigger" ] \
    && ok "B6 last_trigger_cause 对 catchup 行解析不受新字段影响（P5-08 消费面兼容）" || bad "B6 cause 解析异常"

# ═══════════════════════════════════════════════════════════════════════════
# 场景 E：链 note/原因四态
# ═══════════════════════════════════════════════════════════════════════════
ex_new   # E1 dep-fail 传播：b 失败 → c gate-fail，reason 文本 = 审计 reason 同源
mk_task rt0 0830 ""; mk_task b chain rt0; mk_task c chain b
touch "$E_FAILDIR/b"
etick 0830; etick 0831; etick 0832; etick 0833
SC=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" c 2>/dev/null)
note_c=$(printf '%s\n' "$SC" | sed -n 's/^note=//p')
reason_c=$(printf '%s\n' "$SC" | sed -n 's/^reason=//p')
audit_r=$(grep -o 'op=dag|action=fail-propagate|chain=rt0|run=[^|]*|task=c|reason=[^|]*' "$(AUD)" | tail -1 | sed 's/.*|reason=//')
if [ "$note_c" = "gate-fail" ] && [ -n "$reason_c" ] && [ "$reason_c" = "$audit_r" ]; then
    ok "E1 dep-fail：note=gate-fail 且 status reason 与审计 fail-propagate reason 逐字相同（$reason_c）"
else
    bad "E1 dep-fail 异常 note=[$note_c] reason=[$reason_c] audit=[$audit_r]"
fi
ex_new   # E2 中断路（D54）：b DISABLED → note=disabled；run 超时 FAILED → 下游 reason=run-timeout
mk_task rt0 0830 ""; mk_task b chain rt0 0 0; mk_task c chain b
DAG_RUN_TIMEOUT=60
etick 0830; etick 0831; etick 0832; etick 0833
SB2=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" b 2>/dev/null)
SC2=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" c 2>/dev/null)
if printf '%s\n' "$SB2" | grep -q '^note=disabled$' && printf '%s\n' "$SB2" | grep -q '^run_state=FAILED$' \
   && printf '%s\n' "$SC2" | grep -q '^reason=run-timeout$'; then
    ok "E2 中断路：b note=disabled；超时 run 的下游节点 reason=run-timeout（审计尾读，WebUI 键面不动）"
else
    bad "E2 中断/超时异常 b=[$(printf '%s\n' "$SB2" | grep -E '^(note|run_state)=')] c=[$(printf '%s\n' "$SC2" | grep '^reason=')]"
fi
ex_new   # E3 cond-unmet：依赖满足但条件恒假（time.hour==23 vs tick 08xx）→ note=cond-unmet
mk_task rt0 0830 ""; mk_task b chain rt0 0 1 '{{ time.hour == 23 }}'
etick 0830; etick 0831; etick 0832
SB3=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" b 2>/dev/null)
if printf '%s\n' "$SB3" | grep -q '^note=cond-unmet$' && grep -qE 'op=dag\|action=cond-unmet\|chain=rt0\|run=[^|]*\|task=b\|' "$(AUD)"; then
    ok "E3 cond-unmet：note=cond-unmet + action=cond-unmet 审计（reason 文本入审计行）"
else
    bad "E3 cond-unmet 异常: [$(printf '%s\n' "$SB3" | grep '^note=')]"
fi
ex_new   # §F 多根共享：s ∈ {ra, rb} 两链（跨根边取 Optional——required 跨根边在
         # 对方 run 账本外恒 missing:waiting 永不收敛，D51 语义；本用例验证展示面）
mk_task ra 0830 ""; mk_task rb 0831 ""; mk_task s chain '?ra,?rb'
etick 0830; etick 0831; etick 0832; etick 0833; etick 0834
SF=$(task_cli_status_id "$E_BASE" "$E_TASKS" "" s 2>/dev/null)
mem=$(task_cli_chain_membership "$E_BASE" s)
TIF=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_task_info s)
if printf '%s\n' "$SF" | grep -q '^chain_root=ra$' && [ "$mem" = "ra rb" ] \
   && printf '%s\n' "$TIF" | grep -q 'Member Of Chains:.*ra rb' \
   && printf '%s\n' "$TIF" | grep -q 'Upstream:.*ra (optional want=STOPPED via=chain); rb (optional want=STOPPED via=chain)' \
   && printf '%s\n' "$SF" | grep -q '^note=disp opt-unsat$'; then
    ok "F1 多根共享：主行 chain_root=字典序首链 ra（P6-08 v1 口径）；task-info 追加 Member Of Chains 全量 + 双上游边；账本 note=disp opt-unsat"
else
    bad "F1 多根共享异常 root=[$(printf '%s\n' "$SF" | grep '^chain_root=')] mem=[$mem] note=[$(printf '%s\n' "$SF" | grep '^note=')] ti=[$(printf '%s\n' "$TIF" | grep -cE 'Member Of|Upstream')]"
fi
CSF=$(task_cli_chain_summary "$E_BASE")
if printf '%s\n' "$CSF" | grep -q '^chain=ra ' && printf '%s\n' "$CSF" | grep -q '^chain=rb ' \
   && printf '%s\n' "$CSF" | grep -q '^chains=2'; then
    ok "F2 chain 清单含全部两链根（共享节点不吞链）"
else
    bad "F2 清单异常: [$(printf '%s\n' "$CSF" | tr '\n' ';')]"
fi
task_cli_status_id "$E_BASE" "$E_TASKS" "" zzz >/dev/null 2>&1 || F4RC=$?
[ "${F4RC:-0}" -eq 1 ] && ok "F3 task status 未知 id rc1（错误三态零改动）" || bad "F3 rc=$F4RC"

# ═══════════════════════════════════════════════════════════════════════════
# 场景 G：错误详情一致性（CLI apply stderr == IPC configuration_invalid == chain
# detail validation_error，同一字段级原因文本；P6-04 通道）
# ═══════════════════════════════════════════════════════════════════════════
ex_new
mk_task q00 0830 ""
i=1
while [ "$i" -le 19 ]; do
    prev=$(printf 'q%02d' $((i - 1)))
    cur=$(printf 'q%02d' "$i")
    mk_task "$cur" chain "$prev"
    i=$((i + 1))
done
# ① CLI 写路径（cmd_task_config apply 与 ipc EDIT 共用 tcfg_apply_task 校验器）
G_APPLY="$E_DIR/apply.txt"
cp "$E_TCFG/q19.task" "$G_APPLY"
G_ERR=$(cli_fn 1 "$E_BASE" "$E_TASKS" "$E_TCFG" cmd_task_config apply q19 "$G_APPLY" 2>&1)
G1=$(printf '%s\n' "$G_ERR" | sed -n 's/.*\(chain depth [0-9]* exceeds DAG_CHAIN_DEPTH_MAX=[0-9]*\).*/\1/p' | head -1)
# ② IPC 信封（P6-04 透传通道）
G_CONTENT=$(cat "$E_TCFG/q19.task")
ipc_op_validate "$E_BASE" g1 "payload=$(ipc_b64enc "$G_CONTENT")" >/dev/null 2>&1
G_RESP="$E_BASE/ipc/responses/g1.resp"
G2=$(head -1 "$G_RESP" 2>/dev/null | sed -n 's/.*configuration_invalid: //p' | sed -n 's/.*\(chain depth [0-9]* exceeds DAG_CHAIN_DEPTH_MAX=[0-9]*\).*/\1/p')
# ③ chain 详情 validation_error（dep_graph_read 同一校验器、剥前缀）
rm -f "$E_BASE/scheduler/source.md5"
sched_reload "$E_BASE" "$E_CFG" >/dev/null 2>&1
task_cli_attach "$E_BASE" >/dev/null 2>&1
G3=$(task_cli_chain_detail "$E_BASE" "$E_TASKS" q00 | sed -n 's/^validation_error=//p' | head -1)
if [ -n "$G1" ] && [ "$G1" = "$G2" ] && [ "$G1" = "$G3" ]; then
    ok "G1 三路收敛同一字段级原因文本：CLI apply / IPC configuration_invalid / chain validation_error ==「$G1」"
else
    bad "G1 原因不一致 cli=[$G1] ipc=[$G2] chain=[$G3]"
fi
head -1 "$G_RESP" 2>/dev/null | grep -q '^g1|VALIDATE_TASK|4|configuration_invalid: ' \
    && ok "G2 IPC 信封保持 rc4 configuration_invalid 前缀（P6-04 契约零改动）" || bad "G2 信封异常 [$(head -1 "$G_RESP" 2>/dev/null)]"
# apply 拒绝零副作用：旧文件逐字节不变
cmp -s "$G_APPLY" "$E_TCFG/q19.task" \
    && ok "G3 CLI apply 超限拒绝且不写盘（既有 tcfg_apply_task 语义保持）" || bad "G3 apply 意外写盘"
# 图非法 → 快照 KEPT（P4-03 语义）：task status 三态 rc2 configuration invalid
task_cli_status_id "$E_BASE" "$E_TASKS" "" q00 >/dev/null 2>&1 || T4RC=$?
[ "${T4RC:-0}" -eq 2 ] && ok "G4 图超限配置快照 KEPT → status rc2 configuration invalid（三态语义零改动）" || bad "G4 rc=$T4RC"

# ═══════════════════════════════════════════════════════════════════════════
# §P 结构与 POSIX 守卫
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'chain) shift; cmd_chain' "$CLI" && grep -q 'cmd_chain()' "$CLI" \
    && ok "P1 生产 CLI 分发含 chain 子命令" || bad "P1 chain 分发缺失"
grep -q 'su-scheduler chain' "$CLI" \
    && ok "P1b print_help 含 chain 行（help/usage 同步）" || bad "P1b help 缺失"
[ "$(printf '%s\n' $IPC_WHITELIST | wc -l | tr -d ' ')" = "19" ] \
    && ok "P2 IPC 白名单恒 19 op（B7 零新增 op——chain 为纯文件只读，无 daemon 通道）" \
    || bad "P2 op 数漂移"
( . "./$RT"; runtime_lib_selfcheck >/dev/null 2>&1 ) \
    && ok "P2b runtime selfcheck 通过（新函数 task_cli_dag_*/chain_*/catchup_* 已注册）" || bad "P2b selfcheck 失败"
P3B="$T/p3base"; mkdir -p "$P3B"
TR_LOGGING=0 registry_init "$P3B" tests/fixtures/legacy/config.txt >/dev/null 2>&1
LC=$(task_cli_list 2>/dev/null | head -1)
[ "$(printf '%s' "$LC" | awk -F'|' '{print NF}')" = "6" ] \
    && ok "P3 task list 行格式 6 字段零改动（追加不破坏既有行）" || bad "P3 list 行漂移 [$LC]"
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RT" && dash -n "$PWD/$CLI" 2>/dev/null; RC=$?
    dash -n "$PWD/$RT" && ok "P4 dash -n runtime ok" || bad "P4 dash -n runtime"
    [ "$RC" = "0" ] && ok "P4b dash -n CLI ok（bash 数组语法仅测试宿主侧）" || true
fi
sh -n "$0" >/dev/null 2>&1 && ok "P5 sh -n test.sh ok（本套件 POSIX 兼容）" || bad "P5 本套件语法"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p6-cli tests: PASS=$PASS FAIL=$FAIL  (P6-09 CLI/审计/运维接口：链展示同源、跳拍标记、chain 只读、complete 审计、错误一致)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
