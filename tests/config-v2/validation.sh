#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# validation.sh — Task v2 编辑校验矩阵（P3-06 Task Editor 后端底座 §23）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖：
#   §id      ID 路径穿越/字符集拒绝；
#   §enum    trigger 枚举（未实现族拒绝）+ action/health/recovery 枚举；
#   §app     App Action 注入全部拒绝（复用 P2-10 安全门）；
#   §script  recovery/action script 绝对路径且可读；
#   §num     全部数值范围钳制（retry/advanced）；
#   §atomic  tcfg_apply_task 原子性（非法不写盘、失败旧配置不变、tmp 清理、payload id 一致性）；
#   §back    前端校验不是安全边界：非法 payload 直接调用后端仍被拒；
#   §posix   dash -n。
# 加载：`. ./$RTLIB`（TCFG_DIR 先 export 隔离）。
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
mkdir -p "$TCFG_DIR"
. ./$RTLIB

# ── 助手：构造合法 payload ────────────────────────────────────────────────
ok_task() {   # <id> → 合法 Task v2 内容
    cat <<EOF
schema_version=2
id=$1
name=demo
enabled=1
description=validation
trigger=08:30
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
EOF
}

# ── §id：ID 路径穿越 / 字符集 ────────────────────────────────────────────
tcfg_editor_id_ok task_good && ok "P3-06 id: valid id accepted" || bad "P3-06 id: valid id rejected"
tcfg_editor_id_ok '../evil' && bad "P3-06 id: path traversal ../ allowed" || ok "P3-06 id: ../ rejected"
tcfg_editor_id_ok 'a/b' && bad "P3-06 id: slash allowed" || ok "P3-06 id: slash rejected"
tcfg_editor_id_ok 'a\\b' && bad "P3-06 id: backslash allowed" || ok "P3-06 id: backslash rejected"
tcfg_editor_id_ok 'bad space' && bad "P3-06 id: space allowed" || ok "P3-06 id: space rejected"
tcfg_editor_id_ok '' && bad "P3-06 id: empty allowed" || ok "P3-06 id: empty rejected"

# ── §enum：trigger 枚举 ───────────────────────────────────────────────────
for t in boot '08:30' '0830' 'weekly:1:0800' 'nweekly:2:5:1400' 'monthly:01:0000' 'nmonthly:3:15:1200' 'yearly:12:25:0800'; do
    tcfg_editor_trigger_ok "$t" || { bad "P3-06 enum: implemented trigger rejected: $t"; }
done
ok "P3-06 enum: all implemented trigger families accepted"
for t in 'boot_completed' 'delay' 'interval' 'cron:0 8 * * *' 'oneshot'; do
    if tcfg_editor_trigger_ok "$t"; then bad "P3-06 enum: unimplemented trigger allowed: $t"; fi
done
ok "P3-06 enum: unimplemented triggers rejected"

# ── §app：App Action 注入全部拒绝（复用 P2-10）──────────────────────────
for bad in \
    'app:package:moe.shizuku.privileged.api;rm -rf /' \
    'app:package:com.example.app" ; su -c id' \
    'app:activity:com.example/.Main$(id)' \
    'app:broadcast:com.example.ACTION";sh -c id' \
    'app:unknown:com.example.x' \
    'app:package:has space' \
    'app:package:com.example/app:extra' \
    'app:package:com.example.app$(id)'; do
    if tcfg_editor_action_ok app "$bad"; then bad "P3-06 app: injection allowed: $bad"; fi
done
ok "P3-06 app: App Action injection specs all rejected (P2-10 security gate)"
tcfg_editor_action_ok app 'app:package:com.example.app' && ok "P3-06 app: valid app:package accepted" || bad "P3-06 app: valid app rejected"
tcfg_editor_action_ok app 'app:activity:com.example/.Main' && ok "P3-06 app: valid activity accepted" || bad "P3-06 app: valid activity rejected"
tcfg_editor_action_ok app 'app:broadcast:com.example.ACTION_GO' && ok "P3-06 app: valid broadcast accepted" || bad "P3-06 app: valid broadcast rejected"
tcfg_editor_action_ok app 'app:broadcast:com.example.ACTION_GO:msg=hello,count=2' && ok "P3-06 app: valid broadcast+extras accepted" || bad "P3-06 app: valid broadcast+extras rejected"
tcfg_editor_action_ok app 'app:service:com.example/.Svc' && ok "P3-06 app: valid service accepted" || bad "P3-06 app: valid service rejected"

# ── §script：绝对路径且可读 ──────────────────────────────────────────────
touch "$T/recover.sh"
tcfg_editor_recovery_ok script "$T/recover.sh" && ok "P3-06 script: absolute readable recovery script accepted" || bad "P3-06 script: abs script rejected"
tcfg_editor_recovery_ok script 'relative.sh' && bad "P3-06 script: relative script allowed" || ok "P3-06 script: relative path rejected"
tcfg_editor_recovery_ok script "/nonexistent/xyz.sh" && bad "P3-06 script: nonexistent script allowed" || ok "P3-06 script: nonexistent rejected"
touch "$T/act.sh"
tcfg_editor_action_ok script "$T/act.sh" && ok "P3-06 script: action script abs path accepted" || bad "P3-06 script: action script rejected"
tcfg_editor_action_ok script 'act.sh' && bad "P3-06 script: action relative allowed" || ok "P3-06 script: action relative rejected"

