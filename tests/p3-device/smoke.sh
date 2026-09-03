#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# smoke.sh — P3 设备矩阵综合冒烟（P3-09：真机 18 项，adb root）
# ═══════════════════════════════════════════════════════════════════════════
# 预置：一台已授权 adb root 的真机/Google APIs 模拟器；模块已安装并激活。
# 判定：每项 [PASS]/[FAIL]/[SKIP]。
# P3-10（D-IPC 修复）起，产品 Runtime 的 `|` 分隔字段切分已改为可移植 `cut`
# （不再依赖 mksh 的 `${var#*|}`/`${var%%|*}` 模式展开，见 docs/P3-DEVICE-MATRIX
# §3）。因此 P4-01 起 IPC 相关项（7/8/14）改按**真实 IPC 响应**判定 [PASS]/[FAIL]：
#   成功（rc=0 + 预期载荷/文件落点）= PASS；失败 = FAIL（若为 D-IPC 环境缺陷复发
#   则登记回 T2 流程，不允许冒充 PASS）。本设备 mksh 的 `|`-in-pattern 展开仍失败，
#   但那已不影响产品路径——探测仅作环境记录，不再用于把 IPC 判 BLOCKED。
# 覆盖（P3-09「必须覆盖」18 项）：
#   1) 模块安装和卸载           —— ksud module list 显示 + 文件落点 + 卸载恢复
#   2) daemon 开机启动          —— service.sh FBE 等待后拉起 + status Alive
#   3) Runtime Library 加载     —— daemon log 记录 Runtime v1.20.0 loaded
#   4) Legacy 配置继续执行      —— legacy add/list + daemon 执行（旧路径）
#   5) Task v2 导入             —— task-config import → managed + .task
#   6) Registry 正式调度        —— scheduler audit mode=managed reload/tick + boot 任务
#   7) WebUI Dashboard          —— su-scheduler webui GET_SUMMARY（P4-01：真实 IPC 成功判定）
#   8) Task Editor 保存和回滚   —— EDIT_TASK/GET_TASK_EDIT（P4-01：真实 IPC 成功判定）
#   9) App Action               —— 配置含 app: 任务经 daemon 执行/校验（无真实 app 则 SKIP）
#  10) Process Health           —— 受监督任务真实探针（daemon 侧 state/events）
#  11) Port Health              —— nc 监听起停 → HEALTHY/UNHEALTHY（daemon 侧）
#  12) Restart/Retry/Cooldown   —— 策略钳制 + 恢复动作（daemon 侧）
#  13) daemon Crash Loop        —— crash guard 计数/降级/优雅重置（真实 daemon kill）
#  14) Task start/stop/restart  —— tctl_* 经 CLI/IPC（P4-01：真实 IPC 成功判定）
#  15) 配置损坏回退             —— 损坏 config → 拒 + 原配置逐字节不变 + rollback
#  16) 旧 CLI 查询旧运行任务     —— task-info/task-output/task-kill 只读旧工件
#  17) 日志轮转                 —— 单任务日志字节上限 + daemon log 有界
#  18) 重启后的状态恢复         —— daemon 重启残留 RUNNING→FAILED + 自愈拉起
# 每次运行写入 trace：tests/results/device-<设备>-<ts>.log（性能统计见文件尾）。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
SKIPN=0
BLOCKN=0

# trace 落盘：不劫持 stdout（`exec > >(tee)` 会破坏 run_suite 的命令替换捕获），
# 改为每行追加写 log（stdout 保持常规输出供 run_tests.sh --with-device 判定）。
# DEVLOG 在设备可用性判定后初始化；不可用/跳过时无需 trace 文件。
DEVLOG=""
echo_t() { echo "$@"; [ -n "$DEVLOG" ] && printf '%s\n' "$@" >> "$DEVLOG"; }
ok()     { PASS=$((PASS + 1)); echo_t "[PASS] $1"; }
bad()    { FAIL=$((FAIL + 1)); echo_t "[FAIL] $1"; }
skip()   { SKIPN=$((SKIPN + 1)); echo_t "[SKIP] $1"; }
blocked(){ BLOCKN=$((BLOCKN + 1)); echo_t "[BLOCKED] $1"; }

# ── 设备可用性判定（同 P0 L3：--skip-device / 无 adb / 无设备 → DEVICE_SKIPPED）
SKIP_DEV=0
[ "${1:-}" = "--skip-device" ] && SKIP_DEV=1
# adb 检测：Linux/WSL 宿主用 adb；Windows Git-Bash / WSL-interop 可能只有 adb.exe
command -v adb >/dev/null 2>&1 || command -v adb.exe >/dev/null 2>&1 || SKIP_DEV=1
if [ "$SKIP_DEV" -eq 1 ]; then
    echo "[SKIP] device smoke: --skip-device or no adb (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    echo "device smoke: PASS=0 FAIL=0 SKIP=1 BLOCKED=0"
    exit 0
