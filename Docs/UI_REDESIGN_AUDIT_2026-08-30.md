# 首页 UI 重新审计（2026-08-30）

## 结论

首页的首要任务是让用户选择或新建一个项目。当前代码没有独立的 Project 模型，持久化的会话标题是现有系统里最稳定、最接近项目名称的入口，因此首页直接以会话标题呈现项目列表。

这也回答了首页的信息层级问题：项目名称是首页主内容；后台运行态、工具入口、存储说明、权限和诊断属于二级管理能力，不应与项目列表并列占据首页首屏。它们分别通过“工具”和“设置”进入，只有用户主动进入对应路径时才展开。

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
- 搜索改为系统自动展开，默认状态保留可发现的搜索入口但不强制占用首屏高度。

## 模拟器证据

- 设备：`Harness UI Audit`（`C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD`）
- 首页截图：`/tmp/harness-ui-home-projects.png`
- 搜索收口后截图：`/tmp/harness-home-projects-search-collapsed.png`
- 调整前遮挡证据：`/tmp/harness-ui-chat-error-cold2.png`
- 构建：arm64 iOS Simulator build succeeded（`/tmp/hm-ui-derived`）

## 自动化与剩余边界

本轮更新了首页无障碍与渐进披露测试，需在重新安装模拟器产物后执行相关 UI 测试。深色模式、Dynamic Type 极限字号、VoiceOver 朗读顺序、横屏和 iPhone 16 Pro 真机触控仍属于 `VERIFY`，不能用模拟器构建结果代替。

## 用户选择与 Plan Review（本轮）

- 普通选项卡原先混用默认系统背景，选中态只有浅色填充，边界不够清楚；现在复用 `HarnessTheme.surface` 和语义分隔线，选中态增加边界。
- Plan Review 顶部改用共享表面，底部动作统一为中文“讨论计划 / 拒绝 / 批准”，保留原有按钮标识、回调和桌面动作集合。
- 构建：arm64 iOS Simulator build succeeded（`/tmp/hm-user-question`）。
- 专项测试：`HarnessMobilePlanReviewUITests/testPlanReviewPresentsAllDesktopActions` 1/1 通过（`/tmp/hm-user-question-tests/Logs/Test/Test-HarnessMobile-2026.08.30_16-57-17-+0800.xcresult`）。
- 裸启动参数只能准备会话，必须由 UI 测试打开会话后才会出现 Plan Review；因此未把冷启动空白页截图冒充弹层证据。弹层深色、大字、横屏和真机触控仍为 `VERIFY`。

## 设置页首屏复核（本轮）

- 真实模拟器截图：`/tmp/harness-ui-settings-progressive.png`。
- 设置页首屏按“模型 / 后台 / 工具与插件”分组，视觉主题已统一；在当前字号下结构清楚，但信息密度偏高。
- 本轮不继续拆分设置摘要：这些摘要值能帮助用户确认当前配置，且已有对应子页承载详细操作。后续只在 Dynamic Type、横屏或真机截图证明发生遮挡时再调整。
- 可靠夹具下设置分组路由专项测试：1/1 通过（`/tmp/hm-settings-progress2/Logs/Test/Test-HarnessMobile-2026.08.30_17-21-11-+0800.xcresult`）。此前无夹具运行停在 onboarding，不能作为设置页布局证据。

### 设置页分组修订

- 前后截图：`/tmp/harness-ui-settings-progressive.png`、`/tmp/harness-ui-settings-agent-permissions.png`。
- 将“Agent 编排 Bundle / 手机权限”从“工具与插件”拆为独立的“Agent 与权限”分组；Cordis、工具授权和本机工具仍留在“工具与插件”。
- 仅改变信息分组，不改变任何导航、状态、权限请求或授权逻辑。
- 可靠夹具下设置分组路由测试：1/1 通过（`/tmp/hm-settings-agent-perm/Logs/Test/Test-HarnessMobile-2026.08.30_17-33-09-+0800.xcresult`）。

