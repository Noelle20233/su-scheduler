#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# p6-webui/test.sh — P6-08 DAG 可观测性与 WebUI 展示验收
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 权威：docs/architecture/dag-schema-v1.md D58（可观测只增键）+ D49/D50（run.txt
# 账本与五态）+ D51（失败传播）+ D54（节点级 only，v1 无链级取消 API）；
# docs/P3-05-WEBUI-DATA.md（B8 只增键 / JSON 转义 / 前端安全契约）。
# 覆盖：
#   §keys      GET_SUMMARY.dag / GET_TASK_DETAIL.dag 逐键 golden（D58 清单 +
#              P6-08 投影 chains/nodes/frontier/runs/reason）；既有键零删改守卫。
#   §nodes     节点态（运行中/等待/完成/失败/中断路）与链态五态、进度 done/total、
#              frontier、多 run 展示（进行中优先→最新）、RUNS_KEEP 历史钳制。
#   §fail      失败原因（gate-fail 传播 + gate.fail reason 透传、cond-unmet、
#              disabled、timeout）与传播路径数据。
#   §inject    恶意 run.txt（note 注入 <script>/引号/&、corrupt 文件、非法链目录名、
#              非 12 位 token、非法态值）→ JSON 转义/门拒收、零 exec、只读零改写。
#   §ops       B7 零新 op：IPC 19 恒定 + WEBUI_READ_OPS 5 恒定 + 前端 op 数组恒定。
#   §frontend  webroot 静态断言：DAG 视图/徽标/进度/批量=节点级映射文案与复用、
#              链事件/审计过滤、禁 innerHTML/eval/Root 直执（webroot/ 整目录扫描）。
#   §perf      GET_SUMMARY 增 dag 键后有界性（多链×RUNS_KEEP 史，宽松上界）。
#   §posix     本文件 dash -n（存在 dash 时）。
# 风格对齐 p5-webui：后端 JSON 行为断言（真实 IPC 文件通道）+ 前端 grep 特征断言。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
CLI="system/bin/su-scheduler"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── daemon 上下文 shim（同 p5-webui/p6-dag 惯例）─────────────────────────────
EXEC_LOG="$T/exec.log"; : > "$EXEC_LOG"
FAILDIR="$T/fail"; mkdir -p "$FAILDIR"
SLOWDIR="$T/slow"; mkdir -p "$SLOWDIR"
TASKS_DIR=""
execute_task() {           # 同步执行 shim：失败/在途由标记目录控制（p6-dag 同构）
    s_id=$1
    s_d="$TASKS_DIR/$s_id"
    mkdir -p "$s_d" 2>/dev/null
    echo "$s_id|$2" >> "$EXEC_LOG"
    date "+%Y-%m-%d %H:%M:%S" > "$s_d/start_time.txt" 2>/dev/null
    if [ -f "$FAILDIR/$s_id" ]; then
        echo "1" > "$s_d/exit_code.txt"; echo "FAILED" > "$s_d/status.txt"
    elif [ -f "$SLOWDIR/$s_id" ]; then
        echo "RUNNING" > "$s_d/status.txt"
    else
        echo "0" > "$s_d/exit_code.txt"; echo "SUCCESS" > "$s_d/status.txt"
    fi
    return 0
}
. ./$RTLIB

write_task() {   # <id> <trigger> <dep> [enabled] [condition]
    {
        echo "schema_version=2"; echo "id=$1"; echo "name=$1"; echo "enabled=${4:-1}"
        echo "trigger=$2"; echo "condition=${5:-}"; echo "dependency=$3"
        echo "action.type=command"; echo "action.command=echo $1"
        echo "action.notify_start=0"; echo "action.notify_end=0"; echo "action.delete=0"
        echo "action.termux=0"; echo "action.interactive=0"; echo "action.run_once_now=0"
        echo "action.boot=0"; echo "action.msg="; echo "health.type=none"; echo "recovery.type=none"
        echo "retry.max=0"; echo "retry.interval=60"
    } > "$TCFG_DIR/$1.task"
}
new_scene() {   # <name>：独立 base/task-config/tasks（registry 全局复位，同 p6-dag ex_new）
    SC="$T/$1"
    SC_BASE="$SC/base"; SC_TCFG="$SC/task-config"; SC_TASKS="$SC/tasks"; SC_CFG="$SC/config.txt"
    mkdir -p "$SC_BASE" "$SC_TCFG" "$SC_TASKS"; : > "$SC_CFG"
    export TCFG_DIR="$SC_TCFG"; echo managed > "$SC_TCFG/MANAGED"
    TASKS_DIR="$SC_TASKS"; export TASKS_DIR
    TR_BASE=""; TR_CONFIG_PATH=""
    DAG_RUNS_MAX=8; DAG_RUNS_KEEP=8; DAG_RUN_TIMEOUT=86400
    DAG_CHAIN_NODES_MAX=32; DAG_CHAIN_EDGES_MAX=128; DAG_CHAIN_DEPTH_MAX=16
}
etick() {       # <SC_BASE> <SC_CFG> <SC_TASKS> <HHMM> <epoch>
    SCHED_CYCLE_NOW="20260908$4"; GATE_NOW=$5
    state_sync_all "$3" >/dev/null 2>&1
    scheduler_tick "$1" "$2" "$3" "$4" >/dev/null 2>&1
    state_sync_all "$3" >/dev/null 2>&1
    SCHED_CYCLE_NOW=""; GATE_NOW=""
}
send_req() {   # <base> <config> <tasks> <req_id> <line> → resp 全文
    mkdir -p "$1/ipc/requests"
    printf '%s\n' "$5" > "$1/ipc/requests/$4.req"
    ipc_server_poll "$1" "$2" "$3" >/dev/null 2>&1
    cat "$1/ipc/responses/$4.resp" 2>/dev/null
}
sum_payload() {   # <base> <cfg> <tasks> <rid> → 单行 JSON payload
    send_req "$1" "$2" "$3" "$4" "$4|GET_SUMMARY|" | tail -n +2
}
det_payload() {   # <base> <cfg> <tasks> <rid> <id> → 单行 JSON payload
    send_req "$1" "$2" "$3" "$4" "$4|GET_TASK_DETAIL|id=$(ipc_b64enc "$5")" | tail -n +2
}

