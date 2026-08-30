#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Legacy Config Adapter 测试（P1-05）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0（全绿）或非 0。
# 覆盖（对应验收标准）：
#   1) 同一份旧配置每次解析结果一致（重复解析 → 输出逐字节一致，含 Task ID）——验收 1
#   2) 旧配置无需修改即可生成 Task（直接使用 tests/fixtures/legacy/config.txt）——验收 2
#   3) 命令文本保持原样（action.command / source.raw 与 legacy 行逐字节一致）——验收 3
#   4) 保留原始行号（source.line；heredoc 为块范围）
#   5) 稳定 Task ID：t<行号>_<trigger_norm>，无单次执行时间戳；重复加载 ID 一致
#   6) 触发器/修饰符全程支持：boot/HHMM/HH:MM/weekly/nweekly/monthly/nmonthly/
#      yearly/heredoc/全部 modifier/Termux 模式/注释/空行
#   7) 与 P1-02 task-v2 样例逐条一致（同输入 → 同 Task）
#   8) 错误路径：文件缺失/out_dir 不可建 → rc2 且零任务；控制字符触发器 →
#      rc1、该行跳过、其余行完整产出 → 无半成品 Task（验收：解析失败明确报错）
#   9) 合法"少见"形态：仅触发器行（空命令=完整任务）、注释/空行/全空白行、
#      unterminated heredoc（legacy 语义：读到 EOF，接受）——fixtures/config-valid-extras.txt
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
LEGACY_ADAPTER_SOURCED=1
. ./adapter.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

LEGACY="../fixtures/legacy/config.txt"
SAMPLES="../fixtures/task-v2/samples"

# ── 1/2/3/4/5/6/7) 主 fixture 一次解析 ──────────────────────────────────────
OUT1=$(mktemp -d)
stdout1=$(legacy_adapter_parse "$LEGACY" "$OUT1")
rc=$?
[ "$rc" -eq 0 ] && ok "parse legacy fixture rc=0" || bad "parse rc=$rc (expect 0)"

count=$(ls "$OUT1" | wc -l)
[ "$count" -eq 17 ] && ok "17 tasks emitted (comments/blank lines skipped)" || bad "task count=$count (expect 17)"

# 行号保留（含 heredoc 块范围）
chk_line() { # $1=id $2=期望 source.line
    got=$(grep '^source.line=' "$OUT1/$1.task" | cut -d= -f2)
    [ "$got" = "$2" ] && ok "$1 source.line=$2" || bad "$1 source.line=$got (expect $2)"
}
chk_line t11_boot 11
chk_line t16_0830 16
chk_line t26_yearly12250800 26
chk_line t35_0915 35-37
chk_line t39_weekly72300 39-42
chk_line t45_2200 45

# 稳定 ID：文件名 == id 字段；格式 t<行号>_<norm>；无时间戳（epoch 数字）
for f in "$OUT1"/*.task; do
    id=$(basename "$f" .task)
    idf=$(grep '^id=' "$f" | cut -d= -f2)
    [ "$id" = "$idf" ] && ok "$id: filename == id field" || bad "$id: filename/id mismatch"
    case "$id" in
        t[0-9]*_[A-Za-z0-9_]*) ;;
        *) bad "$id: id format violation" ;;
    esac
    # 无单次执行时间戳（legacy task id 曾含 _<epoch>）
    case "$id" in
        *_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) bad "$id contains epoch-like suffix" ;;
        *) ok "$id: no timestamp suffix" ;;
    esac
done

# 命令文本原样（action.command / source.raw 与 legacy 行逐字节一致）
chk_cmd() { # $1=id $2=期望 action.command
    got=$(grep '^action.command=' "$OUT1/$1.task" | cut -d= -f2-)
    [ "$got" = "$2" ] && ok "$1 action.command '$2'" || bad "$1 action.command '$got' (expect '$2')"
}
chk_cmd t16_0830 'logcat -c'
chk_cmd t29_1430 'echo "Run me now"'
chk_cmd t45_2200 'echo "No modifiers at all"'
chk_cmd t12_boot 'sh'
chk_cmd t32_boot '/sdcard/Documents/su-scheduler/backup.sh'
# heredoc 块：与 t35 样例一致（重构命令含残留），且在 adapter 输出中存在
g=$(grep '^action.command=' "$OUT1/t35_0915.task" | cut -d= -f2)
s=$(grep '^action.command=' "$SAMPLES/t35_0915.task" | cut -d= -f2)
[ "$g" = "$s" ] && ok "t35 action.command == sample (heredoc residue preserved)" || bad "t35 command mismatch"

# source.raw 原样：行 16 与 fixture 行 16 逐字节一致
raw16=$(grep '^source.raw=' "$OUT1/t16_0830.task" | cut -d= -f2-)
line16=$(sed -n '16p' "$LEGACY")
[ "$raw16" = "$line16" ] && ok "t16 source.raw == legacy line 16 verbatim" || bad "t16 source.raw mismatch"

# 修饰符标志（parse_modifiers 语义）
chk_flag() { # $1=id $2=key $3=期望值
    got=$(grep "^$2=" "$OUT1/$1.task" | cut -d= -f2)
    [ "$got" = "$3" ] && ok "$1 $2=$3" || bad "$1 $2=$got (expect $3)"
}
chk_flag t11_boot action.notify_start 1
chk_flag t11_boot action.notify_end 1
chk_flag t12_boot action.interactive 1
chk_flag t13_boot action.termux 1
chk_flag t16_0830 action.notify_end 1
chk_flag t16_0830 action.msg 'Logs cleared'
chk_flag t26_yearly12250800 action.delete 1
chk_flag t29_1430 action.run_once_now 1
chk_flag t32_boot action.delete 1
chk_flag t45_2200 action.run_once_now 0
chk_flag t35_0915 action.termux 1
chk_flag t35_0915 runtime.state PENDING

# ── 验收 1：同一配置重复解析 → 逐字节一致（含 ID）────────────────────────────
OUT2=$(mktemp -d)
stdout2=$(legacy_adapter_parse "$LEGACY" "$OUT2")
rc2=$?
[ "$rc2" -eq 0 ] && ok "re-parse rc=0" || bad "re-parse rc=$rc2"
diff -r "$OUT1" "$OUT2" >/dev/null 2>&1 && ok "identical output on re-parse (byte-level)" || bad "re-parse output differs"
# stdout 的 file= 路径属于不同临时目录——只比较 task=<id> 序列（ID 稳定性）
ids1=$(printf '%s\n' "$stdout1" | sed -n 's/^task=\([^ ]*\).*/\1/p' | tr '\n' ' ')
ids2=$(printf '%s\n' "$stdout2" | sed -n 's/^task=\([^ ]*\).*/\1/p' | tr '\n' ' ')
[ "$ids1" = "$ids2" ] && ok "identical task ids on re-parse (stable)" || bad "task ids differ on re-parse: [$ids1] vs [$ids2]"

