# Su Scheduler — P6-10 设备矩阵（设备矩阵扩展 · 真机验证）

> **任务**：P6-10 · 设备矩阵扩展（P6 收尾的设备面）
> **前置**：P6-01..09（Runtime 1.30.0→1.32.0；O-2 跳拍补偿、Cron ID、IPC 错误透传、
> Retry/Recovery、DAG 引擎/加固/可观测/CLI 全部已落地并宿主全绿）
> **日期**：2026-09-09 ～ 2026-09-10（跨夜间执行）
> **性质**：单机发布验证（本环境唯一真机 = KernelSU × Android 16）；其余 14 格按
> 资源探查结果如实登记发布限制，**不以宿主结果冒充真机格**。
> **矩阵格式延续**：docs/P3-DEVICE-MATRIX.md（P3-09/P4-01/P4-11）与 docs/P5-10.md。

---

## 0. 交付物与状态

| 交付物 | 状态 |
| :--- | :--- |
| tests/p6-device/smoke.sh（九场景真机固化，--serial/ANDROID_SERIAL 支持） | ✅ 56 断言（含波 A 四链 + kill + 波 B） |
| tests/run_tests.sh `--with-device` 注册（p1→p3→p6 设备段，p6 SUITE_TIMEOUT 5400s） | ✅ |
| docs/P6-10-DEVICE-MATRIX.md（本文档） | ✅ |
| docs/P6-10.md（执行记录 + 缺陷登记 + 遗留） | ✅ |
| 升级/回滚真机演练（P6 当前构建 ↔ P5 基线构建） | ✅ 完成一轮（§4） |
| 设备矩阵本机格（KernelSU × Android 16）九场景 | ✅ 全绿（run#18 全量 + 分项复跑） |

**本机格判定依据（关键运行）**：`bash tests/p6-device/smoke.sh --with-device
--serial 8934ffc4`（run#18，有线，设备安静）→ **PASS=56 FAIL=0 SKIP=0**（1692s，
trace `tests/results/device-8934ffc4-20260909-220714-p6.log`）。
既有套件零回退复跑：p3-device **28 PASS/0 FAIL/0 BLOCKED**（多次：22:4x 独立 +
23:20 + 02:16）；p1-device **11 PASS/0 FAIL/2 SKIP**（每次含汇总均保持）。
`run_tests.sh --with-device` 全绿汇总：设备段四连跑受**物理链路中断 ×2 与用户 App
负载**干扰未达全绿（明细 §5），p6 段失败均为环境/时序（同断言在安静设备 run#18 全绿）。

---

## 1. 设备矩阵（管理器 × Android 版本）

### 1.1 矩阵（✅=真机已验证；⏳=发布限制，不得伪造）

| 管理器 \ Android | 12 (API 31) | 13 (API 33) | 14 (API 34) | 15 (API 35) | 16 (API 36) |
| :-- | :--: | :--: | :--: | :--: | :--: |
| **KernelSU** | ⏳ | ⏳ | ⏳ | ⏳ | ✅ **本环境设备（P6-10 九场景全绿）** |
| **Magisk** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |
| **APatch** | ⏳ | ⏳ | ⏳ | ⏳ | ⏳ |

### 1.2 本环境设备详情（KernelSU × Android 16）

| 项 | 值 |
| :-- | :-- |
| adb serial | `8934ffc4`（USB）；后半夜 USB 掉线后同机回退到无线 `192.168.2.156:xxxxx`（`ro.serialno=8934ffc4`，同一物理设备） |
| product / model | `pudding` / `25113PN0EC`（Xiaomi 17） |
| Android | 16（API 36），arm64-v8a，SELinux Enforcing |
| Root 管理器 | KernelSU（`u:r:ksu:s0`） |
| 模块 | su-scheduler v1.6.8（**Runtime 库 v1.32.0**，WSL `bash build.sh`，zip sha256 `b04f4b2c…16449`） |
| 安装/回滚方式 | `ksud module install` → reboot 激活（modules_update→modules）；回滚=覆盖安装 P5 基线 zip（Runtime 1.30.0，sha256 `868217a1…cb294`）再 reboot |
| daemon | service.sh FBE 等待 → 看护拉起；`status` Alive；tick 稳态 ~60–70s（用户 App 负载期实测膨胀至 ≥120s，见 §5.3） |

