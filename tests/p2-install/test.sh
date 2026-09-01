#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P2 发布评审：KernelSU/Magisk/APatch 安装结构验证（P2-15）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；出现 [FAIL] → exit 非 0。
# 覆盖（P2-15 出口：KernelSU/Magisk/APatch 基础安装验证 + 发布包结构）：
#   三管理器共享同一 systemless 模块契约：安装至 /data/adb/modules/<id>/，
#   system/ 覆盖 /system，customize.sh 负责安装。此处主机侧验证该契约所依赖的
#   发布产物结构全部就位（构建 zip 内含全部成员；非 LF 检出时对源树断言同一契约
#   以避免 CRLF 检出下无法执行构建——CI/LF 为构建闸，同 p1-build 语义）：
#   1) module.prop：id=su-scheduler，name/version/author/description 就位
#      （三管理器读取的元数据事实源）。
#   2) customize.sh：SKIPUNZIP=1 + 提取 system/* / service.sh / module.prop 到
#      $MODPATH + 数据目录（/data/adb/su-scheduler）与用户目录自建——通用安装器
#      契约（KernelSU/Magisk/APatch 均执行 customize.sh）入口锚点。
#   3) service.sh：开机服务（FBE 等待 + 既有看护）就位（各管理器启动阶段执行）。
#   4) system/ 覆盖：system/bin/su-scheduler / su-schedulerd / su-scheduler-termux
#      / su-scheduler-runtime 在 zip（或源树）中，对应安装至 /data/adb/modules/
#      su-scheduler/system/bin/（systemless 覆盖已满足）。
#   5) 数据/配置独立于模块目录：DATA_DIR=/data/adb/su-scheduler、
#      config 于 /sdcard/Documents/su-scheduler/（模块卸载不丢数据——三管理器
#      卸载仅清模块目录）。
#   6) 三管理器皆以模块目录为部署目标：校验产物以 id 为模块目录名、无硬编码
#      管理器专属路径（非 manager-agnostic 的 install 属发布缺陷）。
#   7) 汇总与退出。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }
skip(){ SKIP=$((SKIP + 1)); echo "[SKIP] $1"; }

# ── CRLF 检出语义（同 p1-build：CRLF 下不可执行构建，对源树断言同一契约）────
CRLF_TREE=0
grep -q "$(printf '\r')" customize.sh && CRLF_TREE=1

if [ "$CRLF_TREE" -eq 0 ]; then
    # 用 p1-build 相同基准构建 zip 供结构断言
    NV=$(sed -n 's/^VERSION="\(.*\)"/\1/p' build.sh | tr -d '\r')
    rm -f "su-scheduler-$NV.zip" 2>/dev/null
    bash build.sh >/dev/null 2>&1
    ZIP="su-scheduler-$NV.zip"
    if [ -n "$(ls "$ZIP" 2>/dev/null)" ] && [ -s "$ZIP" ]; then
        ok "P2-15 install: build.zip present ($NV, $(wc -c < "$ZIP") bytes)"
    else
        bad "P2-15 install: zip missing after build"
    fi
else
    skip "P2-15 install: CRLF worktree — build execution skipped (CI/LF is the build gate); asserting source tree contract only"
fi

# helper：成员是否存在（zip 成员 or 源树文件）
member_tree() {   # <path-in-module>
    if [ "$CRLF_TREE" -eq 0 ]; then
        unzip -l "$ZIP" 2>/dev/null | grep -q " $1$"
    else
        [ -f "$1" ]
    fi
}

MGRS="KernelSU Magisk APatch"
id=$(sed -n 's/^id=\(.*\)/\1/p' module.prop | tr -d '\r')
[ "$id" = "su-scheduler" ] && ok "P2-15 install: module id=su-scheduler ($MGRS 模块目录名)" || bad "P2-15 install: module id=$id (expect su-scheduler)"

# ── 1) module.prop 元数据 ──────────────────────────────────────────────────
for key in "name=" "version=" "versionCode=" "author=" "description=" "updateJson="; do
    grep -q "^$key" module.prop || { bad "P2-15 install: module.prop missing $key"; done_key="1"; }
