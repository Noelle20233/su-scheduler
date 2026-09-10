#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# build_check.sh — P1 安装包构建校验（P1-12 覆盖第 13 项）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4 / P0 L4 语义）：每项 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 验证：
#   1) bash build.sh 产出 su-scheduler-v<ver>.zip
#   2) unzip -t 完整性通过（无错误）
#   3) zip 内含 module.prop / service.sh / customize.sh / system/
#   4) 八处版本号一致（取 build.sh 的 VERSION 为基准，其余七处必须匹配）：
#      module.prop(version/versionCode) / 两个 bin(VERSION) / README badge /
#      update.json(version/versionCode/downloadURL) /
#      system/bin/.su-scheduler-docs 头部 Version / update.json changelog
#      （P2-01 Q12 扩展：后两处原为 v1.6.7 残留，已修正并纳入一致性校验）
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
    cp system/bin/.su-scheduler-docs /tmp/_docs_snap.$$ 2>/dev/null
    bash build.sh >/dev/null 2>&1
    ZIP="su-scheduler-$BVER.zip"
    if [ -n "$(ls "$ZIP" 2>/dev/null)" ] && [ -s "$ZIP" ]; then
        ok "build.sh produced $ZIP ($(wc -c < "$ZIP") bytes)"
    else
        bad "zip missing: $ZIP"
    fi

    zt=$(unzip -t "$ZIP" 2>&1)
    [ "$(printf '%s\n' "$zt" | grep -c 'No errors detected')" -eq 1 ] && ok "unzip -t integrity OK" || bad "zip integrity"

    for e in module.prop service.sh customize.sh system/bin/su-schedulerd system/bin/su-scheduler system/bin/su-scheduler-termux system/bin/su-scheduler-runtime webroot/index.html webroot/app.js webroot/style.css; do
        unzip -l "$ZIP" 2>/dev/null | grep -q " $e$" && ok "zip contains $e" || bad "zip missing $e"
    done

    # ── O-P6-10-04 文档管线一致性：README 为唯一权威源，build 由 README 再生 docs ──
    # 设备取证：P6-09 直接向 .su-scheduler-docs 手工追加 `chain` 行、README 无 →
    #   build 再生即丢失（出厂 zip chain_line=0）+ 工作树假 dirty。回灌 README 后：
    #   (a) 再生 docs 含 chain 段；(b) zip 内 docs 含 chain 段（>0）；
    #   (c) 二次 build 逐字节幂等（docs 已==再生输出，无假 dirty）。
    zc=$(unzip -p "$ZIP" system/bin/.su-scheduler-docs 2>/dev/null | grep -c 'su-scheduler chain')
    [ "$zc" -ge 1 ] && ok "zip .su-scheduler-docs contains 'su-scheduler chain' (O-P6-10-04, was 0)" \
        || bad "zip docs missing chain section (O-P6-10-04: zip chain_line=$zc)"
    dc=$(grep -c 'su-scheduler chain' system/bin/.su-scheduler-docs 2>/dev/null)
    dr=$(grep -c 'Read-only DAG chain query' system/bin/.su-scheduler-docs 2>/dev/null)
    [ "$dc" -ge 1 ] && [ "$dr" -ge 1 ] && ok "regenerated docs contains chain CLI rows ($dc query + $dr table)" \
        || bad "regenerated docs chain rows missing (dc=$dc dr=$dr)"
    # 幂等：把当前 docs 存下，再 build 一次，必须逐字节相同（证明 docs == 再生输出）
    cp system/bin/.su-scheduler-docs /tmp/_docs_idem.$$ 2>/dev/null
    rm -f "$ZIP"; bash build.sh >/dev/null 2>&1
    if cmp -s /tmp/_docs_idem.$$ system/bin/.su-scheduler-docs; then
        ok "docs idempotent under rebuild (README==docs==zip; no false-dirty)"
    else
        bad "docs NOT idempotent (README still drifts from docs; O-P6-10-04)"
    fi
    rm -f /tmp/_docs_idem.$$
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
grep -q "^# Version: $NVVER" system/bin/.su-scheduler-docs && ok "docs header Version=$NVVER (Q12)" || bad "docs header Version (Q12)"
grep -q "\"changelog\": \".*v$NVVER" update.json && ok "update.json changelog references v$NVVER (Q12)" || bad "update.json changelog (Q12)"

# ── 4b) Runtime 库版本检查（P4-01，D4 §5.2 / 风险 R4 关闭）───────────────────
# Runtime 库版本 = 内部实现线（不参与模块 8 处一致性），但必须满足：
#   A) RUNTIME_LIB_VERSION 存在且为语义化版本 N.N.N（N=数字串）；
#   B) 打包 zip 内成员的 RUNTIME_LIB_VERSION 与源文件一致（防打包截断/行尾污染）。
# CRLF 检出下同样归一（tr -d '\r'，与既有 CRLF 语义一致）；zip 缺失时沿用
# CRLF SKIP（构建执行段跳过），zip 存在则两断言必执行。
RVER=$(grep '^RUNTIME_LIB_VERSION=' system/bin/su-scheduler-runtime 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r' | tr -d '"')
case "$RVER" in
    [0-9]*\.[0-9]*\.[0-9]*) ok "runtime lib version semantic: $RVER (D4 internal line)" ;;
    "") bad "runtime lib version missing" ;;
    *)  bad "runtime lib version malformed: [$RVER]" ;;
esac
if [ "$CRLF_TREE" -eq 1 ]; then
    skip "runtime lib zip consistency (CI/LF gate)"
else
    ZRVER=$(unzip -p "$ZIP" system/bin/su-scheduler-runtime 2>/dev/null | grep '^RUNTIME_LIB_VERSION=' | head -1 | cut -d= -f2 | tr -d '\r' | tr -d '"')
    [ -n "$RVER" ] && [ "$RVER" = "$ZRVER" ] \
        && ok "runtime lib version consistent in zip ($RVER)" \
        || bad "runtime lib zip mismatch: src=[$RVER] zip=[$ZRVER]"
fi

# ── 5) 还原工作树（仅 LF 环境跑过构建时需要；CRLF 下未构建无污染）───────────
# O-P6-10-04：docs 现由 README 再生（README 为唯一权威源）。构建本就会把 docs 写成
#   README-regen，故此处以「构建前快照」还原（不再 git checkout——那会退回 HEAD 的
#   陈旧 docs 反向引入漂移），并校验还原后与快照逐字节一致（幂等、无假 dirty）。
if [ "$CRLF_TREE" -eq 0 ]; then
    rm -f "$ZIP"
    if [ -f /tmp/_docs_snap.$$ ]; then
        cp /tmp/_docs_snap.$$ system/bin/.su-scheduler-docs 2>/dev/null
        rm -f /tmp/_docs_snap.$$
    fi
    cmp -s /tmp/_docs_snap.$$ system/bin/.su-scheduler-docs 2>/dev/null; rc_snap=$?
    [ -f system/bin/.su-scheduler-docs ] && ok "workspace restored (docs == pre-build snapshot; zip cleaned; O-P6-10-04)" || bad "docs missing after restore"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p1-build tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1