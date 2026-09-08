#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# run_tests.sh — P0/P1 统一回归入口（P2-01 收口：唯一回归入口）
# ═══════════════════════════════════════════════════════════════════════════
# 串行运行（AGENTS §4 层级）：
#   L1  tests/lint/syntax.sh            静态语法（sh -n / bash -n，LF 归一）
#   L2  tests/legacy/golden.sh          T1 解析 golden 锁定（复现+比对）
#   L2  tests/cli/test.sh               CLI 行为（Q1/Q2/Q3/Q4/Q9 门禁）
#   L2  tests/state-machine/test.sh     P1 状态机（183 断言）
#   L2  tests/providers/test.sh         P1 Provider（136 断言）
#   L2  tests/legacy-adapter/test.sh    P1 legacy adapter（107 断言）
#   L2  tests/task-registry/test.sh     P1 registry（44 断言）
#   L2  tests/scheduling/trigger-decision/test.sh  P1 触发决策（39 断言）
#   L2  tests/execution/action-run/test.sh         P1 执行（24 断言）
#   L2  tests/runtime/test.sh           P1 运行时状态/事件（45 断言）
#   L2  tests/lifecycle/test.sh         P1 生命周期（56 断言）
#   L2  tests/task-cli/test.sh          P1 只读 CLI（39 断言）
#   L2  tests/runtime-lib/test.sh       P2-02 生产 Runtime 库边界（21 断言）
#   L2  tests/shadow/test.sh            P2-03 Registry Shadow Mode（旁路比对）
#   L2  tests/idmap/test.sh             P2-04 Canonical↔Legacy Run ID 映射
#   L2  tests/trigger/test.sh           P2-05 TriggerProvider 接入（25 断言）
#   L2  tests/action/test.sh            P2-06 CommandActionProvider 接入
#   L2  tests/state/test.sh             P2-07 统一状态与事件日志（双写/终态/健康门/重启残留）
#   L2  tests/task-cli-prod/test.sh     P2-08 生产 Task CLI（registry 只读挂载/稳定+旧运行 ID/三态错误）
#   L2  tests/lifecycle-prod/test.sh    P2-09 daemon 生命周期（启动序列/最后有效快照/stale PID/stop/restart/看护）
#   L2  tests/app-action/test.sh        P2-10 App Action（package/activity/broadcast/service、全参数校验、am 安全构建）
#   L2  tests/health/test.sh            P2-11 Process/Port Health（三态+原因+延迟+目标、真实监听验证、P2-07 门槛打开）
#   L2  tests/supervisor/test.sh        P2-12 Supervisor 核心（完整生命周期、统一事件循环、恢复策略）
#   L2  tests/recovery/test.sh          P2-13 Recovery/Retry/Cooldown（restart/start/stopstart/script、max_retry 钳制、cooldown）
#   L2  tests/crashguard/test.sh        P2-14 Crash Loop 与资源保护（guard 降级/节流/优雅重置、日志/目录/快照上限、健康间隔、超时护栏、fake daemon 崩溃序列）
#   L2  tests/p2-integration/test.sh    P2-15 综合回归（daemon kill/task kill/脚本 hang/应用崩溃/重启 端到端集成）
#   L2  tests/p2-install/test.sh        P2-15 发布评审（KernelSU/Magisk/APatch 安装结构 + 发布契约）
#   L2  tests/config-v2/validation.sh  P3-06 Task v2 编辑校验矩阵（ID 路径穿越/trigger 枚举/App Action 注入/
#       recovery script 绝对路径可读/数值范围/原子性/后端权威校验）
#   L2  tests/config-v2/test.sh         P3-02 Canonical Task Config Store（双模式 legacy/managed、
#       导入幂等/失败原子性/回滚/导出/新建 ID 命名空间/损坏回退/接线/POSIX）
#   L2  tests/scheduler-prod/test.sh    P3-03 Registry 正式调度接管（双模式 legacy/managed、
#       TriggerProvider→ActionProvider、同周期去重、配置变更不重复执行、损坏 KEPT、
#       task.v2 快照移除监督兜底、旧 CLI 查询/终止、单任务错误隔离、审计日志、接线）
#   L2  tests/ipc/test.sh               P3-04 本地 IPC 控制面（请求/响应文件通道、固定格式、
#       base64 值、12 op 白名单、错误码可区分、写操作仅 managed、START/STOP/RESTART 经
#       action_run、重复请求不重复启动、原子响应、接线）
#   L2  tests/ipc/security.sh           P3-04 IPC 安全边界（fuzz/注入零副作用、Shell 元字符
#       不进入执行路径、同 req_id 幂等、已运行不重复 START、单轮有界不阻塞、0700 权限、
#       未授权写 permission_denied、daemon 停止 daemon_unavailable、超时 operation_timeout）
#   L2  tests/webui/read-only.test.sh   P3-05 WebUI 只读数据面（GET_SUMMARY/GET_TASK_DETAIL/
#       GET_TASK_EVENTS/GET_DAEMON_LOG 统一 JSON、GET_TASK_LOG meta 行、JSON 转义防注入、
#       空/损坏/daemon 离线三态、CLI Reader 只读白名单 + JSON 信封、零 exec）
#   L2  tests/webui/security.test.sh    P3-05 WebUI 安全（webroot 无 Root 直执特征、恶意
#       请求零 exec/零 config 写、<script>/引号/换行 JSON 转义、malformed→invalid_request、
#       有界日志 + truncated 标志）
#   L2  tests/task-control/test.sh   P3-07 Task 控制操作（WebUI/CLI 共用同一控制 API：§24
#       tctl_* + TSM 强制（start/stop/check 可追踪）+ 并发 skip + stop 不误杀 + 旧运行 ID
#       控制旧运行目录 + enable/disable 仅 managed + CLI 子命令经 IPC 全链路 + 失败零副作用）
#   L2  tests/security/fuzz.sh       P3-08 输入安全（IPC 白名单/格式 fuzz、Task ID 字符集、
#       请求大小限制、START/CREATE/UPDATE 命令注入全拒、App Action/脚本路径校验、零副作用）
#   L2  tests/security/path-validation.sh  P3-08 路径安全（路径穿越/符号链接/允许目录约束/
#       Task ID 门/IPC 穿越 id 拒绝零泄露）
#   L2  tests/security/permission.sh P3-08 文件安全（secv_fix_perms 强制、原子写 tmp 清理、
#       secv_sweep_tmp、未授权写 permission_denied）
#   L2  tests/resource/stress.sh     P3-08 资源安全（100 Task 单循环无 100 永久循环、
#       日志/快照/任务目录上限、单任务错误隔离、IPC 频率限制 rc 7、CPU/内存有界）
#   L2  tests/p3-integration/test.sh P3-09 综合回归（安装契约→Runtime 加载→Legacy 继续
#       执行→Task v2 导入→Registry 调度→WebUI Dashboard→Task Editor 保存/回滚→App Action
#       →Process/Port Health→Retry/Cooldown 钳制→Crash Loop→Task 控制→配置损坏回退→
#       旧 CLI 查询→日志轮转→重启状态恢复 端到端协同，48 断言）
#   L2  tests/p4-dependency/test.sh P4-02/P4-03 Dependency/Condition Schema 与
#       持久化 + 依赖图校验（逗号规范写回/空格容错规范化、[?]id[:STATE] 解析、
#       condition 可打印 ASCII 上限、DEP_MAX/COND_MAX_LEN、editor/store/CLI 后端
#       权威校验、非法拒绝且原文件逐字节不变、依赖图未知/自依赖/环拒绝、
#       前向引用允许、Optional 参与环校验、apply/set/import/snapshot 接入、
#       Legacy 零影响、POSIX）
#   L2  tests/p5-condition/test.sh P5-02 Condition 运算符扩展语法冻结（新运算符
#       < > <= >=（仅 time.*）/ contains（仅 task.state/env.*）适用矩阵、类型与
#       空值/非法值语义、注入面新规则；positive/negative/positive-p5 fixtures；
#       生产代码零改动，新运算符实现与既有断言反转归 P5-03）
#   L2  tests/p5-trigger/test.sh   P5-04 新 Trigger Schema 与持久化（schema-enum/
#       schema-reject/persist/editor/legacy-zero：boot_completed、oneshot:HHMM、
#       delay:MIN、interval:MIN、cron 五段冻结校验；Managed 写路径持久化 + B9
#       原子性；B16 legacy 零触碰；既有家族不回归）
#   L2  tests/p5-webui/test.sh P5-06 WebUI 实时状态增强（counts.recovering +
#       detail condition_state/last_event 后端只增键 B8、前端周期刷新/错误保留/
#       WAITING/RECOVERING 渲染静态断言、只读零 exec、前端无 innerHTML/eval、
#       read-only/security 关键断言不回归）
#   L2  tests/p1-regression/test.sh     P1 跨层集成（44 断言）
#   L4  tests/p1-build/build_check.sh   构建+八处版本一致性
# 可选 L3：--with-device 追加 tests/p1-device/smoke.sh（真实 Android 冒烟；
#   无 adb/设备时明示 DEVICE_SKIPPED 不计失败）。
# 判定（AGENTS §4）：输出不得出现 [FAIL]；全部通过 → exit 0。
# 可追溯（P2-01 出口）：完整逐层输出落盘
#   tests/results/run_tests-<时间戳>.log（*.log 已被 .gitignore 忽略，
#   不污染工作树），结尾打印日志路径与逐层汇总。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/.." || exit 2   # 仓库根

