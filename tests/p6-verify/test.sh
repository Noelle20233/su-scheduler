#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P6-11 综合性能、安全与发布验证（宿主部分）（tests/p6-verify）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；git 历史不可用时 §upgrade 整组 [SKIP]
# （CI shallow checkout 场景，不计失败）；出现 [FAIL] → exit 非 0。
# 性质：**纯测试资产（零生产改动）**。收拢 P6-11 宿主综合验证中"既有套件不
# 覆盖"的净新增断言；既有断言零改。方法沿用先例：
#   §perf3  scheduler_tick 三档基线（空 / 50 任务 / 32 节点链活跃 run 满额）——
#           p6-reliability §perf 与 resource H1-H6 同手法（决策型 tick、
#           SCHED_CYCLE_NOW 冻结时钟、execute_task shim、宽松上界 ≤2000ms）。
#   §ipc    IPC 端到端响应延迟基线（既有文件通道语义：rid|OP|params 请求 →
#           ipc_server_poll → 原子响应）。两级上界：通道空载响应 ≤1000ms
#           （GET_TASKS/VALIDATE），50 任务数据面 GET_TASKS ≤2500ms（聚合 O(n)，
#           防高负载误红——P6-09 A/B 先例）。ipc_client_send 真实往返仅
#           断言 rc=0（其 1s 轮询粒度为设计语义，非回归对象），墙钟记录供报告。
#   §conc   多链并发逼近 DAG_RUNS_MAX=8 与超额拒新的**时延**表现（P6-07 H3 已有
#           状态面，本组补拒新波次与稳态 pass 时延断言）。
#   §sh     shell 兼容扩展面：全部生产脚本 dash -n（L1 为 sh -n）；CLI/daemon
#           入 mksh 静态扫描面（P5-09 D36/D37 先例：参数展开零裸 `|`/`(`/`)`
#           pattern）；P6 新增测试入口 bash -n；webroot JS node --check（工具
#           存在时断言，否则 NOTE）；dash 真跑最小调度/IPC 派发（mksh 真运行时
#           延后设备，真机为最终裁判）。
#   §atomic 保存失败 I/O 级演示：tcfg_apply_task 目标 .tmp.$$ 路径被占 →
#           rc=2、旧文件逐字节不变、无 tmp 残留（既有 B9 面为校验拒绝路径，
#           本组补真实写失败路径；surface 汇总见 docs/P6-11.md）。
#   §dual   Legacy/Managed 互切实弹（dag 树逐字节闲置 → 回切引擎续跑）——
#           config-v2 §7/EX-19c 指认之外的双模式切换不炸断言。
#   §upgrade P5 基线 runtime（git 历史构建）与当前 Runtime 的「旧→新→旧→新」
#           宿主数据面演练：dag/ 对旧版惰性；旧版控制面（ipc_server_poll）在
#           新数据面上可运行（P6-10 §9 设备演练的宿主回归资产）；cycle/
#           last_tick 缺失新版不误补（跨二进制版）；run.txt 账本新版续读；
#           同日回滚期已执行分钟被新版 catch-up 重放 = 当前行为锁定
#           （缺陷登记 O-P6-11-01，见 docs/P6-11.md）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "[SKIP] $1"; }

