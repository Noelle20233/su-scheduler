# Su Scheduler — P6 出口评审报告（P6-EXIT-REPORT）

> **任务**：P6-12 · P6 出口评审与下一阶段移交（评审文档任务，零代码改动）
> **前置**：P6-01..P6-11 全部完成（P6-01 `d32b0e0` / P6-02 `aa87987` / P6-03 `19b5959` /
> P6-04 `37f2339` / P6-05 `335091d`+签核 `78098b9` / P6-06 `1dcb410` / P6-07 `fd9d856` /
> P6-08 `a1d6150` / P6-09 `ff17bf9` / P6-10 `27784c2`+fix `d29e9e2`+docs `be1135b` /
> P6-11 `dff2b55`+设备复验 `2f86322`）
> **日期**：2026-09-10（评审会话实测复跑；HEAD `2f86322`）
> **版本**：模块 `v1.6.8`（P6 全程不变）；Runtime 库 `1.32.0`（P6 出口：1.30.0→1.31.0（P6-06）→1.32.0（P6-09））
> **设备**：KernelSU × Android 16（`8934ffc4` / 无线 `192.168.2.156`；真机证据 = P6-10 §2/§9 记录，本次评审会话未复跑设备套件——见 §7）
> **性质**：P6 出口评审——全量回归复跑 + 出口条件逐条判定 + 约束审计 + 缺陷状态总表 + 性能三点趋势 + P7 移交。
> **环境**：宿主复跑在 WSL 原生 FS `~/su-scheduler`（AGENTS §4.4），21:11–21:24 安静窗，
> 起测前聚合单跑、独占计时（无并行负载）。

---

## 1. 回归总表（本次评审实跑）

### 1.1 宿主全量（本次评审会话复跑，非誊抄）

| 验收命令 | 结果 |
| :-- | :-- |
| `bash tests/run_tests.sh` | **ALL SUITES GREEN / exit 0**；**51 套件**、trace `[PASS]`=**2449**、`[FAIL]`=**0**；trace `tests/results/run_tests-20260910-211107.log`（评审会话实测；与 P6-11 终态 2449/0 完全一致——其后仅 docs 提交，断言面零漂移） |

### 1.2 P6 逐套件（**/0 = PASS/FAIL）

| 套件 | 结果 | 运行方式（本次评审） |
| :-- | :-- | :-- |
| `tests/p6-reliability/test.sh`（P6-01/02/03/04） | **25/0** | 单跑复跑（聚合外惯例套件，P6-09 §7.6）；§perf 实测 **empty=50ms / 50-task=1764ms**（≤2000 带内） |
| `tests/p6-dag/test.sh`（P6-05..07，EX-17c 由 P6-09 转 PASS） | **177/0 SKIP=0** | 单跑复跑（聚合外惯例套件）；EX-01..20 全量真验证 = P6-05 出口条件达成 |
| `tests/p6-webui/test.sh`（P6-08） | **82/0** | 聚合内 |
| `tests/p6-cli/test.sh`（P6-09） | **47/0** | 聚合内 |
| `tests/p6-verify/test.sh`（P6-11） | **30/0 SKIP=0** | 聚合内（本次评审时含 §upgrade 全历史组：WSL git 仓在位，非 CI [SKIP] 形态） |
| `tests/p6-device/smoke.sh`（P6-10，真机 56 断言） | **56/0/0**（记录值） | **本次评审未复跑**——设备 21:18 探测虽在网（新端口 42037、**未重启** up 22:19），但 **loadavg ~10 非安静窗** 且 §9.5 前置（增量清理+bind 复查）未做；真机证据 = run#18（`…20260909-220714-p6.log`）+ 修后复跑 56/0/0（`…-20260910-162551-p6.log`，P6-10 §9.4） |

### 1.3 既有 P3/P4/P5/P1 关键套件零回退（本次聚合实测）

