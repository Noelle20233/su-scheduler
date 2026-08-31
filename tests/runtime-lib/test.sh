#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — 生产 Runtime 库边界（P2-02）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-02 出口：daemon 与 CLI 加载同一套生产运行时原语）：
#   1) 生产库可加载（bash）：selfcheck + §1–§7 代表原语（state / provider /
#      action / registry / runtime / lifecycle / task-cli）——证明是**可加载的
#      生产原语集**，而非死代码拼接；
#   2) 路径隔离：生产库零引用 `tests/` 与 `../`；测试域零引用生产库路径；
#   3) 加载失败 fallback：缺失 / 不可读 / 语法破损 → RUNTIME_LOADED=0 且
#      无错误中止（legacy 路径继续）——镜像 daemon/CLI 加载块语义；
#   4) 接线存在性：daemon 与 CLI 均已含加载块（RUNTIME_LOADED 锚点）；
#   5) POSIX：库可在 dash 下通过语法检查（若宿主可用；否则 bash -n）。
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

# ── 1) 生产库可加载 + 代表原语 ──────────────────────────────────────────────
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
(
    . ./$RTLIB
    runtime_lib_selfcheck && echo "SELFCHECK_OK" || echo "SELFCHECK_FAIL"
) > "$T/selfcheck" 2>/dev/null
grep -q "SELFCHECK_OK" "$T/selfcheck" && ok "P2-02 lib loads + selfcheck ok (v$(sed -n 's/^RUNTIME_LIB_VERSION="\(.*\)"/\1/p' $RTLIB))" || bad "P2-02 lib selfcheck failed"

# §1 state
out=$(TSM_LOG=0 bash -c ". ./$RTLIB; task_state_transition PENDING STARTING time_trigger; echo rc=\$?")
grep -q 'rc=0' <<< "$out" && ok "P2-02 state: PENDING->STARTING allowed" || bad "P2-02 state transition"
out=$(TSM_LOG=0 bash -c ". ./$RTLIB; task_state_transition RUNNING RUNNING xx; echo rc=\$?")
grep -q 'rc=1' <<< "$out" && ok "P2-02 state: RUNNING->RUNNING rejected" || bad "P2-02 illegal transition"

# §3 provider (boot trigger)
out=$(TPR_LOG=0 bash -c ". ./$RTLIB; TRIGGER_BOOT_CONTEXT=1 provider_dispatch trigger boot matches; echo rc=\$?")
grep -q 'rc=0' <<< "$out" && ok "P2-02 provider: trigger>boot matches in boot context" || bad "P2-02 provider boot"