# ═══════════════════════════════════════════════════════════════════════════
# §keys — D58 只增键 golden（真实引擎产 run 账本驱动）
# 场景 K：root(0830) → b(chain) → c(chain) 线性链走完 SUCCESS
# ═══════════════════════════════════════════════════════════════════════════
new_scene k
write_task kroot "0830" ""
write_task kb chain "kroot"
write_task kc chain "kb"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0832 1789192920
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0833 1789192980
P=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "k1")
printf '%s' "$P" | grep -q '"dag":{"active":0,"limit":8,"recent_failed":0,"chains":\[' \
    && ok "P6-08 keys: GET_SUMMARY.dag = {active,limit,recent_failed,chains[]}（D58 三键 + 链投影）" \
    || bad "P6-08 keys: dag 键异常 payload=$P"
printf '%s' "$P" | grep -q '"root":"kroot","run":"202609080830","run_state":"SUCCESS"' \
    && ok "P6-08 keys: chains[] root/run/run_state golden（0830 根执行→0831 登记 run=根 cycle token）" \
    || bad "P6-08 keys: chains[] 内容异常 payload=$P"
printf '%s' "$P" | grep -q '"created":"1789192860"' \
    && ok "P6-08 keys: chains[].created = run.txt created 原值（账本透传）" \
    || bad "P6-08 keys: created 异常 payload=$P"
printf '%s' "$P" | grep -q '"done":3,"total":3,"frontier":\[\]' \
    && ok "P6-08 keys: 进度 done/total=3/3（root 行+成员行终态计数）frontier 空" \
    || bad "P6-08 keys: done/total 异常 payload=$P"
printf '%s' "$P" | grep -q '"nodes":\[{"id":"kroot","role":"root","state":"STOPPED","note":"1"},{"id":"kb","role":"node","state":"STOPPED","note":"disp"},{"id":"kc","role":"node","state":"STOPPED","note":"disp"}\]' \
    && ok "P6-08 keys: nodes[] 逐字段 golden（id/role/state/note；root 行 note=attempt）" \
    || bad "P6-08 keys: nodes[] 异常 payload=$P"
DROOT=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "k2" kroot)
printf '%s' "$DROOT" | grep -q '"dag":{"chain_root":"kroot","role":"root","run":"202609080830","run_state":"SUCCESS"' \
    && ok "P6-08 keys: GET_TASK_DETAIL.dag 根 = {chain_root,role,run,run_state}（D58 四键）" \
    || bad "P6-08 keys: detail root dag 异常 payload=$DROOT"
printf '%s' "$DROOT" | grep -q '"runs":\[{"run":"202609080830","run_state":"SUCCESS","created":"1789192860","done":3,"total":3}\]' \
    && ok "P6-08 keys: detail dag.runs[] 历史（RUNS_KEEP 内最新在前）" \
    || bad "P6-08 keys: dag.runs 异常 payload=$DROOT"
DB=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "k3" kb)
printf '%s' "$DB" | grep -q '"dag":{"chain_root":"kroot","role":"node","run":"202609080830","run_state":"SUCCESS","node_state":"STOPPED","note":"disp"' \
    && ok "P6-08 keys: detail 链节点 = node 归属 + 账本态/note（run.txt 事实源）" \
    || bad "P6-08 keys: detail node dag 异常 payload=$DB"
printf '%s' "$P" | grep -q '"audit":\[' && printf '%s' "$P" | grep -q 'action=register|chain=kroot|run=202609080830' \
    && ok "P6-08 keys: dag.audit[] 链审计尾读（op=dag|action=register 自 scheduler/audit.log 经既有 GET_SUMMARY 呈现）" \
    || bad "P6-08 keys: dag.audit 异常 payload=$P"
