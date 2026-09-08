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
ov_ok_content=$(grep -v '^dependency=' "$vd/linear/dag_l_c.task")
if dep_validate_graph "$vd/linear" dag_l_c "$ov_bad_content" "[task-config] ERROR:" 2>/dev/null; then
    bad "IN-04 覆盖协议：注入未知依赖的新内容应被拒"
else
    ok "IN-04 覆盖协议：新内容含未知依赖 → 图校验拒绝（apply/set 现行为）"
fi
if dep_validate_graph "$vd/linear" dag_l_c "$ov_ok_content" "[task-config] ERROR:" 2>/dev/null; then
    ok "IN-05 覆盖协议：新内容合法（移除入边）→ 图校验接受"
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
for c in deep17 nodes33 edges129; do
    if dgraph "$gl/$c"; then
        ok "LX-06($c) 超限闭包在当前校验器下无环被接受（P4 基线；配置期链拒绝是 P6-06 新增 → SKIP）"
    else
        bad "LX-06($c) 生成闭包被当前图校验意外拒绝: $(head -1 "$T/err.txt")"
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

# 边界：孤儿链节点（当前合法——P4 基线；提案 P6-06 配置期拒绝 → SKIP）
ob="$T/orphan"; mkdir -p "$ob"; cp "$FX/boundary/orphan/"*.task "$ob/" 2>/dev/null
if dgraph "$ob"; then
    ok "BX-01 孤儿 trigger=chain（无入边）当前图校验接受——锁定为 P6-06 的『修前』基线"
else
    bad "BX-01 孤儿图校验异常拒绝: $(head -1 "$T/err.txt")"
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
# §engine — 链引擎行为断言（P6-06 出口条件；ADR 批准前不得实现）
# ═══════════════════════════════════════════════════════════════════════════
skip "DAG-EX-01 根触发（interval/cron/boot/时间/catch-up）→ 创建 run 目录 run.txt（PENDING→RUNNING）— reason: P6-06 实施（ADR D48/D49 已批准 2026-09-08）"
skip "DAG-EX-02 同一根同一 cycle token 至多一次 run（runs/<token> 目录名天然去重）— reason: P6-06 实施（D48）"
skip "DAG-EX-03 手动 tctl start/restart 根不创建 run；节点 restart 终态更新入当前 run — reason: P6-06 实施（D48/D54）"
skip "DAG-EX-04 frontier 释放：线性链 root→b→c 拓扑序执行；分支同层、合流双入边等待 — reason: P6-06 实施（D52）"
skip "DAG-EX-05 单 run 在途进程超 DAG_PARALLEL_MAX=4 的释放节点顺延下一 tick（不丢弃）— reason: P6-06 实施（D52/D57）"
skip "DAG-EX-06 Required 边上游 FAILED（缺省 :STOPPED 期望）→ 下游立即 FAILED 并沿边级联；run=FAILED — reason: P6-06 实施（D51=D15 矩阵）"
skip "DAG-EX-07 Optional 边上游 FAILED/缺失 → 不阻断下游（opt-unsat 记录）— reason: P6-06 实施（D51=D16）"
skip "DAG-EX-08 ':FAILED' 故障分支：上游 STOPPED 反而终态不匹配 → 下游 FAILED — reason: P6-06 实施（D15 行2 复用）"
skip "DAG-EX-09 run 超 DAG_RUN_TIMEOUT=86400s → FAILED(run-timeout)，停止释放，在途进程不强杀 — reason: P6-06 实施（D57）"
skip "DAG-EX-10 节点 retry 退避仅节点级（P4-07 原语义）；gate_fail 传播不接退避；链永不自动重放 — reason: P6-06 实施（D53）"
skip "DAG-EX-11 disable 链中节点=中断路：Required 下游 dep-disabled 有界等待 → run 超时 FAILED — reason: P6-06 实施（D51/D54）"
skip "DAG-EX-12 手动 stop 节点 → STOPPED 满足缺省 :STOPPED 边（文档化行为）下游继续 — reason: P6-06 实施（D54）"
skip "DAG-EX-13 活跃 run 总数超 DAG_RUNS_MAX=8 → 新 run 不启动（审计 dag=run-limit），根照常执行 — reason: P6-06 实施（D57）"
skip "DAG-EX-14 孤儿 trigger=chain 配置期拒绝（chain node without incoming edge）— reason: P6-06 实施（D55；BX-01 为修前基线）"
skip "DAG-EX-15 deep17/nodes33/edges129 配置期按维度拒绝（消息含超限值与常量名）— reason: P6-06 实施（D55/D57；LX-06..10 为修前基线）"
skip "DAG-EX-16 secv_sweep_tmp 覆盖 dag run.txt.tmp.*；secv_fix_perms 覆盖 \$base/dag 0700 / run.txt 0600 — reason: P6-06 实施（D49/§4）"
skip "DAG-EX-17 GET_SUMMARY.dag / GET_TASK_DETAIL.dag 只增键（B8）+ CLI Chain Root:/Run: 行 — reason: P6-06 实施（D58）"
skip "DAG-EX-18 tcfg_editor_trigger_ok 接受 'chain'（仅 managed）；trigger_decide 对 chain 恒 due=N；IPC 19 op 零新增（B7）— reason: P6-06 实施（D47）"
skip "DAG-EX-19 legacy config.txt 永不产生 trigger=chain（legacy_adapter_parse 零 diff；非 managed 引擎 pass 不运行）— reason: P6-06 实施（D12 声明/D55 边界）"
skip "DAG-EX-20 run.txt 损坏→run-corrupt→超时收敛 FAILED→prune；成员集登记冻结、边按现图重算、配置回滚不回滚 run.txt — reason: P6-06 实施（D49/D56）"

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
