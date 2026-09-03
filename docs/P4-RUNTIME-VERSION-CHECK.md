# Su Scheduler — Runtime 版本检查纳入构建验证的方案（P4-RUNTIME-VERSION-CHECK）

> **任务**：P4-01 · P3 发布缺口与基线冻结（本文件为「Runtime 版本检查纳入构建验证
> 的方案」交付物）
> **日期**：2026-09-04
> **依据**：`docs/P3-ARCHITECTURE-DECISIONS.md` §5（决策 D4 版本策略）与 §8 风险
> **R4**（`RUNTIME_LIB_VERSION` 尚未纳入 build_check 版本一致性断言，建议补
> 「存在且语义化版本格式」断言）。P3-02 起持续登记但未实施；本方案在 P4 基线内闭环。

---

## 1. 背景与现状

- **模块版本 = 发布契约**（D4 §5.1）：`build.sh` `VERSION="v1.6.8"` 为单一事实源，
  `tests/p1-build/build_check.sh` 强制 8 处一致（module.prop / build.sh / 两 bin /
  README badge / update.json / .su-scheduler-docs）。
- **Runtime 库版本 = 内部实现线**（D4 §5.2）：`system/bin/su-scheduler-runtime`
  头部 `RUNTIME_LIB_VERSION="1.20.0"`，随 § 功能集合递增，**不参与**模块 8 处一致
  性校验（模块可不变、库递增；破坏性变更才要求模块 major 同步）。
- **现状缺口（R4）**：`RUNTIME_LIB_VERSION` **未纳入任何构建期断言**。当前守护仅
  靠 `runtime_lib_selfcheck`（运行期、缺失即拦）+ zip 成员存在性 + 文档人工维护
  （§9 版本表）。一旦 `RUNTIME_LIB_VERSION` 被误改/丢失/格式破坏，主机门禁无法在
  构建期发现，可能打包出「文档宣称 1.20.0、实际 1.19.0」的发布。

---

## 2. 目标

1. 在 **构建验证期**（`tests/p1-build/build_check.sh`，L4）拦截
   `RUNTIME_LIB_VERSION` 的缺失 / 非语义化 / 打包不一致；
2. 不改变 D4 的「模块版本 ≠ Runtime 版本」策略（两者仍各自独立演进）；
3. 保持 POSIX / 既有工具约束（C3：仅标准工具，不新增依赖）。

---

## 3. 方案设计（三项断言，全部落在 `tests/p1-build/build_check.sh`）

### 3.1 断言 A：`RUNTIME_LIB_VERSION` 存在且为语义化版本格式

```bash
# 期望：system/bin/su-scheduler-runtime 头部存在 RUNTIME_LIB_VERSION="X.Y.Z"（X/Y/Z 纯数字）
RVER=$(grep '^RUNTIME_LIB_VERSION=' system/bin/su-scheduler-runtime | head -1 | cut -d= -f2 | tr -d '"')
case "$RVER" in
    [0-9]*\.[0-9]*\.[0-9]*) ok "runtime lib version semantic: $RVER" ;;
    "") bad "runtime lib version missing" ;;
    *)  bad "runtime lib version malformed: [$RVER]" ;;
esac
```

- 判定：存在 + 匹配 `N.N.N`（N 为数字串，语义化版本；不校验递增——递增属 bump
  流程而非构建闸）。
- 归属：紧随现有「八处版本一致」段之后，独立断言，不并入模块版本集合（D4 隔离）。

### 3.2 断言 B：打包 zip 内 Runtime 版本与源文件一致

```bash
# 源文件 RUNTIME_LIB_VERSION（LF 归一）与 zip 内成员逐字比对（防打包截断/行尾污染）
unzip -p "$ZIP" system/bin/su-scheduler-runtime 2>/dev/null | tr -d '\r' \
    | grep '^RUNTIME_LIB_VERSION=' | head -1 | cut -d= -f2 | tr -d '"'
```

- 判定：与 3.1 提取值一致。该断言在 CRLF 检出下同样执行（`tr -d '\r'` 归一，
  与既有 build_check 的 CRLF 语义一致）；zip 不存在时沿用既有 CRLF SKIP 语义。

### 3.3 断言 C：文档版本表与 Runtime 版本一致（软校验）

- 现状：Runtime 版本随 P2-n/P3-n 文档登记（`P3-EXIT-REPORT` §版本表 /
  `P3-HANDOVER` 头部）。P4 建议把「当前 Runtime 版本」收敛为**单一事实源**——
  `docs/P4-RUNTIME-VERSION-CHECK.md` 或既有架构决策文档 §9 版本表。
- 判定（软）：`build_check.sh` 比对版本表记录的 `RUNTIME_LIB_VERSION` 与源文件
  一致；不一致输出 `[FAIL]`（阻止发布，防止文档-实现漂移）。版本表由
  `bump` 流程/人工维护，P4-01 先落地 3.1/3.2 硬断言，3.3 作为 P4 后续增强
  （待版本表单一化后接入，避免本任务引入新的多源维护负担）。

---

## 4. 实施边界（P4-01 落地范围）

| 项 | P4-01 落地 | 后续（P4 开发期） |
| :-- | :-- | :-- |
| 3.1 断言 A（存在+语义化） | ✅ 写入 `build_check.sh` | 保持 |
| 3.2 断言 B（zip 一致性） | ✅ 写入 `build_check.sh` | 保持 |
| 3.3 断言 C（文档版本表软校验） | ⏳ 登记为 P4 待办（版本表单一化后接入） | 随 P4 版本策略落地 |

> **P4-01 交付语义**：本任务交付**方案文档 + 断言 A/B 落地**（在 `tests/` 范围内，
> 不改生产代码），使 `build_check.sh` 输出含 Runtime 版本断言且全绿；断言 C 留待
> P4 版本表单一化后追加。方案若有取舍，以本文档为裁决记录。

---

## 5. 验收

```bash
bash tests/p1-build/build_check.sh
# 期望：输出含 "runtime lib version semantic: 1.20.0" 等 Runtime 断言，且全部 [PASS]

bash tests/run_tests.sh
# 期望：ALL SUITES GREEN（含 L4 build_check 新增断言），0 FAIL
```

- 回归：断言 A/B 不影响既有 8 处版本一致性、CRLF SKIP 语义与 `unzip -t` 完整性
  判定；P4-01 落地后实测 `p1-build tests: PASS=26 FAIL=0 SKIP=0`（既有 24 + 断言
  A + 断言 B）。