write_task kz "09:00" ""
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
DZ=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "k4" kz)
printf '%s' "$DZ" | grep -q '"dag":{"chain_root":"","role":"","run":"","run_state":"","node_state":"","note":"","reason":"","runs":\[\]}' \
    && ok "P6-08 keys: 非链任务 dag 全空字段（schema 恒在，前端零判空）" \
    || bad "P6-08 keys: 非链 dag 空态异常 payload=$DZ"

# B8 只增不删守卫：既有 GET_SUMMARY 顶层/counts 键全在
miss=0
for k in '"ok":true' '"daemon":"online"' '"mode":' '"counts":{"total":' '"running":' '"healthy":' '"failed":' '"disabled":' '"unhealthy":' '"unknown":' '"waiting":' '"recovering":' '"tasks":\[' '"dep_errors":'; do
    printf '%s' "$P" | grep -q "$k" || { miss=$((miss + 1)); echo "  missing summary key: $k"; }
done
[ "$miss" -eq 0 ] && ok "P6-08 keys: B8 守卫——GET_SUMMARY 既有键零删改（dag 为末尾追加）" \
    || bad "P6-08 keys: $miss 个既有键丢失"
miss=0
for k in '"id":"kroot"' '"status":' '"trigger":' '"action":' '"enabled":' '"health":{"type"' '"recovery":{"type"' '"pid":' '"last_exit":' '"source":' '"dependency":' '"condition":' '"dependency_state":' '"gate_state":' '"condition_state":' '"last_event":' '"has_run_dir":'; do
    printf '%s' "$DROOT" | grep -q "$k" || { miss=$((miss + 1)); echo "  missing detail key: $k"; }
done
[ "$miss" -eq 0 ] && ok "P6-08 keys: B8 守卫——GET_TASK_DETAIL 既有键零删改（dag 为末尾追加）" \
    || bad "P6-08 keys: $miss 个 detail 既有键丢失"

# 零副作用：只读聚合零 exec（k 场景共 3 次执行=链自身 3 节点各 1 次）
[ "$(wc -l < "$EXEC_LOG" | tr -d ' ')" = "3" ] \
    && ok "P6-08 keys: dag 聚合零额外 exec（执行计数=引擎链自身 3，读路径 0）" \
    || bad "P6-08 keys: exec 计数 $(wc -l < "$EXEC_LOG")（读聚合泄漏副作用）"

# ═══════════════════════════════════════════════════════════════════════════
# §nodes — 进行中 run：RUNNING/等待态徽标数据、frontier、active 计数、多 run 选择
# 场景 N：root(0830) → b(chain, slow 在途) → c(chain)
# ═══════════════════════════════════════════════════════════════════════════
new_scene n
write_task nroot "0830" ""
write_task nb chain "nroot"
write_task nc chain "nb"
touch "$SLOWDIR/nb"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800   # 根执行+mark
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860   # 登记 run，b 释放（在途）
PN=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "n1")
printf '%s' "$PN" | grep -q '"dag":{"active":1,"limit":8,"recent_failed":0' \
    && ok "P6-08 nodes: active=1（进行中 run 计数与引擎 dag_active_runs 同口径）" \
    || bad "P6-08 nodes: active 异常 payload=$PN"
printf '%s' "$PN" | grep -q '"run_state":"RUNNING"' \
    && ok "P6-08 nodes: 进行中 run 优先展示（run_state=RUNNING）" \
    || bad "P6-08 nodes: run_state 异常 payload=$PN"
printf '%s' "$PN" | grep -q '"state":"RUNNING","note":"disp"' \
    && ok "P6-08 nodes: 在途节点 RUNNING/disp（前端→「运行中」徽标数据）" \
    || bad "P6-08 nodes: 在途节点态异常 payload=$PN"
printf '%s' "$PN" | grep -q '"frontier":\["nb"\]' \
    && ok "P6-08 nodes: frontier=[nb]（已派发未落地=当前执行层）" \
    || bad "P6-08 nodes: frontier 异常 payload=$PN"
printf '%s' "$PN" | grep -q '"state":"PENDING","note":"waiting"' \
    && ok "P6-08 nodes: 等待节点 PENDING/waiting（前端→「等待」徽标数据）" \
    || bad "P6-08 nodes: 等待节点异常 payload=$PN"
printf '%s' "$PN" | grep -q '"done":1,"total":3' \
    && ok "P6-08 nodes: 进度 1/3（root 落 STOPPED，b/c 未终态）" \
    || bad "P6-08 nodes: 进度异常 payload=$PN"
