# tests/p6-dag — P6-05 DAG / 链式调度裁决基线（fixtures 总览）

> **性质**：P6-05 设计任务的验证夹具。**引擎未实现**（P6-06，且须先批准
> `docs/architecture/dag-schema-v1.md`）。本套件的可跑断言只锁定：
> ① 既有校验器（`dep_validate`/`dep_validate_graph`/`tcfg_validate_task`/
> `secv_id_ok`/`dep_normalize`）对**提案 schema 下 fixtures** 的当前接受/拒绝
> 行为（ADR 引用为基线）；② fixtures 结构与 ADR 表格一致性（grep golden）；
> ③ 注入面拒绝。引擎类断言（链执行/传播/超时/取消/上限运行期行为）全部
> `[SKIP] reason: P6-06 实施` —— **SKIP→PASS 是 P6-06 的出口条件之一**（见
> test.sh 文件头）。
>
> 目录：
> - `valid/`     线性链 / 分支链 / 合流(菱形) / Optional 边 / `:FAILED` 边（提案 schema；当前校验器应全部接受）
> - `invalid/`   环 / 自依赖 / 未知依赖（当前校验器应全部拒绝，消息锁定）
> - `boundary/`  孤儿 `trigger=chain`（当前图校验接受——**P6-06 起配置期拒绝**，见 SKIP）
> - `limits/`    超限例生成规格与生成器 `../tools/gen_limits.sh`：
>                deep17（深度=DAG_CHAIN_DEPTH_MAX+1）、nodes33（节点数=MAX+1）、
>                edges129（边数=MAX+1，节点数恰=32 不触节点上限、深度 3 不触深度上限）、
>                depmax33（单任务 33 条依赖 > DEP_MAX=32，当前即拒）
> - `inject/`    注入字符串表 `strings.tsv` 与注入 Task 文件（`;`、`$( )`、反引号等，
>                当前 `dep_validate`/`tcfg_validate_task`/`secv_id_ok` 应拒绝）
>
> 约定：fixtures 全部使用**既有 Task v2 字段**（ADR D46：边=`dependency=`；D47：
> 成员=`trigger=chain`），因此当前生产校验器可完整解析——这是「不发明第二套语法」
> 的可执行证明。字段与上限的权威定义 = `docs/architecture/dag-schema-v1.md` §2。
