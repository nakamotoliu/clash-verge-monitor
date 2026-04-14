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

# 邮件告警配置（默认开启）
MAIL_TO="${MAIL_TO:-}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[Clash HealthCheck]}"
MAIL_SENDER_SCRIPT="${MAIL_SENDER_SCRIPT:-$HOME/clawd/projects/clash-verge-monitor/scripts/send_email_126.py}"

# UI 配置文件（未来可由 Clash 客户端 UI 写入）
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/ui_config.json}"

# 超时设置（秒）
TIMEOUT_BASIC=3
TIMEOUT_API=5
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

# 响应时间健康阈值（毫秒）
# 超过此阈值视为"慢速降级"，连续多次触发切换
SLOW_THRESHOLD_BASIC_MS=1000         # 基础网络/Google：1 秒算慢
SLOW_THRESHOLD_API_MS=2000           # 大模型 API：2 秒算慢
SLOW_CONSECUTIVE_LIMIT=3             # 连续 N 次慢速才触发切换（防偶发抖动）

# canary URLs
CANARY_BASIC="https://www.baidu.com"
CANARY_CLOUDFLARE="https://1.1.1.1/cdn-cgi/trace"
CANARY_GOOGLE="https://www.google.com"
CANARY_TELEGRAM="https://api.telegram.org"

# 节点过滤（关键词/正则）
FILTER_EXCLUDE_REGEX="(hong.*kong|香港|^Traffic:|^Expire:|^到期:|^Sync:|剩余流量|流量重置|^自动选择$)"
FILTER_INCLUDE_REGEX=""

readonly HTTP_CODE_MIN=200
readonly HTTP_CODE_MAX=499

DRY_RUN=false
RESET_MODE=false
STATS_MODE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --reset) RESET_MODE=true ;;
        --stats) STATS_MODE=true ;;
    esac
done

# ==================== 初始化 ====================
init() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    [[ ! -f "$CIRCUIT_BREAKER_FILE" ]] && echo '{"failures":0,"opened_at":0}' > "$CIRCUIT_BREAKER_FILE"
    [[ ! -f "$QUARANTINE_FILE" ]] && echo '{}' > "$QUARANTINE_FILE"
    [[ ! -f "$NODE_STATE_FILE" ]] && cat > "$NODE_STATE_FILE" <<EOF
{"last_switch_at":0,"last_node":"","switch_count":0,"health_ok_count":0}
EOF

    if [[ "$STATS_MODE" == true ]]; then
        show_stats
        exit 0
    fi

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
    v=$(jq -r '.thresholds.slowBasicMs // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && SLOW_THRESHOLD_BASIC_MS="$v"
    v=$(jq -r '.thresholds.slowApiMs // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && SLOW_THRESHOLD_API_MS="$v"
    v=$(jq -r '.thresholds.slowConsecutiveLimit // empty' "$CONFIG_FILE" 2>/dev/null || true); [[ -n "$v" && "$v" != "null" ]] && SLOW_CONSECUTIVE_LIMIT="$v"

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

# 日志级别过滤：DEBUG < INFO < WARN < ERROR
# 通过环境变量 LOG_LEVEL 控制，默认 INFO（生产环境不刷 DEBUG）
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# 日志轮转配置
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-1024}"       # 单文件最大 1MB
LOG_KEEP_FILES="${LOG_KEEP_FILES:-7}"            # 保留最近 7 个轮转文件
LOG_ARCHIVE_DIR="${LOG_ARCHIVE_DIR:-$(dirname "$LOG_FILE")/archive}"

_log_level_num() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO)  echo 1 ;;
        WARN)  echo 2 ;;
        ERROR) echo 3 ;;
        *)     echo 1 ;;
    esac
}

_should_log() {
    local msg_level="$1"
    local threshold="$LOG_LEVEL"
    [[ $(_log_level_num "$msg_level") -ge $(_log_level_num "$threshold") ]]
}

_rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return 0
    local size_kb
    size_kb=$(( $(wc -c < "$LOG_FILE") / 1024 ))
    if (( size_kb < LOG_MAX_SIZE_KB )); then
        return 0
    fi

    mkdir -p "$LOG_ARCHIVE_DIR"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local archived="${LOG_ARCHIVE_DIR}/clash_health_${timestamp}.log"

    mv "$LOG_FILE" "$archived"
    # 可选：压缩归档
    gzip "$archived" 2>/dev/null || true
    touch "$LOG_FILE"

    # 清理超额的旧归档
    local count
    count=$(ls -1 "$LOG_ARCHIVE_DIR"/clash_health_*.log* 2>/dev/null | wc -l)
    if (( count > LOG_KEEP_FILES )); then
        ls -1t "$LOG_ARCHIVE_DIR"/clash_health_*.log* | tail -n +$((LOG_KEEP_FILES + 1)) | xargs rm -f 2>/dev/null || true
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 日志已轮转 → ${archived}.gz（保留最近 ${LOG_KEEP_FILES} 份）" >> "$LOG_FILE"
}

log() {
    local level="${1:-INFO}"
    local message="$2"

    # 级别过滤
    _should_log "$level" || return 0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

has_duplicate_process() {
    local self_pid parent_pid script_path count
    self_pid=$$
    parent_pid=$PPID
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    count=$(ps -axo pid=,ppid=,command= | awk -v self="$self_pid" -v parent="$parent_pid" -v path="$script_path" '
        index($0, path) > 0 {
            pid=$1
            ppid=$2
            if (pid != self && pid != parent) count++
        }
        END { print count+0 }
    ')

    (( count > 0 ))
}

send_telegram() {
    local message="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] 跳过 Telegram: $message"
        return 0
    fi

    if [[ -z "$TELEGRAM_TARGET" ]]; then
        log "DEBUG" "未配置 TELEGRAM_TARGET，跳过 Telegram"
        return 0
    fi

    local output
    output=$(openclaw message send \
      --channel telegram \
      --account "$TELEGRAM_ACCOUNT" \
      --target "$TELEGRAM_TARGET" \
      --message "$message" 2>&1) || true
    [[ -n "$output" ]] && log "DEBUG" "Telegram 发送: $output"
}

send_email() {
    local subject="$1"
    local body="$2"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] 跳过 Email: $subject"
        return 0
    fi

    if [[ -z "$MAIL_TO" ]]; then
        log "DEBUG" "未配置 MAIL_TO，跳过 Email"
        return 0
    fi

    if [[ ! -f "$MAIL_SENDER_SCRIPT" ]]; then
        log "WARN" "邮件脚本不存在: $MAIL_SENDER_SCRIPT"
        return 0
    fi

    local output
    output=$(python3 "$MAIL_SENDER_SCRIPT" "$MAIL_TO" "$subject" "$body" 2>&1) || true
    [[ -n "$output" ]] && log "DEBUG" "邮件发送: $output"
}

send_alert() {
    local title="$1"
    local message="$2"
    local subject="${MAIL_SUBJECT_PREFIX} ${title}"

    send_telegram "$message"
    send_email "$subject" "$message"
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

# ==================== 统计与日志查询 ====================

# 每日统计文件
_daily_stats_file() {
    echo "$STATE_DIR/stats_$(date '+%Y-%m-%d').json"
}

_init_daily_stats() {
    local f
    f=$(_daily_stats_file)
    [[ -f "$f" ]] && return 0
    cat > "$f" <<'STATS'
{"date":"'$(date '+%Y-%m-%d')'","checks":0,"healthy":0,"faults":{"vpn":0,"cf":0,"api":0,"local":0,"slow":0},"switches":0,"circuit_breaks":0}
STATS
    # fix the date inside the file
    local today
    today=$(date '+%Y-%m-%d')
    local tmp; tmp=$(mktemp)
    jq --arg d "$today" '.date=$d' "$f" > "$tmp" && mv "$tmp" "$f"
}

_bump_daily_stat() {
    local key="$1"
    local f
    f=$(_daily_stats_file)
    _init_daily_stats
    local tmp; tmp=$(mktemp)
    jq ".$key += 1" "$f" > "$tmp" && mv "$tmp" "$f"
}

_bump_daily_fault() {
    local fault_type="$1"
    local f
    f=$(_daily_stats_file)
    _init_daily_stats
    local tmp; tmp=$(mktemp)
    jq ".faults.$fault_type += 1" "$f" > "$tmp" && mv "$tmp" "$f"
}

show_stats() {
    local today yesterday
    today=$(date '+%Y-%m-%d')
    yesterday=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || echo "unknown")

    echo "═══════════════════════════════════════"
    echo "  Clash Monitor 运行统计"
    echo "═══════════════════════════════════════"

    # 节点状态
    echo ""
    echo "📍 当前状态:"
    local state
    state=$(cat "$NODE_STATE_FILE" 2>/dev/null || echo '{}')
    local last_node ok_count switch_count last_switch
    last_node=$(echo "$state" | jq -r '.last_node // "未知"')
    ok_count=$(echo "$state" | jq -r '.health_ok_count // 0')
    switch_count=$(echo "$state" | jq -r '.switch_count // 0')
    last_switch=$(echo "$state" | jq -r '.last_switch_at // 0')
    if [[ "$last_switch" -gt 0 ]]; then
        local elapsed=$(( $(date +%s) - last_switch ))
        local hours=$((elapsed / 3600))
        local mins=$(( (elapsed % 3600) / 60 ))
        echo "   最后切换节点: $last_node（${hours}h${mins}m 前）"
    else
        echo "   最后切换节点: $last_node"
    fi
    echo "   累计健康检查: $ok_count 次"
    echo "   累计节点切换: $switch_count 次"

    # 熔断状态
    local cb
    cb=$(cat "$CIRCUIT_BREAKER_FILE" 2>/dev/null || echo '{}')
    local failures opened
    failures=$(echo "$cb" | jq -r '.failures // 0')
    opened=$(echo "$cb" | jq -r '.opened_at // 0')
    echo "   熔断状态: $([ "$opened" -gt 0 ] && echo "🔴 已触发（故障 $failures 次）" || echo "🟢 正常（故障计数 $failures）")"

    # 今日统计
    echo ""
    echo "📊 今日统计 ($today):"
    local sf="$STATE_DIR/stats_${today}.json"
    if [[ -f "$sf" ]]; then
        local checks healthy vpn_f cf_f api_f local_f switches cbs
        checks=$(jq -r '.checks // 0' "$sf")
        healthy=$(jq -r '.healthy // 0' "$sf")
        vpn_f=$(jq -r '.faults.vpn // 0' "$sf")
        cf_f=$(jq -r '.faults.cf // 0' "$sf")
        api_f=$(jq -r '.faults.api // 0' "$sf")
        local_f=$(jq -r '.faults.local // 0' "$sf")
        slow_f=$(jq -r '.faults.slow // 0' "$sf")
        switches=$(jq -r '.switches // 0' "$sf")
        cbs=$(jq -r '.circuit_breaks // 0' "$sf")
        local total_faults=$((vpn_f + cf_f + api_f + local_f + slow_f))
        local pct=0
        (( checks > 0 )) && pct=$(( healthy * 100 / checks ))
        echo "   检查总数: $checks    健康: $healthy    故障: $total_faults    可用率: ${pct}%"
        echo "   故障明细: VPN=$vpn_f  CF=$cf_f  API=$api_f  本地=$local_f  慢速=$slow_f"
        echo "   节点切换: $switches    熔断: $cbs"
    else
        echo "   (暂无数据)"
    fi

    # 昨日统计
    echo ""
    echo "📊 昨日统计 ($yesterday):"
    local yf="$STATE_DIR/stats_${yesterday}.json"
    if [[ -f "$yf" ]]; then
        local checks healthy vpn_f cf_f api_f local_f switches
        checks=$(jq -r '.checks // 0' "$yf")
        healthy=$(jq -r '.healthy // 0' "$yf")
        vpn_f=$(jq -r '.faults.vpn // 0' "$yf")
        cf_f=$(jq -r '.faults.cf // 0' "$yf")
        api_f=$(jq -r '.faults.api // 0' "$yf")
        local_f=$(jq -r '.faults.local // 0' "$yf")
        slow_f=$(jq -r '.faults.slow // 0' "$yf")
        switches=$(jq -r '.switches // 0' "$yf")
        local total_faults=$((vpn_f + cf_f + api_f + local_f + slow_f))
        local pct=0
        (( checks > 0 )) && pct=$(( healthy * 100 / checks ))
        echo "   检查总数: $checks    健康: $healthy    故障: $total_faults    可用率: ${pct}%"
        echo "   故障明细: VPN=$vpn_f  CF=$cf_f  API=$api_f  本地=$local_f  慢速=$slow_f"
        echo "   节点切换: $switches"
    else
        echo "   (无数据)"
    fi

    # 日志文件信息
    echo ""
    echo "📁 日志文件:"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size log_lines
        log_size=$(ls -lh "$LOG_FILE" | awk '{print $5}')
        log_lines=$(wc -l < "$LOG_FILE")
        echo "   当前: $LOG_FILE ($log_size, ${log_lines} 行)"
    fi
    local archive_count=0
    if [[ -d "$LOG_ARCHIVE_DIR" ]]; then
        archive_count=$(ls -1 "$LOG_ARCHIVE_DIR"/clash_health_*.log* 2>/dev/null | wc -l | tr -d ' ')
    fi
    [[ "$archive_count" -gt 0 ]] 2>/dev/null && echo "   归档: ${archive_count} 份 (${LOG_ARCHIVE_DIR}/)"

    # 最近 5 条异常
    echo ""
    echo "⚠️ 最近异常 (最多 5 条):"
    if [[ -f "$LOG_FILE" ]]; then
        local errors
        errors=$(grep -E "\[(WARN|ERROR)\]" "$LOG_FILE" | grep -v "跳过\|防抖\|未配置\|改善不足\|驻留未满" | tail -5)
        if [[ -n "$errors" ]]; then
            echo "$errors" | while IFS= read -r line; do
                echo "   $line"
            done
        else
            echo "   (无异常记录 ✅)"
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════"

    # 清理 7 天以上的统计文件
    find "$STATE_DIR" -name "stats_*.json" -mtime +7 -delete 2>/dev/null || true
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
        _bump_daily_stat "circuit_breaks"
        send_alert "熔断告警" "🔴 VPN 熔断触发\n连续 $failures 次全局故障\n冷却 ${CIRCUIT_BREAKER_COOLDOWN}s"
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
    local selector_encoded current
    selector_encoded=$(uri_encode "$SELECTOR")
    current=$(clash_api "GET" "/proxies/$selector_encoded" | jq -r '.now // empty' 2>/dev/null || true)
    current=$(sanitize_node_name "$current" || true)
    if [[ -n "$current" ]]; then
        printf '%s\n' "$current"
        return 0
    fi

    # fallback: 如果手动选择当前指向的是“自动选择”这种 selector，则继续展开一层拿真实出口节点
    local auto_encoded auto_now
    auto_encoded=$(uri_encode "自动选择")
    auto_now=$(clash_api "GET" "/proxies/$auto_encoded" | jq -r '.now // empty' 2>/dev/null || true)
    sanitize_node_name "$auto_now" || true
}

sanitize_node_name() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    [[ "$node" =~ ^(DIRECT|REJECT)$ ]] && return 1
    local metadata_exclude_regex="(^Traffic:|^Expire:|^到期:|^Sync:|剩余流量|流量重置|^自动选择$)"
    if [[ -n "$metadata_exclude_regex" ]] && echo "$node" | grep -qiE "$metadata_exclude_regex"; then
        return 1
    fi
    if [[ -n "$FILTER_INCLUDE_REGEX" ]] && ! echo "$node" | grep -qiE "$FILTER_INCLUDE_REGEX"; then
        return 1
    fi
    printf '%s\n' "$node"
}

