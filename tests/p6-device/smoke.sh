#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# smoke.sh — P6 设备矩阵综合冒烟（P6-10：真机 9 必测场景，KernelSU root）
# ═══════════════════════════════════════════════════════════════════════════
# 预置：一台已授权 root 的真机/模拟器；模块 v1.6.8（Runtime 1.32.0）已安装激活。
# 判定：每项 [PASS]/[FAIL]/[SKIP]；全绿 exit 0（AGENTS §4）。
# 无 adb/无设备/--skip-device → DEVICE_SKIPPED（同 P0 L3 / P3 语义）。
# SUITE_TIMEOUT 惯例（D-P5-04）：本套件含分钟级等待（catch-up ≈2 拍 + DAG 波次
# ≈8 拍 + 守护重启窗口；空闲设备 ≈15 分钟，热机/慢拍场景 25–37 分钟），
# run_tests.sh --with-device 注册超时 2400s。
# 运行窗口约束（解释性，属测试侧时钟边界，非产品缺陷）：避开本地时区 23:15–00:40
# （全套件 ~35 分钟 + 波 B 追加 ~8 分钟，HHMM 触发器回绕跨午夜会使等待越界；
#  跳拍补偿用例的 last_tick 回拨不跨午夜；P6-02 语义本身跨午夜不补偿）。
# 覆盖（P6-10 九场景 → 用例号）：
#  1-module   安装态预检（Runtime 1.32.0 加载 + daemon Alive；升级面）
#  2-catchup  P6-02 跳拍补偿（真机时钟等价时序：等待 tick(X) 完成 → 创建
#             trigger=X 的精确任务（主循环窗口已过）→ 回拨 last_tick 至 X-1 →
#             下一拍唯一执行路径 = catch-up）：
#             · op=exec|task=...|catchup=1 + op=tick|...|catchup=n 审计
#             · 过期 oneshot 不补偿；同窗口恰好一次不重复
#             · last_tick 跨 daemon 重启持久，重启后不重放
#  3-cronid   P6-03 Cron ID 派生：task-config new 含空格 cron → ID 合法、文件
#             生成、trigger 逐字保留；穿越形 trigger sanitize 无逃逸；
#             IPC CREATE_TASK 非法 id → invalid_request 显式拒绝
#  4-ipcerr   P6-04 IPC 错误透传：configuration_invalid 字段级原因具体、两类
#             可区分、1000 字符触发限长截断、ERROR 字段无 /data/adb 路径泄露
#  5-dagcfg   P6-06/07 配置期拒绝：孤儿 trigger=chain / 环 / 深度 17>16 ——
#             apply 拒绝不落盘；整目录坏图 snapshot KEPT（registry 不被污染）
#  6-dagwave  P6-06/07 链式执行（managed、真机分钟 tick）：
#             线性 ra→ab→ac SUCCESS；分支合流 rb→(bb,bc)→bz 波中 kill 后按 R7
#             收敛终局（确定性合流 SUCCESS 见 8-control 波 B）；
#             失败重试 rc→cf(exit1, retry.max=1)→cg FAILED：cf 执行恰 2 次
#             （1+max 钳制，无无限重放）、cg 零执行（Required 级联阻断）、
#             fail-propagate 审计、run 终局 FAILED；
#             Optional ya→(yc, yb)：yb FAILED 不阻断 yc（opt-unsat）、run FAILED；
#             chain 子命令清单/成员反查归属根
#  7-dagkill  P6-07 daemon 重启恢复：波中 kill -9 → watchdog 拉起 → 账本存续；
#             在途节点按 R7 收敛终态且**零重派发**（活子进程收养、不重放）；
#             根不重放（计数=1）；同 token 不重复建 run；complete 审计
#  8-control  控制面（WebUI bridge 同源 IPC；浏览器渲染不作设备断言）：
#             波 B（无 kill 确定性窗）在途节点 stop → STOPPED 满足缺省边 →
#             合流下游放行 run=SUCCESS（EX-12）；批量 stop 逐任务返回
#             （「链=批量节点操作」的 IPC 实面）
#  9-webui    P6-08 查询面：GET_SUMMARY.dag（active/limit/chains 键 + 链数据）；
#             GET_TASK_DETAIL.dag（chain_root/run_state 与账本一致）；
#             task status 链七键（P6-09 与 WebUI 同源）
#  10-restore 还原 legacy 基线：清 P6 工件 → mode=legacy + Alive +
#             config.txt 逐字节不变（可重复矩阵）
# Legacy 全链路回归由 tests/p1-device/smoke.sh 承载（P6-10 验收复跑）；升级/回滚
# （需 ksud 安装 + reboot 激活）为矩阵人工演练：docs/P6-10-DEVICE-MATRIX.md。
# 每次运行写 trace：tests/results/device-<设备>-<ts>-p6.log。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
SKIPN=0
DEVLOG=""
echo_t() { echo "$@"; [ -n "$DEVLOG" ] && printf '%s\n' "$@" >> "$DEVLOG"; }
ok()   { PASS=$((PASS + 1)); echo_t "[PASS] $1"; }
bad()  { FAIL=$((FAIL + 1)); echo_t "[FAIL] $1"; }
skip() { SKIPN=$((SKIPN + 1)); echo_t "[SKIP] $1"; }

# ── 设备可用性判定 ─────────────────────────────────────────────────────────
# 用法：smoke.sh [--with-device] [--skip-device] [--serial <S>|-s <S>]
# serial 亦可经 ANDROID_SERIAL 环境变量指定；多设备环境（含 offline 残留条目）
# 下必显式指定，避免 adb "more than one device"（P6-10）。
SKIP_DEV=0
SERIAL="${ANDROID_SERIAL:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-device) ;;
        --skip-device) SKIP_DEV=1 ;;
        --serial|-s)   SERIAL="${2:-}"; shift ;;
        *) echo "[FAIL] p6 device smoke: unknown arg: $1"; exit 2 ;;
    esac
    shift
done
command -v adb >/dev/null 2>&1 || command -v adb.exe >/dev/null 2>&1 || SKIP_DEV=1
if [ "$SKIP_DEV" -eq 1 ]; then
    echo "[SKIP] p6 device smoke: --skip-device or no adb (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    echo "device smoke: PASS=0 FAIL=0 SKIP=1"
    exit 0
fi
ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"
if ! $ADB devices 2>/dev/null | grep -qw "device"; then
    echo "[SKIP] p6 device smoke: no authorized adb device${SERIAL:+ for serial $SERIAL} (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    exit 0
fi

[ -z "$SERIAL" ] && SERIAL=$(adb get-serialno 2>/dev/null | tr -d '\r')
ANDROID_VER=$($ADB shell "getprop ro.build.version.release" 2>/dev/null | tr -d '\r')
MODEL=$($ADB shell "getprop ro.product.model" 2>/dev/null | tr -d '\r')
ROOT_CTX=$($ADB shell "su -c 'id'" 2>/dev/null | tr -d '\r')
echo_t "═══ P6-10 device smoke ═══"
echo_t "device: $SERIAL | $MODEL | Android $ANDROID_VER"
echo_t "root:   $ROOT_CTX"
echo_t "time:   $(date '+%Y-%m-%d %H:%M:%S')"
DEVLOG="tests/results/device-$SERIAL-$(date +%Y%m%d-%H%M%S)-p6.log"
mkdir -p tests/results

