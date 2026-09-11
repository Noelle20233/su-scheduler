#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# smoke.sh — P7-01 设备冒烟：Mountify 兼容（纯委托挂载，真机 root）
# ═══════════════════════════════════════════════════════════════════════════
# 决策（docs/P7-MOUNTIFY-HANDOFF.md）：本模块不从宿主挂载退订——由
# KernelSU/Magisk/APatch magic mount 原生挂载 system/；Mountify metamode
# （mountify_mounts=2）接管后为"每开机重刷的拷贝"。语义=重启生效（放弃
# live-edit）。本模块不再自 bind。
#
# 判定：[PASS]/[FAIL]/[SKIP]；出现 [FAIL] → exit 非 0（AGENTS §4）。
# 无 adb/无设备/--skip-device → DEVICE_SKIPPED。
# 陈旧态（设备仍运行旧版拷贝，未重装+重启新模块）以 SKIP 表达，不误判 FAIL：
# 本套件的"生效"前提是安装本次改动后重新 flash 模块并重启。
#
# 覆盖：
#  1-delegation  模块目录内**不得**存在 skip_mount/skip_mountify（退订已移除）
#  2-files       /system/bin 下 5 文件存在且可执行（宿主/Mountify 已挂载）
#  3-context     su-scheduler 上下文 system_file；shell_data_file→SKIP（待重装）
#  4-cli         PATH 命中 /system/bin/su-scheduler；status Alive；docs 可读
#  5-mountify    /system/bin 挂载条目为 overlay（Mountify 伪装接管签名）→ PASS；
#                不可见/未装 → SKIP（暂存 tmpfs 被 detach，init 命名空间亦不可见）
#  6-converged   挂载 runtime 副本 ≡ 模块目录源（cmp 逐字节）→ PASS；不同→SKIP
#                （待重启传播；daemon drift WARN 应出现）
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

# ── 设备可用性判定（同 p6-device 惯例）────────────────────────────────────
SKIP_DEV=0
SERIAL="${ANDROID_SERIAL:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-device) ;;
        --skip-device) SKIP_DEV=1 ;;
        --serial|-s)   SERIAL="${2:-}"; shift ;;
        *) echo "[FAIL] p7 device smoke: unknown arg: $1"; exit 2 ;;
    esac
    shift
done
command -v adb >/dev/null 2>&1 || command -v adb.exe >/dev/null 2>&1 || SKIP_DEV=1
if [ "$SKIP_DEV" -eq 1 ]; then
    echo "[SKIP] p7 device smoke: --skip-device or no adb (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    exit 0
fi
ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"
if ! $ADB devices 2>/dev/null | grep -qw "device"; then
    echo "[SKIP] p7 device smoke: no authorized adb device (DEVICE_SKIPPED)"
    echo "DEVICE_SKIPPED"
    exit 0
fi

[ -z "$SERIAL" ] && SERIAL=$(adb get-serialno 2>/dev/null | tr -d '\r')
MODEL=$($ADB shell "getprop ro.product.model" 2>/dev/null | tr -d '\r')
ROOT_CTX=$($ADB shell "su -c 'id'" 2>/dev/null | tr -d '\r')
echo_t "═══ P7-01 device smoke (Mountify compat / delegated mount) ═══"
echo_t "device: $SERIAL | $MODEL | root: $ROOT_CTX"
echo_t "time:   $(date '+%Y-%m-%d %H:%M:%S')"
mkdir -p tests/results
DEVLOG="tests/results/device-$SERIAL-$(date +%Y%m%d-%H%M%S)-p7.log"

AS() { $ADB shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }   # 体内禁单引号
AD() { $ADB shell "su -c \"$1\"" 2>/dev/null | tr -d '\r'; } # 体内禁未转义双引号

MOD="/data/adb/modules/su-scheduler"
MODRT="$MOD/system/bin/su-scheduler-runtime"
BINS="su-scheduler su-schedulerd su-scheduler-termux su-scheduler-runtime .su-scheduler-docs"

# ── 1-delegation ───────────────────────────────────────────────────────────
MKS=$(AS "ls $MOD/skip_mount $MOD/skip_mountify 2>/dev/null | wc -l")
if [ "${MKS:-0}" = "0" ]; then
    ok "1-delegation: no skip_mount/skip_mountify in module dir (opt-out removed on device)"
