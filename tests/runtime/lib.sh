#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Runtime State & Event Log（P1-09）
# ═══════════════════════════════════════════════════════════════════════════
# 作用：在不破坏现有 CLI / 旧任务工件的前提下，建立**统一的 Task 状态来源**
# 与结构化事件日志：
#   - 保留旧兼容文件：status.txt / pid.txt / output.log / exit_code.txt /
#     end_time.txt / start_time.txt（只读，绝不改写——验收 2「新旧不互覆盖」）。
#   - 新状态来源：<task_dir>/state.txt（单值，P1-03 v2 状态集合）。
#   - 事件日志：<task_dir>/events.log（追加式，每行一次关键变化）。
#   - 事件行格式（验收要求字段序）：
#       <timestamp>|<task_id>|<event>|<state>|<pid>|<exit_code>|<message>
#   - 原子化：state.txt 用 tmp+mv（镜像 registry current 指针）；events.log
#     用 O_APPEND 追加单行（POSIX 原子追加）——「尽量原子化」。
#   - 日志失败**绝不中止任务执行**（验收）：本库所有写操作失败只返回非 0
#     （2=写失败），内部不 exit；调用方若忽略返回值，任务流程不受影响。
#   - 权限：目录 0755、文件 0644（与现有任务工件一致，见 P1-01 §3）。
#   - daemon 重启残留识别（验收 3）：runtime_scan_stale 扫描任务目录，对
#     「运行态（status.txt 或 state.txt=RUNNING）但 pid.txt 进程已不存在」
#     的记录 -> 记 daemon_restart 事件 + 按 P1-03 task_state_rehydrate 将
#     state.txt 置 FAILED；**旧 status.txt 保持不变**（CLI 仍按旧语义读取）。
#
# 使用前须 source：tests/state-machine/lib.sh（TSM 状态集合/再水合/legacy 映射）。
# 上下文变量（缺省保持 daemon 的目录语义；测试可注入）：
#   RUNTIME_STATE_FILE? 不注入——固定 <dir>/state.txt 与 <dir>/events.log。
# ═══════════════════════════════════════════════════════════════════════════
set -u

# ── 事件集合（关键变化；与 P1-03 触发原因令牌对齐 + create/delete）─────────
RT_EVENTS='create delete config_load time_trigger manual_exec spawn action_success action_failure timeout stop_request daemon_restart rearm enable disable supervisor probe recover'

runtime_log() {
    [ "${RT_LOG:-1}" = "1" ] && echo "[runtime] $1" >&2
}

# ── 文件路径（固定命名：state.txt 新状态源 / events.log 事件日志）───────────
runtime_state_file()  { echo "$1/state.txt"; }
runtime_events_file() { echo "$1/events.log"; }

# ── 当前状态：<dir> → state.txt 内容；缺省从旧 status.txt 推导（不写旧文件）──
runtime_current_state() {
    dir=$1
    sf=$(runtime_state_file "$dir")
    if [ -f "$sf" ] && [ -s "$sf" ]; then
        cat "$sf"
        return 0
    fi
    # 新状态源缺失：从旧兼容文件推导（task_state_from_legacy），不创建任何文件
    if [ -f "$dir/status.txt" ]; then
        task_state_from_legacy "$(cat "$dir/status.txt")"
        return 0
    fi
    echo PENDING
}

