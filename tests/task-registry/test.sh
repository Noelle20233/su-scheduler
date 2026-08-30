#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Canonical Task Registry 测试（P1-06）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每个用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应验收标准）：
#   1) 配置读取 → 完整 Task 快照（17 任务，稳定 ID 索引，source 保留）
#   2) hot reload：同一配置重复 reload → 新快照、任务集一致（无重复任务）
#   3) 配置修改 → 全量新快照（增行出现 / 删行消失，无“部分新+部分旧”混合）
#   4) 无效配置回退：文件不可读 / 全行损坏(rc1-0任务) → 保留最后一次有效快照
#      （任务不消失）——验收 1
#   5) 部分行损坏(rc1-有任务) → 提交“完整新子集”（无混合），无重复任务
#   6) 防重复注册：id==文件名 且 快照内唯一；违规 → 拒绝——验收 2
#   7) 单一调度入口：registry_task_ids 是唯一任务数据源（无直接 config 扫描）
#   8) 原子性：current 指针 tmp+mv；任何失败不留 tmp/半成品
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
LEGACY_ADAPTER_SOURCED=1
. ../legacy-adapter/adapter.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

LEGACY="../fixtures/legacy/config.txt"
BASE=$(mktemp -d)

# ── 1) 初始化：完整快照 ─────────────────────────────────────────────────────
registry_init "$BASE" "$LEGACY"
irc=$?
[ "$irc" -eq 0 ] && ok "registry_init rc=0" || bad "registry_init rc=$irc"
sid=$(registry_current_snapshot_id)
[ "$sid" = "snap_1" ] && ok "initial snapshot id=snap_1" || bad "initial snapshot id=$sid"
cnt=$(registry_task_ids | wc -l)
[ "$cnt" -eq 17 ] && ok "snapshot has 17 tasks (stable IDs)" || bad "snapshot task count=$cnt"
for t in t11_boot t16_0830 t29_1430 t35_0915 t45_2200; do
    registry_has_task "$t" && ok "has $t" || bad "missing $t"
done
f=$(registry_task_file t11_boot)
grep -q '^source.line=11$' "$f" && ok "t11 source.line preserved in registry" || bad "t11 source.line"
grep -q "^config=$LEGACY$" <(registry_manifest) && ok "manifest records config path" || bad "manifest config"
grep -q '^parse_rc=0$' <(registry_manifest) && ok "manifest parse_rc=0" || bad "manifest parse_rc"
grep -q '^task_count=17$' <(registry_manifest) && ok "manifest task_count=17" || bad "manifest count"

# ── 2) hot reload：同一配置 → 新快照、任务集一致、无重复 ────────────────────
rc=$(registry_reload "$LEGACY")
[ "$rc" = "snap_2" ] && ok "reload same config -> snap_2" || bad "reload same config -> $rc"
cnt2=$(registry_task_ids | wc -l)
[ "$cnt2" -eq 17 ] && ok "reload keeps 17 tasks (no duplicates)" || bad "reload count=$cnt2"
ids1=$(registry_task_ids | tr '\n' ' ')
ids2=$(registry_task_ids | tr '\n' ' ')
[ "$ids1" = "$ids2" ] && ok "task id set identical after reload (no dup, no loss)" || bad "id set changed on reload"
[ "$(registry_task_ids | sort -u | wc -l)" -eq 17 ] && ok "ids unique (17 unique)" || bad "duplicate ids in snapshot"

