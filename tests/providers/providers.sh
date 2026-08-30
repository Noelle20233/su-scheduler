#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Provider 静态注册实现（P1-04）
# ═══════════════════════════════════════════════════════════════════════════
# 本文件 source lib.sh，然后注册并实现：
#   trigger>boot     —— BootTriggerProvider（boot 触发）
#   trigger>time     —— TimeTriggerProvider（HHMM/HH:MM 日常触发）
#   action>command   —— CommandActionProvider（现有 Shell 命令适配，全实现）
#   health>builtin   —— HealthProvider（接口 + 空实现 stub）
#   recovery>builtin —— RecoveryProvider（接口 + 空实现 stub）
#
# 新 Provider 模板（后续 AppActionProvider 照此扩展，零核心改动）：
#   1) 实现前缀函数：<prefix>_<capability>()（能力集见 lib.sh / provider-contracts.md）
#   2) 注册一行：provider_register <kind> <name> <prefix>
#   3) 核心引擎零改动；状态机零改动（P1-03 由引擎桥接，§7）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
. "./lib.sh"

# ── TriggerProvider: boot ──────────────────────────────────────────────────
# boot 触发：daemon 启动（boot 上下文）时匹配。
# 上下文标志 TPR_BOOT_CONTEXT=1 由引擎在启动阶段设置（legacy 语义：boot 任务
# 在每次 daemon 启动执行——P1-01 §5.1）。
tpr_trigger_boot_validate() {   # 可解析性：仅接受 "boot"
    [ "$1" = "boot" ] && return 0 || return 1
}

tpr_trigger_boot_parse() {      # 结构化输出：kind=boot
    echo "kind=boot"
}

tpr_trigger_boot_matches() {    # 当前是否命中：boot 上下文中命中
    [ "${TPR_BOOT_CONTEXT:-0}" = "1" ] && return 0 || return 1
}

tpr_trigger_boot_next_due() {   # 距离下次命中秒数：上下文内 = 0（已到期）
    if [ "${TPR_BOOT_CONTEXT:-0}" = "1" ]; then
        echo 0
        return 0
    fi
    return 1   # boot 上下文之外无可计算的下次时间
}

# ── TriggerProvider: time ──────────────────────────────────────────────────
# 日常时间触发：HHMM 或 HH:MM（P1-01 §4.2/§5.2 语义：分钟精确匹配）。
# 匹配比较用当前 HHMM（date +%H%M）。
tpr_trigger_time_norm() { echo "$1" | sed 's/://g'; }

tpr_trigger_time_validate() {
    case "$(tpr_trigger_time_norm "$1")" in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

tpr_trigger_time_parse() {
    norm=$(tpr_trigger_time_norm "$1")
    echo "kind=time;time=$norm"
}

tpr_trigger_time_matches() {
    [ -n "$1" ] || return 1
    [ "$(tpr_trigger_time_norm "$1")" = "$(date +%H%M)" ] && return 0 || return 1
}

tpr_trigger_time_next_due() {
    norm=$(tpr_trigger_time_norm "$1")
    case "$norm" in
        [0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    # 解析时分（去前导零，避免 08 被当八进制）
    th=$(echo "$norm" | cut -c1-2); tm=$(echo "$norm" | cut -c3-4)
    th=$(echo "$th" | sed 's/^0*//'); tm=$(echo "$tm" | sed 's/^0*//')
    [ -z "$th" ] && th=0; [ -z "$tm" ] && tm=0
    now_h=$(date +%H | sed 's/^0*//'); now_m=$(date +%M | sed 's/^0*//')
    [ -z "$now_h" ] && now_h=0; [ -z "$now_m" ] && now_m=0
    target=$((th * 60 + tm))
    now=$((now_h * 60 + now_m))
    if [ "$target" -gt "$now" ]; then
        echo $(((target - now) * 60))
    elif [ "$target" -eq "$now" ]; then
        echo 0
    else
        echo $(((1440 - now + target) * 60))
    fi
    return 0
}

# ── ActionProvider: command（现有 Shell 命令适配，全实现）──────────────────
# 适配 legacy execute_task 语义（P1-01 §5）：异步 sh -c，输出落 task 目录。
# TPR_ACTION_DIR：task 目录根（宿主测试取临时目录；daemon 接线时取 tasks 目录）。
tpr_action_command_dir() { echo "${TPR_ACTION_DIR:-/tmp/su-scheduler-actions}/$1"; }

tpr_action_command_validate() {  # 非空命令即合法
    [ -n "$1" ] && return 0 || return 1
}

tpr_action_command_prepare() {  # $1=task_id $2=command → 建 task 目录并回显路径
    dir=$(tpr_action_command_dir "$1")
    mkdir -p "$dir"
    echo "$2" > "$dir/command.txt"
    echo "$dir"
}

tpr_action_command_start() {   # $1=task_id $2=command → 异步启动，回显 PID
    dir=$(tpr_action_command_dir "$1")
    sh -c "$2" > "$dir/output.log" 2>&1 &
    echo $!
}

tpr_action_command_status() {  # $1=task_id $2=pid → 0=存活 1=已退出
    pid=$2
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && return 0 || return 1
}

tpr_action_command_stop() {    # $1=task_id $2=pid
    kill "$2" 2>/dev/null
}

tpr_action_command_restart() { # $1=task_id $2=command $3=old_pid → 新 PID
    tpr_action_command_stop "$1" "$3"
    sleep 1
    tpr_action_command_start "$1" "$2"
}

# ── HealthProvider: builtin（接口 + 空实现 stub）───────────────────────────
# P1 语义（P1-02 health.type）：none = 不启用健康检查；check 恒 ok。
# Supervisor 接线后由 health>… 新 Provider 替换，或本 stub 扩展（零核心改动）。
tpr_health_builtin_validate() {
    case "$1" in
        ""|none) return 0 ;;
        *) return 1 ;;
    esac
}

tpr_health_builtin_check() {   # 空实现：恒健康
    echo "ok"
    return 0
}

# ── RecoveryProvider: builtin（接口 + 空实现 stub）──────────────────────────
# P1 语义（P1-02 recovery.type）：none = 不启用恢复；recover 恒 no-op。
tpr_recovery_builtin_validate() {
    case "$1" in
        ""|none) return 0 ;;
        *) return 1 ;;
    esac
}

tpr_recovery_builtin_recover() {   # 空实现：无恢复动作
    echo "none"
    return 0
}

# ── 静态注册（加载即注册；重复注册被 lib 拒绝）──────────────────────────────
provider_register trigger boot   tpr_trigger_boot
provider_register trigger time   tpr_trigger_time
provider_register action command tpr_action_command
provider_register health builtin tpr_health_builtin
provider_register recovery builtin tpr_recovery_builtin