RT="system/bin/su-scheduler-runtime"
DAEMON="system/bin/su-schedulerd"
CLI="system/bin/su-scheduler"
SELF="tests/p6-verify/test.sh"
T=$(mktemp -d)
BG_PID=""
cleanup() { [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# 公共 task 写手（resource rs_task 同源，24 字段全量，免 tcfg_new_task 子进程）
PV_TCFG=""
pv_task() {   # <dir> <id> <trigger> <dep>
    { echo "schema_version=2"; echo "id=$2"; echo "name=$2"; echo "enabled=1"
      echo "trigger=$3"; echo "condition="; echo "dependency=$4"
      echo "action.type=command"; echo "action.command=echo $2"
      echo "action.notify_start=0"; echo "action.notify_end=0"; echo "action.delete=0"
      echo "action.termux=0"; echo "action.interactive=0"; echo "action.run_once_now=0"
      echo "action.boot=0"; echo "action.msg="; echo "health.type=none"
      echo "recovery.type=none"; echo "retry.max=0"; echo "retry.interval=60"
    } > "$1/$2.task"
}
pv_manifest() {   # <dir> → 目录全部文件 sha 聚合（含 .scanmark/.scanpending）
    find "$1" -type f 2>/dev/null | sort | xargs -r sha256sum | sha256sum | cut -d' ' -f1
}

# 父层上下文（§atomic / §sh 直用）：TCFG_DIR + 库加载
export TCFG_DIR="$T/pv-tcfg"; mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
. "./$RT"

# ═══════════════════════════════════════════════════════════════════════════
# §perf3 — scheduler_tick 三档基线（空 / 50 任务 / 32 节点链满额活跃 run）
# ═══════════════════════════════════════════════════════════════════════════
PP="$T/perf"; PP_TCFG="$PP/tcfg"; PP_TASKS="$PP/tasks"; PP_BASE="$PP/base"
mkdir -p "$PP_TCFG" "$PP_TASKS" "$PP_BASE"; echo managed > "$PP_TCFG/MANAGED"
PP_CFG="$PP/config.txt"; : > "$PP_CFG"; PP_EXEC="$PP/exec.log"; : > "$PP_EXEC"
(
    export TCFG_DIR="$PP_TCFG" TASKS_DIR="$PP_TASKS"
    execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$PP_EXEC"
        echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; return 0; }
    . "$PWD/$RT"
    # 档 1：空 registry（预热 + 计时）
    SCHED_CYCLE_NOW=202609100900
    state_sync_all "$PP_TASKS" >/dev/null 2>&1
    scheduler_tick "$PP_BASE" "$PP_CFG" "$PP_TASKS" "0900" >/dev/null 2>&1
    state_sync_all "$PP_TASKS" >/dev/null 2>&1
    _t0=$(date +%s%N)
    scheduler_tick "$PP_BASE" "$PP_CFG" "$PP_TASKS" "0900" >/dev/null 2>&1
    _t1=$(date +%s%N)
    pp_empty=$(( (_t1 - _t0) / 1000000 ))
    # 档 2：50 任务（trigger=08:30，09:00 永不命中 → 纯决策，p6-reliability §perf 同构）
    i=1
    while [ "$i" -le 50 ]; do pv_task "$TCFG_DIR" "pvf$i" "08:30" ""; i=$((i + 1)); done
    SCHED_CYCLE_NOW=202609100900
    state_sync_all "$PP_TASKS" >/dev/null 2>&1
    scheduler_tick "$PP_BASE" "$PP_CFG" "$PP_TASKS" "0900" >/dev/null 2>&1   # 预热重建快照
    state_sync_all "$PP_TASKS" >/dev/null 2>&1
    _t0=$(date +%s%N)
    scheduler_tick "$PP_BASE" "$PP_CFG" "$PP_TASKS" "0900" >/dev/null 2>&1
    _t1=$(date +%s%N)
    pp_full=$(( (_t1 - _t0) / 1000000 ))
    echo "P611-TICK empty=$pp_empty full50=$pp_full"
) > "$T/perf3.txt" 2>&1
# 档 3：32 节点链满额活跃 run（root@0830 + 31 leaves slow-RUNNING；独立子 shell
#        全新 attach registry——tick 内含 scheduler_dag_pass。时间线对齐 H 系列：
#        0830 根执行 → 0831 登记+首派（4/拍闸）→ 逐拍全在途 → 测满额稳态 tick；
#        派发波峰值仅记录供 docs 报告（O-P6-11 说明：整 tick 含 32 任务决策 +
#        派发 fork 突发，H1-perf 同界口径为 pass 峰值）。
PC="$T/perf32"; PC_TCFG="$PC/tcfg"; PC_TASKS="$PC/tasks"; PC_BASE="$PC/base"; PC_SLOW="$PC/slow"
mkdir -p "$PC_TCFG" "$PC_TASKS" "$PC_BASE" "$PC_SLOW"; echo managed > "$PC_TCFG/MANAGED"
PC_CFG="$PC/config.txt"; : > "$PC_CFG"; PC_EXEC="$PC/exec.log"; : > "$PC_EXEC"
(
    export TCFG_DIR="$PC_TCFG" TASKS_DIR="$PC_TASKS"
    execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$PC_EXEC"
        if [ -f "$PC_SLOW/$1" ]; then echo RUNNING > "$TASKS_DIR/$1/status.txt"
        else echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; fi
        return 0; }
    . "$PWD/$RT"
    pv_task "$TCFG_DIR" pcr "0830" ""
    j=1; while [ "$j" -le 31 ]; do lv=$(printf 'pcl%02d' "$j"); pv_task "$TCFG_DIR" "$lv" chain pcr; touch "$PC_SLOW/$lv"; j=$((j + 1)); done
    SCHED_CYCLE_NOW=202609100830
    state_sync_all "$PC_TASKS" >/dev/null 2>&1
    scheduler_tick "$PC_BASE" "$PC_CFG" "$PC_TASKS" "0830" >/dev/null 2>&1   # 根执行+mark
    state_sync_all "$PC_TASKS" >/dev/null 2>&1
    SCHED_CYCLE_NOW=202609100831
    state_sync_all "$PC_TASKS" >/dev/null 2>&1
    scheduler_tick "$PC_BASE" "$PC_CFG" "$PC_TASKS" "0831" >/dev/null 2>&1   # 登记波+首派
    state_sync_all "$PC_TASKS" >/dev/null 2>&1
    pp_c32w=0; k=2
    while [ "$k" -le 3 ]; do   # 后续拍（在途恒 4=DAG_PARALLEL_MAX 闸，27 等待——锁设计语义）
        SCHED_CYCLE_NOW="2026091008$k"
        state_sync_all "$PC_TASKS" >/dev/null 2>&1
        _t0=$(date +%s%N)
        scheduler_tick "$PC_BASE" "$PC_CFG" "$PC_TASKS" "08$k" >/dev/null 2>&1
        _t1=$(date +%s%N)
        state_sync_all "$PC_TASKS" >/dev/null 2>&1
        _m=$(( (_t1 - _t0) / 1000000 )); [ "$_m" -gt "$pp_c32w" ] && pp_c32w=$_m
        k=$((k + 1))
    done
    pp_c32=0; k=1
    while [ "$k" -le 3 ]; do   # 满额稳态（run 活跃：4 在途 + 27 等待、零新派发）
        SCHED_CYCLE_NOW="2026091009$k"
        state_sync_all "$PC_TASKS" >/dev/null 2>&1
        _t0=$(date +%s%N)
        scheduler_tick "$PC_BASE" "$PC_CFG" "$PC_TASKS" "09$k" >/dev/null 2>&1
        _t1=$(date +%s%N)
        state_sync_all "$PC_TASKS" >/dev/null 2>&1
        _m=$(( (_t1 - _t0) / 1000000 )); [ "$_m" -gt "$pp_c32" ] && pp_c32=$_m
        k=$((k + 1))
    done
    echo "P611-TICK32 chain32=$pp_c32 dispwave=$pp_c32w disp=$(grep -c '^pcl' "$PC_EXEC" 2>/dev/null | tr -d ' ')"
    exit 0
) > "$T/perf32.txt" 2>&1
TL=$(grep -o 'P611-TICK empty=[0-9]* full50=[0-9]*' "$T/perf3.txt" | head -1)
TL32=$(grep -o 'P611-TICK32 chain32=[0-9]* dispwave=[0-9]* disp=[0-9]*' "$T/perf32.txt" | head -1)
E=$(printf '%s' "$TL" | sed 's/.*empty=\([0-9]*\).*/\1/')
F=$(printf '%s' "$TL" | sed 's/.*full50=\([0-9]*\).*/\1/')
C=$(printf '%s' "$TL32" | sed 's/.*chain32=\([0-9]*\).*/\1/')
if [ -n "$E" ] && [ "$E" -le 200 ]; then ok "P6-11 perf3-1: tick 空 registry ${E}ms (记录性基线，界 ≤200ms)"; else bad "P6-11 perf3-1: tick 空档异常 '$TL'"; fi
if [ -n "$F" ] && [ "$F" -le 2500 ]; then ok "P6-11 perf3-2: tick 50 任务 ${F}ms (记录性基线，P6-01 基线 1731ms 同构，宽松界 ≤2500ms)"; else bad "P6-11 perf3-2: tick 50 任务档异常 '$TL'"; fi
# A/B 环境噪声守卫（P6-09 先例）：链档稳态成本 ≈ 32 任务决策地板 + 32 节点 pass 地板，
# 与 50 任务决策档同阶；若宿主整体变慢两档同涨（非病态），仅当链档超“决策地板×2.2+800ms”
# 判病态回归（如 H5 修前复扫风暴级别）。
if [ -n "$C" ] && [ -n "$F" ]; then
    _cap=$(( F * 22 / 10 + 800 ))
    if [ "$C" -le "$_cap" ] && [ "$C" -le 3000 ]; then
        ok "P6-11 perf3-3: tick 32 节点链满额稳态 ${C}ms (记录性基线，A/B 地板 ${_cap}ms 内·≤3000ms 绝对界；4 在途=并行闸+27 defer)"
    else
        bad "P6-11 perf3-3: 32 节点链档病态越地板（链档=${C}ms > A/B cap=${_cap}ms）'$TL32'"
    fi
