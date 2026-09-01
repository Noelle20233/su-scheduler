#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Canonical Task Config Store & Migration（P3-02）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P3-02 出口：双模式配置权威 + 持久化 + 迁移，8 项）：
#   1) 双模式判定：无 MANAGED → legacy；显式导入 → managed；
#   2) 旧 config.txt 无需修改即可运行：legacy adapter 原样解析 17 任务，
#      导入过程 config.txt 逐字节不变；
#   3) 导入：task-config/ 任务数 == config 激活行数（17），MANAGED + manifest；
#   4) 重复导入幂等：任务数不增、无重复 id、不覆盖既有条目；
#   5) 导入失败（config 缺失/损坏/零有效任务）→ 原 config 逐字节不变、
#      MANAGED 不写、无半成品（staging 清理）；
#   6) 配置写入中断不留半成品：tcfg_atomic_write 失败清理 tmp；
#   7) 迁移可回滚：tcfg_rollback 恢复备份 config 逐字节 + 移除 MANAGED →
#      legacy；导出兼容 config（行数 == 任务数）；
#   8) Managed 编辑（新建/改字段/删除）+ 新建 Task ID（task_ 命名空间，与
#      legacy t<line>_ 不冲突）+ POSIX（dash -n）+ 接线存在性。
# 加载：`. ./$RTLIB`（与 P2-02/03 套件同法；TCFG_DIR 先 export 做隔离）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

RTLIB="system/bin/su-scheduler-runtime"
DAEMON="system/bin/su-schedulerd"
CLI="system/bin/su-scheduler"
LEGACY_FIXTURE="tests/fixtures/legacy/config.txt"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export TCFG_DIR="$T/task-config"   # 隔离存储目录（先 export，tcfg_* 全部可见）
. ./$RTLIB

# ── 1) 双模式判定 ──────────────────────────────────────────────────────────
[ "$(tcfg_mode)" = "legacy" ] && ok "P3-02 mode: no marker -> legacy (default)" || bad "P3-02 mode: default not legacy"
tcfg_is_managed && bad "P3-02 mode: is_managed should be false" || ok "P3-02 mode: is_managed=false without marker"
[ "$(tcfg_task_count)" -eq 0 ] && ok "P3-02 mode: empty store count=0" || bad "P3-02 mode: count=$(tcfg_task_count)"