WITH_DEVICE=0
LINT_ONLY=0
case "${1:-}" in
    --with-device) WITH_DEVICE=1 ;;
    --lint-only)   LINT_ONLY=1 ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="tests/results"
mkdir -p "$RESULT_DIR"
LOG="$RESULT_DIR/run_tests-$TS.log"
: > "$LOG"

ok=1
# D-P5-02：单套件超时上限（秒，可经 SUITE_TIMEOUT 覆盖）。此前 providers/action-run
# 的后台孤儿子进程（start 子 shell 未脱离管道）可令 out=$(bash ...) 永久阻塞 → 整个
# 全量回归挂起。现在改为输出落临时文件 + 超时强杀，任何套件挂起最多阻塞一个超时上限。
SUITE_TIMEOUT=${SUITE_TIMEOUT:-300}

run_suite() {   # <path> [<timeout>]：捕获输出，计数 [FAIL] 与退出码；超时强杀记 FAIL
    # D-P5-04：设备套件（p1-device 含 2×150s 睡眠等）可超过通用 300s 上限，经第 2 参
    # 覆盖超时（默认 SUITE_TIMEOUT）。p1-device 在 --with-device 组合跑时被 300s 强杀
    # 致必 FAIL（standalone 全绿）——测试基建问题，非产品缺陷。
    suite_to=${2:-$SUITE_TIMEOUT}
    echo "== $1 ==" | tee -a "$LOG"
    tmp=$(mktemp "$RESULT_DIR/.suite.XXXXXX") || { ok=0; echo "[FAIL] mktemp failed" | tee -a "$LOG"; echo "" >> "$LOG"; return; }
    bash "$1" > "$tmp" 2>&1 &
    spid=$!
    i=0
    while [ "$i" -lt "$suite_to" ] && kill -0 "$spid" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    if [ "$i" -ge "$suite_to" ] && kill -0 "$spid" 2>/dev/null; then
        kill "$spid" 2>/dev/null
        j=0
        while [ "$j" -lt 5 ] && kill -0 "$spid" 2>/dev/null; do
            sleep 1; j=$((j + 1))
        done
        if kill -0 "$spid" 2>/dev/null; then
            kill -9 "$spid" 2>/dev/null
            # �� wait�����������ڲ����ж��������� FIFO open D-state����wait ��������
            # ���𣻽�ʬ�ɱ��ű��˳�ʱ���գ��ȷ��к����׼���
        else
            wait "$spid" 2>/dev/null
        fi
        ok=0
        echo "[FAIL] suite TIMEOUT after ${suite_to}s: $1" | tee -a "$LOG"
        echo "--- last lines of output ---" | tee -a "$LOG"
        tail -20 "$tmp" | tee -a "$LOG"
        rm -f "$tmp"
        echo "" >> "$LOG"
        return
    fi
    wait "$spid"
    rc=$?
    out=$(cat "$tmp")
    rm -f "$tmp"
    fails=$(printf '%s\n' "$out" | grep -c '\[FAIL\]' || true)
    printf '%s\n' "$out" | tail -1 | tee -a "$LOG"
    printf '%s\n' "$out" >> "$LOG"
    if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
        ok=0
        printf '%s\n' "$out" | grep '\[FAIL\]' | head -10 | tee -a "$LOG"
    fi
    echo "" >> "$LOG"
}

