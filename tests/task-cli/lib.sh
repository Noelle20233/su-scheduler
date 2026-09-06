#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Task 只读 CLI 层（P1-11）
# ═══════════════════════════════════════════════════════════════════════════
# 作用：让内部 Task 模型可以被验证和观察——只读能力：
#   task_cli_list                 # ~ `su-scheduler task list`
#   task_cli_status <id>          # ~ `su-scheduler task status <id>`
# **P1 只增加只读**：不提供 task start/stop/restart（约束；测试结构断言）。
# **保持所有原有 CLI 命令**：本层不定义/不覆盖任何与生产 CLI 子命令同名的
#   函数（list/status/tasks/task-info/... 归生产 CLI），生产文件零改动。
#
# 数据源（验收 1）：
#   - 任务**来源** = P1-06 Canonical Task Registry 快照（registry_task_ids /
#     registry_task_file / registry_manifest）——**不重新解析 config.txt**，
#     不生产第二套任务（本文件无配置文本扫描循环）。
#   - 当前状态 = P1-09 runtime_current_state：优先运行目录
#     $TASK_CLI_TASKS_DIR/<id>/state.txt（新统一源），缺失时旧 status.txt
#     推导（task_state_from_legacy），再缺省回退 registry 快照任务文件的
#     runtime.state 字段（P1-02 默认 PENDING——任务从未运行）。
#   - daemon 运行判定 = P1-10 lifecycle_lock_alive（TASK_CLI_LOCK 注入；
#     未注入则跳过判定——允许离线查看清单快照）。
#
# 错误三态（验收：输出错误必须明确区分）：
#   rc 1 = task not found（registry 无此 id）
#   rc 2 = configuration invalid（无当前有效快照——从未成功加载/损坏）
#   rc 3 = daemon is not running（注入锁时锁不可活——无法保证实时状态；
#          磁盘状态可能是崩溃残留）
#   stdout 一律不混错误；错误走 stderr。
#
# 使用前须按序 source：state-machine → runtime → legacy-adapter（置
#   LEGACY_ADAPTER_SOURCED=1）→ task-registry → lifecycle。list/status 依赖
#   registry 已 init（有当前快照）。
# 上下文变量：TASK_CLI_TASKS_DIR（运行目录根，镜像 daemon tasks/）、
#   TASK_CLI_LOCK（锁文件；空=跳过 daemon 判定）。
# ═══════════════════════════════════════════════════════════════════════════
set -u

task_cli_log() {
    [ "${TASK_CLI_LOG:-1}" = "1" ] && echo "[task-cli] $1" >&2
}

# ── 配置有效性：0=有效（存在当前快照，KEPT 回退也算有效） 1=无效 ────────────
task_cli_config_valid() {
    [ -n "$(registry_current_snapshot_id 2>/dev/null)" ] && return 0
    return 1
}

# ── 任务存在：task_cli_task_exists <id> → 0/1 ──────────────────────────────
task_cli_task_exists() {
    registry_task_file "$1" >/dev/null 2>&1
}

# ── 当前状态（运行态新源 → 旧 status 推导 → 快照字段回退）───────────────────
task_cli_state_for() {   # <id> <task_file> → 当前状态（echo）
    id=$1; tf=$2
    if [ -n "${TASK_CLI_TASKS_DIR:-}" ] && [ -d "$TASK_CLI_TASKS_DIR/$id" ]; then
        runtime_current_state "$TASK_CLI_TASKS_DIR/$id"
        return 0
    fi
    grep '^runtime.state=' "$tf" | head -1 | cut -d= -f2-
}

# ── daemon 判定（注入锁时）：0=运行 1=未运行/无锁 ───────────────────────────
task_cli_daemon_running() {
    [ -n "${TASK_CLI_LOCK:-}" ] || return 1   # 未注入锁 → 视为未运行（不可判）
    lifecycle_lock_alive "$TASK_CLI_LOCK"
}