p3-integration **49/0** · p4-dependency **220/0** · p5-condition **60/0** · p5-trigger **137/0** ·
p5-webui 64/0 · legacy/golden **8/0** · legacy/delete-pipeline 4/0 · legacy-adapter 107/0 ·
state-machine **183/0**（183 迁移恒零接触）· ipc **64/0** + ipc/security **17/0** ·
webui read-only **29/0** + security **35/0** + editor **41/0** · task-cli **56/0** + task-cli-prod **54/0** ·
task-control **60/0** · supervisor **20/0** · recovery **25/0** · crashguard **60/0** ·
resource **26/0** · security/fuzz **37/0** · path-validation 9/0 · permission 5/0 ·
p1-build **29/0 SKIP=0** · p1-regression **44/0** · scheduler-prod 33/0 · config-v2 44/0+validation 41/0 ·
shadow 23/0 · idmap 25/0 · cli 29/0 · lifecycle-prod **44/0**（含 D-P6-10-02 孪生围栏 §8 A/B/C）·
lint 11/0 ·（其余 providers 136 / runtime 45 / lifecycle 56 / app-action 54 / health 55 /
task-registry 44 / trigger-decision 39 / action-run 24 / runtime-lib 20 / trigger 21 / action 33 /
state 35 / p2-integration 22 / p2-install 13 等全部 0 FAIL，合计入 2449）。

- 设备既有段（记录值，P6-10 §9.4 独立复跑保持）：p1-device **11/0/2SKIP**、p3-device **28/0/0/BLOCKED=0**。

---

## 2. 出口条件 1–11 逐条判定（任务书原文编号）

> 编号依任务书；「对应 P6-11 项」列给出与 P6-11 §1 九检查项 / §6 硬门禁的映射，保证可复核。

| # | 出口条件 | 判定 | 证据（本次实跑/记录） | 对应 P6-11 项 | 备注 |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 1 | 基线复核缺陷（O-2/O-3/O-4）与设备缺陷（D-P6-10-01/02/03、O-P6-10-04）全部修复，先 FAIL 后 PASS 测试在位 | ✅ | §4 缺陷总表（逐条测试引用）；p6-reliability 25/0、p6-dag §D01、lifecycle-prod §8、crashguard §16 全绿 | — | 每项独立提交、逐项回归（T2 模式） |
| 2 | 宿主全量回归全绿 | ✅ | run_tests **51 套件 2449/0 exit 0**（§1.1）+ 聚合外惯例套件 p6-reliability 25/0、p6-dag 177/0 | §1 全部 | **口径说明**：`§perf` 类近界计时断言按 **P6-09 A/B 地板口径**判定——高负载下「参照档与受试档同涨」为环境噪声（不误红）、病态独涨必红；p6-verify 已把该规则**固化为测试内建**（界值调整前等价绿 `run_tests-…-120326`，本次复跑同绿）。本次评审起测独占安静窗 |
| 3 | 性能与压力无病态回归（tick 三档 / IPC 延迟基线 / 并发拒新时延 / 资源压测） | ✅ | §6 三点趋势表；resource 26/0、p6-verify §perf3/§ipc/§conc 在聚合内 30/0 | §1-1、§1-2 | 首次成文 IPC 端到端延迟基线（§6.2） |
| 4 | shell 兼容（POSIX/dash 静态面 + mksh） | ✅ | `dash -n` 全部 6 生产脚本（p6-verify §sh）+ lint 11/0 + mksh 静态断言（D36/D37，RTLIB/CLI/daemon 全扫描面 0 命中）+ dash 真跑探针 rc=0；**真机 mksh 终裁已由 p6-device 56/0/0 记录覆盖**（同机同日零语法失败） | §1-3 | 「延后声明」已兑现（P6-11 §7-B ✅） |
| 5 | 注入防护与安全边界（零 Shell 求值 / WebUI 零 Root / IPC 面） | ✅ | 注入/防护直接断言 **93+**（fuzz 37 + ipc/security 17 + path-validation 9 + p6-dag §inject 30）+ §P7 12，本次全绿；§3 审计逐条 | §1-4 | 副作用文件恒不存在断言在位 |
| 6 | 配置原子写/回滚（B9）与 Legacy/Managed 双模式 | ✅ | p6-verify §atomic（I/O 级：占位 tmp 制造真实写失败 rc=2、目标逐字节不变）+ §dual（8 活跃 run 互切不炸、dag 树 sha256 不变、回切续跑）；legacy golden 8/0；真机 p1 11/0/2 | §1-5、§1-7 | 三层原子性闭环（校验拒/写失败/导入中断） |
| 7 | 升级/回滚兼容（宿主演练 + 真机演练） | ✅ | 宿主「旧(1.30.0)→新→旧→新」跨二进制 8 断言（upg-0..7，含 §5 LOCK 固化）聚合内绿；真机 P6→P5→P6 RB-1..6 全过（矩阵 §4）+ 修后双轨落地复验（P6-10 §9.2/§9.3） | §1-8、§1-9 | 回滚窗口有界缺陷 **O-P6-11-01 登记不修**（§4），非阻断 |
| 8 | 构建与版本一致性（八处 / zip 完整 / 再生幂等） | ✅ | p1-build **29/0 SKIP=0**（本次实跑）：`build.sh` 产物、`unzip -t`、zip 内容物、八处版本一致（含 zip 内 runtime `1.32.0`）、update.json/release.yml 合法、**再生幂等**（O-P6-10-04 收口）、zip docs 含 `chain`×2 | §1-6 | §5 逐项列 |
| 9 | **真机全链路**（`run_tests.sh --with-device` 组合单命令全绿） | ◐ **分项达成、组合未竟** | 分项全绿证据链：run#18 **56/0/0**（有线安静窗）+ 修后加固版真机复跑 **56/0/0** + 修后三点 D-01/02/03 真机 5/5·5/5·6/6 + p1 **11/0/2**·p3 **28/0/0** 独立保持 + 组合跑宿主 51 套件段全绿；组合设备段遭用户 App 负载风暴（loadavg 15–55）+尾段 adb 失联 → p1 8/3、p3 TIMEOUT、p6 45/11 **均为环境项（同批断言 40 分钟前分项全绿）** | §1（九项）、§6 门禁行 | **待人工裁决放行与否**（§7 Q1/Q2）；组合全绿待下一安静窗口，动作序已固化 `docs/P6-10.md §9.5`（本次评审 21:18 复测：设备在网但 load ~10，仍非安静窗） |
| 10 | 设备矩阵如实记录（不伪造） | ✅ | `docs/P6-10-DEVICE-MATRIX.md` §1.1：KernelSU×A16 ✅，其余 **14 格 ⏳ 发布限制**；§1.3 资源探查（无 KVM/模拟器/Docker/第二设备）留证 | — | 14 格限制放行**待人工签核**（§7 Q3，同 P0-D3/P5-10 先例） |
| 11 | 出口评审与移交文档完备（本报告 + HANDOVER + 约束审计 + 缺陷台账） | ✅ | 本文档 + `docs/P6-HANDOVER.md`（本次交付）；P6-01..11 分篇 + ADR ACCEPTED 在位、交叉引用核对无死链（§9 一条命名偏差登记） | — | — |