else
    bad "P6-11 perf3-3: 32 节点档缺测量 '$TL32'"
fi
echo "    $TL | $TL32"

# ═══════════════════════════════════════════════════════════════════════════
# §ipc — IPC 端到端响应延迟基线（请求入队(tmp+mv) → 响应可见；10ms 粒度等待）
# ═══════════════════════════════════════════════════════════════════════════
ipc_start_poller() {   # <base> <cfg> <tasks>（后台常驻 poller；就绪 = pid 文件出现）
    (
        export TCFG_DIR="$IPC_TCFG" TASKS_DIR="$3"
        execute_task() { return 0; }
        . "$PWD/$RT"
        sched_reload "$1" "$2" >/dev/null 2>&1
        ipc_server_init "$1" >/dev/null 2>&1
        while :; do
            ipc_server_poll "$1" "$2" "$3" >/dev/null 2>&1
            sleep 0.05
        done
    ) > /dev/null 2>&1 &
    BG_PID=$!
    _i=0
    while [ ! -f "$1/ipc/daemon.pid" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
    sleep 0.2
}
ipc_stop_poller() { kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""; }
PV_LAT=-1
ipc_measure() {   # <base> <op> <params> → PV_LAT=ms；响应 rc 入 PV_R
    _rid="pv$(date +%s%N)$RANDOM"
    _rd="$1/ipc/requests"
    printf '%s|%s|%s\n' "$_rid" "$2" "$3" > "$_rd/$_rid.req.tmp.$$" 2>/dev/null \
        || { PV_LAT=-1; return 1; }
    _t0=$(date +%s%N)
    mv "$_rd/$_rid.req.tmp.$$" "$_rd/$_rid.req" 2>/dev/null || { PV_LAT=-1; return 1; }
    _i=0
    while [ ! -f "$1/ipc/responses/$_rid.resp" ] && [ "$_i" -lt 2000 ]; do sleep 0.01; _i=$((_i + 1)); done
    _t1=$(date +%s%N)
    if [ ! -f "$1/ipc/responses/$_rid.resp" ]; then PV_LAT=-1; return 1; fi
    PV_R=$(head -1 "$1/ipc/responses/$_rid.resp" | cut -d'|' -f3)
    rm -f "$1/ipc/responses/$_rid.resp"
    PV_LAT=$(( (_t1 - _t0) / 1000000 ))
    return 0
}
IPC_T="$T/ipc1"; IPC_TCFG="$IPC_T/tcfg"; IPC_BASE="$IPC_T/base"; IPC_TASKS="$IPC_T/tasks"
mkdir -p "$IPC_TCFG" "$IPC_BASE" "$IPC_TASKS"; echo managed > "$IPC_TCFG/MANAGED"
IPC_CFG="$IPC_T/config.txt"; : > "$IPC_CFG"
ipc_start_poller "$IPC_BASE" "$IPC_CFG" "$IPC_TASKS"
[ -f "$IPC_BASE/ipc/daemon.pid" ] || bad "P6-11 ipc-setup: poller 未就绪"
# 预热（不计入统计：首请求含 snapshot 冷读/页缓存）
ipc_measure "$IPC_BASE" GET_TASKS "" >/dev/null 2>&1
# GET_TASKS（空 registry，纯通道响应性）×5 → max
gt_max=0; gt_ok=1; i=1
while [ "$i" -le 5 ]; do
    ipc_measure "$IPC_BASE" GET_TASKS "" || gt_ok=0
    [ "$PV_R" != "0" ] && gt_ok=0
    [ "$PV_LAT" -gt "$gt_max" ] && gt_max=$PV_LAT
    i=$((i + 1))
done
if [ "$gt_ok" = "1" ] && [ "$gt_max" -ge 0 ] && [ "$gt_max" -le 1000 ]; then
    ok "P6-11 ipc-1: GET_TASKS（空 registry）5 请求 max ${gt_max}ms (≤1000ms 宽松上界)"
else
    bad "P6-11 ipc-1: GET_TASKS 通道延迟异常 max=$gt_max ok=$gt_ok"
fi
# VALIDATE_TASK（trigger+command 通道）×5 → max
VA_P="trigger=$(ipc_b64enc '09:00')&command=$(ipc_b64enc 'echo x')"
va_max=0; va_ok=1; i=1
while [ "$i" -le 5 ]; do
    ipc_measure "$IPC_BASE" VALIDATE_TASK "$VA_P" || va_ok=0
    [ "$PV_R" != "0" ] && va_ok=0
    [ "$PV_LAT" -gt "$va_max" ] && va_max=$PV_LAT
    i=$((i + 1))
done
if [ "$va_ok" = "1" ] && [ "$va_max" -ge 0 ] && [ "$va_max" -le 1000 ]; then
    ok "P6-11 ipc-2: VALIDATE_TASK（合法 payload）5 请求 max ${va_max}ms (≤1000ms)"
else
    bad "P6-11 ipc-2: VALIDATE_TASK 延迟异常 max=$va_max ok=$va_ok"
fi
# 真实 ipc_client_send 往返（rc=0；墙钟记录——其 1s 轮询粒度为设计语义）
(
    export TCFG_DIR="$IPC_TCFG" TASKS_DIR="$IPC_TASKS"
    execute_task() { return 0; }
    . "$PWD/$RT"
    _t0=$(date +%s%N)
    _out=$(ipc_client_send "$IPC_BASE" GET_TASKS "" 8); _rc=$?
    _t1=$(date +%s%N)
    echo "P611-CLISND rc=$_rc wall=$(( (_t1 - _t0) / 1000000 ))ms"
) > "$T/clisnd.txt" 2>&1
CLR=$(grep -o 'rc=[0-9]*' "$T/clisnd.txt" | head -1)
if [ "$CLR" = "rc=0" ]; then
    ok "P6-11 ipc-3: ipc_client_send 全通道往返 rc=0（$(grep -o 'wall=[0-9]*ms' "$T/clisnd.txt")，1s 轮询粒度为设计语义）"
else
    bad "P6-11 ipc-3: ipc_client_send 往返异常 $(tr '\n' ' ' < "$T/clisnd.txt")"
fi
ipc_stop_poller
# 50 任务数据面 GET_TASKS（§perf 同界 ≤2000ms，防高负载误红——P6-09 A/B 先例）
i=1; while [ "$i" -le 50 ]; do pv_task "$IPC_TCFG" "ipct$i" "08:00" ""; i=$((i + 1)); done
ipc_start_poller "$IPC_BASE" "$IPC_CFG" "$IPC_TASKS"
ipc_measure "$IPC_BASE" GET_TASKS "" >/dev/null 2>&1   # 预热（payload 构建冷路径）
g50_max=0; i=1
while [ "$i" -le 5 ]; do
    ipc_measure "$IPC_BASE" GET_TASKS "" || { g50_max=-1; break; }
    [ "$PV_LAT" -gt "$g50_max" ] && g50_max=$PV_LAT
    i=$((i + 1))
done
ipc_stop_poller
if [ "$g50_max" -ge 0 ] && [ "$g50_max" -le 2500 ]; then
    ok "P6-11 ipc-4: GET_TASKS（50 任务数据面）5 请求 max ${g50_max}ms (≤2500ms，payload 聚合 O(n) 记录性基线)"
else
    bad "P6-11 ipc-4: GET_TASKS 50 任务延迟异常 max=$g50_max"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §conc — 9 链并发逼近 DAG_RUNS_MAX=8：拒新波次时延 + 稳态时延 + 在途存续
# ═══════════════════════════════════════════════════════════════════════════
CN="$T/conc"; CN_TCFG="$CN/tcfg"; CN_TASKS="$CN/tasks"; CN_BASE="$CN/base"; CN_SLOW="$CN/slow"
mkdir -p "$CN_TCFG" "$CN_TASKS" "$CN_BASE" "$CN_SLOW"; echo managed > "$CN_TCFG/MANAGED"
CN_CFG="$CN/config.txt"; : > "$CN_CFG"; CN_EXEC="$CN/exec.log"; : > "$CN_EXEC"
(
    export TCFG_DIR="$CN_TCFG" TASKS_DIR="$CN_TASKS"
    execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$CN_EXEC"
        if [ -f "$CN_SLOW/$1" ]; then echo RUNNING > "$TASKS_DIR/$1/status.txt"
        else echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; fi
        return 0; }
    . "$PWD/$RT"
    i=1
    while [ "$i" -le 9 ]; do
        pv_task "$TCFG_DIR" "cnr$i" "0830" ""; pv_task "$TCFG_DIR" "cnl$i" chain "cnr$i"
        touch "$CN_SLOW/cnl$i"; i=$((i + 1))
    done
    SCHED_CYCLE_NOW=202609100830
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
    scheduler_tick "$CN_BASE" "$CN_CFG" "$CN_TASKS" "0830" >/dev/null 2>&1   # 9 根执行+mark
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
    # 拒新波次（登记 8 + 第 9 limit 拒 + 首派）——pass 口径（H3 同源）整 tick 仅记录
    SCHED_CYCLE_NOW=202609100831
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
    _t0=$(date +%s%N)
    scheduler_dag_pass "$CN_BASE" "$CN_CFG" "$CN_TASKS" "0831" >/dev/null 2>&1
    _t1=$(date +%s%N)
    echo "P611-CONC wave_ms=$(( (_t1 - _t0) / 1000000 ))"
    scheduler_tick "$CN_BASE" "$CN_CFG" "$CN_TASKS" "0831" >/dev/null 2>&1   # 同拍 tick 面（不重复登记）
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
    st_max=0; k=2
    while [ "$k" -le 4 ]; do   # 稳态 pass 口径（8 在途 run + 1 pending 后滚）
        SCHED_CYCLE_NOW="2026091008$k"
        state_sync_all "$CN_TASKS" >/dev/null 2>&1
        _t0=$(date +%s%N)
        scheduler_dag_pass "$CN_BASE" "$CN_CFG" "$CN_TASKS" "08$k" >/dev/null 2>&1
        _t1=$(date +%s%N)
        state_sync_all "$CN_TASKS" >/dev/null 2>&1
        _m=$(( (_t1 - _t0) / 1000000 )); [ "$_m" -gt "$st_max" ] && st_max=$_m
        k=$((k + 1))
    done
    echo "P611-CONC steady_max=$st_max"
    exit 0
) > "$T/conc.txt" 2>&1
W=$(grep -o 'wave_ms=[0-9]*' "$T/conc.txt" | head -1 | cut -d= -f2)
SM=$(grep -o 'steady_max=[0-9]*' "$T/conc.txt" | head -1 | cut -d= -f2)
cn_dirs=$(ls "$CN_BASE/dag" 2>/dev/null | grep -c '^cnr' | tr -d ' ')
cn_lim=$(grep -c 'action=limit|chain=cnr9' "$CN_BASE/scheduler/audit.log" | tr -d ' ')
if [ -n "$W" ] && [ "$W" -le 3000 ] && [ "$cn_dirs" = "8" ] && [ "$cn_lim" -ge 1 ]; then
    ok "P6-11 conc-1: 第 9 链拒新（dirs=8+action=limit）登记波 pass ${W}ms (≤3000ms 一次性首扫界：O(roots) 现图重建+8 登记/派发/审计；稳态口径见 conc-2)"
