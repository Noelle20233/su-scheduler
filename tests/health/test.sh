#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Process & Port Health（P2-11）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-11 出口：能验证 Shizuku 进程、服务端口等真实健康状态）：
#   1) 入口：§16 tpr_health_{ms,log,process_validate,process_check,port_validate,
#      port_check} 就位；health>process / health>port 注册；health_check 正式
#      入口；selfcheck 锚点。
#   2) 统一三态 + 原因 + 延迟 + 目标：结果行格式
#      <STATE>|reason=<..>|latency_ms=<数字>|target=<spec>；返回码 0/1/2。
#   3) Process Check：进程名（pidof）→ HEALTHY；本进程 PID → HEALTHY；不存在
#      PID → UNHEALTHY；不存在进程名 → UNHEALTHY；非法 spec（元字符/空）→
#      UNKNOWN（invalid-spec）。
#   4) Port Check：真实监听（nc 起 listener）→ HEALTHY(port-listening)；未监听
#      端口 → UNHEALTHY(port-not-listening)；非法 spec（0/70000/abc）→ UNKNOWN。
#   5) 状态机门槛联动：注册 process/port 后 state_health_allowed=0（P2-07 门槛
#      打开）；state_log_event RUNNING→HEALTHY 可写。
#   6) dispatch：provider_dispatch health <kind> check 0/1/2；health_check
#      用法错误 → 3。
#   7) POSIX：lib dash -n。
# 加载：`. ./$RTLIB`（变量引用保持路径隔离门禁语义）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

. ./$RTLIB

# ── 1) 入口：§16 函数 + 注册 + health_check ────────────────────────────────
n=$(grep -cE '^tpr_health_(ms|log|process_validate|process_check|port_validate|port_check)\(' "$RTLIB")
[ "$n" -eq 6 ] && ok "P2-11 entry: §16 tpr_health_* 6 functions defined" || bad "P2-11 entry: health funcs count=$n (expect 6)"
grep -q 'provider_register health process' "$RTLIB" && grep -q 'provider_register health port' "$RTLIB" \
    && ok "P2-11 entry: health>process + health>port registered" || bad "P2-11 entry: registration missing"
n=$(grep -cE '^health_check\(' "$RTLIB")
[ "$n" -eq 1 ] && ok "P2-11 entry: health_check defined once (formal entry)" || bad "P2-11 entry: health_check count=$n"

# ── 2) 统一三态 + 原因 + 延迟 + 目标（结果行格式）────────────────────────────
check_line() {   # <kind> <spec> → echo 状态行；失败回 3
    out=$(health_check "$1" "$2" 2>/dev/null) || true
    echo "$out"
}
assert_line() {   # <期望状态> <kind> <spec> → 校验状态 + reason + latency_ms + target
    exp=$1; kind=$2; spec=$3
    out=$(check_line "$kind" "$spec")
    st=$(echo "$out" | cut -d'|' -f1)
    [ "$st" = "$exp" ] && ok "P2-11 line: $kind [$spec] → $exp" || bad "P2-11 line: $kind [$spec] → $st (out=$out)"
    echo "$out" | grep -q "|reason=" && ok "P2-11 line: reason field present" || bad "P2-11 line: reason missing: $out"
    lat=$(echo "$out" | sed -n 's/.*|latency_ms=\([0-9][0-9]*\)|.*/\1/p')
    [ -n "$lat" ] && ok "P2-11 line: latency_ms numeric ($lat)" || bad "P2-11 line: latency missing/not-numeric: $out"
    tgt=$spec
    [ "$kind" = "port" ] && tgt="port:$spec"
    echo "$out" | grep -q "|target=$tgt" && ok "P2-11 line: target echoed" || bad "P2-11 line: target missing: $out"
}

# ── 3) Process Check ───────────────────────────────────────────────────────
assert_line HEALTHY process bash        # pidof bash（本测试宿主必有 bash）
assert_line HEALTHY process "$$"        # 本进程 PID → /proc/$$ 存在
assert_line UNHEALTHY process 99999999  # 不存在 PID
assert_line UNHEALTHY process no_such_proc_xyz_12345
assert_line UNKNOWN process "a b"       # 空格 → 安全门拒绝
assert_line UNKNOWN process "a;b"       # 元字符 → 拒绝
assert_line UNKNOWN process "-"         # 非空但结构非法（不以字母开头）