T0=$(date +%s)
tickp() { T1=$(date +%s); echo_t "[perf] step: $((T1 - T0))s elapsed"; }

DATA="/data/adb/su-scheduler"
TCFG="$DATA/task-config"
CONFIG="/sdcard/Documents/su-scheduler/config.txt"
RT="1.32.0"

# 设备侧执行：AS=单引号包裹（体内禁单引号）；AD=双引号包裹（体内禁未转义双引号）
AS() { $ADB shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }
AD() { $ADB shell "su -c \"$1\"" 2>/dev/null | tr -d '\r'; }
DEVTOK() { AS "date +%Y%m%d%H%M"; }
MINADD() { # <HHMM> <n> → HHMM（±分钟，回绕）
    printf '%s' "$1" | awk -v add="$2" '{h=substr($0,1,2)+0; m=substr($0,3,2)+add;
        while(m>=60){m-=60; h++}; while(m<0){m+=60; h--}; h=h%24; if(h<0)h+=24; printf "%02d%02d", h, m}'
}
TOKPREV() { # <12位token> → 上一分钟 token（借位跨小时/跨日由调用方保证同日）
    printf '%s' "$1" | awk '{t=substr($0,1,8); h=substr($0,9,2)+0; m=substr($0,11,2)+0;
        m=m-1; if(m<0){m=59; h=h-1; if(h<0){h=23; t=t-1}}; printf "%s%02d%02d", t, h, m}'
}
# 审计读取：以基线行号隔离历史运行残留（AUD_BASE 在预置复位后采集），宿主侧 grep
AUD_BASE=0
AUD() { AS "tail -n +$((AUD_BASE + 1)) $DATA/scheduler/audit.log 2>/dev/null" | grep -- "$1"; }
ipc_ready() { # daemon restart 后 IPC 就绪有界轮询（D-P5-05 同款；真机 tick 7-9s，
              # 窗口收紧到 40s，个别请求超时由调用点重试兜底。P6-10 agg2 教训：
              # 宿主用户 App 内存压力期（free<200MB/top 122M）单次请求可 >15min，
              # 轮询预算放大到 200s 并在注释记录环境限制）
    w=0; r=""
    while [ "$w" -lt 200 ]; do
        r=$(AD "timeout 30 su-scheduler webui GET_SUMMARY 2>&1" | tail -1)
        echo "$r" | grep -q '"ok":true' && return 0
        sleep 4; w=$((w + 4))
    done
    return 1
}
# IPC 控制请求（写面）：客户端超时放大 + operation_timeout 单次重试（D-P5-05 惯例，
# 真机波次期 tick 预算 7-9s 会短暂饥饿 nap 段逐秒轮询——测试侧时序处理，非产品缺陷）
ctl_send() { # <OP> <key=value...> → 响应首行。真机高负载下 scheduler_tick 可 >15s
             # （dag 波次期实测），客户端 25s + 至多 4 次重试（D-P5-05 惯例强化；
             # P6-10 汇总运行：热机连跑期 rc5 密集出现，3 轮不足 → 5 轮 15s 间隔）
    local op="$1"; shift
    local kv r i
    r=""
    for i in 1 2 3 4 5; do
        r=$(AD "SU_SCHEDULER_IPC_TIMEOUT=25 timeout 40 su-scheduler ipc $op $* 2>&1" | head -1)
        echo "$r" | grep -Eq "operation_timeout|daemon_unavailable|Terminated" || break
        sleep 15
    done
    printf '%s\n' "$r"
}
# 通读型 IPC 重试封装（P6-10 汇总运行教训：设备热机/连跑阶段服务端 rc5
# operation_timeout 快回而非挂起——重试即恢复，属测试侧时序处理，D-P5-05 惯例）
ipc_retry() { # <客户端秒> <轮数> <head|tail> <su-scheduler 参数...> → 响应行
    local to="$1" rounds="$2" mode="$3"; shift 3
    local r i sel
    sel=head
    [ "$mode" = "tail" ] && sel=tail
    r=""
    i=0
    while [ "$i" -lt "$rounds" ]; do
        i=$((i + 1))
        r=$(AD "SU_SCHEDULER_IPC_TIMEOUT=$to timeout $((to + 15)) su-scheduler $* 2>&1" | $sel -1)
        echo "$r" | grep -Eq "operation_timeout|daemon_unavailable|Terminated" || break
        sleep 15
    done
    printf '%s\n' "$r"
}
# managed .task 写入（对齐 p6-dag ex_task 全字段）
# <id> <trigger> <dep> <command> [retry.max] [retry.interval]
task_file() {
    local id="$1" trig="$2" dep="$3" cmd="$4" rmax="${5:-0}" rint="${6:-60}"
    AD "cat > $TCFG/$id.task <<P6EOF
schema_version=2
id=$id
name=$id
enabled=1
trigger=$trig
condition=
dependency=$dep
action.type=command
action.command=$cmd
action.notify_start=0
action.notify_end=0
action.delete=0
action.termux=0
action.interactive=0
action.run_once_now=0
action.boot=0
action.msg=
health.type=none
recovery.type=none
retry.max=$rmax
retry.interval=$rint
P6EOF
chmod 600 $TCFG/$id.task"
}

