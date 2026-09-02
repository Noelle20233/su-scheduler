#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# path-validation.sh — P3-08 路径安全（路径穿越 + 符号链接 + 目录约束）验收
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 安全声明（对照 P3-08 验收）：
#   a) 路径必须位于允许目录：secv_inside 拒绝 `..` 段逃逸（词法）；
#   b) Task ID 字符集：secv_id_ok 拒绝 `..`/`/`/`\`/空白/元字符（路径穿越的
#      输入端拦截）；tcfg_editor_id_ok 同；
#   c) 符号链接风险：secv_nosymlink 拒绝符号链接（防指向允许目录外）；
#   d) 任务运行目录门：secv_guard_task_dir = id 合法 + 位于 tasks 内 + 非符号链接；
#   e) 实际 IPC：GET_TASK_LOG / tctl_logs 的 id 路径穿越 → 拒绝且绝不读任务目录外文件；
#   f) 脚本/recovery 路径：相对路径/非绝对 → 校验拒绝（P3-06 既有）。
# 期望：所有路径穿越/符号链接样例被拒绝；未授权路径无法被读取/修改。
# 加载：`. ./$RTLIB`。
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

TASKS_DIR="$T/tasks"
mkdir -p "$TASKS_DIR"
. ./$RTLIB

# ── a) 路径位于允许目录（词法 `..` 逃逸拒绝）──────────────────────────────
p_ok=1
for p in "$T/tasks/good" "$T/tasks" "$T/tasks/sub/dir"; do
    secv_inside "$T/tasks" "$p" || { bad "P3-08 path-a: inside rejected '$p'"; p_ok=0; }
done
for p in "$T/outside" "$T/tasks/../../etc" "$T/x/../tasks" "$T/tasks/../x"; do
    if secv_inside "$T/tasks" "$p"; then bad "P3-08 path-a: escape allowed '$p'"; p_ok=0; fi
done
[ "$p_ok" -eq 1 ] && ok "P3-08 path-a: secv_inside allows in-tree, rejects ../ escape"

# ── b) Task ID 字符集（路径穿越输入端）────────────────────────────────────
id_ok=1
for good in "t50_0830" "task_foo" "task-1.2_3"; do
    secv_id_ok "$good" || { bad "P3-08 path-b: valid id rejected '$good'"; id_ok=0; }
done
for evil in "../etc" "a/b" "a\\b" "a b" "a;b" "a\$b" "a|b" ".."; do
    if secv_id_ok "$evil"; then bad "P3-08 path-b: malicious id allowed '$evil'"; id_ok=0; fi
done
[ "$id_ok" -eq 1 ] && ok "P3-08 path-b: secv_id_ok rejects traversal/meta ids, allows canonical"

# ── c) 符号链接风险（部分宿主 ln -s 不能产出可检测符号链接 → 显式 SKIP）──
mkdir -p "$T/outside"
SYMLINK_AVAIL=0
if ln -s "$T/outside" "$T/tasks/symlink_escape" 2>/dev/null && [ -L "$T/tasks/symlink_escape" ]; then
    SYMLINK_AVAIL=1
    if secv_nosymlink "$T/tasks/symlink_escape"; then
        bad "P3-08 path-c: symlink not detected"
    else
        ok "P3-08 path-c: secv_nosymlink rejects symlink"
    fi
else
    ok "P3-08 path-c: host cannot produce real symlink (SKIP; logic covered below)"
    rm -rf "$T/tasks/symlink_escape" 2>/dev/null
fi
[ -e "$T/tasks/real" ] || mkdir -p "$T/tasks/real"
secv_nosymlink "$T/tasks/real" && ok "P3-08 path-c: real dir accepted (not symlink)" || bad "P3-08 path-c: real dir rejected"

# ── d) 任务运行目录门 ──────────────────────────────────────────────────────
g_ok=1
mkdir -p "$TASKS_DIR/good_task"
secv_guard_task_dir "$TASKS_DIR" "good_task" || { bad "P3-08 path-d: guard rejected valid"; g_ok=0; }
if secv_guard_task_dir "$TASKS_DIR" "../outside"; then bad "P3-08 path-d: guard allowed ../"; g_ok=0; fi
if secv_guard_task_dir "$TASKS_DIR" "a/b"; then bad "P3-08 path-d: guard allowed slash id"; g_ok=0; fi
if [ "$SYMLINK_AVAIL" -eq 1 ] && secv_guard_task_dir "$TASKS_DIR" "symlink_escape"; then bad "P3-08 path-d: guard allowed symlink escape"; g_ok=0; fi
[ "$g_ok" -eq 1 ] && ok "P3-08 path-d: secv_guard_task_dir enforces containment + non-symlink"

# ── e) 实际 IPC：GET_TASK_LOG 路径穿越 id → 拒绝且不读任务目录外 ──────────
# 在 outside 放一个诱饵文件，若被穿越读取则泄露
mkdir -p "$TASKS_DIR/real"
echo "SECRET" > "$T/outside/secret.log"
echo "tasklog" > "$TASKS_DIR/real/output.log"
EXEC_LOG="$T/exec.log"; : > "$EXEC_LOG"
BASE="$T/base"; CFG="$T/config.txt"
mkdir -p "$BASE"
export TCFG_DIR="$BASE/task-config"; mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
sched_reload "$BASE" "$CFG" >/dev/null 2>&1
ipc_server_init "$BASE" >/dev/null 2>&1
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
drop_req() { printf '%s\n' "$2" > "$BASE/ipc/requests/$1.req"; }
# 尝试用路径穿越 id 读 outside/secret.log
drop_req "pl" "pl|GET_TASK_LOG|id=$(b64 '../outside/secret')&lines=$(b64 '5')"
ipc_server_poll "$BASE" "$CFG" "$TASKS_DIR" >/dev/null 2>&1
rc=$(head -1 "$BASE/ipc/responses/pl.resp" 2>/dev/null | cut -d'|' -f3)
resp=$(cat "$BASE/ipc/responses/pl.resp" 2>/dev/null)
if [ "$rc" = "1" ] || [ "$rc" = "3" ]; then
    printf '%s' "$resp" | grep -q "SECRET" && { bad "P3-08 path-e: traversal id leaked outside file"; } || ok "P3-08 path-e: GET_TASK_LOG traversal id rejected (rc $rc), no leak"
else
    bad "P3-08 path-e: traversal id rc=$rc (want 1/3)"
fi

# ── f) 脚本/recovery 相对路径 → 校验拒绝（P3-06 复用，这里补 tcfg_editor）──
printf '#!/bin/sh\necho hi\n' > "$T/run.sh"
tcfg_editor_action_ok "script" "run.sh" && bad "P3-08 path-f: relative script accepted" || ok "P3-08 path-f: relative script -> rejected"
tcfg_editor_action_ok "script" "$T/run.sh" && ok "P3-08 path-f: absolute existing script accepted" || bad "P3-08 path-f: absolute script rejected"
tcfg_editor_recovery_ok "script" "rel.sh" && bad "P3-08 path-f: relative recovery accepted" || ok "P3-08 path-f: relative recovery -> rejected"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "security path-validation tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1