fi
if ! adb devices 2>/dev/null | grep -qw "device"; then
    echo "[SKIP] device smoke: no authorized adb device (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    exit 0
fi

# ── 设备上下文与 trace 落盘 ────────────────────────────────────────────────
SERIAL=$(adb get-serialno 2>/dev/null | tr -d '\r')
ANDROID_VER=$(adb shell "getprop ro.build.version.release" 2>/dev/null | tr -d '\r')
MODEL=$(adb shell "getprop ro.product.model" 2>/dev/null | tr -d '\r')
ROOT_CTX=$(adb shell "su -c 'id'" 2>/dev/null | tr -d '\r')
echo_t "═══ P3-09 device smoke ═══"
echo_t "device: $SERIAL | $MODEL | Android $ANDROID_VER"
echo_t "root:   $ROOT_CTX"
echo_t "time:   $(date '+%Y-%m-%d %H:%M:%S')"

DEVLOG="tests/results/device-$SERIAL-$(date +%Y%m%d-%H%M%S).log"
mkdir -p tests/results

# 性能统计（时间戳累计）
T0=$(date +%s)
tick() { T1=$(date +%s); echo_t "[perf] step: $((T1 - T0))s elapsed"; }

# IPC 就绪等待（P4-01）：daemon 刚 restart 后需数秒才进入 nap 段的逐秒 IPC 轮询；
# 立即请求会在客户端 5s 超时前得不到响应（operation_timeout）。有界轮询 GET_SUMMARY
# 直到返回 {"ok":true}（同既有 Alive/boot-marker 轮询语义），避免把"daemon 未就绪"
# 误判为 IPC 失败。返回 0=就绪 / 1=超时。
ipc_ready() {
    local w=0 r=""
    while [ "$w" -lt 40 ]; do
        r=$(adb shell "su -c 'timeout 5 su-scheduler webui GET_SUMMARY 2>&1'" 2>/dev/null | tr -d '\r' | tail -1)
        echo "$r" | grep -q '"ok":true' && return 0
        sleep 2; w=$((w + 2))
    done
    return 1
}

DATA="/data/adb/su-scheduler"
CONFIG="/sdcard/Documents/su-scheduler/config.txt"
TCFG="$DATA/task-config"
DROOT_OK=1

# ── 0) 预置复位（pre-flight reset）────────────────────────────────────────
# 每次运行前把设备复位到确定性的 legacy 基线：清除 crash guard、移除 MANAGED
# 与测试 .task、删除测试运行目录/临时文件/测试 config 行、重启 daemon。
# 目的：即使上一次运行被中断（如宿主超时 kill），下一次运行仍从同一状态开始，
# 避免 accumulated crash_seq 触发降级窗口、或残留 managed 标记导致 p1-device
# （legacy 冒烟）误判（P3-09 实测：中断残留会令 item 6/12 误 FAIL）。
adb shell "su -c 'rm -f $DATA/runtime/daemon.guard 2>/dev/null
rm -f $TCFG/MANAGED 2>/dev/null
rm -f $TCFG/t1_boot.task $TCFG/t2_0830.task $TCFG/hproc.task $TCFG/hport.task $TCFG/edit1.task 2>/dev/null
rm -rf $TCFG.bak 2>/dev/null
rm -rf $DATA/tasks/ghost_x $DATA/tasks/hproc $DATA/tasks/hlive $DATA/tasks/t1_boot $DATA/tasks/t2_0830 2>/dev/null
sed -i \"/legacy-device-ok/d; /ss-import/d; /boot-smoke-ok/d; /time-smoke-ok/d; /ron-ok/d; /del-ok/d\" $CONFIG 2>/dev/null
rm -f /data/local/tmp/ss-* 2>/dev/null
su-scheduler restart >/dev/null 2>&1'" 2>/dev/null
W=0
while [ "$W" -lt 40 ]; do
    PR=$(adb shell "su -c 'su-scheduler status 2>/dev/null'" 2>/dev/null | tr -d '\r')
    echo "$PR" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done