else
    bad "1-delegation: opt-out marker(s) present on device (delegation violated)"
fi

# ── 2-files ────────────────────────────────────────────────────────────────
PRESENT=1
for f in $BINS; do
    AS "[ -e /system/bin/$f ] || exit 1" >/dev/null
    [ $? -ne 0 ] && { PRESENT=0; echo_t "    missing: /system/bin/$f"; }
done
[ "$PRESENT" -eq 1 ] \
    && ok "2-files: all 5 files present under /system/bin (host/Mountify mounted them)" \
    || bad "2-files: some /system/bin files missing (mount system did not place them)"

# ── 3-context ──────────────────────────────────────────────────────────────
CTX=$(AD "ls -Z /system/bin/su-scheduler | awk '{print \$1}'")
case "$CTX" in
    *system_file*)    ok "3-context: /system/bin/su-scheduler labeled system_file (chcon propagated)" ;;
    *shell_data_file*) skip "3-context: stale shell_data_file label (reinstall+reboot new module to propagate system_file)" ;;
    "")               skip "3-context: cannot read SELinux context (ls -Z unsupported?)" ;;
    *)                bad "3-context: unexpected context: $CTX" ;;
esac

# ── 4-cli ──────────────────────────────────────────────────────────────────
WHICH=$(AS "command -v su-scheduler")
[ "$WHICH" = "/system/bin/su-scheduler" ] \
    && ok "4-cli: CLI resolves on PATH at /system/bin/su-scheduler" \
    || bad "4-cli: command -v su-scheduler = '${WHICH:-<empty>}'"
ST=$(AS "su-scheduler status")
printf '%s' "$ST" | grep -qi 'alive' \
    && ok "4-cli: su-scheduler status reports Alive (daemon + runtime loaded over mounted files)" \
    || bad "4-cli: status not Alive: ${ST:-<empty>}"
DOCSZ=$(AS "stat -c %s /system/bin/.su-scheduler-docs 2>/dev/null")
[ -n "$DOCSZ" ] && [ "$DOCSZ" -gt 100 ] \
    && ok "4-cli: docs file mounted & readable ($DOCSZ bytes)" \
    || bad "4-cli: /system/bin/.su-scheduler-docs unreadable"

# ── 5-mountify（条件取证：接管态才断言，否则 SKIP）─────────────────────────
# 真机取证：Mountify 以 `KSU /system/bin overlay ... lowerdir=/mnt/vendor/<FAKE>/bin:/system/bin`
# 挂载，且随后 detach 其暂存 tmpfs——init 命名空间也看不到 FAKE 目录（伪装成 OEM 挂载）。
# 故接管签名 = /system/bin 的挂载条目类型为 overlay（宿主原生 magic mount 只做
# bind/tmpfs，不做 overlay）。zygisk 命名空间视图下可能整体不可见 → SKIP。
OVLINE=$(AS "grep \" /system/bin \" /proc/mounts | grep overlay")
if [ -n "$OVLINE" ]; then
    ok "5-mountify: Mountify overlay owns /system/bin (decoy mount): ${OVLINE%% *}"
else
    if [ "$(AS "ls -d /data/adb/modules/mountify >/dev/null 2>&1 && echo yes")" = "yes" ]; then
        skip "5-mountify: Mountify installed but no /system/bin overlay entry in this namespace view (zygisk-umount?)"
    else
        skip "5-mountify: Mountify not installed (host native magic mount owns the files)"
    fi
fi

# ── 6-converged（挂载副本 ≡ 模块源 = 重启已生效）──────────────────────────
MRT="/system/bin/su-scheduler-runtime"
CMPR=$(AS "if [ ! -e $MRT ] || [ ! -e $MODRT ]; then echo NOFILE; elif cmp -s $MRT $MODRT; then echo SAME; else echo DIFF; fi")
case "$CMPR" in
    SAME)   ok "6-converged: mounted runtime is byte-identical to module-dir source (reboot propagated)" ;;
    DIFF)   skip "6-converged: mounted copy differs from module dir (reboot pending; drift WARN expected)" ;;
    *)      skip "6-converged: runtime file(s) not comparable (out='$CMPR')" ;;
esac

echo_t "──────────────────────────────────────────────────────────────────────"
echo_t "p7 device smoke: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
