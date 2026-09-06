#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P5-04 新 Trigger Schema 与持久化（tests/p5-trigger）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（docs/P5-04.md / docs/architecture/trigger-schema-v2.md D41–D45）：
#   §schema-enum   合法新 Trigger（boot_completed/oneshot/delay/interval/cron）
#                  经 tcfg_editor_trigger_ok 通过；已实现既有家族（boot/time/
#                  advanced）不回归；冻结格式 = `*` / `*/N` / 逗号列表 / 单数字
#                  （0-23 范围形式不支持，不做用例）；
#   §schema-reject 非法格式全拒绝（HH/MM 越界、delay/interval 0/越界/非数字、
#                  cron 无参/段数不足/字段越界/`*/0`/非数字、未实现族拼写）；
#   §persist       tcfg_new_task 带新 Trigger 创建 → tcfg_validate_task 通过 +
#                  文件落盘 + trigger 行逐字保留（含空格 cron）；tcfg_set_field
#                  改 trigger；tcfg_apply_task 合法新 Trigger payload 成功；非法
#                  payload 被拒且旧配置逐字节不变（B9 原子性，md5 断言）+ 无 tmp；
#   §editor        tcfg_editor_validate_payload 合法新 Trigger 通过 / 非法拒绝
#                  （Editor 权威校验，写盘前拦截）；
#   §legacy-zero   B16：新 Trigger 仅 Managed；legacy 模式（无 MANAGED）下
#                  tcfg_new_task/tcfg_apply_task 全拒绝，零 task 文件、标记不动；
#   §sched         P5-05：新 Trigger 调度接线（trigger_decide 各家族 due/N +
#                  oneshot 执行自删 + interval last-run rearm + cron 日级去重 +
#                  boot_completed 上下文去重 + scheduler_tick 端到端）；
#   §posix         dash -n。
# 本套件**零生产改动**：只读 source Runtime 库（`. ./$RTLIB`，TCFG_DIR 先 export
#   隔离，同 config-v2/p5-condition 套件），只调用 tcfg_* 纯校验/存储函数。
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

export TCFG_DIR="$T/task-config"   # 隔离存储目录（先 export，tcfg_* 全部可见）
mkdir -p "$TCFG_DIR"
. ./$RTLIB

# ── §schema-enum：合法新 Trigger + 既有家族不回归 ─────────────────────────
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if tcfg_editor_trigger_ok "$t"; then
        ok "P5-04 schema-enum: accepted '$t'"
    else
        bad "P5-04 schema-enum: REJECTED '$t' (must accept)"
    fi
done <<'EOF'
boot
08:30
0830
weekly:1:0800
nweekly:2:5:1400
monthly:01:0000
nmonthly:3:15:1200
yearly:12:25:0800
boot_completed
oneshot:0830
oneshot:2359
oneshot:0000
delay:1
delay:1440
interval:5
interval:1440
cron:0 8 * * *
cron:*/15 * * * *
cron:5,10,15 9 * * 1
cron:1 2 3 4 5
cron:* * * * *
EOF
ok "P5-04 schema-enum: valid new-family + existing-family triggers all accepted"

# ── §schema-reject：非法格式全拒绝 ────────────────────────────────────────
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if tcfg_editor_trigger_ok "$t"; then
        bad "P5-04 schema-reject: ACCEPTED '$t' (must reject)"
    else
        ok "P5-04 schema-reject: rejected '$t'"
    fi
done <<'EOF'
oneshot
oneshot:2460
oneshot:2400
oneshot:0060
oneshot:12a0
oneshot:12345
delay:0
delay:1441
delay:-5
delay:abc
delay:
interval:0
interval:1.5
interval:x
cron
cron:0 8 * *
cron:* * * *
cron:60 * * * *
cron:*/0 * * * *
cron:a * * * *
cron:* 24 * * *
cron:* * 0 * *
cron:* * * 0 *
cron:* * * * 7
cron:*/x * * * *
bootx
boot_completedx
EOF
ok "P5-04 schema-reject: invalid formats all rejected"

# ── P5-09 cron 逗号列表项数上限（CRON_FIELD_MAX_ITEMS=60）─────────────────
# 61 项全 `0`（值合法仅超项数）→ 拒绝；10 项合法列表 → 通过（仅新增边界，语义不变）。
LIST61=""
i=0
while [ "$i" -lt 61 ]; do LIST61="${LIST61}0,"; i=$((i + 1)); done
LIST61=${LIST61%,}
if tcfg_editor_trigger_ok "cron:$LIST61 * * * *"; then
    bad "P5-09 cron-limit: 61-item minute list ACCEPTED (must reject >60)"
else
    ok "P5-09 cron-limit: 61-item minute list rejected (CRON_FIELD_MAX_ITEMS=60)"