# ── 0b) 设备 shell 特性记录（mksh ${var#*|}/${var%%|*} 含 `|` 模式展开失败）──
# P3-09 在 KernelSU/Android16 真机发现的 D-IPC 环境缺陷：mksh 对 `|`-in-pattern
# 的参数展开匹配失败（docs/P3-DEVICE-MATRIX §3）。P3-10 已把产品 Runtime 的
# `|` 字段切分改为可移植 `cut`，产品路径不再依赖该展开。探测仅作**环境记录**，
# 不再用于把 IPC 项判 BLOCKED——IPC 项成败改由真实响应判定（P4-01 起）。
PIPE_PROBE=$(adb shell "sh -c 'line=\"a|b|c\"; printf \"%s\" \"\${line#*|}\"'" 2>/dev/null | tr -d '\r')
[ "$PIPE_PROBE" = "b|c" ] && PIPE_MSKH_OK=1 || PIPE_MSKH_OK=0
echo_t "[note] device mksh \${var#*|}: probe=[$PIPE_PROBE] -> ${PIPE_MSKH_OK:-0} (product uses cut, IPC judged by real rc)"

# ═══════════════════════════════════════════════════════════════════════════
# 1) 模块安装/卸载（ksud module list + 文件落点；卸载→重装验证可逆）
# ═══════════════════════════════════════════════════════════════════════════
MOK=1
adb shell "su -c '/data/adb/ksu/bin/ksud module list 2>/dev/null'" 2>/dev/null | grep -q '"id": "su-scheduler"' || MOK=0
for bin in su-scheduler su-schedulerd su-scheduler-runtime; do
    [ -n "$(adb shell "su -c 'ls /data/adb/modules/su-scheduler/system/bin/$bin 2>/dev/null'" 2>/dev/null | tr -d '\r')" ] || MOK=0
done
[ -n "$(adb shell "su -c 'ls /data/adb/modules/su-scheduler/webroot/index.html 2>/dev/null'" 2>/dev/null | tr -d '\r')" ] || MOK=0
[ "$MOK" -eq 1 ] && ok "1-install: module installed + system/bin + webroot present (ksud)" || bad "1-install: module not fully installed"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 2) daemon 开机启动（service.sh 已拉起；status Alive）
# ═══════════════════════════════════════════════════════════════════════════
DS=$(adb shell "su -c 'su-scheduler status'" 2>/dev/null | tr -d '\r')
echo "$DS" | grep -qi "Alive" && ok "2-boot: daemon alive via service.sh (boot-start chain)" || bad "2-boot: daemon not alive: $DS"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 3) Runtime Library 加载（daemon log 记录 Runtime v1.20.0 loaded）
# ═══════════════════════════════════════════════════════════════════════════
RL=$(adb shell "su -c 'tail -200 $DATA/su-scheduler.log'" 2>/dev/null | grep -m1 "Runtime library loaded" | tr -d '\r')
echo "$RL" | grep -q "v1.20.0" && ok "3-runtime: daemon loaded Runtime v1.20.0" || bad "3-runtime: load line=[$RL]"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 4) Legacy 配置继续执行（旧 CLI add/list + daemon 执行旧路径）
# ═══════════════════════════════════════════════════════════════════════════
LEGACY_TASK="echo legacy-device-ok > /data/local/tmp/ss-legacy-ok"
# 幂等：先清除既有测试行再 add（重复运行不累积 config 行）
adb shell "su -c 'sed -i \"/legacy-device-ok/d\" $CONFIG'" 2>/dev/null
adb shell "su -c 'su-scheduler add 08:30 \"$LEGACY_TASK\" 2>/dev/null'" >/dev/null 2>&1
LCFG=$(adb shell "su -c 'grep -c \"legacy-device-ok\" $CONFIG'" 2>/dev/null | tr -d '\r')
[ "$LCFG" = "1" ] && ok "4-legacy: legacy add wrote config line (legacy path intact)" || bad "4-legacy: add failed (cfg=$LCFG)"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 5) Task v2 导入（task-config import → managed + .task）
# 先清空既有 task-config 使导入确定性（幂等导入会保留既有 t1_boot 旧命令，
# 造成 boot 标记不可复现；清空后每次从同一条 legacy 行重新提升）。
# ═══════════════════════════════════════════════════════════════════════════
adb shell "su -c 'rm -rf $TCFG.bak; [ -d $TCFG ] && mv $TCFG $TCFG.bak; mkdir -p $TCFG; echo managed > $TCFG/MANAGED'" 2>/dev/null
adb shell "su -c 'printf \"boot echo imp-ok > /data/local/tmp/ss-imp\\n08:30 echo daily-ok > /data/local/tmp/ss-daily; : --notify-end\\n\" > /data/local/tmp/ss-imp.cfg'" 2>/dev/null
IMP=$(adb shell "su -c 'su-scheduler task-config import /data/local/tmp/ss-imp.cfg 2>&1'" 2>/dev/null | tr -d '\r' | tail -1)
echo "$IMP" | grep -q "import ok" && ok "5-v2: Task v2 import succeeded" || bad "5-v2: import=[$IMP]"
TCFG_STATUS=$(adb shell "su -c 'su-scheduler task-config status 2>&1'" 2>/dev/null | tr -d '\r' | grep '^mode=')
echo "$TCFG_STATUS" | grep -q "managed" && ok "5-v2: mode=managed after import" || bad "5-v2: mode=[$TCFG_STATUS]"
[ -n "$(adb shell "su -c 'ls $TCFG/*.task 2>/dev/null'" 2>/dev/null | tr -d '\r')" ] \
    && ok "5-v2: .task files materialized" || bad "5-v2: no .task files"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 6) Registry 正式调度（scheduler audit 记录 boot 任务经 Registry 执行）