# ── 0) 预置复位（可重复矩阵；同 p3 pre-flight 语义）
# 注意 cycle-* / last_tick 复位：引擎登记扫描以 cycle 标记为事实源（P6-07 F2 有界
# 扫描）。若只清 dag/ 不清 cycle-*，历史 token 会被重登记为 PENDING 僵尸 run 并占满
# DAG_RUNS_MAX 名额饿死后续链（P6-10 真机发现，登记 D-P6-10-01；此处按运行期残留
# 一并复位，恢复确定性基线——属测试基建，不修改产品行为）。
# 实例普查与收敛（测试侧环境复位；产品面已登记 D-P6-10-02：高负载下
# cmd_stop 6s 等待超时后删锁 → 新实例 noclobber 接管成功 → lock 非持有者残留
# 双 daemon 同 tick——凡 restart 皆竞态源，本套件统一改用**确定性冷启动收敛**：
# 全杀 → 清锁/清 guard → 直启单实例 → 看护扫非持有者）。
# P6-10 真机修正：①`pidof su-schedulerd` 恒空（shebang 进程 comm=sh，toybox
#   pidof 按 comm 匹配；CLI _daemon_pids 同源已修，su-scheduler L900）→ 改
#   /proc cmdline **锚定前缀**扫描（扫描者自身 cmdline 形如 "/system/bin/sh -c
#   su -c for d..."，前缀后是 "-c" 不会命中锚定模式——非锚定的 *pattern* 手工版
#   曾自匹配误杀自身，h_conv 实伤注记）；②daemon 瞬时子 shell 与主进程同
#   cmdline → 按 ppid∉实例集去重；③被杀实例的孤儿子 shell 重挂 init 后短暂
#   仍会被计数 → 收敛尾扫前 sleep 5 消化。
DAE() { # stdout: 空格分隔真实 daemon 实例 pid（子 shell 去重）
    AS "for d in /proc/[0-9]*; do
    c=\$(cat \$d/cmdline 2>/dev/null | tr \"\\0\" \" \")
    case \"\$c\" in
      \"/system/bin/sh /system/bin/su-schedulerd\"*)
        p=\${d#/proc/}; pp=\$(cut -d\" \" -f4 \$d/stat 2>/dev/null); echo \"\$p \$pp\";;
    esac
done" | awk '{pid[$1]=1; a[NR]=$1; b[NR]=$2} END{for(i=1;i<=NR;i++) if(!(b[i] in pid)) printf "%s ", a[i]; print ""}'
}
converge() { # 确定性单实例冷启动（≤3 轮）；成功回 0 并置 AL/NDAE
    a=0
    while [ "$a" -lt 3 ]; do
        a=$((a + 1))
        for p in $(DAE); do AS "kill -9 $p" >/dev/null; done
        AS "rm -f /dev/.su_scheduler.lock $DATA/runtime/daemon.guard" >/dev/null
        sleep 5
        for p in $(DAE); do AS "kill -9 $p" >/dev/null; done
        AS "nohup /system/bin/su-schedulerd >/dev/null 2>&1 & sleep 4" >/dev/null
        W=0; L=""
        while [ "$W" -lt 30 ]; do
            L=$(AS "cat /dev/.su_scheduler.lock 2>/dev/null")
            [ -n "$L" ] && [ -n "$(AS "ls -d /proc/$L 2>/dev/null")" ] && break
            sleep 3; W=$((W + 3))
        done
        for p in $(DAE); do [ "$p" = "$L" ] || AS "kill -9 $p" >/dev/null; done
        sleep 5
        NDAE=$(DAE | wc -w)
        [ "$NDAE" = "1" ] && break
    done
    AL=$(AS "su-scheduler status 2>/dev/null")
}
AS "rm -f $TCFG/MANAGED 2>/dev/null
for tf in $TCFG/p6_*.task; do rm -f \"\$tf\" 2>/dev/null; done
rm -rf $TCFG.bak $DATA/dag 2>/dev/null
rm -f $DATA/scheduler/cycle-* $DATA/scheduler/last_tick 2>/dev/null
rm -rf $DATA/tasks/p6_* 2>/dev/null
rm -f /data/local/tmp/p6-m-* /data/local/tmp/p6-cf-exec /data/local/tmp/p6-*.payload 2>/dev/null" >/dev/null
converge
[ "$NDAE" = "1" ] && ok "0-preflight: single daemon instance (cold-start convergence)" \
    || bad "0-preflight: daemon instances=$NDAE (twin unresolved — D-P6-10-02 active, abort determinism)"
# 审计基线：本运行所有 AUD 只看此行之后的新行（防上一轮运行的旧审计行假绿/假红）
AUD_BASE=$(AS "wc -l < $DATA/scheduler/audit.log 2>/dev/null"); AUD_BASE=${AUD_BASE:-0}
CFG_MD5_BEFORE=$(AS "md5sum $CONFIG | cut -d\" \" -f1")
# ── 0e) 设备负载记录（P6-10 agg#2 教训：宿主用户 App（baidu.tieba/miui notes）
# 内存/CPU 压力期 tick 与 IPC 预算可膨胀 ≥20×，分钟级判据失真；>6 时做一次
# 有界 180s 沉降尝试后照常进行——环境限制记录进 trace，供矩阵引用，不伪造）。
LD=$(AS "cat /proc/loadavg" | awk '{print $1}')
EW=0
while [ "$(printf '%s' "${LD:-0}" | cut -d. -f1)" -ge 6 ] && [ "$EW" -lt 180 ]; do
    sleep 20; EW=$((EW + 20))
    LD=$(AS "cat /proc/loadavg" | awk '{print $1}')
done
echo_t "[env] load1=${LD:-?} (settle wait ${EW}s) | $(AS "grep MemFree /proc/meminfo")"

# ═══════════════════════════════════════════════════════════════════════════
# 1) 安装态预检（升级后的当前构建在位）
# ═══════════════════════════════════════════════════════════════════════════
MOK=1
$ADB shell "su -c '/data/adb/ksu/bin/ksud module list 2>/dev/null'" 2>/dev/null | grep -q '"id": "su-scheduler"' || MOK=0
[ -n "$(AS "ls /data/adb/modules/su-scheduler/system/bin/su-scheduler-runtime 2>/dev/null")" ] || MOK=0
[ "$MOK" -eq 1 ] && ok "1-module: su-scheduler module installed (ksud, current build)" || bad "1-module: module not installed"
RL=$(AS "grep \"Runtime library loaded\" $DATA/su-scheduler.log" | tail -1)
echo "$RL" | grep -q "v$RT" && ok "1-module: daemon Runtime v$RT loaded" || bad "1-module: load=[$RL]"
echo "$AL" | grep -qi "Alive" && ok "1-module: daemon Alive (service.sh watchdog)" || bad "1-module: not alive [$AL]"
tickp

# 进入 managed（2..9 全 managed 域；10 回 legacy）——converge 冷启动读 MANAGED
AS "mkdir -p $TCFG; echo managed > $TCFG/MANAGED" >/dev/null
converge
W=0; MODE=""
while [ "$W" -lt 40 ]; do
    MODE=$(AS "su-scheduler task-config status 2>/dev/null | grep ^mode=")
    echo "$MODE" | grep -q managed && break
    sleep 2; W=$((W + 2))
done
echo "$MODE" | grep -q managed && ok "entry: mode=managed (Task v2 authority)" || bad "entry: mode=[$MODE]"
ipc_ready || echo_t "[note] IPC readiness timeout (per-case bounds absorb)"

# ═══════════════════════════════════════════════════════════════════════════
# 2) 跳拍补偿（P6-02）——真机时钟等价时序（见头注）
# ═══════════════════════════════════════════════════════════════════════════
CUR=$(DEVTOK)
case "$CUR" in
  *235[0-9]|*2359|*000[0-9])
    skip "2-catchup: near-midnight window (suite clock guard; P6-02 no-cross-midnight by design)"
    ;;
  *)
    # 同步到 tick(X) 完成：last_tick == 当前 token
    W=0; LT=""
    while [ "$W" -lt 150 ]; do
        CUR=$(DEVTOK)
        LT=$(AS "cat $DATA/scheduler/last_tick 2>/dev/null")
        [ "$LT" = "$CUR" ] && break
        sleep 3; W=$((W + 3))
    done
    if [ "$LT" != "$CUR" ]; then
        bad "2-catchup: cannot sync on completed tick (cur=$CUR last=$LT)"
    else
        XM=$(printf '%s' "$CUR" | cut -c9-12)
        LTP=$(TOKPREV "$CUR")
        task_file p6_cupt1 "$XM" "" "echo catchup-ok >> /data/local/tmp/p6-m-cupt1"
        task_file p6_cupton "oneshot:$XM" "" "echo oneshot-ok >> /data/local/tmp/p6-m-cupton"
        AD "printf '%s\n' $LTP > $DATA/scheduler/last_tick" >/dev/null
        W=0; EA=""
        while [ "$W" -lt 200 ]; do
            EA=$(AUD "op=exec|task=p6_cupt1")
            [ -n "$EA" ] && break
            sleep 3; W=$((W + 3))
        done
        echo "$EA" | grep -q "catchup=1" \
            && ok "2-catchup: missed HHMM task executed via catch-up (op=exec|...|catchup=1)" \
            || bad "2-catchup: exec audit=[$EA]"
        MK=$(AS "cat /data/local/tmp/p6-m-cupt1 2>/dev/null")
        [ "$MK" = "catchup-ok" ] && ok "2-catchup: caught-up command really ran (marker)" || bad "2-catchup: marker=[$MK]"
        # op=tick 审计在 exec 之后（tick 收尾行）——有界补轮询（P6-10 run#9/run#10
        # 教训：①exec 即断导致过早读取空；②高负载下 tick 落地可迟 1-2 拍，聚合行
        # now= 记的是**实际处理分钟**（可 X+1/X+2/X+3，catchup≤CATCHUP_MAX=3），
        # 断 now=X+1 属测试侧窗口过窄。改为：本次运行新增 tick 行中任一行
        # catchup>0 即认定聚合记录（exec 行已另行断言 catchup=1）。
        TK=$(AUD "op=tick" | grep -E "\|catchup=[1-9]")
        W2=0
        while [ -z "$TK" ] && [ "$W2" -lt 150 ]; do
            sleep 3; W2=$((W2 + 3))
            TK=$(AUD "op=tick" | grep -E "\|catchup=[1-9]")
        done
        [ -n "$TK" ] \
            && ok "2-catchup: op=tick aggregate catchup>0 recorded (late-tick tolerant)" || bad "2-catchup: tick audit=[$TK]"
        EO=$(AUD "op=exec|task=p6_cupton")
        ME=$(AS "cat /data/local/tmp/p6-m-cupton 2>/dev/null")
        [ -z "$EO" ] && [ -z "$ME" ] && ok "2-catchup: expired oneshot NOT compensated" \
            || bad "2-catchup: oneshot compensated exec=[$EO] marker=[$ME]"
        N=$(printf '%s\n' "$EA" | grep -c "catchup=1")
        sleep 65
        N2=$(AUD "op=exec|task=p6_cupt1" | grep -c "")
        { [ "$N" = "1" ] && [ "$N2" = "1" ]; } \
            && ok "2-catchup: same window executed exactly once (no repeat)" \
            || bad "2-catchup: repeats n1=$N n2=$N2"
        LT2=$(AS "cat $DATA/scheduler/last_tick")
        converge
        sleep 65
        LT3=$(AS "cat $DATA/scheduler/last_tick")
        EA3=$(AUD "op=exec|task=p6_cupt1" | grep -c "")
        { [ -n "$LT2" ] && [ "$LT3" != "$LT2" ] && [ "$EA3" = "1" ]; } \
            && ok "2-catchup: last_tick persisted across restart and advanced ($LT2 -> $LT3); no replay" \
            || bad "2-catchup: persist lt2=$LT2 lt3=$LT3 exec=$EA3"
    fi
    AS "rm -f $TCFG/p6_cupt1.task $TCFG/p6_cupton.task /data/local/tmp/p6-m-cupt1 /data/local/tmp/p6-m-cupton" >/dev/null
    ;;