fi
if tcfg_editor_trigger_ok 'cron:0,5,10,15,20,25,30,35,40,45 * * * *'; then
    ok "P5-09 cron-limit: 10-item minute list accepted (<=60, existing semantics intact)"
else
    bad "P5-09 cron-limit: 10-item minute list REJECTED (must accept <=60)"
fi

# ── §persist：持久化 + 原子性 ─────────────────────────────────────────────
echo managed > "$TCFG_DIR/MANAGED"
tcfg_new_task task_os oneshot:0830 "echo hi" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "P5-04 persist: tcfg_new_task oneshot rc=0" || bad "P5-04 persist: oneshot new rc=$rc"
[ -f "$(tcfg_task_file task_os)" ] && ok "P5-04 persist: oneshot task file written" || bad "P5-04 persist: oneshot file missing"
tcfg_validate_task "$(tcfg_task_file task_os)" && ok "P5-04 persist: tcfg_validate_task oneshot passes" || bad "P5-04 persist: oneshot validate failed"
[ "$(tcfg_get "$(tcfg_task_file task_os)" trigger)" = "oneshot:0830" ] && ok "P5-04 persist: oneshot trigger line persisted verbatim" || bad "P5-04 persist: oneshot trigger line wrong"

tcfg_new_task task_dly delay:30 "echo hi" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "P5-04 persist: tcfg_new_task delay rc=0" || bad "P5-04 persist: delay new rc=$rc"
tcfg_validate_task "$(tcfg_task_file task_dly)" && ok "P5-04 persist: tcfg_validate_task delay passes" || bad "P5-04 persist: delay validate failed"

tcfg_new_task task_cron 'cron:0 8 * * *' "echo hi" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "P5-04 persist: tcfg_new_task cron (space) rc=0" || bad "P5-04 persist: cron new rc=$rc"
tcfg_validate_task "$(tcfg_task_file task_cron)" && ok "P5-04 persist: tcfg_validate_task cron passes" || bad "P5-04 persist: cron validate failed"
[ "$(tcfg_get "$(tcfg_task_file task_cron)" trigger)" = 'cron:0 8 * * *' ] && ok "P5-04 persist: cron trigger line persisted verbatim (spaces kept)" || bad "P5-04 persist: cron trigger line wrong"

tcfg_set_field task_os trigger 'interval:15' >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "P5-04 persist: tcfg_set_field trigger rc=0" || bad "P5-04 persist: set_field rc=$rc"
[ "$(tcfg_get "$(tcfg_task_file task_os)" trigger)" = "interval:15" ] && ok "P5-04 persist: trigger field change persisted" || bad "P5-04 persist: trigger not changed"

PAYLOAD_CRON=$(cat <<'PEOF'
schema_version=2
id=task_c2
name=apply-cron
enabled=1
description=p5-04 apply
trigger=cron:*/30 9 * * 1
action.type=command
action.command=echo hi
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=none
health.target=
recovery.type=none
retry.max=0
retry.interval=60
retry.cooldown=0
advanced.timeout=0
advanced.environment=
advanced.concurrency=0
advanced.logging=0
PEOF
)
tcfg_apply_task task_c2 "$PAYLOAD_CRON" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "P5-04 persist: tcfg_apply_task valid cron rc=0" || bad "P5-04 persist: apply cron rc=$rc"
[ -f "$(tcfg_task_file task_c2)" ] && ok "P5-04 persist: applied task persisted" || bad "P5-04 persist: applied file missing"
tcfg_validate_task "$(tcfg_task_file task_c2)" && ok "P5-04 persist: applied task validates" || bad "P5-04 persist: applied validate failed"

MD5_BEFORE=$(md5sum "$(tcfg_task_file task_c2)" | cut -d' ' -f1)
BADPAY=$(printf 'schema_version=2\nid=task_c2\ntrigger=cron:60 * * * *\naction.type=command\naction.command=echo x\n')
tcfg_apply_task task_c2 "$BADPAY" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "P5-04 persist: invalid cron apply rc=1" || bad "P5-04 persist: invalid apply rc=$rc"
[ "$(md5sum "$(tcfg_task_file task_c2)" | cut -d' ' -f1)" = "$MD5_BEFORE" ] && ok "P5-04 persist: old config byte-identical after invalid apply (B9)" || bad "P5-04 persist: config CHANGED"

MD5_BEFORE2=$(md5sum "$(tcfg_task_file task_c2)" | cut -d' ' -f1)
BADPAY2=$(printf 'schema_version=2\nid=task_c2\ntrigger=oneshot:2460\naction.type=command\naction.command=echo x\n')
tcfg_apply_task task_c2 "$BADPAY2" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && [ "$(md5sum "$(tcfg_task_file task_c2)" | cut -d' ' -f1)" = "$MD5_BEFORE2" ] \
    && ok "P5-04 persist: invalid oneshot apply rc=1 + byte-identical" || bad "P5-04 persist: oneshot atomic rc=$rc"
