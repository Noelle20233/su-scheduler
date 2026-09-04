#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Provider 契约测试（P1-04）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0（全绿）或非 0。
# 覆盖：
#   1) 契约表：kind / 全局能力集 / kind 能力子集 / 必备能力
#   2) 静态注册表：条目数、查找（按 kind+name / kind 默认第一个）、重复拒绝、未知拒绝
#   3) 分发：显式点名（provider_dispatch）与默认（provider_dispatch_default）
#   4) Trigger：boot 上下文匹配/到期；time 校验/解析/匹配/next_due
#   5) Action 生命周期：validate/prepare/start/status/stop/restart（真实异步进程）
#   6) Health/Recovery 空实现：validate/check/recover
#   7) 错误路径：未知 kind / 未知能力 / 未知 Provider / 能力不属于 kind / Provider 缺能力
#   8) 与状态机隔离：Provider 不引入/不修改状态机；共存后状态转换仍有效
#   9) 日志钩子：TPR_LOG=1 记录失败；TPR_LOG=0 静音
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
. ./lib.sh
. ./providers.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

# ── 1) 契约表 ───────────────────────────────────────────────────────────────
all_kinds=1
for k in trigger action health recovery; do
    case " $TPR_KINDS " in
        *" $k "*) ;;
        *) all_kinds=0 ;;
    esac
done
[ "$all_kinds" -eq 1 ] && ok "kinds: trigger/action/health/recovery" || bad "kinds missing"
for k in $TPR_KINDS; do
    provider_kind_is_valid "$k" && ok "kind '$k' valid" || bad "kind '$k' should be valid"
done
provider_kind_is_valid sensor && bad "kind 'sensor' should be invalid" || ok "kind 'sensor' invalid"

for c in validate parse matches next_due prepare start stop status restart check recover; do
    provider_cap_is_valid "$c" && ok "cap '$c' in global set" || bad "cap '$c' missing"
done
provider_cap_is_valid fly && bad "cap 'fly' should be invalid" || ok "cap 'fly' invalid"

