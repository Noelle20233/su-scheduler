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