## 社区插件市场首屏复核（本轮）

- 真实模拟器截图：`/tmp/harness-ui-community-market-audit.png`。
- 首屏已按“市场/已安装 + 目录摘要 + 搜索”组织，统计宫格和实现细节没有回流；插件目录行能直接看到名称、描述、分类、原生优先和安装状态。
- 本轮不再改市场布局；刷新、导入、GitHub、清理缓存继续收在操作菜单中，符合渐进披露。
- 专项测试：`HarnessMobilePluginManagementUITests/testCommunityMarketplaceUsesCompactSearchableList` 1/1 通过（`/tmp/hm-plugin-market-audit2/Logs/Test/Test-HarnessMobile-2026.08.30_17-41-31-+0800.xcresult`）。

## Workspace 空态复核（本轮）

- 现状截图：`/tmp/workspace-current-9.png`。
- 截图显示“挂载目录”和“文件”之间存在较大空白，空文件状态占据整个区域；用户必须先猜测右上角 `+` 才能找到导入入口。
- 调整：复用原有 `ContentUnavailableView`、`HarnessTheme` 和文件/文件夹导入状态，在空文件区补充一句范围说明，并提供“导入文件”“挂载文件夹”两个原地动作；没有新增依赖、模型或数据路径。
- 视觉目标：减少空白、把下一步动作放到空态上下文中，同时保留右上角菜单作为全局入口。
- 构建：arm64 iOS Simulator build succeeded（`/tmp/hm-workspace-ui-2`）。
- 专项 UI 测试命令：`HarnessMobileWorkspaceHierarchyUITests/testWorkspaceRootExposesFilesMountsAndSessionStateFromHome`；测试启动阶段因环境报错 `xcrun: error: unable to find utility "simctl", not a developer tool or in PATH`，结果为失败，不能据此判断 Workspace 交互回归。
- 当前状态：代码改造完成，布局截图需在 UI 自动化桥接恢复后重新采集；深色、Dynamic Type 极限字号、横屏、VoiceOver 和真机仍为 `VERIFY`。

## 工具总览与 Console 复核（本轮）

- 工具总览现状：工作区、终端、任务/轨迹、插件和设置均作为同级行展示；设置与插件仍保留独立入口，避免从首页或项目列表回流管理信息。
- Console 问题：原控制台同时放入“任务”“插件”“轨迹”；插件管理与工具总览已有独立入口，重复出现会增加选择成本。
- 调整：删除 Console 内置插件分段，仅保留“任务”和“轨迹”；复用原有 `Picker`、导航路由和插件管理页面，不新增抽象。
- 视觉目标：控制台只承担运行观察职责，工具与插件管理回到工具总览的独立路径。
- 当前状态：代码改造完成，深色、Dynamic Type 极限字号、横屏、VoiceOver 和真机仍为 `VERIFY`。

## Work State 复核（本轮）

- 问题：无目标、计划或待办时，页面同时显示“暂无任务状态”空态和“创建会话目标”入口；两者重复占用列表首屏空间。
- 调整：删除冗余 `ContentUnavailableView`，保留“目标”分组中的“创建会话目标”作为唯一行动入口；运行中、可恢复任务和错误状态逻辑不变。
- 视觉目标：空状态直接落到可执行动作，减少无效留白。
- 当前状态：代码改造完成，深色、Dynamic Type 极限字号、横屏、VoiceOver 和真机仍为 `VERIFY`。

## iSH 终端空态复核（本轮）

- 问题：命令记录为空时，`ContentUnavailableView` 额外保留 48pt 顶部留白；上方状态卡与底部固定命令栏之间出现不必要的断层。
- 调整：移除空态额外顶部 padding；命令栏、状态卡、网络开关和执行逻辑不变。
- 轨迹页本轮仅完成结构检查：统计、Trace、视图模式和事件列表职责清晰，未凭主观判断重排。
- 当前状态：代码改造完成，深色、Dynamic Type 极限字号、横屏、VoiceOver 和真机仍为 `VERIFY`。
