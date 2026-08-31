#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — CLI 行为回归（P0 L2）：Q1/Q2/Q3/Q4/Q9 处理门禁
# ═══════════════════════════════════════════════════════════════════════════
# 覆盖（P2-01 以「先失败后通过」执行；修复前 FAIL 证据见 docs/P2-01.md）：
#   Q1  cmd_log -n NUM（默认 20；-f 保留不阻塞测试）
#   Q2  cmd_add 已文档化触发器集合（boot/HHMM/HH:MM/weekly:/nweekly:/
#       monthly:/nmonthly:/yearly:；仅 HH:MM 去冒号）
#   Q9  cmd_add yearly 文档格式（MM:DD:HHMM）→ 写出行归一为 daemon 已支持
#       格式（yearly:MMDD:HHMM，C4 合规）
#   Q3  cmd_list 非管道循环（有匹配行时不再误报 "No active missions"）
#   Q4  cmd_task_output 函数唯一性（删除死代码重复定义；行为=生效版锁定）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ./harness.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

T=$(mktemp -d)
export CLI_TMP="$T"
trap 'rm -rf "$T"' EXIT

# ── Q4 静态：cmd_task_output 必须恰好定义一次；残留乱注释必须清除 ──────────
n_defs=$(grep -c '^cmd_task_output()' "$CLI_SCRIPT" || true)
if [ "$n_defs" -eq 1 ]; then
    ok "Q4 cmd_task_output defined exactly once (count=$n_defs)"
else
    bad "Q4 cmd_task_output defined $n_defs times (expect exactly 1 — dead duplicate)"
fi
if grep -q 'Kill# 📄 detailed task output' "$CLI_SCRIPT"; then
    bad "Q4 mangled comment '# 💀 Kill# 📄' still present (dead-code leftover)"
else
    ok "Q4 mangled comment cleaned"
fi

# ── Q1 cmd_log：-n NUM 生效，默认 20，-f 保留 ─────────────────────────────
i=1; while [ "$i" -le 30 ]; do printf 'line %02d\n' "$i"; i=$((i + 1)); done > "$T/su-scheduler.log"
cli_run cmd_log -n 5
n=$(printf '%s\n' "$CLI_OUT" | grep -c '^line ')
if printf '%s\n' "$CLI_OUT" | grep -q 'Last 5'; then
    ok "Q1 log -n 5 header 'Last 5'"
else
    bad "Q1 log -n 5 header (got: $(printf '%s\n' "$CLI_OUT" | head -1))"
fi
[ "$n" -eq 5 ] && ok "Q1 log -n 5 prints exactly 5 lines" || bad "Q1 log -n 5 printed $n lines (expect 5)"

cli_run cmd_log
if printf '%s\n' "$CLI_OUT" | grep -q 'Last 20'; then
    ok "Q1 log default header 'Last 20'"
else
    bad "Q1 log default header"
fi
n=$(printf '%s\n' "$CLI_OUT" | grep -c '^line ')
[ "$n" -eq 20 ] && ok "Q1 log default prints 20 lines" || bad "Q1 log default printed $n lines (expect 20)"
ok "Q1 log -f retained (not tested — blocking tail -f; see docs/P2-01.md)"