is_hk_node() {
    local node="$1"
    [[ -z "$node" ]] && return 1
    echo "$node" | grep -qiE '(hong.*kong|香港)'
}

get_available_nodes() {
    local response selector_encoded raw_nodes nodes raw_count filtered_count attempt max_attempts retry_delay
    selector_encoded=$(uri_encode "$SELECTOR")
    max_attempts=3
    retry_delay=3

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        response=$(clash_api "GET" "/proxies/$selector_encoded" || true)

        if [[ -z "$response" ]]; then
            if (( attempt < max_attempts )); then
                log "WARN" "Clash API 未返回 selector 数据（selector=$SELECTOR，attempt=$attempt/$max_attempts），${retry_delay}s 后重试"
                sleep "$retry_delay"
                continue
            fi
            log "WARN" "Clash API 未返回 selector 数据（selector=$SELECTOR，attempt=$attempt/$max_attempts）"
            return 0
        fi

        raw_nodes=$(echo "$response" | jq -r '.all[]?' 2>/dev/null | grep -vE "^(DIRECT|REJECT)$" || true)
        raw_count=$(echo "$raw_nodes" | sed '/^$/d' | wc -l | tr -d ' ')

        if [[ "$raw_count" == "0" ]]; then
            if (( attempt < max_attempts )); then
                log "WARN" "selector 未返回可用节点（selector=$SELECTOR，attempt=$attempt/$max_attempts），${retry_delay}s 后重试"
                sleep "$retry_delay"
                continue
            fi
            log "WARN" "selector 未返回可用节点（selector=$SELECTOR，attempt=$attempt/$max_attempts）"
            return 0
        fi

        nodes="$raw_nodes"

        if [[ -n "$FILTER_EXCLUDE_REGEX" ]]; then
            nodes=$(echo "$nodes" | grep -viE "$FILTER_EXCLUDE_REGEX" || true)
        fi

        if [[ -n "$FILTER_INCLUDE_REGEX" ]]; then
            nodes=$(echo "$nodes" | grep -iE "$FILTER_INCLUDE_REGEX" || true)
        fi

        filtered_count=$(echo "$nodes" | sed '/^$/d' | wc -l | tr -d ' ')
        if [[ "$filtered_count" == "0" ]]; then
            log "WARN" "节点在过滤后为空（selector=$SELECTOR，raw=$raw_count，exclude=$FILTER_EXCLUDE_REGEX，include=${FILTER_INCLUDE_REGEX:-<empty>}）"
            return 0
        fi

        echo "$nodes"
        return 0
    done
}