### 1.3 其余 14 格资源探查（2026-09-09，严禁宿主冒充）

| 资源 | 探查结果 | 结论 |
| :-- | :-- | :-- |
| WSL `/dev/kvm` | 不存在（`HypervisorPresent=True` 但嵌套虚拟化未启用/不可用） | Android 模拟器（Google APIs，`adb root`）不可行 |
| emulator/avdmanager/sdkmanager/qemu/docker | 全部不存在；无 Android SDK 目录；Windows 侧仅 platform-tools | 无 x86/arm64 模拟器通道 |
| 真机（Magisk/APatch） | 本环境仅 1 台物理手机（KernelSU）；无第二台设备、无 root 管理器切换条件（解锁/boot 镜像重刷超出 P6-10 授权且属破坏性） | Magisk×5、APatch×5 格不可覆盖 |
| KernelSU × A12–A15 | 无对应设备/模拟器 | ⏳ 发布限制（延续 P3-09/P5-10 结论） |
| CI 设备 | GitHub Actions ubuntu runner 无 KVM/无 root 手机 | 不可作为真机格证据 |

**发布限制声明**：P6 全部功能（跳拍补偿、Cron ID、IPC 错误透传、DAG/链式、重试/恢复、
WebUI dag 键、CLI chain、升级/回滚兼容）真实验证仅覆盖 **KernelSU × Android 16（API 36）**
一列；Magisk / APatch 与 KernelSU × Android 12–15 组合发布说明须标注未验证。

---

## 2. P6-10 九场景逐条结果（KernelSU × Android 16 真机）

> 用例归属：1..10 号用例为 `tests/p6-device/smoke.sh` 用例前缀；证据行为
> run#18 trace（56/0/0）+ 关键失败迭代运行（run#12..17、汇总）的交叉印证。

### 2.1 场景 1 — 跳拍补偿（P6-02，O-2 收口）→ 用例 2-catchup

**方法**（真机时钟等价时序，不拨系统时钟）：同步到 tick(X) 完成（`last_tick==当前分钟
token`）→ 创建 trigger=X（本分钟）的 HHMM 精确任务与 `oneshot:X` → **回拨
`last_tick=X-1`** → 本分钟主循环窗口已过，唯一执行路径 = catch-up。
**证据**（run#18 trace）：

- `op=exec|task=p6_cupt1|…|catchup=1` 审计 + 磁盘 marker `catchup-ok`；
- `op=tick|…|catchup=n` 聚合行（late-tick tolerant 判据）；
- 过期 `oneshot:X` **不补偿**（零 exec 审计、零 marker）；
- 同窗恰一次（exec 计数跨 +65s 仍=1，无重复）；
- 重启（converge 冷启动）后 `last_tick` 持久并前进（`202609091831 -> 202609091835`），
  无重放（exec 计数仍=1）。
**结果**：✅（6 断言）

### 2.2 场景 2 — Cron ID（P6-03）→ 用例 3-cronid

`task-config new 'cron:0 8 * * *'` → `created task task_cron0_8__1`；ID 字符集
`[A-Za-z0-9._-]`、`task_cron*` 命名空间；`.task` 内 `trigger=cron:0 8 * * *`
**逐字保留**（空格不损）；穿越形 `'cron:../../etc/passwd'` → `task_cron_etc_passwd_1`
（文件名安全、无目录逃逸）；IPC `CREATE_TASK id=../evil` → `|1|invalid_request` 显式拒。
**结果**：✅（6 断言；run#13 曾因热机 `Terminated` 1 例，ctl_send 重试后稳定）

