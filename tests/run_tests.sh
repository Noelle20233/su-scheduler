#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# run_tests.sh — P0/P1 统一回归入口（P2-01 收口：唯一回归入口）
# ═══════════════════════════════════════════════════════════════════════════
# 串行运行（AGENTS §4 层级）：
#   L1  tests/lint/syntax.sh            静态语法（sh -n / bash -n，LF 归一）
#   L2  tests/legacy/golden.sh          T1 解析 golden 锁定（复现+比对）
#   L2  tests/cli/test.sh               CLI 行为（Q1/Q2/Q3/Q4/Q9 门禁）
#   L2  tests/state-machine/test.sh     P1 状态机（183 断言）
#   L2  tests/providers/test.sh         P1 Provider（136 断言）
#   L2  tests/legacy-adapter/test.sh    P1 legacy adapter（107 断言）
#   L2  tests/task-registry/test.sh     P1 registry（44 断言）
#   L2  tests/scheduling/trigger-decision/test.sh  P1 触发决策（39 断言）
#   L2  tests/execution/action-run/test.sh         P1 执行（24 断言）
#   L2  tests/runtime/test.sh           P1 运行时状态/事件（45 断言）
#   L2  tests/lifecycle/test.sh         P1 生命周期（56 断言）
#   L2  tests/task-cli/test.sh          P1 只读 CLI（39 断言）
#   L2  tests/runtime-lib/test.sh       P2-02 生产 Runtime 库边界（21 断言）
#   L2  tests/p1-regression/test.sh     P1 跨层集成（44 断言）
#   L4  tests/p1-build/build_check.sh   构建+八处版本一致性
# 可选 L3：--with-device 追加 tests/p1-device/smoke.sh（真实 Android 冒烟；
#   无 adb/设备时明示 DEVICE_SKIPPED 不计失败）。
# 判定（AGENTS §4）：输出不得出现 [FAIL]；全部通过 → exit 0。
# 可追溯（P2-01 出口）：完整逐层输出落盘
#   tests/results/run_tests-<时间戳>.log（*.log 已被 .gitignore 忽略，
#   不污染工作树），结尾打印日志路径与逐层汇总。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/.." || exit 2   # 仓库根

WITH_DEVICE=0
LINT_ONLY=0
case "${1:-}" in
    --with-device) WITH_DEVICE=1 ;;
    --lint-only)   LINT_ONLY=1 ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="tests/results"
mkdir -p "$RESULT_DIR"
LOG="$RESULT_DIR/run_tests-$TS.log"
: > "$LOG"

ok=1
run_suite() {   # <path>：捕获输出，判 [FAIL] 计数与退出码；全量入 trace 日志
    echo "== $1 ==" | tee -a "$LOG"
    out=$(bash "$1" 2>&1)
    rc=$?
    fails=$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)
    printf '%s\n' "$out" | tail -1 | tee -a "$LOG"
    printf '%s\n' "$out" >> "$LOG"
    if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
        ok=0
        printf '%s\n' "$out" | grep '\[FAIL\]' | head -10 | tee -a "$LOG"
    fi
    echo "" >> "$LOG"
}

if [ "$LINT_ONLY" -eq 1 ]; then
    run_suite "tests/lint/syntax.sh"
else
    run_suite "tests/lint/syntax.sh"
    run_suite "tests/legacy/golden.sh"
    run_suite "tests/legacy/delete-pipeline.sh"
    run_suite "tests/cli/test.sh"
    for suite in \
        "tests/state-machine/test.sh" \
        "tests/providers/test.sh" \
        "tests/legacy-adapter/test.sh" \
        "tests/task-registry/test.sh" \
        "tests/scheduling/trigger-decision/test.sh" \
        "tests/execution/action-run/test.sh" \
        "tests/runtime/test.sh" \
        "tests/lifecycle/test.sh" \
        "tests/task-cli/test.sh" \
        "tests/runtime-lib/test.sh" \
        "tests/shadow/test.sh" \
        "tests/idmap/test.sh" \
        "tests/p1-regression/test.sh" \
        "tests/p1-build/build_check.sh"; do
        run_suite "$suite"
    done
    if [ "$WITH_DEVICE" -eq 1 ]; then
        run_suite "tests/p1-device/smoke.sh"
    fi
fi

echo "──────────────────────────────────────────────────────────────────────"
if [ "$ok" -eq 1 ]; then
    echo "ALL SUITES GREEN (L1+L2+L4 host regression; device optional: see p1-device)"
else
    echo "FAILURES PRESENT"
fi
echo "trace log: $LOG"
[ "$ok" -eq 1 ] && exit 0 || exit 1