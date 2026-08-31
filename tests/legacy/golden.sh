#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# golden.sh — L2 legacy 解析 golden 锁定（P0 T1 / R-02..R-07 自动化）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 机制（tests/fixtures/legacy/README.md「推导方法」）：
#   goldens 不是手写的——由 tests/fixtures/legacy/tools/derive-goldens.sh
#   从生产 daemon（system/bin/su-schedulerd）按注释标记切出真实
#   parse_modifiers/extract_command 原函数并执行 fixture 后生成。
#   本层=「复现 + 比对」：重新推导，然后与仓库已登记的 expected/*.txt
#   逐字节比对；任何差异（=生产解析语义漂移/被破坏）立即 [FAIL]。
# 另断言 fixtures 输入本身不可变（config.txt / config.example.txt 不得被
# 改——它们是 T1 golden 的不可变输入）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

LEGACY="tests/fixtures/legacy"

# ── 1) 输入不可变：fixtures 不得相对 HEAD 有内容差异 ──────────────────────
if git diff --quiet -- "$LEGACY/config.txt" "$LEGACY/config.example.txt"; then
    ok "fixtures immutable (config.txt / config.example.txt == HEAD)"
else
    bad "fixtures changed vs HEAD (immutability violated)"
    git diff --stat -- "$LEGACY/config.txt" "$LEGACY/config.example.txt" | sed 's/^/    /' | head -5
fi

# ── 2) golden 文件齐备 ─────────────────────────────────────────────────────
missing=0
for g in parse_modifiers.txt extract_command.txt heredoc-reconstruction.txt \
         run-once-now-prune.txt state-keys.txt; do
    [ -f "$LEGACY/expected/$g" ] && ok "golden present: $g" || { bad "golden missing: $g"; missing=1; }
done
[ "$missing" -eq 1 ] && { echo "cannot verify without goldens"; exit 1; }

# ── 3) 复现 + 比对：重新推导，与登记 golden 逐字节一致 ────────────────────
if bash "$LEGACY/tools/derive-goldens.sh" > /dev/null 2>&1; then
    ok "derive-goldens.sh re-derived (real daemon functions)"
else
    bad "derive-goldens.sh failed to derive"
    bash "$LEGACY/tools/derive-goldens.sh" 2>&1 | sed 's/^/    /' | head -5
fi

if git diff --exit-code -- "$LEGACY/expected/" > /tmp/ss-golden.diff 2>&1; then
    ok "derived output == registered goldens (parse semantics locked)"
else
    bad "derived output differs from registered goldens (semantics drifted)"
    sed 's/^/    /' /tmp/ss-golden.diff | head -40
fi
rm -f /tmp/ss-golden.diff

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "legacy golden tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1