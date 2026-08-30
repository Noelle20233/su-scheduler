#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Trigger Decision 层（P1-07）
# ═══════════════════════════════════════════════════════════════════════════
# 作用：让旧调度能力通过统一 TriggerProvider 运行——每轮遍历 Canonical Task
# Registry（P1-06）的快照任务，按触发器前缀选 TriggerProvider，只判断
# 「本轮是否应该执行」，输出决策（id + cause）。**不负责**进程健康/恢复
# （验收 2）、不执行动作、不写任务状态（P1-03 状态机归引擎）。
#
# 保持的 legacy 语义（P1-01 §5）：
#   - 分钟级：时间触发 == 当前 HHMM 精确匹配（TRIGGER_DECISION_NOW 注入，
#     缺省 date +%H%M）；每轮一个 NOW → 每分钟一轮（daemon 每分钟扫描）。
#   - boot 启动语义：TRIGGER_BOOT_CONTEXT=1 的轮次，boot 任务匹配；同时该轮
#     也做当前分钟时间匹配（镜像 daemon 启动后首个主循环迭代，P1-01 §5.2 注）。
#   - advanced（weekly/nweekly/monthly/nmonthly/yearly）：镜像 daemon
#     should_run_advanced_schedule——日/星期匹配 + 时间>=目标 + 状态文件去重键
#     检查（**读取**）；匹配后由本层调用 trigger_decision_mark 记录键（写入，
#     镜像 daemon 的"检查+记录同轮完成"）→ 周期内不重触发。
#   - --run-once-now：任何任务带该标志 → 本轮立即决策（cause=run-once-now），
#     标志保留（修剪属接线层/daemon 语义）；--delete：保留标志，不在此删除。
#   - --boot：标志保留（action.boot=1），**不**产生 boot 触发（daemon Q10 镜像）。
#   - 未知触发器 → 不决策（daemon 不匹配即不执行）。
#
# 上下文变量（缺省保持 daemon 语义；决策/测试可注入）：
#   TRIGGER_DECISION_NOW / TRIGGER_BOOT_CONTEXT / TRIGGER_TODAY /
#   TRIGGER_STATE_FILE（复用 providers 的 tpr_ctx_* 同源变量）
# ═══════════════════════════════════════════════════════════════════════════
set -u

trigger_decision_log() {
    [ "${TRIGGER_DECISION_LOG:-1}" = "1" ] && echo "[trigger-decision] $1" >&2
}

# ── Provider 选择：旧触发器前缀 → TriggerProvider 名（镜像 daemon 判定路径）──
trigger_decision_provider() {
    case "$1" in
        boot)                    echo boot ;;
        [0-9]*)                  echo time ;;
        weekly:*|nweekly:*|monthly:*|nmonthly:*|yearly:*) echo advanced ;;
        *) return 1 ;;
    esac
}

# ── 任务 clean 行推导（advanced 去重键 md5 输入；镜像 daemon md5(clean_line)）──
# source.raw 为存储转义形式（P1-02 §6）；反解后修剪 = clean 行。
# 注：对含反斜杠的怪癖行是近似（fixture 与常规行无歧义；文档记录）。
trigger_decision_clean_line() {
    task=$1
    raw=$(grep '^source.raw=' "$task" | cut -d= -f2-)
    printf '%s\n' "$raw" |
        awk '{ gsub(/\\\\/, "\\"); gsub(/\\n/, "\n"); printf "%s", (NR>1 ? "\n" : "") $0 }' |
        sed 's/^[ \t]*//;s/[ \t]*$//'
}