else
    bad "P6-11 conc-1: 拒新波次异常 wave=$W dirs=$cn_dirs limit=$cn_lim"
fi
if [ -n "$SM" ] && [ "$SM" -le 2000 ]; then
    ok "P6-11 conc-2: 8 活跃 run + 1 pending 稳态 pass 峰值 ${SM}ms (≤2000ms，H5c 同界)"
else
    bad "P6-11 conc-2: 稳态时延异常 steady_max=$SM"
fi
cn_alive=$(grep -l '^state=RUNNING$' "$CN_BASE"/dag/cnr*/runs/202609100830/run.txt 2>/dev/null | wc -l | tr -d ' ')
cn_disp=$(grep -c '^cnl' "$CN_EXEC" | tr -d ' ')
if [ "$cn_alive" = "8" ] && [ "$cn_disp" = "8" ]; then
    ok "P6-11 conc-3: 超额拒新期间在途 8 run 全 RUNNING、8 节点各恰 1 次派发（零误杀零重派）"
else
    bad "P6-11 conc-3: 在途受损 alive=$cn_alive disp=$cn_disp"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §sh — shell 兼容扩展面（dash -n 全生产 / mksh 扫描入 CLI+daemon / JS / dash 真跑）
# ═══════════════════════════════════════════════════════════════════════════
PV_LF="$T/lf.tmp"
sh_all=1
for f in "$CLI" "$DAEMON" system/bin/su-scheduler-termux "$RT" service.sh customize.sh; do
    tr -d '\r' < "$f" > "$PV_LF"
    dash -n "$PV_LF" 2>/dev/null || { sh_all=0; echo "    dash -n FAIL: $f"; }