rm -f "$SLOWDIR/nb"
echo 0 > "$SC_TASKS/nb/exit_code.txt"; echo SUCCESS > "$SC_TASKS/nb/status.txt"   # 模拟在途进程落地
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0832 1789192920   # b 完成→c 释放
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0833 1789192980
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0834 1789193040
PN2=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "n2")
printf '%s' "$PN2" | grep -q '"run_state":"SUCCESS"' \
    && ok "P6-08 nodes: 链收敛后 run_state=SUCCESS 展示更新" \
    || bad "P6-08 nodes: 收敛态异常 payload=$PN2"

# 多 run：同链第二轮 → 把根 trigger 改 0840 并强制快照重建（fingerprint 对等长行
# 同秒 mtime 不敏感，测试显式失效之）
sed 's/^trigger=0830/trigger=0840/' "$SC_TCFG/nroot.task" > "$SC_TCFG/nroot.task.tmp" && mv "$SC_TCFG/nroot.task.tmp" "$SC_TCFG/nroot.task"
rm -f "$SC_BASE/scheduler/source.md5"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0840 1789193400
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0841 1789193460
PN3=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "n3")
printf '%s' "$PN3" | grep -q '"run":"202609080840"' \
    && ok "P6-08 nodes: 多 run 时展示最新（全终态取最新 token）" \
    || bad "P6-08 nodes: 多 run 选择异常 payload=$PN3"
DN3=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "n4" nroot)
printf '%s' "$DN3" | grep -q '"runs":\[{"run":"202609080840"' \
    && ok "P6-08 nodes: 历史 runs[] 最新在前（0840 先于 0830）" \
    || bad "P6-08 nodes: 历史顺序异常 payload=$DN3"

# RUNS_KEEP 钳制：注入 9 个额外合法 SUCCESS run 目录（token 0900..0908）→ 展示史 ≤8
for tkn in 0900 0901 0902 0903 0904 0905 0906 0907 0908; do
    d="$SC_BASE/dag/nroot/runs/20260908$tkn"
    mkdir -p "$d"
    printf 'chain=nroot\nrun=20260908%s\nstate=SUCCESS\ncreated=1789199999\nroot=nroot|STOPPED|1\nnb|chain|STOPPED|disp\nnc|chain|STOPPED|disp\n' "$tkn" > "$d/run.txt"
done
DN4=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "n5" nroot)
nhist=$(printf '%s' "$DN4" | grep -o '"run":"2026' | wc -l | tr -d ' ')
[ "$nhist" -eq 9 ] \
    && ok "P6-08 nodes: runs[] 钳至 DAG_RUNS_KEEP=8（+chains[].run 展示位共 9 个 token 可见）" \
    || bad "P6-08 nodes: 历史钳制异常 count=$nhist payload=$DN4"
printf '%s' "$DN4" | grep -q '"runs":\[{"run":"202609080908","run_state":"SUCCESS","created":"1789199999","done":3,"total":3},{"run":"202609080907"' \
    && ok "P6-08 nodes: runs[] 倒序且不含被剪出的旧 token（0908→0907→…）" \
    || bad "P6-08 nodes: runs[] 序异常 payload=$DN4"
printf '%s' "$DN4" | grep -q '"run":"202609080830"' && bad "P6-08 nodes: 8 钳失效（0830 仍在历史）" \
    || ok "P6-08 nodes: 超出 RUNS_KEEP 的旧 run 不入展示历史（有界扫描）"

# 中断路（D54 disable）：新链根 → b enabled=0 → 账本 note=disabled
new_scene dis
write_task droot "0830" ""
write_task db chain "droot" 0
write_task dc chain "db"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0832 1789192920
PD=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "dis1")
printf '%s' "$PD" | grep -q '"id":"db","role":"node","state":"PENDING","note":"disabled"' \
    && ok "P6-08 nodes: disable=中断路账本 note=disabled（前端→「中断路」徽标数据，D54/D15）" \
    || bad "P6-08 nodes: disabled 态异常 payload=$PD"

# cond-unmet：b condition 恒假 → note=cond-unmet
new_scene cond
write_task croot "0830" ""
write_task cb chain "croot" 1 "{{ time.hour < 0 }}"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860
PC=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "cond1")
printf '%s' "$PC" | grep -q '"id":"cb","role":"node","state":"PENDING","note":"cond-unmet"' \
    && ok "P6-08 nodes: 条件不满足账本 note=cond-unmet（D52 释放叠加条件门）" \
    || bad "P6-08 nodes: cond-unmet 异常 payload=$PC"

# timeout：run 总时限超 → run_state=FAILED + action=timeout 审计可见
new_scene tmo
write_task troot "0830" ""
write_task tb chain "troot"
touch "$SLOWDIR/tb"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860
DAG_RUN_TIMEOUT=60
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0832 1789199999
DAG_RUN_TIMEOUT=86400
PT=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "tmo1")
printf '%s' "$PT" | grep -q '"run_state":"FAILED"' \
    && ok "P6-08 nodes: run 超时展示 run_state=FAILED（D57 五态收敛）" \
    || bad "P6-08 nodes: timeout 态异常 payload=$PT"
