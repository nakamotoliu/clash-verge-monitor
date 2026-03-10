# Clash Verge Monitor

Clash Verge / verge-mihomo 节点健康检查与自动切换脚本，面向 **macOS + Clash Unix socket + AI 工作流**。

它不是通用 VPN 教程，而是一个偏实战的故障切换项目：
- 检查基础网络、Google、Telegram、OpenAI、Anthropic 可达性
- 检查响应时间，识别“慢但没死”的降级情况
- 读取 **OpenClaw `gateway.err.log`**，识别真实的 **LLM timeout**
- 在满足条件时自动切换到更优节点
- 带隔离、冷却、熔断、防抖、日志和日报统计

---

## 这项目现在解决什么问题

过去只靠轻量连通性探测时，会出现一种很烦的错位：

- `api.openai.com` 看起来能通
- `api.anthropic.com` 看起来也能通
- 但 OpenClaw 在真实模型请求里持续报：
  - `LLM request timed out.`
  - `FailoverError: LLM request timed out.`
  - `All models failed ... timeout`

结果就是：**监控说健康，agent 实际已经半死不活。**

现在这项目会同时看：
1. 基础探测结果
2. OpenClaw 真实错误日志

也就是不只看“路通不通”，还看“车是不是已经在路上熄火了”。

---

## 当前核心能力

### 1. 故障分类
脚本会区分：
- 本地网络故障
- 节点 / VPN 故障
- Cloudflare 类全局故障
- 上游 API 故障
- 慢速降级
- OpenClaw LLM timeout 驱动的故障

### 2. 智能切换
不是盲切，会综合：
- 候选节点延迟
- 当前节点延迟
- 最小改善阈值
- 节点隔离状态
- 最大尝试次数

### 3. 防抖 / 保护
- 熔断：连续全局故障后进入冷却
- 隔离：失败节点暂时不再尝试
- 驻留时间：避免频繁来回切
- LLM timeout 冷却：避免同一波日志反复触发切换
- 并发锁：避免重入执行

### 4. LLM timeout 感知
会读取：
- `~/.openclaw/logs/gateway.err.log`

识别这些模式：
- `LLM request timed out.`
- `FailoverError: LLM request timed out.`
- `All models failed .* timeout`

默认策略：
- 最近 `600` 秒窗口
- `>= 4` 次 timeout
- 冷却 `1800` 秒
- 扫描日志尾部 `5000` 行

并且现在会：
- 记录最近事件 key 做去重
- 将 `llm_timeout` 单独计入统计
- 在 `llm_timeout_trigger` 切换后做一次 **复验**，避免“切了但模型照样超时”还误判成功

---

## 项目结构

```text
clash-verge-monitor/
├── README.md
├── CHANGELOG.md
├── config/
│   └── ui_config.json
├── logs/
│   └── clash_health.log
└── scripts/
    ├── health_check.sh
    ├── weekly_report.sh
    └── send_email_126.py
```

运行期状态文件在：

```text
data/state/
├── circuit_breaker.json
├── quarantine.json
├── node_state.json
├── llm_timeout_state.json
└── stats_YYYY-MM-DD.json
```

---

## 运行前提

- macOS
- Clash Verge / verge-mihomo 已运行
- Clash Unix socket 存在：`/tmp/verge/verge-mihomo.sock`
- `bash`、`curl`、`jq` 可用
- 如果要发 Telegram 通知：本机 `openclaw` CLI 可用
- 如果要依赖 LLM timeout 联动：本机存在 OpenClaw 错误日志
  - 默认：`~/.openclaw/logs/gateway.err.log`

---

## 快速开始

### 1. Dry-run
只跑检查，不实际切换：

```bash
cd /path/to/clash-verge-monitor
bash scripts/health_check.sh --dry-run
```

### 2. 实际运行

```bash
bash scripts/health_check.sh
```

### 3. 查看统计

```bash
bash scripts/health_check.sh --stats
```

### 4. 重置状态

```bash
bash scripts/health_check.sh --reset
```

### 5. 看日志

```bash
tail -f logs/clash_health.log
```

---

## 配置文件

配置文件：
- `config/ui_config.json`

当前支持的关键项：

```json
{
  "selector": "手动选择",
  "intervals": {
    "rebalanceCheckInterval": 6,
    "minNodeDwellSeconds": 1800
  },
  "thresholds": {
    "failoverImprovementMs": 50,
    "rebalanceImprovementMs": 120,
    "slowBasicMs": 1000,
    "slowApiMs": 2000,
    "slowConsecutiveLimit": 3
  },
  "timers": {
    "timeoutBasicSeconds": 5,
    "timeoutApiSeconds": 10
  },
  "llmTimeout": {
    "windowSeconds": 600,
    "threshold": 4,
    "switchCooldownSeconds": 1800,
    "tailLines": 5000
  },
  "filters": {
    "excludeRegex": "(hong.*kong|香港|^Expire:|^到期:|剩余流量|流量重置)",
    "includeRegex": ""
  }
}
```

