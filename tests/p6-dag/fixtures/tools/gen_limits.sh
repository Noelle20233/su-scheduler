#!/bin/sh
# gen_limits.sh — P6-05 超限 fixtures 生成器（确定性；测试沙箱内展开，不入库产物）
# 用法: sh tools/gen_limits.sh <out_dir>
# 生成三个「当前图校验接受、但超 DAG 提案上限（dag-schema-v1.md §2，ACCEPTED 已批准）」的链闭包：
#   deep17/    17 节点单线梯  = DAG_CHAIN_DEPTH_MAX(16) + 1（节点 17>32? 否；仅深度超限）
#   nodes33/   1 根 + 32 叶   = DAG_CHAIN_NODES_MAX(32) + 1（深度 2、边 32，均不触其他上限）
#   edges129/  1 根 + 17 中 + 14 叶 = 17+14*8 = 129 边 = DAG_CHAIN_EDGES_MAX(128) + 1
#              （节点数 32 = 上限恰好不触；深度 3 = 不触）
# 每个用例同时生成 manifest.txt：nodes/edges/depth 三个计数（test.sh 的 golden 输入）。
set -u
out=${1:?usage: gen_limits.sh OUT_DIR}

g_tpl() {   # <file> <id> <trigger> <dependency>
    {
        echo "schema_version=2"
        echo "id=$2"
        echo "name=$2"
        echo "enabled=1"
        echo "trigger=$3"
        echo "condition="
        echo "dependency=$4"
        echo "action.type=command"
        echo "action.command=echo p6-dag-fixture"
        echo "health.type=none"
        echo "recovery.type=none"
        echo "retry.max=0"
        echo "retry.interval=60"
    } > "$out/$1"
}

mkdir -p "$out/deep17" "$out/nodes33" "$out/edges129"

# ── deep17：root → d01 → … → d16（17 节点单线；边 16；深度 17 = 上限+1）─────
g_tpl deep17/dg_d00.task dg_d00 "interval:60" ""
i=1
while [ "$i" -le 16 ]; do
    prev=$(printf 'dg_d%02d' $((i - 1)))
    cur=$(printf 'dg_d%02d' "$i")
    g_tpl "deep17/$cur.task" "$cur" "chain" "$prev"
    i=$((i + 1))
done
printf 'nodes=17\nedges=16\ndepth=17\n' > "$out/deep17/manifest.txt"

# ── nodes33：1 根 + 32 叶（节点 33；边 32；深度 2）──────────────────────────
g_tpl nodes33/dg_n00.task dg_n00 "boot" ""
i=1
while [ "$i" -le 32 ]; do
    cur=$(printf 'dg_n%02d' "$i")
    g_tpl "nodes33/$cur.task" "$cur" "chain" "dg_n00"
    i=$((i + 1))
done
printf 'nodes=33\nedges=32\ndepth=2\n' > "$out/nodes33/manifest.txt"

# ── edges129：1 根 + 17 中(各依赖根) + 14 叶(依赖根+7 中) = 17+112=129 边；32 节点；深度 3
g_tpl edges129/dg_e00.task dg_e00 "cron:0 6 * * *" ""
i=1
while [ "$i" -le 17 ]; do
    cur=$(printf 'dg_m%02d' "$i")
    g_tpl "edges129/$cur.task" "$cur" "chain" "dg_e00"
    i=$((i + 1))
done
i=1
while [ "$i" -le 14 ]; do
    cur=$(printf 'dg_l%02d' "$i")
    j=1
    dep="dg_e00"
    while [ "$j" -le 7 ]; do
        dep="$dep,$(printf 'dg_m%02d' "$j")"
        j=$((j + 1))
    done
    g_tpl "edges129/$cur.task" "$cur" "chain" "$dep"
    i=$((i + 1))
done
printf 'nodes=32\nedges=129\ndepth=3\n' > "$out/edges129/manifest.txt"

echo "generated: deep17 nodes33 edges129 under $out"