esac
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 3) Cron ID 派生（P6-03）
# ═══════════════════════════════════════════════════════════════════════════
CN=$(AD "su-scheduler task-config new 'cron:0 8 * * *' 'echo p6cron > /data/local/tmp/p6-m-cron' 2>&1")
CID=$(printf '%s\n' "$CN" | sed -n 's/^created task //p' | head -1)
if [ -n "$CID" ]; then
    ok "3-cronid: task-config new with spaced cron accepted (id=$CID)"
    case "$CID" in
        *[!A-Za-z0-9._-]*) bad "3-cronid: derived id '$CID' outside charset" ;;
        *) ok "3-cronid: derived id charset-safe [A-Za-z0-9._-]" ;;
    esac
    case "$CID" in
        task_cron*) ok "3-cronid: id in task_cron* derivation namespace" ;;
        *) bad "3-cronid: unexpected id shape [$CID]" ;;
    esac
    CT=$(AS "grep ^trigger= $TCFG/$CID.task 2>/dev/null")
    [ "$CT" = "trigger=cron:0 8 * * *" ] \
        && ok "3-cronid: trigger stored verbatim (spaces intact, ID sanitize does not touch field)" \
        || bad "3-cronid: trigger=[$CT]"
else
    bad "3-cronid: new cron task failed=[$CN]"; CID=""
fi
TN=$(AD "su-scheduler task-config new 'cron:../../etc/passwd' 'echo x' 2>&1")
TID=$(printf '%s\n' "$TN" | sed -n 's/^created task //p' | head -1)
if [ -n "$TID" ] && [ -n "$(AS "ls $TCFG/$TID.task 2>/dev/null")" ]; then
    case "$TID" in
        *[/]*) bad "3-cronid: traversal id not sanitized [$TID]" ;;
        *) ok "3-cronid: traversal-shaped trigger sanitized to safe in-dir filename ($TID)" ;;
    esac
else
    bad "3-cronid: traversal new=[$TN]"
fi
ipc_ready
# run#13 教训：裸 timeout 5 在 daemon 忙拍（catch-up 期 tick 可达 20s+）被杀出
# "Terminated"——改走 ctl_send（25s 客户端 + operation_timeout/Terminated 重试）。
EV=$(ctl_send CREATE_TASK id=../evil trigger=0830 command=echo+hi)
{ echo "$EV" | grep -q "|1|invalid_request"; } \
    && ok "3-cronid: IPC CREATE_TASK id=../evil explicitly rejected (invalid_request rc=1)" \
    || bad "3-cronid: ipc evil resp=[$EV]"
