#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Provider 静态实现（P1-04 + P1-07 接线）
# ═══════════════════════════════════════════════════════════════════════════
# 本文件 source lib.sh，然后注册并实现全部静态 Provider。
# 注册表（P1-07 起）：
#   trigger>boot      BootTriggerProvider（boot 启动语义）
#   trigger>time      TimeTriggerProvider（HHMM/HH:MM 分钟级）
#   trigger>advanced  LegacyAdvancedTriggerProvider（weekly/nweekly/monthly/
#                     nmonthly/yearly——镜像 daemon should_run_advanced_schedule，
#                     读状态文件去重，**只判断**不写状态；写入归决策层 mark）
#   action>command    CommandActionProvider（现有 Shell 命令适配，全实现）
#   health>builtin    HealthProvider（接口 + 空实现 stub）
#   recovery>builtin  RecoveryProvider（接口 + 空实现 stub）
#
# P1-07 上下文注入（决策层/测试设置，缺省保持 daemon 语义）：
#   TRIGGER_DECISION_NOW   HHMM（缺省 date +%H%M）——分钟级匹配
#   TRIGGER_TODAY          YYYYMMDD（缺省真实日期）——advanced 日期分量
#   TRIGGER_STATE_FILE     状态文件路径（缺省 /data/adb/su-scheduler/schedule_state.txt）
#   TRIGGER_DECISION_LINE  任务行 clean 后全文（advanced 去重键 md5 输入，镜像
#                          daemon md5(clean_line)
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "./lib.sh"

# ── 通用上下文助手 ──────────────────────────────────────────────────────────
tpr_ctx_now()  { echo "${TRIGGER_DECISION_NOW:-$(date +%H%M)}"; }
tpr_ctx_date() { # $1 = strftime 格式；TRIGGER_TODAY=YYYYMMDD 时用 -d 镜像（测试确定性）
    if [ -n "${TRIGGER_TODAY:-}" ]; then date -d "$TRIGGER_TODAY" "+$1"; else date "+$1"; fi
}
tpr_ctx_state_file() { echo "${TRIGGER_STATE_FILE:-/data/adb/su-scheduler/schedule_state.txt}"; }
tpr_ctx_line_md5() {  # 镜像 daemon：md5(clean_line)（clean 已由决策层注入）
    printf '%s\n' "${TRIGGER_DECISION_LINE:-}" | md5sum | cut -d' ' -f1
}

# ── TriggerProvider: boot ──────────────────────────────────────────────────
# 启动语义（P1-01 §5.1）：daemon 每次（重新）启动时匹配。上下文标志
# TRIGGER_BOOT_CONTEXT=1 由决策层在启动扫描阶段设置（tests/scheduling/...）。
tpr_trigger_boot_validate() {   # 仅接受 "boot"
    [ "$1" = "boot" ] && return 0 || return 1
}
tpr_trigger_boot_parse() { echo "kind=boot"; }
tpr_trigger_boot_matches() {
    [ "${TRIGGER_BOOT_CONTEXT:-0}" = "1" ] && return 0 || return 1
}
tpr_trigger_boot_next_due() {
    if [ "${TRIGGER_BOOT_CONTEXT:-0}" = "1" ]; then echo 0; return 0; fi
    return 1   # boot 上下文外无可计算的下次时间
}

# ── TriggerProvider: time（分钟级，daemon L609/L683 语义）────────────────────
tpr_trigger_time_norm() { echo "$1" | sed 's/://g'; }
tpr_trigger_time_validate() {
    case "$(tpr_trigger_time_norm "$1")" in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}
