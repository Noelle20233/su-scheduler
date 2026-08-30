#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Trigger Decision 层测试（P1-07）
# ═══════════════════════════════════════════════════════════════════════════
# 判定约定（AGENTS §4）：每用例 [PASS]/[FAIL]；最终 exit 0 或非 0。
# 覆盖（对应要求/验收）：
#   1) 旧配置经 TriggerProvider 触发（boot/时间/advanced 各家族走对应 Provider）
#   2) 分钟级语义：当前 HHMM 精确匹配（注入 NOW 确定性）
#   3) boot 启动语义：boot 上下文轮 → boot 任务决策；同时该轮做当前分钟时间决策
#   4) --boot/--delete/--run-once-now 保留：标志仍在任务中；--boot 不额外触发
#      boot（daemon Q10 镜像）；--delete 不在此删除；--run-once-now 本轮立即决策
#   5) Provider 只判断——不写状态、不写任务、不生成决策（副作用归决策层 mark）；
#      mark 周期去重 → 同周期不重触发（验收 1/2 语义：现有行为不变）
#   6) 决策 id 全部来自 Registry 快照（P1-06 单一入口，无直接 config 扫描）
#   7) 职责隔离：决策层不触碰 health/recovery/进程（验收 2：Provider 不负责健康恢复）
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")" || exit 2
LEGACY_ADAPTER_SOURCED=1
. ../../legacy-adapter/adapter.sh
. ../../providers/lib.sh
. ../../providers/providers.sh
. ../../task-registry/lib.sh
. ./lib.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

BB=$(mktemp -d)
BASE=$(mktemp -d)
MON=$(date -d 'monday' +%Y%m%d 2>/dev/null || date +%Y%m%d)

# ── 主配置（行号即 id 前缀；全部换行结尾）────────────────────────────────────
CFG="$BASE/config.txt"
cat > "$CFG" <<'EOF'
boot echo b1
12:34 echo t1
weekly:1:0800 echo w1
08:00 echo d1; : --delete
14:30 echo r1; : --run-once-now
EOF
TRIGGER_STATE_FILE="$BASE/state.txt"
registry_init "$BASE" "$CFG" >/dev/null 2>&1 \
    && ok "registry init (snapshot from config)" || bad "registry init"
[ -f "$BASE/current" ] && ok "registry current pointer" || bad "registry no current"

# ── 1) Provider 选择（旧触发前缀 → TriggerProvider）──────────────────────────
[ "$(trigger_decision_provider boot)" = boot ]                                  && ok "select boot"                          || bad "select boot"
[ "$(trigger_decision_provider 0830)" = time ] && [ "$(trigger_decision_provider '08:30')" = time ] && ok "select time" || bad "select time"
for t in weekly:1:0800 nweekly:2:5:1400 monthly:15:1200 nmonthly:3:01:0900 yearly:12:25:0800; do
    [ "$(trigger_decision_provider "$t")" = advanced ] && ok "select advanced ($t)" || bad "select advanced ($t)"
done
trigger_decision_provider 'nonsense' >/dev/null 2>&1 && bad "unknown trigger should have no provider" || ok "unknown trigger -> no provider"

# ── 2) 轮 A（boot 上下文 + NOW=1234）：boot/时间/周/run-once 各触发一次 ───────
[ -f "$TRIGGER_STATE_FILE" ] && bad "state file exists before any decision (provider wrote it!)" \
                             || ok "state file absent pre-cycle (providers read-only)"
