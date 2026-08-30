#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# derive-task-fixtures.sh — regenerate Task Schema v2 fixture samples
# ═══════════════════════════════════════════════════════════════════════════
# Purpose: P1-02 acceptance proof — "every legacy config line converts to a
#          legal internal Task".  The samples under
#          tests/fixtures/task-v2/samples/ are NOT hand-written: they are
#          produced from the REAL parse_modifiers/extract_command functions
#          of system/bin/su-schedulerd (baseline v1.6.8), applied to the
#          P1-01 legacy fixture tests/fixtures/legacy/config.txt.
#
# Usage:   bash tests/fixtures/task-v2/tools/derive-task-fixtures.sh
#          (run from the repository root)
#
# Outputs: one .task file per active legacy task line/block in
#          tests/fixtures/task-v2/samples/
# ═══════════════════════════════════════════════════════════════════════════
set -u

ROOT="$(cd "$(dirname "$0")/../../../../" && pwd)"
DAEMON="$ROOT/system/bin/su-schedulerd"
FIXTURE="$ROOT/tests/fixtures/legacy/config.txt"
OUT_DIR="$ROOT/tests/fixtures/task-v2/samples"

[ -f "$DAEMON" ] || { echo "FATAL: daemon not found: $DAEMON" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: legacy fixture not found: $FIXTURE" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# ── Source the REAL parsing functions (same provenance as P1-01 goldens) ────
FUNCS=$(sed -n '/^# 🔍 Parse task modifiers from config line/,/^# 🛡️ Single Instance Protection/p' "$DAEMON" | tr -d '\r')
eval "$FUNCS" || { echo "FATAL: could not source daemon functions" >&2; exit 1; }

# ── Helpers ─────────────────────────────────────────────────────────────────
# clean: trim like the daemon loop does (and drop CR from a Windows checkout)
clean() { echo "$1" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//'; }
# norm: legacy trigger -> id suffix (colons removed, like daemon L650)
norm()  { echo "$1" | sed 's/://g'; }

# esc: escape for key=value storage — backslash -> \\, real LF -> literal \n
esc() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//$'\n'/\\n}"
    printf '%s' "$v"
}

# first word of the command (default name derivation)
first_word() { echo "$1" | awk '{print $1}'; }

reset_flags() {
    notify_start=0; notify_end=0; delete_after=0; interactive=0
    use_termux=0; run_once_now=0; custom_msg=""
}

# ═══════════════════════════════════════════════════════════════════════════
# emit_task <id> <trigger> <action> <source_type> <source_line> <source_raw>
# Caller must have run reset_flags + parse_modifiers just before.
# ═══════════════════════════════════════════════════════════════════════════
emit_task() {
    local id="$1" trigger="$2" action="$3" stype="$4" sline="$5" sraw="$6"
    local boot_flag=0 name
    echo "$action" | grep -q -- '--boot' && boot_flag=1
    name=$(first_word "$action"); [ -n "$name" ] || name="task"
    name="${name:0:40}"
    local f="$OUT_DIR/$id.task"
    {
        echo "# Su Scheduler internal task object — schema_version=2"
        echo "# Provenance: tests/fixtures/legacy/config.txt (${stype} ${sline})"
        echo "# Converted with the REAL parse_modifiers/extract_command of su-schedulerd v1.6.8"
        echo "# Legacy execution quirks preserved verbatim (docs/phase-1-baseline.md §6)"
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
        echo "runtime.state=idle"
        echo "runtime.run_count=0"
        echo "runtime.last_status="
        echo "runtime.last_exit="
        echo "runtime.last_start="
        echo "runtime.last_end="
        echo "runtime.pid="
    } > "$f"
    echo "✔ $id.task  (${stype} ${sline}, trigger='$trigger')"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main scan — mirrors the daemon read pattern: `|| [ -n "$line" ]` guard for a
# final line without trailing newline, and heredoc blocks consumed on the
# shared fd (su-schedulerd L584/L623/L631-646).  `lineno` tracks the FILE line
# number; the inner heredoc loop consumes lines the outer loop never sees, so
# lineno is re-aligned at the end of each heredoc block.
# ═══════════════════════════════════════════════════════════════════════════
rm -f "$OUT_DIR"/*.task
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    cl=$(clean "$line")
    case "$cl" in
        \#*|"") continue ;;
    esac

    # ── heredoc block ────────────────────────────────────────────────────────
    # Daemon ALWAYS reconstructs a <<EOF line (even with an empty body) using
    # literal \n joins (L641) and re-emits `; : <mods>` — see P1-01 goldens.
    if echo "$cl" | grep -q '<<EOF'; then
        trigger=$(echo "$cl" | awk '{print $1}')
        cmd_start=$(echo "$cl" | sed 's/^[^ ]* //' | sed 's/ *<<EOF.*//')
        multiline_cmd=""
        block_raw="$cl"
        j=0
        found_eof=0
        while IFS= read -r block_line; do
            if echo "$block_line" | grep -q '^EOF'; then
                found_eof=1
                break
            fi
            j=$((j + 1))
            # Daemon joins the multiline BODY with LITERAL \n (L641) — keep that
            # for reconstruction fidelity (it ends up in action.command).
            multiline_cmd="${multiline_cmd}${block_line}\n"
            # source.raw, however, records the ORIGINAL config layout: use REAL
            # newlines between block lines; esc() will encode them as \n.
            block_raw="${block_raw}"$'\n'"${block_line}"
        done

        mods=$(echo "$cl" | sed -n 's/.*\(: --[^;]*\).*/\1/p')
        reconstructed="$trigger $cmd_start '$multiline_cmd'; : $mods"

        if [ "$found_eof" -eq 1 ]; then
            end=$((lineno + j + 1))     # header .. EOF line
        else
            end=$((lineno + j))         # unterminated block: .. last consumed line
        fi

        reset_flags
        parse_modifiers "$reconstructed"
        action=$(extract_command "$reconstructed")
        id="t${lineno}_$(norm "$trigger")"
        emit_task "$id" "$trigger" "$action" "block" "${lineno}-${end}" "$block_raw"

        # Re-align lineno: inner loop consumed j body lines + 1 terminator
        # (or j lines with no terminator) that the outer loop will never see.
        if [ "$found_eof" -eq 1 ]; then
            lineno=$((lineno + j + 1))
        else
            lineno=$((lineno + j))
        fi
        continue
    fi

    # ── single line ─────────────────────────────────────────────────────────
    trigger=$(echo "$cl" | awk '{print $1}')
    reset_flags
    parse_modifiers "$cl"
    action=$(extract_command "$cl")
    id="t${lineno}_$(norm "$trigger")"
    emit_task "$id" "$trigger" "$action" "line" "$lineno" "$line"
done < "$FIXTURE"

echo "── Done. Samples written to $OUT_DIR"
echo "task files: $(ls -1 "$OUT_DIR" | wc -l)"