for spec in $TPR_CAPS_REQUIRED; do
    k=${spec%%>*}; c=${spec#*>}
    provider_cap_is_of_kind "$c" "$k" && ok "required $k>$c in kind caps" || bad "required $k>$c NOT in kind caps"
done
for k in $TPR_KINDS; do
    eval "caps=\$TPR_CAPS_$(echo "$k" | tr 'a-z' 'A-Z')"
    for c in $caps; do
        provider_cap_is_valid "$c" && ok "$k caps: '$c' valid" || bad "$k caps: '$c' unknown"
    done
done

# ── 2) 静态注册表 ───────────────────────────────────────────────────────────
count=$(echo "$TPR_REGISTRY" | tr ' ' '\n' | sed '/^$/d' | wc -l)
[ "$count" -eq 6 ] && ok "registry has 6 providers (got $count)" || bad "registry expected 6, got $count"

[ "$(provider_lookup trigger boot)" = "tpr_trigger_boot" ]    && ok "lookup trigger>boot"    || bad "lookup trigger>boot"
[ "$(provider_lookup trigger time)" = "tpr_trigger_time" ]    && ok "lookup trigger>time"    || bad "lookup trigger>time"
[ "$(provider_lookup trigger advanced)" = "tpr_trigger_advanced" ] && ok "lookup trigger>advanced" || bad "lookup trigger>advanced"
[ "$(provider_lookup action command)" = "tpr_action_command" ] && ok "lookup action>command" || bad "lookup action>command"
[ "$(provider_lookup health builtin)" = "tpr_health_builtin" ]   && ok "lookup health>builtin"  || bad "lookup health>builtin"
[ "$(provider_lookup recovery builtin)" = "tpr_recovery_builtin" ] && ok "lookup recovery>builtin" || bad "lookup recovery>builtin"
[ "$(provider_lookup trigger)" = "tpr_trigger_boot" ] && ok "lookup trigger (default = first)" || bad "lookup trigger default"
provider_lookup trigger nosuch >/dev/null 2>&1 && bad "lookup unknown provider should fail" || ok "lookup unknown provider rejected"
provider_lookup sensor >/dev/null 2>&1 && bad "lookup unknown kind should fail" || ok "lookup unknown kind rejected"

TPR_LOG=0 provider_register trigger boot xxx >/dev/null 2>&1 && bad "duplicate register should fail" || ok "duplicate register rejected"
TPR_LOG=0 provider_register sensor x y >/dev/null 2>&1 && bad "register unknown kind should fail" || ok "register unknown kind rejected"

# ── 3/4) Trigger：boot ──────────────────────────────────────────────────────
TPR_LOG=0 provider_dispatch trigger boot validate boot >/dev/null 2>&1 && ok "boot validate 'boot'" || bad "boot validate 'boot'"
TPR_LOG=0 provider_dispatch trigger boot validate '08:30' >/dev/null 2>&1 && bad "boot provider should reject '08:30'" || ok "boot rejects '08:30'"
[ "$(TPR_LOG=0 provider_dispatch trigger boot parse boot)" = "kind=boot" ] && ok "boot parse -> kind=boot" || bad "boot parse"
TPR_LOG=0 TRIGGER_BOOT_CONTEXT=1 provider_dispatch trigger boot matches boot >/dev/null 2>&1 && ok "boot matches in boot context" || bad "boot matches in context"
TPR_LOG=0 TRIGGER_BOOT_CONTEXT=0 provider_dispatch trigger boot matches boot >/dev/null 2>&1 && bad "boot should not match outside context" || ok "boot no match outside context"
due=$(TPR_LOG=0 TRIGGER_BOOT_CONTEXT=1 provider_dispatch trigger boot next_due boot) && [ "$due" = 0 ] && ok "boot next_due=0 in context" || bad "boot next_due in context"
TPR_LOG=0 provider_dispatch trigger boot next_due boot >/dev/null 2>&1 && bad "boot next_due outside context should fail" || ok "boot next_due outside context rejected"

# ── 3/4) Trigger：time ──────────────────────────────────────────────────────
for t in 08:30 0830; do
    TPR_LOG=0 provider_dispatch trigger time validate "$t" >/dev/null 2>&1 && ok "time validate '$t'" || bad "time validate '$t'"
done
TPR_LOG=0 provider_dispatch trigger time validate 'weekly:1:0800' >/dev/null 2>&1 && bad "time provider should reject weekly" || ok "time rejects weekly (advanced = future providers)"
TPR_LOG=0 provider_dispatch trigger time validate abcd >/dev/null 2>&1 && bad "time validate 'abcd' should fail" || ok "time validate 'abcd' rejected"
TPR_LOG=0 provider_dispatch trigger time validate '' >/dev/null 2>&1 && bad "time validate empty should fail" || ok "time validate empty rejected"
[ "$(TPR_LOG=0 provider_dispatch trigger time parse '08:30')" = "kind=time;time=0830" ] && ok "time parse '08:30'" || bad "time parse"

now=$(date +%H%M)
next=$(date -d '+1 min' +%H%M)
TPR_LOG=0 provider_dispatch trigger time matches "$now" >/dev/null 2>&1 && ok "time matches current ($now)" || bad "time matches current"
TPR_LOG=0 provider_dispatch trigger time matches "$next" >/dev/null 2>&1 && bad "time should not match +1min" || ok "time no match +1min"
due_now=$(TPR_LOG=0 provider_dispatch trigger time next_due "$now")
[ "$due_now" = 0 ] && ok "time next_due(current)=0" || bad "time next_due(current)=$due_now"
due_next=$(TPR_LOG=0 provider_dispatch trigger time next_due "$next")
if [ "$due_next" -gt 0 ] 2>/dev/null && [ "$due_next" -le 3600 ]; then
    ok "time next_due(+1min)=$due_next in (0,3600]"
else
    bad "time next_due(+1min)=$due_next out of range"
fi

# 默认分发（kind 第一个）：trigger 默认 = boot
TPR_LOG=0 provider_dispatch_default trigger validate boot >/dev/null 2>&1 && ok "dispatch_default trigger validate 'boot' (first=boot)" || bad "dispatch_default trigger validate boot"
TPR_LOG=0 provider_dispatch_default trigger validate '08:30' >/dev/null 2>&1 && bad "dispatch_default should use boot (reject 08:30)" || ok "dispatch_default first=boot rejects '08:30'"

# ── 4b) Trigger：advanced（weekly/nweekly/monthly/nmonthly/yearly 封装）────────
# P1-07：现有高级调度封装为 TriggerProvider（只判断；去重键读取，不写状态）。
for t in weekly:1:0800 nweekly:2:5:1400 monthly:15:1200 nmonthly:3:01:0900 yearly:12:25:0800; do
    TPR_LOG=0 provider_dispatch trigger advanced validate "$t" >/dev/null 2>&1 && ok "advanced validate '$t'" || bad "advanced validate '$t'"
done
TPR_LOG=0 provider_dispatch trigger advanced validate '08:30' >/dev/null 2>&1 && bad "advanced should reject '08:30'" || ok "advanced rejects plain time"
TPR_LOG=0 provider_dispatch trigger advanced validate 'nweekly:0:5:1400' >/dev/null 2>&1 && ok "advanced accepts nweekly syntax (shape check)" || bad "advanced rejects nweekly"
[ "$(TPR_LOG=0 provider_dispatch trigger advanced parse 'weekly:1:0800')" = "kind=advanced;family=weekly" ] && ok "advanced parse weekly" || bad "advanced parse weekly"
TPR_LOG=0 provider_dispatch trigger advanced parse 'yearly:12:25:0800' >/dev/null 2>&1 && ok "advanced parse yearly" || bad "advanced parse yearly"

# 星期匹配（注入 TRIGGER_TODAY=周一；状态文件为空 → 应匹配）——只判不写
MON=$(date -d 'monday' +%Y%m%d 2>/dev/null || date +%Y%m%d)
SF=$(mktemp)
TRIGGER_TODAY=$MON TRIGGER_DECISION_NOW=0900 TRIGGER_DECISION_LINE='weekly:1:0800 echo w' \
    TRIGGER_STATE_FILE="$SF" TPR_LOG=0 provider_dispatch trigger advanced matches 'weekly:1:0800' >/dev/null 2>&1 \
    && ok "advanced weekly matches on Monday 09:00 (state empty, decision-only)" \
    || bad "advanced weekly should match Monday 09:00"
[ -s "$SF" ] && bad "advanced matches wrote state (decision-only violation!)" || ok "advanced matches did NOT write state (decision-only)"
# 已记录去重键 → 不应再匹配（只在判断期 reads 的镜像）
printf 'weekly_1_0800_%s_%s\n' "$(printf '%s\n' 'weekly:1:0800 echo w' | md5sum | cut -d' ' -f1)" "$(date -d "$MON" +%Y%m%d)" > "$SF"
TRIGGER_TODAY=$MON TRIGGER_DECISION_NOW=0900 TRIGGER_DECISION_LINE='weekly:1:0800 echo w' \
    TRIGGER_STATE_FILE="$SF" TPR_LOG=0 provider_dispatch trigger advanced matches 'weekly:1:0800' >/dev/null 2>&1 \
    && bad "advanced should NOT re-match after dedup key exists" \
    || ok "advanced dedup: no re-match on same period (state read respected)"
rm -f "$SF"
# 其他日期（周中）不匹配
WED=$(date -d 'wednesday' +%Y%m%d 2>/dev/null || date +%Y%m%d)
[ "$WED" != "$MON" ] || WED=$(date -d 'monday +2 days' +%Y%m%d)
SF2=$(mktemp)
TRIGGER_TODAY=$WED TRIGGER_DECISION_NOW=0900 TRIGGER_DECISION_LINE='weekly:1:0800 echo w' \
    TRIGGER_STATE_FILE="$SF2" TPR_LOG=0 provider_dispatch trigger advanced matches 'weekly:1:0800' >/dev/null 2>&1 \
    && bad "advanced weekly should not match on Wednesday" || ok "advanced weekly no match on Wednesday"
rm -f "$SF2"
# nweekly 语法可识别并接受（格式形状；实际周差在决策层测试）
# 注（2026-09-04 修复）：原用例不设 TRIGGER_TODAY/NOW → 回退真实时钟，周五（dow=5）
# 且过 14:00 时 nweekly:2:5:1400 会真实匹配 → 测试自身日期/时间敏感缺陷（P4-06 门禁
# 13:10 跑时 now<1400 才通过）。固定为周一上下文（dow=1≠5）使判定确定性。
TRIGGER_TODAY=$MON TRIGGER_DECISION_NOW=0900 TPR_LOG=0 \
    provider_dispatch trigger advanced matches 'nweekly:2:5:1400' >/dev/null 2>&1 \
    && bad "nweekly non-matching context should not match" || ok "nweekly non-matching context rejected"

# ── 5) Action：CommandActionProvider 生命周期与全模式（P1-08）───────────────
# 引擎式调用约定：start/restart 的 stdout=PID，**引擎用文件接收后读取**（镜像
# daemon `echo $! > pid.txt`），不用命令替换（命令替换内启动的后台子 shell 的
# PID 在本测试环境 /proc 不可见——探针实证；引擎接线亦采用文件/变量接收）。
ACT_DIR=$(mktemp -d)
export TPR_ACTION_DIR="$ACT_DIR"
TPR_LOG=0 provider_dispatch action command validate 'sleep 3' >/dev/null 2>&1 && ok "action validate cmd" || bad "action validate"
TPR_LOG=0 provider_dispatch action command validate '' >/dev/null 2>&1 && bad "action validate empty should fail" || ok "action validate empty rejected"
dir=$(TPR_LOG=0 provider_dispatch action command prepare task1 'sleep 3')
[ -f "$dir/command.txt" ] && [ "$(cat "$dir/command.txt")" = 'sleep 3' ] && ok "action prepare creates task dir + command.txt" || bad "action prepare"
[ -f "$dir/start_time.txt" ] && [ "$(cat "$dir/status.txt")" = "RUNNING" ] && \
    ok "action prepare writes start_time + status=RUNNING" || bad "action prepare start_time/status"
TPR_LOG=0 provider_dispatch action command start task1 'sleep 3' > "$ACT_DIR/task1.pid" 2>/dev/null
pid=$(cat "$ACT_DIR/task1.pid")
[ -n "$pid" ] && ok "action start pid=$pid" || bad "action start"
TPR_LOG=0 provider_dispatch action command status task1 "$pid" >/dev/null 2>&1 && ok "action status alive" || bad "action status alive"
TPR_LOG=0 provider_dispatch action command stop task1 "$pid" >/dev/null 2>&1
sleep 1
TPR_LOG=0 provider_dispatch action command status task1 "$pid" >/dev/null 2>&1 && bad "action status should be dead after stop" || ok "action status dead after stop"
TPR_LOG=0 provider_dispatch action command restart task1 'sleep 3' "$pid" > "$ACT_DIR/task1.pid2" 2>/dev/null
pid2=$(cat "$ACT_DIR/task1.pid2")
[ -n "$pid2" ] && [ "$pid2" != "$pid" ] && ok "action restart new pid=$pid2" || bad "action restart"
TPR_LOG=0 provider_dispatch action command stop task1 "$pid2" >/dev/null 2>&1
sleep 1
TPR_LOG=0 provider_dispatch action command stop task1 "$pid2" >/dev/null 2>&1 || true

# P1-08：运行一个任务到结束并返回任务目录（引擎式 start；轮询 exit_code.txt/进程）。
act_run() {   # <id> <cmd> [termux] [interactive] → dir
    d=$(TPR_LOG=0 provider_dispatch action command prepare "$1" "$2")
    TPR_LOG=0 provider_dispatch action command start "$1" "$2" "${3:-0}" "${4:-0}" > "$ACT_DIR/$1.pid" 2>/dev/null
    p=$(cat "$ACT_DIR/$1.pid")
    i=0
    while [ "$i" -lt 30 ]; do
        [ -f "$d/exit_code.txt" ] && break
        TPR_LOG=0 provider_dispatch action command status "$1" "$p" >/dev/null 2>&1 || break
        sleep 1
        i=$((i + 1))
    done
    echo "$d"
}
act_assert_out() {  # <dir> <expect-substr> → ok/bad
    if [ -f "$1/output.log" ] && grep -q "$2" "$1/output.log"; then
        ok "act output.log contains '$2'"
    else
        bad "act output.log missing '$2'"
    fi
}

# 5a) 普通命令成功：stdout+stderr 合并落 output.log；exit 0；SUCCESS；end_time 存在
d=$(act_run plain_ok 'echo out-line; echo err-line >&2')
[ -f "$d/exit_code.txt" ] && [ "$(cat "$d/exit_code.txt")" = "0" ] && ok "plain cmd exit_code=0" || bad "plain cmd exit_code"
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "SUCCESS" ] && ok "plain cmd status=SUCCESS" || bad "plain cmd status"
act_assert_out "$d" "out-line"
act_assert_out "$d" "err-line"
[ -f "$d/end_time.txt" ] && ok "plain cmd end_time.txt written" || bad "plain cmd end_time missing"