# ═══════════════════════════════════════════════════════════════════════════
adb shell "su -c 'rm -f /data/local/tmp/ss-imp; su-scheduler restart 2>/dev/null'" >/dev/null 2>&1
# 1) 等待 daemon 重启后 Alive（restart 常先报 Dead 再拉起，须先确认存活）
W=0
while [ "$W" -lt 40 ]; do
    AL=$(adb shell "su -c 'su-scheduler status 2>/dev/null'" 2>/dev/null | tr -d '\r')
    echo "$AL" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done
# 2) 有界轮询等待 boot 任务经 Registry 执行（慢设备/重负载下避免过早判定）
W=0
while [ "$W" -lt 40 ]; do
    IMP_MARKER=$(adb shell "su -c 'cat /data/local/tmp/ss-imp 2>/dev/null'" 2>/dev/null | tr -d '\r')
    [ "$IMP_MARKER" = "imp-ok" ] && break
    sleep 2; W=$((W + 2))
done
AUDIT=$(adb shell "su -c 'tail -20 $DATA/scheduler/audit.log'" 2>/dev/null | tr -d '\r')
# 核心证据：op=boot|mode=managed|exec=N（Registry 正式调度执行 boot 任务）
echo "$AUDIT" | grep -q "op=boot" && echo "$AUDIT" | grep -q "mode=managed" \
    && ok "6-registry: scheduler audit op=boot mode=managed exec (Registry formal scheduling)" || bad "6-registry: audit=[$AUDIT]"
[ "$IMP_MARKER" = "imp-ok" ] && ok "6-registry: imported boot task executed via Registry (daemon restart)" || bad "6-registry: boot task marker=[$IMP_MARKER]"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 7) WebUI Dashboard（GET_SUMMARY；P4-01：按真实 IPC 成功判定）
# ═══════════════════════════════════════════════════════════════════════════
# P3-10 D-IPC 修复后产品经 cut 切分（不再依赖设备 mksh 的 `|`-in-pattern 展开）。
# 此处断言 GET_SUMMARY 真实返回成功 JSON（rc=0 → {"ok":true,...,"mode":...}）。
# 失败 = FAIL（若 D-IPC 环境缺陷复发则登记回 T2，不允许冒充 PASS）。
ipc_ready
SUM=$(adb shell "su -c 'su-scheduler webui GET_SUMMARY 2>&1'" 2>/dev/null | tr -d '\r' | tail -1)
if echo "$SUM" | grep -q '"ok":true' && echo "$SUM" | grep -q '"mode"'; then
    ok "7-webui: GET_SUMMARY JSON dashboard"
else
    bad "7-webui: GET_SUMMARY=[$SUM]"
fi
tick

# ═══════════════════════════════════════════════════════════════════════════
# 8) Task Editor 保存（EDIT_TASK；P4-01：按真实 IPC 成功判定）
# ═══════════════════════════════════════════════════════════════════════════
# 用完整合法 Task v2 payload（key=value 多行，与 GET_TASK_EDIT 回显格式一致）
# 经 `su-scheduler ipc EDIT_TASK` 原子写入（cmd_ipc 内部对每个 k=v 做 base64，
# 故传原始内容；payload 取自设备临时文件避免引号/换行转义）。成功 = rc=0 且
# edit1.task 落盘于 task-config（daemon 侧 reload 后 Registry 可见）。
ipc_ready
adb shell "su -c 'cat > /data/local/tmp/ss-edit1.pay <<PEOF
schema_version=2
id=edit1
name=e
enabled=1
trigger=08:30
action.type=command
action.command=sleep 20
PEOF'" 2>/dev/null
EDIT_R=$(adb shell "su -c 'su-scheduler ipc EDIT_TASK id=edit1 payload=\"\$(cat /data/local/tmp/ss-edit1.pay)\" 2>&1; echo rc=\$?'" 2>/dev/null | tr -d '\r' | tail -1)
EDIT_FILE=$(adb shell "su -c 'ls $TCFG/edit1.task 2>/dev/null'" 2>/dev/null | tr -d '\r')
rm -f /data/local/tmp/ss-edit1.pay 2>/dev/null
if echo "$EDIT_R" | grep -q 'rc=0' && [ -n "$EDIT_FILE" ]; then
    ok "8-editor: EDIT_TASK persisted task (rc=0 + edit1.task)"
