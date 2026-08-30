#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# derive-goldens.sh — regenerate legacy golden outputs from production code
# ═══════════════════════════════════════════════════════════════════════════
# Purpose: The goldens under tests/fixtures/legacy/expected/ are NOT
#          hand-written.  They are produced by extracting the REAL parsing
#          functions from system/bin/su-schedulerd (baseline v1.6.8) and
#          executing them against tests/fixtures/legacy/config.txt.
#
# Usage:   bash tests/fixtures/legacy/tools/derive-goldens.sh
#          (run from the repository root)
#
# Outputs: tests/fixtures/legacy/expected/{parse_modifiers,extract_command,
#          heredoc-reconstruction,run-once-now-prune,state-keys}.txt
# ═══════════════════════════════════════════════════════════════════════════
set -u

ROOT="$(cd "$(dirname "$0")/../../../../" && pwd)"
DAEMON="$ROOT/system/bin/su-schedulerd"
FIXTURE="$ROOT/tests/fixtures/legacy/config.txt"
OUT_DIR="$ROOT/tests/fixtures/legacy/expected"

[ -f "$DAEMON" ] || { echo "FATAL: daemon not found: $DAEMON" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: fixture not found: $FIXTURE" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# ── Extract the REAL functions from the daemon (lines between markers) ──────
# parse_modifiers() and extract_command() live between these two markers in
# system/bin/su-schedulerd. Sourcing them verbatim keeps goldens faithful.
# NOTE: the repo stores LF, but a Windows checkout (core.autocrlf=true) shows
# CRLF; strip \r so the host harness can source the functions either way.
FUNCS=$(sed -n '/^# 🔍 Parse task modifiers from config line/,/^# 🛡️ Single Instance Protection/p' "$DAEMON" | tr -d '\r')
eval "$FUNCS" || { echo "FATAL: could not source daemon functions" >&2; exit 1; }

# ── Helper: normalize a line exactly like the daemon loop does ──────────────
# (also strips CR left over from a Windows checkout of the fixture)
clean() { echo "$1" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//'; }

# ── Helper: daemon-style multiline body join (block_line + "\n") ────────────
# Mirrors: multiline_cmd="${multiline_cmd}${block_line}\n"

# ── 0) Loop guard note ───────────────────────────────────────────────────────
# The daemon reads config with `while IFS= read -r line <&3 || [ -n "$line" ]`
# (su-schedulerd L584/L623). The `|| [ -n "$line" ]` guard matters: the fixture
# deliberately ends WITHOUT a trailing newline, so the final line must still be
# processed. All outer loops below use the same guard.

# ── 1) parse_modifiers golden ───────────────────────────────────────────────
: > "$OUT_DIR/parse_modifiers.txt"
{
    echo "# Golden: daemon parse_modifiers() applied to every active fixture line"
    echo "# Flags correspond to the daemon global vars (v1.6.8)."
    echo "# NOTE: heredoc lines are shown raw here; see heredoc-reconstruction.txt"
    echo "#       for the reconstructed-line behaviour."
    echo ""
    while IFS= read -r line || [ -n "$line" ]; do
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac
        # Reset globals, then run the REAL function
        notify_start=0; notify_end=0; delete_after=0; interactive=0
        use_termux=0; run_once_now=0; custom_msg=""
        parse_modifiers "$cl"
        echo "LINE: $cl"
        echo "  notify_start=$notify_start notify_end=$notify_end delete_after=$delete_after"
        echo "  interactive=$interactive use_termux=$use_termux run_once_now=$run_once_now"
        echo "  custom_msg=\"$custom_msg\""
        echo ""
    done < "$FIXTURE"
} > "$OUT_DIR/parse_modifiers.txt"

# ── 2) extract_command golden ───────────────────────────────────────────────
: > "$OUT_DIR/extract_command.txt"
{
    echo "# Golden: daemon extract_command() applied to every active fixture line"
    echo ""
    while IFS= read -r line || [ -n "$line" ]; do
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac
        echo "LINE: $cl"
        echo "CMD: $(extract_command "$cl")"
        echo ""
    done < "$FIXTURE"
} > "$OUT_DIR/extract_command.txt"

# ── 3) heredoc reconstruction golden ────────────────────────────────────────
# Mirrors the daemon main loop (su-schedulerd ~L631-646) exactly:
#   if echo "$clean_line" | grep -q '<<EOF'; then
#       trigger=...; cmd_start=...
#       multiline_cmd="" ; while read block_line; do ... break on ^EOF ... done
#       clean_line="$trigger $cmd_start '$multiline_cmd'; : $(echo "$clean_line" | sed -n 's/.*\(: --[^;]*\).*/\1/p')"
#   fi
: > "$OUT_DIR/heredoc-reconstruction.txt"
{
    echo "# Golden: daemon heredoc reconstruction (config block -> single line)"
    echo ""
    while IFS= read -r line || [ -n "$line" ]; do
        orig="$line"
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac
        if echo "$cl" | grep -q '<<EOF'; then
            trigger=$(echo "$cl" | awk '{print $1}')
            cmd_start=$(echo "$cl" | sed 's/^[^ ]* //' | sed 's/ *<<EOF.*//')
            multiline_cmd=""
            while IFS= read -r block_line; do
                if echo "$block_line" | grep -q '^EOF'; then
                    break
                fi
                multiline_cmd="${multiline_cmd}${block_line}
"
            done
            mods=$(echo "$cl" | sed -n 's/.*\(: --[^;]*\).*/\1/p')
            reconstructed="$trigger $cmd_start '$multiline_cmd'; : $mods"
            echo "HEADER: $cl"
            echo "RECONSTRUCTED: $reconstructed"
            echo "PARSE_MODIFIERS(RECON):"
            notify_start=0; notify_end=0; delete_after=0; interactive=0
            use_termux=0; run_once_now=0; custom_msg=""
            parse_modifiers "$reconstructed"
            echo "  notify_start=$notify_start notify_end=$notify_end delete_after=$delete_after"
            echo "  interactive=$interactive use_termux=$use_termux run_once_now=$run_once_now"
            echo "  custom_msg=\"$custom_msg\""
            echo "EXTRACT_CMD(RECON): $(extract_command "$reconstructed")"
            echo ""
        fi
    done < "$FIXTURE"
} > "$OUT_DIR/heredoc-reconstruction.txt"

# ── 4) --run-once-now prune golden ──────────────────────────────────────────
# Mirrors the daemon prune pipeline (su-schedulerd ~L664-665):
#   new_line=$(echo "$line" | sed "s/--run-once-now//; s/  */ /g; s/ :[ \t]*$//; s/[ \t]*$//")
# The daemon prunes the RAW read line and awk-replaces that exact raw line;
# we print the same $line as ORIGINAL. Every fixture line is already trimmed
# (clean == raw), so PRUNED is identical either way — the comment documents
# the daemon behaviour for fixtures that may later carry leading/trailing gaps.
: > "$OUT_DIR/run-once-now-prune.txt"
{
    echo "# Golden: daemon --run-once-now prune of the config line"
    echo ""
    while IFS= read -r line || [ -n "$line" ]; do
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac
        notify_start=0; notify_end=0; delete_after=0; interactive=0
        use_termux=0; run_once_now=0; custom_msg=""
        parse_modifiers "$cl"
        if [ "$run_once_now" = "1" ]; then
            new_line=$(echo "$cl" | sed "s/--run-once-now//; s/  */ /g; s/ :[ 	]*$//; s/[ 	]*$//")
            echo "ORIGINAL: $cl"
            echo "PRUNED:   $new_line"
            echo ""
        fi
    done < "$FIXTURE"
} > "$OUT_DIR/run-once-now-prune.txt"

# ── 5) advanced-schedule state keys golden ──────────────────────────────────
# Mirrors should_run_advanced_schedule() key construction (v1.6.8).
# cmd_hash = md5 of the FULL clean line (third arg = command_full).
# Date parts are sampled from the CURRENT clock at derivation time, so these
# keys are structural goldens; the algorithm is what is locked.
md5of() { echo "$1" | md5sum | cut -d' ' -f1; }
: > "$OUT_DIR/state-keys.txt"
{
    echo "# Golden: structure of schedule_state.txt keys (should_run_advanced_schedule)"
    echo "# KEY FORMATS (daemon v1.6.8):"
    echo "#   weekly:   weekly_<dow>_<hhmm>_<md5(linenl)>_<YYYYMMDD>"
    echo "#   monthly:  monthly_<day>_<hhmm>_<md5(linenl)>_<YYYYMM>"
    echo "#   yearly:   yearly_<MMDD>_<hhmm>_<md5(linenl)>_<YYYY>"
    echo "#   nweekly:  nweekly_<n>_<dow>_<hhmm>_<md5(linenl)>=<week>"
    echo "#   nmonthly: nmonthly_<n>_<day>_<hhmm>_<md5(linenl)>=<month>"
    echo "# (md5 covers the whole line INCLUDING its trailing newline: echo + pipe.)"
    echo ""
    while IFS= read -r line || [ -n "$line" ]; do
        cl=$(clean "$line")
        case "$cl" in
            \#*|"") continue ;;
        esac
        trig=$(echo "$cl" | awk '{print $1}')
        case "$trig" in
            weekly:*)  dow=$(echo "$trig" | cut -d: -f2); t=$(echo "$trig" | cut -d: -f3)
                       echo "LINE: $cl"
                       echo "  KEY: weekly_${dow}_${t}_$(md5of "$cl")_YYYYMMDD" ;;
            monthly:*) dd=$(echo "$trig" | cut -d: -f2); t=$(echo "$trig" | cut -d: -f3)
                       echo "LINE: $cl"
                       echo "  KEY: monthly_${dd}_${t}_$(md5of "$cl")_YYYYMM" ;;
            yearly:*)  md=$(echo "$trig" | cut -d: -f2); t=$(echo "$trig" | cut -d: -f3)
                       echo "LINE: $cl"
                       echo "  KEY: yearly_${md}_${t}_$(md5of "$cl")_YYYY" ;;
            nweekly:*) n=$(echo "$trig" | cut -d: -f2); dow=$(echo "$trig" | cut -d: -f3); t=$(echo "$trig" | cut -d: -f4)
                       echo "LINE: $cl"
                       echo "  KEY: nweekly_${n}_${dow}_${t}_$(md5of "$cl")=<current_week>" ;;
            nmonthly:*) n=$(echo "$trig" | cut -d: -f2); dd=$(echo "$trig" | cut -d: -f3); t=$(echo "$trig" | cut -d: -f4)
                       echo "LINE: $cl"
                       echo "  KEY: nmonthly_${n}_${dd}_${t}_$(md5of "$cl")=<current_month>" ;;
            *) continue ;;
        esac
        echo ""
    done < "$FIXTURE"
} > "$OUT_DIR/state-keys.txt"

echo "✔ Goldens regenerated from $DAEMON:"
ls -1 "$OUT_DIR"