# ── 2) 旧 config.txt 无需修改即可运行（legacy adapter 原样）──────────────────
legacy_adapter_parse "$LEGACY_FIXTURE" "$T/legacy-out" >/dev/null 2>&1
n=$(ls "$T/legacy-out"/*.task 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -eq 17 ] && ok "P3-02 legacy: adapter still parses 17 tasks (C2 unchanged)" || bad "P3-02 legacy: adapter count=$n (expect 17)"

# 导入前快照（逐字节基准）
cp "$LEGACY_FIXTURE" "$T/orig.cfg"
ORIG_MD5=$(md5sum "$T/orig.cfg" | cut -d' ' -f1)

# ── 3) 导入：task-config/ 任务数 == 17，MANAGED + manifest ──────────────────
tcfg_import "$LEGACY_FIXTURE" >/dev/null 2>&1
rci=$?
[ "$rci" -eq 0 ] && ok "P3-02 import: rc=0" || bad "P3-02 import: rc=$rci"
[ "$(tcfg_mode)" = "managed" ] && ok "P3-02 import: mode now managed" || bad "P3-02 import: mode=$(tcfg_mode)"
[ "$(tcfg_task_count)" -eq 17 ] && ok "P3-02 import: task-config count=17 (== config active lines)" || bad "P3-02 import: count=$(tcfg_task_count)"
[ -f "$(tcfg_manifest_file)" ] && ok "P3-02 import: manifest written" || bad "P3-02 import: manifest missing"
md5now=$(md5sum "$LEGACY_FIXTURE" | cut -d' ' -f1)
[ "$md5now" = "$ORIG_MD5" ] && ok "P3-02 import: config.txt byte-identical (never rewritten)" || bad "P3-02 import: config.txt CHANGED"
# legacy id 保留（t<line>_<trigger> 命名空间不变）
grep -q '^id=t11_boot$' "$(tcfg_task_file t11_boot)" 2>/dev/null && ok "P3-02 import: legacy id t11_boot preserved" || bad "P3-02 import: t11_boot id missing"
[ "$(tcfg_get "$(tcfg_task_file t35_0915)" source.type)" = "block" ] && ok "P3-02 import: block task source.type=block kept" || bad "P3-02 import: block provenance lost"

# ── 4) 重复导入幂等（不产生重复 Task、不覆盖）────────────────────────────────
tcfg_import "$LEGACY_FIXTURE" >/dev/null 2>&1
rci=$?
[ "$rci" -eq 0 ] && ok "P3-02 reimport: rc=0 (idempotent)" || bad "P3-02 reimport: rc=$rci"
[ "$(tcfg_task_count)" -eq 17 ] && ok "P3-02 reimport: count stays 17 (no duplicates)" || bad "P3-02 reimport: count=$(tcfg_task_count)"
ids=$(tcfg_task_ids)
uniqids=$(printf '%s\n' "$ids" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
[ "$uniqids" -eq 17 ] && ok "P3-02 reimport: 17 unique ids (no dup task files)" || bad "P3-02 reimport: unique=$uniqids"

# ── 5) 导入失败 → 原 config 逐字节不变、无 MANAGED 半成品 ────────────────────
# 5a) config 缺失
tcfg_import "$T/missing.cfg" >/dev/null 2>&1
rcm=$?
[ "$rcm" -eq 2 ] && ok "P3-02 fail: missing config -> rc=2" || bad "P3-02 fail: missing rc=$rcm"
# 5b) 损坏 config（全部行含控制字符 → adapter 0 有效任务）
printf '08\x01:30 x\n23\x02:00 y\n' > "$T/bad.cfg"
BADMD5=$(md5sum "$T/bad.cfg" | cut -d' ' -f1)
tcfg_import "$T/bad.cfg" >/dev/null 2>&1
rcb=$?
[ "$rcb" -eq 1 ] && ok "P3-02 fail: corrupt config -> rc=1 (no valid tasks)" || bad "P3-02 fail: corrupt rc=$rcb"
[ "$(md5sum "$T/bad.cfg" | cut -d' ' -f1)" = "$BADMD5" ] && ok "P3-02 fail: corrupt config byte-identical" || bad "P3-02 fail: corrupt config CHANGED"
# 导入失败不产生半成品：无 staging、无 .tmp、MANAGED 仍是既有 managed（不降级）
ls "$(tcfg_dir)"/.staging.* >/dev/null 2>&1 && bad "P3-02 fail: staging leftover" || ok "P3-02 fail: no staging leftover"
ls "$(tcfg_dir)"/*.tmp.* >/dev/null 2>&1 && bad "P3-02 fail: tmp leftover" || ok "P3-02 fail: no tmp leftover"
[ -f "$(tcfg_managed_marker)" ] && ok "P3-02 fail: MANAGED intact (import fail doesn't remove managed)" || bad "P3-02 fail: MANAGED lost"
# 5c) 空/全注释 config → 零任务，rc=1
printf '# only a comment\n' > "$T/empty.cfg"
tcfg_import "$T/empty.cfg" >/dev/null 2>&1
rce=$?
[ "$rce" -eq 1 ] && ok "P3-02 fail: comment-only config -> rc=1" || bad "P3-02 fail: comment-only rc=$rce"

# ── 6) 配置写入中断不留半成品（原子写失败清理 tmp）───────────────────────────
# 失败路径：目标父路径是一个普通文件（mkdir -p 失败 → rc=2，无 tmp 残留）
: > "$T/notadir"
tcfg_atomic_write "$T/notadir/x" >/dev/null 2>&1
rcw=$?
[ "$rcw" -eq 2 ] && ok "P3-02 atomic: unwritable target -> rc=2" || bad "P3-02 atomic: rc=$rcw"
[ ! -e "$T/notadir/x" ] && ok "P3-02 atomic: no target on failure" || bad "P3-02 atomic: target left"
[ -z "$(ls "$T"/x.tmp.* 2>/dev/null)" ] && ok "P3-02 atomic: no tmp leftover on failure" || bad "P3-02 atomic: tmp left"
# 成功写：内容完整 + 无 tmp
echo "hello" | tcfg_atomic_write "$T/ok.txt" >/dev/null 2>&1
[ "$(cat "$T/ok.txt")" = "hello" ] && ok "P3-02 atomic: success write intact" || bad "P3-02 atomic: write corrupt"
[ -z "$(ls "$T"/ok.txt.tmp.* 2>/dev/null)" ] && ok "P3-02 atomic: no tmp after success" || bad "P3-02 atomic: tmp after success"

# ── 7) 迁移可回滚 + 导出 ────────────────────────────────────────────────────
# 7a) 回滚：恢复备份 config 逐字节 + 移除 MANAGED → legacy
cp "$LEGACY_FIXTURE" "$T/rollback.cfg"
tcfg_import "$T/rollback.cfg" >/dev/null 2>&1
# 用户后续改了 config（模拟），回滚应恢复导入时的备份
printf '99:99 echo touched\n' >> "$T/rollback.cfg"
tcfg_rollback "$T/rollback.cfg" >/dev/null 2>&1
rcr=$?
[ "$rcr" -eq 0 ] && ok "P3-02 rollback: rc=0" || bad "P3-02 rollback: rc=$rcr"
cmp -s "$T/rollback.cfg" "$LEGACY_FIXTURE" && ok "P3-02 rollback: config restored byte-identical (backup source)" || bad "P3-02 rollback: config NOT restored"
[ "$(tcfg_mode)" = "legacy" ] && ok "P3-02 rollback: mode back to legacy (MANAGED removed)" || bad "P3-02 rollback: mode=$(tcfg_mode)"
# 回滚后文件保留（惰性，不误删用户数据）
[ -f "$(tcfg_task_file t11_boot)" ] && ok "P3-02 rollback: task files retained (inert in legacy)" || bad "P3-02 rollback: files removed"
# 7b) 导出：managed 下 task-config → 兼容 config，行数 == 任务数
tcfg_import "$LEGACY_FIXTURE" >/dev/null 2>&1
tcfg_export "$T/export.cfg" >/dev/null 2>&1
rcex=$?
[ "$rcex" -eq 0 ] && ok "P3-02 export: rc=0" || bad "P3-02 export: rc=$rcex"
[ "$(wc -l < "$T/export.cfg" | tr -d ' ')" -eq 17 ] && ok "P3-02 export: 17 lines (== task count)" || bad "P3-02 export: lines=$(wc -l < "$T/export.cfg")"
n2=$(legacy_adapter_parse "$T/export.cfg" "$T/re-parse" >/dev/null 2>&1; ls "$T/re-parse"/*.task 2>/dev/null | wc -l | tr -d ' ')
[ "$n2" -ge 1 ] && ok "P3-02 export: exported config re-parses ($n2 tasks)" || bad "P3-02 export: re-parse failed"

# ── 8) Managed 编辑 + 新建 ID + 接线 ───────────────────────────────────────
# 8a) 新建（task_ 命名空间，不与 legacy t<line>_ 冲突）+ 字段更新 + 删除
newid=$(tcfg_new_id "weekly:1:0800")
case "$newid" in
    task_*) ok "P3-02 new: id='$newid' uses task_ namespace (no t<line>_ collision)" ;;
    *) bad "P3-02 new: id='$newid' unexpected" ;;
esac
tcfg_new_task "$newid" "weekly:1:0800" "echo hi" >/dev/null 2>&1
rcn=$?
[ "$rcn" -eq 0 ] && ok "P3-02 new: tcfg_new_task rc=0" || bad "P3-02 new: rc=$rcn"
[ -f "$(tcfg_task_file "$newid")" ] && ok "P3-02 new: task file created" || bad "P3-02 new: file missing"
tcfg_set_field "$newid" "enabled" "0" >/dev/null 2>&1
[ "$(tcfg_get "$(tcfg_task_file "$newid")" enabled)" = "0" ] && ok "P3-02 new: set_field enabled=0 persisted" || bad "P3-02 new: set_field failed"
tcfg_remove_task "$newid" >/dev/null 2>&1
[ ! -f "$(tcfg_task_file "$newid")" ] && ok "P3-02 new: remove_task ok" || bad "P3-02 new: remove failed"
# 8b) legacy 模式下新建应被拒（Managed 语义：先导入）
unset TCFG_DIR
TCFG_DIR="$T/legacy-store" bash -c ". ./$RTLIB; tcfg_mode" >/dev/null 2>&1
[ "$(TCFG_DIR="$T/legacy-store" bash -c ". ./$RTLIB; tcfg_mode")" = "legacy" ] && ok "P3-02 gating: fresh dir is legacy" || bad "P3-02 gating: mode wrong"
TCFG_DIR="$T/legacy-store" bash -c ". ./$RTLIB; tcfg_new_task x boot echo" >/dev/null 2>&1 \
    && bad "P3-02 gating: new allowed in legacy" || ok "P3-02 gating: new rejected in legacy (import first)"
# 8c) 接线存在性：CLI 含 task-config 子命令 + dispatcher；daemon 零改动（C2）
grep -q 'task-config' "$CLI" && ok "P3-02 wiring: CLI has task-config subcommand" || bad "P3-02 wiring: CLI missing task-config"
grep -q 'task-config) shift; cmd_task_config' "$CLI" && ok "P3-02 wiring: dispatcher routes task-config" || bad "P3-02 wiring: dispatcher missing"
git diff 3fe7631 -- service.sh --quiet 2>/dev/null && ok "P3-02 wiring: service.sh untouched (C5/C2)" || bad "P3-02 wiring: service.sh changed"
# 8d) POSIX：库（含 §19）dash -n（或 bash -n 兜底）
if command -v dash >/dev/null 2>&1; then
    dash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-02 POSIX: dash -n ok (lib v$(grep '^RUNTIME_LIB_VERSION=' "$RTLIB" | cut -d= -f2 | tr -d '"') incl. §19)" || bad "P3-02 POSIX: dash -n failed"
else
    bash -n "$PWD/$RTLIB" 2>/dev/null && ok "P3-02 POSIX: bash -n ok (dash unavailable)" || bad "P3-02 POSIX: bash -n failed"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "config-v2 tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
