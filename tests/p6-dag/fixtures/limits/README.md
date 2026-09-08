# P6-05 limits fixtures — 生成规格（golden 说明）

上限权威定义 = `docs/architecture/dag-schema-v1.md` §2 常量表（**DRAFT 待批准**）。
超限例由 `../tools/gen_limits.sh <dir>` 确定性生成（不入库产物，test.sh 现场展开到
临时沙箱），每目录附 `manifest.txt`（nodes/edges/depth 计数，test.sh 交叉校验）：

| 用例 | nodes | edges | depth | 超限维度（提案值） | 当前 P4 校验器 | P6-06（提案） |
| deep17    | 17（不触） | 16（不触）  | **17 = 16+1** | DAG_CHAIN_DEPTH_MAX | 接受（无环） | 配置期拒绝 |
| nodes33   | **33 = 32+1** | 32 | 2 | DAG_CHAIN_NODES_MAX | 接受（无环） | 配置期拒绝 |
| edges129  | 32（恰好不触） | **129 = 128+1** | 3（不触） | DAG_CHAIN_EDGES_MAX | 接受（无环） | 配置期拒绝 |
| depmax33/（静态 fixture） | 1 | 33 | — | DEP_MAX=32（既有） | **即拒**（`dep_validate`/`tcfg_validate_task`） | 不变 |

设计约束：deep17/nodes33/edges129 **只**超单一维度（其余两维留余量），保证
P6-06 的拒绝消息可按维度定位；三例都无环（当前 `dep_validate_graph` 必须接受——
这一「修前基线」由 test.sh 真验证锁定）。