### 2.3 场景 3 — IPC 错误透传（P6-04）→ 用例 4-ipcerr

payload（editor 校验）通道：`oneshot:2460` → `configuration_invalid: trigger 'oneshot:2460'`
字段级原因；`VALIDATE_TASK trigger=0830`（缺 command）→ `configuration_invalid:
trigger+command required`（两类**可区分**，O-4 设备面收口）；1000 字符 trigger →
reason 截断至 256 + `...(truncated)`；三响应合并 grep `/data/adb` = 0（无内部路径泄露）。
**结果**：✅（5 断言）

### 2.4 场景 4 — DAG 执行（P6-06/07：线性/分支合流/失败传播/配置期拒/chain 子命令）
→ 用例 5-dagcfg + 6-dagwave

- 配置期拒：孤儿 `trigger=chain`（无入边）apply 拒不落盘；两文件成环 → 合并校验
  cycle 拒；深 17 梯子（>16）→ snapshot KEPT（`reason=dependency-graph-invalid`
  审计 / `chain` 的 validation_error）。✅（3 断言）
- 波次执行（真机分钟 tick）：线性 `ra→ab→ac` run=**SUCCESS**；分支合流
  `rb→(bb,bc)→bz` 达终局（kill 波内，见 2.6）；失败链 `rc→cf(exit1,retry.max=1)→cg`：
  cf **恰执行 2 次**（1+max 钳制）、cg **零执行**（Required 级联阻断）、
  `action=fail-propagate` 审计、run=FAILED；Optional `ya→(yc,?yb)`：yb FAILED
  不阻断 yc（opt-unsat，yc 实际执行）、run=FAILED（v1 语义）；`chain` 清单
  （4 链→波 B 后 5 链）与 `chain <member-id>` 反查归属根 + run_state。
**结果**：✅（9 断言 + chain 视图 2）

### 2.5 场景 5 — Retry/Recovery/Crash Loop（失败收敛、guard 无死循环）

真机面 = 2.4 的 cf 钳制（恰 2 次、无界复跑未现）+ rc 链终局 FAILED + p3-device 项
13（crash_guard 计数/降级/重置，28/0 复跑承载）+ guard 清冷（converge 清
`daemon.guard` 后重启不触发降级）+ 无重放（见 2.6）。宿主 25/0（p6-reliability）
与 168/0（p6-dag）同源背书。**结果**：✅（钳制/guard 断言；**例外**：D-P6-10-03
kill-after-respawn 微窗使 cf 复跑第 3 次一次——run#16 取证，已登记）

### 2.6 场景 6 — daemon 重启恢复（run 中途 kill 账本续跑不重放）→ 用例 7-dagkill

**方法**：五判据 kill 点（ra 终局 SUCCESS + rc/ya 终局 + rb 在途 + bb 活进程
state.txt=RUNNING，轮询 ≤420s）→ kill -9 持锁 daemon → service.sh 看护拉起。
**证据**（run#18）：watchdog 拉起 Alive ✅；同 token **不重复建 run**（dirs=1）✅；
**在途节点按 R7 收敛终态且零重派发**（`bb=FAILED`、`action=dispatch|task=p6_bb`
计数=1——真机澄清：R7 对重启时在途节点判 FAILED、活子进程由 reaper 收养至自然结束、
**不重派发**，「kill 时在途 + 合流 SUCCESS」不可能同窗成立，run#10 属相位运气）；
根 p6_ra 不重放（marker=1）✅；账本 `root=p6_ra|…` 行跨重启完整 ✅；
`action=complete` 双态审计 ✅。**结果**：✅（6 断言）

### 2.7 场景 7 — WebUI 查询与控制（dag 键、节点控制、链=批量）→ 用例 8-control + 9-webui

