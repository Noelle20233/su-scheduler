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
[ "$count" -eq 5 ] && ok "registry has 5 providers (got $count)" || bad "registry expected 5, got $count"

[ "$(provider_lookup trigger boot)" = "tpr_trigger_boot" ]    && ok "lookup trigger>boot"    || bad "lookup trigger>boot"
[ "$(provider_lookup trigger time)" = "tpr_trigger_time" ]    && ok "lookup trigger>time"    || bad "lookup trigger>time"
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
TPR_LOG=0 TPR_BOOT_CONTEXT=1 provider_dispatch trigger boot matches boot >/dev/null 2>&1 && ok "boot matches in boot context" || bad "boot matches in context"
TPR_LOG=0 TPR_BOOT_CONTEXT=0 provider_dispatch trigger boot matches boot >/dev/null 2>&1 && bad "boot should not match outside context" || ok "boot no match outside context"
due=$(TPR_LOG=0 TPR_BOOT_CONTEXT=1 provider_dispatch trigger boot next_due boot) && [ "$due" = 0 ] && ok "boot next_due=0 in context" || bad "boot next_due in context"
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

# ── 5) Action：CommandActionProvider 生命周期（真实异步进程） ────────────────
ACT_DIR=$(mktemp -d)
export TPR_ACTION_DIR="$ACT_DIR"
TPR_LOG=0 provider_dispatch action command validate 'sleep 3' >/dev/null 2>&1 && ok "action validate cmd" || bad "action validate"
TPR_LOG=0 provider_dispatch action command validate '' >/dev/null 2>&1 && bad "action validate empty should fail" || ok "action validate empty rejected"
dir=$(TPR_LOG=0 provider_dispatch action command prepare task1 'sleep 3')
[ -f "$dir/command.txt" ] && [ "$(cat "$dir/command.txt")" = 'sleep 3' ] && ok "action prepare creates task dir + command.txt" || bad "action prepare"
pid=$(TPR_LOG=0 provider_dispatch action command start task1 'sleep 3')
[ -n "$pid" ] && ok "action start pid=$pid" || bad "action start"
TPR_LOG=0 provider_dispatch action command status task1 "$pid" >/dev/null 2>&1 && ok "action status alive" || bad "action status alive"
TPR_LOG=0 provider_dispatch action command stop task1 "$pid" >/dev/null 2>&1
sleep 1
TPR_LOG=0 provider_dispatch action command status task1 "$pid" >/dev/null 2>&1 && bad "action status should be dead after stop" || ok "action status dead after stop"
pid2=$(TPR_LOG=0 provider_dispatch action command restart task1 'sleep 3' "$pid")
[ -n "$pid2" ] && [ "$pid2" != "$pid" ] && ok "action restart new pid=$pid2" || bad "action restart"
TPR_LOG=0 provider_dispatch action command stop task1 "$pid2" >/dev/null 2>&1
sleep 1
TPR_LOG=0 provider_dispatch action command stop task1 "$pid2" >/dev/null 2>&1 || true
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