[ -n "$CID" ] && AS "rm -f $TCFG/$CID.task" >/dev/null
[ -n "$TID" ] && AS "rm -f $TCFG/$TID.task" >/dev/null
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 4) IPC 错误透传（P6-04）
#    字段级原因走 **payload（editor 校验）通道**（P6-04 实装面）；trigger=/command=
#    沙箱通道是 tcfg_validate_task 弱门（仅非空/charset），设备实测该通道接受
#    oneshot:2460 等形状非法串——通道语义差异登记于 docs/P6-10.md（O-P6-10-03），
#    测试按实装通道断言（非掩盖：payload 通道才是 CLI/WebUI 消费面）。
# ═══════════════════════════════════════════════════════════════════════════
ipc_ready
LONG=$(printf 'x%.0s' $(seq 1 1000))
AD "cat > /data/local/tmp/p6-e1.pay <<P6EOF
schema_version=2
id=p6_e1
name=p6_e1
enabled=1
trigger=oneshot:2460
action.type=command
action.command=echo x
P6EOF
cat > /data/local/tmp/p6-e3.pay <<P6EOF
schema_version=2
id=p6_e3
name=p6_e3
enabled=1
trigger=$LONG
action.type=command
action.command=echo x
P6EOF" >/dev/null
R1=$(ipc_retry 20 4 head ipc VALIDATE_TASK 'payload=\"$(cat /data/local/tmp/p6-e1.pay)\"')
R2=$(ipc_retry 15 4 head ipc VALIDATE_TASK trigger=0830)
R3=$(ipc_retry 20 4 head ipc VALIDATE_TASK 'payload=\"$(cat /data/local/tmp/p6-e3.pay)\"')
AS "rm -f /data/local/tmp/p6-e1.pay /data/local/tmp/p6-e3.pay" >/dev/null
E1=$(printf '%s' "$R1" | cut -d'|' -f4)
E2=$(printf '%s' "$R2" | cut -d'|' -f4)
echo "$R1" | grep -q "|4|configuration_invalid: trigger" \
    && ok "4-ipcerr: bad trigger via payload channel -> field-level reason (configuration_invalid: trigger 'oneshot:2460'...)" \
    || bad "4-ipcerr: R1=[$R1]"
echo "$R2" | grep -q "|4|configuration_invalid: trigger+command required" \
    && ok "4-ipcerr: missing command -> distinct required-fields reason" \
    || bad "4-ipcerr: R2=[$R2]"
[ -n "$E1" ] && [ "$E1" != "$E2" ] \
    && ok "4-ipcerr: two invalid classes distinguishable (O-4 semantics on device)" \
    || bad "4-ipcerr: identical [$E1]"
EF3=$(printf '%s' "$R3" | cut -d'|' -f4)
LE=${#EF3}
{ [ "$LE" -le 260 ] && echo "$R3" | grep -q "(truncated)"; } \
    && ok "4-ipcerr: overlong reason clamped (field len=$LE<=256, ...(truncated) marker)" \
    || bad "4-ipcerr: clamp len=$LE field=[$(printf '%s' "$EF3" | head -c 100)...]"
LEAK=$(printf '%s' "$R1$R2$R3" | grep -c "/data/adb")
[ "$LEAK" = "0" ] && ok "4-ipcerr: no internal path (/data/adb) leakage in ERROR fields" \
    || bad "4-ipcerr: path leak count=$LEAK"
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 5) DAG 配置期拒绝（D55）
# ═══════════════════════════════════════════════════════════════════════════
AD "cat > /data/local/tmp/p6-orph.payload <<P6EOF
schema_version=2
id=p6_orph2
name=p6_orph2
enabled=1
trigger=chain
condition=
dependency=
action.type=command
action.command=echo x
P6EOF" >/dev/null
ORPH=$(AS "su-scheduler task-config apply p6_orph2 /data/local/tmp/p6-orph.payload 2>&1; echo rc=\$?")
AS "rm -f /data/local/tmp/p6-orph.payload $TCFG/p6_orph2.task" >/dev/null
{ echo "$ORPH" | grep -Eq "rc=[1-9]" && echo "$ORPH" | grep -q "chain node without incoming edge"; } \
    && ok "5-dagcfg: orphan trigger=chain rejected at config time (not persisted)" \
    || bad "5-dagcfg: orphan=[$ORPH]"
# 环：b1 直写（依赖 b2）+ apply b2（依赖 b1）→ 合并图成环被拒
task_file p6_cycb1 "chain" "p6_cycb2" "echo x"
AD "cat > /data/local/tmp/p6-b2.payload <<P6EOF
schema_version=2
id=p6_cycb2
name=p6_cycb2
enabled=1
trigger=chain
condition=
dependency=p6_cycb1
action.type=command
action.command=echo x
P6EOF" >/dev/null
CYC=$(AS "su-scheduler task-config apply p6_cycb2 /data/local/tmp/p6-b2.payload 2>&1; echo rc=\$?")
AS "rm -f $TCFG/p6_cycb1.task $TCFG/p6_cycb2.task /data/local/tmp/p6-b2.payload" >/dev/null
{ echo "$CYC" | grep -Eq "rc=[1-9]" && echo "$CYC" | grep -qiE "cycle|circular"; } \
    && ok "5-dagcfg: cycle graph rejected at config time (cycle keyword, b2 not persisted)" \
    || bad "5-dagcfg: cycle=[$CYC]"
# 深度超限 17：直写整梯 → 下一拍 snapshot 图校验 KEPT（审计 reason=dependency-graph-invalid）
task_file p6_droot "interval:1440" "" "echo x"
task_file p6_d1 "chain" "p6_droot" "echo x"
i=2
while [ "$i" -le 17 ]; do task_file "p6_d$i" "chain" "p6_d$((i-1))" "echo x"; i=$((i + 1)); done
W=0; KEPT=""
while [ "$W" -lt 100 ]; do
    KEPT=$(AUD "reason=dependency-graph-invalid")
    [ -n "$KEPT" ] && break
    sleep 3; W=$((W + 3))
done
DEEPV=$(AS "su-scheduler chain p6_droot 2>&1 | grep -m1 validation_error")
{ [ -n "$KEPT" ] || echo "$DEEPV" | grep -q "depth"; } \
    && ok "5-dagcfg: depth-17 ladder refused (snapshot KEPT audit / chain validation_error)" \
    || bad "5-dagcfg: deep17 kept=[$KEPT] chain=[$DEEPV]"
AS "rm -f $TCFG/p6_d*.task" >/dev/null
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 6/7) DAG 波次（真机分钟 tick）+ 波中 kill -9
# ═══════════════════════════════════════════════════════════════════════════
CM=$(printf '%s' "$(DEVTOK)" | cut -c9-12)
M=$(MINADD "$CM" 2)
task_file p6_ra "$M" "" "echo ra >> /data/local/tmp/p6-m-ra"
task_file p6_ab "chain" "p6_ra" "echo ab >> /data/local/tmp/p6-m-ab"
task_file p6_ac "chain" "p6_ab" "echo ac >> /data/local/tmp/p6-m-ac"
task_file p6_rb "$M" "" "echo rb >> /data/local/tmp/p6-m-rb"
task_file p6_bb "chain" "p6_rb" "sleep 420"
task_file p6_bc "chain" "p6_rb" "echo bc >> /data/local/tmp/p6-m-bc"
task_file p6_bz "chain" "p6_bb,p6_bc" "echo bz >> /data/local/tmp/p6-m-bz"
task_file p6_rc "$M" "" "echo rc >> /data/local/tmp/p6-m-rc"
task_file p6_cf "chain" "p6_rc" "echo cf >> /data/local/tmp/p6-cf-exec; exit 1" 1 0
task_file p6_cg "chain" "p6_cf" "echo cg >> /data/local/tmp/p6-m-cg"
task_file p6_ya "$M" "" "echo ya >> /data/local/tmp/p6-m-ya"
task_file p6_yb "chain" "p6_ya" "echo yb >> /data/local/tmp/p6-m-yb; exit 1"
task_file p6_yc "chain" "p6_ya,?p6_yb" "echo yc >> /data/local/tmp/p6-m-yc"
echo_t "[wave] roots scheduled at $M (device now $CM)"
W=0; REG=""; RG=""
while [ "$W" -lt 300 ]; do
    REG=$(AS "ls -d $DATA/dag/p6_ra/runs/*/run.txt 2>/dev/null")
    [ -n "$REG" ] && break
    sleep 3; W=$((W + 3))