# ── §num：数值范围钳制 ───────────────────────────────────────────────────
tcfg_editor_num 0 0 100 && ok "P3-06 num: 0 in range" || bad "P3-06 num: 0 rejected"
tcfg_editor_num 100 0 100 && ok "P3-06 num: 100 in range" || bad "P3-06 num: 100 rejected"
tcfg_editor_num 101 0 100 && bad "P3-06 num: 101 allowed" || ok "P3-06 num: >100 rejected"
tcfg_editor_num -1 0 100 && bad "P3-06 num: negative allowed" || ok "P3-06 num: negative rejected"
tcfg_editor_num abc 0 100 && bad "P3-06 num: non-numeric allowed" || ok "P3-06 num: non-numeric rejected"
tcfg_editor_num 86400 0 86400 && ok "P3-06 num: 86400 boundary" || bad "P3-06 num: boundary rejected"
tcfg_editor_num 86401 0 86400 && bad "P3-06 num: 86401 allowed" || ok "P3-06 num: >86400 rejected"
tcfg_editor_num 1000000 0 1000000 && ok "P3-06 num: 1M boundary" || bad "P3-06 num: 1M rejected"

# ── §atomic：原子性 ──────────────────────────────────────────────────────
echo managed > "$TCFG_DIR/MANAGED"
GOOD=$(ok_task task_v)
tcfg_apply_task task_v "$GOOD"
rc=$?
[ "$rc" -eq 0 ] && ok "P3-06 atomic: valid apply rc=0" || bad "P3-06 atomic: valid apply rc=$rc"
[ -f "$TCFG_DIR/task_v.task" ] && ok "P3-06 atomic: task file created" || bad "P3-06 atomic: file missing"

# 非法 payload → rc=1，不写盘，旧配置不变
MD5_BEFORE=$(md5sum "$TCFG_DIR/task_v.task" | cut -d' ' -f1)
BAD_PAYLOAD=$(printf 'schema_version=2\nid=task_v\ntrigger=boot_completed\naction.type=command\naction.command=echo x\n')
tcfg_apply_task task_v "$BAD_PAYLOAD" >/dev/null 2>&1
rcb=$?
[ "$rcb" -eq 1 ] && ok "P3-06 atomic: invalid apply rc=1" || bad "P3-06 atomic: invalid rc=$rcb"
[ "$(md5sum "$TCFG_DIR/task_v.task" | cut -d' ' -f1)" = "$MD5_BEFORE" ] && ok "P3-06 atomic: old config byte-identical after failed save" || bad "P3-06 atomic: config changed"
ls "$TCFG_DIR"/*.tmp.* >/dev/null 2>&1 && bad "P3-06 atomic: tmp leftover" || ok "P3-06 atomic: no tmp leftover"
# payload 内 id= 必须等于请求 id（防保存后 reload 隔离）
MISMATCH=$(printf 'schema_version=2\nid=other_id\ntrigger=boot\naction.type=command\naction.command=echo x\n')
tcfg_apply_task task_v "$MISMATCH" >/dev/null 2>&1 && bad "P3-06 atomic: payload id mismatch accepted" || ok "P3-06 atomic: payload id mismatch rejected (config unchanged)"

# ── §back：前端校验不是安全边界（直接后端调用仍拒绝）───────────────────
# 绕过前端直接提交非法 payload（路径穿越 id / 未实现 trigger / 越界数值）→ 后端仍拒
BAD1=$(printf 'schema_version=2\nid=../../etc/passwd\ntrigger=boot\naction.type=command\naction.command=echo x\n')
if tcfg_editor_validate_payload "$BAD1"; then bad "P3-06 back: path traversal id passed backend"; else ok "P3-06 back: path traversal id rejected by backend"; fi
BAD2=$(printf 'schema_version=2\nid=t2\ntrigger=cron:0 8 * * *\naction.type=command\naction.command=echo x\n')
if tcfg_editor_validate_payload "$BAD2"; then bad "P3-06 back: unimplemented trigger passed backend"; else ok "P3-06 back: unimplemented trigger rejected by backend"; fi
BAD3=$(printf 'schema_version=2\nid=t3\ntrigger=boot\naction.type=command\naction.command=echo x\nretry.max=999\n')
if tcfg_editor_validate_payload "$BAD3"; then bad "P3-06 back: out-of-range retry passed backend"; else ok "P3-06 back: out-of-range retry rejected by backend"; fi
# 杂散行（非 key=value）被 lenient 跳过，不影响整体校验（schema 宽容原则）
GOOD4=$(ok_task t4)
STRAY=$(printf '%s\nrm -rf /' "$GOOD4")
if tcfg_editor_validate_payload "$STRAY"; then ok "P3-06 back: stray line skipped leniently"; else bad "P3-06 back: stray line broke validation"; fi
# 多行命令的合法编码是字面 \n（两字符转义）；真实换行会把记录拆行 -> 不引入注入面
MULTI=$(printf 'schema_version=2\nid=tm\ntrigger=boot\naction.type=command\naction.command=echo a\\nb\n')
if tcfg_editor_validate_payload "$MULTI"; then ok "P3-06 back: literal \n (two-char) command accepted"; else bad "P3-06 back: literal \n command rejected"; fi
BADDESC="$(ok_task task_d | sed 's#^description=.*#description=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#')"
if tcfg_editor_validate_payload "$BADDESC"; then bad "P3-06 back: oversize description passed"; else ok "P3-06 back: oversize description rejected"; fi

# ── §posix ────────────────────────────────────────────────────────────────
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-06 POSIX: dash -n ok (lib incl. §23)" || bad "P3-06 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-06 POSIX: bash -n ok (dash unavailable)" || bad "P3-06 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "config-v2 validation tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
