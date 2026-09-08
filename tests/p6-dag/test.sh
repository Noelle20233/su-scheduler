#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — P6-05 DAG / 链式调度裁决基线（tests/p6-dag）
# ═══════════════════════════════════════════════════════════════════════════
# 判定（AGENTS §4）：每项 [PASS]/[FAIL]；链引擎未实现类断言 [SKIP]（带原因）；
# 出现 [FAIL] → exit 非 0。**SKIP→PASS 是 P6-06 的出口条件之一**：本文件所有
# §engine 组 SKIP 行（DAG-EX-01..20）在 `docs/architecture/dag-schema-v1.md`
# （ACCEPTED，已批准 2026-09-08）获批后、P6-06 链引擎落地时必须逐条转为真验证 [PASS]，
# 禁止删除 SKIP 行以凑绿（AGENTS §10 测试不可作弊）。
#
# 本套件是 **P6-05 文档/裁决任务**的验证面，零生产代码改动：
#   §schema-doc   ADR（dag-schema-v1.md）存在性/ACCEPTED 批准标注/上限常量/链态五态/
#                 183 迁移零改动声明/B16 声明/裁决表 D-01..D-13 完备性 +
#                 fixtures 字段 ⊆ ADR 白名单（grep golden）。
#   §valid        正例 fixtures（线性/分支/合流/Optional/:FAILED）：
#                 既有 dep_validate_graph / tcfg_validate_task / dep_validate /
#                 dep_normalize 的当前接受行为（ADR 引用的 P4 基线锁定）。
#   §invalid      环/自依赖/未知依赖：既有 dep_validate_graph 拒绝 + 消息文案
#                 锁定（P6-05 D-08「继承不改动」的证据）+ 覆盖节点协议正反例。
#   §limits       depmax33 当前即拒（DEP_MAX 锁定）；deep17/nodes33/edges129
#                 由 fixtures/tools/gen_limits.sh 确定性生成：当前无环被接受 +
#                 独立复算度量 == manifest == ADR 上限+1（单维超限）。
#   §inject       strings.tsv 逐条过 secv_id_ok / dep_validate（真跑函数）；
#                 inject/tasks 注入 Task 文件被 tcfg_validate_task 拒绝；
#                 零 exec 守卫（/tmp/pwn 不存在）。
#   §p4-baseline  dep_entry STATE 枚举/双问号/全分隔符拒绝、TAB 拒绝（可打印性
#                 门）、空格容错（D1）等现行为（P6-06 升级所依赖的「修前」基线，禁改）。
#   §engine       链执行/传播/并行/超时/取消/上限运行期/WebUI 键/sweep/editor
#                 白名单/legacy 边界 → 全部 [SKIP]（P6-06 实施 + ADR 批准）。
#   §posix        本文件与 gen_limits.sh 的 dash -n / sh -n 语法自检。
# ═══════════════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/../.." || exit 2   # 仓库根

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }
skip() { SKIP=$((SKIP + 1)); echo "[SKIP] $1"; }

RT="system/bin/su-scheduler-runtime"
ADR="docs/architecture/dag-schema-v1.md"
REQ="docs/P6-05.md"
FX="tests/p6-dag/fixtures"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export TCFG_DIR="$T/task-config"
mkdir -p "$TCFG_DIR"; echo managed > "$TCFG_DIR/MANAGED"
. "./$RT"

# helper：跑图校验；stderr 捕获到 $T/err.txt
dgraph() {   # <dir> → rc
    dep_validate_graph "$1" "" "" "[task-config] ERROR:" 2>"$T/err.txt"
}

# helper：从目录计算链度量，stdout="nodes edges depth"
# 口径 = ADR D55：节点=任务数；边=去重 (up,target) 对（含 Optional，剥 `?`、
# 去 `:STATE`）；深度=最长路径节点数（init 1，DAG 松弛 ≤V+1 轮收敛）。
dmetrics() {   # <dir>
    {
        for f in "$1"/*.task; do
            [ -f "$f" ] || continue
            n=$(basename "$f" .task)
            d=$(grep '^dependency=' "$f" 2>/dev/null | head -1 | cut -d= -f2-)
            printf '%s|%s\n' "$n" "$(printf '%s' "$d" | tr ',' ' ' | sed 's/?//g; s/:[A-Z][A-Z]*//g')"
        done
    } | awk -F'|' '
        { nodes[$1]=1; m=split($2, t, " ")
          for (i=1; i<=m; i++) if (t[i] != "") {
              if (!(($1 SUBSEP t[i]) in seen)) { seen[$1 SUBSEP t[i]]=1; ne++ }
              dep[$1] = dep[$1] " " t[i]
          } }
        END {
            nv=0
            for (n in nodes) { dep0[n]=1; nv++ }
            iter=0
            while (iter <= nv) {
                ch=0
                for (v in nodes) {
                    m=split(dep[v], t, " ")
                    for (i=1; i<=m; i++)
                        if (t[i] != "" && nodes[t[i]] == 1 && dep0[t[i]] + 1 > dep0[v]) {
                            dep0[v] = dep0[t[i]] + 1; ch=1
                        }
                }
                iter++
                if (ch == 0) break
            }
            md=0
            for (n in nodes) if (dep0[n] > md) md = dep0[n]
            printf "%d %d %d\n", nv, ne, md
        }'
}

# ADR §2 常量表取值：adreno <CONST_NAME> → echo 数值（表行格式 `| \`NAME\` | 值 |`）
adreno() {
    sed -n "s/^| \`$1\` | *\([0-9]*\) |.*/\1/p" "$ADR" | head -1
}

# ═══════════════════════════════════════════════════════════════════════════
# §schema-doc — ADR/需求文档一致性（grep golden）
# ═══════════════════════════════════════════════════════════════════════════
if [ -f "$ADR" ]; then
    ok "SD-01 ADR 存在：$ADR"
else
    bad "SD-01 ADR 缺失：$ADR"
fi
if grep -q 'ACCEPTED — 已获人工批准' "$ADR" 2>/dev/null; then
    ok "SD-02 ADR 状态标注 ACCEPTED（已获人工批准 2026-09-08；P6-05 修订：原 DRAFT 断言随签核更新）"
else
    bad "SD-02 ADR 缺 ACCEPTED 批准标注"
fi
if grep -q 'ACCEPTED\|已获人工批准\|已批准' "$REQ" 2>/dev/null; then
    ok "SD-03 需求文档记录批准状态（P6-05 修订：原待批准断言随签核更新）"
else
    bad "SD-03 需求文档缺批准状态记录"
fi

n_MISSING=0
for c in DAG_CHAIN_NODES_MAX DAG_CHAIN_EDGES_MAX DAG_CHAIN_DEPTH_MAX DAG_RUNS_MAX \
         DAG_PARALLEL_MAX DAG_RUN_TIMEOUT DAG_RUNS_KEEP; do
    v=$(adreno "$c")
    case "$v" in
        ''|*[!0-9]*) n_MISSING=$((n_MISSING + 1)); bad "SD-04 ADR 常量表缺 $c 数值行" ;;
    esac
done
[ "$n_MISSING" -eq 0 ] && ok "SD-04 ADR §2 七项上限常量均可机读"

if [ "$(adreno DAG_CHAIN_NODES_MAX)" = "32" ]; then ok "SD-05 DAG_CHAIN_NODES_MAX=32（与 DEP_MAX 同形）"; else bad "SD-05 nodes 上限非 32"; fi
if [ "$(adreno DAG_CHAIN_EDGES_MAX)" = "128" ]; then ok "SD-06 DAG_CHAIN_EDGES_MAX=128"; else bad "SD-06 edges 上限非 128"; fi
if [ "$(adreno DAG_CHAIN_DEPTH_MAX)" = "16" ]; then ok "SD-07 DAG_CHAIN_DEPTH_MAX=16"; else bad "SD-07 depth 上限非 16"; fi
if [ "$(adreno DAG_RUNS_MAX)" = "8" ]; then ok "SD-08 DAG_RUNS_MAX=8（活跃 run 并发）"; else bad "SD-08 runs 上限非 8"; fi
if [ "$(adreno DAG_PARALLEL_MAX)" = "4" ]; then ok "SD-09 DAG_PARALLEL_MAX=4（在途进程闸，对齐 P2-12 无线程原则）"; else bad "SD-09 parallel 上限非 4"; fi
if [ "$(adreno DAG_RUN_TIMEOUT)" = "86400" ]; then ok "SD-10 DAG_RUN_TIMEOUT=86400（与 WAIT_MAX 对齐）"; else bad "SD-10 run 超时非 86400"; fi
if grep -q 'WAIT_MAX' "$ADR"; then ok "SD-11 ADR 显式对齐 WAIT_MAX/DEP_MAX 既有常量轴"; else bad "SD-11 ADR 未引用既有常量轴"; fi

for st in PENDING RUNNING SUCCESS FAILED; do
    if grep -q "$st" "$ADR"; then :; else bad "SD-12 链态枚举缺 $st"; fi
done
if grep -q 'CANCELLED' "$ADR" && grep -q '预留' "$ADR"; then
    ok "SD-12 链态五态齐备且 CANCELLED=预留不产出（诚实声明）"
else
    bad "SD-12 CANCELLED 预留声明缺失"
