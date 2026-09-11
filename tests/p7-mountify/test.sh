#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P7-01 Mountify 兼容（纯委托挂载）L2
# ═══════════════════════════════════════════════════════════════════════════
# 决策（见 docs/P7-MOUNTIFY-HANDOFF.md）：本模块**不**从宿主挂载系统退订。
# KernelSU/Magisk/APatch 的 magic mount 原生挂载 system/；Mountify metamodule
# （metamode / mountify_mounts=2）接管后是"每开机重刷的拷贝"。二者语义均为
# **重启生效**（放弃 live-edit）。因此本模块不再写 skip_mount/skip_mountify、
# 不再自 bind。customize.sh 仅 chcon 源文件为 system_file（宿主 bind 带源
# 标签、Mountify 镜像源标签，标正才不留 shell_data_file 脏标签）。
# su-schedulerd 加 runtime_drift_check（仅记日志：模块目录版本≠/system/bin
# 版本时提示待重启，纯诊断零行为改动）。
#
# 断言：
#   静态 1) customize.sh：skip_mount/skip_mountify 零出现；chcon 覆盖 5 文件；
#         既有安装契约（SKIPUNZIP / system/* 解包 / set_perm）不回归
#   静态 2) service.sh：self_mount/SS_BINS/mount -o bind 零出现；无任何
#         mount/umount 命令行首调用；MODDIR 回退保留（C2）；委托注释在位
#   静态 3) su-schedulerd：runtime_drift_check 定义+调用各一次；含版本比对；
#         无任何 mount/umount 命令行首调用（C2/C3 核查）
#   静态 4) 回归入口已注册本套件与设备套件
#   行为 5) runtime_drift_check 单测：漂移→写 WARN；等值→零写；未加载→零写；
#         模块文件不可读→优雅零写
# 判定（AGENTS §4）：出现 [FAIL] → exit 非 0。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CUST=customize.sh
SVC=service.sh
DAEM=system/bin/su-schedulerd
BINS='su-scheduler su-schedulerd su-scheduler-termux su-scheduler-runtime .su-scheduler-docs'

# ── 静态 1) customize.sh：opt-out 彻底移除 + chcon 标签 + 契约不回归 ───────
[ "$(grep -c 'skip_mount' "$CUST")" -eq 0 ] \
    && ok "P7-01 cust: no skip_mount/skip_mountify (opt-out removed)" \
    || bad "P7-01 cust: skip marker token still present in customize.sh"
grep -qF 'chcon u:object_r:system_file:s0' "$CUST" \
    && ok "P7-01 cust: chcon system_file label loop present" \
    || bad "P7-01 cust: chcon label loop missing"
[ "$(grep -c 'for SS_BIN in su-scheduler su-schedulerd su-scheduler-termux su-scheduler-runtime' "$CUST")" -eq 1 ] \
    && ok "P7-01 cust: chcon loop covers the 5 binaries (once)" \
    || bad "P7-01 cust: chcon loop list drift"
CONTRACT_OK=1
for pat in '^SKIPUNZIP=1' 'system/\*' 'set_perm_recursive'; do
    grep -q "$pat" "$CUST" || { CONTRACT_OK=0; bad "P7-01 cust: existing install contract regressed ($pat)"; }
done
[ "$CONTRACT_OK" -eq 1 ] && ok "P7-01 cust: SKIPUNZIP/extract/set_perm intact"

# ── 静态 2) service.sh：无自挂载、无 mount 调用、回退保留、委托注释在位 ────
[ "$(grep -c 'self_mount' "$SVC")" -eq 0 ] \
    && ok "P7-01 svc: self_mount fully removed" \
    || bad "P7-01 svc: self_mount residue"
[ "$(grep -c 'SS_BINS' "$SVC")" -eq 0 ] \
    && ok "P7-01 svc: SS_BINS removed (no per-file bind list)" \
    || bad "P7-01 svc: SS_BINS residue"
[ "$(grep -c 'mount -o bind' "$SVC")" -eq 0 ] \
    && ok "P7-01 svc: no 'mount -o bind' call site" \
    || bad "P7-01 svc: bind call site still present"
[ "$(grep -c 'skip_mount' "$SVC")" -eq 0 ] \
    && ok "P7-01 svc: no skip marker handling" \
    || bad "P7-01 svc: skip marker handling residue"
if grep -qE '^[[:space:]]*(mount|umount)[[:space:]]' "$SVC"; then
    bad "P7-01 svc: a mount/umount command line exists (delegation violated)"
else
    ok "P7-01 svc: no mount/umount command line (mounting fully delegated)"
fi
grep -qF 'DAEMON="$MODDIR/system/bin/su-schedulerd"' "$SVC" \
    && ok "P7-01 svc: C2 MODDIR fallback path intact (unmounted/boot-early safety net)" \
    || bad "P7-01 svc: MODDIR fallback removed"