# 5b) 普通命令失败：FAILED + exit_code 非 0（验收：Action 失败能返回 failure 和 exit_code）
d=$(act_run plain_fail 'echo bad; exit 3')
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "FAILED" ] && ok "fail cmd status=FAILED" || bad "fail cmd status"
[ -f "$d/exit_code.txt" ] && [ "$(cat "$d/exit_code.txt")" = "3" ] && ok "fail cmd exit_code=3" || bad "fail cmd exit_code"

# 5c) 脚本智能执行：无 shebang 脚本文件（镜像 daemon L428-454，sh 回退）
SCRIPT1="$ACT_DIR/myscript.sh"
printf 'echo from-plain-script\n' > "$SCRIPT1"
d=$(act_run script_plain "$SCRIPT1")
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "SUCCESS" ] && ok "script (no shebang) SUCCESS" || bad "script (no shebang) status"
act_assert_out "$d" "from-plain-script"

# 5d) 脚本智能执行：坏 shebang → sh -c 126/127 → bash/sh 回退（镜像 daemon L442-453）
SCRIPT2="$ACT_DIR/badshebang.sh"
printf '#!/bin/definitely-not-exist\nprintf from-fallback\n' > "$SCRIPT2"
d=$(act_run script_fallback "$SCRIPT2")
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "SUCCESS" ] && ok "script (bad shebang) fallback SUCCESS" || bad "script (bad shebang) fallback status"
act_assert_out "$d" "from-fallback"