# ── 事件/状态写入：runtime_log_event <dir> <task_id> <event> <state> <pid>
#    <exit_code> <message> → 0 成功 / 1 拒绝（非法 state 或 event）/ 2 写失败
# 规则：
#   - state 须为 P1-03 合法状态（task_state_is_valid）；event 须在 RT_EVENTS；
#     任一非法 → 整体拒绝（rc 1），不写半成品（不污染状态源）。
#   - 先追加事件行（O_APPEND 原子），再 tmp+mv 更新 state.txt。
#   - message 中的 `|` 统一替换为 `;`（保证 7 字段格式稳定）。
#   - 写失败仅返回 2，不 exit——任务执行绝不因日志失败中止。
runtime_log_event() {
    dir=$1; task_id=$2; event=$3; state=$4; pid=${5:-}; exit_code=${6:-}; message=${7:-}
    [ -n "$dir" ] || { runtime_log "ERROR log_event: dir required"; return 1; }
    task_state_is_valid "$state" || {
        runtime_log "WARNING log_event: illegal state '$state' rejected (task=$task_id)"
        return 1
    }
    case " $RT_EVENTS " in
        *" $event "*) ;;
        *) runtime_log "WARNING log_event: unknown event '$event' rejected (task=$task_id)"; return 1 ;;
    esac
    [ -d "$dir" ] || mkdir -p "$dir" || { runtime_log "ERROR log_event: cannot mkdir $dir"; return 2; }

    ts=$(date "+%Y-%m-%d %H:%M:%S")
    # message 去竖线（保持 7 字段）；pid/exit_code 可能为空（|| / |）
    msg=$(printf '%s' "$message" | sed 's/|/;/g')
    line="$ts|$task_id|$event|$state|$pid|$exit_code|$msg"

    # 1) 事件行原子追加（subshell 包裹重定向：失败返回非 0 且错误静音）
    if ( printf '%s\n' "$line" >> "$(runtime_events_file "$dir")" ) 2>/dev/null; then
        :
    else
        runtime_log "ERROR log_event: append failed for $task_id (event=$event) — task continues"
        return 2
    fi
    # 2) 状态源原子更新（tmp+mv，subshell 包裹：失败返回非 0 且错误静音）
    sf=$(runtime_state_file "$dir")
    tmp="$sf.tmp"
    if ( printf '%s\n' "$state" > "$tmp" && mv -f "$tmp" "$sf" ) 2>/dev/null; then
        :
    else
        rm -f "$tmp" 2>/dev/null
        runtime_log "ERROR log_event: state write failed for $task_id (state=$state) — task continues"
        return 2
    fi
    return 0
}

# ── daemon 重启残留识别：runtime_scan_stale <tasks_dir> → 残留 id（每行一个）
# 规则（验收 3）：
#   - 任务目录形如 <tasks_dir>/<id>/；对每个含 pid.txt 的目录判定：
#   - 「运行态」= status.txt=RUNNING（旧）或 state.txt 经映射为 v2 执行态。
#   - pid 不存在（/proc/<pid> 不可见）→ 残留运行记录：
#       记事件 daemon_restart（pid=记录值）；state.txt 按 task_state_rehydrate
#       更新（执行态→FAILED）；**不改写旧 status.txt**。
#   - pid 存活 → 不是残留（不动作）。
#   - 本函数只做识别+记录，不杀进程、不删目录（识别归识别，清理属接线层）。
runtime_scan_stale() {
    root=$1
    [ -d "$root" ] || { runtime_log "ERROR scan_stale: no tasks dir $root"; return 2; }
    found=0
    for p in "$root"/*; do
        [ -d "$p" ] || continue
        [ -f "$p/pid.txt" ] || continue
        id=$(basename "$p")
        pid=$(cat "$p/pid.txt" 2>/dev/null)
        # 运行态判定（新旧任一来源；新 source 缺失时从旧推导）
        cur=$(runtime_current_state "$p")
        case "$cur" in
            STARTING|RUNNING|HEALTHY|UNHEALTHY|RECOVERING|STOPPING) ;;
            *) continue ;;
        esac
        # 进程存活判定
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            continue
        fi
        # 残留：按 P1-03 再水合（执行态→FAILED），记事件；旧 status.txt 不动
        newstate=$(task_state_rehydrate "$cur")
        runtime_log_event "$p" "$id" daemon_restart "$newstate" "$pid" "" \
            "stale running record detected at startup (legacy status.txt untouched)"
        echo "$id"
        found=$((found + 1))
    done
    return 0
}