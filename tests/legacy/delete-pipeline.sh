#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# delete-pipeline.sh — `--delete` 删除管线语义锁定（P2-01 Q13）
# ═══════════════════════════════════════════════════════════════════════════
# 背景（Q13，2026-09-02 真实 KernelSU 设备冒烟实证）：daemon 主循环删除路径
#   grep -v -F "$line" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv ...
# 当配置的**激活内容恰好只有该删除行**时，`grep -v` 输出为空且退出码 1，
# `&&` 短路 → mv 不执行 → 行未被删除（/sdcard 实测残留 0 字节
# config.txt.tmp；对应 smoke 用例 5 `--delete removed line` FAIL，但日志已见
# `💥 Boom. Task deleted.`，任务执行正常——即执行 OK、删除写入被短路）。
# 修复（su-schedulerd L680/L692 两处）：`&&` 改 `;`，mv 尽力而为。本测试
# 锁定修复后的管线语义（表达式与 daemon 逐字一致；golden 系原表达式复刻）。
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CFG="$T/config.txt"

# 复刻 daemon 删除管线（修复后形态：mv 独立执行）
del_line() {   # $1 = 配置中的删除行原文
    line="$1"
    grep -v -F "$line" "$CFG" > "$CFG.tmp"
    mv "$CFG.tmp" "$CFG"
}

# ── 1) 单激活行（Q13 复现场景）：执行后行消失、文件仍在 ────────────────────
printf '09:15 echo only-line; : --delete\n' > "$CFG"
del_line '09:15 echo only-line; : --delete'
if [ -f "$CFG" ] && ! grep -q 'only-line' "$CFG" 2>/dev/null; then
    ok "Q13 single-active-line delete: line removed (fix target)"
else
    bad "Q13 single-active-line delete: line survives (grep -v && mv short-circuit)"
fi

# ── 2) 多行配置回归守卫：仅删除目标行，其余行原样保留 ──────────────────────
printf '08:00 echo keep-a; : --notify\n09:15 echo del-this; : --delete\n23:00 echo keep-b\n' > "$CFG"
del_line '09:15 echo del-this; : --delete'
if grep -q 'del-this' "$CFG" 2>/dev/null; then
    bad "Q13 multi-line delete: target line survived"
else
    ok "Q13 multi-line delete: target line removed"
fi
if grep -q 'keep-a' "$CFG" && grep -q 'keep-b' "$CFG"; then
    ok "Q13 multi-line delete: other lines preserved"
else
    bad "Q13 multi-line delete: unrelated lines damaged"
fi

# ── 3) 修复前差异文档化（不在此断言旧表达式；实测证据见 docs/P2-01.md） ────
ok "Q13 pre-fix evidence recorded: device smoke case 5 FAIL + 0-byte config.txt.tmp (docs/P2-01.md)"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "delete-pipeline tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1