# 5e) Termux：helper 缺失 → 优雅失败（镜像 daemon L422-426）
TPR_TERMUX_HELPER="$ACT_DIR/no-such-helper" \
    d=$(act_run termux_missing 'echo t' 1)
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "FAILED" ] && ok "termux missing status=FAILED" || bad "termux missing status"
[ -f "$d/exit_code.txt" ] && [ "$(cat "$d/exit_code.txt")" = "1" ] && ok "termux missing exit_code=1" || bad "termux missing exit_code"
act_assert_out "$d" "Termux helper missing"

# 5f) Termux：helper READY → exec 执行（镜像 daemon L404-412）
MOCK_TERMUX="$ACT_DIR/su-scheduler-termux"
printf '#!/usr/bin/env bash\nif [ "$1" = status ]; then echo READY; elif [ "$1" = exec ]; then shift; bash -c "$*"; fi\n' > "$MOCK_TERMUX"
chmod +x "$MOCK_TERMUX"
TPR_TERMUX_HELPER="$MOCK_TERMUX" \
    d=$(act_run termux_ready 'echo from-termux' 1)
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "SUCCESS" ] && ok "termux READY status=SUCCESS" || bad "termux READY status"
act_assert_out "$d" "from-termux"

# 5g) Termux：helper LOCKED → ERROR: User 0 locked（镜像 daemon L413-416）
printf '#!/usr/bin/env bash\n[ "$1" = status ] && echo LOCKED\n' > "$MOCK_TERMUX"
chmod +x "$MOCK_TERMUX"
TPR_TERMUX_HELPER="$MOCK_TERMUX" \
    d=$(act_run termux_locked 'echo t' 1)
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "FAILED" ] && ok "termux LOCKED status=FAILED" || bad "termux LOCKED status"
act_assert_out "$d" "User 0 locked"