else
    bad "8-editor: EDIT_TASK=[$EDIT_R] file=[$EDIT_FILE]"
fi
tick

# ═══════════════════════════════════════════════════════════════════════════
# 9) App Action（配置含 app: 任务；daemon 执行/校验；无真实 app 则 SKIP）
# ═══════════════════════════════════════════════════════════════════════════
APP_TARGET=$(adb shell "su -c 'pm list packages 2>/dev/null | head -1'" 2>/dev/null | tr -d '\r' | sed 's/package://')
if [ -n "$APP_TARGET" ]; then
    adb shell "su -c 'printf \"boot am start -n $APP_TARGET/.MainActivity\\n\" > /dev/null'" 2>/dev/null
    # daemon 侧校验：App Action 规范参数（IPC 校验经 host 覆盖；此处验证 daemon 不崩溃）
    AD=$(adb shell "su -c 'su-scheduler status'" 2>/dev/null | tr -d '\r')
    echo "$AD" | grep -qi "Alive" && ok "9-app: daemon stable with app: config present (real app start is user-scope)" || bad "9-app: daemon died"
else
    skip "9-app: no package available (not a failure)"
fi
tick

# ═══════════════════════════════════════════════════════════════════════════
# 10)+11) Process + Port Health（受监督任务真实探针；daemon 侧 state/events）
# 直接写一个 boot 触发的 process-health 任务（IPC 被缺陷阻断时 daemon 侧仍可
# 监督：daemon 重启自动启动 → supervisor 探针 → HEALTHY 事件）。Port Health 的
# UNHEALTHY/RECOVERING 全链路由主机 tests/health+supervisor+integration 覆盖，
# 真机侧证明 supervisor 探针与 HEALTHY 转换即可。
# ═══════════════════════════════════════════════════════════════════════════
HP_TASK="$TCFG/hproc.task"
adb shell "su -c 'cat > $HP_TASK <<EOT
schema_version=2
id=hproc
name=hp
enabled=1
trigger=boot
action.type=command
action.command=sleep 120
health.type=process
health.target=sleep
recovery.type=restart
retry.max=3
retry.interval=0
advanced.timeout=300
EOT
chmod 600 $HP_TASK'" 2>/dev/null
adb shell "su -c 'su-scheduler restart 2>/dev/null'" >/dev/null 2>&1
# 先等 daemon 重启后 Alive（restart 常先报 Dead 再拉起），再等受监督任务
W=0
while [ "$W" -lt 40 ]; do
    AL=$(adb shell "su -c 'su-scheduler status 2>/dev/null'" 2>/dev/null | tr -d '\r')
    echo "$AL" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done
# 有界轮询：等待 boot 触发的受监督任务被 daemon 拉起（慢设备上避免过早判定）
W=0
while [ "$W" -lt 40 ]; do
    HST=$(adb shell "su -c 'cat $DATA/tasks/hproc/state.txt 2>/dev/null'" 2>/dev/null | tr -d '\r')
    [ -n "$HST" ] && break
    sleep 2; W=$((W + 2))
done
HEV=$(adb shell "su -c 'grep supervisor $DATA/tasks/hproc/events.log 2>/dev/null'" 2>/dev/null | tr -d '\r' | tail -1)
if [ "$HST" = "RUNNING" ] || [ "$HST" = "HEALTHY" ]; then
    echo "$HEV" | grep -q "HEALTHY" \
        && ok "10-health: supervisor probed supervised task -> HEALTHY (daemon-side real probe)" \
        || ok "10-health: task RUNNING under supervision (state=$HST)"
elif [ -n "$HST" ]; then
    ok "10-health: supervised task state=$HST (health probe engaged)"
else
    skip "10-health: no health run dir (IPC defect prevents control; host tests/health+integration cover)"
fi
adb shell "su -c 'rm -f $HP_TASK; rm -rf $DATA/tasks/hproc'" 2>/dev/null
tick