- **波 B（无 kill 确定性窗）**：`sb→(s1 sleep420, s2)→s3`：s1 在途期
  `STOP_TASK`（IPC 同源面）→ rc0 接受 → `state.txt=STOPPED` → **缺省边
  want=STOPPED 满足** → s3 放行执行 → run=**SUCCESS**（EX-12 真机闭环）。✅（4 断言）
- 批量：`task stop p6_ac p6_bz` → 逐任务结果行 ×2（「链=批量节点操作」IPC 实面）。✅
- 查询：`GET_SUMMARY` 含 `dag.active/dag.limit/dag.chains` + chains[] 视图数据
  （p6_ra 账本在列）；`GET_TASK_DETAIL.dag`：`chain_root=p6_ra`、
  `run_state=SUCCESS` 与账本一致；CLI `task status p6_ac` 链七键（chain_root/role=node
  …，P6-09 与 WebUI 同源）。✅（6 断言；GET_SUMMARY 真机时延实测 quiet 15–58s、
  负载期 >80s×5 ——O-P7-05 记录 §5.3）
- 浏览器渲染不作设备断言（宿主 p6-webui 82/0 背书）。

### 2.8 场景 8 — Legacy 回归（p1-device 承载）

`tests/p1-device/smoke.sh --skip-device` 环境全绿 + **每次真机跑均 11 PASS/0 FAIL/
2 SKIP**（22:4x 独立、23:0x/00:2x/02:1x/03:3x 汇总内），config.txt 逐字节自愈核对
（含回滚后旧 runtime 1.30.0 的 boot+HHMM 真执行，§4 RB-4）。**结果**：✅

### 2.9 场景 9 — 升级与回滚（当前构建 ↔ P5 基线）→ 矩阵人工演练（§4）

**结果**：✅（升级面=run#18 用例 1-module 常绿；回滚演练完整一轮，数据保险库保留）

---

## 3. 安装态预检与还原基线 → 用例 1-module / 10-restore

- 预检：ksud `module list` 含 su-scheduler、模块目录 runtime 文件在位、
  `Runtime library loaded (v1.32.0)`、daemon Alive（service.sh 看护）。✅
- 还原：清全部 p6 工件 → `mode=legacy`、Alive、**config.txt 逐字节一致**
  （md5 `d41d8cd9…427e`，空文件基线）——每次套件尾固定执行，矩阵可重复。✅

---

## 4. 升级/回滚真机演练（P6-10，2026-09-09 22:46 → 23:0x，KernelSU × Android 16）

**现场快照（破坏性步骤前）**：`/data/local/tmp/p6-snap/vault-pre-rollback-20260909-181735.tgz`
+ `22:52 vault-pre-rollback.tgz`（/data/adb/su-scheduler 全量 tar，rc=0）、
`config.pre-rollback`（md5 d41d8…=空基线逐字节）。