---

## 3. 约束审计（C1–C5 + P6 阶段不变量）

> C 编号沿用 AGENTS.md §2（P0 起源），P5/P6 出口按既有惯例映射至当前阶段禁改项。
> diff 基准：P5 基线 `cbd065f` → P6 HEAD `2f86322`。

| 约束 | 结论 | 证据 |
| :-- | :-- | :-- |
| **C1 最小 diff、不重构** | ✅ | 生产面总计 **+2236/−54**（runtime +1832/−49、CLI +63/−1、daemon +10/−0、webroot +322/−4、README +9；另生成物 `.su-scheduler-docs` +216）；删除 54 行逐处为局部替换（`tcfg_new_id` 单行、`ipc_respond` 写前行、P6-07 §27 F1–F4 改造、app.js 渲染局改）；无整文件/整函数重写、无脚本/函数/路径重命名；逐任务 diff 记录见 P6-0x 各分篇 §改动摘要 |
| **C2 不删旧解析/执行路径** | ✅ | `su-schedulerd` `parse_modifiers`（L522）/`extract_command`（L564）/`legacy_adapter_parse` 活跃在位（本次 grep 实证）；20 项旧函数全存在（p5/p6 审计沿用）；`trigger_decide` 仅插 `chain)` 分支、`dep_validate_graph` 仅尾部追加（非链图逐字节不变——p4 220/0 + DAG IN-01..03 双侧守卫）；`scheduler_tick` 本体不重写（链 pass 单行插入，D53 层序）；执行路径 SYSTEM/TERMUX/INTERACTIVE 零改动 |
| **C3 无新增外部依赖** | ✅ | 运行期零新命令（toybox 集内：sed/tr/awk/grep/cut/date/getprop）；生产 `dash -n` 全 6 脚本 + mksh 静态面（D36/D37）+ dash 真跑探针（P6-11 §1-3）；**mksh 真运行时延后声明已兑现**（p6-device 真机 56/0/0 终裁记录）；测试期新工具仅 `dash -n`/`node --check`（在场守卫，缺席 NOTE）/`git show`（历史提取，CI 无历史自动 [SKIP]）——不入生产 |
| **C4 config.txt 格式零变更** | ✅ | legacy golden 8/0、delete-pipeline 4/0、parsing fixtures 恒绿（聚合内）；`trigger=chain` 仅 Managed（B16/D12），legacy 词表零 chain、chain-token 行 import 拒且 config 逐字节（EX-19/19b/19c）；真机 config 逐字节自愈核对恒等（矩阵 §3） |
| **C5 不提前实现下一阶段项 / service.sh 零触碰** | ✅ | **`service.sh` git diff 为空**（P6 全程；customize.sh/build.sh/module.prop/update.json 亦零改动，仅 bin 内版本串无关——本次 numstat 实证）；无第二常驻循环（`su-schedulerd` `while true` 恰 1，本次 grep 实证；库零常驻 stress 断言）；IPC 恒 **19 op**（白名单实测 19 + EX-18c/p6-cli P 断言守卫）；P7 域零实现零占位：链级取消 API 不做（`CANCELLED` 仅枚举预留不产出——v1 裁决的**诚实声明**非占位实现）、链自动重放不做、秒级 tick 不做、配置加密/备份增强/多 profile 零触碰 |
| **阶段不变量：单常驻主循环 + 锁主围栏** | ✅ | D-P6-10-02 修复后 `lifecycle_lock_owner_fence`（非持有者自退不删锁）+ `cmd_stop` 确认持有者死亡才删锁；lifecycle-prod **44/0**（含 §8 孪生断言 A/B/C）；真机双静置窗每 token `op=tick`=1 行（P6-10 §9.3） |
| **阶段不变量：WebUI 零 Root** | ✅ | webroot 三文件 `su -c`/`sh -c` grep **0 命中**（本次实证）；webui/security 35/0 静态扫描 + 链聚合只读零副作用断言（p6-webui：执行计数=链节点数、cksum 不变） |
| **阶段不变量：Condition 无任意 shell 求值** | ✅ | 链/门控/条件复用 cond_eval 白名单通道（P5 冻结）；IJ-05 `/tmp/pwn` 零求值、run.txt 注入纯数据（P7-04）、§27 零 eval/sh -c/kill 系结构审计（P7-02）——本次 fuzz 37/0、p6-dag 177/0 复跑绿 |
| **阶段不变量：config 原子写/B9 逐字节** | ✅ | 校验拒 rc1 / I/O 写失败 **rc=2**（可区分）/导入中断三层（p6-verify §atomic 3 实证 + §4 既有面汇总）；run.txt tmp+mv；`.valerr.*`/`run.txt.tmp.*` 入 sweep |