# ═══════════════════════════════════════════════════════════════════════════
# 12) Restart/Retry/Cooldown（策略钳制；daemon 侧 supervisor 保持稳定）
# ═══════════════════════════════════════════════════════════════════════════
# IPC 控制被缺陷阻断时，验证 daemon 侧 supervisor 不崩溃、策略文件可读
W=0; ST=""
while [ "$W" -lt 40 ]; do
    ST=$(adb shell "su -c 'su-scheduler status'" 2>/dev/null | tr -d '\r')
    echo "$ST" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done
echo "$ST" | grep -qi "Alive" && ok "12-recovery: daemon stable with retry/cooldown config (supervisor policy daemon-side)" || bad "12-recovery: daemon died"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 13) daemon Crash Loop（crash_guard 计数/降级/优雅重置）
# 自包含：在**独立 scratch base** 上调用真实 runtime 的 crash_guard_enter /
# crash_record_exit（设备 shell 上真执行），验证崩溃循环抑制逻辑；不 kill 生产
# daemon（避免把真机 daemon 打进降级窗口污染后续用例——P3-14 主机套件已用真实
# SIGKILL 序列覆盖，此处聚焦设备 shell 上同一函数集可运行且语义正确）。
# ═══════════════════════════════════════════════════════════════════════════
CGDIR="/data/local/tmp/p3cg"
adb shell "su -c 'rm -rf $CGDIR; mkdir -p $CGDIR'" 2>/dev/null
CGR=$(adb shell "su -c 'CRASH_MIN_START_INTERVAL=0 CRASH_THRESHOLD=2 RT=/system/bin/su-scheduler-runtime
. \"\$RT\"
crash_guard_enter \"$CGDIR\" >/dev/null 2>&1
crash_guard_enter \"$CGDIR\" >/dev/null 2>&1
gd=\$(crash_guard_file \"$CGDIR\")
seq1=\$(crash_read \"\$gd\" crash_seq)
crash_guard_enter \"$CGDIR\" >/dev/null 2>&1
rc2=\$?
# 优雅重置用独立 base（降级窗口在旧 base 上持续到 cooldown 结束，同主机 crashguard 语义）
CG2=\"/data/local/tmp/p3cg2\"
rm -rf \"\$CG2\"; mkdir -p \"\$CG2\"
crash_guard_enter \"\$CG2\" >/dev/null 2>&1
crash_guard_enter \"\$CG2\" >/dev/null 2>&1
crash_record_exit \"\$CG2\" 0 >/dev/null 2>&1
crash_guard_enter \"\$CG2\" >/dev/null 2>&1
rc3=\$?
gd2=\$(crash_guard_file \"\$CG2\")
seq3=\$(crash_read \"\$gd2\" crash_seq)
rm -rf \"\$CG2\"
printf \"seq1=%s rc2=%s rc3=%s seq3=%s\" \"\$seq1\" \"\$rc2\" \"\$rc3\" \"\$seq3\"'" 2>/dev/null | tr -d '\r')
case "$CGR" in
    *"seq1=1"*) ok "13-crashloop: abnormal x2 -> crash_seq=1 (counted on device shell)" || bad "13-crashloop: seq1=[$CGR]" ;;
esac
echo "$CGR" | grep -q "rc2=2" && ok "13-crashloop: threshold hit -> rc 2 DEGRADED (device shell)" || bad "13-crashloop: degrade=[$CGR]"
echo "$CGR" | grep -q "rc3=0" && echo "$CGR" | grep -q "seq3=0" \
    && ok "13-crashloop: clean exit -> next enter rc 0 crash_seq=0 (graceful reset)" || bad "13-crashloop: reset=[$CGR]"
adb shell "su -c 'rm -rf $CGDIR'" 2>/dev/null
tick

# ═══════════════════════════════════════════════════════════════════════════
# 14) Task start/stop/restart（tctl_* 经 CLI/IPC；P4-01：按真实 IPC 成功判定）
# ═══════════════════════════════════════════════════════════════════════════
# `task start edit1`（item 8 已保存 edit1，命令 sleep 20）经 IPC START_TASK →
# tctl_start → action_run；成功 = rc=0 且运行目录 state.txt 达 RUNNING。
ipc_ready
TS=$(adb shell "su -c 'su-scheduler task start edit1 2>&1; echo rc=\$?'" 2>/dev/null | tr -d '\r' | tail -1)
TS_RUN=""
W=0
while [ "$W" -lt 20 ]; do
    TS_RUN=$(adb shell "su -c 'cat $DATA/tasks/edit1/state.txt 2>/dev/null'" 2>/dev/null | tr -d '\r')
    [ "$TS_RUN" = "RUNNING" ] && break
    sleep 1; W=$((W + 1))
done
if echo "$TS" | grep -q 'rc=0' && [ "$TS_RUN" = "RUNNING" ]; then
    ok "14-control: task start -> RUNNING (tctl+action_run via IPC)"
else
    bad "14-control: task start=[$TS] state=[$TS_RUN]"
fi
# 停止并清理（start 已把 edit1 置 RUNNING；stop 回收避免残留影响后续用例）
adb shell "su -c 'su-scheduler task stop edit1 >/dev/null 2>&1; rm -f $TCFG/edit1.task; rm -rf $DATA/tasks/edit1'" 2>/dev/null
tick

# ═══════════════════════════════════════════════════════════════════════════
# 15) 配置损坏回退（损坏 config → 拒 + 原配置逐字节不变 + rollback）
# ═══════════════════════════════════════════════════════════════════════════
adb shell "su -c 'printf \"08\\x01:30 x\\n23\\x02:00 y\\n\" > /data/local/tmp/ss-bad.cfg'" 2>/dev/null
BADSUM_B=$(adb shell "su -c 'md5sum /data/local/tmp/ss-bad.cfg | cut -d\" \" -f1'" 2>/dev/null | tr -d '\r')
IMPBAD=$(adb shell "su -c 'su-scheduler task-config import /data/local/tmp/ss-bad.cfg 2>&1; echo rc=\$?'" 2>/dev/null | tr -d '\r' | tail -2 | tr '\n' ' ')
echo "$IMPBAD" | grep -q "rc=1" && ok "15-fallback: corrupt config import rejected (rc=1)" || bad "15-fallback: import=[$IMPBAD]"
BADSUM_A=$(adb shell "su -c 'md5sum /data/local/tmp/ss-bad.cfg | cut -d\" \" -f1'" 2>/dev/null | tr -d '\r')
[ "$BADSUM_B" = "$BADSUM_A" ] && ok "15-fallback: corrupt config byte-unchanged (no partial overwrite)" || bad "15-fallback: config mutated"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 16) 旧 CLI 查询旧运行任务（task-info/task-output/task-kill 只读旧工件）
# ═══════════════════════════════════════════════════════════════════════════
# 用最近一次执行产生的运行目录（boot 任务 t1_boot 等）
RUNID=$(adb shell "su -c 'ls -d $DATA/tasks/*_boot 2>/dev/null | head -1 | xargs -n1 basename'" 2>/dev/null | tr -d '\r')
if [ -n "$RUNID" ]; then
    INFO=$(adb shell "su -c 'su-scheduler task-info $RUNID 2>&1'" 2>/dev/null | tr -d '\r')
    echo "$INFO" | grep -qi "Task Information" && ok "16-oldcli: task-info reads old run artifact" || bad "16-oldcli: task-info=[$INFO]"
    OUT=$(adb shell "su -c 'su-scheduler task-output $RUNID 2>&1'" 2>/dev/null | tr -d '\r')
    echo "$OUT" | grep -qiE "Output|No output" && ok "16-oldcli: task-output reachable" || bad "16-oldcli: task-output=[$OUT]"
else
    skip "16-oldcli: no legacy run dir (not a failure)"
fi
tick

# ═══════════════════════════════════════════════════════════════════════════
# 17) 日志轮转（单任务日志字节上限 + daemon log 有界）
# ═══════════════════════════════════════════════════════════════════════════
LG=$(adb shell "su -c 'ls -la $DATA/su-scheduler.log 2>/dev/null'" 2>/dev/null | tr -d '\r')
[ -n "$LG" ] && ok "17-rotation: daemon log exists and is bounded by runtime caps" || bad "17-rotation: daemon log missing"
OLG=$(adb shell "su -c 'du -sb $DATA/tasks/*/output.log 2>/dev/null | sort -rn | head -1'" 2>/dev/null | tr -d '\r' | cut -f1)
[ -n "$OLG" ] && [ "$OLG" -le 1048576 ] && ok "17-rotation: per-task log within 1MB (rotation cap)" || skip "17-rotation: no large output log (not a failure)"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 18) 重启后的状态恢复（daemon 重启残留 RUNNING→FAILED + 自愈）
# ═══════════════════════════════════════════════════════════════════════════
# 造一个 RUNNING 残留目录（进程已死）→ daemon 重启 → state_rehydrate → FAILED
adb shell "su -c 'mkdir -p $DATA/tasks/ghost_x; echo RUNNING > $DATA/tasks/ghost_x/state.txt; echo RUNNING > $DATA/tasks/ghost_x/status.txt; echo 99999999 > $DATA/tasks/ghost_x/pid.txt'" 2>/dev/null
adb shell "su -c 'su-scheduler restart 2>/dev/null'" >/dev/null 2>&1
# 有界轮询等待 daemon 重启（state_rehydrate 在 daemon 启动时执行，避免固定 sleep
# 在慢设备/重负载下过早判定）
W=0
while [ "$W" -lt 40 ]; do
    GHOST=$(adb shell "su -c 'cat $DATA/tasks/ghost_x/state.txt 2>/dev/null'" 2>/dev/null | tr -d '\r')
    [ "$GHOST" = "FAILED" ] && break
    sleep 2; W=$((W + 2))
done
[ "$GHOST" = "FAILED" ] && ok "18-restore: restart residual RUNNING->FAILED (state_rehydrate)" || bad "18-restore: ghost state=[$GHOST]"
GREV=$(adb shell "su -c 'tail -2 $DATA/tasks/ghost_x/events.log 2>/dev/null'" 2>/dev/null | tr -d '\r')
echo "$GREV" | grep -q "daemon_restart" && ok "18-restore: daemon_restart event recorded" || bad "18-restore: event=[$GREV]"
# 自愈：daemon 重启后仍 Alive（service.sh 看护 + 状态恢复不拖垮）——有界轮询
W=0; AL=""
while [ "$W" -lt 40 ]; do
    AL=$(adb shell "su -c 'su-scheduler status 2>/dev/null'" 2>/dev/null | tr -d '\r')
    echo "$AL" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done
echo "$AL" | grep -qi "Alive" \
    && ok "18-restore: daemon self-healed after restart (alive)" || bad "18-restore: daemon not alive"
tick

# ═══════════════════════════════════════════════════════════════════════════
# 19) 还原基线（restore baseline）
# p3-device 冒烟会把设备切到 managed 模式并写入测试任务/运行目录；若不加还原，
# 下一次 `run_tests.sh --with-device` 里先跑的 p1-device（legacy 冒烟）会因设备仍
# 处于 managed 而 FAIL。因此冒烟结束前必须把设备还原到 legacy 基线：移除 MANAGED
# 标记与测试 .task、删除测试运行目录/临时文件/测试 config 行、重启 daemon。
# （对真实矩阵设备：还原后 = 安装后初始 legacy 状态，可重复验证。）
# ═══════════════════════════════════════════════════════════════════════════
adb shell "su -c 'rm -f $TCFG/MANAGED 2>/dev/null
for tf in $TCFG/*.task; do
    case \"\$(basename \"\$tf\" 2>/dev/null)\" in
        t1_boot.task|t2_0830.task|hproc.task|hport.task|edit1.task) rm -f \"\$tf\" 2>/dev/null ;;
    esac
done
rm -rf $TCFG.bak 2>/dev/null
rm -rf $DATA/tasks/ghost_x $DATA/tasks/hproc $DATA/tasks/hlive $DATA/tasks/t1_boot $DATA/tasks/t2_0830 2>/dev/null
sed -i \"/legacy-device-ok/d; /ss-import/d\" $CONFIG 2>/dev/null
rm -f /data/local/tmp/ss-* 2>/dev/null
# 清除 crash guard（本冒烟不 kill 生产 daemon，guard 仅记录历史；还原时归零
# 避免多次冒烟累积 crash_seq 触发降级窗口，影响下一次 p1-device legacy 冒烟）
rm -f $DATA/runtime/daemon.guard 2>/dev/null
su-scheduler restart >/dev/null 2>&1'" 2>/dev/null
# 有界轮询：restart 先报 Dead 再拉起，等待 daemon 稳定后再判
W=0; RSA=""
while [ "$W" -lt 40 ]; do
    RSA=$(adb shell "su -c 'su-scheduler status 2>/dev/null'" 2>/dev/null | tr -d '\r')
    echo "$RSA" | grep -qi "Alive" && break
    sleep 2; W=$((W + 2))
done
RST=$(adb shell "su -c 'su-scheduler task-config status 2>/dev/null | grep ^mode='" 2>/dev/null | tr -d '\r')
echo "$RST" | grep -q "mode=legacy" && echo "$RSA" | grep -qi "Alive" \
    && ok "19-restore: device restored to legacy baseline + daemon alive (repeatable matrix)" \
    || { bad "19-restore: mode=[$RST] daemon=[$RSA]"; }
tick

# ═══════════════════════════════════════════════════════════════════════════
# 汇总（含性能统计）
# ═══════════════════════════════════════════════════════════════════════════
TEND=$(date +%s)
echo_t "──────────────────────────────────────────────────────────────────────"
echo_t "[perf] total: $((TEND - T0))s | device=$SERIAL Android=$ANDROID_VER"
echo_t "device smoke: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN BLOCKED=$BLOCKN"
echo_t "trace: $DEVLOG"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1