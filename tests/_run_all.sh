#!/usr/bin/env bash
# ═══ P2-01 兼容保留 ═══
# 本脚本已被 tests/run_tests.sh（唯一统一入口：L1+L2+L4，可选 L3）取代，
# 保留仅为既有 P1 入口兼容；新任务/CI 一律使用 tests/run_tests.sh。
# 全量回归（P1 五套）：全部 [PASS] 无 [FAIL] 且 exit 0 才算绿。
set -u
cd "$(dirname "$0")/.." || exit 2
ok=1
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
    "tests/p1-regression/test.sh"; do
    echo "== $suite =="
    out=$(bash "$suite" 2>&1)
    rc=$?
    fails=$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)
    last=$(printf '%s\n' "$out" | tail -1)
    echo "$last"
    if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
        ok=0
        printf '%s\n' "$out" | grep '\[FAIL\]' | head -20
    fi
done
[ "$ok" -eq 1 ] && echo "ALL SUITES GREEN" || echo "FAILURES PRESENT"
exit $((1 - ok))