is_candidate_allowed() {
    local node="$1"
    sanitize_node_name "$node" >/dev/null || return 1
    if [[ -n "$FILTER_EXCLUDE_REGEX" ]] && echo "$node" | grep -qiE "$FILTER_EXCLUDE_REGEX"; then
        return 1
    fi
    if [[ -n "$FILTER_INCLUDE_REGEX" ]] && ! echo "$node" | grep -qiE "$FILTER_INCLUDE_REGEX"; then
        return 1
    fi
    return 0
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

check_url_via_proxy_timed() {
    local url="$1" timeout="$2"
    local proxy_port="7897"
    local result http_code time_s time_ms
    result=$(curl -x "http://127.0.0.1:${proxy_port}" -s -o /dev/null -w "%{http_code} %{time_total}" --max-time "$timeout" "$url" 2>/dev/null || echo "000 0")
    http_code=$(echo "$result" | awk '{print $1}')
    time_s=$(echo "$result" | awk '{print $2}')
    time_ms=$(echo "$time_s" | awk '{printf "%d", $1 * 1000}')
    echo "$http_code $time_ms"
    if [[ "$http_code" -ge "$HTTP_CODE_MIN" && "$http_code" -le "$HTTP_CODE_MAX" ]]; then
        return 0
    fi
    return 1
}

score_candidate_node() {
    local node="$1"
    local selector_encoded old_node switched=false restored=false
    local telegram_ms openai_ms anthropic_ms
    local code result score=0

    is_candidate_allowed "$node" || return 1

    selector_encoded=$(uri_encode "$SELECTOR")
    old_node=$(get_current_node || true)
    [[ -z "$old_node" ]] && return 1

    restore_original_node() {
        if [[ "$switched" == true && "$restored" == false && -n "$old_node" && "$old_node" != "$node" ]]; then
            clash_api "PUT" "/proxies/$selector_encoded" "{\"name\":\"$old_node\"}" >/dev/null || true
            sleep 1
            restored=true
        fi
    }

    trap restore_original_node RETURN

    if [[ "$old_node" != "$node" ]]; then
        if ! clash_api "PUT" "/proxies/$selector_encoded" "{\"name\":\"$node\"}" >/dev/null; then
            return 1
        fi
        sleep "$SWITCH_WAIT"

        local now_node
        now_node=$(get_current_node || true)
        if [[ "$now_node" != "$node" ]]; then
            log "WARN" "候选评分切换未生效，跳过节点: $node (current=${now_node:-unknown})"
            return 1
        fi
        switched=true
    fi

    result=$(check_url_via_proxy_timed "$CANARY_TELEGRAM" "$TIMEOUT_API" || true)
    code=$(echo "$result" | awk '{print $1}'); telegram_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] || telegram_ms=99999

    result=$(check_url_via_proxy_timed "https://api.openai.com/v1/models" "$TIMEOUT_API" || true)
    code=$(echo "$result" | awk '{print $1}'); openai_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] || openai_ms=99999

    result=$(check_url_via_proxy_timed "https://api.anthropic.com" "$TIMEOUT_API" || true)
    code=$(echo "$result" | awk '{print $1}'); anthropic_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] || anthropic_ms=99999

    score=$((telegram_ms + openai_ms + anthropic_ms))
    echo -e "${node}\t${telegram_ms}\t${openai_ms}\t${anthropic_ms}\t${score}"
}