done
[ "$sh_all" = "1" ] && ok "P6-11 sh-1: dash -n 全部 6 个生产脚本通过（L1 sh -n 之外的显式 dash 面）" \
    || bad "P6-11 sh-1: dash -n 生产脚本存在失败"
mksh_scan() {   # <file> <name> → 3 类 pattern 展开零命中（代码行，去注释）
    tr -d '\r' < "$1" | grep -vE '^[[:space:]]*#' > "$T/code.tmp"
    n1=$(grep -cE '\$\{[^}]*\|' "$T/code.tmp")
    n2=$(grep -cE '\$\{[A-Za-z0-9_]*##?[^}]*[()]' "$T/code.tmp")
    n3=$(grep -cE '\$\{[A-Za-z0-9_]*%[^}]*[()]' "$T/code.tmp")
    if [ "$n1" = "0" ] && [ "$n2" = "0" ] && [ "$n3" = "0" ]; then
        ok "P6-11 sh-2: mksh 静态扫描 $2 零裸 |/( ) in-pattern 参数展开（D36/D37 面扩展）"
    else
        bad "P6-11 sh-2: mksh 静态扫描 $2 命中 pipe=$n1 paren=$n2/$n3"
    fi
}
mksh_scan "$CLI" "CLI(su-scheduler)"
mksh_scan "$DAEMON" "daemon(su-schedulerd)"
bn_all=1
for f in tests/p6-device/smoke.sh tests/p6-reliability/test.sh tests/resource/stress.sh "$SELF"; do
    tr -d '\r' < "$f" > "$PV_LF"
    bash -n "$PV_LF" 2>/dev/null || { bn_all=0; echo "    bash -n FAIL: $f"; }
done
[ "$bn_all" = "1" ] && ok "P6-11 sh-3: P6 测试入口 bash -n（p6-device/p6-reliability/resource/verify-self）通过" \
    || bad "P6-11 sh-3: P6 测试入口存在语法失败"
if command -v node >/dev/null 2>&1; then
    node --check webroot/app.js 2>/dev/null \
        && ok "P6-11 sh-4: node --check webroot/app.js 语法通过（P6-08 前端资产）" \
        || bad "P6-11 sh-4: node --check webroot/app.js 失败"
else
    echo "    NOTE: node 不可用，跳过 app.js 语法检查（真机 WebView 为最终裁判）"
fi
# dash 真跑（mksh 代理，P5-09 先例：静态断言 + dash 真跑 + 设备终裁）：
# tick 决策 + IPC 派发 + dag pass 全链路在纯 dash 下执行 rc=0
DR="$T/dashrun"; DR_TCFG="$DR/tcfg"; DR_TASKS="$DR/tasks"; DR_BASE="$DR/base"
mkdir -p "$DR_TCFG" "$DR_TASKS" "$DR_BASE"; echo managed > "$DR_TCFG/MANAGED"
pv_task "$DR_TCFG" drt "0830" ""
cat > "$DR/probe.sh" <<'PEOF'
#!/bin/sh
# dash 严格 POSIX 真跑探针：source runtime → tick → ipc poll → dag pass
set -u
. "$1"
TCFG_DIR="$2" TASKS_DIR="$3"; export TCFG_DIR TASKS_DIR
execute_task() { mkdir -p "$TASKS_DIR/$1"; echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; echo SUCCESS > "$TASKS_DIR/$1/state.txt"; return 0; }
SCHED_CYCLE_NOW=202609100830
scheduler_tick "$4" "$5" "$3" "0830" >/dev/null 2>&1 || exit 1
ipc_server_init "$4" >/dev/null 2>&1 || exit 1
printf 'dr1|GET_TASKS|\n' > "$4/ipc/requests/dr1.req"
ipc_server_poll "$4" "$5" "$3" >/dev/null 2>&1 || exit 1
head -1 "$4/ipc/responses/dr1.resp" | cut -d'|' -f3 | grep -qx 0 || exit 1
SCHED_CYCLE_NOW=202609100831 scheduler_dag_pass "$4" "$5" "$3" "0831" >/dev/null 2>&1 || exit 1
exit 0
PEOF
dash "$DR/probe.sh" "$PWD/$RT" "$DR_TCFG" "$DR_TASKS" "$DR_BASE" "$DR/cfg.txt" && \
    ok "P6-11 sh-5: dash 真跑 tick+IPC+dag-pass 探针 rc=0（mksh 真运行时延后设备，P5-09 先例）" \
    || bad "P6-11 sh-5: dash 真跑探针失败"