# §3 provider (action command end-to-end)
out=$(TPR_LOG=0 bash -c "
    . ./$RTLIB
    export TPR_ACTION_DIR=\"$T/acts\"
    d=\$(TPR_LOG=0 provider_dispatch action command prepare t1 'echo p2-02-ok')
    TPR_LOG=0 provider_dispatch action command start t1 'echo p2-02-ok' > \"$T/acts/t1.pid\" 2>/dev/null
    i=0; while [ \"\$i\" -lt 20 ] && [ ! -f \"\$d/exit_code.txt\" ]; do sleep 0.3; i=\$((i+1)); done
    cat \"\$d/status.txt\"
")
grep -q 'SUCCESS' <<< "$out" && ok "P2-02 action: command -> SUCCESS (artifacts)" || bad "P2-02 action command"

# §5 registry (17 tasks from legacy fixture + KEPT fallback)
out=$(TR_LOGGING=0 bash -c "
    . ./$RTLIB
    TR_LOGGING=0 registry_init \"$T/reg\" \"$PWD/tests/fixtures/legacy/config.txt\" >/dev/null 2>&1
    registry_task_ids | wc -l
")
[ "$out" -eq 17 ] && ok "P2-02 registry: legacy fixture -> 17 tasks" || bad "P2-02 registry count=$out"
# 无效配置 = 触发含控制字符 → adapter rc1 + 0 任务 → registry 判定无效 → KEPT
printf '08\x01:30 x\n23\x02:00 y\n' > "$T/bad.cfg"
out=$(TR_LOGGING=0 bash -c "
    . ./$RTLIB
    TR_LOGGING=0 registry_init \"$T/reg\" \"$PWD/tests/fixtures/legacy/config.txt\" >/dev/null 2>&1
    TR_LOGGING=0 registry_reload \"$T/bad.cfg\" >/dev/null 2>&1; rc=\$?
    echo rc=\$rc ids=\$(registry_task_ids | wc -l)
")
grep -q 'rc=1 ids=17' <<< "$out" && ok "P2-02 registry: invalid reload -> KEPT (17 tasks survive)" || bad "P2-02 registry fallback: $out"

# §4 runtime state/event
out=$(RT_LOG=0 bash -c "
    . ./$RTLIB
    RT_LOG=0 runtime_log_event \"$T/rt\" t1 spawn PENDING 0 0 created
    runtime_current_state \"$T/rt\"
")
grep -q 'PENDING' <<< "$out" && ok "P2-02 runtime: log_event + current_state" || bad "P2-02 runtime event"

# §6 lifecycle lock
out=$(LIFECYCLE_LOG=0 bash -c "
    . ./$RTLIB
    LIFECYCLE_LOG=0 lifecycle_lock_acquire \"$T/lock\" && echo first-ok
    LIFECYCLE_LOG=0 lifecycle_lock_acquire \"$T/lock\" && echo second-ok || echo second-rejected
    rm -f \"$T/lock\"
")
grep -q 'first-ok' <<< "$out" && grep -q 'second-rejected' <<< "$out" && ok "P2-02 lifecycle: single-instance lock" || bad "P2-02 lifecycle lock"

# §7 task-cli (list rows from registry)
out=$(TASK_CLI_LOG=0 TASK_CLI_TASKS_DIR="" bash -c "
    . ./$RTLIB
    TR_LOGGING=0 registry_init \"$T/reg2\" \"$PWD/tests/fixtures/legacy/config.txt\" >/dev/null 2>&1
    TASK_CLI_TASKS_DIR=\"\" task_cli_list 2>/dev/null | wc -l
")
[ "$out" -eq 17 ] && ok "P2-02 task-cli: list emits 17 rows from registry snapshot" || bad "P2-02 task-cli rows=$out"

# ── 2) 路径隔离 ────────────────────────────────────────────────────────────
if grep -qE 'tests/|\.\./' $RTLIB; then
    bad "P2-02 path separation: production lib references tests/ or ../"
else
    ok "P2-02 path separation: production lib has no tests/ or ../ references"
fi
# 任何 tests/ 脚本（除本套件自身）不得**加载**生产库路径——包括加载与引用。
# 语义分清：**引用**（lint/build_check 把该路径纳入 L1 覆盖与 zip 成员校验——
# 是合法接线，不构成混用）与 **加载**（任何 `. source` 生产库作测试库）不同。
# 门禁只禁止「加载」：tests/ 下任何 `. ` 行指向生产库即 FAIL。
if grep -rn 'su-scheduler-runtime' tests/ --include='*.sh' 2>/dev/null \
   | grep -E '\. [^#]*su-scheduler-runtime|[[:space:]]source[[:space:]]+su-scheduler-runtime' \
   | grep -v 'tests/runtime-lib/test.sh' | grep -q .; then
    bad "P2-02 path separation: a test script loads $RTLIB as its library (path mixing)"
else
    ok "P2-02 path separation: no test script sources the production lib (refs in lint/build_check are coverage wiring, allowed)"
fi

# ── 3) 加载失败 fallback（镜像 daemon/CLI 加载块表达式）────────────────────
try_load() {   # $1=库路径 → echo RUNTIME_LOADED=0|1
    RUNTIME_LIB=$1
    RUNTIME_LOADED=0
    if [ -f "$RUNTIME_LIB" ] && [ -r "$RUNTIME_LIB" ]; then
        . "$RUNTIME_LIB" 2>/dev/null && RUNTIME_LOADED=1 || RUNTIME_LOADED=0
    fi
    if [ "$RUNTIME_LOADED" -eq 1 ] && ! runtime_lib_selfcheck >/dev/null 2>&1; then
        RUNTIME_LOADED=0
    fi
    echo "RUNTIME_LOADED=$RUNTIME_LOADED"
}
out=$(try_load "$T/no-such-runtime-lib")
grep -q 'RUNTIME_LOADED=0' <<< "$out" && ok "P2-02 fallback: missing lib -> RUNTIME_LOADED=0 (no abort)" || bad "P2-02 fallback missing: $out"
printf 'if ; then\n' > "$T/broken-lib"
out=$(try_load "$T/broken-lib")
grep -q 'RUNTIME_LOADED=0' <<< "$out" && ok "P2-02 fallback: syntax-broken lib -> RUNTIME_LOADED=0 (legacy continues)" || bad "P2-02 fallback broken: $out"
out=$(try_load "$PWD/$RTLIB")
grep -q 'RUNTIME_LOADED=1' <<< "$out" && ok "P2-02 fallback: valid lib -> RUNTIME_LOADED=1" || bad "P2-02 fallback valid: $out"

# ── 4) 接线存在性（P2-02 出口：daemon + CLI 同一套原语加载钩子）────────────
for f in "$DAEMON" "$CLI"; do
    if grep -q 'RUNTIME_LOADED' "$f"; then
        ok "P2-02 wiring: $(basename "$f") contains runtime loader (RUNTIME_LOADED)"
    else
        bad "P2-02 wiring: $(basename "$f") missing runtime loader"
    fi
    if grep -q '/system/bin/su-scheduler-runtime' "$f"; then
        ok "P2-02 wiring: $(basename "$f") points to production lib path"
    else
        bad "P2-02 wiring: $(basename "$f") no RUNTIME_LIB path"
    fi
done

# ── 5) POSIX（dash 可用时 dash -n；否则 bash -n）────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P2-02 POSIX: dash -n ok (no local/[[ ]] bash-isms in lib)" || bad "P2-02 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" && ok "P2-02 POSIX: bash -n ok (dash unavailable on host)" || bad "P2-02 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "runtime-lib tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1