| 步骤 | 内容 | 结果 |
| :-- | :-- | :-- |
| PREP | 确认当前态 v1.6.8/**Runtime 1.32.0** 单实例 → `ksud module install ss-mod-p5.zip`（**P5 基线构建：git archive P5 时代码，Runtime 1.30.0**，同模块版本 v1.6.8/11608，sha256 868217a1…）→ modules_update 暂存 | ✅ |
| RB-1 | reboot 激活 → `sys.boot_completed=1`、`Runtime library loaded (v1.30.0)`、`status` Alive | ✅ **回滚生效** |
| RB-2 | 旧 runtime CLI 对未知 `chain` 子命令：优雅（usage/横幅，无崩溃、无副作用） | ✅ |
| RB-3 | 植入 P6 形数据：`dag/p6x/runs/…/run.txt`（P6 账本 schema）+ `MANAGED` + `trigger=chain` .task → 旧 runtime **无视不崩、账本树逐字节不变**（`find dag md5` 前后一致 `DAG_TREE_UNCHANGED`；3+ 拍、`su-scheduler restart` 后仍不变；chain marker 恒空=旧版永不派发链） | ✅ **旧版对 dag/ 数据兼容** |
| RB-4 | legacy 面：config 写 `boot` + `HHMM+2` → 旧 runtime 真执行（boot marker ✓ 时间 marker ✓），daemon 稳定 | ✅ |
| RB-5/6 | 审计行可读且为**旧格式（无 `catchup=` 字段）**= P6-02 只增字段的向下兼容实证；无 crash-loop | ✅ |
| UPGRADE | rb_final：清演练工件 → config 逐字节还原（d41d8…）→ `ksud module install ss-mod-p6.zip`（当前构建）→ reboot → `1.32.0` 加载 + Alive + legacy + 审计恢复 `catchup=0` 字段 | ✅ **升回最新** |

**升级/回滚结论**：P6→P5→P6 全链无损；数据保险库（vault/审计/schedule_state）保留；
旧版对 P6 账本数据**只读忽略**（前向兼容）；新版对旧版审计格式**只增字段**（后向兼容）。

---

## 5. 真机观测与限制记录（矩阵诚实面）

### 5.1 本轮新增缺陷登记（详见 docs/P6-10.md §缺陷）

| ID | 面 | 摘要 |
| :-- | :-- | :-- |
| D-P6-10-01 | 引擎（测试基建规避） | 历史 `cycle-*` 标记残留使旧 token 重登记为 PENDING 僵尸 run、占满 DAG_RUNS_MAX 名额饿死新链 → 套件 preflight 一并复位 cycle-*/last_tick（产品面建议：登记扫描加窗口/年龄钳制） |
| D-P6-10-02 | 锁接管竞态 | 高负载/看护并发期 cmd_stop 6s 等待超时删锁 → 新实例 noclobber 接管成功但**旧非持有者残留** → 双/三 daemon 同 tick（审计 2–3 行/分钟实证，02:10–02:23）→ 套件用确定性冷启动收敛+扫非持有者；**P6-10 后证：converge 收敛后仍可再起孪生**（重启风暴期），套件已加波 B 前补扫，产品面待专项 |
| D-P6-10-03 | 重试钳制缺口 | **kill -9 落在节点重试 respawn 后数秒**（start 与子进程完成写入之间的微窗）→ 恢复把该次判 daemon_restart 残留在途并清 retry 计数 → `retry.max=1` 节点实际执行 **3 次**（1+max+1），且发生在其链 run 已终局 FAILED 之后（run#16 取证：21:02:14 start / 21:02:18 kill / 21:03:10 run complete / 21:04:08 再 arm attempt=1 / 21:05:08 第 3 跑）。有界（+1）非无界循环；P6-07 F3 的 replenish 三工件存在时不生效。套件规避（kill 点等 rc 链终局）+ 产品待复现修复（宿主+设备双证） |
| O-P6-10-04 | 文档管线 | `build.sh` 由 **README 再生** `.su-scheduler-docs`，P6-09 向 HEAD 的 docs 文件手工加的 `chain` 行未同步 README → 任何构建后 git 工作树出现 docs 假性 dirty、且**出厂模块内文档缺 chain/新章节**（本次构建 zip 实证 `chain_line=0`）。修复属文档管线（P1/T4 类），登记不修 |
| O-P6-10-05 | 真机控制竞态（设计面） | kill×startup IPC 饥饿×residual 三方竞速：manual stop 想在 kill 波内赢过恢复判定不可稳定复现（run#10 赢、#15/16/17 输）→ 套件的 EX-12 取证改为**无 kill 波 B**（确定性）；产品语义本身（R7/EX-12）两路均已实证 |

### 5.2 既有套件保持