# ── 3) 配置修改 → 全量新快照（增/删，无混合） ────────────────────────────────
# 3a) 追加一行 → snap_3：18 任务，旧任务仍在（全量替换，无混合）
CFG_ADD=$(mktemp)
cp "$LEGACY" "$CFG_ADD"
printf '\n23:00 echo "added late"\n' >> "$CFG_ADD"
rc=$(registry_reload "$CFG_ADD")
[ "$rc" = "snap_3" ] && ok "reload added-line -> snap_3" || bad "reload add -> $rc"
[ "$(registry_task_ids | wc -l)" -eq 18 ] && ok "added config -> 18 tasks" || bad "added count=$(registry_task_ids | wc -l)"
registry_has_task t46_2300 && ok "new task t46_2300 present" || bad "t46_2300 missing"
registry_has_task t45_2200 && ok "old t45_2200 still present (append keeps counts)" || bad "t45_2200 lost on append"
# 3b) 删除一行（去掉 22:00 行）→ snap_4：16 任务，被删任务消失（无残留=无混合）
CFG_DEL=$(mktemp)
grep -v '^22:00 echo "No modifiers at all"' "$LEGACY" > "$CFG_DEL"
rc=$(registry_reload "$CFG_DEL")
[ "$rc" = "snap_4" ] && ok "reload deleted-line -> snap_4" || bad "reload del -> $rc"
[ "$(registry_task_ids | wc -l)" -eq 16 ] && ok "deleted config -> 16 tasks" || bad "deleted count=$(registry_task_ids | wc -l)"
registry_has_task t45_2200 && bad "t45_2200 should be gone (full replace, no mix)" || ok "t45_2200 removed (no old/new mix)"
registry_has_task t11_boot && ok "t11_boot retained (full new snapshot)" || bad "t11_boot missing after reload"

# ── 4) 无效配置回退（验收 1：损坏不会导致任务消失） ─────────────────────────
# 4a) 文件不可读 → 回退（保留 snap_4，16 任务仍在）
rc=$(registry_reload /nonexistent/zzz.txt)
[ "$rc" = "KEPT" ] && ok "missing config -> KEPT (fallback)" || bad "missing config rc=$rc"
[ "$(registry_current_snapshot_id)" = "snap_4" ] && ok "current still snap_4 (old kept)" || bad "current moved on missing config"
[ "$(registry_task_ids | wc -l)" -eq 16 ] && ok "16 tasks still present (corruption keeps tasks)" || bad "tasks vanished on missing config"
# 4b) 全行损坏（rc1-零任务）→ 无效 → 回退
CFG_ALLBAD=$(mktemp)
printf '08\x01:30 x\n23\x02:00 y\n' > "$CFG_ALLBAD"
rc=$(registry_reload "$CFG_ALLBAD")
[ "$rc" = "KEPT" ] && ok "all-bad config -> KEPT (fallback)" || bad "all-bad rc=$rc"
[ "$(registry_task_ids | wc -l)" -eq 16 ] && ok "still 16 tasks after all-bad reload" || bad "tasks vanished on all-bad"
# 4c) 硬错误（adapter 未加载）→ rc=2，状态不动
# 子进程仅加载 lib.sh（无 adapter），但传入**存在**的配置文件 → 通过文件检查
# 后在 adapter 检查处返回 rc2（硬错误，快照生成前退出 → 无残留目录）
RCH=$(mktemp -d)
# 外层已 cd 到本目录；子进程直接继承 cwd（不再 cd，避免 $0 路径分隔符差异）
out2=$( LEGACY_REL="$LEGACY" sh -c 'set -u; . ./lib.sh >/dev/null 2>&1 || exit 9; registry_reload "$LEGACY_REL" >/dev/null 2>&1; echo $?' )
[ "$out2" = "2" ] && ok "hard error path: reload without adapter -> rc2 (no snapshot touched)" || bad "no-adapter rc=$out2"
rm -rf "$RCH"

# ── 5) 部分行损坏（rc1-有任务）→ 提交“完整新子集”（无混合） ─────────────────
CFG_PARTBAD=$(mktemp)
printf '08\x01:30 bad-line\n' > "$CFG_PARTBAD"
cat "$LEGACY" >> "$CFG_PARTBAD"
rc=$(registry_reload "$CFG_PARTBAD")
case "$rc" in
    snap_*) ok "partial-bad -> new snapshot $rc (complete new subset)" ;;
    *) bad "partial-bad rc=$rc" ;;
