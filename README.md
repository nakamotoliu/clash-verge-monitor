# Clash Verge 自动监控与切换

## 项目简介
自动检测 AI 大模型（OpenAI/Claude/Google）可访问性，VPN 节点故障时自动切换到可用节点。

---

## 🚀 v2 版本（推荐使用）

### v2 新增特性
| 特性 | 说明 |
|------|------|
| **故障分类** | 区分本地网络/VPN节点/Cloudflare/上游API故障 |
| **熔断机制** | 连续3次全局故障后进入30分钟冷却，避免无效切换 |
| **尝试预算** | 单次最多切换5个节点，防止轮询所有节点 |
| **节点隔离** | 失败节点30分钟内不再尝试 |
| **节点名修复** | 正确处理带空格/emoji的节点名 |
| **延迟评分** | 候选节点先测延迟，再按综合分排序 |
| **防抖切换** | 最小驻留时间+改善阈值，避免“追最低延迟”导致频繁切换 |

### v2.2（进行中）新增：UI 配置化双引擎
- 双引擎并行：故障切换 + 定时重平衡
- 参数由 `config/ui_config.json` 读取（后续可由 UI 面板写入）
- 节点过滤支持 `excludeRegex/includeRegex`
- 默认过滤订阅信息行：`Expire/到期/剩余流量/流量重置`

### v2.1 快速开始
```bash
# 1. 测试运行（不切换节点）
./scripts/health_check.sh --dry-run

# 2. 实际运行
./scripts/health_check.sh

# 3. 重置熔断状态
./scripts/health_check.sh --reset

# 4. 查看状态文件
cat <project-root>/data/state/circuit_breaker.json  # 熔断状态
cat <project-root>/data/state/quarantine.json       # 隔离节点
```

### v2 故障分类逻辑
```
基础网络(baidu) ──┬── ❌ ──> 本地网络故障（不切换）
                  │
                  └── ✅ ──> Google ──┬── ❌ ──> VPN/节点故障（切换）
                                      │
                                      └── ✅ ──> Cloudflare ──┬── ❌ + API❌ ──> CF全局故障（不切换，熔断）
                                                              │
                                                              └── ✅ ──> API ──┬── ❌ ──> 上游故障（不切换，熔断）
                                                                               │
                                                                               └── ✅ ──> 正常
```

---

## ⚡ 快速开始（兼容命令）

```bash
# 1. 测试运行（不切换节点）
cd <project-root>
./scripts/health_check.sh --dry-run

# 2. 实际运行（会切换节点）
./scripts/health_check.sh

# 3. 设置定时任务（每 5 分钟）
openclaw cron add \
  --name "Clash 健康检查" \
  --schedule '*/5 * * * *' \
  --isolated \
  --command "bash <project-root>/scripts/health_check.sh"

# 4. 验证定时任务
openclaw cron list | grep "Clash"

# 5. 查看日志
tail -f <project-root>/logs/clash_health.log
```

---

## 核心特性
- ✅ 实时健康检查（Google/OpenAI/Anthropic）
- ✅ 自动切换节点（排除 Hong Kong 节点）
- ✅ 并发保护（避免重复执行）
- ✅ Telegram 通知
- ✅ 完整日志记录
- ✅ Dry-run 测试模式

## 技术栈
- **Clash Verge** - macOS VPN 客户端
- **Unix Socket API** - 控制 Clash 节点
- **Bash 脚本** - 健康检查与切换逻辑

## 文件结构
```
clash-verge-monitor/
├── README.md
├── scripts/
│   └── health_check.sh        # 主脚本
├── logs/
│   └── clash_health.log       # 运行日志
└── config/
    └── (预留配置文件)
```

## 使用方法

### 🧪 测试步骤（首次使用必做）

#### 1. Dry-run 测试（不切换节点）
```bash
cd <project-root>
./scripts/health_check.sh --dry-run
```

**预期输出：**
```
[2026-03-02 10:09:05] [INFO] ========== 开始健康检查 ==========
[2026-03-02 10:09:05] [INFO] ⚠️ DRY-RUN 模式
[2026-03-02 10:09:05] [INFO] 当前节点: 🇺🇸 美国 01
[2026-03-02 10:09:06] [DEBUG] ✅ Google 可达 (HTTP 200)
[2026-03-02 10:09:07] [DEBUG] ✅ OpenAI API 可达 (HTTP 401)
[2026-03-02 10:09:08] [DEBUG] ✅ Anthropic API 可达 (HTTP 404)
[2026-03-02 10:09:08] [INFO] ✅ 所有 AI 服务可访问
[2026-03-02 10:09:08] [INFO] ========== 检查完成：正常 ==========
```

#### 2. 实际运行测试（会切换节点）
```bash
cd <project-root>
./scripts/health_check.sh
```

**检查结果：**
```bash
# 查看日志
tail -20 <project-root>/logs/clash_health.log

# 查看当前节点
curl --unix-socket /tmp/verge/verge-mihomo.sock \
  http://localhost/proxies/手动选择 -s | jq '.now'
```