---

## 4. 缺陷状态总表

### 4.1 已修复（每项 = 先 FAIL 复现 + 最小修复 + FAIL→PASS + 门禁回归）

| ID | 面 | 修复 | 测试引用（本次全绿） | 真机 |
| :-- | :-- | :-- | :-- | :-- |
| O-2 主循环跳拍无 catch-up | runtime `scheduler_tick` | P6-02（last_tick=cycle token 轴、CATCHUP_MAX=3、同日、一次性族不补、复用既有门控路径） | `tests/p6-reliability` §O-2 FAIL→PASS + §P6-02-1..5（25/0） | ✅ 矩阵 §2.1（6 断言） |
| O-3 cron trigger ID 派生非法路径字符 | runtime `tcfg_new_id` | P6-03（拼路径前 sanitize 至 `[A-Za-z0-9._-]`，旧 golden 6 条逐字节不变） | §O-3 + §P6-03-1..5 | ✅ 矩阵 §2.2 |
| O-4 IPC 错误详情丢失 | runtime ipc + CLI `cmd_webui` | P6-04（`符号: 原因` 字段级透传 + `ipc_err_sanitize` 咽喉净化 + 脱敏 + 256 截断；六码语义不变） | §O-4 + §P6-04-1..6（25/0） | ✅ 矩阵 §2.3 |
| D-P6-10-01 陈旧 cycle 标记重登记饿死新链 | runtime §27 `dag_scan_registrations` | P6-10-fix（年龄/可解析钳制 `dag_token_age_le`，窗 `DAG_SCAN_MAX_AGE_MIN=1440`） | `tests/p6-dag` §D01（DAG-D01-01..07）先 FAIL 后 PASS | ✅ 真机 5/5（P6-10 §9.3，套件外构造） |
| D-P6-10-02 锁接管竞态双/三 daemon 同 tick | daemon 围栏 + CLI `cmd_stop` | P6-10-fix（`lifecycle_lock_owner_fence` + 删锁前置持有者死亡确认） | `tests/lifecycle-prod` §8 A/B/C 先 FAIL（双实例 2 行 op=tick）后 PASS（44/0） | ✅ 真机 5/5（围栏审计行原文 + 双静置窗 op=tick=1） |
| D-P6-10-03 kill×respawn 微窗击穿重试钳制（终局后第 3 跑） | runtime §27 重试/终局分支 | P6-10-fix（events.log 全失败事件计尝试 `dag_retry_replenish` + 终局 `dag_retry_terminate` 拒重放） | `tests/crashguard` §16 G4（修前 `cf_ex=3`→PASS ≤2）+ G4b..f（60/0） | ✅ 真机 6/6（2s 粒度命中 attempt-2 即杀：执行=2、+180s 零重放） |
| O-P6-10-04 文档管线漂移（README↔`.su-scheduler-docs` 双向） | 文档管线（无代码） | be1135b：README 唯一权威源回灌 + 再生；新增守卫断言 | `tests/p1-build/build_check.sh`（zip docs `chain`×2 + **再生幂等**，29/0） | —（构建面） |