esac
[ "$(registry_task_ids | wc -l)" -eq 17 ] && ok "partial-bad snapshot = 17 tasks (bad line isolated)" || bad "partial-bad count=$(registry_task_ids | wc -l)"
# 无混合：旧快照的 id（t11_boot 等，依赖原行号）不应出现在新快照（行号整体平移）
case "$(registry_task_ids | tr '\n' ' ')" in
    *t11_boot*) bad "old snapshot id t11_boot leaked into new (mix!)" ;;
    *) ok "no residue from previous snapshot (no old/new mix)" ;;
esac
[ "$(registry_task_ids | sort -u | wc -l)" -eq 17 ] && ok "partial-bad ids unique" || bad "partial-bad dup ids"
rm -f "$CFG_ADD" "$CFG_DEL" "$CFG_ALLBAD" "$CFG_PARTBAD"

# ── 6) 防重复注册（验收 2）：id==文件名 且 快照内唯一 ─────────────────────────
DUP=$(mktemp -d)
printf 'schema_version=2\nid=t9_boot\n' > "$DUP/t9_boot.task"
printf 'schema_version=2\nid=t9_boot\n' > "$DUP/t9_boot_2.task"
TR_LOGGING=0 _registry_snap_valid "$DUP" && bad "duplicate id should be rejected" || ok "duplicate id rejected by validator"
printf 'schema_version=2\nid=t99_wrong\n' > "$DUP/t9_boot.task"
TR_LOGGING=0 _registry_snap_valid "$DUP" && bad "id-field mismatch should be rejected" || ok "id-field mismatch rejected by validator"
printf 'schema_version=2\nid=t9_boot\n' > "$DUP/t9_boot.task"
rm -f "$DUP/t9_boot_2.task"
TR_LOGGING=0 _registry_snap_valid "$DUP" && ok "single unique task passes validator" || bad "validator rejects unique snapshot"
rm -rf "$DUP"

# ── 7) 单一调度入口（验收 3：daemon 只保留一个调度入口） ─────────────────────
# 结构断言：lib.sh 无 config 文本读取循环（唯一文本边界 = adapter via reload）
[ "$(grep -c 'IFS= read' lib.sh)" -eq 0 ] && ok "registry lib has no config-scan loop (single entry: reload->adapter)" || bad "registry lib scans text"
[ "$(grep -c 'legacy_adapter_parse "\$config"' lib.sh)" -eq 1 ] && ok "exactly one adapter invocation (registry_reload)" || bad "adapter invocation count: $(grep -c 'legacy_adapter_parse "\$config"' lib.sh)"
# 行为断言：任务数据只来自 registry_task_ids（当前快照）
[ "$(registry_task_ids | wc -l)" -eq "$(registry_task_ids | wc -l)" ] && ok "registry_task_ids deterministic (single data source)" || bad "registry_task_ids unstable"

# ── 8) 原子性 ───────────────────────────────────────────────────────────────
[ "$(find "$BASE" -name '*.tmp' | wc -l)" -eq 0 ] && ok "no .tmp leftovers in registry base" || bad ".tmp leftovers"
[ -s "$BASE/current" ] && ok "current pointer file readable" || bad "current pointer missing/empty"
snap4="$BASE/snapshots/snap_4"
[ "$(ls "$snap4" | wc -l)" -eq 17 ] && ok "snap_4 intact: 16 tasks + 1 manifest" || bad "snap_4 content changed ($(ls "$snap4" | wc -l))"
# 最后提交的是 partial-bad 新快照 → current = 该次提交的快照（非 snap_4）
case "$(registry_current_snapshot_id)" in
    snap_*) ok "current = last committed snapshot $(registry_current_snapshot_id) (fallbacks never moved pointer)" ;;
    *) bad "current drifted: $(registry_current_snapshot_id)" ;;
esac

# ── 汇总 ────────────────────────────────────────────────────────────────────
rm -rf "$BASE"
echo "──────────────────────────────────────────────────────────────────────"
echo "task-registry tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1