tpr_trigger_time_parse() {
    echo "kind=time;time=$(tpr_trigger_time_norm "$1")"
}
tpr_trigger_time_matches() {
    [ -n "$1" ] || return 1
    [ "$(tpr_trigger_time_norm "$1")" = "$(tpr_ctx_now)" ] && return 0 || return 1
}
tpr_trigger_time_next_due() {   # 距下次命中的秒数（分钟粒度，镜像 P1-01 §5.2）
    norm=$(tpr_trigger_time_norm "$1")
    case "$norm" in
        [0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    th=$(echo "$norm" | cut -c1-2); tm=$(echo "$norm" | cut -c3-4)
    th=$(echo "$th" | sed 's/^0*//'); tm=$(echo "$tm" | sed 's/^0*//')
    [ -z "$th" ] && th=0; [ -z "$tm" ] && tm=0
    nh=$(date +%H | sed 's/^0*//'); nm=$(date +%M | sed 's/^0*//')
    [ -z "$nh" ] && nh=0; [ -z "$nm" ] && nm=0
    target=$((th * 60 + tm)); now=$((nh * 60 + nm))
    if [ "$target" -gt "$now" ]; then
        echo $(((target - now) * 60))
    elif [ "$target" -eq "$now" ]; then
        echo 0
    else
        echo $(((1440 - now + target) * 60))
    fi
    return 0
}

# ── TriggerProvider: advanced（镜像 daemon should_run_advanced_schedule）─────
# 语义（P1-01 §5.3 + su-schedulerd L84-206）：
#   weekly:DOW:HHMM / nweekly:N:DOW:HHMM / monthly:DD:HHMM / nmonthly:N:DD:HHMM /
#   yearly:MMDD:HHMM；日/星期匹配 + 当前时间 >= 目标 + 状态文件去重键检查。
# **只判断**：本 Provider 只读状态文件；去重键的**写入**由决策层（P1-07
#   trigger_decision_mark，见 tests/scheduling/trigger-decision/lib.sh）在匹配后
#   执行——与 daemon 的“检查+记录同分钟完成”等价，且把副作用留在决策层。
# **不实现新高级触发**（P1-07 约束）：仅封装既有家族，格式/键完全沿用。
tpr_trigger_advanced_validate() {
    case "$1" in
        weekly:*|nweekly:*|monthly:*|nmonthly:*|yearly:*) return 0 ;;
        *) return 1 ;;
    esac
}
tpr_trigger_advanced_parse() {
    case "$1" in
        weekly:*)  echo "kind=advanced;family=weekly" ;;
        nweekly:*) echo "kind=advanced;family=nweekly" ;;
        monthly:*) echo "kind=advanced;family=monthly" ;;
        nmonthly:*) echo "kind=advanced;family=nmonthly" ;;
        yearly:*)  echo "kind=advanced;family=yearly" ;;
    esac
}
_tpr_adv_read() {  # $1=行；返回 0 若状态文件含该行（去重判定，只读）
    sf=$(tpr_ctx_state_file)
    [ -f "$sf" ] && grep -qF "$1" "$sf"
}
tpr_trigger_advanced_matches() {
    trigger=$1
    now=$(tpr_ctx_now)
    hash=$(tpr_ctx_line_md5)
    yy=$(tpr_ctx_date %Y); mm=$(tpr_ctx_date %m); dd=$(tpr_ctx_date %d)
    dow=$(tpr_ctx_date %u); wk=$(tpr_ctx_date %V)
    mmdd="${mm}${dd}"; yymm="${yy}${mm}"; yymmdd="${yy}${mm}${dd}"

    case "$trigger" in
        weekly:*)
            tdow=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            if [ "$dow" = "$tdow" ] && [ "$now" -ge "$ttime" ] \
               && ! _tpr_adv_read "weekly_${tdow}_${ttime}_${hash}_${yymmdd}"; then
                return 0
            fi ;;
        nweekly:*)
            n=$(echo "$trigger" | cut -d: -f2); tdow=$(echo "$trigger" | cut -d: -f3)
            ttime=$(echo "$trigger" | cut -d: -f4)
            key="nweekly_${n}_${tdow}_${ttime}_${hash}"
            last=$(grep "^${key}=" "$(tpr_ctx_state_file)" 2>/dev/null | cut -d= -f2)
            if [ "$dow" = "$tdow" ] && [ "$now" -ge "$ttime" ] && {
                [ -z "$last" ] || [ $(((wk - last + 53) % 53)) -ge "$n" ]; }; then
                return 0
            fi ;;
        monthly:*)
            tdd=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            if [ "$dd" = "$tdd" ] && [ "$now" -ge "$ttime" ] \
               && ! _tpr_adv_read "monthly_${tdd}_${ttime}_${hash}_${yymm}"; then
                return 0
            fi ;;
        nmonthly:*)
            n=$(echo "$trigger" | cut -d: -f2); tdd=$(echo "$trigger" | cut -d: -f3)
            ttime=$(echo "$trigger" | cut -d: -f4)
            key="nmonthly_${n}_${tdd}_${ttime}_${hash}"
            last=$(grep "^${key}=" "$(tpr_ctx_state_file)" 2>/dev/null | cut -d= -f2)
            lt=$((yy * 12 + ${last:-0})); tt=$((yy * 12 + mm))
            [ "$lt" -gt "$tt" ] && lt=$(((yy - 1) * 12 + last))   # 跨年回卷（镜像 daemon L176）
            if [ "$dd" = "$tdd" ] && [ "$now" -ge "$ttime" ] && {
                [ -z "$last" ] || [ $((tt - lt)) -ge "$n" ]; }; then
                return 0
            fi ;;
        yearly:*)
            tdate=$(echo "$trigger" | cut -d: -f2); ttime=$(echo "$trigger" | cut -d: -f3)
            if [ "$mmdd" = "$tdate" ] && [ "$now" -ge "$ttime" ] \
               && ! _tpr_adv_read "yearly_${tdate}_${ttime}_${hash}_${yy}"; then
                return 0
            fi ;;
        *) return 1 ;;
    esac
    return 1
}
tpr_trigger_advanced_next_due() {
    # 命中即 0 秒（镜像：条件满足的当轮执行；无未来时间推算）
    if tpr_trigger_advanced_matches "$1"; then echo 0; return 0; fi
    return 1
}