### 4.2 登记未修 / 观察项（全部证据、影响、去向）

| ID | 证据 | 影响 | 建议去向 |
| :-- | :-- | :-- | :-- |
| **O-P6-11-01** catch-up × 同日回滚重放 | `tests/p6-verify` upg-5（**当前行为已固化为 LOCK 断言**：ut2 总执行=2，语义漂移会红提醒）；宿主复现 | 新版（last_tick=T）→同日回滚旧版（无 last_tick 语义）→同日再升级：catch-up 重放旧版已执行窗口，**非幂等任务最坏二次执行**；**有界**（同日且 gap≤CATCHUP_MAX=3 分钟）；真实升级路径（重启）不触发（upg-7 证） | P7 策略裁决（候选：catch-up 前查 `cycle-<窗口token>` 字面行含该 id 即跳过——与 pending 有效性检查同源；触碰 P6-02 冻结语义） |
| **O-P7-04** `.scanmark` 升级首扫 | p6-verify §perf3/§conc（9 根拒新波 ~1.7s；32 根档 tick ~1.7–2.2s）+ resource H5/H6；真机 scanmark 首扫观察并入 P6-10 §9 | 升级到本版后**首个** pass 一次性 O(roots) 全历史扫描（此后稳态 0.35–0.5s）；无正确性影响 | P7：首扫增量/后台迁移；维持登记（非缺陷） |
| **O-P6-08-01** 多根共享节点归属 | p6-webui（D58 单数键 v1 口径：detail 归属取字典序首链）；CLI 已给 `Member Of Chains` 补偿 | 多根共享节点 WebUI 主视图只展示首链归属 | P7：B8 兼容增键 `chains[]`（多链视图）；真机专项演练并入 U-4 结转 |
| **O-P7-01** `sched_cycle_seen` 正则面 | P6-07 §7（与 F1 同款 `grep -qx` 以 id 作正则；`.` 可跨行误配） | 仅查当前 token 单文件 O(1)；误配损失当分钟一次执行（下窗自愈）；非资源/安全缺口 | P7 人工裁决（改动触碰 P4 冻结语义，需 golden 评审） |
| **depg_dfs 合流误判观察**（P6-06 §10.6 / O-P7-06） | P4-03 既有缺陷（合流节点 id 字母序先于其依赖时误判环）；P6-07 §7 复验**未恶化**（p4 220/0、zjoin 及全部新增链测试零误配） | 特定命名的合法合流图被配置期**误拒**（假环）；生产既有约束，测试以命名规避 | P7 修复专项：含**消息继承门禁方案**（P4 golden 错误消息逐字节冻结，修复须新增不改动） |
| **P6-04 §9.1** REQ_ID 段未过 id 门 | malformed 响应 REQ_ID 取自请求文件名（basename 后未再过 `[A-Za-z0-9._-]` 门）；ERROR 字段本身已咽喉净化 | 利用前提=可向 0700 root 目录写文件（等价已失陷）；伪响应面已收窄 | P7 协议卫生（rid 段过 `ipc_err_sanitize` 或白名单） |
| **P6-04 §9.2** update 校验失败不回滚 | `ipc_op_update`「invalid after update」时先前 `tcfg_set_field` 改动已落盘（既有行为，P6-04 仅追加诊断文本） | 半更新态 task 文件（字段已改、校验不过） | P7 update 事务性增强（与 B9 同源） |
| **P6-04 §9.3** tctl 层详情仅在载荷行 | set_enabled/start/stop/restart/check 的 configuration_invalid 详情不并 ERROR 字段（tctl 层已有具体消息，非「stderr 丢弃」缺陷面） | 该组 op 首行第 4 段仍纯符号 | P7 统一口径（文档或实现裁决） |
| **O-P6-10-05** 真机控制三方竞速 | P6-10 §4（kill×startup IPC 饥饿×residual；#10 赢 / #15/16/17 输） | **非缺陷**：R7 在途判 FAILED 为既定语义；套件已改波 B 确定性取证 | 无产品改动（设计语义文档化已足） |
| **O-P6-10-06** `root=` 行 STOPPED 展示 | 根自然完成后 run.txt root 行镜像 STOPPED 与 run SUCCESS 并存（P6-10 §4） | 展示易误读，账本正确 | P7 展示语义微调 |
| **EX 相关（ADR §8 U 项 / EX-17 系）收口状态** | U-1 执行标记回读、U-2 引擎自持 PENDING 簿、U-3 注册时机（次 tick 登记）均已实施+宿主锁定+真机 R7 佐证；**DAG-EX-17a/b/c 已全部转 PASS**（177/0/0，P6-08/09 收口）；U-4「多根共享链真机**专项**演练」九场景未单列（真机已证分支/合流/9 链并发；宿主 F1 多根共享×3 代理） | 无遗留 FAIL/SKIP；U-4 为覆盖度缺口非缺陷 | P7 设备窗口补 U-4 专列用例（§6-P7 矩阵扩展条目一并跑） |
| P6-03 §8.1 `legacy_adapter_task_id` 未同步 sanitize | 导入命名空间 `t<line>_<norm>` 理论可含 `*`/`/`（config 首字段含通配符时）；不在 P6-03 任务书面 | 仅畸形手工 config 行可触发 | P7 裁决是否统一（触碰已导入 ID golden） |