grep -q 'op=dag|action=timeout|chain=troot' "$SC_BASE/scheduler/audit.log" 2>/dev/null \
    && ok "P6-08 nodes: 超时审计 op=dag|action=timeout 入审计账本（dag.audit 尾读同源）" \
    || bad "P6-08 nodes: timeout 审计缺失"

# ═══════════════════════════════════════════════════════════════════════════
# §fail — 失败原因与传播路径
# 场景 F：root → b(失败) → c(b 的 Required 下游)  → c gate-fail 传播
# ═══════════════════════════════════════════════════════════════════════════
new_scene f
write_task froot "0830" ""
write_task fb chain "froot"
write_task fc chain "fb"
touch "$FAILDIR/fb"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0830 1789192800
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0831 1789192860
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0832 1789192920
etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" 0833 1789192980
PF=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "f1")
printf '%s' "$PF" | grep -q '"id":"fb","role":"node","state":"FAILED","note":"disp"' \
    && ok "P6-08 fail: 执行失败节点 FAILED/disp（前端→「失败·启动后失败」徽标数据）" \
    || bad "P6-08 fail: 失败节点态异常 payload=$PF"
printf '%s' "$PF" | grep -q '"id":"fc","role":"node","state":"FAILED","note":"gate-fail"' \
    && ok "P6-08 fail: Required 上游终态不匹配 → 传播 FAILED/gate-fail（D51 立即级联）" \
    || bad "P6-08 fail: 传播节点异常 payload=$PF"
printf '%s' "$PF" | grep -q '"recent_failed":1' \
    && ok "P6-08 fail: recent_failed=1（保留史内 FAILED run 计数）" \
    || bad "P6-08 fail: recent_failed 异常 payload=$PF"
DF=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "f2" fc)
printf '%s' "$DF" | grep -q '"note":"gate-fail","reason":"dep failed: fb(FAILED want STOPPED)"' \
    && ok "P6-08 fail: dag.reason 透传 gate.fail 传播原因（dep failed: 上游 id 可见）" \
    || bad "P6-08 fail: reason 透传异常 payload=$DF"
printf '%s' "$PF" | grep -q '"run_state":"FAILED"' \
    && ok "P6-08 fail: 成员含 FAILED → run 终态 FAILED（无 FAILED 则 SUCCESS，D51）" \
    || bad "P6-08 fail: run 终态异常 payload=$PF"
# 审计传播事件（dag.audit 与 scheduler/audit.log 数据面）
grep -q 'op=dag|action=fail-propagate|chain=froot.*reason=dep failed: fb' "$SC_BASE/scheduler/audit.log" 2>/dev/null \
    && ok "P6-08 fail: fail-propagate 审计（传播路径的审计侧账本）" \
    || bad "P6-08 fail: fail-propagate 审计缺失"
# :FAILED 故障分支（D51 行3）：c 唯一入边 ?sfb:FAILED → sfb FAILED 后 c 合法释放
new_scene sf
write_task sfroot "0830" ""
write_task sfb chain "sfroot"
write_task sfc chain "?sfb:FAILED"
touch "$FAILDIR/sfb"
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
for tkv in 0830 0831 0832 0833 0834; do etick "$SC_BASE" "$SC_CFG" "$SC_TASKS" "$tkv" $((1789192800 + (10#${tkv} - 830) * 60)); done
PSF=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "sf1")
printf '%s' "$PSF" | grep -q '"id":"sfc","role":"node","state":"STOPPED","note":"disp opt-unsat"\|"id":"sfc","role":"node","state":"STOPPED","note":"disp"' \
    && ok "P6-08 fail: :FAILED 故障分支节点在上游失败后释放执行（STOPPED/disp 可见）" \
    || bad "P6-08 fail: 故障分支异常 payload=$PSF"

# ═══════════════════════════════════════════════════════════════════════════
# §inject — 恶意 run.txt → JSON/HTML 转义与门拒收（前端不是安全边界，后端兜底）
# 手工伪造账本文件（引擎写路径不可产出这些内容——正是外部篡改/磁盘恶意数据的展示面）
# ═══════════════════════════════════════════════════════════════════════════
new_scene inj
write_task iroot "0830" ""
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
CFG_MD5_BEFORE=$(find "$SC_TCFG" -type f | sort | xargs cat 2>/dev/null | { cksum; })
d="$SC_BASE/dag/iroot/runs/202609081000"
mkdir -p "$d"
printf 'chain=iroot\nrun=202609081000\nstate=RUNNING\ncreated=1789199000\nroot=iroot|STOPPED|1\nevil|chain|RUNNING|"><script>alert(1)</script>\nsecond|chain|PENDING|a&b;touch /tmp/pwnweb_inj\n' > "$d/run.txt"
PI=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "inj1")
case "$PI" in
    *'<script>'*) bad "P6-08 inject: 裸 <script> 泄漏进 JSON payload" ;;
    *) ok "P6-08 inject: run.txt note 的 <script> 不出现在 payload 原文" ;;