# ── ActionProvider: command（现有 Shell 命令适配，全实现）──────────────────
# 适配 legacy execute_task 语义（P1-01 §5）：异步 sh -c，输出落 task 目录。
tpr_action_command_dir() { echo "${TPR_ACTION_DIR:-/tmp/su-scheduler-actions}/$1"; }
tpr_action_command_validate() { [ -n "$1" ] && return 0 || return 1; }
tpr_action_command_prepare() {
    dir=$(tpr_action_command_dir "$1")
    mkdir -p "$dir"
    echo "$2" > "$dir/command.txt"
    echo "$dir"
}
tpr_action_command_start() {
    dir=$(tpr_action_command_dir "$1")
    sh -c "$2" > "$dir/output.log" 2>&1 &
    echo $!
}
tpr_action_command_status() {
    pid=$2
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0 || return 1
}
tpr_action_command_stop() { kill "$2" 2>/dev/null; }
tpr_action_command_restart() {
    tpr_action_command_stop "$1" "$3"
    sleep 1
    tpr_action_command_start "$1" "$2"
}

# ── HealthProvider: builtin（接口 + 空实现 stub）───────────────────────────
tpr_health_builtin_validate() {
    case "$1" in
        ""|none) return 0 ;;
        *) return 1 ;;
    esac
}
tpr_health_builtin_check() { echo "ok"; return 0; }

# ── RecoveryProvider: builtin（接口 + 空实现 stub）──────────────────────────
tpr_recovery_builtin_validate() {
    case "$1" in
        ""|none) return 0 ;;
        *) return 1 ;;
    esac
}
tpr_recovery_builtin_recover() { echo "none"; return 0; }

# ── 静态注册（加载即注册；重复注册被 lib 拒绝）──────────────────────────────
provider_register trigger boot     tpr_trigger_boot
provider_register trigger time     tpr_trigger_time
provider_register trigger advanced tpr_trigger_advanced
provider_register action command   tpr_action_command
provider_register health builtin   tpr_health_builtin
provider_register recovery builtin tpr_recovery_builtin