# ── Q2/Q9 cmd_add：已文档化触发器集 + yearly 归一 ──────────────────────────
add_chk() {  # $1=描述  $2=期望写出行（grep -F 片段）  $3..=cmd_add 参数
    desc="$1"; expect="$2"; shift 2
    : > "$T/config.txt"
    cli_run cmd_add "$@"
    written=$(cat "$T/config.txt" 2>/dev/null)
    if [ "$CLI_RC" -eq 0 ] && printf '%s\n' "$written" | grep -qF "$expect"; then
        ok "Q2/Q9 $desc (rc=0, wrote: $(printf '%s\n' "$written" | head -1))"
    else
        bad "Q2/Q9 $desc rc=$CLI_RC expect line containing *$expect* — wrote: [$written] out: [$CLI_OUT]"
    fi
}
add_chk "add 08:00 -> 0800 (HH:MM colon stripped)"     "0800 echo daily"  "08:00"    "echo daily"
add_chk "add 0800 as-is"                                "0800 echo plain" "0800"      "echo plain"
add_chk "add boot"                                      "boot echo onboot" "boot"     "echo onboot"
add_chk "add weekly:1:0900"                             "weekly:1:0900 echo wk" "weekly:1:0900" "echo wk"
add_chk "add nweekly:2:5:1400"                          "nweekly:2:5:1400 echo bi" "nweekly:2:5:1400" "echo bi"
add_chk "add monthly:01:0000"                           "monthly:01:0000 echo mo" "monthly:01:0000" "echo mo"
add_chk "add nmonthly:3:15:1200"                        "nmonthly:3:15:1200 echo q" "nmonthly:3:15:1200" "echo q"
add_chk "Q9 yearly doc format normalized to MMDD"       "yearly:1225:0800 echo xmas" "yearly:12:25:0800" "echo xmas"
add_chk "yearly impl format accepted as-is"             "yearly:1225:0800 echo xmas2" "yearly:1225:0800" "echo xmas2"

# 无效触发器仍被拒绝且不写配置
: > "$T/config.txt"
cli_run cmd_add banana "echo nope"
if [ "$CLI_RC" -ne 0 ] && printf '%s\n' "$CLI_OUT" | grep -q 'Invalid trigger'; then
    ok "Q2 invalid trigger rejected (rc=$CLI_RC)"
else
    bad "Q2 invalid trigger should reject (rc=$CLI_RC out: $CLI_OUT)"
fi
[ ! -s "$T/config.txt" ] && ok "Q2 invalid trigger wrote nothing" || bad "Q2 invalid trigger polluted config"

# ── Q3 cmd_list：非管道循环，有匹配不再误报空态 ───────────────────────────
cat > "$T/config.txt" <<'CFG'
# comment
08:30 logcat -c; : --notify

weekly:1:0900 echo Monday
CFG
cli_run cmd_list
if printf '%s\n' "$CLI_OUT" | grep -q '08:30'; then
    ok "Q3 list renders matching line (08:30)"
else
    bad "Q3 list missing 08:30 line"
fi
if printf '%s\n' "$CLI_OUT" | grep -q 'No active missions'; then
    bad "Q3 list falsely reports 'No active missions' despite matches (subshell bug)"
else
    ok "Q3 list no false empty-state when matches exist"
fi
# 空配置（仅注释）→ 应正确报空态
printf '# only comments\n# nothing active\n' > "$T/config.txt"
cli_run cmd_list
if printf '%s\n' "$CLI_OUT" | grep -q 'No active missions'; then
    ok "Q3 list empty-state shown when no matches"
else
    bad "Q3 list should show empty-state when no matches"
fi

# ── Q4 行为：生效版 cmd_task_output（output.log → shells .out → 报错） ────
mkdir -p "$T/tasks/id1" "$T/shells"
printf 'hello-out\n' > "$T/tasks/id1/output.log"
cli_run cmd_task_output id1
if printf '%s\n' "$CLI_OUT" | grep -q 'hello-out' && printf '%s\n' "$CLI_OUT" | grep -q 'Output for id1'; then
    ok "Q4 task-output reads output.log (header + content)"
else
    bad "Q4 task-output output.log path (out: $CLI_OUT)"
fi
rm "$T/tasks/id1/output.log"
printf 'shell-out\n' > "$T/shells/id1.out"
cli_run cmd_task_output id1
if printf '%s\n' "$CLI_OUT" | grep -q 'shell-out'; then
    ok "Q4 task-output falls back to shells <id>.out"
else
    bad "Q4 task-output shell .out fallback (out: $CLI_OUT)"
fi
cli_run cmd_task_output id2
if printf '%s\n' "$CLI_OUT" | grep -q 'No output found for task id2'; then
    ok "Q4 task-output error when neither output.log nor .out exists"
else
    bad "Q4 task-output missing-error (out: $CLI_OUT)"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "cli tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1