# ── task list：每行 <id>|<name>|<trigger>|<action>|<enabled>|<state> ────────
# rc：0 正常 / 2 配置无效。daemon 停机不影响 list（静态快照可离线查看）。
task_cli_list() {
    task_cli_config_valid || {
        echo "ERROR: configuration invalid (no valid task snapshot)" >&2
        return 2
    }
    for id in $(registry_task_ids); do
        f=$(registry_task_file "$id") || continue
        name=$(grep '^name=' "$f" | head -1 | cut -d= -f2-)
        trigger=$(grep '^trigger=' "$f" | head -1 | cut -d= -f2)
        action=$(grep '^action.command=' "$f" | head -1 | cut -d= -f2-)
        enabled=$(grep '^enabled=' "$f" | head -1 | cut -d= -f2)
        state=$(task_cli_state_for "$id" "$f")
        echo "$id|$name|$trigger|$action|$enabled|$state"
    done
    return 0
}

# ── task status <id>：来源 + 状态 + 最近一次执行信息（key=value）────────────
# rc：0 正常 / 1 任务不存在 / 2 配置无效 / 3 daemon 未运行。
task_cli_status() {
    id=$1
    [ -n "$id" ] || { echo "ERROR: usage: task status <id>" >&2; return 1; }
    task_cli_config_valid || {
        echo "ERROR: configuration invalid (no valid task snapshot)" >&2
        return 2
    }
    f=$(registry_task_file "$id") || {
        echo "ERROR: task not found: $id" >&2
        return 1
    }
    if [ -n "${TASK_CLI_LOCK:-}" ] && ! task_cli_daemon_running; then
        echo "ERROR: daemon is not running — cannot report live task state (disk state may be stale)" >&2
        return 3
    fi

    rdir="${TASK_CLI_TASKS_DIR:-}/$id"
    echo "id=$id"
    echo "name=$(grep '^name=' "$f" | head -1 | cut -d= -f2-)"
    echo "enabled=$(grep '^enabled=' "$f" | head -1 | cut -d= -f2)"
    echo "trigger=$(grep '^trigger=' "$f" | head -1 | cut -d= -f2)"
    echo "dependency=$(grep '^dependency=' "$f" | head -1 | cut -d= -f2-)"
    echo "condition=$(grep '^condition=' "$f" | head -1 | cut -d= -f2-)"
    echo "action=$(grep '^action.command=' "$f" | head -1 | cut -d= -f2-)"
    echo "source.type=$(grep '^source.type=' "$f" | head -1 | cut -d= -f2)"
    echo "source.line=$(grep '^source.line=' "$f" | head -1 | cut -d= -f2)"
    echo "source.raw=$(grep '^source.raw=' "$f" | head -1 | cut -d= -f2-)"
    echo "state=$(task_cli_state_for "$id" "$f")"
    if [ -d "$rdir" ] && [ -f "$rdir/status.txt" ]; then
        echo "legacy_status=$(cat "$rdir/status.txt" 2>/dev/null)"
    else
        echo "legacy_status="
    fi
    echo "run_count=$(grep '^runtime.run_count=' "$f" | head -1 | cut -d= -f2)"
    echo "last_status=$(grep '^runtime.last_status=' "$f" | head -1 | cut -d= -f2-)"
    echo "last_exit=$(grep '^runtime.last_exit=' "$f" | head -1 | cut -d= -f2-)"
    echo "last_start=$(grep '^runtime.last_start=' "$f" | head -1 | cut -d= -f2-)"
    echo "last_end=$(grep '^runtime.last_end=' "$f" | head -1 | cut -d= -f2-)"
    if [ -n "${TASK_CLI_LOCK:-}" ]; then
        if task_cli_daemon_running; then echo "daemon=running"; else echo "daemon=stopped"; fi
    fi
    if [ -d "$rdir" ] && [ -f "$rdir/events.log" ]; then
        echo "last_event=$(tail -1 "$rdir/events.log" 2>/dev/null)"
    else
        echo "last_event="
    fi
    # P5-08：触发/下次执行/最近原因/条件/依赖 只读摘要（既有行零改动，仅新增行）
    st_trig=$(grep '^trigger=' "$f" | head -1 | cut -d= -f2)
    tk=$(task_cli_trigger_kind "$st_trig" 2>/dev/null) || tk=""
    echo "trigger_kind=$tk"
    nd=$(task_cli_next_due "$(task_cli_base)" "$st_trig" "$id" 2>/dev/null) || nd=""
    echo "next_due=$nd"
    echo "last_trigger_cause=$(task_cli_last_cause "$id" 2>/dev/null)"
    echo "condition_state=$(_tcli_cond_state "${TASK_CLI_TASKS_DIR:-}" "$id")"
    echo "dependency_state=$(_tcli_dep_state "${TASK_CLI_TASKS_DIR:-}" "$id")"
    # P4-09：门控状态行（WAITING + 原因；缺省空）
    if [ -d "$rdir" ] && [ "$(cat "$rdir/state.txt" 2>/dev/null)" = "WAITING" ]; then
        greason=$(grep -E '\|(gate_wait|gate_fail)\|' "$rdir/events.log" 2>/dev/null | tail -1 | cut -d'|' -f7-)
        if [ -n "$greason" ]; then
            echo "Gate: WAITING ($greason)"
        else
            echo "Gate: WAITING"
        fi
    fi
    return 0
}