ls "$TCFG_DIR"/*.tmp.* >/dev/null 2>&1 && bad "P5-04 persist: tmp leftover" || ok "P5-04 persist: no tmp leftover"

# ── §editor：Editor 权威校验（合法通过 / 非法拒绝）────────────────────────
GOOD_BOOTCOMP=$(printf 'schema_version=2\nid=task_e1\ntrigger=boot_completed\naction.type=command\naction.command=echo x\n')
tcfg_editor_validate_payload "$GOOD_BOOTCOMP" && ok "P5-04 editor: boot_completed payload accepted" || bad "P5-04 editor: boot_completed rejected"
GOOD_OS=$(printf 'schema_version=2\nid=task_e2\ntrigger=oneshot:0830\naction.type=command\naction.command=echo x\n')
tcfg_editor_validate_payload "$GOOD_OS" && ok "P5-04 editor: oneshot:0830 payload accepted" || bad "P5-04 editor: oneshot rejected"
GOOD_DLY=$(printf 'schema_version=2\nid=task_e3\ntrigger=delay:120\naction.type=command\naction.command=echo x\n')
tcfg_editor_validate_payload "$GOOD_DLY" && ok "P5-04 editor: delay:120 payload accepted" || bad "P5-04 editor: delay rejected"
GOOD_CRON=$(printf 'schema_version=2\nid=task_e4\ntrigger=cron:0 8 * * *\naction.type=command\naction.command=echo x\n')
tcfg_editor_validate_payload "$GOOD_CRON" && ok "P5-04 editor: cron payload accepted" || bad "P5-04 editor: cron rejected"
BAD_OS=$(printf 'schema_version=2\nid=task_e5\ntrigger=oneshot:2460\naction.type=command\naction.command=echo x\n')
if tcfg_editor_validate_payload "$BAD_OS"; then bad "P5-04 editor: oneshot:2460 accepted"; else ok "P5-04 editor: oneshot:2460 rejected"; fi
BAD_DLY=$(printf 'schema_version=2\nid=task_e6\ntrigger=delay:0\naction.type=command\naction.command=echo x\n')
if tcfg_editor_validate_payload "$BAD_DLY"; then bad "P5-04 editor: delay:0 accepted"; else ok "P5-04 editor: delay:0 rejected"; fi
BAD_CRON=$(printf 'schema_version=2\nid=task_e7\ntrigger=cron:60 * * * *\naction.type=command\naction.command=echo x\n')
if tcfg_editor_validate_payload "$BAD_CRON"; then bad "P5-04 editor: cron:60 accepted"; else ok "P5-04 editor: cron:60 rejected"; fi

# ── §legacy-zero：新 Trigger 仅 Managed（B16；legacy 零触碰）────────────────
LEG_DIR="$T/legacy-tcfg"
mkdir -p "$LEG_DIR"
export TCFG_DIR="$LEG_DIR"
[ "$(tcfg_mode)" = "legacy" ] && ok "P5-04 legacy-zero: fresh dir is legacy mode" || bad "P5-04 legacy-zero: mode=$(tcfg_mode)"
tcfg_new_task task_lt oneshot:0830 "echo hi" >/dev/null 2>&1 \
    && bad "P5-04 legacy-zero: new-trigger task allowed in legacy" || ok "P5-04 legacy-zero: tcfg_new_task rejected in legacy (B16)"
tcfg_apply_task task_lt "id=task_lt" >/dev/null 2>&1 \
    && bad "P5-04 legacy-zero: apply allowed in legacy" || ok "P5-04 legacy-zero: tcfg_apply_task rejected in legacy (B16)"
[ -z "$(ls "$LEG_DIR"/*.task 2>/dev/null)" ] && ok "P5-04 legacy-zero: zero task files in legacy dir" || bad "P5-04 legacy-zero: task files present"
[ "$(tcfg_mode)" = "legacy" ] && ok "P5-04 legacy-zero: mode stays legacy (MANAGED untouched)" || bad "P5-04 legacy-zero: MANAGED written"

# ── §sched：新 Trigger 调度接线（P5-05，trigger_decide + scheduler_tick）─────
# 断言（docs/P5-05.md §3.C.10）：oneshot 精确分钟 due + 执行自删；delay 首 tick
# 建基准不执行、N 分钟后 due、执行后（dlx 标记）不再 due；interval 首 tick due、
# 同分钟不重复（cycle 去重）、N 分钟后再次 due；cron 全字段匹配 due=Y、同日重复
# tick 不重复（cn_ 键）、不匹配分钟 due=N；boot_completed 上下文=0 due=N、=1
# 首 tick due=Y、再 tick 不重复（bc_ 键）。注入 TRIGGER_EPOCH_MIN/TRIGGER_TODAY/
# TRIGGER_STATE_FILE/TRIGGER_TASK_ID/TRIGGER_BOOT_COMPLETED_CONTEXT 保证确定性。
SCHED_T="$T/p5sched"
SCHED_BASE="$SCHED_T/base"; SCHED_CFG="$SCHED_T/config.txt"
SCHED_TASKS="$SCHED_T/tasks"; SCHED_SF="$SCHED_BASE/schedule_state.txt"
mkdir -p "$SCHED_TASKS" "$SCHED_BASE"
SCHED_EXEC_LOG="$SCHED_T/exec.log"; : > "$SCHED_EXEC_LOG"
TASKS_DIR="$SCHED_TASKS"
execute_task() {   # 7 参 shim：id cmd ns ne msg itr tmx（镜像 daemon 工件）
    id=$1; cmd=$2
    d="$SCHED_TASKS/$id"
    mkdir -p "$d"
    echo "$cmd" > "$d/command.txt"
    date "+%Y-%m-%d %H:%M:%S" > "$d/start_time.txt"
    echo "SYSTEM" > "$d/exec_mode.txt"
    echo "0" > "$d/exit_code.txt"
    echo "SUCCESS" > "$d/status.txt"
    echo "$id|$cmd" >> "$SCHED_EXEC_LOG"
    return 0
}
export TCFG_DIR="$SCHED_T/tsks"
mkdir -p "$TCFG_DIR"
echo managed > "$TCFG_DIR/MANAGED"
tcfg_new_task s_os  oneshot:0830        "echo oneshot-run"  >/dev/null 2>&1
tcfg_new_task s_ose oneshot:0830        "echo oneshot-e2e"  >/dev/null 2>&1
tcfg_new_task s_dl  delay:30            "echo delay-run"    >/dev/null 2>&1
tcfg_new_task s_iv  interval:15         "echo interval-run" >/dev/null 2>&1
tcfg_new_task s_cr  'cron:0 0 6 9 *'    "echo cron-run"     >/dev/null 2>&1
tcfg_new_task s_crx 'cron:30 0 6 9 *'   "echo cron-miss"    >/dev/null 2>&1
tcfg_new_task s_bc  boot_completed      "echo bootcomp-run" >/dev/null 2>&1
: > "$SCHED_CFG"
sched_reload "$SCHED_BASE" "$SCHED_CFG" >/dev/null 2>&1
[ "$(registry_task_ids | grep -c '^s_')" -ge 7 ] && ok "P5-05 sched: managed snapshot holds 7 new-trigger tasks" || bad "P5-05 sched: snapshot tasks=$(registry_task_ids | grep -c '^s_')"

# ── trigger_decide 直接断言（独立状态文件隔离 e2e）───────────────────────
DSF="$SCHED_T/direct_state.txt"; : > "$DSF"
# oneshot：精确分钟 due=Y / 非精确分钟 due=N
out=$(trigger_decide "$SCHED_BASE" s_os 0830 0 "$DSF")
echo "$out" | grep -q 'task=s_os.*due=Y.*cause=oneshot' && ok "P5-05 sched: oneshot due=Y at exact minute 08:30" || bad "P5-05 sched: oneshot due: $out"
out=$(trigger_decide "$SCHED_BASE" s_os 0831 0 "$DSF")
echo "$out" | grep -q 'task=s_os.*due=N' && ok "P5-05 sched: oneshot due=N at off minute 08:31" || bad "P5-05 sched: oneshot off: $out"

# delay：缺失基准 → 写 dl_ 基准 + due=N；未到 N 分钟 due=N；到达 N 分钟 due=Y；dlx 后不再 due
out=$(TRIGGER_EPOCH_MIN=5000 trigger_decide "$SCHED_BASE" s_dl 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_dl.*due=N' && ok "P5-05 sched: delay first decide arms base (due=N)" || bad "P5-05 sched: delay arm: $out"
[ "$(TRIGGER_STATE_FILE="$DSF" tpr_trigger_state_read dl_s_dl)" = "5000" ] && ok "P5-05 sched: delay base dl_s_dl=5000 persisted" || bad "P5-05 sched: delay base key wrong"
out=$(TRIGGER_EPOCH_MIN=5029 trigger_decide "$SCHED_BASE" s_dl 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_dl.*due=N' && ok "P5-05 sched: delay due=N before N min (29<30)" || bad "P5-05 sched: delay early: $out"
out=$(TRIGGER_EPOCH_MIN=5030 trigger_decide "$SCHED_BASE" s_dl 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_dl.*due=Y.*cause=delay' && ok "P5-05 sched: delay due=Y at N min elapsed" || bad "P5-05 sched: delay due: $out"
TRIGGER_STATE_FILE="$DSF" tpr_trigger_state_write dlx_s_dl 1 >/dev/null 2>&1
out=$(TRIGGER_EPOCH_MIN=5040 trigger_decide "$SCHED_BASE" s_dl 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_dl.*due=N' && ok "P5-05 sched: delay not due after once (dlx marker)" || bad "P5-05 sched: delay after once: $out"

# interval：首 tick due=Y（无 last-run）；写 last-run 后同 epoch due=N；N 分钟到 due=Y
out=$(TRIGGER_EPOCH_MIN=6000 trigger_decide "$SCHED_BASE" s_iv 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_iv.*due=Y.*cause=interval' && ok "P5-05 sched: interval first decide due=Y (no last-run)" || bad "P5-05 sched: interval first: $out"
TRIGGER_STATE_FILE="$DSF" tpr_trigger_state_write iv_s_iv 6000 >/dev/null 2>&1
out=$(TRIGGER_EPOCH_MIN=6000 trigger_decide "$SCHED_BASE" s_iv 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_iv.*due=N' && ok "P5-05 sched: interval due=N same epoch (last-run=now)" || bad "P5-05 sched: interval same epoch: $out"
out=$(TRIGGER_EPOCH_MIN=6014 trigger_decide "$SCHED_BASE" s_iv 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_iv.*due=N' && ok "P5-05 sched: interval due=N before 15min (14<15)" || bad "P5-05 sched: interval 14: $out"
out=$(TRIGGER_EPOCH_MIN=6015 trigger_decide "$SCHED_BASE" s_iv 0900 0 "$DSF")
echo "$out" | grep -q 'task=s_iv.*due=Y.*cause=interval' && ok "P5-05 sched: interval due=Y at 15min elapsed" || bad "P5-05 sched: interval 15: $out"

# cron：全字段匹配 due=Y / 非匹配分钟 due=N / cn_ 键存在 due=N（同日去重）
out=$(TRIGGER_TODAY=20260906 trigger_decide "$SCHED_BASE" s_cr 0000 0 "$DSF")
echo "$out" | grep -q 'task=s_cr.*due=Y.*cause=cron' && ok "P5-05 sched: cron due=Y when all 5 fields match (2026-09-06 00:00)" || bad "P5-05 sched: cron match: $out"
out=$(TRIGGER_TODAY=20260906 trigger_decide "$SCHED_BASE" s_crx 0000 0 "$DSF")
echo "$out" | grep -q 'task=s_crx.*due=N' && ok "P5-05 sched: cron due=N on non-matching minute (30≠00)" || bad "P5-05 sched: cron miss: $out"
TRIGGER_STATE_FILE="$DSF" tpr_trigger_state_write cn_s_cr 20260906 >/dev/null 2>&1
out=$(TRIGGER_TODAY=20260906 trigger_decide "$SCHED_BASE" s_cr 0000 0 "$DSF")
echo "$out" | grep -q 'task=s_cr.*due=N' && ok "P5-05 sched: cron due=N after cn_ key (same-day dedup)" || bad "P5-05 sched: cron dedup: $out"

# boot_completed：上下文=0 due=N；=1 due=Y；bc_ 键存在 due=N
out=$(TRIGGER_BOOT_COMPLETED_CONTEXT=0 trigger_decide "$SCHED_BASE" s_bc 0700 0 "$DSF")
echo "$out" | grep -q 'task=s_bc.*due=N' && ok "P5-05 sched: boot_completed due=N when context=0" || bad "P5-05 sched: bc ctx0: $out"
out=$(TRIGGER_BOOT_COMPLETED_CONTEXT=1 trigger_decide "$SCHED_BASE" s_bc 0700 0 "$DSF")
echo "$out" | grep -q 'task=s_bc.*due=Y.*cause=boot_completed' && ok "P5-05 sched: boot_completed due=Y when context=1" || bad "P5-05 sched: bc ctx1: $out"
TRIGGER_STATE_FILE="$DSF" tpr_trigger_state_write bc_s_bc 20260906 >/dev/null 2>&1
out=$(TRIGGER_BOOT_COMPLETED_CONTEXT=1 trigger_decide "$SCHED_BASE" s_bc 0700 0 "$DSF")
echo "$out" | grep -q 'task=s_bc.*due=N' && ok "P5-05 sched: boot_completed due=N after bc_ key (once per boot)" || bad "P5-05 sched: bc dedup: $out"

# ── scheduler_tick 端到端：oneshot 自删 + rearm 持久化 + cycle 去重 ────────
# oneshot：执行 → 任务自删（sched_execute_one 后置）
: > "$SCHED_EXEC_LOG"
SCHED_CYCLE_NOW=202609060830 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0830" >/dev/null 2>&1
grep -q '^s_ose|echo oneshot-e2e$' "$SCHED_EXEC_LOG" && ok "P5-05 sched: oneshot executed via scheduler_tick at 08:30" || bad "P5-05 sched: oneshot e2e exec missing (log=$(cat "$SCHED_EXEC_LOG"))"
registry_has_task s_ose && bad "P5-05 sched: oneshot task still present after exec (self-delete missing)" || ok "P5-05 sched: oneshot self-delete after execution"

# delay：首 tick 建基准不执行；N 分钟后执行一次；执行后不再执行（dlx 键）
rm -f "$SCHED_SF"
: > "$SCHED_EXEC_LOG"
SCHED_CYCLE_NOW=202609060900 TRIGGER_EPOCH_MIN=1000 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0900" >/dev/null 2>&1
grep -q '^s_dl|' "$SCHED_EXEC_LOG" && bad "P5-05 sched: delay executed on first tick (must arm)" || ok "P5-05 sched: delay first tick arms base, not executed"
[ "$(TRIGGER_STATE_FILE="$SCHED_SF" tpr_trigger_state_read dl_s_dl)" = "1000" ] && ok "P5-05 sched: delay base dl_s_dl=1000 persisted (e2e)" || bad "P5-05 sched: delay base e2e missing"
SCHED_CYCLE_NOW=202609061029 TRIGGER_EPOCH_MIN=1029 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0900" >/dev/null 2>&1
grep -q '^s_dl|' "$SCHED_EXEC_LOG" && bad "P5-05 sched: delay executed before N min (29<30)" || ok "P5-05 sched: delay not due before N min (e2e)"
SCHED_CYCLE_NOW=202609061030 TRIGGER_EPOCH_MIN=1030 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0900" >/dev/null 2>&1
grep -q '^s_dl|echo delay-run$' "$SCHED_EXEC_LOG" && ok "P5-05 sched: delay executed once at N min elapsed (e2e)" || bad "P5-05 sched: delay e2e exec missing (log=$(cat "$SCHED_EXEC_LOG"))"
SCHED_CYCLE_NOW=202609061040 TRIGGER_EPOCH_MIN=1040 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0900" >/dev/null 2>&1
[ "$(grep -c '^s_dl|' "$SCHED_EXEC_LOG")" -eq 1 ] && ok "P5-05 sched: delay not re-executed after once (dlx, e2e)" || bad "P5-05 sched: delay re-exec count=$(grep -c '^s_dl|' "$SCHED_EXEC_LOG")"

# interval：首 tick 执行；同分钟再 tick 不重复（cycle 去重 + iv 键）；N 分钟后再执行
rm -f "$SCHED_SF"
: > "$SCHED_EXEC_LOG"
SCHED_CYCLE_NOW=202609061000 TRIGGER_EPOCH_MIN=7000 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "1000" >/dev/null 2>&1
grep -q '^s_iv|echo interval-run$' "$SCHED_EXEC_LOG" && ok "P5-05 sched: interval executed on first tick" || bad "P5-05 sched: interval first exec missing"
[ "$(TRIGGER_STATE_FILE="$SCHED_SF" tpr_trigger_state_read iv_s_iv)" = "7000" ] && ok "P5-05 sched: interval last-run iv_s_iv=7000 persisted" || bad "P5-05 sched: interval iv key missing"
SCHED_CYCLE_NOW=202609061000 TRIGGER_EPOCH_MIN=7000 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "1000" >/dev/null 2>&1
[ "$(grep -c '^s_iv|' "$SCHED_EXEC_LOG")" -eq 1 ] && ok "P5-05 sched: interval not re-executed same cycle (sched_cycle_seen + iv key)" || bad "P5-05 sched: interval same-cycle re-exec (count=$(grep -c '^s_iv|' "$SCHED_EXEC_LOG"))"
SCHED_CYCLE_NOW=202609061015 TRIGGER_EPOCH_MIN=7015 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "1015" >/dev/null 2>&1
[ "$(grep -c '^s_iv|' "$SCHED_EXEC_LOG")" -eq 2 ] && ok "P5-05 sched: interval re-executed after N min elapsed" || bad "P5-05 sched: interval re-exec count=$(grep -c '^s_iv|' "$SCHED_EXEC_LOG")"

# cron：全字段匹配首 tick 执行；同日再 tick（跨 cycle token）不重复（cn_ 键）
rm -f "$SCHED_SF"
: > "$SCHED_EXEC_LOG"
SCHED_CYCLE_NOW=202609060000 TRIGGER_TODAY=20260906 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0000" >/dev/null 2>&1
grep -q '^s_cr|echo cron-run$' "$SCHED_EXEC_LOG" && ok "P5-05 sched: cron executed when all 5 fields match (TRIGGER_TODAY=20260906)" || bad "P5-05 sched: cron first exec missing"
[ "$(TRIGGER_STATE_FILE="$SCHED_SF" tpr_trigger_state_read cn_s_cr)" = "20260906" ] && ok "P5-05 sched: cron cn_s_cr=20260906 persisted (day-level dedup key)" || bad "P5-05 sched: cron cn key missing"
SCHED_CYCLE_NOW=202609060001 TRIGGER_TODAY=20260906 scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0001" >/dev/null 2>&1
[ "$(grep -c '^s_cr|' "$SCHED_EXEC_LOG")" -eq 1 ] && ok "P5-05 sched: cron not re-executed same day (cn_ key, cycle bypassed)" || bad "P5-05 sched: cron re-exec same day (count=$(grep -c '^s_cr|' "$SCHED_EXEC_LOG"))"

# boot_completed：上下文=0 不执行；=1 首 tick 执行；再 tick 不重复（bc_ 键）
rm -f "$SCHED_SF"
: > "$SCHED_EXEC_LOG"
SCHED_CYCLE_NOW=202609060700 TRIGGER_BOOT_COMPLETED_CONTEXT=0 TRIGGER_TODAY=20260906 \
    scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0700" >/dev/null 2>&1
grep -q '^s_bc|' "$SCHED_EXEC_LOG" && bad "P5-05 sched: boot_completed executed with context=0 (forbidden)" || ok "P5-05 sched: boot_completed not executed with context=0"
SCHED_CYCLE_NOW=202609060701 TRIGGER_BOOT_COMPLETED_CONTEXT=1 TRIGGER_TODAY=20260906 \
    scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0701" >/dev/null 2>&1
grep -q '^s_bc|echo bootcomp-run$' "$SCHED_EXEC_LOG" && ok "P5-05 sched: boot_completed executed with context=1" || bad "P5-05 sched: boot_completed not executed (log=$(cat "$SCHED_EXEC_LOG"))"
[ "$(TRIGGER_STATE_FILE="$SCHED_SF" tpr_trigger_state_read bc_s_bc)" = "20260906" ] && ok "P5-05 sched: boot_completed bc_s_bc=20260906 persisted (once key)" || bad "P5-05 sched: bc key missing"
SCHED_CYCLE_NOW=202609060702 TRIGGER_BOOT_COMPLETED_CONTEXT=1 TRIGGER_TODAY=20260906 \
    scheduler_tick "$SCHED_BASE" "$SCHED_CFG" "$SCHED_TASKS" "0702" >/dev/null 2>&1
[ "$(grep -c '^s_bc|' "$SCHED_EXEC_LOG")" -eq 1 ] && ok "P5-05 sched: boot_completed not re-executed across ticks (bc_ key)" || bad "P5-05 sched: boot_completed re-exec (count=$(grep -c '^s_bc|' "$SCHED_EXEC_LOG"))"

# ── §nextdue：P5-08 next_due 真计算（统一返回距下次命中秒数；注入确定性）──────
# oneshot：距 HHMM 秒数（精确分钟=0；未来=当天差值；已过=明天同刻）
out=$(TRIGGER_DECISION_NOW=0830 provider_dispatch trigger oneshot next_due oneshot:0830); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "0" ] && ok "P5-08 next_due: oneshot exact minute -> 0" || bad "P5-08 next_due: oneshot now out=$out rc=$rc"
out=$(TRIGGER_DECISION_NOW=1000 provider_dispatch trigger oneshot next_due oneshot:0830)
[ "$out" = "81000" ] && ok "P5-08 next_due: oneshot passed (08:30 after 10:00) -> 81000s next day" || bad "P5-08 next_due: oneshot passed=$out"
out=$(TRIGGER_DECISION_NOW=0900 provider_dispatch trigger oneshot next_due oneshot:1000)
[ "$out" = "3600" ] && ok "P5-08 next_due: oneshot future same day -> 3600s" || bad "P5-08 next_due: oneshot future=$out"
# delay：读 dl_<tid> 基准 + N 分钟；缺失基准 / dlx 已消费 → 不可预测（rc1）
rm -f "$DSF"   # 清 §sched 残留状态（dlx 等），保证基准重建
TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_dl" tpr_trigger_state_write dl_s_dl 5000 >/dev/null 2>&1
out=$(TRIGGER_EPOCH_MIN=5010 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_dl" provider_dispatch trigger delay next_due delay:30)
[ "$out" = "1200" ] && ok "P5-08 next_due: delay base+N diff -> 1200s (20min*60)" || bad "P5-08 next_due: delay=$out"
out=$(TRIGGER_EPOCH_MIN=5035 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_dl" provider_dispatch trigger delay next_due delay:30)
[ "$out" = "0" ] && ok "P5-08 next_due: delay elapsed -> 0" || bad "P5-08 next_due: delay elapsed=$out"
TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_dl" tpr_trigger_state_write dlx_s_dl 1 >/dev/null 2>&1
TRIGGER_EPOCH_MIN=5040 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_dl" \
    provider_dispatch trigger delay next_due delay:30 >/dev/null 2>&1 \
    && bad "P5-08 next_due: delay after once (dlx) should be unpredictable" \
    || ok "P5-08 next_due: delay consumed (dlx) -> rc1"
# interval：读 iv_<tid> last-run + N 分钟；last 缺失 → 不可预测（rc1）
TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_iv" tpr_trigger_state_write iv_s_iv 7000 >/dev/null 2>&1
out=$(TRIGGER_EPOCH_MIN=7010 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_iv" provider_dispatch trigger interval next_due interval:15)
[ "$out" = "300" ] && ok "P5-08 next_due: interval last+N diff -> 300s" || bad "P5-08 next_due: interval=$out"
out=$(TRIGGER_EPOCH_MIN=7020 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_iv" provider_dispatch trigger interval next_due interval:15)
[ "$out" = "0" ] && ok "P5-08 next_due: interval elapsed -> 0" || bad "P5-08 next_due: interval elapsed=$out"
rm -f "$DSF"
TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_iv" \
    provider_dispatch trigger interval next_due interval:15 >/dev/null 2>&1 \
    && bad "P5-08 next_due: interval without last-run should be unpredictable" \
    || ok "P5-08 next_due: interval no last-run -> rc1"
# cron：5 段全字段推进找首次匹配（分钟级，TRIGGER_TODAY+TRIGGER_DECISION_NOW 确定性）
out=$(TRIGGER_TODAY=20260906 TRIGGER_DECISION_NOW=0830 provider_dispatch trigger cron next_due 'cron:0 * * * *')
[ "$out" = "1800" ] && ok "P5-08 next_due: cron :00 hourly at 08:30 -> 1800s" || bad "P5-08 next_due: cron hourly=$out"
out=$(TRIGGER_TODAY=20260906 TRIGGER_DECISION_NOW=0833 provider_dispatch trigger cron next_due 'cron:*/15 * * * *')
[ "$out" = "720" ] && ok "P5-08 next_due: cron */15 at 08:33 -> 720s (08:45)" || bad "P5-08 next_due: cron step=$out"
out=$(TRIGGER_TODAY=20260906 TRIGGER_DECISION_NOW=0830 provider_dispatch trigger cron next_due 'cron:30 8 * * *')
[ "$out" = "0" ] && ok "P5-08 next_due: cron current minute match -> 0" || bad "P5-08 next_due: cron now=$out"
out=$(TRIGGER_TODAY=20260906 TRIGGER_DECISION_NOW=0830 provider_dispatch trigger cron next_due 'cron:0 0 * * *')
[ "$out" = "55800" ] && ok "P5-08 next_due: cron midnight from 08:30 -> 55800s (15.5h)" || bad "P5-08 next_due: cron midnight=$out"
# advanced weekly：当天未到 → 当天；已过 → 下一匹配日
MON=$(date -d 'monday' +%Y%m%d 2>/dev/null || date +%Y%m%d)
out=$(TRIGGER_TODAY=$MON TRIGGER_DECISION_NOW=0900 provider_dispatch trigger advanced next_due 'weekly:1:1000')
[ "$out" = "3600" ] && ok "P5-08 next_due: advanced weekly today 10:00 (later) -> 3600s" || bad "P5-08 next_due: weekly today=$out"
out=$(TRIGGER_TODAY=$MON TRIGGER_DECISION_NOW=0900 provider_dispatch trigger advanced next_due 'weekly:1:0800')
[ "$out" = "601200" ] && ok "P5-08 next_due: advanced weekly passed today -> next Mon 08:00 601200s" || bad "P5-08 next_due: weekly next=$out"
out=$(TRIGGER_TODAY=20260906 TRIGGER_DECISION_NOW=0900 provider_dispatch trigger advanced next_due 'monthly:15:1200')
[ "$out" = "788400" ] && ok "P5-08 next_due: advanced monthly 09-15 12:00 from 09-06 09:00 -> 788400s" || bad "P5-08 next_due: monthly=$out"
# bootcompleted：上下文=1（未消费）→ 0；已消费（bc_ 键）/上下文=0 → 不可预测
out=$(TRIGGER_BOOT_COMPLETED_CONTEXT=1 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_bc" provider_dispatch trigger bootcompleted next_due boot_completed)
[ "$out" = "0" ] && ok "P5-08 next_due: bootcompleted context=1 (not fired) -> 0" || bad "P5-08 next_due: bootcompleted out=$out rc=$?"
TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_bc" tpr_trigger_state_write bc_s_bc 20260906 >/dev/null 2>&1
TRIGGER_BOOT_COMPLETED_CONTEXT=1 TRIGGER_STATE_FILE="$DSF" TRIGGER_TASK_ID="s_bc" \
    provider_dispatch trigger bootcompleted next_due boot_completed >/dev/null 2>&1 \
    && bad "P5-08 next_due: bootcompleted fired (bc_ key) should be unpredictable" \
    || ok "P5-08 next_due: bootcompleted after fire -> rc1"

# ── §posix ────────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P5-04 POSIX: dash -n ok (lib incl. P5-04 helpers)" || bad "P5-04 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P5-04 POSIX: bash -n ok (dash unavailable)" || bad "P5-04 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p5-trigger tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