esac
printf '%s' "$PI" | grep -q '\\u003cscript\\u003e' \
    && ok "P6-08 inject: note < > 转义为 \\u003c/\\u003e（与 §2 编码规则一致）" \
    || bad "P6-08 inject: \\u003c 转义缺失 payload=$PI"
printf '%s' "$PI" | grep -q '\\"' \
    && ok "P6-08 inject: note 内双引号 JSON 转义（不破结构）" \
    || bad "P6-08 inject: 引号未转义 payload=$PI"
printf '%s' "$PI" | grep -q '\\u0026' \
    && ok "P6-08 inject: note & 转义 \\u0026" \
    || bad "P6-08 inject: & 未转义 payload=$PI"
[ ! -e /tmp/pwnweb_inj ] && ok "P6-08 inject: 注入 ';touch' 零执行（/tmp/pwnweb_inj 不存在）" \
    || bad "P6-08 inject: 注入被执行（!!!）"
DI=$(det_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "inj2" iroot)
printf '%s' "$DI" | grep -q '"dag":{"chain_root":"iroot","role":"root","run":"202609081000","run_state":"RUNNING"' \
    && ok "P6-08 inject: detail 读恶意账本不崩（root 视角正常出四键，字段全走转义通道）" \
    || bad "P6-08 inject: detail 异常 payload=$DI"
CFG_MD5_AFTER=$(find "$SC_TCFG" -type f | sort | xargs cat 2>/dev/null | { cksum; })
[ "$CFG_MD5_BEFORE" = "$CFG_MD5_AFTER" ] \
    && ok "P6-08 inject: 恶意账本读取零改写 task-config（只读面）" \
    || bad "P6-08 inject: task-config 被读路径改动"
# corrupt/缺 run.txt 的伪造目录 → 展示层静默跳过（dag_run_parse 同门），不崩
mkdir -p "$SC_BASE/dag/iroot/runs/202609081001"   # 目录在、run.txt 缺（半成品）
mkdir -p "$SC_BASE/dag/iroot/runs/202609081002"
printf 'chain=iroot\nrun=WRONG\nstate=RUNNING\ncreated=1\nroot=iroot|STOPPED|1\n' > "$SC_BASE/dag/iroot/runs/202609081002/run.txt"
PI2=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "inj3")
printf '%s' "$PI2" | grep -q '"run":"202609081000"' && ! printf '%s' "$PI2" | grep -q '"run":"202609081002"' \
    && ok "P6-08 inject: token/chain 不一致的伪造 run 目录被门拒（不进展示）" \
    || bad "P6-08 inject: 伪造 run 未被拒 payload=$PI2"
# 非法链目录名（id 门）与非 12 位 token 目录：不读不出
badid="$SC_BASE/dag/bad;id/runs"; mkdir -p "$badid/202609081003"
printf 'chain=bad;id\nrun=202609081003\nstate=RUNNING\ncreated=1\nroot=bad;id|STOPPED|1\n' > "$badid/202609081003/run.txt"
mkdir -p "$SC_BASE/dag/iroot/runs/12345678901"; printf 'chain=iroot\nrun=12345678901\nstate=SUCCESS\ncreated=1\nroot=iroot|STOPPED|1\n' > "$SC_BASE/dag/iroot/runs/12345678901/run.txt"
PI3=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "inj4")
printf '%s' "$PI3" | grep -q 'bad;id' && bad "P6-08 inject: 非法链目录名入 payload" \
    || ok "P6-08 inject: 非法链目录名（secv_id_ok 门）与 11 位 token 目录全部拒出"
# 成员态值白名单归一：非法态 HACK → UNKNOWN（不裸泄任意串到 state 字段）
d2="$SC_BASE/dag/iroot/runs/202609081004"; mkdir -p "$d2"
printf 'chain=iroot\nrun=202609081004\nstate=RUNNING\ncreated=1789199004\nroot=iroot|STOPPED|1\nweird|chain|HACKSTATE|note with  spaces\n' > "$d2/run.txt"
PI4=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "inj5")
printf '%s' "$PI4" | grep -q '"id":"weird","role":"node","state":"UNKNOWN","note":"note with  spaces"' \
    && ok "P6-08 inject: 白名单外账本态归一 UNKNOWN（note 原样但已转义通道）" \
    || bad "P6-08 inject: 态归一异常 payload=$PI4"
[ ! -e /tmp/pwnweb_inj ] && ok "P6-08 inject: 全部注入场景后仍零执行文件" || bad "P6-08 inject: 注入执行泄漏"