---

## 5. 版本一致性与构建（本次实跑 p1-build 29/0 SKIP=0）

- **八处一致**：`module.prop`（version=`v1.6.8`/versionCode=`11608`）、`build.sh` `VERSION="v1.6.8"`、
  `system/bin/su-scheduler`/`su-schedulerd` `VERSION="1.6.8"`、`README.md` badge、
  `update.json`（version/versionCode + downloadURL 指向 v1.6.8 约定路径）、zip 内
  `su-scheduler-runtime` `RUNTIME_LIB_VERSION="1.32.0"`（本次 grep 复核全部一致）。
- **zip 完整性**：`build.sh` 产物 + `unzip -t`；zip 含 `module.prop/service.sh/customize.sh/system//webroot/`。
- **再生幂等**：二次构建 docs == pre-build snapshot（O-P6-10-04 收口断言）；zip docs 含 `chain` 行×2。
- **Runtime 独立版本线**：module v1.6.8 P6 全程不变；库 1.30.0→1.31.0（P6-06 feat）→1.32.0（P6-09 feat）；
  测试 pin 同步面（p4-dependency/p3-device）由 p1-build/聚合守卫。
- **设备双轨升级法**（真机验证过，P6-10 §9.2）：①模块目录文件同步（下次重启生效源）②当会话
  per-file bind mount（KSU×A16 boot-time tmpfs overlay 不可写 upper 的环境事实）；push 后强制
  chmod 755 再 mount（§9.6 纪律）。正规用户路径仍是 zip 安装+reboot（矩阵 §4 RB/UPGRADE 全过）。

---

## 6. 性能三点趋势（P6-01 → P6-07 → P6-11/出口复验）

### 6.1 scheduler_tick 三档（WSL 原生宿主 ≈0.2–0.5ms/fork；历史值引 P6-11 §2.1，本次评审复核在带内）

| 档 | P6-01（1.30） | P6-07（1.31 引擎后） | P6-11（1.32.0） | **本次评审复核** | 判定 |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 空 registry | 44ms | 50ms | 48–60ms | **50ms**（p6-reliability 单跑实测） | 无退化 |
| 50 任务纯决策 | 1731ms | 1672ms | 1614–1697ms | **1764ms**（本次实测，带内偏上——起测 load 3.1，同涨属环境噪声，A/B 口径） | 无退化 |
| 32 节点链满额稳态 | —（无引擎） | H1 pass 峰值 1223ms | 整 tick 1682–1741ms；首扫波 1724–1734ms | 聚合内 p6-verify §perf3 全 PASS（≤3000 绝对界 + A/B 地板） | 无病态回归 |

