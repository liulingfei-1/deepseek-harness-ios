# Harness Mobile 实施计划

状态：活动控制文档
详细任务真源：[桌面修补日志](Docs/DESKTOP_PARITY_REMEDIATION.md)
产品范围：[PRD](PRD.md)

## 使用规则

本文件只维护阶段、顺序和验收门，不复制每个 parity ID。具体代码路径、命令、结果和剩余真机边界继续写入修补日志。

## 当前阶段

| 阶段 | 目标 | 状态 | 完成门 |
| --- | --- | --- | --- |
| P0 控制基线 | 12 份控制文档接入 `AGENTS.md` | DONE | 13 个入口文件、相对链接、优先级和 `git diff --check` 已验证 |
| P1 UI 收口 | 逐页审计全部主要界面并最小改造 | DONE（模拟器范围） | 审计表 26 页 DONE、仅 VoiceOver/触控归 P4 真机矩阵；116 张证据覆盖深色/浅色/XXXL 三模式，11 类专项测试全绿 |
| P2 Runtime/Parity | 完成活动 parity 项和上游契约核对 | IN PROGRESS | 修补日志活动项均有诚实状态和证据 |
| P3 能力/安全 | 对齐生产目录、权限、entitlement、清单和边界 | IN PROGRESS | capability verifier、边界审计与安全测试通过 |
| P4 真机验收 | 在 iPhone 16 Pro 覆盖真实路径 | VERIFY | API、图片、文件、iSH、插件、后台、长会话、诊断、UI 矩阵通过 |
| P5 发布收尾 | 可复现构建、文档、许可证和发布检查 | TODO | Release checklist 全部通过 |

## P1：界面顺序

已完成的批次以 [UI 审计](Docs/UI_REDESIGN_AUDIT_2026-08-30.md) 和 Git 历史为准。下一轮按用户频率和风险处理：

1. 手机权限与后台任务设置。
2. 记忆管理与插件设置。
3. 聊天页剩余状态、模型选择回归和轨迹完整矩阵。
4. 深色、极限 Dynamic Type、横屏、VoiceOver 和真机统一复核。

每页执行：真实入口截图 → 问题记录 → 删除/复用优先改造 → 最小 UI 测试 → 调整后截图 → 独立提交。

## P2：Runtime/Parity

- 先关闭安全、数据丢失、错误状态和 session/run ownership 缺口。
- 再处理 Provider wire、Agent loop、插件 generation、后台恢复和长会话性能。
- 每个 parity 项同步生产路径、窄测试、全量影响和真机边界。
- 不以宽范围重写 `AppModel` 或 `AgentRuntime` 代替单一根因修复。

## P3：能力与安全

- 核对 `ProductionToolCatalog`、`CAPABILITY_MANIFEST.json`、移动能力矩阵和 Info.plist/entitlement。
- 每个工具明确授权、系统权限、资源范围、模型数据出口、取消、超时和脱敏。
- 插件、ZIP、路径、网络和凭据变更运行安全门禁。

## P4：真机矩阵

| 组 | 必须证据 |
| --- | --- |
| Provider | DeepSeek/OpenAI-compatible/Anthropic 真实请求、流式、重试、会话覆盖 |
| 输入 | 图片、OCR、文件导入、分享扩展和深链 |
| 工具 | 代表性读/写/危险工具及权限拒绝 |
| iSH/插件 | shell、Host 启停、市场安装、设置、升级/回滚 |
| 后台 | 切屏、锁屏、到期、恢复、通知、Live Activity |
| 稳定性 | 长会话、热、内存、低电量、断网和诊断导出 |
| UI | 浅/深色、大字、横屏、VoiceOver、键盘与触控 |

## 每批变更模板

```text
目标：
生产路径：
保持不变：
自动化：命令 + 结果
设备：型号/系统 + 结果
文档：更新项
剩余：VERIFY 边界
```

## 下一步判定

优先处理能推进真实用户闭环或关闭高风险 `VERIFY` 的最小项。设备离线时继续完成不依赖设备的审计、测试和签名构建，但不得把待安装写成已验收。
