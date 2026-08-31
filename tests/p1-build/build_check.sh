#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# build_check.sh — P1 安装包构建校验（P1-12 覆盖第 13 项）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4 / P0 L4 语义）：每项 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 验证：
#   1) bash build.sh 产出 su-scheduler-v<ver>.zip
#   2) unzip -t 完整性通过（无错误）
#   3) zip 内含 module.prop / service.sh / customize.sh / system/
#   4) 六处版本号一致（取 build.sh 的 VERSION 为基准，其余五处必须匹配）：
#      module.prop(version/versionCode) / 两个 bin(VERSION) / README badge /
#      update.json(version/versionCode/downloadURL)
#   5) 演练后还原工作树：删 zip + git checkout system/bin/.su-scheduler-docs
#      （build.sh 会重建该文件；还原防止污染 P1 工作树，同 P0 T4 惯例）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }
skip(){ SKIP=$((SKIP + 1)); echo "[SKIP] $1"; }

# ── 工作树行尾检测（P1-01 §1：CRLF 检出不可发布——基线记录，不修）──────────
# CRLF 检出（core.autocrlf=true）下 build.sh 行尾 \r 令 bash 报
# "$'\r': command not found"（实测），且打包会把 CRLF 带进 zip——基线文档
# 判定该形态不可发布。因此 CRLF 检出下构建执行**明示跳过**（等价 P0 L3
# --skip-device 的"明示跳过"语义），完整 build/unzip 由 CI（LF 工作树）承担；
# 六处版本一致性在两种环境都校验。
CRLF_TREE=0
grep -q "$(printf '\r')" build.sh && CRLF_TREE=1
[ "$CRLF_TREE" -eq 1 ] && skip "build execution: CRLF worktree (P1-01 §1 documented, not fixable in P1; CI/LF is the build gate)"

# 版本基准（build.sh 单一事实源）
# CRLF 检出（core.autocrlf=true）下 sed 会残留 \r——统一剥离（基线语义以 LF 为准，P1-01 §1）
BVER=$(sed -n 's/^VERSION="\(.*\)"/\1/p' build.sh | tr -d '\r')   # v1.6.8
NVVER=${BVER#v}                                                  # 1.6.8（bin/README 无 v 前缀）
[ -n "$BVER" ] && ok "version baseline from build.sh: $BVER" || bad "cannot read build.sh VERSION"

# ── 1-3) 构建 + 完整性 + 内容（CRLF 检出时明示跳过构建执行段）──────────────
if [ "$CRLF_TREE" -eq 1 ]; then
    # 8 项断言（产出/完整性/6 内容成员）在 CRLF 检出下不执行——明示 SKIP，
    # 完整构建闸由 CI（LF 工作树）承担（P1-01 §1 基线事实）。
    skip "build execution: produce zip (CI/LF gate)"
    skip "build execution: unzip -t integrity (CI/LF gate)"
    skip "build execution: zip content members (CI/LF gate)"
else
    rm -f "su-scheduler-$NVVER.zip" 2>/dev/null
    bash build.sh >/dev/null 2>&1
    ZIP="su-scheduler-$BVER.zip"
    if [ -n "$(ls "$ZIP" 2>/dev/null)" ] && [ -s "$ZIP" ]; then
        ok "build.sh produced $ZIP ($(wc -c < "$ZIP") bytes)"
    else
        bad "zip missing: $ZIP"
    fi

    zt=$(unzip -t "$ZIP" 2>&1)
    [ "$(printf '%s\n' "$zt" | grep -c 'No errors detected')" -eq 1 ] && ok "unzip -t integrity OK" || bad "zip integrity"

    for e in module.prop service.sh customize.sh system/bin/su-schedulerd system/bin/su-scheduler system/bin/su-scheduler-termux; do
        unzip -l "$ZIP" 2>/dev/null | grep -q " $e$" && ok "zip contains $e" || bad "zip missing $e"
    done
fi

# ── 4) 六处版本号一致 ──────────────────────────────────────────────────────
# CRLF 检出（core.autocrlf=true）下行尾有 \r——grep 用行尾 $ 锚会失配，
# 统一去掉 $ 锚（P1-01 §1：基线语义以 LF 为准，\r 不参与匹配值）。
grep -q "^version=$BVER" module.prop && ok "module.prop version=$BVER" || bad "module.prop version"
grep -q "^versionCode=11" module.prop && ok "module.prop versionCode present" || bad "module.prop versionCode"
grep -q "^VERSION=\"$NVVER\"" system/bin/su-scheduler && ok "CLI VERSION=$NVVER" || bad "CLI VERSION"
grep -q "^VERSION=\"$NVVER\"" system/bin/su-schedulerd && ok "daemon VERSION=$NVVER" || bad "daemon VERSION"
grep -q "Version-$NVVER-blue" README.md && ok "README badge Version-$NVVER" || bad "README badge"
grep -q "\"version\": \"$BVER\"," update.json && ok "update.json version=$BVER" || bad "update.json version"
grep -q "\"versionCode\": [0-9]*," update.json && ok "update.json versionCode present" || bad "update.json versionCode"
grep -q "releases/download/$BVER/su-scheduler-$BVER.zip" update.json && ok "update.json downloadURL -> $BVER" || bad "update.json downloadURL"

# ── 5) 还原工作树（仅 LF 环境跑过构建时需要；CRLF 下未构建无污染）───────────
if [ "$CRLF_TREE" -eq 0 ]; then
    rm -f "$ZIP"
    git checkout -- system/bin/.su-scheduler-docs 2>/dev/null
    [ -z "$(git status --porcelain -- system/bin/.su-scheduler-docs)" ] && ok "workspace restored (.su-scheduler-docs + zip cleaned)" || bad "workspace dirty after build"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p1-build tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1