# ═══════════════════════════════════════════════════════════════════════════
# §ops — B7 零新增 IPC op（19 恒定）+ Reader 白名单恒定 + 参数键门恒定
# ═══════════════════════════════════════════════════════════════════════════
[ "$(printf '%s\n' $IPC_WHITELIST | wc -l | tr -d ' ')" = "19" ] \
    && ok "P6-08 ops: IPC 白名单恒 19 op（dag 展示零新 op，纯既有 GET_* 增键）" \
    || bad "P6-08 ops: IPC_WHITELIST $(printf '%s\n' $IPC_WHITELIST | wc -l | tr -d ' ') op"
nro=$(grep '^WEBUI_READ_OPS=' "$CLI" | tr -d '"' | tr ' =' '\n\n' | grep -c '^GET')
[ "$nro" = "5" ] && ok "P6-08 ops: CLI Reader 只读白名单恒 5 op（零扩表）" \
    || bad "P6-08 ops: WEBUI_READ_OPS 计数异常 ($nro)"
grep -q 'GET_TASKS|GET_SUMMARY) echo "" ;;' "$RTLIB" \
    && ok "P6-08 ops: GET_SUMMARY 参数键门不变（无新查询参数面）" \
    || bad "P6-08 ops: ipc_allowed_keys GET_SUMMARY 改动"
grep -q 'GET_TASK_STATUS|GET_TASK_LOG|GET_TASK_DETAIL|GET_TASK_EVENTS) echo "id lines"' "$RTLIB" \
    && ok "P6-08 ops: GET_TASK_DETAIL 参数键仍 id/lines（链过滤走展示层，非后端参数）" \
    || bad "P6-08 ops: detail 参数键被扩"

# ═══════════════════════════════════════════════════════════════════════════
# §frontend — webroot 静态断言（链视图/徽标/批量=节点级映射/过滤/安全基线）
# ═══════════════════════════════════════════════════════════════════════════
grep -q 'DAG 链视图' webroot/app.js && ok "P6-08 front: DAG 链视图（route + h2）" || bad "P6-08 front: 链视图缺失"
grep -q 'r.view === "dag"' webroot/app.js && ok "P6-08 front: #dag 路由（复用 GET_SUMMARY 轮询刷新，P5-06 模式）" || bad "P6-08 front: dag 路由缺失"
grep -q 'href="#dag" data-view="dag"' webroot/index.html && ok "P6-08 front: 导航「DAG 链视图」入口" || bad "P6-08 front: 导航入口缺失"
grep -q 'dagNodeBadge' webroot/app.js && ok "P6-08 front: 节点态徽标映射（run.txt disp/waiting/FAILED/…）" || bad "P6-08 front: 徽标映射缺失"
for lbl in "运行中" "等待" "已完成" "失败" "中断路" "待调度" "顺延·并行" "失败·传播"; do
    grep -q "$lbl" webroot/app.js && ok "P6-08 front: 徽标文案「$lbl」" || bad "P6-08 front: 徽标文案「$lbl」缺失"
done
grep -q 'dag-prog' webroot/app.js && grep -q '\.dag-prog-fill' webroot/style.css \
    && ok "P6-08 front: 链进度条（done/total + 五态色）" || bad "P6-08 front: 进度条缺失"
grep -q '在途节点' webroot/app.js && ok "P6-08 front: frontier（当前执行层）展示" || bad "P6-08 front: frontier 缺失"
grep -q 'rs-' webroot/app.js && grep -q '\.rs-SUCCESS' webroot/style.css \
    && ok "P6-08 front: 链态五态样式族" || bad "P6-08 front: 链态样式缺失"
grep -q '尚未触发（静态拓扑）' webroot/app.js \
    && ok "P6-08 front: 配置期链（无 run）静态拓扑回退（根→下游，复用 depBadges 边徽标）" \
    || bad "P6-08 front: 静态拓扑回退缺失"
grep -q 'depBadges' webroot/app.js && grep -q 'dagNodeRow' webroot/app.js \
    && ok "P6-08 front: 链视图复用 P5-07 depBadges（Required/Optional/:STATE 边标注，单一渲染）" \
    || bad "P6-08 front: 未复用 dep 图面组件（重造第二套渲染）"
grep -q '批量节点操作' webroot/app.js \
    && ok "P6-08 front: 链停止/重启文案明示「批量节点操作」（D54 映射）" \
    || bad "P6-08 front: 批量节点操作文案缺失"
grep -q 'v1 无链级取消 API' webroot/app.js \
    && ok "P6-08 front: UI 声明 v1 无链级取消 API（与批准 ADR 一致）" \
    || bad "P6-08 front: 无链级取消 API 声明缺失"
grep -q 'runBatchIds(pair\[1\], pair\[0\], memberIds.slice(), box)' webroot/app.js \
    && ok "P6-08 front: 链操作走 runBatchIds 既有逐任务通道（B19 复用，零新后端面）" \
    || bad "P6-08 front: 链批量未复用 runBatchIds"
grep -q '逐任务返回结果' webroot/app.js \
    && ok "P6-08 front: 逐任务结果文案（B19 模式重申）" || bad "P6-08 front: 逐任务结果文案缺失"