# ── 验收 2/7：与 P1-02 task-v2 样例逐条一致（去注释后逐字节）──────────────────
for f in "$SAMPLES"/*.task; do
    id=$(basename "$f" .task)
    if [ -f "$OUT1/$id.task" ]; then
        diff <(grep -v '^#' "$OUT1/$id.task") <(grep -v '^#' "$f") >/dev/null 2>&1 \
            && ok "adapter == sample: $id" || bad "adapter != sample: $id"
    else
        bad "sample $id missing from adapter output"
    fi
done

# ── 8) 错误路径 ─────────────────────────────────────────────────────────────
err_out=$(mktemp -d)
out_err=$(mktemp)
stderr=$(mktemp)
legacy_adapter_parse /nonexistent/conf.txt "$err_out/.." >"$out_err" 2>"$stderr"
erc=$?
[ "$erc" -eq 2 ] && ok "missing config -> rc2" || bad "missing config rc=$erc (expect 2)"
[ ! -s "$out_err" ] && ok "missing config: no tasks on stdout" || bad "missing config emitted tasks"
grep -q 'ERROR' "$stderr" && grep -q 'not found' "$stderr" && ok "missing config: clear ERROR logged" || bad "missing config error message"

legacy_adapter_parse "$LEGACY" /nonexistent-parent-xyz/sub >"$out_err" 2>"$stderr"
erc=$?
[ "$erc" -eq 2 ] && ok "uncreatable out_dir -> rc2" || bad "uncreatable out_dir rc=$erc"

# 控制字符触发器 → rc1；该行不产出任务；其余行完整产出（无半成品）
BADIN=$(mktemp)
printf '08\x01:30 echo bad\n14:00 echo good\n' > "$BADIN"
BADOUT=$(mktemp -d)
legacy_adapter_parse "$BADIN" "$BADOUT" >"$out_err" 2>"$stderr"
erc=$?
[ "$erc" -eq 1 ] && ok "control-char trigger line -> rc1" || bad "control-char trigger rc=$erc (expect 1)"
grep -q "ERROR" "$stderr" && grep -q "control character" "$stderr" && ok "line-level ERROR logged with reason" || bad "line-level error message"
[ "$(ls "$BADOUT" | wc -l)" -eq 1 ] && ok "bad line produced no task; good line produced 1" || bad "task count for BADIN=$(ls "$BADOUT" | wc -l)"
[ -f "$BADOUT/t2_1400.task" ] && ok "good line task is complete (t2_1400)" || bad "good line task missing"
grep -q '^action.command=echo good$' "$BADOUT/t2_1400.task" && ok "good line command intact" || bad "good line command corrupted"
grep -q '^schema_version=2$' "$BADOUT/t2_1400.task" && ok "good task has full schema (no half-baked)" || bad "good task incomplete"
[ ! -e "$BADOUT/t1_08130.task" ] && [ ! -e "$BADOUT/t1_*.task" ] && ok "no half-baked artifact for bad line" || bad "half-baked task artifact exists"
if ls "$BADOUT"/*.tmp >/dev/null 2>&1; then bad "leftover .tmp (atomic write failed)"; else ok "no leftover .tmp files"; fi
rm -f "$BADIN"

# 注释+空行+全空白行 → 0 任务，rc0
CLEAN=$(mktemp)
printf '# only comment\n\n   \n# another\n' > "$CLEAN"
CLEANOUT=$(mktemp -d)
legacy_adapter_parse "$CLEAN" "$CLEANOUT" >/dev/null 2>&1
[ "$?" -eq 0 ] && [ "$(ls "$CLEANOUT" | wc -l)" -eq 0 ] && ok "comments/blank lines -> 0 tasks, rc0" || bad "comments-only config handling"
rm -f "$CLEAN"

# ── 9) 合法少见形态（fixtures/config-valid-extras.txt）────────────────────────
EX3=$(mktemp -d)
stdout3=$(legacy_adapter_parse "fixtures/config-valid-extras.txt" "$EX3")
erc=$?
[ "$erc" -eq 0 ] && ok "valid-extras parse rc=0" || bad "valid-extras rc=$erc"
[ "$(ls "$EX3" | wc -l)" -eq 3 ] && ok "valid-extras -> 3 tasks" || bad "valid-extras count=$(ls "$EX3" | wc -l)"
# 位置无关校验：从 fixture 用 grep 定位各触发器物理行，再核对 adapter 产出的 id/行号
EXF="fixtures/config-valid-extras.txt"
boot_pos=$(grep -n '^boot$' "$EXF" | head -1 | cut -d: -f1)
t_pos=$(grep -n '^14:30$' "$EXF" | head -1 | cut -d: -f1)
h_pos=$(grep -n '<<EOF' "$EXF" | head -1 | cut -d: -f1)
[ -n "$boot_pos" ] && [ -n "$t_pos" ] && [ -n "$h_pos" ] && ok "extras fixture triggers locatable (boot@$boot_pos, 14:30@$t_pos, heredoc@$h_pos)" || bad "extras fixture locate failed"

b_id="t${boot_pos}_boot"
[ -f "$EX3/$b_id.task" ] && ok "extras boot task emitted: $b_id (physical line $boot_pos)" || bad "extras boot task missing ($b_id)"
got=$(grep '^source.line=' "$EX3/$b_id.task" | cut -d= -f2)
[ "$got" = "$boot_pos" ] && ok "$b_id source.line=$boot_pos (original line preserved)" || bad "$b_id source.line=$got (expect $boot_pos)"
got=$(grep '^action.command=' "$EX3/$b_id.task" | cut -d= -f2)
[ "$got" = "" ] && ok "trigger-only boot: empty action.command (complete, legal)" || bad "trigger-only boot command: '$got'"

t_id="t${t_pos}_1430"
[ -f "$EX3/$t_id.task" ] && ok "extras time task emitted: $t_id (physical line $t_pos)" || bad "extras time task missing ($t_id)"
got=$(grep '^source.line=' "$EX3/$t_id.task" | cut -d= -f2)
[ "$got" = "$t_pos" ] && ok "$t_id source.line=$t_pos" || bad "$t_id source.line=$got"
got=$(grep '^action.command=' "$EX3/$t_id.task" | cut -d= -f2)
[ "$got" = "" ] && ok "trigger-only 14:30: empty command" || bad "trigger-only time command: '$got'"

# 无 EOF 终止符 heredoc：任务 id 用头部行；块范围以 "h-" 前缀；notify 已解析；命令带残留
h_id="t${h_pos}_0800"
[ -f "$EX3/$h_id.task" ] && ok "extras heredoc task emitted: $h_id (header line $h_pos)" || bad "extras heredoc task missing ($h_id)"
got=$(grep '^source.line=' "$EX3/$h_id.task" | cut -d= -f2)
case "$got" in
    "${h_pos}-"*) ok "$h_id source.line=$got (block from header $h_pos)" ;;
    *) bad "$h_id source.line=$got (expect ${h_pos}-…)" ;;
esac
grep -q '^action.notify_start=1$' "$EX3/$h_id.task" && ok "unterminated heredoc: modifiers parsed (notify)" || bad "unterminated heredoc notify"
hcmd=$(grep '^action.command=' "$EX3/$h_id.task" | cut -d= -f2)
case "$hcmd" in
    "sh '"*"; :"*) ok "unterminated heredoc: reconstructed command with residue" ;;
    *) bad "unterminated heredoc command: '$hcmd'" ;;
esac
rm -f "$out_err" "$stderr"
rm -rf "$OUT1" "$OUT2" "$err_out" "$BADOUT" "$EX3" "$CLEANOUT"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "legacy-adapter tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1