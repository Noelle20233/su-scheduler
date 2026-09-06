#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P5-02 Condition 运算符扩展语法冻结（tests/p5-condition）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P5-02 交付，docs/P5-02.md §6；语法决策 docs/P5-02.md §3/§4 与
#   docs/architecture/dependency-schema.md D38–D40）：
#   §fixtures       三个 fixtures 存在且非空；positive-p5.txt 非空行 ≥ 8；
#                   negative.txt 断言行数 ≥ 20；
#   §positive       positive.txt（既有 ==/!= 合法形态）全部经 cond_grammar_ok 通过
#                   （P4-06 合法形态不回归）；
#   §negative       negative.txt（非法形态全集：注入/类型越界/运算符误用/未授权/
#                   未知谓词/未包裹/空 id/非法 STATE）全部经 cond_grammar_ok 拒绝，
#                   行尾 `  # 理由` 注释由本脚本剥离后断言；
#   §boundary       cond_eval 对 negative.txt 前 5 条返回 rc=2（运行期非法防御）；
#                   COND_MAX_LEN 边界：256 字符通过 / 257 字符被 cond_validate 拒绝
#                   （参照 p4-dependency cond-max 用例）；
#   §pos5-notactive positive-p5.txt（P5-03 实现目标登记）当前被 cond_grammar_ok
#                   拒绝——生产未实现新运算符，这是预期，如实记录为 P5-03 反转点；
#                   若某行当前意外通过 → FAIL。
# 本套件**零生产改动**：只读 source Runtime 库（`. ./$RTLIB`，TCFG_DIR 先 export
#   隔离，同 p4-dependency/test.sh），只调用纯函数 cond_grammar_ok/cond_validate/
#   cond_eval（文法校验无副作用，不写文件、不读任务状态）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TCFG_DIR="$T/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
. ./$RTLIB

FIX="tests/p5-condition/fixtures"
POS="$FIX/positive.txt"
NEG="$FIX/negative.txt"
P5POS="$FIX/positive-p5.txt"

# 剥离行尾注释（`  # 理由`）并去尾空白：<line> → echo expr
strip_comment() {
    sc=$1
    sc=${sc%%#*}
    while :; do
        case "$sc" in
            *' ') sc=${sc%?} ;;
            *) break ;;
        esac
    done
    echo "$sc"
}

# ── §fixtures：文件存在、非空、行数门槛 ─────────────────────────────────
for f in positive.txt negative.txt positive-p5.txt; do
    if [ -s "$FIX/$f" ]; then
        ok "P5-02 fixtures: $f exists and non-empty"
    else
        bad "P5-02 fixtures: $f missing or empty"
    fi
done
P5POS_N=$(grep -vc '^$' "$P5POS")
[ "$P5POS_N" -ge 8 ] \
    && ok "P5-02 fixtures: positive-p5.txt has $P5POS_N non-empty lines (>=8)" \
    || bad "P5-02 fixtures: positive-p5.txt has $P5POS_N non-empty lines (<8)"
NEG_N=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    e=$(strip_comment "$line")
    [ -n "$e" ] || continue
    NEG_N=$((NEG_N + 1))
done < "$NEG"
[ "$NEG_N" -ge 20 ] \
    && ok "P5-02 fixtures: negative.txt has $NEG_N assertion lines (>=20)" \
    || bad "P5-02 fixtures: negative.txt has $NEG_N assertion lines (<20)"

# ── §positive：既有 ==/!= 合法形态必须仍被接受（不回归）──────────────────
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if cond_grammar_ok "$line"; then
        ok "P5-02 positive: accepted '$line'"
    else
        bad "P5-02 positive: REJECTED '$line' (regression vs P4-06)"
    fi
done < "$POS"

# ── §negative：非法形态全集必须被拒绝（剥离注释后逐条断言）──────────────
while IFS= read -r line; do
    [ -n "$line" ] || continue
    e=$(strip_comment "$line")
    [ -n "$e" ] || continue
    if cond_grammar_ok "$e"; then
        bad "P5-02 negative: ACCEPTED '$e' (must reject; fixture: $line)"
    else
        ok "P5-02 negative: rejected '$e'"
    fi
done < "$NEG"

# ── §boundary：运行期非法防御 + COND_MAX_LEN 存储层边界 ─────────────────
# cond_eval 对 negative.txt 前 5 条返回 rc=2（非法，防御性视为「不满足」）
BN=0
EVAL_N=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    e=$(strip_comment "$line")
    [ -n "$e" ] || continue
    BN=$((BN + 1))
    [ "$BN" -gt 5 ] && break
    EVAL_N=$((EVAL_N + 1))
    cond_eval "$e" "$TASKS_DIR" "0800" "0" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "P5-02 boundary: cond_eval rc=2 (illegal) for '$e'"
    else
        bad "P5-02 boundary: cond_eval rc=$rc (want 2) for '$e'"
    fi
done < "$NEG"
[ "$EVAL_N" -ge 5 ] \
    && ok "P5-02 boundary: evaluated first $EVAL_N negative fixtures via cond_eval" \
    || bad "P5-02 boundary: only $EVAL_N negative fixtures available (<5)"

# COND_MAX_LEN=256 存储层边界（cond_validate，参照 p4-dependency §cond）
LONG=""; i=0; while [ "$i" -lt 256 ]; do LONG="${LONG}a"; i=$((i + 1)); done
cond_validate "$LONG" \
    && ok "P5-02 boundary: cond_validate 256 chars accepted (== COND_MAX_LEN)" \
    || bad "P5-02 boundary: cond_validate 256 chars rejected"
LONG257="${LONG}b"
cond_validate "$LONG257" \
    && bad "P5-02 boundary: cond_validate 257 chars accepted (must reject)" \
    || ok "P5-02 boundary: cond_validate 257 chars rejected (> COND_MAX_LEN)"

# ── §pos5-notactive：P5-03 实现目标登记，当前拒绝即预期（反转点）────────
# 生产未实现 < > <= >= contains → 下列冻结语法表达式当前被拒是**如实反映**。
# P5-03 实现后本段将从「拒绝」转「接受」（FAIL→PASS 门禁锚点）。
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if cond_grammar_ok "$line"; then
        bad "P5-02 pos5-notactive: '$line' unexpectedly ACCEPTED (P5-03 新运算符未实现，当前应拒绝)"
    else
        ok "P5-02 pos5-notactive: '$line' rejected (P5-03 反转点)"
    fi
done < "$P5POS"

# ── 汇总 ─────────────────────────────────────────────────────────────────
echo "p5-condition tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