grep -c 'write(op, { id: id })' webroot/app.js | grep -q '^1$' \
    && ok "P6-08 front: write(op,{id}) 单点实现（批量与链批量共通道）" \
    || bad "P6-08 front: 控制写通道出现重复实现"
grep -q 'dag-events-filter' webroot/app.js && grep -q 'dag_register' webroot/app.js \
    && ok "P6-08 front: events 面板「只看链事件」过滤（dag_register/dag_dispatch 令牌）" \
    || bad "P6-08 front: 链事件过滤缺失"
grep -q 'dag-log-filter' webroot/app.js && grep -q 'op=dag|' webroot/app.js \
    && ok "P6-08 front: daemon 日志面板「只看链审计」过滤（GET_DAEMON_LOG 原样行客户端投影）" \
    || bad "P6-08 front: 审计过滤缺失"
grep -q 'dag.chain_root' webroot/app.js && grep -q 'dag.run_state' webroot/app.js \
    && ok "P6-08 front: Task Detail 渲染 dag 键（chain_root/role/run/run_state/node_state/note/reason）" \
    || bad "P6-08 front: detail dag 渲染缺失"
grep -q '链 run 历史' webroot/app.js && ok "P6-08 front: detail 链 run 历史（RUNS_KEEP）渲染" || bad "P6-08 front: 历史渲染缺失"
fbad=0
for pat in 'innerHTML' 'eval(' 'document.write' 'su -c' 'sh -c' '/data/adb' 'new Function' 'child_process'; do
    grep -rq "$pat" webroot/ && { echo "  forbidden pattern in webroot/: $pat"; fbad=1; }
done
[ "$fbad" -eq 0 ] && ok "P6-08 front: 全部 webroot 文件（含新增代码）零 Root 直执/动态求值特征" \
    || bad "P6-08 front: 新增前端代码引入禁用特征"
grep -q 'var READ_OPS' webroot/app.js && grep -q 'var WRITE_OPS' webroot/app.js \
    && ok "P6-08 front: READ_OPS/WRITE_OPS 常量结构不变" || bad "P6-08 front: op 常量结构回退"
nread=$(sed -n 's/^  var READ_OPS = \[.*\];$/&/p' webroot/app.js | grep -o '"[A-Z_]*"' | wc -l | tr -d ' ')
[ "$nread" = "5" ] && ok "P6-08 front: 前端 READ_OPS 恒 5 只读 op" || bad "P6-08 front: READ_OPS 扩表演进 ($nread)"

# ═══════════════════════════════════════════════════════════════════════════
# §perf — GET_SUMMARY 增 dag 键后有界（12 链 × 8 run × 32 节点级账本）
# ═══════════════════════════════════════════════════════════════════════════
new_scene perf
i=1
while [ "$i" -le 12 ]; do
    cr="proot$i"
    write_task "$cr" "0830" ""
    j=0
    while [ "$j" -lt 8 ]; do
        ddir="$SC_BASE/dag/$cr/runs/20260908100$j"
        mkdir -p "$ddir"
        {
            printf 'chain=%s\nrun=20260908100%s\nstate=SUCCESS\ncreated=1789199000\nroot=%s|STOPPED|1\n' "$cr" "$j" "$cr"
            k=1
            while [ "$k" -le 30 ]; do printf '%s_n%02d|chain|STOPPED|disp\n' "$cr" "$k"; k=$((k + 1)); done
        } > "$ddir/run.txt"
        j=$((j + 1))
    done
    i=$((i + 1))
done
sched_reload "$SC_BASE" "$SC_CFG" >/dev/null 2>&1
S0=$(date +%s%N)
PP=$(sum_payload "$SC_BASE" "$SC_CFG" "$SC_TASKS" "perf1")
S1=$(date +%s%N)
MS=$(( (S1 - S0) / 1000000 ))
echo "PERF get_summary_dag ms=$MS (96 run.txt x 31 nodes)"
printf '%s' "$PP" | grep -q '"root":"proot12"' && [ "$MS" -le 3000 ] \
    && ok "P6-08 perf: GET_SUMMARY(dag) 12 链×8 run×30 节点 ${MS}ms ≤3000ms 宽松上界，chains 钳 $WEBUI_DAG_CHAINS_MAX 内" \
    || bad "P6-08 perf: ${MS}ms 或 chains 异常"

# ═══════════════════════════════════════════════════════════════════════════
# §posix — dash -n 自检（存在 dash 时）
# ═══════════════════════════════════════════════════════════════════════════
if command -v dash >/dev/null 2>&1; then
    dash -n tests/p6-webui/test.sh 2>/dev/null && ok "P6-08 posix: test.sh dash -n 通过" \
        || bad "P6-08 posix: dash -n 失败"
else
    ok "P6-08 posix: dash 不可用（跳过，bash -n 已过 lint）"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p6-webui tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
