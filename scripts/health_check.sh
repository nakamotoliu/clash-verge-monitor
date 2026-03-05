#!/bin/bash

###############################################################################
# Clash VPN 健康检查与智能切换 v2.1
#
# 新增（相对 v2）：
#   - 延迟检测：候选节点按延迟排序（Clash /delay API）
#   - 综合评分：延迟 + 稳定性惩罚（近期失败/隔离）
#   - 防抖切换：最小驻留时间 + 改善阈值（hysteresis）
#
# 设计目标：
#   1) 故障时优先切到“更快且更稳”的节点
#   2) 正常时不频繁追逐最低延迟，避免抖动和业务中断
#
###############################################################################

set -euo pipefail

# ==================== 配置区域 ====================
readonly SOCKET="/tmp/verge/verge-mihomo.sock"
SELECTOR="手动选择"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${LOG_FILE:-$PROJECT_ROOT/logs/clash_health.log}"
readonly LOCK_FILE="/tmp/clash_health_check.lock"

STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/data/state}"
CIRCUIT_BREAKER_FILE="$STATE_DIR/circuit_breaker.json"
QUARANTINE_FILE="$STATE_DIR/quarantine.json"
NODE_STATE_FILE="$STATE_DIR/node_state.json"

TELEGRAM_ACCOUNT="${TELEGRAM_ACCOUNT:-default}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"

# UI 配置文件（未来可由 Clash 客户端 UI 写入）
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/ui_config.json}"

# 超时设置（秒）
TIMEOUT_BASIC=5
TIMEOUT_API=10
SWITCH_WAIT=3
STABILIZE_WAIT=5

# 熔断配置
MAX_GLOBAL_FAILURES=3
CIRCUIT_BREAKER_COOLDOWN=1800     # 30 min
MAX_SWITCH_ATTEMPTS=5
NODE_QUARANTINE_TIME=1800         # 30 min

# 延迟检测配置
DELAY_TEST_URL="https://www.gstatic.com/generate_204"
DELAY_TIMEOUT_MS=5000
LATENCY_FAILOVER_IMPROVEMENT_MS=50   # 故障切换场景：至少快 50ms 视为显著
LATENCY_REBALANCE_IMPROVEMENT_MS=120 # 正常重平衡：至少快 120ms 才切
MIN_NODE_DWELL_SECONDS=1800          # 最小驻留 30 分钟，避免频繁切换
REBALANCE_CHECK_INTERVAL=6           # 每 N 次健康轮询才做一次重平衡检查

# canary URLs
CANARY_BASIC="https://www.baidu.com"
CANARY_CLOUDFLARE="https://1.1.1.1/cdn-cgi/trace"
CANARY_GOOGLE="https://www.google.com"

# 节点过滤（关键词/正则）
FILTER_EXCLUDE_REGEX="(hong.*kong|香港|^Expire:|^到期:|剩余流量|流量重置)"
FILTER_INCLUDE_REGEX=""

readonly HTTP_CODE_MIN=200
readonly HTTP_CODE_MAX=499

DRY_RUN=false
RESET_MODE=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${1:-}" == "--reset" ]] && RESET_MODE=true

# ==================== 初始化 ====================
init() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    [[ ! -f "$CIRCUIT_BREAKER_FILE" ]] && echo '{"failures":0,"opened_at":0}' > "$CIRCUIT_BREAKER_FILE"
    [[ ! -f "$QUARANTINE_FILE" ]] && echo '{}' > "$QUARANTINE_FILE"
    [[ ! -f "$NODE_STATE_FILE" ]] && cat > "$NODE_STATE_FILE" <<EOF
{"last_switch_at":0,"last_node":"","switch_count":0,"health_ok_count":0}
EOF

    if [[ "$RESET_MODE" == true ]]; then
        echo '{"failures":0,"opened_at":0}' > "$CIRCUIT_BREAKER_FILE"
        echo '{}' > "$QUARANTINE_FILE"
        cat > "$NODE_STATE_FILE" <<EOF
{"last_switch_at":0,"last_node":"","switch_count":0,"health_ok_count":0}
EOF
        echo "✅ 状态已重置（熔断/隔离/节点状态）"
        exit 0
    fi
}