grep -qiF 'delegated to the host mount system' "$SVC" \
    && ok "P7-01 svc: delegation rationale documented inline" \
    || bad "P7-01 svc: delegation comment missing"

# ── 静态 3) su-schedulerd：漂移诊断在位、无 mount 调用 ─────────────────────
[ "$(grep -c '^runtime_drift_check() {' "$DAEM")" -eq 1 ] \
    && [ "$(grep -c '^runtime_drift_check$' "$DAEM")" -eq 1 ] \
    && ok "P7-01 daemon: runtime_drift_check defined once, called once" \
    || bad "P7-01 daemon: runtime_drift_check def/call count wrong"
grep -qF 'Runtime version drift' "$DAEM" \
    && ok "P7-01 daemon: drift WARN string present" \
    || bad "P7-01 daemon: drift WARN string missing"
grep -qF '/data/adb/modules/su-scheduler/system/bin/su-scheduler-runtime' "$DAEM" \
    && ok "P7-01 daemon: drift check reads module-dir source (manager-agnostic via module id)" \
    || bad "P7-01 daemon: drift module source path missing"
if grep -qE '^[[:space:]]*(mount|umount)[[:space:]]' "$DAEM"; then
    bad "P7-01 daemon: mount/umount command present (forbidden)"
else
    ok "P7-01 daemon: no mount/umount command line"
fi

# ── 静态 4) 回归入口注册 ───────────────────────────────────────────────────
grep -qF 'tests/p7-mountify/test.sh' tests/run_tests.sh \
    && ok "P7-01 wire: L2 suite registered in run_tests.sh" \
    || bad "P7-01 wire: L2 suite not registered"
grep -qF 'tests/p7-device/smoke.sh' tests/run_tests.sh \
    && ok "P7-01 wire: device suite registered in run_tests.sh" \
    || bad "P7-01 wire: device suite not registered"

# ── 行为 5) runtime_drift_check 单元（可宿主机运行，无需设备）──────────────
sed -n '/^runtime_drift_check() {/,/^}/p' "$DAEM" > "$TMP/drift.sh"
if [ ! -s "$TMP/drift.sh" ]; then
    bad "P7-01 behavior: runtime_drift_check not extractable"
else
    # shellcheck disable=SC1090
    . "$TMP/drift.sh"

    printf 'RUNTIME_LIB_VERSION="9.9.9"\n' > "$TMP/rt_mod"

    # 5a) 漂移：加载版本 1.32.0 ≠ 模块目录 9.9.9 → 写 WARN
    RUNTIME_LOADED=1; RUNTIME_LIB_VERSION="1.32.0"; SS_MODRT="$TMP/rt_mod"; LOG_FILE="$TMP/ev"
    : > "$LOG_FILE"
    runtime_drift_check
    if grep -q 'Runtime version drift' "$LOG_FILE" \
       && grep -q 'mounted v1.32.0' "$LOG_FILE" \
       && grep -q 'module-dir v9.9.9' "$LOG_FILE"; then
        ok "P7-01 behavior: drift detected -> WARN logged (mounted v1.32.0 != module-dir v9.9.9)"
    else
        bad "P7-01 behavior: drift not logged correctly ($(cat "$LOG_FILE"))"
    fi

    # 5b) 等值：加载版本 == 模块目录版本 → 零写（收敛态无噪声）
    RUNTIME_LIB_VERSION="9.9.9"; : > "$LOG_FILE"
    runtime_drift_check
    [ ! -s "$LOG_FILE" ] \
        && ok "P7-01 behavior: versions equal -> no log line (converged state silent)" \
        || bad "P7-01 behavior: equal versions wrongly logged ($(cat "$LOG_FILE"))"

    # 5c) 未加载 Runtime → 早退零写（不干扰 legacy 路径）
    RUNTIME_LOADED=0; : > "$LOG_FILE"
    runtime_drift_check
    [ "$?" -eq 0 ] && [ ! -s "$LOG_FILE" ] \
        && ok "P7-01 behavior: RUNTIME_LOADED=0 -> graceful no-op (legacy path untouched)" \
        || bad "P7-01 behavior: not-loaded path wrongly acted"
    RUNTIME_LOADED=1

    # 5d) 模块文件不可读 → 早退零写（无 /data/adb 访问不崩）
    SS_MODRT="$TMP/does-not-exist"; : > "$LOG_FILE"
    runtime_drift_check
    [ "$?" -eq 0 ] && [ ! -s "$LOG_FILE" ] \
        && ok "P7-01 behavior: missing module file -> graceful no-op" \
        || bad "P7-01 behavior: missing-file path not graceful"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p7-mountify tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