# ── 高级去重键记录（决策后同轮写入；镜像 daemon 状态文件写语义）──────────────
# daemon：weekly/monthly/yearly 追加全键；nweekly/nmonthly 首次追加 key=周/月，
# 后续 sed 原位更新（su-schedulerd L111-112/L131-136/L152/L170-180/L197）。
trigger_decision_mark() {
    task=$1
    trigger=$(grep '^trigger=' "$task" | cut -d= -f2)
    line=$(trigger_decision_clean_line "$task")
    hash=$(printf '%s\n' "$line" | md5sum | cut -d' ' -f1)
    sf=$(tpr_ctx_state_file)
    [ -f "$sf" ] || touch "$sf"
    yy=$(tpr_ctx_date %Y); mm=$(tpr_ctx_date %m); dd=$(tpr_ctx_date %d)
    dow=$(tpr_ctx_date %u); wk=$(tpr_ctx_date %V)
    case "$trigger" in
        weekly:*)
            tdow=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            echo "weekly_${tdow}_${ttime}_${hash}_${yy}${mm}${dd}" >> "$sf" ;;
        nweekly:*)
            n=$(echo "$trigger" | cut -d: -f2); tdow=$(echo "$trigger" | cut -d: -f3)
            ttime=$(echo "$trigger" | cut -d: -f4)
            key="nweekly_${n}_${tdow}_${ttime}_${hash}"
            if grep -q "^${key}=" "$sf"; then
                sed -i "s/^${key}=.*/${key}=${wk}/" "$sf"
            else
                echo "${key}=${wk}" >> "$sf"
            fi ;;
        monthly:*)
            tdd=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            echo "monthly_${tdd}_${ttime}_${hash}_${yy}${mm}" >> "$sf" ;;
        nmonthly:*)
            n=$(echo "$trigger" | cut -d: -f2); tdd=$(echo "$trigger" | cut -d: -f3)
            ttime=$(echo "$trigger" | cut -d: -f4)
            key="nmonthly_${n}_${tdd}_${ttime}_${hash}"
            if grep -q "^${key}=" "$sf"; then
                sed -i "s/^${key}=.*/${key}=${mm}/" "$sf"
            else
                echo "${key}=${mm}" >> "$sf"
            fi ;;
        yearly:*)
            tdate=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            echo "yearly_${tdate}_${ttime}_${hash}_${yy}" >> "$sf" ;;
    esac
}

# ── 单轮决策：trigger_decision_cycle → stdout `id=<id> cause=<cause>` ────────
trigger_decision_cycle() {
    for id in $(registry_task_ids); do
        task=$(registry_task_file "$id") || continue
        trigger=$(grep '^trigger=' "$task" | cut -d= -f2)
        ronow=$(grep '^action.run_once_now=' "$task" | cut -d= -f2)

        # --run-once-now：本轮立即决策（legacy 扫描语义，标志保留）
        if [ "$ronow" = "1" ]; then
            echo "id=$id cause=run-once-now"
            continue
        fi

        # 注入任务 clean 行（advanced 去重键 md5 输入；镜像 daemon md5(clean_line)）
        TRIGGER_DECISION_LINE=$(trigger_decision_clean_line "$task")

        p=$(trigger_decision_provider "$trigger") || {
            trigger_decision_log "WARNING unknown trigger '$trigger' (id=$id): no provider -> no fire"
            continue
        }

        case "$p" in
            boot)
                [ "${TRIGGER_BOOT_CONTEXT:-0}" = "1" ] && echo "id=$id cause=boot" ;;
            time)
                # 分钟级：NOW 精确匹配（镜像 daemon L683）；boot 轮也做当前分钟匹配
                if provider_dispatch trigger time matches "$trigger" >/dev/null 2>&1; then
                    echo "id=$id cause=time_trigger"
                fi ;;
            advanced)
                # 注入 clean 行（md5 输入）；matches 只读状态文件 = 只判断
                if provider_dispatch trigger advanced matches "$trigger" >/dev/null 2>&1; then
                    echo "id=$id cause=advanced_trigger"
                    # 同轮记录去重键（镜像 daemon 检查+记录同轮完成）
                    trigger_decision_mark "$task"
                fi ;;
            *) : ;;
        esac
    done
}