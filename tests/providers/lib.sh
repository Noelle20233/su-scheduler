#!/system/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Provider 契约库（P1-04）— POSIX sh，可被 daemon source（C3 合规，无外部运行时）
# ═══════════════════════════════════════════════════════════════════════════
# 模型：Provider = kind + name + 函数前缀。
#   - kind: trigger | action | health | recovery（四类的能力表见下）
#   - name: 同一 kind 内唯一（如 trigger>boot、trigger>time、action>command）
#   - prefix: 该 Provider 全部能力函数的统一前缀（如 tpr_trigger_boot）
#   - 能力函数：<prefix>_<capability>，签名见 docs/architecture/provider-contracts.md
#
# 核心引擎（Supervisor）只依赖 provider_dispatch 这一个入口 —— 不依赖任何具体
# Provider 名字；新增 Provider = 注册一行 + 实现一组前缀函数，零核心改动
# （验收标准 2）。Provider 永不直接改任务状态机（P1-03）—— 只返回结果/退出码，
# 由引擎按桥接表用 cause 触发转换（见 provider-contracts.md §7）。
#
# 返回码约定（与 P1-03 校验函数同构）：
#   0 = 成功/允许
#   1 = 失败/错误/非法（调用方记录）
#   2 = 能力不支持/用法错误
# stdout 约定：每能力最多一行值（见能力契约）；所有日志走 provider_log 钩子。
# ═══════════════════════════════════════════════════════════════════════════

# ── 类型与能力表（单一事实源；tests/providers/test.sh 断言一致性）────────────
TPR_KINDS='trigger action health recovery'

TPR_CAPS_ALL='validate parse matches next_due prepare start stop status restart check recover'

# 每 kind 的能力子集：<cap> 允许；*<cap>* 标记"必备"（Provider 必须实现）
TPR_CAPS_TRIGGER='validate parse matches next_due'
TPR_CAPS_ACTION='validate prepare start stop status restart'
TPR_CAPS_HEALTH='validate check'
TPR_CAPS_RECOVERY='validate recover'

# 必备能力（Provider 注册时须具备；缺则注册被拒）
TPR_CAPS_REQUIRED='trigger>validate trigger>parse trigger>matches action>validate action>prepare action>start health>validate health>check recovery>validate recovery>recover'

# ── 注册表（静态注册，加载时由 providers.sh 调用 provider_register 填充）──────
TPR_REGISTRY=''

# ── 日志钩子（默认 stderr；TPR_LOG=0 静音；daemon 接线时覆盖为写 su-scheduler.log）
provider_log() {
    [ "${TPR_LOG:-1}" = "1" ] && echo "[provider] $1" >&2
}

# ── kind 合法性 ─────────────────────────────────────────────────────────────
provider_kind_is_valid() {
    case " $TPR_KINDS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── 能力合法性（全局集合 / kind 子集）────────────────────────────────────────
provider_cap_is_valid() {
    case " $TPR_CAPS_ALL " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

provider_cap_is_of_kind() {  # $1=cap $2=kind（无 eval；显式 case）
    cap=$1
    case "$2" in
        trigger)  case " $TPR_CAPS_TRIGGER " in *" $cap "*) return 0 ;; *) return 1 ;; esac ;;
        action)   case " $TPR_CAPS_ACTION " in *" $cap "*) return 0 ;; *) return 1 ;; esac ;;
        health)   case " $TPR_CAPS_HEALTH " in *" $cap "*) return 0 ;; *) return 1 ;; esac ;;
        recovery) case " $TPR_CAPS_RECOVERY " in *" $cap "*) return 0 ;; *) return 1 ;; esac ;;
        *) return 1 ;;
    esac
}

# ── 注册（静态）：provider_register <kind> <name> <prefix> ──────────────────
provider_register() {
    kind=$1; name=$2; prefix=$3
    provider_kind_is_valid "$kind" || { provider_log "register: unknown kind '$kind'"; return 1; }
    case " $TPR_REGISTRY " in
        *" $kind>$name>"*) provider_log "register: duplicate '$kind>$name'"; return 1 ;;
    esac
    TPR_REGISTRY="$TPR_REGISTRY $kind>$name>$prefix"
    return 0
}

# ── 查找：provider_lookup <kind> [name] → echo prefix；rc 0=找到 1=未找到 ───
provider_lookup() {
    kind=$1; name=${2:-}
    for entry in $TPR_REGISTRY; do
        f1=${entry%%>*}          # kind
        rest=${entry#*>}
        f2=${rest%%>*}           # name
        pre=${rest#*>}           # prefix
        if [ "$f1" = "$kind" ] && { [ -z "$name" ] || [ "$f2" = "$name" ]; }; then
            echo "$pre"
            return 0
        fi
    done
    return 1
}

# ── 分发入口（核心唯一依赖）：provider_dispatch <kind> <name> <cap> [args…] ─
# <kind> <name> 与注册表条目 "kind>name>prefix" 同序（先选 Provider，再选能力）。
# name 显式且必填（避免 'boot' 既是 Provider 名又是触发串的歧义）。
# 便捷入口 provider_dispatch_default <kind> <cap> [args…] = 该 kind 第一个已注册
# Provider（单 Provider 场景；多 Provider 必须显式点名）。
provider_dispatch() {
    kind=$1; name=$2; cap=$3
    shift 3
    provider_kind_is_valid "$kind" || { provider_log "dispatch: unknown kind '$kind'"; return 1; }
    provider_cap_is_valid "$cap" || { provider_log "dispatch: unknown capability '$cap'"; return 2; }
    provider_cap_is_of_kind "$cap" "$kind" || { provider_log "dispatch: capability '$cap' not in kind '$kind'"; return 2; }
    prefix=$(provider_lookup "$kind" "$name") || {
        provider_log "dispatch: no $kind provider named '$name' registered"
        return 1
    }
    fn="${prefix}_${cap}"
    type "$fn" >/dev/null 2>&1 || { provider_log "dispatch: provider '$prefix' lacks capability '$cap'"; return 2; }
    "$fn" "$@"
}

provider_dispatch_default() {  # <kind> <cap> [args…] — 取该 kind 第一个已注册 Provider
    kind=$1; cap=$2
    shift 2
    provider_kind_is_valid "$kind" || { provider_log "dispatch_default: unknown kind '$kind'"; return 1; }
    provider_cap_is_valid "$cap" || { provider_log "dispatch_default: unknown capability '$cap'"; return 2; }
    provider_cap_is_of_kind "$cap" "$kind" || { provider_log "dispatch_default: capability '$cap' not in kind '$kind'"; return 2; }
    prefix=$(provider_lookup "$kind") || {
        provider_log "dispatch_default: no $kind provider registered"
        return 1
    }
    fn="${prefix}_${cap}"
    type "$fn" >/dev/null 2>&1 || { provider_log "dispatch_default: provider '$prefix' lacks capability '$cap'"; return 2; }
    "$fn" "$@"
}