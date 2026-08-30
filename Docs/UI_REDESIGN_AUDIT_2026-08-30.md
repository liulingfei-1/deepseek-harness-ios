# 首页 UI 重新审计（2026-08-30）

## 结论

首页的首要任务是让用户选择或新建一个项目。当前代码没有独立的 Project 模型，持久化的会话标题是现有系统里最稳定、最接近项目名称的入口，因此首页直接以会话标题呈现项目列表。

## 已确认的问题

- 旧首页把“继续当前任务”放在项目列表之前，用户进入应用后首先看到的是运行态动作，而不是项目。
- 旧首页把后台任务数量、降级原因和恢复设置放在首屏，属于系统运营信息，不是项目选择的核心路径。
- 浮动新建按钮曾可能覆盖底部列表内容，尤其在紧凑高度和大字体下风险更明显。

## 本轮调整

- 移除首页的“继续当前任务”区块。
- 移除首页的后台系统状态区块；后台设置仍保留在设置导航中。
- 将活动会话分区标题改为“项目”，归档筛选仍显示归档内容。
- 复用现有 `ConversationSessionSummary.title` 作为项目名称，不新增 Project 抽象或持久化迁移。
- 使用 `List.safeAreaInset(edge: .bottom)` 放置“新建会话”按钮，避免遮挡项目行。

## 模拟器证据

- 设备：`Harness UI Audit`（`C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD`）
- 首页截图：`/tmp/harness-ui-home-projects.png`
- 调整前遮挡证据：`/tmp/harness-ui-chat-error-cold2.png`
- 构建：arm64 iOS Simulator build succeeded（`/tmp/hm-ui-derived`）

## 自动化与剩余边界

本轮更新了首页无障碍与渐进披露测试，需在重新安装模拟器产物后执行相关 UI 测试。深色模式、Dynamic Type 极限字号、VoiceOver 朗读顺序、横屏和 iPhone 16 Pro 真机触控仍属于 `VERIFY`，不能用模拟器构建结果代替。