# ==================== 故障分类 ====================

# check_url_timed: 检测 URL 可达性 + 响应时间
# 用法: check_url_timed <url> <timeout>
# 输出: "<http_code> <time_ms>" 到 stdout
# 返回: 0=可达, 1=不可达
check_url_timed() {
    local url="$1" timeout="$2"
    local result
    result=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time "$timeout" "$url" 2>/dev/null || echo "000 0")
    local http_code time_s
    http_code=$(echo "$result" | awk '{print $1}')
    time_s=$(echo "$result" | awk '{print $2}')

    # 转换为毫秒（兼容无小数的情况）
    local time_ms
    time_ms=$(echo "$time_s" | awk '{printf "%d", $1 * 1000}')

    echo "$http_code $time_ms"

    if [[ "$http_code" -ge "$HTTP_CODE_MIN" && "$http_code" -le "$HTTP_CODE_MAX" ]]; then
        return 0
    fi
    return 1
}

# 兼容旧接口
check_url() {
    local url="$1" timeout="$2"
    local result
    result=$(check_url_timed "$url" "$timeout")
    local http_code
    http_code=$(echo "$result" | awk '{print $1}')
    if [[ "$http_code" -ge "$HTTP_CODE_MIN" && "$http_code" -le "$HTTP_CODE_MAX" ]]; then
        return 0
    fi
    return 1
}