load_ui_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local v
    v=$(jq -r '.selector // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" ]] && SELECTOR="$v"

    v=$(jq -r '.intervals.rebalanceCheckInterval // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && REBALANCE_CHECK_INTERVAL="$v"
    v=$(jq -r '.intervals.minNodeDwellSeconds // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && MIN_NODE_DWELL_SECONDS="$v"

    v=$(jq -r '.thresholds.failoverImprovementMs // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && LATENCY_FAILOVER_IMPROVEMENT_MS="$v"
    v=$(jq -r '.thresholds.rebalanceImprovementMs // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && LATENCY_REBALANCE_IMPROVEMENT_MS="$v"

    v=$(jq -r '.timers.timeoutBasicSeconds // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && TIMEOUT_BASIC="$v"
    v=$(jq -r '.timers.timeoutApiSeconds // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && TIMEOUT_API="$v"

    v=$(jq -r '.filters.excludeRegex // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" ]] && FILTER_EXCLUDE_REGEX="$v"
    v=$(jq -r '.filters.includeRegex // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$v" ]]; then
        FILTER_INCLUDE_REGEX="$v"
    fi
}

# ==================== 依赖检查 ====================
check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v openclaw >/dev/null 2>&1 || missing+=("openclaw")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ 缺少依赖: ${missing[*]}"
        exit 1
    fi

    if [[ ! -S "$SOCKET" ]]; then
        echo "❌ Clash socket 不存在: $SOCKET"
        exit 1
    fi
}

# ==================== 日志与通知 ====================
log() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

send_telegram() {
    local message="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] 跳过 Telegram: $message"
        return 0
    fi

    if [[ -z "$TELEGRAM_TARGET" ]]; then
        log "INFO" "未配置 TELEGRAM_TARGET，跳过通知: $message"
        return 0
    fi

    openclaw message send \
      --channel telegram \
      --account "$TELEGRAM_ACCOUNT" \
      --target "$TELEGRAM_TARGET" \
      --message "$message" 2>&1 | tee -a "$LOG_FILE" || true
}

# ==================== 状态管理 ====================
get_state_value() {
    local key="$1"
    jq -r ".$key" "$NODE_STATE_FILE" 2>/dev/null || echo ""
}

set_state_json() {
    local jq_expr="$1"
    local tmp
    tmp=$(mktemp)
    jq "$jq_expr" "$NODE_STATE_FILE" > "$tmp" && mv "$tmp" "$NODE_STATE_FILE"
}

touch_health_ok_counter() {
    set_state_json '.health_ok_count = ((.health_ok_count // 0) + 1)'
}

mark_switch() {
    local node="$1"
    local now
    now=$(date +%s)
    set_state_json ".last_switch_at=$now | .last_node=\"$node\" | .switch_count=((.switch_count // 0)+1)"
}

# ==================== 熔断器 ====================
check_circuit_breaker() {
    local now state opened_at failures elapsed remaining
    now=$(date +%s)
    state=$(cat "$CIRCUIT_BREAKER_FILE")
    opened_at=$(echo "$state" | jq -r '.opened_at')
    failures=$(echo "$state" | jq -r '.failures')

    if [[ "$opened_at" -gt 0 ]]; then
        elapsed=$((now - opened_at))
        if [[ $elapsed -lt $CIRCUIT_BREAKER_COOLDOWN ]]; then
            remaining=$((CIRCUIT_BREAKER_COOLDOWN - elapsed))
            log "WARN" "🔴 熔断中，剩余冷却: ${remaining}s（累计故障: $failures）"
            return 1
        else
            log "INFO" "🟢 熔断冷却结束，恢复检测"
            echo '{"failures":0,"opened_at":0}' > "$CIRCUIT_BREAKER_FILE"
        fi
    fi
    return 0
}

record_global_failure() {
    local now state failures
    now=$(date +%s)
    state=$(cat "$CIRCUIT_BREAKER_FILE")
    failures=$(echo "$state" | jq -r '.failures')
    failures=$((failures + 1))

    if [[ $failures -ge $MAX_GLOBAL_FAILURES ]]; then
        echo "{\"failures\":$failures,\"opened_at\":$now}" > "$CIRCUIT_BREAKER_FILE"
        log "ERROR" "🔴 触发熔断：连续 $failures 次全局故障"
        send_telegram "🔴 VPN 熔断触发\n连续 $failures 次全局故障\n冷却 ${CIRCUIT_BREAKER_COOLDOWN}s"
    else
        echo "{\"failures\":$failures,\"opened_at\":0}" > "$CIRCUIT_BREAKER_FILE"
        log "WARN" "全局故障计数: $failures/$MAX_GLOBAL_FAILURES"
    fi
}

reset_failure_count() {
    echo '{"failures":0,"opened_at":0}' > "$CIRCUIT_BREAKER_FILE"
}

# ==================== 节点隔离 ====================
node_key() {
    echo -n "$1" | base64 | tr -d '\n'
}

is_node_quarantined() {
    local node="$1" now key until remaining
    now=$(date +%s)
    key=$(node_key "$node")
    until=$(jq -r --arg k "$key" '.[$k] // 0' "$QUARANTINE_FILE")

    if [[ "$until" -gt "$now" ]]; then
        remaining=$((until - now))
        log "DEBUG" "节点 [$node] 隔离中，剩余 ${remaining}s"
        return 0
    fi
    return 1
}

quarantine_node() {
    local node="$1" now until key tmp
    now=$(date +%s)
    until=$((now + NODE_QUARANTINE_TIME))
    key=$(node_key "$node")
    tmp=$(mktemp)
    jq --arg k "$key" --argjson v "$until" '. + {($k): $v}' "$QUARANTINE_FILE" > "$tmp" && mv "$tmp" "$QUARANTINE_FILE"
    log "INFO" "🚫 节点 [$node] 隔离 ${NODE_QUARANTINE_TIME}s"
}

cleanup_quarantine() {
    local now tmp
    now=$(date +%s)
    tmp=$(mktemp)
    jq --argjson now "$now" 'to_entries | map(select(.value > $now)) | from_entries' "$QUARANTINE_FILE" > "$tmp" && mv "$tmp" "$QUARANTINE_FILE"
}

# ==================== Clash API ====================
uri_encode() {
    jq -nr --arg v "$1" '$v|@uri'
}

clash_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local curl_opts=(--unix-socket "$SOCKET" -s -X "$method")
    if [[ -n "$data" ]]; then
        curl_opts+=( -H "Content-Type: application/json" -d "$data" )
    fi

    curl "${curl_opts[@]}" "http://localhost${endpoint}" 2>/dev/null
}

get_current_node() {
    local selector_encoded
    selector_encoded=$(uri_encode "$SELECTOR")
    clash_api "GET" "/proxies/$selector_encoded" | jq -r '.now' 2>/dev/null
}

get_available_nodes() {
    local nodes selector_encoded
    selector_encoded=$(uri_encode "$SELECTOR")
    nodes=$(clash_api "GET" "/proxies/$selector_encoded" \
      | jq -r '.all[]' 2>/dev/null \
      | grep -vE "^(DIRECT|REJECT)$")

    if [[ -n "$FILTER_EXCLUDE_REGEX" ]]; then
        nodes=$(echo "$nodes" | grep -viE "$FILTER_EXCLUDE_REGEX" || true)
    fi

    if [[ -n "$FILTER_INCLUDE_REGEX" ]]; then
        nodes=$(echo "$nodes" | grep -iE "$FILTER_INCLUDE_REGEX" || true)
    fi

    echo "$nodes"
}

switch_node() {
    local node="$1" selector_encoded
    selector_encoded=$(uri_encode "$SELECTOR")
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] 模拟切换到: $node"
        mark_switch "$node"
        return 0
    fi

    log "INFO" "🔄 切换节点: $node"
    if ! clash_api "PUT" "/proxies/$selector_encoded" "{\"name\":\"$node\"}" >/dev/null; then
        log "ERROR" "切换节点失败: $node"
        return 1
    fi

    sleep "$SWITCH_WAIT"
    mark_switch "$node"
    return 0
}

get_node_delay_ms() {
    local node="$1"
    local encoded url_encoded resp delay
    encoded=$(uri_encode "$node")
    url_encoded=$(uri_encode "$DELAY_TEST_URL")

    resp=$(clash_api "GET" "/proxies/${encoded}/delay?timeout=${DELAY_TIMEOUT_MS}&url=${url_encoded}") || true
    delay=$(echo "$resp" | jq -r '.delay // -1' 2>/dev/null || echo -1)

    if [[ "$delay" =~ ^[0-9]+$ ]] && [[ "$delay" -ge 0 ]]; then
        echo "$delay"
    else
        echo -1
    fi
}

# ==================== 故障分类 ====================
check_url() {
    local url="$1" timeout="$2" http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" -ge "$HTTP_CODE_MIN" && "$http_code" -le "$HTTP_CODE_MAX" ]]; then
        return 0
    fi
    return 1
}

# 0 正常
# 1 VPN/节点故障（可切换）
# 2 Cloudflare 全局故障（不切）
# 3 上游 API 故障（不切）
# 4 本地网络故障（不切）
classify_fault() {
    local basic_ok=false cloudflare_ok=false google_ok=false openai_ok=false anthropic_ok=false

    check_url "$CANARY_BASIC" "$TIMEOUT_BASIC" && basic_ok=true
    check_url "$CANARY_CLOUDFLARE" "$TIMEOUT_BASIC" && cloudflare_ok=true
    check_url "$CANARY_GOOGLE" "$TIMEOUT_BASIC" && google_ok=true
    check_url "https://api.openai.com/v1/models" "$TIMEOUT_API" && openai_ok=true
    check_url "https://api.anthropic.com" "$TIMEOUT_API" && anthropic_ok=true

    [[ "$basic_ok" == true ]] && log "DEBUG" "✅ 基础网络正常" || log "DEBUG" "❌ 基础网络异常"
    [[ "$cloudflare_ok" == true ]] && log "DEBUG" "✅ Cloudflare 正常" || log "DEBUG" "❌ Cloudflare 异常"
    [[ "$google_ok" == true ]] && log "DEBUG" "✅ Google 正常" || log "DEBUG" "❌ Google 异常"
    [[ "$openai_ok" == true ]] && log "DEBUG" "✅ OpenAI 正常" || log "DEBUG" "❌ OpenAI 异常"
    [[ "$anthropic_ok" == true ]] && log "DEBUG" "✅ Anthropic 正常" || log "DEBUG" "❌ Anthropic 异常"

    if [[ "$google_ok" == true && "$openai_ok" == true && "$anthropic_ok" == true ]]; then
        return 0
    fi

    if [[ "$basic_ok" == false ]]; then
        return 4
    fi

    if [[ "$google_ok" == false ]]; then
        return 1
    fi

    if [[ "$cloudflare_ok" == false && "$openai_ok" == false ]]; then
        return 2
    fi

    if [[ "$google_ok" == true && "$openai_ok" == false && "$anthropic_ok" == false ]]; then
        return 3
    fi

    return 1
}

# ==================== 延迟评分与选择 ====================
# 输出："node<TAB>delay<TAB>score"
rank_candidates() {
    local current_node="$1"
    local -a nodes
    local node delay score penalty

    while IFS= read -r node; do
        [[ -n "$node" ]] && nodes+=("$node")
    done < <(get_available_nodes)

    for node in "${nodes[@]}"; do
        [[ -z "$node" ]] && continue
        [[ "$node" == "$current_node" ]] && continue

        # 隔离中的直接跳过
        if is_node_quarantined "$node"; then
            continue
        fi

        delay=$(get_node_delay_ms "$node")
        if [[ "$delay" -lt 0 ]]; then
            # 无法测延迟，给高惩罚
            score=99999
        else
            penalty=0
            # 可扩展：按地区/历史失败给 penalty，这里先保留接口
            score=$((delay + penalty))
        fi

        echo -e "${node}\t${delay}\t${score}"
    done | sort -t$'\t' -k3,3n
}

# 正常态重平衡（防抖）：
# - 不在每次检查都切
# - 最小驻留时间未到不切
# - 改善幅度不够不切
maybe_rebalance_when_healthy() {
    local current_node="$1"
    local ok_count last_switch_at now dwell best_line best_node best_delay current_delay improvement

    ok_count=$(get_state_value "health_ok_count")
    [[ -z "$ok_count" || "$ok_count" == "null" ]] && ok_count=0

    # 不是每轮都做延迟重平衡，降低扰动
    if (( ok_count % REBALANCE_CHECK_INTERVAL != 0 )); then
        log "DEBUG" "跳过重平衡检查（health_ok_count=$ok_count）"
        return 0
    fi

    current_delay=$(get_node_delay_ms "$current_node")
    if [[ "$current_delay" -lt 0 ]]; then
        log "DEBUG" "当前节点延迟不可测，跳过重平衡"
        return 0
    fi

    best_line=$(rank_candidates "$current_node" | head -1 || true)
    [[ -z "$best_line" ]] && return 0

    best_node=$(echo "$best_line" | awk -F'\t' '{print $1}')
    best_delay=$(echo "$best_line" | awk -F'\t' '{print $2}')

    [[ "$best_delay" -lt 0 ]] && return 0

    improvement=$((current_delay - best_delay))
    last_switch_at=$(get_state_value "last_switch_at")
    [[ -z "$last_switch_at" || "$last_switch_at" == "null" ]] && last_switch_at=0
    now=$(date +%s)
    dwell=$((now - last_switch_at))

    log "INFO" "重平衡评估: current=${current_node}(${current_delay}ms), best=${best_node}(${best_delay}ms), improvement=${improvement}ms, dwell=${dwell}s"

    if (( dwell < MIN_NODE_DWELL_SECONDS )); then
        log "INFO" "防抖: 驻留未满 ${MIN_NODE_DWELL_SECONDS}s，不切换"
        return 0
    fi

    if (( improvement < LATENCY_REBALANCE_IMPROVEMENT_MS )); then
        log "INFO" "防抖: 改善不足 ${LATENCY_REBALANCE_IMPROVEMENT_MS}ms，不切换"
        return 0
    fi

    # 满足条件才切（较少发生）
    log "WARN" "⚖️ 触发重平衡切换: $current_node(${current_delay}ms) -> $best_node(${best_delay}ms)"
    if switch_node "$best_node"; then
        send_telegram "⚖️ 节点重平衡\n$current_node(${current_delay}ms) → $best_node(${best_delay}ms)\n改善 ${improvement}ms"
    fi
}

# ==================== 故障切换（按延迟+稳定性） ====================
smart_switch() {
    local current_node="$1"
    local current_delay best_line best_node best_delay best_score attempt=0

    current_delay=$(get_node_delay_ms "$current_node")
    [[ "$current_delay" -lt 0 ]] && current_delay=99999

    log "WARN" "⚠️ 当前节点 [$current_node] 故障，开始智能切换..."
    send_telegram "⚠️ VPN 节点故障\n当前: $current_node\n开始智能切换（含延迟评分）"

    cleanup_quarantine
    quarantine_node "$current_node"

    # 按 score 从低到高挑节点，最多尝试 N 次
    while IFS=$'\t' read -r best_node best_delay best_score; do
        [[ -z "${best_node:-}" ]] && continue
        ((attempt++))
        if (( attempt > MAX_SWITCH_ATTEMPTS )); then
            break
        fi

        # 如果延迟改善非常有限，且不是首次尝试，可跳过，避免无意义切换
        if [[ "$best_delay" =~ ^[0-9]+$ ]] && (( best_delay >= 0 )); then
            if (( current_delay - best_delay < LATENCY_FAILOVER_IMPROVEMENT_MS && attempt > 1 )); then
                log "INFO" "跳过候选 [$best_node]：延迟改善不足 ${LATENCY_FAILOVER_IMPROVEMENT_MS}ms"
                continue
            fi
        fi

        log "INFO" "🔍 尝试节点 [$best_node] delay=${best_delay}ms score=${best_score} (${attempt}/${MAX_SWITCH_ATTEMPTS})"

        if ! switch_node "$best_node"; then
            quarantine_node "$best_node"
            continue
        fi

        sleep "$STABILIZE_WAIT"

        # 切过去后重新判定故障类型
        local fault_type
        if classify_fault; then
            fault_type=0
        else
            fault_type=$?
        fi

        if [[ $fault_type -eq 0 ]]; then
            log "INFO" "✅ 切换成功: $best_node"
            reset_failure_count
            send_telegram "✅ VPN 恢复\n新节点: $best_node\n延迟: ${best_delay}ms\n尝试次数: $attempt"
            return 0
        fi

        if [[ $fault_type -eq 2 || $fault_type -eq 3 || $fault_type -eq 4 ]]; then
            log "WARN" "检测到非节点级故障（type=$fault_type），停止继续切换"
            record_global_failure
            return 1
        fi

        log "WARN" "❌ 节点 [$best_node] 仍不可用，加入隔离"
        quarantine_node "$best_node"
    done < <(rank_candidates "$current_node")

    log "ERROR" "❌ 未找到可用节点（已尝试 $attempt 个）"
    record_global_failure
    send_telegram "🚨 节点切换失败\n尝试 $attempt 个候选仍不可用"
    return 1
}

# ==================== 并发保护 ====================
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
        if (( lock_age < 300 )); then
            log "WARN" "检测到实例运行中，跳过本次"
            exit 0
        else
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT
}

# ==================== 主逻辑 ====================
main() {
    init
    check_dependencies
    load_ui_config
    acquire_lock

    log "INFO" "========== 开始健康检查 v2.1 =========="
    [[ "$DRY_RUN" == true ]] && log "INFO" "⚠️ DRY-RUN 模式"

    if ! check_circuit_breaker; then
        log "INFO" "========== 完成：熔断冷却中 =========="
        exit 0
    fi

    local current_node
    current_node=$(get_current_node) || {
        log "ERROR" "无法获取当前节点"
        exit 1
    }
    log "INFO" "当前节点: $current_node"

    local fault_type=0
    if classify_fault; then
        fault_type=0
    else
        fault_type=$?
    fi

    case $fault_type in
        0)
            log "INFO" "✅ 服务健康"
            reset_failure_count
            touch_health_ok_counter
            maybe_rebalance_when_healthy "$current_node"
            log "INFO" "========== 完成：正常 =========="
            ;;
        1)
            log "WARN" "⚠️ 节点级故障，开始故障切换"
            if smart_switch "$current_node"; then
                log "INFO" "========== 完成：已切换 =========="
                exit 0
            else
                log "ERROR" "========== 完成：切换失败 =========="
                exit 1
            fi
            ;;
        2)
            log "WARN" "⚠️ Cloudflare 全局故障（不切节点）"
            record_global_failure
            send_telegram "⚠️ 疑似 Cloudflare 故障\n当前节点: $current_node\n已暂停切换，等待恢复"
            ;;
        3)
            log "WARN" "⚠️ 上游 API 故障（不切节点）"
            record_global_failure
            send_telegram "⚠️ 疑似上游 API 故障\nOpenAI/Anthropic 同时异常\n已暂停切换"
            ;;
        4)
            log "WARN" "⚠️ 本地网络故障（不切节点）"
            record_global_failure
            send_telegram "⚠️ 本地网络异常\n请检查本机网络/路由"
            ;;
    esac
}

main "$@"