### 6.2 IPC 端到端延迟（P6-11 首次成文基线，本次评审 = 该基线之聚合复绿）

GET_TASKS 空载 max **94–106ms** ≤1000 · VALIDATE max **157–172ms** ≤1000 ·
GET_TASKS 50 任务 **963–1164ms** ≤2500（记录性）· `ipc_client_send` 真往返 **rc=0**
（墙钟 ~1030ms = 服务端 1s poll + 客户端 1s 轮询**双重粒度设计语义**，非回归量）。

### 6.3 压力面与 H6 注记

- resource 26/0 复跑（本次）：H1 1248ms / H2 606ms / H5 394ms / H5c 355ms 全带内（Δ≤+3%）。
- **H6 632→784ms（+24%）归因**：P6-10-fix D-P6-10-01 年龄钳制（`dag_token_age_le` 每登记候选一次
  awk 历法差）所致**常数开销**；仍 ≤2000ms 界内、无阶乘项——**非回归**，入趋势表如实注记。
- **无退化总裁决**：tick 三档、IPC、并发拒新波、稳态波全部带内；三点趋势无病态项。

---

## 7. 出口判定与待人工签核

**已满足**：出口条件 1–8、10（记录面）、11（本报告 + HANDOVER 交付即达成）——宿主回归
**51 套件 2449/0** + 惯例单跑套件 25/0·177/0、真机九场景 56/0/0（run#18 + 修后复跑记录）、
既有套件零回退、约束审计 C1–C5 全过、版本/构建全绿、缺陷闭环（7 修 + 12 登记台账）。

**条件 9（真机全链路）判定为「分项达成、组合未竟」**（见 §2 行 9），按 P0-D3/P5-10 先例转人工裁决。

### 待人工签核项（放行/不放行需逐条回答）

| # | 问题 | 背景与建议 |
| :-- | :-- | :-- |
| **Q1** | 是否接受 P6 出口在「`run_tests.sh --with-device` **组合单命令**全绿未竟」状态下放行？ | 同批断言 40 分钟前分项全绿（p1 11/0/2、p3 28/0、p6 修后 56/0/0）+ 组合跑宿主段全绿；败因=负载风暴+adb 失联环境项（P6-10 §9.4 trace `run_tests-20260910-180903.log`）。本次评审复测：设备 21:18 在网（新端口 42037，**未重启**）但 **load ~10 仍非安静窗**。建议：放行出口冻结 + 组合全绿列为下一窗口硬动作（Q2） |
| **Q2** | 是否授权并执行 `docs/P6-10.md §9.5` 下一窗口动作序：①链路恢复后 §7 步骤 2 **增量清理**组合遗留（MANAGED、`p6_*`/`p6_s*` HHMM 任务、p3 `t1_boot/t2_0830/edit1/hproc`、config `0830` 行——**先复位再动**，到点会真执行 echo 级无害任务，今日 08:30/19:17/19:36 可能已触发一次，盘点确认）②bind/staging 复核（未重启故当会话仍为修后码；staging **下次重启前勿删**）③安静窗 `run_tests.sh --with-device` 组合复跑（预期全绿）？ | 全部为既有 runbook/套件语义，无新操作面 |
| **Q3** | 是否接受设备矩阵 **1/15**、14 格 ⏳ 发布限制的放行方式（发布说明标注未验证组合；同 P0-D3/P5-10 先例）？ | 资源探查实证无 KVM/模拟器/Docker/第二设备（矩阵 §1.3）；扩展执行条件见 P6-HANDOVER §6 |
| **Q4** | O-P6-11-01（同日回滚再升级 catch-up 重放 ≤3 分钟窗）是否接受「已 LOCK 固化、语义变更会红」现状，策略裁决延至 P7？ | 真实升级路径（含重启）不触发（upg-7 证）；候选方案已在 §4.2 登记 |
| **Q5** | CI 是否授权 `test.yml` checkout 加 `fetch-depth:0`（使 p6-verify §upgrade 在 CI 真跑 8/8；现状自动 [SKIP] 不计失败）？ | 属 CI 配置变更（P6-11 §7-D），宿主全历史已实测绿 |