if [ "$LINT_ONLY" -eq 1 ]; then
    run_suite "tests/lint/syntax.sh"
else
    run_suite "tests/lint/syntax.sh"
    run_suite "tests/legacy/golden.sh"
    run_suite "tests/legacy/delete-pipeline.sh"
    run_suite "tests/cli/test.sh"
    for suite in \
        "tests/state-machine/test.sh" \
        "tests/providers/test.sh" \
        "tests/legacy-adapter/test.sh" \
        "tests/task-registry/test.sh" \
        "tests/scheduling/trigger-decision/test.sh" \
        "tests/execution/action-run/test.sh" \
        "tests/runtime/test.sh" \
        "tests/lifecycle/test.sh" \
        "tests/task-cli/test.sh" \
        "tests/runtime-lib/test.sh" \
        "tests/shadow/test.sh" \
        "tests/idmap/test.sh" \
        "tests/trigger/test.sh" \
        "tests/action/test.sh" \
        "tests/state/test.sh" \
        "tests/task-cli-prod/test.sh" \
        "tests/lifecycle-prod/test.sh" \
        "tests/app-action/test.sh" \
        "tests/health/test.sh" \
        "tests/supervisor/test.sh" \
        "tests/recovery/test.sh" \
        "tests/crashguard/test.sh" \
        "tests/p2-integration/test.sh" \
        "tests/p2-install/test.sh" \
        "tests/config-v2/test.sh" \
        "tests/config-v2/validation.sh" \
        "tests/scheduler-prod/test.sh" \
        "tests/ipc/test.sh" \
        "tests/ipc/security.sh" \
        "tests/webui/read-only.test.sh" \
        "tests/webui/security.test.sh" \
        "tests/webui/editor.test.sh" \
        "tests/task-control/test.sh" \
        "tests/security/fuzz.sh" \
        "tests/security/path-validation.sh" \
        "tests/security/permission.sh" \
        "tests/resource/stress.sh" \
        "tests/p3-integration/test.sh" \
        "tests/p4-dependency/test.sh" \
        "tests/p5-condition/test.sh" \
        "tests/p5-trigger/test.sh" \
        "tests/p5-webui/test.sh" \
        "tests/p6-webui/test.sh" \
        "tests/p1-regression/test.sh" \
        "tests/p1-build/build_check.sh"; do
        run_suite "$suite"
    done
    if [ "$WITH_DEVICE" -eq 1 ]; then
        # D-P5-04：设备套件超时放大（p1-device 含 2×150s 睡眠、p3-device 多轮 daemon
        # 重启），默认 300s 组合跑必强杀 → 单独给足 900s。
        run_suite "tests/p1-device/smoke.sh" 900
        run_suite "tests/p3-device/smoke.sh" 900
    fi
fi

echo "──────────────────────────────────────────────────────────────────────"
if [ "$ok" -eq 1 ]; then
    echo "ALL SUITES GREEN (L1+L2+L4 host regression; device optional: see p1-device/p3-device)"
else
    echo "FAILURES PRESENT"
fi
echo "trace log: $LOG"
[ "$ok" -eq 1 ] && exit 0 || exit 1