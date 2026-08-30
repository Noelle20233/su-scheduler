#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Action Runner（P1-08 接线层）
# ═══════════════════════════════════════════════════════════════════════════
# 作用：让任务执行通过统一 ActionProvider 运行——Task Engine **不直接拼接
# 执行命令**（P1-08 验收 1）：读取 Canonical Task Registry（P1-06）快照中的
# 任务动作字段（action.command / action.termux / action.interactive），经
# provider_dispatch action command 分发执行，把 PID 落盘为任务工件 pid.txt
# （镜像 daemon `echo $! > "$task_dir/pid.txt"`，L486）。
#
# 使用前须 source：tests/providers/providers.sh（含 lib.sh 注册表/分发）与
# tests/task-registry/lib.sh（registry API）；任务文件取自 registry 快照
# （registry_task_file <id>）或任何合法 schema_version=2 的 Task 对象。
#
# 保持的 legacy 执行语义（P1-01 §5 / su-schedulerd execute_task）：
#   普通命令 / 脚本智能执行 / Termux（helper READY|LOCKED|缺失优雅失败）/
#   Interactive（FIFO task.in/task.out + sh -i）——四模式全部由
#   CommandActionProvider 承担，本层只负责"读任务字段 → dispatch → 记 PID"。
# 工件语义与 providers.sh 相同（output.log/exit_code.txt/end_time.txt/
#   SUCCESS|FAILED；interactive 保真怪癖只写 exit_code.txt）。
#
# 返回码：0=已启动 1=任务无效（缺 action.command）/分发失败；stdout 至多一
# 行 `id=<id> pid=<pid> dir=<dir>`。
# ═══════════════════════════════════════════════════════════════════════════
set -u

action_run_log() {
    [ "${ACTION_RUN_LOG:-1}" = "1" ] && echo "[action-run] $1" >&2
}

# ── 执行一个任务：action_run_task <task_file> → id=.. pid=.. dir=.. ─────────
action_run_task() {
    task=$1
    [ -f "$task" ] || { action_run_log "ERROR task file missing: $task"; return 1; }
    id=$(grep '^id=' "$task" | head -1 | cut -d= -f2)
    cmd=$(grep '^action.command=' "$task" | head -1 | cut -d= -f2-)
    termux=$(grep '^action.termux=' "$task" | head -1 | cut -d= -f2)
    interactive=$(grep '^action.interactive=' "$task" | head -1 | cut -d= -f2)
    [ -n "$id" ] || { action_run_log "ERROR no id in $task"; return 1; }
    [ -n "$cmd" ] || { action_run_log "ERROR no action.command in $task (id=$id)"; return 1; }

    # prepare（建任务目录 + command.txt/start_time.txt/status.txt=RUNNING）
    dir=$(provider_dispatch action command prepare "$id" "$cmd") || {
        action_run_log "ERROR prepare failed for $id"
        return 1
    }
    # start：stdout（PID）落盘 task/pid.txt（引擎式接收，镜像 daemon L486）
    provider_dispatch action command start "$id" "$cmd" "${termux:-0}" "${interactive:-0}" \
        > "$dir/pid.txt" 2>/dev/null || {
        action_run_log "ERROR start failed for $id"
        return 1
    }
    pid=$(cat "$dir/pid.txt")
    echo "id=$id pid=$pid dir=$dir"
}

# ── 等待任务结束：action_run_wait <dir> <id> <pid>（exit_code.txt 或进程退）──
action_run_wait() {
    dir=$1; id=$2; pid=$3
    i=0
    while [ "$i" -lt 60 ]; do
        [ -f "$dir/exit_code.txt" ] && return 0
        provider_dispatch action command status "$id" "$pid" >/dev/null 2>&1 || return 1
        sleep 1
        i=$((i + 1))
    done
    return 1
}