| 套件 | 基线 | P6-10 复跑 | 结论 |
| :-- | :-- | :-- | :-- |
| tests/p6-device/smoke.sh | （新建） | run#18 **56/0/0**（安静设备、有线）；#12..17 为判据迭代记录 | ✅ 九场景固化 |
| tests/p3-device/smoke.sh | 28/0 | 独立 + 汇总内多次 **28/0/0**；03:33 负载期 26/2（7/8 两项 rc5 超时，环境项，非回退——同夜安静期两次 28/0） | ✅ 零回退 |
| tests/p1-device/smoke.sh | 11/0/2SKIP | **每次 11/0/2** | ✅ 零回退 |
| tests/run_tests.sh（宿主 L1+L2+L4） | 全绿 | 每轮汇总宿主段全绿；p6-dag 168/0、p6-reliability 25/0 独立复跑 | ✅ 零回退 |

### 5.3 环境限制（不可控因素，全部有 trace 取证）

1. **USB 链路不稳定**：01:15 与 01:34 后有线掉线（同夜 17:57 亦发生一次）；04:20 起
   **无线 adb 亦掉线**，至本文档完成时设备不可达。掉线期套件输出空 token、有界等待
   相继超时（run_suite 900/3000s 强杀）→ 三张真机格汇总全绿未竟，非产品/测试逻辑问题。
2. **用户 App 负载**：02:1x–04:3x load1 7–10、MemFree ~120MB/15GB（com.baidu.tieba
   `:swan0/:media` 等后台）→ tick 60s→≥120s、IPC 预算膨胀 ≥20×、**连既有 p3-device 也
   降为 26/2**（7-webui/8-editor rc5）——同一批断言在安静设备全绿（#18/23:20/02:16）。
   测试侧对策：`[env]` 负载记录 + 沉降等待 ≤180s + 判据窗口放大 + rc5 快回重试
   （ipc_retry/ctl_send 5 轮）。
3. **WSL adb = Windows interop**：`adb push` 不认 `/mnt/d` 路径；全量设备命令统一走
   显式 `-s <serial>` 或 `ANDROID_SERIAL`。WSL VM 空闲回收曾杀死 17:33 挂起 run
   （run#11）→ 长套件一律前台+日志落 home。
4. **运行时钟窗**：套件避开 23:15–00:40 起波（分钟级跨午夜回绕）；夜间执行仍受
   用户 App 活跃期干扰 → 建议后续真机矩阵任务在**设备充电+锁屏静置/飞行**条件跑。

---

## 6. 性能统计（本机格，run#18 / 各轮汇总实测）

| 项 | 值 |
| :-- | :-- |
| p6-device 全套（安静设备，有线） | **1692s（~28min）**，56 断言 |
| p6-device 全套（负载期，无线） | 1201–3000s+（判据窗多被 20× 膨胀打穿） |
| tick 稳态间隔 | 60–70s；catch-up 积压拍 ~10–15s/拍 |
| GET_SUMMARY（dag 聚合，波后） | quiet **15–58s**；load1≈8 期 >80s×5 全超时（O-P7-05 真机时延项） |
| GET_TASK_DETAIL（dag） | 4–5s（负载期亦正常） |
| 看护拉起（kill -9 → status Alive） | 10–40s（service.sh 循环周期主导） |
| 重启一次（reboot→boot_completed） | ~40–60s |

---

## 7. 结论

- **KernelSU × Android 16 格**：P6-10 九必测场景全部真机达成（§2，run#18 56/0/0 +
  §4 升降级演练 + §2.8 legacy 复跑），既有设备套件零回退。
- 其余 **14 格维持 ⏳ 发布限制**（§1.3 资源探查：无 KVM/模拟器/Docker/第二设备），
  与前阶段结论一致，不伪造。
- `run_tests.sh --with-device` 在**链路稳定且设备安静**前提下具备全绿能力（p6 段
  全绿样本 run#18 + p1/p3 段全绿样本多次），本轮受物理链路两度中断与用户 App 负载
  阻断（§5.3），已按诚实原则如实登记；遗留恢复步骤见 docs/P6-10.md §现场。