#### 3. 模拟故障测试
```bash
# 临时关闭 VPN，测试自动切换
# 然后运行脚本，应该会自动切换节点

./scripts/health_check.sh

# 检查是否收到 Telegram 通知
# 检查日志是否有切换记录
tail -50 <project-root>/logs/clash_health.log | grep "切换"
```

---

### 🚀 部署定时任务

#### 方式 1：OpenClaw Cron（推荐）

**添加定时任务（每 5 分钟）：**
```bash
openclaw cron add \
  --name "Clash 健康检查" \
  --schedule '*/5 * * * *' \
  --isolated \
  --command "bash <project-root>/scripts/health_check.sh"
```

**验证任务已添加：**
```bash
openclaw cron list | grep "Clash"
```

**手动触发测试：**
```bash
# 获取 job ID
JOB_ID=$(openclaw cron list | grep "Clash 健康检查" | jq -r '.id')

# 手动运行
openclaw cron run $JOB_ID --force
```

**查看运行历史：**
```bash
openclaw cron runs $JOB_ID
```

**停用/启用任务：**
```bash
# 停用
openclaw cron disable $JOB_ID

# 启用
openclaw cron enable $JOB_ID
```

**删除任务：**
```bash
openclaw cron remove $JOB_ID
```

---

#### 方式 2：macOS LaunchAgent（备选）

**创建 plist 文件：**
```bash
cat > ~/Library/LaunchAgents/com.clash.healthcheck.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clash.healthcheck</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string><project-root>/scripts/health_check.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string><project-root>/logs/clash_health.log</string>
    <key>StandardErrorPath</key>
    <string><project-root>/logs/clash_health.err</string>
</dict>
</plist>
EOF
```

**加载任务：**
```bash
launchctl load ~/Library/LaunchAgents/com.clash.healthcheck.plist
```

**查看状态：**
```bash
launchctl list | grep clash
```

**卸载任务：**
```bash
launchctl unload ~/Library/LaunchAgents/com.clash.healthcheck.plist
```

---

### 📊 监控与调试

#### 实时日志
```bash
# 实时查看日志
tail -f <project-root>/logs/clash_health.log
```

#### 查看最近运行
```bash
# 最近 20 条
tail -20 <project-root>/logs/clash_health.log

# 只看错误
grep ERROR <project-root>/logs/clash_health.log | tail -10

# 只看切换记录
grep "切换" <project-root>/logs/clash_health.log | tail -10
```

#### 测试 Telegram 通知
```bash
openclaw message send \
  --channel telegram \
  --account <your-account> \
  --target <your-telegram-chat-id> \
  --message "Clash 监控测试通知"
```

### 查看日志
```bash
# 实时日志
tail -f <project-root>/logs/clash_health.log

# 查看最近10条
tail -n 10 <project-root>/logs/clash_health.log
```

## 配置说明

### 修改配置（在脚本顶部）
```bash
# Clash socket 路径
readonly SOCKET="/tmp/verge/verge-mihomo.sock"

# 选择器名称
readonly SELECTOR="手动选择"

# 超时设置
readonly TIMEOUT_BASIC=5      # Google 测试超时
readonly TIMEOUT_API=10       # API 测试超时
readonly SWITCH_WAIT=3        # 切换等待时间
readonly STABILIZE_WAIT=5     # 稳定等待时间

# Telegram 通知
readonly TELEGRAM_ACCOUNT="alerts"
readonly TELEGRAM_TARGET="1625845749"
```

## 工作原理

### 健康检查流程
```
1. 检测 Google 基础连通性
   ↓
2. 检测 OpenAI API 可达性
   ↓
3. 检测 Anthropic API 可达性
   ↓
4. 如果全部通过 → 正常
   如果任一失败 → 触发切换
```

### 节点切换逻辑
```
1. 获取所有可用节点
   ↓
2. 过滤掉 Hong Kong / 香港 节点
   ↓
3. 遍历节点列表
   ↓
4. 切换 → 等待稳定 → 健康检查
   ↓
5. 成功 → 发通知，结束
   失败 → 尝试下一个节点
   ↓
6. 所有节点都失败 → 发警告通知
```

### HTTP 状态码判断
- **200-499** - 认为网络可达（包括 401/404，说明能到服务器）
- **000, 500+** - 认为网络不可达

## 依赖检查
脚本会自动检查以下依赖：
- `curl` - HTTP 请求
- `jq` - JSON 解析
- `openclaw` - Telegram 通知

## 并发保护
- 使用 lockfile (`/tmp/clash_health_check.lock`)
- 自动清理过期锁（>5分钟）
- 避免多个实例同时切换节点

## 🔧 故障排查

### 问题 1: 脚本无法运行

**症状：** 运行脚本时报错或无响应