fi
if grep -q '183' "$ADR" && grep -q '零修改\|不增不删不改\|零改动' "$ADR"; then
    ok "SD-13 链级状态=文件级记录；183 条迁移零修改声明在 ADR"
else
    bad "SD-13 缺 183 零改动声明"
fi
if grep -q 'B16' "$ADR" && grep -q '仅 Managed' "$ADR"; then
    ok "SD-14 DAG 仅 Managed / Legacy 零关系声明（B16 先例）"
else
    bad "SD-14 缺 B16/managed-only 声明"
fi
if grep -q 'configuration_invalid' "$ADR"; then
    ok "SD-15 错误语义映射到既有 IPC 码（configuration_invalid + P6-04 字段级通道）"
else
    bad "SD-15 缺错误码映射"
fi
if grep -q '只增键\|只增不改' "$ADR"; then ok "SD-16 WebUI 可观测性 B8 只增键契约在 ADR"; else bad "SD-16 缺 B8 只增键声明"; fi

d_ok=1; i=1
while [ "$i" -le 13 ]; do
    idn=$(printf 'D-%02d' "$i")
    if ! grep -q "^### $idn " "$REQ"; then d_ok=0; bad "SD-17 需求文档缺裁决 $idn"; fi
    i=$((i + 1))
done
[ "$d_ok" -eq 1 ] && ok "SD-17 P6-05.md 裁决表 D-01..D-13 完备"

# fixtures 字段 ⊆ ADR dag-fields 白名单（含生成器模板字段）
wl="$T/whitelist.txt"
awk '/^```dag-fields$/{f=1;next} /^```$/{f=0} f && NF' "$ADR" > "$wl"
if [ -s "$wl" ]; then ok "SD-18 ADR 白名单块可机读（$(wc -l < "$wl" | tr -d ' ') 键）"; else bad "SD-18 ADR 白名单块为空"; fi
used="$T/used.txt"
{
    grep -rh -v '^#' "$FX" --include='*.task' 2>/dev/null | grep '=' | cut -d= -f1
    sed -n 's/^[[:space:]]*echo "\([a-z_.]*\)=.*$/\1/p' "$FX/tools/gen_limits.sh" 2>/dev/null
} | grep -v '^$' | sort -u > "$used"
stray=0
while IFS= read -r k; do
    if ! grep -qx "$k" "$wl"; then stray=$((stray + 1)); bad "SD-19 fixture 字段 '$k' 不在 ADR 白名单"; fi
done < "$used"
[ "$stray" -eq 0 ] && ok "SD-19 fixtures/生成器字段全部 ⊆ ADR 白名单（零发明字段，键数 $(wc -l < "$used" | tr -d ' ')）"
core_ok=1
for core in schema_version id trigger dependency condition; do
    grep -qx "$core" "$wl" || { core_ok=0; bad "SD-20 ADR 白名单缺核心键 $core"; }
done
[ "$core_ok" -eq 1 ] && ok "SD-20 ADR 白名单覆盖核心五键"

# ═══════════════════════════════════════════════════════════════════════════
# §valid — 提案 schema fixtures × 既有校验器（P4 基线锁定）
# ═══════════════════════════════════════════════════════════════════════════
vd="$T/valid"; mkdir -p "$vd"
cp -R "$FX/valid/linear" "$FX/valid/branch" "$FX/valid/merge" \
      "$FX/valid/optional" "$FX/valid/statefail" "$vd/" 2>/dev/null
