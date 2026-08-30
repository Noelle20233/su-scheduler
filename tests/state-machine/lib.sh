#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Task State Machine v2 — 校验函数（P1-03）
# ═══════════════════════════════════════════════════════════════════════════
# 纯 POSIX sh，可被 daemon 直接 source（C3 合规：无外部运行时）。
# 无副作用（除可选日志钩子）。状态/转换集是本文件的单一事实源，
# docs/architecture/task-state-machine-transitions.tsv 与之镜像；
# tests/state-machine/test.sh 负责断言两者一致。
#
# 用法：
#   task_state_transition <from> <to> [cause]   # 0=允许, 1=非法(已记录), 2=边允许但 cause 未知
#   task_state_cause_is_valid <cause>           # 0/1
#   task_state_rehydrate <state>                # echo daemon 重启后的状态
#   task_state_from_legacy <state>              # legacy/P1-02 状态 -> v2 状态
# ═══════════════════════════════════════════════════════════════════════════

# ── 11 个规范状态（P1-03）────────────────────────────────────────────────────
TSM_STATES='DISABLED PENDING WAITING STARTING RUNNING HEALTHY UNHEALTHY RECOVERING FAILED STOPPING STOPPED'

# ── 触发原因令牌集合 ────────────────────────────────────────────────────────
TSM_CAUSES='config_load time_trigger manual_exec action_success action_failure timeout daemon_restart stop_request rearm enable disable supervisor spawn probe'

# ── 允许转换（单一事实源，镜像 transitions.tsv）──────────────────────────────
TSM_ALLOWED='DISABLED>PENDING PENDING>DISABLED PENDING>STARTING PENDING>WAITING WAITING>PENDING WAITING>STARTING WAITING>FAILED WAITING>DISABLED STARTING>RUNNING STARTING>WAITING STARTING>FAILED STARTING>STOPPING RUNNING>STOPPED RUNNING>FAILED RUNNING>STOPPING RUNNING>HEALTHY HEALTHY>UNHEALTHY HEALTHY>STOPPED HEALTHY>FAILED HEALTHY>STOPPING UNHEALTHY>RUNNING UNHEALTHY>RECOVERING UNHEALTHY>STOPPED UNHEALTHY>FAILED UNHEALTHY>STOPPING RECOVERING>STARTING RECOVERING>FAILED RECOVERING>STOPPING STOPPING>STOPPED STOPPING>FAILED FAILED>PENDING FAILED>WAITING FAILED>DISABLED STOPPED>PENDING STOPPED>DISABLED'

# ── 日志钩子（默认 stderr；daemon 接线时覆盖为写 su-scheduler.log）───────────
# TSM_LOG=0 可静音（测试遍历时使用）。
task_state_log() {
    [ "${TSM_LOG:-1}" = "1" ] && echo "[WARNING] $1" >&2
}

# ── 状态合法性 ───────────────────────────────────────────────────────────────
task_state_is_valid() {
    case " $TSM_STATES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── 触发原因合法性 ───────────────────────────────────────────────────────────
task_state_cause_is_valid() {
    case " $TSM_CAUSES " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── 状态转换校验：0 允许 / 1 非法（已拒绝并记录）/ 2 边允许但 cause 未知 ──────
task_state_transition() {
    from=$1
    to=$2
    cause=${3:-}
    if ! task_state_is_valid "$from" || ! task_state_is_valid "$to"; then
        task_state_log "state-machine: unknown state in transition '$from'->'$to'"
        return 1
    fi
    case " $TSM_ALLOWED " in
        *" $from>$to "*)
            if [ -n "$cause" ] && ! task_state_cause_is_valid "$cause"; then
                task_state_log "state-machine: unknown cause '$cause' for allowed edge '$from'->'$to'"
                return 2
            fi
            return 0
            ;;
        *)
            task_state_log "state-machine: ILLEGAL transition '$from'->'$to' rejected${cause:+ (cause=$cause)}"
            return 1
            ;;
    esac
}

# ── daemon 重启再水合：执行态 → FAILED（崩溃；对应 legacy ZOMBIE_CRASHED）───
#    其余状态原样保留。
task_state_rehydrate() {
    case "$1" in
        STARTING|RUNNING|HEALTHY|UNHEALTHY|RECOVERING|STOPPING) echo FAILED ;;
        *) echo "$1" ;;
    esac
}

# ── legacy 状态映射（status.txt / P1-02 runtime.state 旧值 → v2）────────────
task_state_from_legacy() {
    case "$1" in
        RUNNING|running)   echo RUNNING ;;
        SUCCESS|success)   echo STOPPED ;;
        FAILED|failed|ZOMBIE_CRASHED|zombie) echo FAILED ;;
        invalid|disabled)  echo DISABLED ;;
        idle)              echo PENDING ;;
        *)                 echo "$1" ;;
    esac
}