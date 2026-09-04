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