done
[ -z "${done_key:-}" ] && ok "P2-15 install: module.prop metadata keys complete ($MGRS)" || bad "P2-15 install: module.prop incomplete"
unset done_key
grep -qi "Magisk.*KernelSU.*APatch" module.prop \
    && ok "P2-15 install: description declares Magisk/KernelSU/APatch support" || bad "P2-15 install: manager coverage not declared in description"

# ── 2) customize.sh 通用安装器契约 ─────────────────────────────────────────
grep -q '^SKIPUNZIP=1' customize.sh && ok "P2-15 install: customize.sh SKIPUNZIP=1 (manual sysless install)" || bad "P2-15 install: SKIPUNZIP missing"
for pat in "system/*" "service.sh" "module.prop"; do
    grep -q "$pat" customize.sh || { bad "P2-15 install: customize.sh missing extract $pat"; ex1="1"; }
done
[ -z "${ex1:-}" ] && ok "P2-15 install: customize.sh extracts system|service.sh|module.prop to \$MODPATH" || bad "P2-15 install: customize.sh extract incomplete"
unset ex1
grep -q '/data/adb/su-scheduler' customize.sh && ok "P2-15 install: DATA_DIR=/data/adb/su-scheduler (module-independent vault)" || bad "P2-15 install: DATA_DIR not set in customize.sh"
grep -q '/sdcard/Documents/su-scheduler' customize.sh && ok "P2-15 install: config under /sdcard/Documents/su-scheduler (persistent user doc)" || bad "P2-15 install: user config dir not set"

# ── 3) service.sh 开机服务 ─────────────────────────────────────────────────
if [ "$CRLF_TREE" -eq 0 ]; then
    member_tree "service.sh" && ok "P2-15 install: zip contains service.sh (boot service for $MGRS)" || bad "P2-15 install: service.sh missing in zip"
else
    [ -f service.sh ] && ok "P2-15 install: service.sh present in source tree ($MGRS boot service)" || bad "P2-15 install: service.sh missing"
fi

# ── 4) system/ 覆盖（systemless）───────────────────────────────────────────
sys_ok=1
for bin in su-scheduler su-schedulerd su-scheduler-termux su-scheduler-runtime; do
    if [ "$CRLF_TREE" -eq 0 ]; then
        unzip -l "$ZIP" 2>/dev/null | grep -q " system/bin/$bin$" || sys_ok=0
    else
        [ -f "system/bin/$bin" ] || sys_ok=0
    fi
done
[ "$sys_ok" -eq 1 ] && ok "P2-15 install: system/bin/{su-scheduler,su-schedulerd,su-scheduler-termux,su-scheduler-runtime} ship ($MGRS systemless overlay)" || bad "P2-15 install: system/bin members incomplete"

# ── 5) 无管理器专属安装路径（manager-agnostic）─────────────────────────────
mgr_spec=0
for p in magisk ksu kenzy apatch; do
    grep -rqi "/data/adb/$p" customize.sh 2>/dev/null && mgr_spec=$((mgr_spec + 1))
done
[ "$mgr_spec" -eq 0 ] && ok "P2-15 install: customize.sh has NO manager-specific /data/adb/<mgr> path (manager-agnostic, dir=module id)" || bad "P2-15 install: $mgr_spec manager-specific path(s)"
grep -q 'MODPATH' customize.sh && ok "P2-15 install: installer uses \$MODPATH (manager-injected module dir)" || bad "P2-15 install: MODPATH not used"

# ── 6) 还原工作树（仅 LF 环境跑过构建时需要）───────────────────────────────
if [ "$CRLF_TREE" -eq 0 ]; then
    rm -f "$ZIP"
    git checkout -- system/bin/.su-scheduler-docs 2>/dev/null
    [ -z "$(git status --porcelain -- system/bin/.su-scheduler-docs)" ] && ok "P2-15 install: workspace restored (zip + .su-scheduler-docs cleaned)" || bad "P2-15 install: workspace dirty after build"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p2-install tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1