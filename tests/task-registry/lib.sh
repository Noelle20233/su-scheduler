#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Canonical Task Registry（P1-06）
# ═══════════════════════════════════════════════════════════════════════════
# 作用：让 daemon 每轮使用**统一 Task 注册表**，而不是重复直接扫描 config.txt。
# 依赖：P1-05 Legacy Config Adapter（使用前须 source adapter.sh 与本文件）。
#
# 设计要点：
#   - 每次（重新）加载 = 一次完整解析 → **完整 Task 快照**（snapshot），存于
#     <base>/snapshots/snap_<N>/（N 为确定性递增序号，无时间戳）。
#   - **稳定 ID 索引**：快照目录内每任务一个 <id>.task（id 规则见
#     docs/architecture/task-id-rules.md）；读取 API 一律按 id。
#   - **保留配置来源**：每任务含 source.*（行号/原文，adapter 产出）；快照
#     manifest 记录 config 路径、parse_rc、task_count。
#   - **hot reload**：registry_reload <config> 随时重解析并原子切换。
#   - **无效回退（验收）**：新配置解析失败（rc2 / rc1-零任务 / 文件不可读）→
#     保留**最后一次有效快照**，任务不消失；绝不产生"部分新+部分旧"混合。
#   - **原子切换**：新快照在独立目录构建（adapter 直接写入该目录），快照目录
#     构建后**不可变**；`current` 指针单文件 tmp+mv 原子更新 → 读者永远看到
#     完整旧快照或完整新快照（无混合态）。
#   - **防重复注册（验收）**：提交前校验——id==文件名 且 快照内 id 唯一；
#     违规即该快照无效（回退）；配置修改通过"整快照替换"天然避免重复任务。
#   - **单一调度入口**：所有消费者只通过 current 快照读任务；config.txt 文本
#     只在 reload 内部被 adapter 读取（未来 daemon 接线必须以其替换逐分钟扫描）。
#
# 返回码（registry_reload）：
#   0 = 新快照已提交并生效
#   1 = 解析失败/无效 → 回退（保留现有快照；当前指针不动）
#   2 = 硬错误（无 config 路径 / adapter 未加载）→ 现状不动
# ═══════════════════════════════════════════════════════════════════════════
set -u

TR_LOGGING=1
registry_log() {
    [ "${TR_LOGGING:-1}" = "1" ] && echo "[task-registry] $1" >&2
}

# ── 初始化：registry_init <base_dir> <config> ───────────────────────────────
registry_init() {
    TR_BASE=${1:-}
    TR_CONFIG_PATH=${2:-}
    [ -n "$TR_BASE" ] || { registry_log "ERROR init: base_dir required"; return 2; }
    [ -n "$TR_CONFIG_PATH" ] || { registry_log "ERROR init: config required"; return 2; }
    mkdir -p "$TR_BASE/snapshots" || { registry_log "ERROR init: cannot mkdir $TR_BASE/snapshots"; return 2; }
    if [ -f "$TR_CONFIG_PATH" ]; then
        registry_reload "$TR_CONFIG_PATH"
    else
        # 首载无回退：快照为空（current 未建立），记录错误
        registry_log "ERROR init: config not found: $TR_CONFIG_PATH (no fallback on first load)"
        TASK_REGISTRY_SNAPSHOT=""
        return 1
    fi
}

# ── 快照管理 ────────────────────────────────────────────────────────────────
registry_snapshot_next() {   # 确定性递增序号（无时间戳）
    next=1
    for d in "$TR_BASE"/snapshots/snap_*; do
        [ -d "$d" ] || continue
        n=${d##*snap_}
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -ge "$next" ] && next=$((n + 1))
    done
    echo "snap_$next"
}

registry_current_snapshot_id() {
    [ -f "$TR_BASE/current" ] && cat "$TR_BASE/current" || echo ""
}

registry_snapshot_dir() {   # 当前快照目录（消费者唯一读入口）
    id=$(registry_current_snapshot_id)
    [ -n "$id" ] && echo "$TR_BASE/snapshots/$id"
}

registry_has_task() {        # registry_has_task <id>
    d=$(registry_snapshot_dir)
    [ -n "$d" ] && [ -f "$d/$1.task" ]
}

registry_task_file() {       # registry_task_file <id> → echo path
    d=$(registry_snapshot_dir)
    if [ -n "$d" ] && [ -f "$d/$1.task" ]; then
        echo "$d/$1.task"
        return 0
    fi
    return 1
}