# 慢速计数器（状态文件）
_slow_count_file() { echo "$STATE_DIR/slow_count"; }

_get_slow_count() {
    cat "$(_slow_count_file)" 2>/dev/null || echo 0
}

_set_slow_count() {
    echo "$1" > "$(_slow_count_file)"
}

# 0 正常（模型可达且延迟可接受）
# 1 模型不可达/超时（立即切换）
# 5 模型慢速降级（可切换）
# 2/3/4 旧分类保留注释位，当前模型优先策略下不再返回
classify_fault() {
    local basic_ok=false cloudflare_ok=false google_ok=false telegram_ok=false openai_ok=false anthropic_ok=false
    local basic_ms=0 cloudflare_ms=0 google_ms=0 telegram_ms=0 openai_ms=0 anthropic_ms=0
    local result code ms

    result=$(check_url_timed "$CANARY_BASIC" "$TIMEOUT_BASIC") && basic_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); basic_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && basic_ok=true

    result=$(check_url_timed "$CANARY_CLOUDFLARE" "$TIMEOUT_BASIC") && cloudflare_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); cloudflare_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && cloudflare_ok=true

    result=$(check_url_timed "$CANARY_GOOGLE" "$TIMEOUT_BASIC") && google_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); google_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && google_ok=true

    result=$(check_url_timed "$CANARY_TELEGRAM" "$TIMEOUT_API") && telegram_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); telegram_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && telegram_ok=true

    result=$(check_url_timed "https://api.openai.com/v1/models" "$TIMEOUT_API") && openai_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); openai_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && openai_ok=true

    result=$(check_url_timed "https://api.anthropic.com" "$TIMEOUT_API") && anthropic_ok=true || true
    code=$(echo "$result" | awk '{print $1}'); anthropic_ms=$(echo "$result" | awk '{print $2}')
    [[ "$code" -ge "$HTTP_CODE_MIN" && "$code" -le "$HTTP_CODE_MAX" ]] && anthropic_ok=true

    # 日志输出（带响应时间）
    [[ "$basic_ok" == true ]] && log "DEBUG" "✅ 基础网络正常 (${basic_ms}ms)" || log "DEBUG" "❌ 基础网络异常"
    [[ "$cloudflare_ok" == true ]] && log "DEBUG" "✅ Cloudflare 正常 (${cloudflare_ms}ms)" || log "DEBUG" "❌ Cloudflare 异常"
    [[ "$google_ok" == true ]] && log "DEBUG" "✅ Google 正常 (${google_ms}ms)" || log "DEBUG" "❌ Google 异常"
    [[ "$telegram_ok" == true ]] && log "DEBUG" "✅ Telegram 正常 (${telegram_ms}ms)" || log "DEBUG" "❌ Telegram 异常"
    [[ "$openai_ok" == true ]] && log "DEBUG" "✅ OpenAI 正常 (${openai_ms}ms)" || log "DEBUG" "❌ OpenAI 异常"
    [[ "$anthropic_ok" == true ]] && log "DEBUG" "✅ Anthropic 正常 (${anthropic_ms}ms)" || log "DEBUG" "❌ Anthropic 异常"

    # 以关键上游可用性为核心健康标准：
    # - OpenAI / Anthropic / Telegram 任一不可达或超时：立即切换（节点级故障）
    # - OpenAI / Anthropic 都可达但延迟持续偏高：按慢速降级策略切换
    # - 基础网络探针仅作诊断日志，不主导切换决策

    if [[ "$openai_ok" == false || "$anthropic_ok" == false || "$telegram_ok" == false ]]; then
        local unavailable_targets=""
        [[ "$openai_ok" == false ]] && unavailable_targets+="OpenAI "
        [[ "$anthropic_ok" == false ]] && unavailable_targets+="Anthropic "
        [[ "$telegram_ok" == false ]] && unavailable_targets+="Telegram "
        log "WARN" "🤖 关键上游不可达或超时：${unavailable_targets}，立即触发切换"
        _set_slow_count 0
        return 1
    fi

    # 模型均可达，再判断模型延迟是否慢速
    local is_slow=false
    local slow_targets=""

    if (( openai_ms > SLOW_THRESHOLD_API_MS )); then
        is_slow=true; slow_targets+="OpenAI(${openai_ms}ms) "
    fi
    if (( anthropic_ms > SLOW_THRESHOLD_API_MS )); then
        is_slow=true; slow_targets+="Anthropic(${anthropic_ms}ms) "
    fi

    if [[ "$is_slow" == true ]]; then
        local count
        count=$(_get_slow_count)
        count=$((count + 1))
        _set_slow_count "$count"
        log "WARN" "🐌 模型慢速检测: ${slow_targets}(连续 ${count}/${SLOW_CONSECUTIVE_LIMIT})"

        if (( count >= SLOW_CONSECUTIVE_LIMIT )); then
            log "WARN" "🐌 连续 ${count} 次模型慢速，触发降级切换"
            _set_slow_count 0
            return 5
        fi
    else
        _set_slow_count 0
    fi

    return 0
}

