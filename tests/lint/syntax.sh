#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# syntax.sh — L1 静态语法层（P0 AGENTS §4.1 / T0 交付物）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖：
#   - `sh -n`    ：所有 `#!/system/bin/sh` 生产脚本（su-scheduler /
#                  su-schedulerd / su-scheduler-termux / service.sh /
#                  customize.sh）
#   - `bash -n`  ：build.sh、bump_version.sh
# 行尾无关性（P1-01 §1 基线）：仓库以 LF 存储；Windows core.autocrlf=true
#   检出为 CRLF，CRLF 下 `sh -n`/`bash -n` 会对全部脚本报 `\r` 语法错（实测）。
#   本层统一 `tr -d '\r'` 归一后检查——归一不改变基线语义（LF 为基准），
#   使 L1 在 CRLF 检出与 LF CI 下均可作为同一道语法门禁。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check_n() {   # $1=解释器(sh|bash)  $2=文件
    interp="$1"; file="$2"
    tr -d '\r' < "$file" > "$TMP/lf.tmp"
    if "$interp" -n "$TMP/lf.tmp" 2>"$TMP/err.tmp"; then
        ok "$interp -n $file"
    else
        bad "$interp -n $file"
        sed 's/^/    /' "$TMP/err.tmp" | head -4
    fi
}

# ── sh -n：所有 #!/system/bin/sh 生产脚本 ──────────────────────────────────
for f in \
    system/bin/su-scheduler \
    system/bin/su-schedulerd \
    system/bin/su-scheduler-termux \
    service.sh \
    customize.sh; do
    [ -f "$f" ] || { bad "missing script: $f"; continue; }
    grep -q '^#!.*sh' "$f" && check_n sh "$f" || bad "shebang not sh: $f"
done

# ── bash -n：构建/版本脚本 ────────────────────────────────────────────────
for f in build.sh bump_version.sh; do
    [ -f "$f" ] || { bad "missing script: $f"; continue; }
    check_n bash "$f"
done

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "lint tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1