---

## 关键状态文件说明

### `node_state.json`
记录：
- 最近切换时间
- 最近切换到的节点
- 累计切换次数
- 健康检查累计次数

### `quarantine.json`
记录暂时隔离的失败节点。

### `circuit_breaker.json`
记录全局故障计数和熔断打开时间。

### `llm_timeout_state.json`
记录 LLM timeout 联动切换状态：
- 上次 timeout 触发切换时间
- 最近已处理事件 key
- 最近看到的事件 key
- 最近窗口内 timeout 数量

这个文件是避免重复消费同一波日志的关键。

---

## LLM timeout 检测逻辑

脚本不会真的去发一轮大模型 prompt 做探测。
它用的是 **OpenClaw 已经产生的真实错误日志** 作为信号源。

流程大致是：
1. 扫描 `gateway.err.log` 尾部最近 N 行
2. 提取最近窗口内的 timeout 事件
3. 统计数量
4. 通过事件 key 去重
5. 达到阈值则触发 `llm_timeout_trigger`
6. 切换后再次复验 timeout 是否仍在持续

这个设计的重点是：
**用真实业务失败信号驱动切换，而不是只看轻量接口能不能通。**

---

## 日志里你应该看到什么

### 正常健康
```text
[INFO] 当前节点: 🇸🇬 新加坡 09
[INFO] LLM timeout 观察: recent_count=0, window=600s, threshold=4, latest_event_at=0
[INFO] ✅ 服务健康
```

### LLM timeout 触发切换
```text
[INFO] LLM timeout 观察: recent_count=6, window=600s, threshold=4, latest_event_at=...
[WARN] 检测到 OpenClaw LLM timeout 达阈值，触发节点切换
[WARN] ⚠️ 基于 OpenClaw LLM timeout 触发节点切换
```

### 切换后复验失败
```text
[WARN] LLM timeout 复验未通过：recent_count=5, threshold=4
[WARN] 切换后基础探测正常，但 LLM timeout 仍在持续，继续尝试下一个候选节点
```

---

## 给 agent 用时应该知道什么

如果你是让另一个 agent 接手这个项目，最重要的是这几条：

1. **不要只盯着 README 的老描述，要以 `scripts/health_check.sh` 当前逻辑为准**
2. 这个项目现在不是“普通的网络存活检测”，而是：
   - 网络探测
   - 慢速降级判断
   - OpenClaw LLM timeout 联动
   三套逻辑并行
3. 真正的关键配置在：
   - `config/ui_config.json`
4. 真正的运行状态在：
   - `data/state/*.json`
5. 如果线上表现与 GitHub 不一致，先检查是不是**线上机器没 pull 最新代码**，不要先怀疑脚本闹鬼
6. 修改这项目时，优先做 **增量修改**，不要没事重写整份脚本

---

## 推荐的 agent 交接提示词

可以直接把下面这段给 agent：

```text
请在当前仓库中工作，不要脱离现有脚本另写一套系统。

项目是一个 macOS 上的 Clash Verge / verge-mihomo 自动健康检查与节点切换脚本，核心文件是 scripts/health_check.sh。

当前脚本不仅做基础网络探测，还会：
1. 检测 Google / Telegram / OpenAI / Anthropic 可达性
2. 检测慢速降级
3. 读取 OpenClaw ~/.openclaw/logs/gateway.err.log，识别真实 LLM timeout
4. 在达到阈值时触发 llm_timeout_trigger 自动切换
5. 使用 llm_timeout_state.json 做事件去重与冷却
6. 在 llm_timeout_trigger 后做复验，避免切换后仍然超时却误判成功

工作原则：
- 优先增量修改，不要重构整份脚本
- 修改后必须通过 bash -n
- 如果调整配置项，同时更新 config/ui_config.json
- 如果修改统计口径，同时检查 --stats 输出是否仍然一致
```

---

## 验证建议

### 本地静态验证
```bash
bash -n scripts/health_check.sh
jq . config/ui_config.json >/dev/null
```

### 运行验证
```bash
bash scripts/health_check.sh --dry-run
bash scripts/health_check.sh --stats
```

### 线上同步验证
如果某台机器线上脚本表现和 GitHub 不一致，先检查：

```bash
git status
git pull origin main
grep -nE 'llm_timeout_still_firing|last_handled_event_key|latest_event_key|_bump_daily_fault "llm_timeout"' scripts/health_check.sh
```

---

## 注意事项

- 这是 **本地脚本项目**，不是 SaaS 服务
- 正式修改应先在本地仓库完成，再 commit / push / 部署
- 不要直接在线上机器手改后假装世界还是一致的；那会制造平行宇宙
- 如果你真的在线上紧急止血了，记得立刻把改动回收到本地仓库

---

## License / Internal Use

当前仓库按内部运维工具使用。若要对外公开给更多人用，建议再补：
- 明确安装前提
- 示例日志
- 部署方式
- 故障场景说明
- License