OUT_A=$(TRIGGER_DECISION_NOW=1234 TRIGGER_BOOT_CONTEXT=1 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$TRIGGER_STATE_FILE" trigger_decision_cycle)
echo "$OUT_A" | grep -q '^id=t1_boot cause=boot$'            && ok "A: t1 boot fires (boot ctx)"      || bad "A boot: $(echo "$OUT_A" | grep 'id=t1_boot')"
echo "$OUT_A" | grep -q '^id=t2_1234 cause=time_trigger$'    && ok "A: t2 time fires (NOW match)"     || bad "A time: $(echo "$OUT_A" | grep 'id=t2_1234')"
echo "$OUT_A" | grep -q '^id=t3_weekly10800 cause=advanced_trigger$' && ok "A: t3 weekly fires (Mon>=0800)" || bad "A weekly: $(echo "$OUT_A" | grep 'id=t3_weekly')"
echo "$OUT_A" | grep -q '^id=t5_1430 cause=run-once-now$'    && ok "A: t5 run-once-now fires"         || bad "A run-once: $(echo "$OUT_A" | grep 'id=t5_1430')"
echo "$OUT_A" | grep -q '^id=t4_0800' && bad "A: t4 (08:00) should NOT fire at 1234" || ok "A: t4 not fired (time no match)"
[ "$(echo "$OUT_A" | wc -l)" -eq 4 ] && ok "A decision count=4" || bad "A count=$(echo "$OUT_A" | wc -l)"

# ── 3) mark：周去重键已写入（决策副作用在决策层，不在 Provider）───────────────
[ -f "$TRIGGER_STATE_FILE" ] && [ "$(wc -l < "$TRIGGER_STATE_FILE")" -eq 1 ] && ok "mark wrote exactly 1 dedup key" || bad "state lines=$(wc -l < "$TRIGGER_STATE_FILE" 2>/dev/null)"
grep -q '^weekly_1_0800_' "$TRIGGER_STATE_FILE" && ok "weekly dedup key present" || bad "weekly key missing"

# ── 4) 轮 B（下一分钟 1235，boot ctx 关闭）：周不重触发、run-once 仍触发 ─────
OUT_B=$(TRIGGER_DECISION_NOW=1235 TRIGGER_BOOT_CONTEXT=0 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$TRIGGER_STATE_FILE" trigger_decision_cycle)
echo "$OUT_B" | grep -q '^id=t3_weekly' && bad "B: weekly re-fired (dedup broken!)" || ok "B: weekly no re-fire (dedup)"
echo "$OUT_B" | grep -q '^id=t5_1430 cause=run-once-now$' && ok "B: run-once still fires (flag preserved)" || bad "B run-once"
echo "$OUT_B" | grep -q '^id=t1_boot' && bad "B: boot fired w/o ctx" || ok "B: boot not fired (no ctx)"
echo "$OUT_B" | grep -q '^id=t2_1234' && bad "B: t2 fired at 1235"  || ok "B: t2 not fired (minute passed)"
[ "$(echo "$OUT_B" | wc -l)" -eq 1 ] && ok "B decision count=1" || bad "B count=$(echo "$OUT_B" | wc -l)"

# ── 5) 无 boot ctx 轮（NOW=1234）：boot 不触发、时间仍触发 ───────────────────
OUT_C=$(TRIGGER_DECISION_NOW=1234 TRIGGER_BOOT_CONTEXT=0 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$BASE/state2.txt" trigger_decision_cycle)
echo "$OUT_C" | grep -q '^id=t1_boot' && bad "C: boot fired without ctx" || ok "C: boot not fired (no ctx)"
echo "$OUT_C" | grep -q '^id=t2_1234 cause=time_trigger$' && ok "C: time fires at NOW (ctx-independent)" || bad "C time"

# ── 6) --boot / --delete 保留（标志仍在任务；决策不消费）──────────────────────
CFG2="$BASE/config2.txt"
cat > "$CFG2" <<'EOF'
12:34 echo x; : --boot
12:34 echo y; : --delete
EOF
BASE2="$BASE/reg2"
registry_init "$BASE2" "$CFG2" >/dev/null 2>&1 && ok "registry2 init" || bad "registry2 init"
T1=$(registry_task_file t1_1234); T2=$(registry_task_file t2_1234)
[ -n "$T1" ] && [ -n "$T2" ] && ok "registry2 tasks exist" || bad "registry2 tasks"
grep -q '^action.boot=1$' "$T1" && ok "--boot flag preserved in task" || bad "--boot flag missing"
grep -q '^action.delete=1$' "$T2" && ok "--delete flag preserved in task" || bad "--delete flag missing"
# boot 上下文中 --boot 时间任务不额外触发（daemon Q10 镜像）
OUT_D=$(TRIGGER_DECISION_NOW=1200 TRIGGER_BOOT_CONTEXT=1 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$BASE/state3.txt" trigger_decision_cycle)  # 需要在 reg2 快照上运行
OUT_D=$(cd "$(dirname "$0")" && TRIGGER_DECISION_NOW=1200 TRIGGER_BOOT_CONTEXT=1 \
        TRIGGER_TODAY="$MON" TRIGGER_STATE_FILE="$BASE/state3.txt" \
        TASK_REGISTRY_SNAPSHOT_PATH="" registry_has_snapshot 2>/dev/null; true)  # placeholder
# 说明：上面 placeholder 仅文档用途；真正的“reg2 快照上的决策轮”由下面步骤完成：
# 决策轮作用于当前 registry（BASE2）。轮 D'：boot ctx + NOW=1200 → 无任务触发。
OUT_D=$(registry_use_manifest "$BASE2/current" >/dev/null 2>&1; echo "$?" | tr -d '0-9'; true)
# ── 真正实现：用 BASE2 作为当前 registry 的轮（通过重置 TR_BASE）────────────
TR_BASE=$BASE2
TR_CONFIG_PATH=$CFG2
OUT_D=$(TRIGGER_DECISION_NOW=1200 TRIGGER_BOOT_CONTEXT=1 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$BASE/state3.txt" trigger_decision_cycle)
[ -z "$OUT_D" ] && ok "D: --boot time task NOT fired at boot ctx (Q10 preserved)" \
                || bad "D fired at boot: $OUT_D"
OUT_E=$(TRIGGER_DECISION_NOW=1234 TRIGGER_BOOT_CONTEXT=1 TRIGGER_TODAY="$MON" \
        TRIGGER_STATE_FILE="$BASE/state3.txt" trigger_decision_cycle)
[ "$(echo "$OUT_E" | grep -c '^id=t1_1234 cause=time_trigger$')" -eq 1 ] && ok "E: t1 fires once as time (boot flag doesn't add boot)" || bad "E t1: $OUT_E"
[ "$(echo "$OUT_E" | grep -c '^id=t2_1234 cause=time_trigger$')" -eq 1 ] && ok "E: t2 fires once as time (delete flag not consumed)" || bad "E t2: $OUT_E"
[ "$(echo "$OUT_E" | grep -c 'cause=boot')" -eq 0 ] && ok "E: no boot-cause emitted (no extra boot firing)" || bad "E boot-cause: $OUT_E"
grep -q '^action.delete=1$' "$T2" && ok "delete flag intact after decision" || bad "delete flag consumed"

# ── 7) 决策 id 全部来自 Registry 快照（单一入口）─────────────────────────────
# 注意：前段 §4-5 把 TR_BASE 切到了 CFG2 注册表；此处决策来自 BASE 注册表，
# 先切回 BASE（registry 全局指针）再校验 id 归属。
TR_BASE=$BASE
missing=""
for id in $(printf '%s\n' "$OUT_A" "$OUT_B" "$OUT_C" | grep '^id=' | cut -d' ' -f1 | cut -d= -f2); do
    registry_has_task "$id" || missing="$missing $id"
done
[ -z "$missing" ] && ok "all decision ids resolve in current registry snapshot" || bad "unknown ids: $missing"
[ "$(grep -c 'IFS= read' ./lib.sh)" -eq 0 ] && ok "decision lib: no config text scan (registry-only entry)" || bad "decision lib scans text"

# ── 8) 职责隔离：决策层/触发 Provider 不触碰 health/recovery/进程 ───────────
[ "$(grep -icE 'health|recover|/proc|kill ' ./lib.sh)" -eq 0 ] && ok "decision lib: no health/recovery/process" || bad "decision lib touches health/proc"
# 只检查触发 Provider 区段（action Provider 合法 spawn/kill，不在此断言内）
if sed -n '/tpr_trigger_boot/,/tpr_action_command_dir/p' ../../providers/providers.sh \
       | grep -qE 'kill |/proc|&[[:space:]]*$'; then
    bad "trigger providers spawn/kill processes"
else
    ok "trigger providers: no process spawning (decision only, trigger section)"
fi

# ── 清理 ────────────────────────────────────────────────────────────────────
rm -rf "$BB" "$BASE"
echo "──────────────────────────────────────────────────────────────────────"
echo "trigger-decision tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1