**tag 建议（本任务不执行）**：`p6-baseline-v1.6.8-runtime1.32.0`（延续 p5 tag 命名式）。

---

## 8. 已知 flake 台账（测试侧，非产品缺陷）

| 面 | 症状 | 记录 | 判别/处置惯例 |
| :-- | :-- | :-- | :-- |
| task-control IPC 时序 | 60/0 偶发 **59/1**（`stop rc=1` 而输出文本正确） | P6-04 §7、P6-07 §6 各 1 次（修前修后均现，与本阶段改动无关）；本次评审 60/0 | 独立重跑 ×3 + 以聚合内结果为准；出现即记录不改测试 |
| lifecycle（非 -prod）IPC 时序窗 | 同族瞬时 rc5/race 窗口 | P6-10 §5 迭代记录（rc5 快回重试族入 p6-device） | 同上；lifecycle-prod 围栏落地后 44/0 稳定（含本次） |
| **§perf 近界高负载误红** | 50 任务决策档 ~1700/2500、链档 ~1700/3000 在高负载宿主整体抬升 | P6-09 首现（1.69→1.76s 级抖动）；P6-11 起 **A/B 地板口径固化为测试内建**（参照档与受试档同涨=环境噪声放行，病态独涨必红）；本次评审实测 1764ms（load 3.1，同涨形态） | 复跑前 `uptime` 记录 load；误红争议按 A/B 取证流程（两档对照） |
| 设备段环境项 | p3-device 26/2（负载期 rc5 超时）、组合 p6 段 TIMEOUT、adb 失联 | P6-10 §5.3 四项（USB/无线掉线、用户 App 风暴、WSL interop、时钟窗）；本次评审复测 load ~10 证实风暴间歇仍在 | 真机矩阵任务须在**充电+锁屏静置/飞行**安静窗跑（矩阵 §5.3.4 建议） |
| 历史 flake 惯例 | WSL VM 空闲回收杀后台长套件（run#11） | P6-10 §5.3.3；本次评审改用 setsid+home 落日志+前台轮询保活 | 长套件前台+日志落 home |

---

## 9. 本次评审发现的分篇文档不一致清单（只登记，未擅改既有 P6-0x 分篇）

| # | 不一致 | 处置 |
| :-- | :-- | :-- |
| 1 | `docs/P6-06.md` §9 与 `dag-schema-v1.md` §7 行 5 引用设备链冒烟路径为 `tests/device/smoke.sh`（早期规划名）；实际交付 = `tests/p6-device/smoke.sh`（P6-10） | **登记**；本两份新文档一律用实路径。既有分篇不擅改（评审纪律）；建议 P7 文档卫生时统一或加历史注记 |
| 2 | `dag-schema-v1.md` §2 非字段常量表 = **7 常量**；P6-10-fix 已增第 8 个环境可覆盖常量 `DAG_SCAN_MAX_AGE_MIN=1440`（D-P6-10-01），ADR 表未回注（ADR 状态冻结不回改属惯例） | **登记**；权威语义见 `docs/P6-10.md` §4 与 P6-HANDOVER §4 速查（已并列注明） |
| 3 | 数字一致性：任务书引用的逐套件数字（25/177/82/47/30/56 与既有 49/220/60/137/8/183/64/17/29/35/56/54/60/20/25/60/26/37/29/44）与本次评审**实跑全部一致**，无一处漂移（2f86322 仅 docs 提交，预期如此） | 无需处置（核对项闭环）；ADR 状态=ACCEPTED 与 P6-05 签核、§7 实施标注（P6-06 §1 逐行）核对一致 |

> 除上述两条轻微命名/表列偏差外，未发现 P6 分篇间数字矛盾；交叉引用 56 处文件名 grep 核对，
> 除 #1 外全部命中存在文件（无死链）。

---

## 10. 交付与不交付声明

- 本任务交付 = 本文档 + `docs/P6-HANDOVER.md`；**零生产/测试代码改动**（`git status` 仅新增两文件）、
  **未 commit、未 push、未建 tag**（tag 建议见 §7，由人工裁决后执行）。
- P6 全程 24 项回归资产、P6-01..11 分篇文档、ADR（ACCEPTED）、设备矩阵与 §9.5 动作序共同构成
  P6 基线冻结证据链；出口冻结生效以人工对 Q1–Q5 裁决为准。
