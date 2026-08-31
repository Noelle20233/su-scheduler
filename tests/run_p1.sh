#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# run_p1.sh — P1 出口回归入口（P1-12）
# ═══════════════════════════════════════════════════════════════════════════
# 串行运行：
#   9 套既有 P1 套件（state-machine / providers / legacy-adapter /
#     task-registry / trigger-decision / action-run / runtime / lifecycle /
#     task-cli）
#   + tests/p1-regression/test.sh（P1-12 12 项跨层集成回归）
#   + tests/p1-build/build_check.sh（第 13 项：安装包构建校验；CRLF 检出下
#     构建执行明示 [SKIP]，版本六处一致照常校验）
# 可选 --with-device：追加 tests/p1-device/smoke.sh（真实 Android 冒烟；
#   无 adb/设备时明示 DEVICE_SKIPPED，不计失败）。
# 判定（AGENTS §4）：输出中不得出现 [FAIL]；全部套件通过则 exit 0。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/.." || exit 2   # 仓库根

WITH_DEVICE=0
[ "${1:-}" = "--with-device" ] && WITH_DEVICE=1

ok=1
run_suite() {   # <path>：捕获输出，判 [FAIL] 计数与退出码
    echo "== $1 =="
    out=$(bash "$1" 2>&1)
    rc=$?
    fails=$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)
    printf '%s\n' "$out" | tail -1
    if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
        ok=0
        printf '%s\n' "$out" | grep '\[FAIL\]' | head -10
    fi
}

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
    "tests/p1-regression/test.sh" \
    "tests/p1-build/build_check.sh"; do
    run_suite "$suite"
done

if [ "$WITH_DEVICE" -eq 1 ]; then
    run_suite "tests/p1-device/smoke.sh"
fi

echo "──────────────────────────────────────────────────────────────────────"
if [ "$ok" -eq 1 ]; then
    echo "P1 ALL SUITES GREEN (host regression + build-check; device optional: see p1-device)"
else
    echo "P1 FAILURES PRESENT"
fi
[ "$ok" -eq 1 ] && exit 0 || exit 1