# ==================== 候选选择 ====================
choose_next_candidate() {
    local current_node="$1"
    local node count=0

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        [[ "$node" == "$current_node" ]] && continue
        is_node_quarantined "$node" && continue
        is_candidate_allowed "$node" || continue
        printf '%s\n' "$node"
        count=$((count + 1))
        if (( count >= MAX_SWITCH_ATTEMPTS )); then
            break
        fi
    done < <(get_available_nodes || true)
}

# 正常态重平衡（防抖）：
# 只做记录，不在健康状态下主动来回切候选
maybe_rebalance_when_healthy() {
    local current_node="$1"
    local ok_count last_switch_at now dwell candidate

    ok_count=$(get_state_value "health_ok_count")
    [[ -z "$ok_count" || "$ok_count" == "null" ]] && ok_count=0

    if (( ok_count % REBALANCE_CHECK_INTERVAL != 0 )); then
        log "DEBUG" "跳过重平衡检查（health_ok_count=$ok_count）"
        return 0
    fi

    last_switch_at=$(get_state_value "last_switch_at")
    [[ -z "$last_switch_at" || "$last_switch_at" == "null" ]] && last_switch_at=0
    now=$(date +%s)
    dwell=$((now - last_switch_at))

    if (( dwell < MIN_NODE_DWELL_SECONDS )); then
        log "INFO" "防抖: 驻留未满 ${MIN_NODE_DWELL_SECONDS}s，不切换"
        return 0
    fi

    candidate=$(choose_next_candidate "$current_node" | head -1 || true)
    if [[ -z "$candidate" ]]; then
        log "DEBUG" "无可用候选节点，跳过重平衡"
        return 0
    fi

    log "INFO" "重平衡候选观察: current=${current_node}, candidate=${candidate}, dwell=${dwell}s（保守模式，不在健康态主动切换）"
}