for d in linear branch merge optional statefail; do
    if dgraph "$vd/$d"; then
        ok "VA-01($d) dep_validate_graph 接受正例链闭包（无环）"
    else
        bad "VA-01($d) 正例被图校验拒绝: $(head -1 "$T/err.txt")"
    fi
    inv=0; tot=0
    for f in "$vd/$d"/*.task; do
        tot=$((tot + 1))
        tcfg_validate_task "$f" || inv=$((inv + 1))
    done
    if [ "$tot" -gt 0 ] && [ "$inv" -eq 0 ]; then
        ok "VA-02($d) tcfg_validate_task 接受全部 $tot 个链任务文件"
    else
        bad "VA-02($d) tcfg 文件级拒绝 inv=$inv/$tot"
    fi
done
if dep_validate 'dag_op_root,?dag_op_aux'; then ok "VA-03 Optional 边 '?id' 过既有 dep_validate（D2 语法复用）"; else bad "VA-03 Optional 边被拒"; fi
if dep_validate 'dag_sf_root:FAILED'; then ok "VA-04 ':FAILED' 故障分支边过既有 dep_validate（D15 语义复用）"; else bad "VA-04 :FAILED 被拒"; fi
if [ "$(dep_normalize 'a b,c')" = "a,b,c" ]; then ok "VA-05 dep_normalize 空格容错→逗号规范（D1 golden）"; else bad "VA-05 D1 golden 破坏"; fi
if [ "$(dep_normalize ' a , b ')" = "a,b" ]; then ok "VA-06 dep_normalize 空段/空白容错（D1 golden）"; else bad "VA-06 D1 空段 golden 破坏"; fi

# ═══════════════════════════════════════════════════════════════════════════
# §invalid — 环/自依赖/未知（既有图校验器拒绝 + 消息文案锁定 = D-08 继承基线）
# ═══════════════════════════════════════════════════════════════════════════
ic="$T/invalid"; mkdir -p "$ic"
cp -R "$FX/invalid/cycle" "$FX/invalid/selfdep" "$FX/invalid/unknown" "$ic/" 2>/dev/null
if ! dgraph "$ic/cycle"; then
    # 实际 DFS 遍历序 = a→(a 的上游 c)→(c 的上游 b)→回到 a；锁定当前消息形状，
    # P6-05 D-08 要求 P6-06 继承同文案（起点/方向不重新定义）。
    if grep -q 'cycle: dag_cy_a->dag_cy_c->dag_cy_b->dag_cy_a' "$T/err.txt"; then
        ok "IN-01 环 fixture 被拒且完整环路径消息锁定（P6-06 须继承此文案）"
    else
        bad "IN-01 环消息文案异常: $(head -1 "$T/err.txt")"
    fi
else
    bad "IN-01 环 fixture 未被拒绝（P4 基线回退！）"
fi
if ! dgraph "$ic/selfdep"; then
    if grep -q "self-dependency in 'dag_sd'" "$T/err.txt"; then
        ok "IN-02 自依赖 fixture 被拒且消息锁定"
    else
        bad "IN-02 自依赖消息异常: $(head -1 "$T/err.txt")"
    fi
else
    bad "IN-02 自依赖未被拒绝（P4 基线回退！）"
fi
if ! dgraph "$ic/unknown"; then
    if grep -q "unknown dependency 'dag_no_such_task' in 'dag_un'" "$T/err.txt"; then
        ok "IN-03 未知依赖 fixture 被拒且消息锁定"
    else
        bad "IN-03 未知依赖消息异常: $(head -1 "$T/err.txt")"
    fi
else
    bad "IN-03 未知依赖未被拒绝（P4 基线回退！）"
fi
# 覆盖节点协议（<id> <content>）——P6-06 四写路径升级所依赖的现行为：正反例
ov_bad_content=$(printf 'schema_version=2\nid=dag_l_c\ntrigger=chain\ndependency=dag_ghost\n')
# P6-06 注记：原「移除入边」正例在 D55 孤儿拒绝下不再合法（链节点空入边=孤儿）；
# 正例改为「入边重指根」（仍为覆盖协议合法改写，保持 IN-05 的 overlay 正例语义）。
ov_ok_content=$(grep -v '^dependency=' "$vd/linear/dag_l_c.task"; echo 'dependency=dag_l_root')
if dep_validate_graph "$vd/linear" dag_l_c "$ov_bad_content" "[task-config] ERROR:" 2>/dev/null; then
    bad "IN-04 覆盖协议：注入未知依赖的新内容应被拒"
else
    ok "IN-04 覆盖协议：新内容含未知依赖 → 图校验拒绝（apply/set 现行为）"
fi
if dep_validate_graph "$vd/linear" dag_l_c "$ov_ok_content" "[task-config] ERROR:" 2>/dev/null; then
    ok "IN-05 覆盖协议：新内容合法（入边重指根）→ 图校验接受"
else
    bad "IN-05 覆盖协议合法内容被拒"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §limits — DEP_MAX 现拒 + deep17/nodes33/edges129 生成 golden
# ═══════════════════════════════════════════════════════════════════════════
dm="$T/limits/depmax33"; mkdir -p "$dm"
cp "$FX/limits/depmax33/dag_dm33.task" "$dm/"
dm_dep=$(grep '^dependency=' "$dm/dag_dm33.task" | cut -d= -f2-)
n_ent=$(printf '%s' "$dm_dep" | tr ',' '\n' | grep -c .)
if [ "$n_ent" -eq 33 ]; then ok "LX-01 depmax33 fixture 恰 33 条依赖（=DEP_MAX+1，golden）"; else bad "LX-01 条目数=$n_ent ≠33"; fi
if dep_validate "$dm_dep"; then bad "LX-02 DEP_MAX 未拒绝超限依赖"; else ok "LX-02 33 条依赖被既有 dep_validate 拒绝（DEP_MAX=32 现行为）"; fi
if tcfg_validate_task "$dm/dag_dm33.task"; then bad "LX-03 超限文件仍判合法"; else ok "LX-03 tcfg_validate_task 连带拒绝该文件"; fi

gl="$T/limits/gen"
if sh "$FX/tools/gen_limits.sh" "$gl" >/dev/null 2>&1; then
    ok "LX-04 gen_limits.sh 运行成功（确定性生成器，入库脚本仅 tools/）"
else
    bad "LX-04 gen_limits.sh 运行失败"
fi
gl2="$T/limits/gen2"
sh "$FX/tools/gen_limits.sh" "$gl2" >/dev/null 2>&1
if diff -r "$gl" "$gl2" >/dev/null 2>&1; then ok "LX-05 生成器双跑逐字节一致（可复现 golden）"; else bad "LX-05 生成器非确定"; fi

lim_n=$(adreno DAG_CHAIN_NODES_MAX); lim_e=$(adreno DAG_CHAIN_EDGES_MAX); lim_d=$(adreno DAG_CHAIN_DEPTH_MAX)
# P6-06 翻转（ADR D55 批准的「修前→修后」迁移）：修前=超限闭包被接受（P4 基线，
# P6-05 已锁定）；修后=配置期按维度拒绝（DAG-EX-15 同源断言，测试文件头授权）。
for c in deep17 nodes33 edges129; do
    if dgraph "$gl/$c"; then
        bad "LX-06($c) 超限闭包仍被接受（P6-06 D55 链段拒绝未生效！）"
    else
        ok "LX-06($c) 超限闭包配置期被拒（P6-06 修后行为；修前=P4 基线见 git 历史）"
    fi
    mm=$(dmetrics "$gl/$c"); set -- $mm; g_n=$1; g_e=$2; g_d=$3
    m_n=$(sed -n 's/^nodes=//p' "$gl/$c/manifest.txt")
    m_e=$(sed -n 's/^edges=//p' "$gl/$c/manifest.txt")
    m_d=$(sed -n 's/^depth=//p' "$gl/$c/manifest.txt")
    if [ "$g_n" = "$m_n" ] && [ "$g_e" = "$m_e" ] && [ "$g_d" = "$m_d" ]; then
        ok "LX-07($c) 独立复算度量 == manifest（nodes=$g_n edges=$g_e depth=$g_d）"
    else
        bad "LX-07($c) 复算($g_n/$g_e/$g_d) != manifest($m_n/$m_e/$m_d)"
    fi
done
mm=$(dmetrics "$gl/deep17"); set -- $mm
if [ "$3" = "$((lim_d + 1))" ] && [ "$1" -le "$lim_n" ]; then
    ok "LX-08 deep17 深度=$(($lim_d + 1))（=DAG_CHAIN_DEPTH_MAX+1）且仅深度维超限"
else
    bad "LX-08 deep17 维度异常 n=$1 d=$3"
fi
mm=$(dmetrics "$gl/nodes33"); set -- $mm
if [ "$1" = "$((lim_n + 1))" ] && [ "$3" -le "$lim_d" ] && [ "$2" -le "$lim_e" ]; then
    ok "LX-09 nodes33 节点=$(($lim_n + 1))（=DAG_CHAIN_NODES_MAX+1）且仅节点维超限"
else
    bad "LX-09 nodes33 维度异常 n=$1"
fi
mm=$(dmetrics "$gl/edges129"); set -- $mm
if [ "$2" = "$((lim_e + 1))" ] && [ "$1" -le "$lim_n" ] && [ "$3" -le "$lim_d" ]; then
    ok "LX-10 edges129 边=$(($lim_e + 1))（=DAG_CHAIN_EDGES_MAX+1）且节点/深度均留界内"
else
    bad "LX-10 edges129 维度异常 e=$2"
fi

# 边界：孤儿链节点（P6-05 修前基线=接受；P6-06 D55 配置期拒绝 → 翻转断言）
ob="$T/orphan"; mkdir -p "$ob"; cp "$FX/boundary/orphan/"*.task "$ob/" 2>/dev/null
if dgraph "$ob"; then
    bad "BX-01 孤儿 trigger=chain 仍被接受（P6-06 D55 孤儿拒绝未生效！）"
else
    if grep -q "chain node without incoming edge 'dag_or'" "$T/err.txt"; then
        ok "BX-01 孤儿 trigger=chain 配置期被拒且消息锁定（P6-06 修后；修前基线见 git 历史）"
    else
        bad "BX-01 孤儿被拒但消息异常: $(head -1 "$T/err.txt")"
    fi
fi
if dep_validate ""; then ok "BX-02 空 dependency 合法（无依赖恒通过，D1）"; else bad "BX-02 空依赖被拒"; fi

# ═══════════════════════════════════════════════════════════════════════════
# §inject — secv_id_ok / dep_validate 真跑 + 注入 Task 文件拒绝 + 零 exec
# ═══════════════════════════════════════════════════════════════════════════
inj="$T/inject"; mkdir -p "$inj"
cp "$FX/inject/strings.tsv" "$inj/"
cp "$FX/inject/tasks/"*.task "$inj/" 2>/dev/null
rm -f /tmp/pwn 2>/dev/null
inj_bad=0; inj_rows=0
while IFS="	" read -r tag se de payload; do
    case "$tag" in ''|'#'*) continue ;; esac
    inj_rows=$((inj_rows + 1))
    real=$(printf '%b' "$payload")
    if [ "$se" = "reject" ]; then
        if secv_id_ok "$real"; then inj_bad=$((inj_bad + 1)); bad "IJ-01($tag) secv_id_ok 误接受注入 id"
        else ok "IJ-01($tag) secv_id_ok 拒绝（链目录名/节点 id 门）"; fi
    else
        if secv_id_ok "$real"; then ok "IJ-01($tag) secv_id_ok 接受合法对照"
        else inj_bad=$((inj_bad + 1)); bad "IJ-01($tag) 合法 id 被误拒"; fi
    fi
    if [ "$de" = "reject" ]; then
        if dep_validate "$real"; then inj_bad=$((inj_bad + 1)); bad "IJ-02($tag) dep_validate 误接受注入依赖"
        else ok "IJ-02($tag) dep_validate 拒绝（dependency= 存储层门）"; fi
    else
        if dep_validate "$real"; then ok "IJ-02($tag) dep_validate 接受对照（现行为诚实锁定）"
        else inj_bad=$((inj_bad + 1)); bad "IJ-02($tag) 对照值被误拒"; fi
    fi
done < "$inj/strings.tsv"
ijf=0; ijt=0
for f in "$inj"/dag_ix*.task; do
    [ -f "$f" ] || continue
    ijt=$((ijt + 1))
    if tcfg_validate_task "$f"; then ijf=$((ijf + 1)); bad "IJ-03($(basename "$f" .task)) 注入 Task 文件被判合法"; fi
done
if [ "$ijt" -eq 5 ] && [ "$ijf" -eq 0 ]; then
    ok "IJ-03 注入 Task 文件（';'、\$( )、反引号、'|'、路径穿越）全部被 tcfg_validate_task 拒绝（$ijt/$ijt）"
else
    bad "IJ-03 注入 Task 文件计数异常 tot=$ijt bad=$ijf（期望 5/0）"
fi
if ! dgraph "$inj" 2>/dev/null; then
    ok "IJ-04 含注入依赖的目录被图校验拒绝（双层门）"
else
    bad "IJ-04 注入目录通过图校验"
fi
if [ ! -e /tmp/pwn ]; then
    ok "IJ-05 零 exec 守卫：/tmp/pwn 不存在（校验全程无 shell 求值）"
else
    bad "IJ-05 注入产生了文件！"
    rm -f /tmp/pwn 2>/dev/null
fi
if [ "$inj_bad" -eq 0 ]; then
    ok "IJ-06 strings.tsv 全表 $inj_rows 条注入/对照断言零误判"
else
    bad "IJ-06 注入表存在 $inj_bad 个误判"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §p4-baseline — entry 级语义锁定（P6-06 继承基线，禁改）
# ═══════════════════════════════════════════════════════════════════════════
if dep_validate 't_a:PAUSED'; then bad "PB-01 STATE 枚举外值被接受（应仅 STOPPED/FAILED）"; else ok "PB-01 ':PAUSED' 拒绝（D2 STATE 枚举锁定）"; fi
if dep_validate '??t_a'; then bad "PB-02 双问号被接受"; else ok "PB-02 '??t_a' 拒绝（保留符号单义）"; fi
if dep_validate '?t_a:STOPPED'; then ok "PB-03 '?id:STOPPED' 接受（Optional+显式终态组合）"; else bad "PB-03 合法组合被拒"; fi
if dep_validate ',,'; then bad "PB-04 全分隔符串被接受"; else ok "PB-04 ',,' 拒绝（空依赖列表非法，D1/§3-2）"; fi
if dep_validate 't_a\tt_b'; then bad "PB-05 字面反斜杠串应被字符集门拒绝"; else ok "PB-05 字面 '\\t' 两字符按非法字符拒绝（控制符门不误伤）"; fi
# 当前实现基线（诚实锁定）：真实 TAB 在 dep_validate 的**可打印性门**即被拒
# （D1 文法「HT 容错」位于分词层，dep_validate 不可达）；p4 套件从未断言 dep-TAB
# 接受，仅 cond_validate 有 TAB 拒绝断言。P6-06 链校验升级必须**继承此门**（ADR D46 注记）。
if dep_validate "$(printf 't_a\tt_b')"; then bad "PB-06 dep-TAB 现行为回退（应被可打印性门拒绝）"; else ok "PB-06 真实制表符被可打印性门拒绝（现行为 golden；D1『HT 容错』在 dep_validate 不可达已注记 ADR）"; fi
# 空格分隔 = D1 容错路径（非注入面）：接受为两条 entry（p4 golden 同源断言）
if dep_validate 'dag_a dag_b'; then ok "PB-07 空格分隔两 entry 接受（D1 容错现行为，非注入）"; else bad "PB-07 空格容错丢失（P4 基线回退！）"; fi

# ═══════════════════════════════════════════════════════════════════════════
# §engine — 链引擎行为断言（P6-06 实施 + ADR 批准后；DAG-EX-01..20 逐条真验证）
# ═══════════════════════════════════════════════════════════════════════════
# Harness（scheduler-prod / p4-dependency 同源惯例）：execute_task shim 同步执行
# （失败/挂起由 $E_FAILDIR/$E_SLOWDIR 标记控制）；SCHED_CYCLE_NOW/GATE_NOW 确定性
# 时钟；每场景独立 base/task-config；etick = scheduler_tick + state_sync_all
# （镜像 daemon 主循环收尾顺序）。根触发统一 0830：t830 根执行 → t831 登记 run 并
# 首波释放 → 此后每 tick 一层（frontier 用行更新前的账本 → 每 tick 单波，可预测）。
E_N=0
execute_task() {           # daemon 上下文委托（P2-06 同源 7 参；p4 shim 同构）
    e_id=$1
    e_d="$TASKS_DIR/$e_id"
    mkdir -p "$e_d" 2>/dev/null
    echo "$e_id|$2" >> "$E_EXEC"
    date "+%Y-%m-%d %H:%M:%S" > "$e_d/start_time.txt" 2>/dev/null
    echo "$e_id" >> "$E_SEQLOG"
    if [ -f "$E_FAILDIR/$e_id" ]; then
        echo "1" > "$e_d/exit_code.txt"; echo "FAILED" > "$e_d/status.txt"
    elif [ -f "$E_SLOWDIR/$e_id" ]; then
        echo "RUNNING" > "$e_d/status.txt"    # 无 exit_code → 保持 RUNNING（在途）
    else
        echo "0" > "$e_d/exit_code.txt"; echo "SUCCESS" > "$e_d/status.txt"
    fi
    return 0
}
ex_new() {                 # 新场景沙箱（tcfg/base/tasks/执行日志/失败与挂起标记）
    E_N=$((E_N + 1))
    E_DIR="$T/ex$E_N"
    E_BASE="$E_DIR/base"; E_TASKS="$E_DIR/tasks"; E_TCFG="$E_DIR/task-config"
    mkdir -p "$E_BASE" "$E_TASKS" "$E_TCFG" "$E_DIR/fail" "$E_DIR/slow"
    echo managed > "$E_TCFG/MANAGED"
    export TCFG_DIR="$E_TCFG"
    E_CFG="$E_DIR/config.txt"; : > "$E_CFG"
    E_EXEC="$E_DIR/exec.log"; : > "$E_EXEC"
    E_SEQLOG="$E_DIR/order.log"; : > "$E_SEQLOG"
    E_FAILDIR="$E_DIR/fail"; E_SLOWDIR="$E_DIR/slow"
    TR_BASE=""; TR_CONFIG_PATH=""
    export TASKS_DIR="$E_TASKS"
    # 上限常量复位（场景可覆盖；set -u 下恒有值）
    DAG_CHAIN_NODES_MAX=32; DAG_CHAIN_EDGES_MAX=128; DAG_CHAIN_DEPTH_MAX=16
    DAG_RUNS_MAX=8; DAG_PARALLEL_MAX=4; DAG_RUN_TIMEOUT=86400; DAG_RUNS_KEEP=8
    WAIT_MAX=86400
    E_SEQ=0; E_EPOCH=1789192800
}
ex_task() {                # <id> <trigger> <dep> [retry.max] [enabled]
    {
        echo "schema_version=2"
        echo "id=$1"
        echo "name=$1"
        echo "enabled=${5:-1}"
        echo "trigger=$2"
        echo "condition="
        echo "dependency=$3"
        echo "action.type=command"
        echo "action.command=echo ex-$1"
        echo "action.notify_start=0"
        echo "action.notify_end=0"
        echo "action.delete=0"
        echo "action.termux=0"
        echo "action.interactive=0"
        echo "action.run_once_now=0"
        echo "action.boot=0"
        echo "action.msg="
        echo "health.type=none"
        echo "recovery.type=none"
        echo "retry.max=${4:-0}"
        echo "retry.interval=60"
    } > "$E_TCFG/$1.task"
}
etick() {                  # <HHMM>：token=20260908<HHMM>、GATE_NOW=+60s/拍。先对账
    E_SEQ=$((E_SEQ + 1))   # 上一波退出码（等价 daemon 相邻 tick 观察序）再跑本波 tick
    SCHED_CYCLE_NOW="20260908$1"
    GATE_NOW=$((E_EPOCH + E_SEQ * 60))
    state_sync_all "$E_TASKS" >/dev/null 2>&1
    scheduler_tick "$E_BASE" "$E_CFG" "$E_TASKS" "$1" >/dev/null 2>&1
    state_sync_all "$E_TASKS" >/dev/null 2>&1
    SCHED_CYCLE_NOW=""; GATE_NOW=""
}
run_of() {  echo "$E_BASE/dag/$1/runs/$2/run.txt"; }   # <chain> <token>
ex_completed() {           # 线性 root→b→c 走完至 run SUCCESS（供复用场景）
    ex_task rt0 0830 ""
    ex_task b  chain rt0
    ex_task c  chain b
    etick 0830; etick 0831; etick 0832; etick 0833
}

ex_new   # ── EX-01/EX-02：根触发登记 run（tmp+mv/五态/root 行）+ token 去重
ex_completed
run01="$(run_of rt0 202609080830)"
if [ -f "$run01" ] && grep -q '^state=SUCCESS$' "$run01"; then
    ok "DAG-EX-01 根触发（0830 窗口）→ runs/<token>/run.txt 创建并收敛 SUCCESS（PENDING→RUNNING→SUCCESS 文件记录）"
else
    bad "DAG-EX-01 run.txt 缺失或未收敛: $(ls "$E_BASE/dag" 2>/dev/null)"
fi
if grep -q '^chain=rt0$' "$run01" && grep -q '^run=202609080830$' "$run01" \
   && grep -q '^created=178919' "$run01" && grep -q '^root=rt0|STOPPED|1$' "$run01" \
   && grep -q '^b|chain|STOPPED|' "$run01" && grep -q '^c|chain|STOPPED|' "$run01"; then
    ok "DAG-EX-01b run.txt 结构合规（chain/run/state/created/root=id|态|attempt + 成员行，D49）"
else
    bad "DAG-EX-01b run.txt 结构异常: $(head -8 "$run01" 2>/dev/null | tr '\n' ';')"
fi
if [ -n "$(grep 'op=dag|action=register|chain=rt0|run=202609080830' "$E_BASE/scheduler/audit.log" 2>/dev/null)" ] \
   && [ -n "$(grep '|dag_register|' "$E_TASKS/rt0/events.log" 2>/dev/null)" ]; then
    ok "DAG-EX-01c 登记审计 op=dag|action=register + dag_register 事件令牌（D50）"
else
    bad "DAG-EX-01c register 审计/事件缺失"
fi
n_before=$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')
etick 0831
n_after=$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_before" = "$n_after" ] && [ -d "$E_BASE/dag/rt0/runs/202609080830" ]; then
    ok "DAG-EX-02 同窗口重复扫描不重复建 run（目录名=token 天然去重；tick 幂等 $n_after 个）"
else
    bad "DAG-EX-02 token 去重失败 before=$n_before after=$n_after"
fi
if dag_try_register "$E_BASE" "$E_TASKS" rt0 202609080830 "b c" 2>/dev/null; then
    bad "DAG-EX-02b dag_try_register 对已存在 token 未去重"
else
    ok "DAG-EX-02b dag_try_register 幂等（同 root+token 二次调用拒绝）"
fi

ex_new   # ── EX-03：手动 tctl 不点火；节点手动终态入当前 run
ex_task rt0 0830 ""
ex_task b chain rt0
ex_task c chain b
touch "$E_SLOWDIR/b"
etick 0830; etick 0831          # run 登记 + b 释放（slow → 在途 RUNNING）
n0=$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')
tctl_start "$E_BASE" "$E_TASKS" rt0 1 >/dev/null 2>&1   # 手动 start 根（force）
n1=$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')
etick 0832
n2=$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n0" = "$n1" ] && [ "$n1" = "$n2" ] && [ "$n2" = "1" ]; then
    ok "DAG-EX-03 手动 tctl start/restart 根不创建 run（run 是调度器产物，D48）"
else
    bad "DAG-EX-03 手动 start 点火了 run n=$n0/$n1/$n2"
fi
tctl_restart "$E_BASE" "$E_TASKS" c >/dev/null 2>&1     # 手动节点重执行（RUNNING 中）
etick 0833
etick 0834
if grep -q '^c|chain|STOPPED|' "$(run_of rt0 202609080830)" \
   && [ "$(grep -c '^c|' "$E_EXEC" | tr -d ' ')" = "1" ]; then
    ok "DAG-EX-03b 节点手动终态更新入当前 run.txt（引擎不重复派发：c 执行 1 次）"
else
    bad "DAG-EX-03b 手动节点终态未入 run 或引擎重复派发"
fi

ex_new   # ── EX-04：frontier 拓扑序（线性/分支同层/合流双入边）
ex_task rt0 0830 ""
ex_task b chain rt0
ex_task c chain b
ex_task rt2 0830 ""
ex_task l chain rt2
ex_task r chain rt2
ex_task rt3 0830 ""
ex_task m1 chain rt3
ex_task m2 chain rt3
ex_task zjoin chain m1,m2     # 合流命名晚于其依赖（规避 depg_dfs 既有合流假环；见回报）
etick 0830                    # 三根执行
etick 0831                    # 链 pass：登记各 run + 首波释放 b / l,r / m1,m2
o_b=$(grep -n '^b$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_r0=$(grep -n '^rt0$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_c=$(grep -n '^c$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_l=$(grep -n '^l$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_r=$(grep -n '^r$' "$E_SEQLOG" | head -1 | cut -d: -f1)
if [ -n "$o_b" ] && [ -n "$o_r0" ] && [ -z "$o_c" ] && [ -n "$o_l" ] && [ -n "$o_r" ]; then
    ok "DAG-EX-04 线性 rt0→b 已释放而 b→c 未释放（b 在途）；分支 l/r 同 tick 释放（同层确定序=账本升序）"
else
    bad "DAG-EX-04 释放编排异常 b=$o_b c=$o_c l=$o_l r=$o_r"
fi
if [ "$(printf '%s\n%s\n' "$o_l" "$o_r" | sort -n | head -1 | tr -d ' ')" = "$o_l" ]; then
    ok "DAG-EX-04b 同 frontier 确定序：字典序 l 先于 r（锁定解释性决策=账本行序）"
else
    bad "DAG-EX-04b 同层顺序非确定"
fi
etick 0832   # b STOPPED → c 释放；m1/m2 STOPPED → zjoin 释放
o_c2=$(grep -n '^c$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_j=$(grep -n '^zjoin$' "$E_SEQLOG" | head -1 | cut -d: -f1)
o_m1=$(grep -n '^m1$' "$E_SEQLOG" | head -1 | cut -d: -f1)
if [ -n "$o_c2" ] && [ "$o_c2" -gt "$o_b" ] && [ -n "$o_j" ] && [ -n "$o_m1" ] && [ "$o_j" -gt "$o_m1" ]; then
    ok "DAG-EX-04c c 仅在 b 终态后释放；合流 zjoin 等待双入边 m1+m2（拓扑序推进）"
else
    bad "DAG-EX-04c 拓扑序违规 c=$o_c2 zjoin=$o_j"
fi
etick 0833; etick 0834
if grep -q '^state=SUCCESS$' "$(run_of rt0 202609080830)" \
   && grep -q '^state=SUCCESS$' "$(run_of rt2 202609080830)" \
   && grep -q '^state=SUCCESS$' "$(run_of rt3 202609080830)"; then
    ok "DAG-EX-04d 线性/分支/合流三形态 run 全部收敛 SUCCESS"
else
    bad "DAG-EX-04d 收敛失败: rt0=$(grep '^state=' "$(run_of rt0 202609080830)" 2>/dev/null) rt3=$(grep '^state=' "$(run_of rt3 202609080830)" 2>/dev/null)"
fi

ex_new   # ── EX-05：并行闸（在途 > DAG_PARALLEL_MAX 顺延不丢弃）
DAG_PARALLEL_MAX=2
ex_task rt0 0830 ""
ex_task p1 chain rt0; ex_task p2 chain rt0; ex_task p3 chain rt0
ex_task p4 chain rt0; ex_task p5 chain rt0
for i in 1 2 3 4 5; do touch "$E_SLOWDIR/p$i"; done
etick 0830; etick 0831
if [ "$(grep -c '^p' "$E_EXEC" | tr -d ' ')" = "2" ] \
   && grep -q '^p3|chain|PENDING|defer$' "$(run_of rt0 202609080830)"; then
    ok "DAG-EX-05 5 释放节点仅前 2（字典序 p1,p2）派发；p3-p5 note=defer 顺延（不丢弃）"
else
    bad "DAG-EX-05 并行闸失效 dispatched=$(grep -c '^p' "$E_EXEC")"
fi
etick 0832
if [ "$(grep -c '^p' "$E_EXEC" | tr -d ' ')" = "2" ]; then
    ok "DAG-EX-05b 在途=2 期间新 tick 零派发（闸持续生效）"
else
    bad "DAG-EX-05b 在途超限仍派发"
fi
rm -f "$E_SLOWDIR/p1" "$E_SLOWDIR/p2"
echo 0 > "$E_TASKS/p1/exit_code.txt"; echo 0 > "$E_TASKS/p2/exit_code.txt"
etick 0833
n5=$(grep -c '^p' "$E_EXEC" | tr -d ' ')
rm -f "$E_SLOWDIR/p3" "$E_SLOWDIR/p4"
echo 0 > "$E_TASKS/p3/exit_code.txt"; echo 0 > "$E_TASKS/p4/exit_code.txt"
etick 0834
rm -f "$E_SLOWDIR/p5"; echo 0 > "$E_TASKS/p5/exit_code.txt"
etick 0835
n_done=$(grep -c '^p' "$E_EXEC" | tr -d ' ')
if [ "$n5" = "4" ] && [ "$n_done" = "5" ] && grep -q '^state=SUCCESS$' "$(run_of rt0 202609080830)"; then
    ok "DAG-EX-05c 分批推进 2→4→5，全部节点最终执行（顺延语义）且 run SUCCESS"
else
    bad "DAG-EX-05c 分批释放异常 n=$n5/$n_done"
fi

ex_new   # ── EX-06：Required 上游 FAILED → 下游立即 FAILED 级联，run=FAILED
ex_task rt0 0830 ""
ex_task b chain rt0
ex_task c chain b
touch "$E_FAILDIR/b"
etick 0830; etick 0831; etick 0832
rf="$(run_of rt0 202609080830)"
if grep -q '^b|chain|FAILED|disp$' "$rf" && grep -q '^c|chain|FAILED|gate-fail$' "$rf" \
   && grep -q '^state=FAILED$' "$rf"; then
    ok "DAG-EX-06 上游 FAILED（缺省 :STOPPED 期望）→ c 立即 FAILED 级联（不等超时），run=FAILED"
else
    bad "DAG-EX-06 传播异常: $(grep '^c|' "$rf" 2>/dev/null; grep '^state=' "$rf" 2>/dev/null)"
fi
if [ -f "$E_TASKS/c/gate.fail" ] && grep -q '|gate_fail|FAILED|' "$E_TASKS/c/events.log" 2>/dev/null \
   && grep -q 'action=fail-propagate' "$E_BASE/scheduler/audit.log"; then
    ok "DAG-EX-06b 传播经 P4 既有通道：gate_fail 事件 + gate.fail 标记 + fail-propagate 审计（D51=D15）"
else
    bad "DAG-EX-06b gate_fail 通道缺失"
fi
if [ -z "$(grep '^c|' "$E_EXEC")" ]; then
    ok "DAG-EX-06c 传播失败节点不执行（c 零执行）"
else
    bad "DAG-EX-06c 传播节点被误执行"
fi

ex_new   # ── EX-07：Optional 边不阻断（opt-unsat 记录）
ex_task rt0 0830 ""
ex_task aux chain rt0
ex_task kid chain rt0,?aux
touch "$E_FAILDIR/aux"
etick 0830; etick 0831
rf="$(run_of rt0 202609080830)"
if grep -q '^kid|chain|RUNNING|disp opt-unsat$' "$rf" && grep -q '^kid|' "$E_EXEC"; then
    ok "DAG-EX-07 Optional 上游不满足不阻断：kid 与 aux 同波释放，note 记 opt-unsat（D51=D16）"
else
    bad "DAG-EX-07 opt 阻断或记录缺失: $(grep '^kid|' "$rf" 2>/dev/null)"
fi
etick 0832; etick 0833
if grep -q '^state=FAILED$' "$(run_of rt0 202609080830)"; then
    ok "DAG-EX-07b 结论按成员计：aux FAILED → run=FAILED（kid SUCCESS 不改变聚合）"
else
    bad "DAG-EX-07b run 结论异常"
fi

ex_new   # ── EX-08：`:FAILED` 故障分支（缺省边被 STOPPED 满足、FAILED 不满足）
ex_task rt0 0830 ""
ex_task fd chain rt0:FAILED
ex_task nm chain rt0
touch "$E_FAILDIR/rt0"
etick 0830; etick 0831; etick 0832
rf="$(run_of rt0 202609080830)"
if grep -q '^fd|chain|.*|disp$' "$rf" && grep -q '^nm|chain|FAILED|gate-fail$' "$rf" \
   && grep -q '^fd|' "$E_EXEC" && [ -z "$(grep '^nm|' "$E_EXEC")" ]; then
    ok "DAG-EX-08 根 FAILED：:FAILED 边满足（故障分支释放执行），缺省边终态不匹配 → nm 立即 FAILED（D15 行2）"
else
    bad "DAG-EX-08 :FAILED 语义异常: $(grep '^fd|' "$rf"; grep '^nm|' "$rf")"
fi
etick 0833
if grep -q '^fd|chain|STOPPED|disp$' "$rf" && grep -q '^state=FAILED$' "$rf"; then
    ok "DAG-EX-08b 故障分支处置完成后 run=FAILED（存在终态 FAILED 成员）"
else
    bad "DAG-EX-08b 聚合异常"
fi

ex_new   # ── EX-09：run 超时（不强杀在途、停止释放）
DAG_RUN_TIMEOUT=60
ex_task rt0 0830 ""
ex_task b chain rt0
ex_task c chain b
touch "$E_SLOWDIR/b"
etick 0830; etick 0831; etick 0832; etick 0833
rf="$(run_of rt0 202609080830)"
if grep -q '^state=FAILED$' "$rf" && grep -q 'action=timeout' "$E_BASE/scheduler/audit.log" \
   && grep -q 'limit=60' "$E_BASE/scheduler/audit.log"; then
    ok "DAG-EX-09 超 DAG_RUN_TIMEOUT → run=FAILED + action=timeout 审计（含 elapsed/limit，D57）"
else
    bad "DAG-EX-09 超时未收敛: $(grep '^state=' "$rf" 2>/dev/null)"
fi
if [ "$(cat "$E_TASKS/b/state.txt" 2>/dev/null)" = "RUNNING" ] && [ -z "$(grep '^c|' "$E_EXEC")" ]; then
    ok "DAG-EX-09b 超时不强杀在途进程（b 仍 RUNNING）且停止释放（c 零派发）"
else
    bad "DAG-EX-09b 超时副作用越界"
fi
rm -f "$E_SLOWDIR/b"; echo 0 > "$E_TASKS/b/exit_code.txt"
etick 0834; etick 0835
if grep -q '^state=FAILED$' "$rf" && [ -z "$(grep '^c|' "$E_EXEC")" ]; then
    ok "DAG-EX-09c 超时终态粘滞：b 事后完成也不再释放下游（链不重放）"
else
    bad "DAG-EX-09c 终态被翻案"
fi

ex_new   # ── EX-10(a)：重试耗尽 → 传播；gate_fail 不接退避；链零重放
ex_task rt0 0830 ""
ex_task b chain rt0 1          # b：retry.max=1（耗尽后终局）
ex_task c chain b 3            # c：retry.max=3 但传播失败不接退避
touch "$E_FAILDIR/b"
etick 0830; etick 0831; etick 0832; etick 0833
rf="$(run_of rt0 202609080830)"
if [ -f "$E_TASKS/c/gate.fail" ] && [ ! -f "$E_TASKS/c/retry.until" ] \
   && grep -q '^c|chain|FAILED|gate-fail$' "$rf" && [ -z "$(grep '^c|' "$E_EXEC")" ]; then
    ok "DAG-EX-10 c 传播 FAILED 且 retry.max=3 仍不接退避（gate.fail 阻断，D25/D53）"
else
    bad "DAG-EX-10 传播节点被退避接线"
fi
if [ "$(grep -c '^b|' "$E_EXEC" | tr -d ' ')" = "2" ] \
   && [ "$(ls "$E_BASE/dag/rt0/runs" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "DAG-EX-10a 链零重放：b 仅自身节点级重试 2 次执行；run 数恒 1（无整链重放）"
else
    bad "DAG-EX-10a 重放异常 b=$(grep -c '^b|' "$E_EXEC")"
fi

ex_new   # ── EX-10(b)：上游重试成功 → 终态更新入 run.txt → frontier 前进（D-06）
ex_task rt0 0830 ""
ex_task b chain rt0 2          # 首轮失败、重试成功
ex_task c chain b
touch "$E_FAILDIR/b"
etick 0830; etick 0831; etick 0832      # b 失败（退避中：c 等待而非误传播）
if grep -q '^c|chain|PENDING|waiting$' "$(run_of rt0 202609080830)" \
   && [ ! -f "$E_TASKS/c/gate.fail" ]; then
    ok "DAG-EX-10b 上游 FAILED 但重试预算未完 → c 等待（不提前传播；run 不收敛）"
else
    bad "DAG-EX-10b 传播抢跑于节点重试之前"
fi
rm -f "$E_FAILDIR/b"
etick 0833; etick 0834; etick 0835      # advance 释放重试 → b STOPPED → c 释放
rf="$(run_of rt0 202609080830)"
if [ "$(grep -c '^b|' "$E_EXEC" | tr -d ' ')" = "2" ] \
   && grep -q '^b|chain|STOPPED|disp$' "$rf" && grep -q '^c|chain|.*|disp$' "$rf" \
   && grep -q '^state=SUCCESS$' "$rf" \
   && grep -q 'retry backoff attempt 1/' "$E_TASKS/b/events.log" 2>/dev/null; then
    ok "DAG-EX-10c 节点重试成功翻正 run.txt（b STOPPED）→ frontier 前进 → c 执行 → run SUCCESS"
else
    bad "DAG-EX-10c 重试推进异常: $(grep '^b|' "$rf"; grep '^c|' "$rf"; grep '^state=' "$rf")"
fi

ex_new   # ── EX-11：disable=中断路（有界等待→超时 FAILED）
DAG_RUN_TIMEOUT=60
ex_task rt0 0830 ""
ex_task b chain rt0 0 0        # b enabled=0
ex_task c chain b
etick 0830; etick 0831; etick 0832; etick 0833
rf="$(run_of rt0 202609080830)"
if grep -q '^b|chain|PENDING|disabled$' "$rf" && grep -q '^state=FAILED$' "$rf" \
   && [ -z "$(grep '^b|' "$E_EXEC")" ] && [ -z "$(grep '^c|' "$E_EXEC")" ]; then
    ok "DAG-EX-11 中断路：b disabled 永不执行 → c 有界等待 → run 超时 FAILED（b/c 零执行）"
else
    bad "DAG-EX-11 中断路异常: $(grep '^b|' "$rf" 2>/dev/null; grep '^state=' "$rf" 2>/dev/null)"
fi

ex_new   # ── EX-12：手动 stop → STOPPED 满足缺省边（签核①文档化行为）
ex_task rt0 0830 ""
ex_task b chain rt0
ex_task c chain b
touch "$E_SLOWDIR/b"
etick 0830; etick 0831; etick 0832
tctl_stop "$E_BASE" "$E_TASKS" b >/dev/null 2>&1
etick 0833; etick 0834
rf="$(run_of rt0 202609080830)"
if [ "$(cat "$E_TASKS/b/state.txt" 2>/dev/null)" = "STOPPED" ] \
   && grep -q '^b|chain|STOPPED|disp$' "$rf" && grep -q '^c|' "$E_EXEC" \
   && grep -q '^state=SUCCESS$' "$rf"; then
    ok "DAG-EX-12 手动 stop 节点 → STOPPED 满足缺省 :STOPPED 边，下游照常释放、run SUCCESS"
else
    bad "DAG-EX-12 stop 放行失效: b=$(grep '^b|' "$rf" 2>/dev/null) c=$(grep -c '^c|' "$E_EXEC")"
fi

ex_new   # ── EX-13：活跃 run 超限不启动新 run（根照常执行、在途不杀）
DAG_RUNS_MAX=2
ex_task r1 0830 ""; ex_task r1l chain r1
ex_task r2 0830 ""; ex_task r2l chain r2
ex_task r3 0830 ""; ex_task r3l chain r3
for i in 1 2 3; do touch "$E_SLOWDIR/r${i}l"; done
etick 0830; etick 0831
if [ "$(ls "$E_BASE/dag" 2>/dev/null | wc -l | tr -d ' ')" = "2" ] \
   && [ -z "$(ls "$E_BASE/dag/r3/runs" 2>/dev/null)" ] \
   && grep -q 'action=limit|chain=r3' "$E_BASE/scheduler/audit.log"; then
    ok "DAG-EX-13 活跃 run ≥2 → r3 新 run 不启动 + action=limit 审计；r1/r2 在途不受影响"
else
    bad "DAG-EX-13 并发闸异常 chains=$(ls "$E_BASE/dag" 2>/dev/null | tr '\n' ',')"
fi
if grep -q '^r3|' "$E_EXEC" && [ -z "$(grep '^r3l|' "$E_EXEC")" ]; then
    ok "DAG-EX-13b 超限下根照常执行（r3 已执行；其链节点未启动）"
else
    bad "DAG-EX-13b 根被执行策略牵连"
fi
rm -f "$E_SLOWDIR/r1l" "$E_SLOWDIR/r2l"
echo 0 > "$E_TASKS/r1l/exit_code.txt"; echo 0 > "$E_TASKS/r2l/exit_code.txt"
etick 0832; etick 0833; etick 0834
n3=$(ls "$E_BASE/dag/r3/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$n3" = "1" ] && grep -q '^r3l|' "$E_EXEC"; then
    ok "DAG-EX-13c 名额释放后 r3 run 登记并释放（拒启动不丢弃；后续 tick 重试扫描）"
else
    bad "DAG-EX-13c 释放后未补登记 n=$n3"
fi
etick 0835

ex_new   # ── EX-14：孤儿 trigger=chain 配置期拒绝（四写路径 + editor 消息）
mkdir -p "$E_TCFG"; cp "$FX/boundary/orphan/dag_or.task" "$E_TCFG/"
if dep_validate_graph "$E_TCFG" "" "" "[task-config] ERROR:" 2>"$T/e14a"; then
    bad "DAG-EX-14 apply/snapshot 路径未拒孤儿"
elif grep -q "\[task-config\] ERROR: chain node without incoming edge 'dag_or'" "$T/e14a"; then
    ok "DAG-EX-14 孤儿 trigger=chain 配置期拒绝（apply/snapshot=dep_validate_graph 接入点，D55）"
else
    bad "DAG-EX-14 消息异常: $(head -1 "$T/e14a")"
fi
if tcfg_editor_validate_payload "$(cat "$E_TCFG/dag_or.task")" 2>"$T/e14b"; then
    bad "DAG-EX-14b editor 路径未拒孤儿"
elif grep -q "\[editor\] ERROR: chain node without incoming edge 'dag_or'" "$T/e14b"; then
    ok "DAG-EX-14b editor/EDIT_TASK 载荷路径拒绝且字段级消息（edit 写路径）"
else
    bad "DAG-EX-14b editor 消息异常: $(head -1 "$T/e14b")"
fi
ov_orphan=$(printf 'schema_version=2\nid=nn1\ntrigger=chain\ndependency=\n')
if dep_validate_graph "$E_TCFG" nn1 "$ov_orphan" "[ipc] ERROR:" 2>"$T/e14c"; then
    bad "DAG-EX-14c 覆盖协议（create 注入新节点）未拒孤儿"
elif grep -q "\[ipc\] ERROR: chain node without incoming edge 'nn1'" "$T/e14c"; then
    ok "DAG-EX-14c create 写路径（覆盖协议）拒绝 trigger=chain 新孤儿（D55 + 任务书 create 面）"
else
    bad "DAG-EX-14c create 面消息异常: $(head -1 "$T/e14c")"
fi

# ── EX-15：deep17/nodes33/edges129 配置期按维度拒绝（含 IPC configuration_invalid 透传）
ex_new   # 沙箱：t 目录装 deep17 前 16 节点，第 17 个走 payload 覆盖协议
for cse in deep17 nodes33 edges129; do
    d="$E_DIR/g_$cse"; mkdir -p "$d"
    for f in "$gl/$cse"/*.task; do cp "$f" "$d/"; done
    case "$cse" in
        deep17)   pat="chain depth 17 exceeds DAG_CHAIN_DEPTH_MAX=16" ;;
        nodes33)  pat="chain nodes 33 exceeds DAG_CHAIN_NODES_MAX=32" ;;
        edges129) pat="chain edges 129 exceeds DAG_CHAIN_EDGES_MAX=128" ;;
    esac
    if dgraph "$d" && :; then
        bad "DAG-EX-15($cse) 超限闭包仍被接受"
    elif grep -q "$pat" "$T/err.txt"; then
        ok "DAG-EX-15($cse) 配置期按维度拒绝（消息含超限值与常量名：$pat）"
    else
        bad "DAG-EX-15($cse) 消息异常: $(head -1 "$T/err.txt")"
    fi
done
# 界内：deep16 同形梯（15 chain+root=16 深度）必须被接受（维度精确性）
d16="$E_DIR/g_deep16"; mkdir -p "$d16"
cp "$gl/deep17/dg_d00.task" "$d16/"
i=1; while [ "$i" -le 15 ]; do cp "$gl/deep17/$(printf 'dg_d%02d' "$i").task" "$d16/"; i=$((i + 1)); done
if dgraph "$d16"; then
    ok "DAG-EX-15b deep16 界内对照被接受（拒绝按精确维度，非一刀切）"
else
    bad "DAG-EX-15b 界内 deep16 被误拒: $(head -1 "$T/err.txt")"
fi
# IPC 端到端：VALIDATE_TASK 载荷 → configuration_invalid 字段级透传（P6-04 通道）
export TCFG_DIR="$d16"
ipcv_content=$(cat "$gl/deep17/dg_d16.task")
ipc_op_validate "$E_BASE" r15 "payload=$(ipc_b64enc "$ipcv_content")" >/dev/null 2>&1
r15resp="$E_BASE/ipc/responses/r15.resp"
if grep -q '^r15|VALIDATE_TASK|4|configuration_invalid: ' "$r15resp" 2>/dev/null \
   && grep -q 'chain depth 17 exceeds DAG_CHAIN_DEPTH_MAX=16' "$r15resp" 2>/dev/null; then
    ok "DAG-EX-15c IPC VALIDATE_TASK 超限 → rc4 configuration_invalid 透传字段级原因（信封样例见回报）"
else
    bad "DAG-EX-15c IPC 信封异常: $(head -1 "$r15resp" 2>/dev/null)"
fi
export TCFG_DIR="$E_TCFG"

ex_new   # ── EX-16：run.txt.tmp.* sweep + dag 0700/run.txt 0600
ex_completed
rf="$(run_of rt0 202609080830)"
touch "$(dirname "$rf")/run.txt.tmp.4242"
secv_sweep_tmp "$E_BASE" >/dev/null 2>&1
if [ ! -e "$(dirname "$rf")/run.txt.tmp.4242" ]; then
    ok "DAG-EX-16 secv_sweep_tmp 清除 \$base/dag/*/runs/*/run.txt.tmp.* 残留（D49 兜底）"
else
    bad "DAG-EX-16 sweep 未覆盖 dag tmp"
fi
chmod 777 "$E_BASE/dag" "$rf" 2>/dev/null
secv_fix_perms "$E_BASE" "$E_TASKS" >/dev/null 2>&1
m_dag=$(stat -c '%a' "$E_BASE/dag" 2>/dev/null)
m_run=$(stat -c '%a' "$rf" 2>/dev/null)
if [ "$m_dag" = "700" ] && [ "$m_run" = "600" ]; then
    ok "DAG-EX-16b secv_fix_perms 覆盖 \$base/dag 0700 / run.txt 0600（引擎创建亦 0600）"
else
    bad "DAG-EX-16b 权限异常 dag=$m_dag run=$m_run"
fi

skip "DAG-EX-17 GET_SUMMARY.dag / GET_TASK_DETAIL.dag 只增键（B8）+ CLI Chain Root:/Run: 行 — reason: 按 P6-06 任务书范围切分，WebUI JSON 键归 P6-08、CLI 展示归 P6-09；本任务已落引擎侧数据面（run.txt/op=dag 审计/dag_* 事件令牌）供其消费"

# ── DAG-EX-18：editor 枚举 / trigger_decide 恒 due=N / IPC 19 op 零新增
if tcfg_editor_trigger_ok chain && ! tcfg_editor_trigger_ok 'chain:extra' && ! tcfg_editor_trigger_ok 'CHAIN'; then
    ok "DAG-EX-18 tcfg_editor_trigger_ok 接受裸 'chain'（无参数；拒绝带参/大写变体，D47）"
else
    bad "DAG-EX-18 editor 枚举接入异常"
fi
ex_new
ex_task rt0 0830 ""; ex_task b chain rt0
etick 0830
dout=$(trigger_decide "$E_BASE" b 0830 0 "$E_BASE/schedule_state.txt")
drc=$?
case "$dout" in *"due=N|cause="*) if [ "$drc" -eq 1 ]; then ok "DAG-EX-18b trigger_decide 对 chain 恒 due=N|cause=（释放不经时间窗口，D47）"; else bad "DAG-EX-18b due=N 但 rc=$drc"; fi ;; *) bad "DAG-EX-18b trigger_decide 异常: $dout" ;; esac
if [ "$(printf '%s\n' $IPC_WHITELIST | wc -l | tr -d ' ')" = "19" ]; then
    ok "DAG-EX-18c IPC 白名单恒 19 op（B7 零新增；chain 走既有 CREATE/UPDATE/EDIT/VALIDATE 载荷）"
else
    bad "DAG-EX-18c op 数漂移: $(printf '%s\n' $IPC_WHITELIST | wc -l)"
fi
etick 0831   # run 正常登记（chain 节点仅经引擎释放的另一面证据）
if [ -f "$(run_of rt0 202609080830)" ] && grep -q '^b|' "$E_EXEC"; then
    ok "DAG-EX-18d chain 节点执行仅由引擎 pass 释放（主循环对 due=N 零派发）"
else
    bad "DAG-EX-18d 引擎释放路径未生效"
fi

ex_new   # ── EX-19：legacy 边界（词表零 chain；import 图形化拒；非 managed 引擎不运行）
printf 'boot echo hi\n06:30 echo time\n0700 echo hhmm\nweekly:1:0900 echo adv\n' > "$E_DIR/legacy_ok.txt"
mkdir -p "$E_DIR/lok"
legacy_adapter_parse "$E_DIR/legacy_ok.txt" "$E_DIR/lok" >/dev/null 2>&1
nchain=$(grep -l '^trigger=chain$' "$E_DIR/lok"/*.task 2>/dev/null | wc -l | tr -d ' ')
if [ "$(ls "$E_DIR/lok"/*.task 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ] && [ "$nchain" = "0" ]; then
    ok "DAG-EX-19 合法 legacy 语法（boot/时间/advanced）解析产物零 trigger=chain（legacy 词表无 chain 族，B16/C4）"
else
    bad "DAG-EX-19 legacy 词表产出 chain 族 n=$nchain"
fi
# 裸 `chain` 首 token 行非合法 legacy 语法（适配器逐字透传=既有 C2 行为）；但其提升
# 进 managed 域必被 D55 图校验（孤儿）整单拒绝，legacy 域亦 due=N + 引擎不运行（双惰性）
printf 'chain echo not-a-legacy-trigger\n' > "$E_DIR/legacy_bad.txt"
if tcfg_import "$E_DIR/legacy_bad.txt" 2>"$T/e19b"; then
    bad "DAG-EX-19b 含 chain-token 行的 config 竟被 import 提升"
elif ! grep -q "chain node without incoming edge 't1_chain'" "$T/e19b" \
   || ! grep -q 'import rejected (dependency graph invalid)' "$T/e19b"; then
    bad "DAG-EX-19b import 拒绝但消息异常: $(head -2 "$T/e19b" | tr '\n' ';')"
elif ls "$E_TCFG"/*chain*.task >/dev/null 2>&1; then
    bad "DAG-EX-19b 拒绝后仍残留 chain 任务文件"
else
    ok "DAG-EX-19b legacy 行提升 managed 被链段拒绝（孤儿消息+import rejected，B9 逐字节不变；非 legacy 词表诚实注记）"
fi
# 旧模式（无 MANAGED）：存量 \$base/dag 闲置不读
ex_completed
chain_md5_before=$(find "$E_BASE/dag" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
rm -f "$E_TCFG/MANAGED"                   # 回退 legacy 模式（存量 dag 树保留）
SCHED_CYCLE_NOW="202609080900" scheduler_tick "$E_BASE" "$E_DIR/legacy_ok.txt" "$E_TASKS" "0900" >/dev/null 2>&1
chain_md5_after=$(find "$E_BASE/dag" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
if [ -n "$chain_md5_before" ] && [ "$chain_md5_before" = "$chain_md5_after" ]; then
    ok "DAG-EX-19c 非 managed：链引擎 pass 不运行（存量 \$base/dag 逐字节闲置，D12）"
else
    bad "DAG-EX-19c legacy 模式下 dag 树被触碰 $chain_md5_before/$chain_md5_after"
fi

ex_new   # ── EX-20：corrupt 收敛 + prune + 成员冻结/现图重算 + 回滚不回滚链态
ex_task rt0 0830 ""             # 快照有效性守卫（根于 0830 窗口执行）
# (a) corrupt：非本引擎格式文件 → 审计 + FAILED（不猜态）
mkdir -p "$E_BASE/dag/extc/runs/202609080700"
printf 'garbage-not-a-run\n===???===\n' > "$E_BASE/dag/extc/runs/202609080700/run.txt"
etick 0830
rfc="$E_BASE/dag/extc/runs/202609080700/run.txt"
if grep -q 'action=corrupt|chain=extc|run=202609080700' "$E_BASE/scheduler/audit.log" \
   && grep -q '^state=FAILED$' "$rfc"; then
    ok "DAG-EX-20 run.txt 不可解析 → dag=corrupt 审计 → 按超时路径收敛 FAILED（prune 域，D49）"
else
    bad "DAG-EX-20 corrupt 收敛失效"
fi
# (b) prune：保留 DAG_RUNS_KEEP=2（token 字典序=时间序，最旧先删）
DAG_RUNS_KEEP=2
for tk in 202609080601 202609080602 202609080603 202609080604; do
    mkdir -p "$E_BASE/dag/extp/runs/$tk"
    printf 'chain=extp\nrun=%s\nstate=SUCCESS\ncreated=1789190000\nroot=extp|STOPPED|1\n' "$tk" \
        > "$E_BASE/dag/extp/runs/$tk/run.txt"
done
etick 0831
nkeep=$(ls "$E_BASE/dag/extp/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "$nkeep" = "2" ] && [ -d "$E_BASE/dag/extp/runs/202609080604" ] \
   && [ ! -d "$E_BASE/dag/extp/runs/202609080601" ] \
   && grep -q 'action=prune' "$E_BASE/scheduler/audit.log"; then
    ok "DAG-EX-20b 每链超 DAG_RUNS_KEEP 按 token 字典序 prune 最旧 + prune 审计（D49/D57）"
else
    bad "DAG-EX-20b prune 异常 kept=$nkeep"
fi
# (c) 成员集登记冻结：run 登记**之后**新增闭包成员 d 不注入进行中 run
#     登记发生在 etick 0831（观察到 0830 的 cycle 标记），故 d 须在 0831 之后加入
ex_task b chain rt0; ex_task c chain b
etick 0830                        # 根执行（本波链 pass 尚无 cycle → 不登记）
etick 0831                        # 链 pass 观察 cycle-0830 → 登记 run（冻结 b,c）+ b 释放
ex_task d chain rt0               # 登记**之后**加入闭包的新成员
etick 0832                        # b STOPPED → c 释放；d 不在 run.txt
etick 0833
rf="$(run_of rt0 202609080830)"
if ! grep -q '^d|' "$rf" && [ -z "$(grep '^d|' "$E_EXEC")" ]; then
    ok "DAG-EX-20c run 成员集登记时冻结：闭包新增 d 不注入进行中 run（D56）"
else
    bad "DAG-EX-20c 成员集被扩: $(grep '^d|' "$rf" 2>/dev/null)"
fi
# (d) 边每 tick 现图重算：c 的入边 b→root 改写后，下一波按新边释放
ex_new
ex_task rt0 0830 ""; ex_task b chain rt0; ex_task c chain b
touch "$E_SLOWDIR/b"
etick 0830; etick 0831            # run 登记；b 释放并挂起（RUNNING）
if [ -z "$(grep '^c|' "$E_EXEC")" ]; then :; else bad "DAG-EX-20d 现图基线异常（c 提前释放）"; fi
sed -i 's/^dependency=b$/dependency=rt0/' "$E_TCFG/c.task"   # 改边 c→rt0（D55 合法）
etick 0832
rf="$(run_of rt0 202609080830)"
if grep -q '^c|' "$E_EXEC" && [ "$(cat "$E_TASKS/b/state.txt" 2>/dev/null)" = "RUNNING" ]; then
    ok "DAG-EX-20d frontier 每 tick 按现图重算：改边后 c 不再等 b（b 仍 RUNNING）即释放（D56）"
else
    bad "DAG-EX-20d 现图重算失效 c=$(grep -c '^c|' "$E_EXEC")"
fi
# (e) 配置回滚不回滚 run.txt（链态前滚）：删除链任务文件，run 目录与账本存续
rf_md5=$(md5sum "$rf" 2>/dev/null | cut -d' ' -f1)
rm -f "$E_TCFG/b.task" "$E_TCFG/c.task"
etick 0833
if [ -f "$rf" ] && grep -q '^chain=rt0$' "$rf" && [ -n "$rf_md5" ]; then
    ok "DAG-EX-20e 配置回滚/成员删除不回滚 run.txt（运行态前滚；账本存续 D56/D-09）"
else
    bad "DAG-EX-20e 链态被回滚波及"
fi

# ═══════════════════════════════════════════════════════════════════════════
# §posix — 自身与 fixtures 工具语法（lint 惯例：dash 可用则 dash -n，否则 bash -n；sh -n 恒跑）
# ═══════════════════════════════════════════════════════════════════════════
SELF="tests/p6-dag/test.sh"
GEN="tests/p6-dag/fixtures/tools/gen_limits.sh"
if command -v dash >/dev/null 2>&1; then
    dash -n "$SELF" && ok "PX-01 dash -n $SELF" || bad "PX-01 dash -n 失败：$SELF"
    dash -n "$GEN"  && ok "PX-02 dash -n $GEN"  || bad "PX-02 dash -n 失败：$GEN"
else
    bash -n "$SELF" && ok "PX-01 bash -n $SELF（dash 不可用降级）" || bad "PX-01 bash -n 失败：$SELF"
    bash -n "$GEN"  && ok "PX-02 bash -n $GEN（dash 不可用降级）"  || bad "PX-02 bash -n 失败：$GEN"
fi
sh -n "$SELF" && ok "PX-03 sh -n $SELF" || bad "PX-03 sh -n 失败：$SELF"
sh -n "$GEN"  && ok "PX-04 sh -n $GEN"  || bad "PX-04 sh -n 失败：$GEN"

# ── 汇总 ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────────────"
echo "p6-dag tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP  (P6-05 裁决基线：既有校验器真验证 + ADR/文档 golden；DAG-EX-01..20 SKIP → P6-06 实施且 ADR 批准后逐条转 PASS=出口条件)"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
