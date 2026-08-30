#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Legacy Config Adapter（P1-05）— config.txt → 内部 Task v2
# ═══════════════════════════════════════════════════════════════════════════
# 作用：把现有 config.txt（legacy 格式，P1-01 锁定）转换为内部 Task（P1-02
#       schema v2）。保持 legacy 全部语义：boot/HHMM/HH:MM/weekly/monthly/
#       yearly/nweekly/nmonthly/heredoc/全部 modifier/Termux 模式/注释/空行。
#
# 用法：
#   sh adapter.sh parse <config> <out_dir>      # 独立运行
#   source adapter.sh; legacy_adapter_parse <config> <out_dir>
#
# 返回码：
#   0 = 全部行解析成功（任务已全部写出）
#   1 = 存在行级错误（合法行仍写出完整任务；出错行不产出任务——无半成品）
#   2 = 文件级错误（未产出任何任务）
#
# stdout：每任务一行 `task=<id> file=<path>`（机器可读）
# stderr：`[legacy-adapter] <ERROR|WARNING> <config>:<line>: <detail>`
#
# 设计要点（对齐既有基线）：
#   - 行号保留：source.line = config.txt 原始行号（heredoc 为 头行-EOF 行范围）
#   - 稳定 Task ID：t<行号>_<trigger_norm>（无时间戳；规则见
#     docs/architecture/task-id-rules.md）→ 同一配置重复加载 ID 一致
#   - 解析语义 = system/bin/su-schedulerd v1.6.8 参考镜像（parse_modifiers /
#     extract_command / heredoc 重组，见 P1-01 golden；本文件自带副本，
#     一致性由 tests/legacy-adapter/test.sh 与 P1-02 样例断言）
#   - 命令文本保持原样：action.command = extract_command 结果原文（含 heredoc
#     残留等怪癖，P1-01 §6）；source.raw = 原始行原文
#   - 失败原子性：每个任务先写 <id>.task.tmp 再 mv；INT/TERM/HUP 清理 tmp →
#     绝不产生半成品 Task（验收标准）
#   - 错误处置：文件缺失/不可读 → rc2；触发器含控制字符 → 行级错误 rc1、
#     该行跳过、其余行照常；unterminated heredoc 按 legacy 语义接受（读到
#     EOF；与 daemon 一致，P1-01 §4.4）
# ═══════════════════════════════════════════════════════════════════════════
set -u