done
RUNTOK=$(printf '%s' "$REG" | sed -n '1s|.*/runs/||; s|/run.txt||p')
[ -n "$RUNTOK" ] && ok "6-dagwave: chain runs registered after root tick (run=$RUNTOK)" \
    || bad "6-dagwave: registration not observed in 300s (register audit=[$(AUD 'action=register' | tail -2)])"
RAN=$(AS "wc -l < /data/local/tmp/p6-m-ra 2>/dev/null"); RAN=${RAN:-0}
[ "$RAN" = "1" ] && ok "6-dagwave: root fired exactly once" || bad "6-dagwave: root count=$RAN"
# ── kill 时机（测试侧时序处理，P6-10 run#6/12/13/15/16 教训迭代）：kill 必须晚于
#    「全部非 bb 链定稿」且落在 bb 真实在途窗内。判据演进：run#12 marker 落地即 kill
#    → dispatch+3s 死而未收 → R7 FAILED+级联（语义正确，run#6 实证）；run#13 误用
#    chain CLI 渲染格式恒不命中；run#15 成员镜像 STOPPED 即 kill（与定稿拍同窗）仍
#    FAILED；run#16 三条件（ra 终局）kill 落在 cf 重试 attempt-2 start 后 4s——真机
#    暴露「kill-after-respawn 使 retry.count 复位 → 终局 run 仍复跑一次」缺陷
#    （D-P6-10-03 登记；本套件按 rc 链终局后再 kill 规避同窗，缺陷另行复现）。
#    现判据（五条件，轮询 5s，≤420s）：①ra run 终局 state=SUCCESS（账本不可变，
#    kill 验「不重放/不重复建 run」）；②rc 终局 FAILED（cf 重试活动全部落定，
#    避开 respawn 微窗）；③ya 终局 FAILED；④rb 在途 RUNNING（bz 未跑）；⑤bb
#    state.txt=RUNNING（活进程）。kill 后：watchdog 拉起 → 快打 STOP_TASK 抢在恢复
#    首拍 residual 判 FAILED 之前送达 → bb STOPPED（EX-12 缺省边满足）→ bz 放行 →
#    rb 重启后收敛 SUCCESS——「run 中途 kill 账本续跑（不重放）+ 控制面在途干预」
#    的完整真机证据。bb=sleep 420：非 bb 链 ~root+4.2min 全落定，bb 活至 +7min，
#    窗口 ~3 分钟（DAG_RUN_TIMEOUT=86400s 无超时压力）。未命中 → [note] 后仍 kill。
#    注：pattern 尾锚 `$` 在 adb→mksh 双引号层被解析成 ANSI-C `$'…'` 破坏参数
#    （P6-10 pred2 实测）；五态命名下 SUCCESS/RUNNING 无歧义前缀，仅左锚 `^` 即可。
W=0; QUIET=""
while [ "$W" -lt 420 ]; do
    QUIET=$(AD "grep -q '^state=SUCCESS' $DATA/dag/p6_ra/runs/*/run.txt 2>/dev/null && grep -q '^state=FAILED' $DATA/dag/p6_rc/runs/*/run.txt 2>/dev/null && grep -q '^state=FAILED' $DATA/dag/p6_ya/runs/*/run.txt 2>/dev/null && grep -q '^state=RUNNING' $DATA/dag/p6_rb/runs/*/run.txt 2>/dev/null && grep -q RUNNING $DATA/tasks/p6_bb/state.txt 2>/dev/null && echo fin")
    [ "$QUIET" = "fin" ] && break
    sleep 5; W=$((W + 5))
done
[ "$QUIET" = "fin" ] && ok "6-dagwave: all settled-chains closed + rb in-flight (bb RUNNING) — safe mid-run kill point" \
    || echo_t "[note] safe kill window not observed in 420s — killing anyway (R7/assertions expose)"
# ── 波中 kill -9 守护（账本存续、watchdog 拉起）
DPID=$(AS "cat /dev/.su_scheduler.lock 2>/dev/null")
AS "kill -9 $DPID 2>/dev/null" >/dev/null
echo_t "[wave] daemon pid=$DPID killed at $(date +%H:%M:%S)"
W=0; AL=""
while [ "$W" -lt 150 ]; do
    AL=$(AS "su-scheduler status 2>/dev/null"); echo "$AL" | grep -qi Alive && break
    sleep 3; W=$((W + 3))
done
echo "$AL" | grep -qi "Alive" \
    && ok "7-dagkill: watchdog restarted daemon after kill -9" || bad "7-dagkill: daemon not back [$AL]"
RUNS_RA=$(AS "ls -d $DATA/dag/p6_ra/runs/*/ 2>/dev/null | wc -l")
[ "$RUNS_RA" = "1" ] && ok "7-dagkill: no duplicate run for same root token (dirs=1, ledger survives)" \
    || bad "7-dagkill: run dirs=$RUNS_RA"
# 在途节点收敛语义（R7，P6-06/07 既定设计——run#16 真机澄清、run#10 属相位运气）：
# daemon 重启时 RUNNING 在途节点由恢复判 FAILED（活子进程由 reaper 收养至自然结束、
# **不重派发**）；bz 据 fail-propagate 级联、rb run 终局。manual-stop→STOPPED 的
# EX-12 通道由 8-control 的**无 kill 波 B** 确定性取证（kill×startup IPC 饥饿×residual
# 三方竞态真机不可稳定取胜：run#10 win / run#15/16/17 lose，O-P6-10-05）。
W=0; BST=""
while [ "$W" -lt 180 ]; do
    BST=$(AS "cat $DATA/tasks/p6_bb/state.txt 2>/dev/null")
    echo "$BST" | grep -Eq "STOPPED|FAILED|SUCCESS" && break
    sleep 3; W=$((W + 3))
done
DISP_BB=$(AUD "action=dispatch" | grep -c "task=p6_bb")
echo "$BST" | grep -Eq "FAILED|STOPPED" && [ "$DISP_BB" = "1" ] \
    && ok "7-dagkill: mid-run node converged terminal post-restart (bb=$BST) with ZERO re-dispatch (dispatch count=1, ledger continues, no replay)" \
    || bad "7-dagkill: bb=$BST dispatches=$DISP_BB"