# ── 4) Port Check ─────────────────────────────────────────────────────────
assert_line UNKNOWN port 0
assert_line UNKNOWN port 70000
assert_line UNKNOWN port abc
assert_line UNHEALTHY port 1            # 端口 1 几乎不可能监听；若占用则下方修正
# 真实监听：nc 起 listener → HEALTHY
PORT=""
p=35000
while [ "$p" -lt 36000 ]; do
    hexp=$(printf '%04X' "$p")
    # awk 退出码：0=未监听（可用） 1=已监听（忙碌）
    if awk -v h="$hexp" '$4=="0A" && $2 ~ ":" h "$" { n++ } END { exit n>0 }' /proc/net/tcp 2>/dev/null; then
        PORT=$p; break
    fi
    p=$((p + 1))
done
if [ -n "$PORT" ] && command -v nc >/dev/null 2>&1; then
    nc -l 127.0.0.1 "$PORT" >/dev/null 2>&1 &
    NCPID=$!
    # 重试等待监听就绪（nc 绑定 /proc/net/tcp 可见有延迟）
    up=0
    i=0
    while [ "$i" -lt 10 ]; do
        out=$(check_line port "$PORT")
        st=$(echo "$out" | cut -d'|' -f1)
        [ "$st" = "HEALTHY" ] && { up=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$up" -eq 1 ] && echo "$out" | grep -q "reason=port-listening" && ok "P2-11 port: real listener on $PORT → HEALTHY(port-listening)" || bad "P2-11 port: listener HEALTHY failed: $out"
    kill "$NCPID" 2>/dev/null
    # 重试等待端口释放（kill 后 LISTEN 关闭可能滞后）
    closed=0
    i=0
    while [ "$i" -lt 10 ]; do
        out=$(check_line port "$PORT")
        st=$(echo "$out" | cut -d'|' -f1)
        [ "$st" = "UNHEALTHY" ] && { closed=1; break; }
        sleep 0.3; i=$((i + 1))
    done
    [ "$closed" -eq 1 ] && echo "$out" | grep -q "reason=port-not-listening" && ok "P2-11 port: listener stopped → UNHEALTHY(port-not-listening)" || bad "P2-11 port: post-close not UNHEALTHY: $out"
else
    ok "P2-11 port: listener tool (nc) unavailable — HEALTHY-listener case not exercised (UNHEALTHY/UNKNOWN covered)"
fi

# ── 5) 状态机门槛联动（P2-07 门打开）────────────────────────────────────────
state_health_allowed >/dev/null 2>&1
[ $? -eq 0 ] && ok "P2-11 gate: state_health_allowed=0 with process/port providers (P2-07 gate open)" || bad "P2-11 gate: health gate still closed"
HD="$T/health/run_t200_0000"
mkdir -p "$HD"
echo "RUNNING" > "$HD/state.txt"
state_log_event "$HD" run_t200_0000 supervisor HEALTHY >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(cat "$HD/state.txt" 2>/dev/null)" = "HEALTHY" ] && ok "P2-11 gate: RUNNING→HEALTHY writable (real health provider wired)" || bad "P2-11 gate: HEALTHY write failed (state=$(cat "$HD/state.txt" 2>/dev/null))"

# ── 6) dispatch 语义 ───────────────────────────────────────────────────────
provider_dispatch health process check "bash" >/dev/null 2>&1
[ $? -eq 0 ] && ok "P2-11 dispatch: provider_dispatch health process check → 0 (HEALTHY)" || bad "P2-11 dispatch: process check rc"
provider_dispatch health process check "99999999" >/dev/null 2>&1
[ $? -eq 1 ] && ok "P2-11 dispatch: process check missing → 1 (UNHEALTHY)" || bad "P2-11 dispatch: missing rc"
health_check >/dev/null 2>&1
[ $? -eq 3 ] && ok "P2-11 dispatch: health_check usage error → 3" || bad "P2-11 dispatch: usage rc"

# ── 7) POSIX ───────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-11 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §16)" || bad "P2-11 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-11 POSIX: bash -n ok (dash unavailable)" || bad "P2-11 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "health tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1