# ── 帮助函数 ────────────────────────────────────────────────────────────────
# clean：修剪首尾空白（daemon 语义），并去除 Windows 检出残留的 \r
clean() { echo "$1" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//'; }
# norm：去冒号（daemon L650 语义，用于 ID 派生）
norm()  { echo "$1" | sed 's/://g'; }
first_word() { echo "$1" | awk '{print $1}'; }
# esc：存储层转义——反斜杠 → \\，真实换行 → 字面 \n（P1-02 §6）
esc() {
    printf '%s' "$1" | awk '{ gsub(/\\/, "\\\\"); if (NR>1) printf "\\n"; printf "%s", $0 }'
}

# ── 参考镜像：daemon 解析函数（su-schedulerd v1.6.8，P1-01 golden 同源）─────
parse_modifiers() {
    line=$1
    notify_start=0; notify_end=0; delete_after=0; interactive=0
    use_termux=0; run_once_now=0; custom_msg=""
    mods=$(echo "$line" | sed -n 's/.* : //p')
    if [ -n "$mods" ]; then
        echo "$mods" | grep -q -- '--run-once-now' && run_once_now=1
        echo "$mods" | grep -q -- '--notify-start' && notify_start=1
        echo "$mods" | grep -q -- '--notify-end' && notify_end=1
        if echo "$mods" | grep -q -- '--notify' && ! echo "$mods" | grep -E -q -- '--notify-(start|end)'; then
            notify_start=1
            notify_end=1
        fi
        echo "$mods" | grep -q -- '--delete' && delete_after=1
        echo "$mods" | grep -q -- '--interactive' && interactive=1
        echo "$mods" | grep -q -- '--termux' && use_termux=1
        if echo "$mods" | grep -q -- '--msg='; then
            custom_msg=$(echo "$mods" | sed -n 's/.*--msg="\([^"]*\)".*/\1/p')
        fi
    fi
}

# 说明：daemon 用 `cut -d' ' -f2-`；GNU cut 对单字段行会回显整行（宿主怪癖），
# Android toybox cut 与文档化语义（P1-02：触发器-only 行 = 空命令，合法）取空。
# adapter 采用确定性语义：首 token 之后的内容；无第二个 token → 空。
# 单空格分隔（与 cut -d' ' -f2- 对多字段行一致）；多空格前导保留（同 cut）。
extract_command() {
    line=$1
    raw_cmd=$(printf '%s' "$line" | awk '{ rest=$0; if (sub(/^[^ ]+[ ]/, "", rest)) print rest; else print "" }')
    echo "$raw_cmd" | sed 's/[ \t]*;*[ \t]*:[ \t]*--.*//'
}

# ── 稳定 Task ID（规则见 docs/architecture/task-id-rules.md）────────────────
legacy_adapter_task_id() {   # <line> <trigger> → echo id
    echo "t${1}_$(norm "$2")"
}

# ── 任务写出（原子；无注释的纯 key=value，与 P1-02 §6 序列化一致）────────────
# 参数：<id> <trigger> <action> <stype> <sline> <sraw> <subject>
# flags 来自调用方已执行的 parse_modifiers；subject 用于 --boot 保留标志判定
_emit_task() {
    id=$1; trigger=$2; action=$3; stype=$4; sline=$5; sraw=$6; subject=$7
    boot_flag=0
    echo "$subject" | grep -q -- '--boot' && boot_flag=1
    name=$(first_word "$action")
    [ -n "$name" ] || name="task"
    name=$(printf '%s' "$name" | cut -c1-40)
    f="$out/$id.task"
    t="$f.tmp"
    tmp="$t"   # 全局，供 trap 清理
    {
        echo "schema_version=2"
        echo "id=$id"
        echo "name=$(esc "$name")"
        echo "enabled=1"
        echo "trigger=$(esc "$trigger")"
        echo "condition="
        echo "action.command=$(esc "$action")"
        echo "action.notify_start=$notify_start"
        echo "action.notify_end=$notify_end"
        echo "action.delete=$delete_after"
        echo "action.termux=$use_termux"
        echo "action.interactive=$interactive"
        echo "action.run_once_now=$run_once_now"
        echo "action.boot=$boot_flag"
        echo "action.msg=$(esc "$custom_msg")"
        echo "dependency="
        echo "health.type=none"
        echo "recovery.type=none"
        echo "retry.max=0"
        echo "retry.interval=60"
        echo "source.type=$stype"
        echo "source.line=$sline"
        echo "source.raw=$(esc "$sraw")"
        echo "runtime.state=PENDING"
        echo "runtime.run_count=0"
        echo "runtime.last_status="
        echo "runtime.last_exit="
        echo "runtime.last_start="
        echo "runtime.last_end="
        echo "runtime.pid="
    } > "$t"
    mv "$t" "$f"
    tmp=""
    echo "task=$id file=$f"
}

# ── 主入口：legacy_adapter_parse <config> <out_dir> ─────────────────────────
legacy_adapter_parse() {
    config=$1
    out=${2:-}
    rc=0

    if [ ! -f "$config" ]; then
        echo "[legacy-adapter] ERROR: config file not found: $config" >&2
        return 2
    fi
    if [ -z "$out" ]; then
        echo "[legacy-adapter] ERROR: out_dir required" >&2
        return 2
    fi
    if ! mkdir -p "$out"; then
        echo "[legacy-adapter] ERROR: cannot create out_dir: $out" >&2
        return 2
    fi

    tmp=""
    trap 'rm -f "$tmp"' INT TERM HUP

    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac

        trigger=$(echo "$cl" | awk '{print $1}')

        # 行级错误：触发器含控制字符（会污染 ID charset 与匹配，禁止半成品）
        if printf '%s' "$trigger" | grep -q '[[:cntrl:]]'; then
            echo "[legacy-adapter] ERROR $config:${lineno}: trigger contains control character: '$trigger'" >&2
            rc=1
            continue
        fi

        # ── heredoc 块（daemon L632-646 镜像：总是重组，含 `: :` 工件、字面 \n）──
        if echo "$cl" | grep -q '<<EOF'; then
            cmd_start=$(echo "$cl" | sed 's/^[^ ]* //' | sed 's/ *<<EOF.*//')
            multiline_cmd=""
            block_raw="$cl"
            # NOTE: $(printf '\n') would strip the trailing newline (POSIX cmd
            # substitution), so block_raw joins body lines with a LITERAL
            # newline embedded in the script text below.
            j=0
            found_eof=0
            while IFS= read -r block_line; do
                if echo "$block_line" | grep -q '^EOF'; then
                    found_eof=1
                    break
                fi
                j=$((j + 1))
                multiline_cmd="${multiline_cmd}${block_line}\n"
                # real newline join for block_raw (literal break inside quotes)
                block_raw="$block_raw
${block_line}"
            done
            mods=$(echo "$cl" | sed -n 's/.*\(: --[^;]*\).*/\1/p')
            reconstructed="$trigger $cmd_start '$multiline_cmd'; : $mods"
            if [ "$found_eof" -eq 1 ]; then
                end=$((lineno + j + 1))
            else
                end=$((lineno + j))
            fi

            parse_modifiers "$reconstructed"
            action=$(extract_command "$reconstructed")
            id=$(legacy_adapter_task_id "$lineno" "$trigger")
            _emit_task "$id" "$trigger" "$action" "block" "${lineno}-${end}" "$block_raw" "$reconstructed"

            if [ "$found_eof" -eq 1 ]; then
                lineno=$((lineno + j + 1))
            else
                lineno=$((lineno + j))
            fi
            continue
        fi

        # ── 单行 ─────────────────────────────────────────────────────────────
        parse_modifiers "$cl"
        action=$(extract_command "$cl")
        id=$(legacy_adapter_task_id "$lineno" "$trigger")
        _emit_task "$id" "$trigger" "$action" "line" "$lineno" "$line" "$cl"
    done < "$config"

    trap - INT TERM HUP
    return "$rc"
}

# ── 独立运行入口 ─────────────────────────────────────────────────────────────
if [ "${LEGACY_ADAPTER_SOURCED:-0}" != "1" ] && [ "$(basename "$0" 2>/dev/null)" = "adapter.sh" ]; then
    [ $# -ge 3 ] && [ "$1" = "parse" ] || { echo "[legacy-adapter] usage: adapter.sh parse <config> <out_dir>" >&2; exit 2; }
    legacy_adapter_parse "$2" "$3"
    exit $?
fi