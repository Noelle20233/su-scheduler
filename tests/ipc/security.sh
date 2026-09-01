#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# security.sh — P3-04 本地 IPC 控制面（安全边界：fuzz / 注入 / 权限 / 超时 / 去重）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 安全声明（对照任务验收）：
#   a) 非法请求不会执行任何 Root action（malformed/未知 op/坏 base64/超长 → rc 1
#      且 EXEC_LOG / task-config 零变化）
#   b) Shell 元字符不会进入执行路径（请求体只允许 base64 字母表；服务端绝不 eval；
#      START_TASK 仅接受 id，命令取自已校验任务文件）
#   c) 重复请求不会重复启动任务（同 req_id 幂等丢弃 + 已运行任务不重复 START）
#   d) IPC 超时不会阻塞 daemon（ipc_server_poll 单轮有界 IPC_POLL_MAX；客户端超时
#      → operation_timeout）
#   e) 未授权路径无法修改 Task（ipc 目录 0700；非 root 写不进去；非法请求零副作用）
#   f) daemon 停止时返回明确错误（daemon_unavailable rc 6）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── daemon 上下文 shim（同 test.sh）──────────────────────────────────────
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
EXEC_LOG="$T/exec.log"
execute_task() {
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

BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"
mkdir -p "$TCFG_DIR"
echo "managed" > "$TCFG_DIR/MANAGED"
ipc_server_init "$BASE" >/dev/null 2>&1

# 触发一次轮询并返回响应首行字段
poll_one() {   # <rid> → 首行 "rid|op|rc|err"
    ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
    cat "$BASE/ipc/responses/$1.resp" 2>/dev/null | head -1
}
drop_req() {   # <rid> <line>
    printf '%s\n' "$2" > "$BASE/ipc/requests/$1.req"
}
req_rc()  { echo "$1" | cut -d'|' -f3; }
req_err() { echo "$1" | cut -d'|' -f4; }

# 基线：task-config 快照（md5）与 EXEC_LOG 行数
tc_snap() { find "$TCFG_DIR" -type f ! -name 'MANAGED' ! -name 'manifest' 2>/dev/null | sort | xargs -r md5sum 2>/dev/null | md5sum | cut -d' ' -f1; }
SNAP_A=$(tc_snap)

# ── a) 非法请求零 Root action ─────────────────────────────────────────────
: > "$EXEC_LOG"
for c in \
    "f_empty||" \
    "f_noop|x" \
    "f_badop|h1|RM -rf /|" \
    "f_badrid|a;touch $T/pwn|GET_TASKS|" \
    "f_badrid2|\$(id)|GET_TASKS|" \
    "f_badb64|h2|GET_TASKS|id=\$();rm -rf /" \
    "f_badb64pipe|h3|GET_TASKS|id=bm90YmFzZQ==&x=\$(id)|" \
    "f_oversize|h4|GET_TASKS|p=$(printf 'A%.0s' $(seq 1 9000))" \
    "f_amp|h5|GET_TASKS|a=b&" \
    "f_badkey|h6|GET_TASKS|..=x" \
    "f_unknownkey|h7|GET_TASKS|id=$(echo -n y | base64 | tr -d '\n')"; do
    rid="${c%%|*}"
    line="${c#*|}"
    drop_req "$rid" "$line"
done
# 逐个轮询（单轮上限 64，足够）
ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
badcount=0
for rid in f_empty f_noop f_badop f_badrid f_badrid2 f_badb64 f_badb64pipe f_oversize f_amp f_badkey f_unknownkey; do
    rc=$(req_rc "$(poll_one "$rid")")
    [ "$rc" = "1" ] || badcount=$((badcount + 1))
done
[ "$badcount" -eq 0 ] && ok "P3-04 sec-a: 11 malformed/injection requests all -> invalid_request" || bad "P3-04 sec-a: $badcount requests not rejected"
[ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-04 sec-a: ZERO Root actions executed by malformed requests" || bad "P3-04 sec-a: exec leaked ($(wc -l < "$EXEC_LOG"))"
[ "$(tc_snap)" = "$SNAP_A" ] && ok "P3-04 sec-a: task-config byte-identical after fuzz" || bad "P3-04 sec-a: task-config mutated"

# ── b) Shell 元字符不进入执行路径 ─────────────────────────────────────────
# 建一个 registry 任务（managed 快照里要存在才能 START）
echo "managed" > "$TCFG_DIR/MANAGED"
mkid="task_sec_1"
[ -f "$TCFG_DIR/$mkid.task" ] || {
    tcfg_new_task "$mkid" "09:00" "echo safe-task" >/dev/null 2>&1
    sched_reload "$BASE" "$CFG" >/dev/null 2>&1
}
: > "$EXEC_LOG"
# START_TASK 仅按 id；即使请求行里塞满元字符也不执行它们
drop_req "inj1" "inj1|START_TASK|id=$(echo -n "$mkid" | base64 | tr -d '\n')"
out=$(poll_one "inj1")
[ "$(req_rc "$out")" = "0" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-04 sec-b: START_TASK by id executes stored command once (no injection)" || bad "P3-04 sec-b: start rc=$(req_rc "$out") exec=$(wc -l < "$EXEC_LOG")"
grep -q '^task_sec_1|echo safe-task|' "$EXEC_LOG" && ok "P3-04 sec-b: executed command == stored command (not request-supplied)" || bad "P3-04 sec-b: wrong command in exec log"

# 若请求尝试给 START_TASK 传 command（base64 化元字符）→ 参数键白名单拒绝
: > "$EXEC_LOG"
evil=$(printf 'echo pwned > %s/pwn' "$T" | base64 | tr -d '\n')
drop_req "inj2" "inj2|START_TASK|id=$(echo -n "$mkid" | base64 | tr -d '\n')&command=$evil"
out=$(poll_one "inj2")
[ "$(req_rc "$out")" = "1" ] && echo "$out" | grep -q invalid_request \
    && ok "P3-04 sec-b: START_TASK rejects unknown param key (command injection -> invalid_request)" || bad "P3-04 sec-b: rc=$(req_rc "$out") out=$out"
[ ! -f "$T/pwn" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 0 ] && ok "P3-04 sec-b: injected command never executed (no pwn file, no exec)" || bad "P3-04 sec-b: injection executed"

# ── c) 重复请求不重复启动任务 ─────────────────────────────────────────────
# 新任务（未运行）：同 req_id 投递两次 → 首次执行一次，二次幂等丢弃
dkid="task_sec_c"
[ -f "$TCFG_DIR/$dkid.task" ] || {
    tcfg_new_task "$dkid" "10:00" "echo dedup-task" >/dev/null 2>&1
    sched_reload "$BASE" "$CFG" >/dev/null 2>&1
}
SNAP_B=$(tc_snap)   # 所有任务创建完成后再取基线（sec-b + sec-c 已建好）
: > "$EXEC_LOG"
drop_req "dup1" "dup1|START_TASK|id=$(echo -n "$dkid" | base64 | tr -d '\n')"
ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
[ -f "$BASE/ipc/responses/dup1.resp" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-04 sec-c: first req_id processed + executed once" || bad "P3-04 sec-c: first exec=$(wc -l < "$EXEC_LOG") resp=$([ -f "$BASE/ipc/responses/dup1.resp" ] && echo yes || echo no)"
# 再投一次相同 req_id → 幂等丢弃，不重复执行
printf '%s\n' "dup1|START_TASK|id=$(echo -n "$dkid" | base64 | tr -d '\n')" > "$BASE/ipc/requests/dup1.req"
ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
[ "$(wc -l < "$EXEC_LOG")" -eq 1 ] && ok "P3-04 sec-c: same req_id re-delivered -> no double START (exec=1)" || bad "P3-04 sec-c: double-start exec=$(wc -l < "$EXEC_LOG")"

# 不同 req_id 但任务已 RUNNING → 也不重复启动
drop_req "dup2" "dup2|START_TASK|id=$(echo -n "$dkid" | base64 | tr -d '\n')"
out=$(poll_one "dup2")
[ "$(req_rc "$out")" = "0" ] && [ "$(wc -l < "$EXEC_LOG")" -eq 1 ] \
    && ok "P3-04 sec-c: already-running task -> no duplicate start (exec=1)" || bad "P3-04 sec-c: second start rc=$(req_rc "$out") exec=$(wc -l < "$EXEC_LOG")"

# ── d) IPC 超时不阻塞 daemon（轮询有界）──────────────────────────────────
# 投 70 个请求（> IPC_POLL_MAX=64）→ 单轮至多处理 64 个，且返回（不 hang）
rm -rf "$BASE/ipc/requests"/*.req 2>/dev/null
rm -f "$BASE/ipc/responses/bulk_"*.resp 2>/dev/null
for i in $(seq 1 70); do
    drop_req "bulk_$i" "bulk_$i|GET_TASKS|"
done
t0=$(date +%s)
ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
t1=$(date +%s)
procd=$(ls "$BASE/ipc/responses/"bulk_*.resp 2>/dev/null | wc -l)
[ $((t1 - t0)) -le 15 ] && [ "$procd" -le 64 ] && ok "P3-04 sec-d: server poll bounded (single call processed $procd <= 64, no hang)" || bad "P3-04 sec-d: took $((t1 - t0))s procd=$procd"
# 客户端：daemon 不响应 → operation_timeout（有界等待）
rm -rf "$BASE/ipc/requests"/*.req 2>/dev/null
echo "$$" > "$BASE/ipc/daemon.pid"
rm -f "$BASE/ipc/responses/ttl_*.resp" 2>/dev/null
t0=$(date +%s)
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
t1=$(date +%s)
[ "$rc" -eq 5 ] && [ $((t1 - t0)) -le 3 ] && ok "P3-04 sec-d: client timeout -> operation_timeout rc 5 (≤3s)" || bad "P3-04 sec-d: timeout rc=$rc took=$((t1 - t0))s"

# ── e) 未授权路径无法修改 Task ────────────────────────────────────────────
# ipc 目录 0700：非 root 用户不能写入（目录权限即门禁）
pm=$(ls -ld "$BASE/ipc" | awk '{print $1}')
[ "$pm" = "drwx------" ] && ok "P3-04 sec-e: ipc dir 0700 (root-only, unauthorized cannot drop requests)" || bad "P3-04 sec-e: ipc perms=$pm"
# 未授权写入模拟：chmod 000 后客户端写请求 → permission_denied
echo "$$" > "$BASE/ipc/daemon.pid"
chmod 000 "$BASE/ipc/requests"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
chmod 700 "$BASE/ipc/requests"
[ "$rc" -eq 2 ] && echo "$out" | grep -q permission_denied && ok "P3-04 sec-e: unauthorized write -> permission_denied (rc 2)" || bad "P3-04 sec-e: unauthorized rc=$rc out=$out"
# 非法请求零副作用（任务文件未被触碰——与创建后基线比对）
[ "$(tc_snap)" = "$SNAP_B" ] && ok "P3-04 sec-e: task-config unchanged since task creation" || bad "P3-04 sec-e: task-config mutated"

# ── f) daemon 停止 → 明确错误 ─────────────────────────────────────────────
rm -f "$BASE/ipc/daemon.pid"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
[ "$rc" -eq 6 ] && echo "$out" | grep -q daemon_unavailable && ok "P3-04 sec-f: daemon stopped -> daemon_unavailable (rc 6)" || bad "P3-04 sec-f: stopped rc=$rc out=$out"
# 死 pid 同样 daemon_unavailable
echo "999999" > "$BASE/ipc/daemon.pid"
out=$(ipc_client_send "$BASE" GET_TASKS "" 1 2>/dev/null)
rc=$?
[ "$rc" -eq 6 ] && ok "P3-04 sec-f: stale pid -> daemon_unavailable (rc 6)" || bad "P3-04 sec-f: stale pid rc=$rc"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "ipc security tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