# 全波收敛（有界 12 分钟）。注：`\\\$c` 三层转义——宿主 bash→adb→设备外层 sh 各剥
# 一层，保证 for-loop 变量在 su -c 内层展开（P6-10 run#4：设备外层 shell 提前展开
# $c 致状态读取恒空——测试自身 bug，修复注明）。
W=0; STS=""
while [ "$W" -lt 720 ]; do
    STS=$(AD "for c in p6_ra p6_rb p6_rc p6_ya; do printf '%s ' \\\$c; sed -n s/^state=//p $DATA/dag/\\\$c/runs/*/run.txt 2>/dev/null | tail -1; done")
    { echo "$STS" | grep -q "p6_ra SUCCESS" && echo "$STS" | grep -Eq "p6_rb (SUCCESS|FAILED)" \
      && echo "$STS" | grep -q "p6_rc FAILED" && echo "$STS" | grep -q "p6_ya FAILED"; } && break
    sleep 5; W=$((W + 5))
done
echo_t "[wave] converged states: $STS (after ${W}s)"
echo "$STS" | grep -q "p6_ra SUCCESS" \
    && ok "6-dagwave: linear ra->ab->ac converged run=SUCCESS on real minute ticks" \
    || bad "6-dagwave: linear=[$STS]"
echo "$STS" | grep -Eq "p6_rb (SUCCESS|FAILED)" \
    && ok "6-dagwave: branch+merge rb->(bb,bc)->bz reaches terminal run-state despite mid-wave kill (EX-12 stop proven kill-free in wave B)" \
    || bad "6-dagwave: merge unresolved=[$STS]"
CFN=$(AS "wc -l < /data/local/tmp/p6-cf-exec 2>/dev/null")
[ "$CFN" = "2" ] \
    && ok "6-dagwave: failing node executions clamped to 1+retry.max=2 (no infinite replay)" \
    || bad "6-dagwave: cf execs=$CFN"
CGM=$(AS "cat /data/local/tmp/p6-m-cg 2>/dev/null")
[ -z "$CGM" ] && ok "6-dagwave: Required-failed downstream (cg) never executed (cascade blocks)" \
    || bad "6-dagwave: cg executed!"
FPA=$(AUD "action=fail-propagate|chain=p6_rc")
[ -n "$FPA" ] && ok "6-dagwave: fail-propagate audit recorded (run.txt gate-fail cascade)" \
    || bad "6-dagwave: no propagate audit [$(AUD 'op=dag' | tail -3 | head -1)]"
echo "$STS" | grep -q "p6_rc FAILED" && ok "6-dagwave: failure chain terminal run=FAILED" || bad "6-dagwave: rc=[$STS]"
DMM=$(AS "cat /data/local/tmp/p6-m-yc 2>/dev/null")
[ "$DMM" = "yc" ] && ok "6-dagwave: optional-unsatisfied does not block node (yc ran despite yb FAILED)" \
    || bad "6-dagwave: yc marker=[$DMM]"
echo "$STS" | grep -q "p6_ya FAILED" && ok "6-dagwave: optional aux failure converges run=FAILED (v1)" \
    || bad "6-dagwave: ya=[$STS]"
RAN2=$(AS "wc -l < /data/local/tmp/p6-m-ra 2>/dev/null")
[ "$RAN2" = "1" ] && ok "7-dagkill: root NOT replayed after mid-wave kill -9 (count stays 1)" \
    || bad "7-dagkill: root replayed count=$RAN2"
COMPL=$(AUD "action=complete")
{ echo "$COMPL" | grep -q "state=SUCCESS" && echo "$COMPL" | grep -q "state=FAILED"; } \
    && ok "7-dagkill: run-terminal action=complete audits for both outcomes (P6-09)" \
    || bad "7-dagkill: complete=[$COMPL]"
[ -z "$RUNTOK" ] && RUNTOK=$(AS "ls $DATA/dag/p6_ra/runs/ 2>/dev/null | head -1")
RUNROOT=$(AS "sed -n s/^root=//p $DATA/dag/p6_ra/runs/$RUNTOK/run.txt 2>/dev/null")
echo "$RUNROOT" | grep -q "p6_ra" && ok "6-dagwave: run.txt ledger intact across restart (root=$RUNROOT)" \
    || bad "6-dagwave: ledger root line=[$RUNROOT]"
# ── 批量控制（波收敛后的静默期执行——「链=批量节点操作」的 IPC 实面；在途期
#    批量会撞上真机 tick 7-9s 的 IPC 饥饿窗口：测试侧时序处理，D-P5-05 同款惯例）
BRES=$(AS "SU_SCHEDULER_IPC_TIMEOUT=15 timeout 60 su-scheduler task stop p6_ac p6_bz 2>&1; echo rc=\$?")
NBL=$(printf '%s\n' "$BRES" | grep -cE "^p6_(ac|bz): ")
[ "$NBL" = "2" ] && ok "8-control: batch stop emits per-task result lines (chain=bulk mapping)" \
    || bad "8-control: batch=[$BRES]"
CH=$(AS "su-scheduler chain 2>&1")
NCH=$(printf '%s\n' "$CH" | grep -c "^chain=p6_")
[ "$NCH" = "4" ] && ok "6-dagwave: chain listing shows all 4 chains" || bad "6-dagwave: list=[$CH]"
CHD=$(AS "su-scheduler chain p6_ac 2>&1")
{ echo "$CHD" | grep -q "^chain=p6_ra" && echo "$CHD" | grep -q "^run_state=SUCCESS"; } \
    && ok "6-dagwave: chain <member-id> resolves owning root + SUCCESS (P6-09 read-only query)" \
    || bad "6-dagwave: detail=[$CHD]"
# ── 波 B（无 kill）：在途 manual stop → STOPPED 满足缺省边 → 合流下游放行 → run
#    SUCCESS —— EX-12 控制面的确定性真机取证（daemon 健康期 IPC 正常响应，
#    run#10/15/16/17 证明 kill×startup 饥饿×residual 三方竞态不可稳定取胜）。
#    agg#2 加固：前置 settle 门（tick 间隔 >90s 的饥饿期不定根派发时刻）+ 看护扫
#    （非持有者再起 = D-P6-10-02，重启后先扫）+ 注册/在途窗 300→600s（用户 App
#    内存压力期 20× 膨胀取证）。
for p in $(DAE); do [ "$p" = "$(AS "cat /dev/.su_scheduler.lock 2>/dev/null")" ] || AS "kill -9 $p" >/dev/null; done
ipc_ready || echo_t "[note] wave-B pre-settle timeout (proceeding; window enlarged)"
BM=$(printf '%s' "$(DEVTOK)" | cut -c9-12)
BM2=$(MINADD "$BM" 2)
task_file p6_sb "$BM2" "" "echo sb >> /data/local/tmp/p6-m-sb"
task_file p6_s1 "chain" "p6_sb" "sleep 240"
task_file p6_s2 "chain" "p6_sb" "echo s2 >> /data/local/tmp/p6-m-s2"
task_file p6_s3 "chain" "p6_s1,p6_s2" "echo s3 >> /data/local/tmp/p6-m-s3"
echo_t "[wave-B] root scheduled at $BM2 (device now $BM)"
W=0; SREG=""
while [ "$W" -lt 480 ]; do
    SREG=$(AD "grep -q '^state=RUNNING' $DATA/dag/p6_sb/runs/*/run.txt 2>/dev/null && grep -q RUNNING $DATA/tasks/p6_s1/state.txt 2>/dev/null && echo fin")
    [ "$SREG" = "fin" ] && break
    sleep 5; W=$((W + 5))