# ═══════════════════════════════════════════════════════════════════════════
# §atomic — 保存失败（I/O 级）config 逐字节不变（真实写失败演示）
# ═══════════════════════════════════════════════════════════════════════════
AT_ID=pvat1
pv_task "$TCFG_DIR" "$AT_ID" "08:00" ""
AT_F=$(tcfg_task_file "$AT_ID")
cp "$AT_F" "$T/at-before.txt"
GOOD2=$(sed 's/^enabled=1/enabled=0/' "$T/at-before.txt")
mkdir -p "$AT_F.tmp.$$"   # 抢占 .tmp.$$ 路径 → printf 重定向失败（真实 I/O 故障）
tcfg_apply_task "$AT_ID" "$GOOD2" 2>"$T/at-err.txt"
ATR=$?
AT_SAME=1; cmp -s "$AT_F" "$T/at-before.txt" || AT_SAME=0
rmdir "$AT_F.tmp.$$" 2>/dev/null
AT_TMP=$(ls "$TCFG_DIR"/*.tmp.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$ATR" = "2" ]; then
    ok "P6-11 atomic-1: 写失败（.tmp.\$\$ 被占）→ tcfg_apply_task rc=2（I/O 错误与校验拒绝 rc=1 可区分）"
else
    bad "P6-11 atomic-1: 写失败路径 rc=$ATR（期望 2）"
fi
[ "$AT_SAME" = "1" ] && ok "P6-11 atomic-2: 保存失败后目标 task 文件逐字节不变（B9 面 I/O 路径实证）" \
    || bad "P6-11 atomic-2: 保存失败改动了目标文件"
[ "$AT_TMP" = "0" ] && ok "P6-11 atomic-3: 失败后无半成品 tmp 文件残留（tmp 已清理/未产生）" \
    || bad "P6-11 atomic-3: tmp 残留 n=$AT_TMP"

# ═══════════════════════════════════════════════════════════════════════════
# §dual — Legacy/Managed 互切实弹（以 §conc 8 活跃 run 树为对象）
# ═══════════════════════════════════════════════════════════════════════════
DUAL_M1=$(pv_manifest "$CN_BASE/dag")
rm -f "$CN_TCFG/MANAGED"
(
    export TCFG_DIR="$CN_TCFG" TASKS_DIR="$CN_TASKS"
    execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$CN_EXEC"; return 0; }
    . "$PWD/$RT"
    [ "$(tcfg_mode)" = "legacy" ] || echo "MODE_BAD" > "$T/dual-mode.txt"
    SCHED_CYCLE_NOW=202609100835
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
    scheduler_tick "$CN_BASE" "$CN_CFG" "$CN_TASKS" "0835" >/dev/null 2>&1 || echo "TICK_BAD" >> "$T/dual-mode.txt"
    state_sync_all "$CN_TASKS" >/dev/null 2>&1
)
DUAL_M2=$(pv_manifest "$CN_BASE/dag")
DUAL_EXEC=$(grep -c '^cn' "$CN_EXEC" | tr -d ' ')
if [ "$DUAL_M1" = "$DUAL_M2" ] && [ "$DUAL_EXEC" = "17" ]; then
    ok "P6-11 dual-1: 切 legacy（去 MANAGED）tick 正常返回，dag 树逐字节闲置、零新增派发（EX-19c 同源、互切实证）"
else
    bad "P6-11 dual-1: legacy 切换触碰数据面 m1=$DUAL_M1 m2=$DUAL_M2 exec=$DUAL_EXEC"
fi
[ -f "$T/dual-mode.txt" ] && bad "P6-11 dual-2: 切换期模式判定/tick 异常 $(cat "$T/dual-mode.txt" | tr '\n' ';')" \
    || ok "P6-11 dual-2: tcfg_mode=legacy 判定正确且 legacy tick rc=0"
echo managed > "$CN_TCFG/MANAGED"
rm -f "$CN_SLOW/cnl1"; echo 0 > "$CN_TASKS/cnl1/exit_code.txt"; echo SUCCESS > "$CN_TASKS/cnl1/status.txt"
(
    export TCFG_DIR="$CN_TCFG" TASKS_DIR="$CN_TASKS"
    execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$CN_EXEC"; return 0; }
    . "$PWD/$RT"
    k=6
    while [ "$k" -le 7 ]; do
        SCHED_CYCLE_NOW="2026091008$k"
        state_sync_all "$CN_TASKS" >/dev/null 2>&1
        scheduler_tick "$CN_BASE" "$CN_CFG" "$CN_TASKS" "08$k" >/dev/null 2>&1
        state_sync_all "$CN_TASKS" >/dev/null 2>&1
        k=$((k + 1))
    done
)
DUAL_EXEC2=$(grep -c '^cnl1$' "$CN_EXEC" | tr -d ' ')
if grep -q '^state=SUCCESS$' "$CN_BASE/dag/cnr1/runs/202609100830/run.txt" 2>/dev/null \
   && [ "$DUAL_EXEC2" = "1" ]; then
    ok "P6-11 dual-3: 回切 managed 引擎续跑（cnr1 run 收敛 SUCCESS、节点零重派）——双模式互切不炸"
else
    bad "P6-11 dual-3: 回切后续跑异常 state=$(grep '^state=' "$CN_BASE/dag/cnr1/runs/202609100830/run.txt" 2>/dev/null) l1exec=$DUAL_EXEC2"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §upgrade — P5 基线 runtime ↔ 当前 Runtime 旧→新→旧→新 数据面演练
# 基线引用解析序：tag p5-baseline-v1.6.8-runtime1.30.0 → sha cbd065f → SKIP
# （CI actions/checkout fetch-depth=1 无历史 → 本组 SKIP，不计失败）
# ═══════════════════════════════════════════════════════════════════════════
OLD_RT="$T/old-runtime"
git show "p5-baseline-v1.6.8-runtime1.30.0:system/bin/su-scheduler-runtime" 2>/dev/null \
    | tr -d '\r' > "$OLD_RT"
if [ ! -s "$OLD_RT" ]; then
    git show "cbd065f334c774e643ba66b65aea0661b40c8df0:system/bin/su-scheduler-runtime" 2>/dev/null \
        | tr -d '\r' > "$OLD_RT"
fi
if [ ! -s "$OLD_RT" ] || ! grep -q 'RUNTIME_LIB_VERSION="1.30.0"' "$OLD_RT"; then
    skip "P6-11 upg-0: git 历史不可用（shallow checkout）——§upgrade 全组延后至全历史宿主/设备（P6-10 §9 已做设备版）"
else
    ok "P6-11 upg-0: P5 基线 Runtime 1.30.0 自 git 历史构建（零 dag/零 last_tick 代码面：hits=$(grep -c 'scheduler_dag_pass\|last_tick' "$OLD_RT")）"
    UP="$T/upg"; UP_TCFG="$UP/tcfg"; UP_TASKS="$UP/tasks"; UP_BASE="$UP/base"; UP_SLOW="$UP/slow"
    mkdir -p "$UP_TCFG" "$UP_TASKS" "$UP_BASE" "$UP_SLOW"; echo managed > "$UP_TCFG/MANAGED"
    UP_CFG="$UP/config.txt"; : > "$UP_CFG"; UP_EXEC="$UP/exec.log"; : > "$UP_EXEC"
    touch "$UP_SLOW/uleaf"
    up_exec_new() { mkdir -p "$TASKS_DIR/$1"; echo "$1|new" >> "$UP_EXEC"
        if [ -f "$UP_SLOW/$1" ]; then echo RUNNING > "$TASKS_DIR/$1/status.txt"
        else echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; fi
        return 0; }
    # ── 阶段 1（新版）：root@0830 + chain 慢叶 + t2@0833（留给回滚期）──
    #    时间线对齐 H 系列语义：0830 根执行 → 0831 登记 → 0832 派发（在途）──
    (
        export TCFG_DIR="$UP_TCFG" TASKS_DIR="$UP_TASKS"
        execute_task() { up_exec_new "$@"; }
        . "$PWD/$RT"
        pv_task "$TCFG_DIR" uroot "0830" ""; pv_task "$TCFG_DIR" uleaf chain uroot; pv_task "$TCFG_DIR" ut2 "0833" ""
        SCHED_CYCLE_NOW=202609100830
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        scheduler_tick "$UP_BASE" "$UP_CFG" "$UP_TASKS" "0830" >/dev/null 2>&1 || exit 1
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        SCHED_CYCLE_NOW=202609100831
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        scheduler_tick "$UP_BASE" "$UP_CFG" "$UP_TASKS" "0831" >/dev/null 2>&1 || exit 1
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        SCHED_CYCLE_NOW=202609100832
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        scheduler_tick "$UP_BASE" "$UP_CFG" "$UP_TASKS" "0832" >/dev/null 2>&1 || exit 1
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        exit 0
    ) && UP_P1=OK || UP_P1=BAD
    UP_M1=$(pv_manifest "$UP_BASE/dag")
    UP_RUN=$(ls "$UP_BASE"/dag/uroot/runs 2>/dev/null | head -1)
    UP_L1=$(grep -c '^uleaf|new' "$UP_EXEC" | tr -d ' ')
    [ "$UP_P1" = "OK" ] && [ "$UP_RUN" = "202609100830" ] && [ "$UP_L1" = "1" ] \
        && grep -q '^state=RUNNING$' "$UP_BASE/dag/uroot/runs/202609100830/run.txt" 2>/dev/null \
        && ok "P6-11 upg-1: 新版建立数据面（run=202609100830 登记、leaf RUNNING 在途恰 1 次派发）" \
        || bad "P6-11 upg-1: 新版数据面构建异常 p1=$UP_P1 run=$UP_RUN leaf=$UP_L1"
    # ── 阶段 2（回滚旧版 1.30）：tick 0833 —— ut2 执行、dag/ 惰性 ──
    (
        export TCFG_DIR="$UP_TCFG" TASKS_DIR="$UP_TASKS"
        execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1|old" >> "$UP_EXEC"; echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; return 0; }
        . "$OLD_RT"
        SCHED_CYCLE_NOW=202609100833
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        scheduler_tick "$UP_BASE" "$UP_CFG" "$UP_TASKS" "0833" >/dev/null 2>&1 || exit 1
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        exit 0
    ) && UP_P2=OK || UP_P2=BAD
    UP_M2=$(pv_manifest "$UP_BASE/dag")
    [ "$UP_P2" = "OK" ] && [ "$UP_M1" = "$UP_M2" ] \
        && ok "P6-11 upg-2: 旧版（1.30）tick 在新数据面上 rc=0，\$base/dag 逐字节惰性（未知目录不触碰）" \
        || bad "P6-11 upg-2: 旧版触碰 dag 或异常 p2=$UP_P2"
    UP_OLD_EXEC=$(grep -c '|old$' "$UP_EXEC" | tr -d ' ')
    UP_OLD_IDS=$(grep '|old$' "$UP_EXEC" | cut -d'|' -f1 | sort | tr '\n' ',')
    if [ "$UP_OLD_EXEC" = "1" ] && [ "$UP_OLD_IDS" = "ut2," ]; then
        ok "P6-11 upg-3: 旧版正常继续调度时间任务（ut2@0833 恰 1 次）、chain 族任务对旧版零派发"
    else
        bad "P6-11 upg-3: 旧版执行面异常 n=$UP_OLD_EXEC ids=$UP_OLD_IDS"
    fi
    # ── 阶段 3（再升级新版）：0834 tick —— 账本续读收敛 + catch-up 行为锁定 ──
    rm -f "$UP_SLOW/uleaf"
    (
        export TCFG_DIR="$UP_TCFG" TASKS_DIR="$UP_TASKS"
        execute_task() { up_exec_new "$@"; }
        . "$PWD/$RT"
        mkdir -p "$UP_TASKS/uleaf"; echo 0 > "$UP_TASKS/uleaf/exit_code.txt"; echo SUCCESS > "$UP_TASKS/uleaf/status.txt"
        SCHED_CYCLE_NOW=202609100834
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        scheduler_tick "$UP_BASE" "$UP_CFG" "$UP_TASKS" "0834" >/dev/null 2>&1 || exit 1
        state_sync_all "$UP_TASKS" >/dev/null 2>&1
        exit 0
    ) && UP_P3=OK || UP_P3=BAD
    UP_RF="$UP_BASE/dag/uroot/runs/202609100830/run.txt"
    UP_LEAF=$(grep -c '^uleaf|new' "$UP_EXEC" | tr -d ' ')
    UP_ROOTN=$(grep -c '^uroot|' "$UP_EXEC" | tr -d ' ')
    if [ "$UP_P3" = "OK" ] && [ -f "$UP_RF" ] && grep -q '^state=SUCCESS$' "$UP_RF" \
       && [ "$UP_LEAF" = "1" ] && [ "$UP_ROOTN" = "1" ]; then
        ok "P6-11 upg-4: run.txt 账本新版续读——同 run token 收敛 SUCCESS、在途节点零重派（回滚窗口无损）"
    else
        bad "P6-11 upg-4: 账本续读异常 p3=$UP_P3 state=$(grep '^state=' "$UP_RF" 2>/dev/null) leaf=$UP_LEAF root=$UP_ROOTN"
    fi
    UP_T2=$(grep -c '^ut2|' "$UP_EXEC" | tr -d ' ')
    if [ "$UP_T2" = "2" ]; then
        ok "P6-11 upg-5: LOCK（当前行为，登记 O-P6-11-01）：同日回滚期旧版已执行的 0833 窗口被新版 catch-up 重放（ut2 总执行=2；last_tick 停留 0832 → 补 0833）"
    else
        bad "P6-11 upg-5: catch-up 跨回滚行为偏离锁定值 n=$UP_T2（O-P6-11-01 语义变化需同步本锁）"
    fi
    # ── 阶段 4（item 9 控制面）：旧版 ipc_server_poll 读新数据面 ──
    UP_M2B=$(pv_manifest "$UP_BASE/dag")
    (
        export TCFG_DIR="$UP_TCFG" TASKS_DIR="$UP_TASKS"
        execute_task() { return 0; }
        . "$OLD_RT"
        ipc_server_init "$UP_BASE" >/dev/null 2>&1
        printf 'ug1|GET_TASKS|\n' > "$UP_BASE/ipc/requests/ug1.req"
        ipc_server_poll "$UP_BASE" "$UP_CFG" "$UP_TASKS" >/dev/null 2>&1
        head -1 "$UP_BASE/ipc/responses/ug1.resp" | cut -d'|' -f3 | grep -qx 0 || exit 1
    ) && UP_P4=OK || UP_P4=BAD
    UP_M3=$(pv_manifest "$UP_BASE/dag")
    [ "$UP_P4" = "OK" ] && [ "$UP_M2B" = "$UP_M3" ] \
        && ok "P6-11 upg-6: 旧版 IPC 控制面在新数据面 GET_TASKS rc=0 且 dag 树仍逐字节不变（回滚后旧版可运行·宿主面）" \
        || bad "P6-11 upg-6: 旧版控制面异常 p4=$UP_P4"
    # ── 阶段 5（升级正向）：纯旧版构建的 base（无 last_tick/cycle 新版语义）→ 新版首拍不误补 ──
    OB="$T/oldbase"; OB_TCFG="$OB/tcfg"; OB_TASKS="$OB/tasks"; OB_BASE="$OB/base"
    mkdir -p "$OB_TCFG" "$OB_TASKS" "$OB_BASE"; echo managed > "$OB_TCFG/MANAGED"
    OB_CFG="$OB/config.txt"; : > "$OB_CFG"; OB_EXEC="$OB/exec.log"; : > "$OB_EXEC"
    (
        export TCFG_DIR="$OB_TCFG" TASKS_DIR="$OB_TASKS"
        execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$OB_EXEC"; echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; return 0; }
        . "$OLD_RT"
        pv_task "$TCFG_DIR" ob1 "0830" ""
        SCHED_CYCLE_NOW=202609100829
        scheduler_tick "$OB_BASE" "$OB_CFG" "$OB_TASKS" "0829" >/dev/null 2>&1 || exit 1
        SCHED_CYCLE_NOW=202609100831
        scheduler_tick "$OB_BASE" "$OB_CFG" "$OB_TASKS" "0831" >/dev/null 2>&1 || exit 1
    ) && UP_P5=OK || UP_P5=BAD
    OB_LAST=$( [ -f "$OB_BASE/scheduler/last_tick" ] && echo YES || echo NO )
    (
        export TCFG_DIR="$OB_TCFG" TASKS_DIR="$OB_TASKS"
        execute_task() { mkdir -p "$TASKS_DIR/$1"; echo "$1" >> "$OB_EXEC"; echo 0 > "$TASKS_DIR/$1/exit_code.txt"; echo SUCCESS > "$TASKS_DIR/$1/status.txt"; return 0; }
        . "$PWD/$RT"
        SCHED_CYCLE_NOW=202609100833
        scheduler_tick "$OB_BASE" "$OB_CFG" "$OB_TASKS" "0833" >/dev/null 2>&1 || exit 1
    ) && UP_P6=OK || UP_P6=BAD
    OB_N=$(grep -c '^ob1|' "$OB_EXEC" | tr -d ' ')
    OB_TK=$(cat "$OB_BASE/scheduler/last_tick" 2>/dev/null)
    if [ "$UP_P5" = "OK" ] && [ "$UP_P6" = "OK" ] && [ "$OB_LAST" = "NO" ] && [ "$OB_N" = "0" ] && [ "$OB_TK" = "202609100833" ]; then
        ok "P6-11 upg-7: 旧版产物 base（无 last_tick）→ 新版首拍不误补已过 0830 窗口（跨二进制版 P6-02-5；last_tick 正确接管=202609100833）"
    else
        bad "P6-11 upg-7: 升级首拍语义异常 p5=$UP_P5 p6=$UP_P6 last=$OB_LAST n=$OB_N tk=$OB_TK"
    fi
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p6-verify tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