# 5h) Interactive：FIFO + sh -i（镜像 daemon L345-380）——legacy 保真怪癖：
#     结束后只写 exit_code.txt；status.txt 保持 RUNNING；无 end_time/output.log
d=$(act_run inter 'echo hi-from-interactive; exit' 0 1)
[ -f "$d/exit_code.txt" ] && [ "$(cat "$d/exit_code.txt")" = "0" ] && ok "interactive exit_code=0" || bad "interactive exit_code"
[ -f "$d/task.out" ] && grep -q "hi-from-interactive" "$d/task.out" && ok "interactive task.out has output" || bad "interactive task.out"
[ -f "$d/status.txt" ] && [ "$(cat "$d/status.txt")" = "RUNNING" ] && \
    ok "interactive status stays RUNNING (legacy mirror)" || bad "interactive status should stay RUNNING"
[ -f "$d/end_time.txt" ] && bad "interactive end_time should NOT exist (legacy mirror)" || ok "interactive no end_time (legacy mirror)"
[ -f "$d/output.log" ] && bad "interactive output.log should NOT exist (legacy mirror)" || ok "interactive no output.log (legacy mirror)"

rm -rf "$ACT_DIR"

# ── 6) Health/Recovery 空实现 ───────────────────────────────────────────────
for h in none ''; do
    TPR_LOG=0 provider_dispatch health builtin validate "$h" >/dev/null 2>&1 && ok "health validate '$h'" || bad "health validate '$h'"