registry_task_ids() {        # 当前快照全部任务 id（排序）——调度唯一数据源
    d=$(registry_snapshot_dir)
    [ -n "$d" ] && ls "$d" 2>/dev/null | grep '\.task$' | sed 's/\.task$//' | sort
}

registry_manifest() {        # 当前快照 manifest（逐行）
    d=$(registry_snapshot_dir)
    [ -n "$d" ] && cat "$d/manifest" 2>/dev/null
}

# ── 提交校验：快照合法 ⇔ id==文件名 且 快照内 id 唯一（防重复注册）────────────
# 返回 0=合法（TASK_REGISTRY_COUNT 置任务数）；1=非法（并记录原因）
_registry_snap_valid() {
    sdir=$1
    seen=""
    count=0
    for f in "$sdir"/*.task; do
        [ -f "$f" ] || continue
        count=$((count + 1))
        id=$(basename "$f" .task)
        iid=$(grep '^id=' "$f" | head -1 | cut -d= -f2)
        [ "$id" = "$iid" ] || {
            registry_log "ERROR snapshot $sdir: id field '$iid' != filename '$id'"
            return 1
        }
        case " $seen " in
            *" $id "*) registry_log "ERROR snapshot $sdir: duplicate task id '$id'"; return 1 ;;
        esac
        seen="$seen $id"
    done
    TASK_REGISTRY_COUNT=$count
    return 0
}

# ── reload 主流程 ────────────────────────────────────────────────────────────
registry_reload() {
    config=${1:-$TR_CONFIG_PATH}
    [ -n "$config" ] || { registry_log "ERROR reload: no config (init first)"; echo "HARD"; return 2; }
    [ -f "$config" ] || {
        # 文件不可读 = 损坏形态之一 → 回退（保留现有快照；任务不消失）
        registry_log "ERROR reload: config not found: $config (fallback: keeping current snapshot)"
        echo "KEPT"
        return 1
    }
    command -v legacy_adapter_parse >/dev/null 2>&1 || {
        registry_log "ERROR reload: legacy_adapter_parse not sourced (source adapter.sh first)"
        echo "HARD"
        return 2
    }

    sid=$(registry_snapshot_next)
    sdir="$TR_BASE/snapshots/$sid"
    mkdir -p "$sdir" || { registry_log "ERROR reload: cannot mkdir $sdir"; echo "HARD"; return 2; }

    # 完整解析 → 新快照目录（adapter 原子写；此处为独立目录的“全量构建”）
    stdout=$(legacy_adapter_parse "$config" "$sdir")
    arc=$?
    tcount=$(ls "$sdir" 2>/dev/null | grep -c '\.task$')

    # 快照有效性策略：
    #   rc0                → 有效（含 0 任务：用户主动清空合法）
    #   rc1 且 ≥1 任务      → 有效（部分行失败已被隔离 = “完整新子集”，非混合）
    #   rc1 且 0 任务       → 无效（整份损坏，回退）
    #   rc2                → 无效（文件级失败，回退）
    valid=0
    if [ "$arc" -eq 0 ]; then
        valid=1
    elif [ "$arc" -eq 1 ] && [ "$tcount" -ge 1 ]; then
        valid=1
    fi

    if [ "$valid" -eq 1 ]; then
        if _registry_snap_valid "$sdir"; then
            {
                echo "snapshot=$sid"
                echo "config=$config"
                echo "parse_rc=$arc"
                echo "task_count=$TASK_REGISTRY_COUNT"
            } > "$sdir/manifest.tmp" && mv "$sdir/manifest.tmp" "$sdir/manifest"
            # 原子切换当前指针（tmp+mv）→ 读者可见完整旧或完整新（无混合态）
            echo "$sid" > "$TR_BASE/current.tmp" && mv "$TR_BASE/current.tmp" "$TR_BASE/current"
            TASK_REGISTRY_SNAPSHOT=$sid
            echo "$sid"
            return 0
        fi
        registry_log "ERROR reload: snapshot $sid invalid (dup/mismatch); fallback"
        rm -rf "$sdir"
        TASK_REGISTRY_SNAPSHOT=$(registry_current_snapshot_id)
        return 1
    fi

    # 无效 → 回退：删除未提交的快照目录，现有快照 / 指针不动
    registry_log "ERROR reload: parse rc=$arc tasks=$tcount -> invalid; keeping last valid snapshot"
    rm -rf "$sdir"
    TASK_REGISTRY_SNAPSHOT=$(registry_current_snapshot_id)
    echo "KEPT"
    return 1
}