**排查步骤：**
```bash
# 1. 检查依赖
command -v curl jq openclaw

# 如果缺少，安装：
brew install curl jq

# 2. 检查 Clash socket
ls -la /tmp/verge/verge-mihomo.sock

# 3. 检查 Clash 进程
ps aux | grep -i clash | grep -v grep

# 4. 检查脚本权限
ls -l <project-root>/scripts/health_check.sh

# 如果没有执行权限：
chmod +x <project-root>/scripts/health_check.sh
```

**常见原因：**
- Clash Verge 未启动
- Socket 路径不对（检查脚本中 `SOCKET` 变量）
- 缺少依赖工具

---

### 问题 2: 节点切换失败

**症状：** 日志显示 "切换节点失败"

**排查步骤：**
```bash
# 1. 手动测试 Clash API
curl --unix-socket /tmp/verge/verge-mihomo.sock \
  http://localhost/proxies/手动选择 -s | jq .

# 2. 检查选择器名称
curl --unix-socket /tmp/verge/verge-mihomo.sock \
  http://localhost/proxies -s | jq 'keys'

# 3. 查看错误日志
tail -50 <project-root>/logs/clash_health.log | grep ERROR
```

**常见原因：**
- 选择器名称错误（脚本中 `SELECTOR` 变量）
- Clash API 未启用
- 所有节点都被过滤掉了（检查 Hong Kong 过滤逻辑）

---

### 问题 3: Telegram 通知不发送

**症状：** 切换成功但未收到通知

**排查步骤：**
```bash
# 1. 测试 OpenClaw 通知
openclaw message send \
  --channel telegram \
  --account <your-account> \
  --target <your-telegram-chat-id> \
  --message "测试通知"

# 2. 检查 OpenClaw 配置
openclaw config get channels.telegram

# 3. 查看日志中的通知错误
grep "Telegram" <project-root>/logs/clash_health.log
```

**常见原因：**
- OpenClaw Telegram 未配置
- Account 或 Target 错误
- 网络问题（Telegram 被墙）

---

### 问题 4: 健康检查误报

**症状：** VPN 正常但脚本认为失败

**排查步骤：**
```bash
# 1. 手动测试各个 URL
curl -s -o /dev/null -w "%{http_code}\n" https://www.google.com
curl -s -o /dev/null -w "%{http_code}\n" https://api.openai.com/v1/models
curl -s -o /dev/null -w "%{http_code}\n" https://api.anthropic.com

# 2. 检查超时设置（脚本中 TIMEOUT_* 变量）
grep "TIMEOUT" <project-root>/scripts/health_check.sh

# 3. 调整超时时间（如果网络慢）
# 编辑脚本，增加 TIMEOUT_API 值
```

**常见原因：**
- 网络慢，超时设置太短
- DNS 解析失败
- 节点被限流

---

### 问题 5: 定时任务不执行

**症状：** 添加了 cron 但从不运行

**排查步骤：**
```bash
# 1. 检查任务状态
openclaw cron list

# 2. 查看任务详情
JOB_ID=$(openclaw cron list | grep "Clash" | jq -r '.id')
openclaw cron runs $JOB_ID

# 3. 手动触发测试
openclaw cron run $JOB_ID --force

# 4. 检查 OpenClaw Gateway 状态
openclaw gateway status
```

**常见原因：**
- 任务被禁用（`enabled: false`）
- OpenClaw Gateway 未运行
- cron 表达式错误

---

### 问题 6: 并发锁死

**症状：** 脚本提示 "检测到其他实例正在运行"

**排查步骤：**
```bash
# 1. 检查锁文件
ls -l /tmp/clash_health_check.lock

# 2. 查看锁文件年龄
stat -f %m /tmp/clash_health_check.lock
date +%s

# 3. 如果确认无其他实例，手动删除
rm -f /tmp/clash_health_check.lock

# 4. 检查是否有僵尸进程
ps aux | grep health_check.sh | grep -v grep
```

**常见原因：**
- 上次运行异常退出
- 脚本超时未结束
- 多个定时任务重复添加

---

### 🆘 仍然无法解决？

**收集以下信息反馈：**
```bash
# 1. 系统信息
uname -a
sw_vers

# 2. Clash 状态
ps aux | grep clash

# 3. 最近日志
tail -50 <project-root>/logs/clash_health.log

# 4. 依赖版本
curl --version
jq --version
openclaw --version

# 5. Clash API 测试
curl --unix-socket /tmp/verge/verge-mihomo.sock \
  http://localhost/proxies -s | jq 'keys | length'
```

## 未来改进
- [ ] 支持自定义健康检查 URL
- [ ] 节点延迟测试
- [ ] 历史数据分析（最优节点）
- [ ] Web 界面（可视化）
- [ ] 支持 mihomo 和 Clash Verge 双版本

## 相关项目
- `ai-auto-clash` - mihomo (Clash.Meta) 版本
- `email-agent` - 邮件通知
- `devtools` - 通用工具脚本

---
*Created: 2026-03-02*  
*Author: Nakamoto AI*  
*Status: ✅ 生产运行*