# ==================== 故障切换（保守模式：一轮最多切一次） ====================
smart_switch() {
    local current_node="$1"
    local best_node attempt=0

    log "WARN" "⚠️ 当前节点 [$current_node] 故障，开始保守切换..."
    send_alert "节点故障" "⚠️ VPN 节点故障\n当前: $current_node\n开始保守切换（本轮最多切一次）"

    cleanup_quarantine
    quarantine_node "$current_node"

    while IFS= read -r best_node; do
        [[ -z "$best_node" ]] && continue
        attempt=$((attempt + 1))
        if (( attempt > MAX_SWITCH_ATTEMPTS )); then
            break
        fi

        log "INFO" "🔍 选择候选节点 [$best_node] (${attempt}/${MAX_SWITCH_ATTEMPTS})"

        if ! switch_node "$best_node"; then
            quarantine_node "$best_node"
            continue
        fi

        log "INFO" "✅ 已切换到候选节点: $best_node（保守模式，本轮不继续测速，等待下次运行验证）"
        reset_failure_count
        send_alert "节点已切换" "✅ 已切换节点\n$current_node → $best_node\n本轮停止继续测试，等待下一次健康检查验证"
        return 0
    done < <(choose_next_candidate "$current_node")

    log "ERROR" "❌ 未找到可用节点（已尝试 $attempt 个）"
    record_global_failure
    send_alert "切换失败" "🚨 节点切换失败\n尝试 $attempt 个候选仍不可用"
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

    # 先做进程级去重，再拿 lock
    if has_duplicate_process; then
        _rotate_log
        log "WARN" "检测到重复的 health_check.sh 进程，跳过本次运行"
        exit 0
    fi

    acquire_lock

    # 每次运行前检查日志轮转
    _rotate_log

    log "INFO" "========== 开始健康检查 v2.1 =========="
    [[ "$DRY_RUN" == true ]] && log "INFO" "⚠️ DRY-RUN 模式"

    # 初始化每日统计
    _init_daily_stats
    _bump_daily_stat "checks"

    if ! check_circuit_breaker; then
        log "INFO" "========== 完成：熔断冷却中 =========="
        exit 0
    fi

    # 清理过期隔离节点（每次运行都清理，不仅限故障路径）
    cleanup_quarantine

    local current_node
    current_node=$(get_current_node) || {
        log "ERROR" "无法获取当前节点"
        exit 1
    }
    log "INFO" "当前节点: $current_node"

    if is_hk_node "$current_node"; then
        log "WARN" "⚠️ 当前节点命中香港，按策略立即切换"
        _bump_daily_fault "vpn"
        if smart_switch "$current_node"; then
            _bump_daily_stat "switches"
            log "INFO" "========== 完成：香港节点已切换 =========="
            exit 0
        else
            log "ERROR" "========== 完成：香港节点切换失败 =========="
            exit 1
        fi
    fi

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
            _bump_daily_stat "healthy"
            maybe_rebalance_when_healthy "$current_node"
            log "INFO" "========== 完成：正常 =========="
            ;;
        1)
            log "WARN" "⚠️ 节点级故障，开始故障切换"
            _bump_daily_fault "vpn"
            if smart_switch "$current_node"; then
                _bump_daily_stat "switches"
                log "INFO" "========== 完成：已切换 =========="
                exit 0
            else
                log "ERROR" "========== 完成：切换失败 =========="
                exit 1
            fi
            ;;
        2)
            log "WARN" "⚠️ Cloudflare 全局故障（不切节点）"
            _bump_daily_fault "cf"
            record_global_failure
            send_alert "Cloudflare 异常" "⚠️ 疑似 Cloudflare 故障\n当前节点: $current_node\n已暂停切换，等待恢复"
            ;;
        3)
            log "WARN" "⚠️ 上游 API 故障（不切节点）"
            _bump_daily_fault "api"
            record_global_failure
            send_alert "上游API异常" "⚠️ 疑似上游 API 故障\nOpenAI/Anthropic 同时异常\n已暂停切换"
            ;;
        4)
            log "WARN" "⚠️ 本地网络故障（不切节点）"
            _bump_daily_fault "local"
            record_global_failure
            send_alert "本地网络异常" "⚠️ 本地网络异常\n请检查本机网络/路由"
            ;;
        5)
            log "WARN" "🐌 慢速降级，尝试切换更快节点"
            _bump_daily_fault "slow"
            if smart_switch "$current_node"; then
                _bump_daily_stat "switches"
                log "INFO" "========== 完成：慢速切换成功 =========="
                exit 0
            else
                log "WARN" "========== 完成：慢速切换失败（保持当前节点） =========="
            fi
            ;;
    esac
}

main "$@"
