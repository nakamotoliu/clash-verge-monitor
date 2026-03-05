# Changelog

## [1.0.0] - 2026-03-02

### 🎉 初始版本

**Created by:** Nakamoto AI  
**Status:** ✅ 生产就绪

### ✨ Features
- 自动健康检查（Google/OpenAI/Anthropic）
- 智能节点切换（排除 Hong Kong）
- 并发保护（lockfile）
- Telegram 通知
- 完整日志记录
- Dry-run 测试模式
- HTTP 状态码智能判断（200-499 认为可达）

### 📁 项目结构
```
clash-verge-monitor/
├── README.md           # 完整使用文档
├── CHANGELOG.md        # 本文件
├── scripts/
│   └── health_check.sh # 主脚本 (8.4K)
├── logs/               # 日志目录（自动创建）
└── config/             # 配置目录（预留）
```

### 🔧 Technical Details
- **Language:** Bash (严格模式: set -euo pipefail)
- **Dependencies:** curl, jq, openclaw
- **Clash API:** Unix Socket (/tmp/verge/verge-mihomo.sock)
- **Log Level:** DEBUG/INFO/WARN/ERROR

### 📋 迁移记录
- 从 `~/clawd/scripts/` 迁移到独立项目
- 整合 scripts/ 目录到各项目（方案 B）
- 更新 TOOLS.md 路径引用

### 🎯 测试状态
- ✅ Dry-run 测试通过
- ✅ 健康检查正常
- ⏳ 定时任务待部署
- ⏳ 故障切换待测试

### 📝 待办事项
- [ ] 首次实际运行测试
- [ ] 模拟故障测试
- [ ] 部署定时任务（每 5 分钟）
- [ ] 监控一周，验证稳定性

---

## 未来计划

### v1.1 (计划)
- [ ] 支持自定义健康检查 URL
- [ ] 节点延迟测试
- [ ] 历史数据分析（最优节点统计）
- [ ] 配置文件支持（不再硬编码）

### v2.0 (远期)
- [ ] Web 界面（可视化）
- [ ] 支持 mihomo 和 Clash Verge 双版本
- [ ] 多账号支持（不同 Telegram 通知）
- [ ] 节点质量评分系统

---

*Keep it simple. Keep it working.*