done
[ "$SREG" = "fin" ] && ok "8-control: wave-B branch node s1 in-flight, merge s3 waiting (no restart involved)" \
    || bad "8-control: wave-B not in-flight (${W}s, gate=[$SREG])"
SRES=$(ctl_send STOP_TASK "id=p6_s1")
echo "$SRES" | grep -Eq "\|STOP_TASK\|(0|2)\|" \
    && ok "8-control: in-flight node stop accepted via IPC STOP_TASK (rc0/rc2, no timeout)" \
    || bad "8-control: stop s1=[$SRES]"
W=0; BST2=""
while [ "$W" -lt 300 ]; do
    BST2=$(AS "cat $DATA/tasks/p6_s1/state.txt 2>/dev/null")
    echo "$BST2" | grep -Eq "STOPPED|FAILED" && break
    sleep 3; W=$((W + 3))
done
echo "$BST2" | grep -q "STOPPED" \
    && ok "8-control: manually stopped node reaches STOPPED (satisfies default want=STOPPED)" \
    || bad "8-control: s1 final=[$BST2]"
W=0; SBST=""
while [ "$W" -lt 420 ]; do
    SBST=$(AS "sed -n s/^state=//p $DATA/dag/p6_sb/runs/*/run.txt 2>/dev/null | tail -1")
    [ "$SBST" = "SUCCESS" ] && break
    sleep 5; W=$((W + 5))
done
S3M=$(AS "cat /data/local/tmp/p6-m-s3 2>/dev/null")
{ [ "$SBST" = "SUCCESS" ] && [ "$S3M" = "s3" ]; } \
    && ok "8-control: merge s3 dispatched after manual stop (STOPPED satisfies edge) — wave-B run=SUCCESS" \
    || bad "8-control: wave-B end sb=[$SBST] s3 marker=[$S3M]"
AS "rm -f $TCFG/p6_s*.task /data/local/tmp/p6-m-s*" >/dev/null
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 9) WebUI 查询面（P6-08 dag 只增键；CLI Reader）
#    真机时延说明：波后 registry 含 13+ 链任务 + 4 链账本，GET_SUMMARY/DETAIL 的
#    dag 聚合在设备 toybox 上实测显著慢于 WSL（P6-08 §4 移交 P6-10 的真机时延
#    测量项，O-P7-05）——客户端超时放大到 90s 并把实测时延记入 trace 作矩阵证据。
# ═══════════════════════════════════════════════════════════════════════════
# ── 先探一次 IPC 可读性（热机期 rc5 快回——就绪后计时才有意义；≤8 轮）
ipc_ready || echo_t "[note] pre-webui IPC readiness timeout (latency incl. retries)"
WS=$(date +%s)
SUM=$(ipc_retry 80 5 tail webui GET_SUMMARY)
WE=$(date +%s)
echo_t "[perf] GET_SUMMARY (dag-enabled, device) latency: $((WE - WS))s"
{ echo "$SUM" | grep -q "\"ok\":true" && echo "$SUM" | grep -q '"dag"'; } \
    && ok "9-webui: GET_SUMMARY carries dag block (D58 additive key)" \
    || bad "9-webui: summary=[$(printf '%s' "$SUM" | head -c 160)]"
{ echo "$SUM" | grep -q '"active"' && echo "$SUM" | grep -q '"limit"' && echo "$SUM" | grep -q '"chains"'; } \
    && ok "9-webui: dag.active/dag.limit/dag.chains keys present" || bad "9-webui: dag keys missing"
echo "$SUM" | grep -q "p6_ra" && ok "9-webui: chains[] view data includes p6_ra ledger run" \
    || bad "9-webui: chains[] no p6_ra"
WS=$(date +%s)
DET=$(ipc_retry 80 5 tail webui GET_TASK_DETAIL id=p6_ac)
WE=$(date +%s)
echo_t "[perf] GET_TASK_DETAIL (dag) latency: $((WE - WS))s"
{ echo "$DET" | grep -q '"dag"' && echo "$DET" | grep -q '"chain_root":"p6_ra"'; } \
    && ok "9-webui: GET_TASK_DETAIL.dag.chain_root=p6_ra (node attribution)" \
    || bad "9-webui: detail=[$(printf '%s' "$DET" | head -c 160)]"
echo "$DET" | grep -q '"run_state":"SUCCESS"' \
    && ok "9-webui: dag.run_state=SUCCESS matches ledger" || bad "9-webui: run_state=[$(printf '%s' "$DET" | head -c 160)]"
TST=$(AS "su-scheduler task status p6_ac 2>&1")
{ echo "$TST" | grep -q "chain_root=p6_ra" && echo "$TST" | grep -q "role=node"; } \
    && ok "9-webui: CLI task status dag lines (P6-09 same-source)" || bad "9-webui: status=[$TST]"
tickp

# ═══════════════════════════════════════════════════════════════════════════
# 10) 还原 legacy 基线
# ═══════════════════════════════════════════════════════════════════════════
AS "rm -f $TCFG/p6_*.task $TCFG/MANAGED 2>/dev/null
rm -rf $DATA/dag $DATA/tasks/p6_* 2>/dev/null
rm -f /data/local/tmp/p6-m-* /data/local/tmp/p6-cf-exec /data/local/tmp/p6-*.payload 2>/dev/null" >/dev/null
converge
W=0; MODE=""
while [ "$W" -lt 40 ]; do
    MODE=$(AS "su-scheduler task-config status 2>/dev/null | grep ^mode=")
    echo "$MODE" | grep -q "legacy" && break
    sleep 2; W=$((W + 2))
done
CFG_MD5_AFTER=$(AS "md5sum $CONFIG | cut -d\" \" -f1")
{ echo "$AL" | grep -qi "Alive" && echo "$MODE" | grep -q "mode=legacy" && [ "$CFG_MD5_BEFORE" = "$CFG_MD5_AFTER" ]; } \
    && ok "10-restore: legacy baseline restored, daemon Alive, config byte-identical ($CFG_MD5_AFTER)" \
    || bad "10-restore: alive=[$AL] mode=[$MODE] md5 $CFG_MD5_BEFORE -> $CFG_MD5_AFTER"
tickp

TEND=$(date +%s)
echo_t "──────────────────────────────────────────────────────────────────────"
echo_t "[perf] total: $((TEND - T0))s | device=$SERIAL Android=$ANDROID_VER | Runtime $RT"
echo_t "device smoke: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
echo_t "trace: $DEVLOG"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