done
TPR_LOG=0 provider_dispatch health builtin validate supervised >/dev/null 2>&1 && bad "health validate 'supervised' should fail (P1: none only)" || ok "health rejects unknown type"
[ "$(TPR_LOG=0 provider_dispatch health builtin check)" = "ok" ] && ok "health check -> ok (stub)" || bad "health check"
TPR_LOG=0 provider_dispatch recovery builtin validate none >/dev/null 2>&1 && ok "recovery validate none" || bad "recovery validate"
[ "$(TPR_LOG=0 provider_dispatch recovery builtin recover)" = "none" ] && ok "recovery recover -> none (stub)" || bad "recovery recover"

# ── 7) 错误路径 ─────────────────────────────────────────────────────────────
TPR_LOG=0 provider_dispatch sensor boot validate boot >/dev/null 2>&1 && bad "unknown kind should fail" || ok "dispatch unknown kind"
TPR_LOG=0 provider_dispatch trigger boot fly >/dev/null 2>&1 && bad "unknown cap should fail" || ok "dispatch unknown cap"
TPR_LOG=0 provider_dispatch trigger nosuch validate boot >/dev/null 2>&1 && bad "unknown provider should fail" || ok "dispatch unknown provider"
TPR_LOG=0 provider_dispatch action command matches >/dev/null 2>&1 && bad "cap 'matches' not in action kind should fail" || ok "cap 'matches' rejected for action kind"
TPR_LOG=0 provider_dispatch health builtin matches >/dev/null 2>&1 && bad "health lacks 'matches' should fail" || ok "health lacks cap 'matches'"
TPR_LOG=0 provider_dispatch_default sensor validate boot >/dev/null 2>&1 && bad "dispatch_default unknown kind should fail" || ok "dispatch_default unknown kind"
TPR_LOG=0 provider_dispatch_default health recover >/dev/null 2>&1 && bad "recover not in health kind should fail" || ok "dispatch_default recover rejected for health"

# ── 8) 与状态机隔离 ─────────────────────────────────────────────────────────
type task_state_transition >/dev/null 2>&1 && bad "providers must not define state machine fns" || ok "providers do not introduce state machine"
[ -z "${TSM_ALLOWED:-}" ] && ok "providers do not set TSM_ALLOWED" || bad "providers leaked TSM_ALLOWED"
. ../state-machine/lib.sh
if TSM_LOG=0 task_state_transition PENDING STARTING time_trigger; then
    ok "state machine still works after provider load (coexistence)"
else
    bad "state machine broken after provider load"
fi

# ── 9) 日志钩子 ─────────────────────────────────────────────────────────────
err=$(TPR_LOG=1 provider_dispatch trigger nosuch validate boot 2>&1 >/dev/null)
case "$err" in *"[provider]"*) ok "TPR_LOG=1 logs failure" ;; *) bad "TPR_LOG=1 log missing: $err" ;; esac
out=$(TPR_LOG=0 provider_dispatch trigger nosuch validate boot 2>&1)
[ -z "$out" ] && ok "TPR_LOG=0 silences" || bad "TPR_LOG=0 should silence (got: $out)"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "provider tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1