# ── P5-08 只读查询助手（测试域自包含镜像；生产在 su-scheduler-runtime）─────────
# base 解析：TASK_CLI_BASE 优先（测试注入），回退 TR_BASE（registry_init 设置）。
task_cli_base() { echo "${TASK_CLI_BASE:-${TR_BASE:-}}"; }
task_cli_audit_file() { echo "$(task_cli_base)/scheduler/audit.log"; }
task_cli_trigger_kind() {   # <trigger> → kind=...;...（未知家族 → 空 + rc1）
    tk_trig=$1
    case "$tk_trig" in
        boot) echo "kind=boot" ;;
        boot_completed) echo "kind=bootcompleted" ;;
        oneshot:*) echo "kind=oneshot;time=$(echo "$tk_trig" | cut -d: -f2)" ;;
        delay:*) echo "kind=delay;minutes=$(echo "$tk_trig" | cut -d: -f2)" ;;
        interval:*) echo "kind=interval;minutes=$(echo "$tk_trig" | cut -d: -f2)" ;;
        cron:*) echo "kind=cron;spec=${tk_trig#cron:}" ;;
        [0-9][0-9]:[0-9][0-9]|[0-9][0-9][0-9][0-9]) echo "kind=time;time=$(echo "$tk_trig" | sed 's/://g')" ;;
        weekly:*|nweekly:*|monthly:*|nmonthly:*|yearly:*) _tcli_adv_family "$tk_trig" ;;
        *) return 1 ;;
    esac
}
_tcli_adv_family() {
    case "$1" in
        weekly:*) echo "kind=advanced;family=weekly" ;;
        nweekly:*) echo "kind=advanced;family=nweekly" ;;
        monthly:*) echo "kind=advanced;family=monthly" ;;
        nmonthly:*) echo "kind=advanced;family=nmonthly" ;;
        yearly:*) echo "kind=advanced;family=yearly" ;;
    esac
}
task_cli_next_due() {   # <base> <trigger> <id> → echo 距下次命中秒数（rc0）；不可预测 rc1
    nd_base=$1; nd_trig=$2; nd_id=$3
    case "$nd_trig" in
        boot) [ "${TRIGGER_BOOT_CONTEXT:-0}" = "1" ] && { echo 0; return 0; } || return 1 ;;
        boot_completed) [ "${TRIGGER_BOOT_COMPLETED_CONTEXT:-0}" = "1" ] && { echo 0; return 0; } || return 1 ;;
        oneshot:*) _tcli_hhmm_due "$(echo "$nd_trig" | cut -d: -f2)" ;;
        [0-9][0-9]:[0-9][0-9]|[0-9][0-9][0-9][0-9]) _tcli_hhmm_due "$(echo "$nd_trig" | sed 's/://g')" ;;
        *) return 1 ;;
    esac
}
_tcli_hhmm_due() {   # <HHMM> → 距该时刻秒数（当天或明天，取最小正值）
    th=$(echo "$1" | cut -c1-2); tm=$(echo "$1" | cut -c3-4)
    th=$(echo "$th" | sed 's/^0*//'); tm=$(echo "$tm" | sed 's/^0*//')
    [ -z "$th" ] && th=0; [ -z "$tm" ] && tm=0
    now=${TRIGGER_DECISION_NOW:-$(date +%H%M)}
    nh=$(echo "$now" | cut -c1-2); nm=$(echo "$now" | cut -c3-4)
    nh=$(echo "$nh" | sed 's/^0*//'); nm=$(echo "$nm" | sed 's/^0*//')
    [ -z "$nh" ] && nh=0; [ -z "$nm" ] && nm=0
    target=$((th * 60 + tm)); nowmin=$((nh * 60 + nm))
    if [ "$target" -gt "$nowmin" ]; then
        echo $(((target - nowmin) * 60))
    elif [ "$target" -eq "$nowmin" ]; then
        echo 0
    else
        echo $(((1440 - nowmin + target) * 60))
    fi
    return 0
}
task_cli_last_cause() {   # <id> → scheduler/audit.log 末条 op=exec 的 cause=（无 → 空+rc1）
    lc_id=$1
    lc_f=$(task_cli_audit_file)
    [ -f "$lc_f" ] || return 1
    grep -F "task=$lc_id|" "$lc_f" 2>/dev/null | grep -F 'op=exec' | tail -1 \
        | sed -n 's/.*|cause=\([^|]*\).*/\1/p'
}
_tcli_cond_unzero() {   # <str> → echo 去前导零数字
    ccu=$1
    while :; do
        case "$ccu" in 0*) ccu=${ccu#0} ;; *) break ;; esac
    done
    [ -n "$ccu" ] || ccu=0
    echo "$ccu"
}
_tcli_cond_eval() {   # <expr> <tasks> → 0=真 1=假 2=非法（受限白名单：time.* / task.state）
    cee_expr=$1; cee_tasks=$2
    case "$cee_expr" in
        "{{"*"}}") cee_inner=${cee_expr#\{\{}; cee_inner=${cee_inner%\}\}} ;;
        *) return 2 ;;
    esac
    cee_inner=$(echo "$cee_inner" | sed 's/^[ \t]*//;s/[ \t]*$//')
    set -- $cee_inner
    [ $# -eq 3 ] || return 2
    cee_pred=$1; cee_op=$2; cee_val=$3
    case "$cee_pred" in
        time.hour|time.minute|time.wday)
            cee_now=${TRIGGER_DECISION_NOW:-$(date +%H%M)}
            case "$cee_pred" in
                time.hour) cee_cur=$(echo "$cee_now" | cut -c1-2) ;;
                time.minute) cee_cur=$(echo "$cee_now" | cut -c3-4) ;;
                time.wday) cee_cur=$(date +%w) ;;
            esac
            cee_cur=$(_tcli_cond_unzero "$cee_cur")
            cee_val=$(_tcli_cond_unzero "$cee_val")
            case "$cee_val" in ''|*[!0-9]*) return 2 ;; esac
            case "$cee_op" in
                ==) [ "$cee_cur" -eq "$cee_val" ] && return 0 || return 1 ;;
                '!=') [ "$cee_cur" -ne "$cee_val" ] && return 0 || return 1 ;;
                '<') [ "$cee_cur" -lt "$cee_val" ] && return 0 || return 1 ;;
                '>') [ "$cee_cur" -gt "$cee_val" ] && return 0 || return 1 ;;
                '<=') [ "$cee_cur" -le "$cee_val" ] && return 0 || return 1 ;;
                '>=') [ "$cee_cur" -ge "$cee_val" ] && return 0 || return 1 ;;
                *) return 2 ;;
            esac ;;
        task.state*)
            cee_dep=${cee_pred#task.state(}; cee_dep=${cee_dep%)}
            cee_df=$(registry_task_file "$cee_dep" 2>/dev/null)
            cee_curstate=$(task_cli_state_for "$cee_dep" "$cee_df" 2>/dev/null)
            case "$cee_op" in
                ==) [ "$cee_curstate" = "$cee_val" ] && return 0 || return 1 ;;
                '!=') [ "$cee_curstate" != "$cee_val" ] && return 0 || return 1 ;;
                *) return 2 ;;
            esac ;;
        *) return 2 ;;
    esac
}
_tcli_cond_state() {   # <tasks> <id> → ok|unsat|n/a（空条件=恒真 ok）
    cst_tasks=$1; cst_id=$2
    cst_tf=$(registry_task_file "$cst_id" 2>/dev/null)
    [ -n "$cst_tf" ] || { echo "n/a"; return 0; }
    cst_cond=$(grep '^condition=' "$cst_tf" 2>/dev/null | head -1 | cut -d= -f2-)
    [ -z "$cst_cond" ] && { echo "ok"; return 0; }
    if _tcli_cond_eval "$cst_cond" "$cst_tasks"; then
        echo "ok"
    else
        cee_rc=$?
        if [ "$cee_rc" -eq 2 ]; then echo "illegal"; else echo "unsat"; fi
    fi
    return 0
}
_tcli_dep_state() {   # <tasks> <id> → ok|satisfied|waiting|unsat（无依赖=恒真 ok）
    dst_tasks=$1; dst_id=$2
    dst_tf=$(registry_task_file "$dst_id" 2>/dev/null)
    [ -n "$dst_tf" ] || { echo "ok"; return 0; }
    dst_dep=$(grep '^dependency=' "$dst_tf" 2>/dev/null | head -1 | cut -d= -f2-)
    [ -z "$dst_dep" ] && { echo "ok"; return 0; }
    dst_tokens=$(printf '%s' "$dst_dep" | tr ', ' ',' | tr -s ',' | sed 's/^,//; s/,$//' | sed 's/,/ /g')
    dst_fail=0; dst_wait=0; dst_opt=0
    for dst_e in $dst_tokens; do
        dst_optional=0
        case "$dst_e" in
            "?"*) dst_optional=1; dst_e=${dst_e#\?} ;;
        esac
        dst_depid=$dst_e; dst_want=STOPPED
        case "$dst_e" in
            *:*)
                dst_depid=${dst_e%%:*}
                dst_want=${dst_e#*:}
                ;;
        esac
        [ -n "$dst_depid" ] || continue
        dst_df=$(registry_task_file "$dst_depid" 2>/dev/null)
        dst_cur=$(task_cli_state_for "$dst_depid" "$dst_df" 2>/dev/null)
        if [ "$dst_cur" = "$dst_want" ]; then
            continue
        fi
        if [ "$dst_optional" -eq 1 ]; then
            dst_opt=1
            continue
        fi
        if [ -z "$dst_df" ]; then
            dst_wait=1
            continue
        fi
        case "$dst_cur" in
            STOPPED|FAILED) dst_fail=1 ;;
            *) dst_wait=1 ;;
        esac
    done
    if [ "$dst_fail" -eq 1 ]; then
        echo "unsat"
    elif [ "$dst_wait" -eq 1 ]; then
        echo "waiting"
    else
        echo "satisfied"
    fi
    return 0
}