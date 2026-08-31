#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# harness.sh — CLI 行为测试 harness（P0 L2：R-08..R-13 锁定层）
# ═══════════════════════════════════════════════════════════════════════════
# 机制（与 tests/fixtures/legacy/tools/derive-goldens.sh 同源思路，AGENTS
# §4.2「L2 测试 shim」授权）：source 生产 system/bin/su-scheduler 的**真实
# 函数**——剥离主分发器尾部（# 🚦 Main Dispatcher 起）、中和环境覆盖
# （unset $(env …) / export PATH=…，避免污染宿主），LF 归一后 eval；
# 在隔离临时目录下逐命令执行并断言（CLI_OUT/CLI_RC 捕获）。
# 用法：
#   . ./harness.sh
#   CLI_TMP=<临时目录> cli_run cmd_log -n 5    # 捕获 stdout+stderr 到
#                                             # CLI_OUT，退出码到 CLI_RC
# ═══════════════════════════════════════════════════════════════════════════
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLI_SCRIPT="$ROOT/system/bin/su-scheduler"

# 生产脚本 → 可 source 的函数体（LF 归一 + 去环境覆盖 + 去主分发器）
cli_src() {
    sed '/^# 🚦 Main Dispatcher/,$d' "$CLI_SCRIPT" \
      | tr -d '\r' \
      | sed '/^unset /d; /^export PATH=/d'
}

CLI_OUT=""
CLI_RC=0

# 在隔离子 shell 中执行一个 CLI 函数；stdout+stderr 收进 CLI_OUT，
# 退出码收进 CLI_RC（函数内 `exit` 仅退出该子 shell，不殃及测试进程）。
cli_run() {
    local tmp="${CLI_TMP:?CLI_TMP must be set before cli_run}"
    mkdir -p "$tmp/tasks" "$tmp/shells"
    CLI_OUT=$( {
        # 生产脚本不使用 `set -u`（且函数引用 $1 无守卫）；测试脚本的
        # `set -u` 会被子 shell 继承并使无参调用（如 cmd_log）因 $1 未绑定
        # 而崩溃——此处复位，与生产语义一致。
        set +u
        # 先 source 生产函数体，**再**覆盖路径变量——生产脚本的顶层赋值
        # （CONFIG_FILE=/sdcard/... 等）在 eval 时生效，覆盖必须在其后，
        # 否则会被重新打回真实路径（P2-01 实测教训，见 harness 头注释外）。
        eval "$(cli_src)"
        CONFIG_FILE="$tmp/config.txt"
        LOG_FILE="$tmp/su-scheduler.log"
        TASKS_DIR="$tmp/tasks"
        SHELLS_DIR="$tmp/shells"
        "$@"
    } 2>&1 )
    CLI_RC=$?
}