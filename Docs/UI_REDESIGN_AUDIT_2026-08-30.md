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

### 轨迹页框架语言一致性（2026-08-31）

- 调整前截图：`/tmp/harness-trajectory-live-audit-2.png`。统计、分段、运行时摘要和事件类型混用 `Duration / Turns / Calls / Model / Tools / Output / Cache / Between turns` 等英文框架标签。
- 调整：框架标签、事件角色、回合/步骤状态和常用 Inspector 字段统一为中文；provider/model、工具名、Call ID、事件原始类型、JSON、路径和参数继续保持真实技术值。
- 调整后截图：`/tmp/harness-trajectory-localized-0831-2.png`。
- 专项测试：`HarnessMobileTrajectoryUITests/testTrajectoryLedgersSearchCollapseAndInspect` 1/1 通过（`/tmp/hm-trajectory-localized-final/Logs/Test`），覆盖耗时/回合/调用三种视图、折叠、搜索、工具调用与工具结果 Inspector。
- 当前状态：模拟器布局与交互通过；深色、极限 Dynamic Type、VoiceOver、横屏和 iPhone 16 Pro 新构建仍为 `VERIFY`。

## 原生客户端详情页复核（本轮）

- 问题：详情页分区标题混用 `Native Client / Settings / Commands` 英文，与中文设置和插件市场页面不一致；技术值本身仍需保留原文。
- 调整：仅统一界面标签为“原生客户端 / 设置 / 命令”，并将摘要字段改为中文；namespace、命令名、摘要值和插件协议未改变。
- 当前状态：代码改造完成，深色、Dynamic Type 极限字号、横屏、VoiceOver 和真机仍为 `VERIFY`。

## 服务商配置页复核（本轮）

- 问题：页面分区标题仍使用 `Provider Profiles`，与中文导航和字段标签不一致。
- 调整：改为“服务商配置”显示文案；provider ID、API Key、协议和路由保持不变。

## 插件管理摘要复核（本轮）

- 问题：运行时摘要使用 `Prompt / Client / Cordis Runtime` 英文标签，与中文页面主体不一致。
- 调整：改为“提示词 / 客户端 / Cordis 运行时”；插件 ID、Host、Package 和运行状态值保持原样。

## Setup 模型选择复核（本轮）

- 问题：Setup 内的模型选择子页使用原生 `List`，没有继承设置页统一的页面背景、紧凑行高和滚动内容样式。
- 调整：复用现有 `harnessCompactListChrome()`；模型搜索、选中态和返回逻辑不变。

### 本会话模型直接选择（2026-08-31）

- 调整前截图：`/tmp/modelpicker-audit-attachments-0831-1/35BD9851-BA27-46D3-BEEA-624C08FA4997.png`。打开“选择模型”后只有范围开关和重复的当前模型卡，模型列表被隐藏，搜索框却仍显示，首屏大面积空白。
- 调整：删除重复的当前模型卡，跟随默认设置时也直接显示已有模型；点选其他模型会自动切换为本会话覆盖。服务商与推理设置仍只在覆盖模式展开。
- 搜索使用系统导航栏抽屉，避免底部浮层遮挡列表；`Provider Profile / Profile 目录` 等框架文案统一为“服务商配置 / 配置目录”，API Key、Keychain、模型 ID 和协议名保持技术原文。
- 调整后截图：跟随默认 `/tmp/modelpicker-final-attachments-0831-1/352A5850-FEF9-44DA-A190-15E119DCD0CE.png`；会话覆盖 `/tmp/modelpicker-final-attachments-0831-1/5D2D99EB-6163-4B01-A71F-A6E2F2C79647.png`。
- 专项测试：`HarnessMobileSessionModelPickerUITests/testSessionModelPickerShowsScopeAndSearchableModels` 1/1 通过（`/tmp/hm-model-picker-final/Logs/Test/Test-HarnessMobile-2026.08.31_09-28-15-+0800.xcresult`）。深色、极限 Dynamic Type、VoiceOver、横屏、真实模型目录刷新和 iPhone 16 Pro 新构建仍为 `VERIFY`。

### Setup 首次配置渐进披露（2026-08-31）

- 调整前截图：`/tmp/harness-after-bootstrap-relaunch.png`。首次配置把服务商、连接、模型、高级推理和安全边界放在同一张长表单里；连接和模型说明也沿用编辑页的完整技术文案。
- 调整：首次配置只保留服务商、连接、模型和安全边界；高级推理仍完整保留在保存后的服务商编辑页。首次配置的连接与模型说明压缩为当前操作所需信息，没有删除 Keychain、本机 Agent Loop 或第三方模型请求边界。
- 服务商行继续使用系统 Picker，但将标签和值分列对齐，避免名称紧贴左侧标签且右侧大面积空置。
- 调整后截图：`/tmp/harness-setup-provider-aligned-0831.png`。
- 专项测试：`HarnessMobileOnboardingUITests` 2/2 通过（`/tmp/hm-onboarding-ui/Logs/Test`）；新增测试确认安全边界仍可达且首次配置不展示“推理”段。
- 当前状态：模拟器代码与交互验证完成；iPhone 16 Pro 上的新构建覆盖安装、深色、极限 Dynamic Type、VoiceOver 和横屏仍为 `VERIFY`。

## 后台任务面板复核（本轮）

- 问题：聊天页打开的后台任务面板单独使用 `.insetGrouped`，与应用其他列表页面的统一背景、行高和分隔策略不一致。
- 调整：复用现有 `harnessCompactListChrome()`；任务刷新、停止、输出查看和子 Agent 顶部树状区域保持不变。

## 设置主题覆盖复核（本轮）

- 问题：设置页调用共享 `harnessCompactListChrome()` 后又重复设置系统分组背景，存在主题覆盖冗余。
- 调整：删除重复背景修饰，继续使用共享主题作为唯一页面背景来源；设置分组、导航和数据逻辑不变。

## 插件页面语言一致性复核（本轮）

- 问题：插件设置、插件管理和社区插件详情仍混用 `Settings Provider / Settings Host / Prompt / Native Client` 等用户可见英文标签。
- 调整：统一为“设置提供方 / 设置 Host / 提示词 / 原生客户端”；namespace、Prompt 类型值、插件 ID 和协议字段保持原样。

## 手机权限页渐进披露（2026-08-31）

- 调整前截图：`/tmp/phone-permissions-audit-attachments-0831-1/51410D98-5F84-43A4-B3FA-507A5BCFB4B8.png`、`/tmp/phone-permissions-audit-attachments-0831-1/3A7EEB5F-016D-45B9-9359-59EA450926DD.png`。16 项权限始终展开用途说明，状态胶囊又因外层标签样式只显示图标，造成列表过长且状态不可读。
- 调整：复用系统 `DisclosureGroup`，默认只显示权限名称与状态，按需展开用途；`HarnessStatusPill` 固定使用“图标 + 标题”，从共享入口修复状态文字丢失。权限查询、刷新、iOS 设置跳转和请求时机不变。
- 调整后截图：`/tmp/phone-permissions-final-attachments-0831-2/A502CCCE-15EB-4DCF-8B34-48DBA2D83910.png`、`/tmp/phone-permissions-final-attachments-0831-2/27DA6045-4F38-4775-9CFB-6C2D59AA5122.png`。
- 专项测试：`HarnessMobilePhonePermissionsUITests/testPhonePermissionsShowsGroupedStatusAndSystemSettingsLink` 1/1 通过（`/tmp/hm-phone-permissions-final/Logs/Test/Test-HarnessMobile-2026.08.31_18-56-24-+0800.xcresult`），覆盖真实设置入口、状态文字、默认折叠、用途展开、分组和 iOS 设置入口。真机权限状态变化、深色、极限 Dynamic Type、VoiceOver 和横屏仍为 `VERIFY`。

## 后台任务设置渐进披露（2026-08-31）

- 调整前截图：`/tmp/background-settings-audit-attachments-0831-1/FA42747D-D88A-42B3-BED5-AF6B4EE99C8E.png`、`/tmp/background-settings-audit-attachments-0831-1/6584B545-AD81-4EAA-B7B8-E6B9B317C841.png`。后台执行、定位、实时活动、通知、隐私、状态和系统投影的技术说明全部永久展开，关键开关和状态被长段落分隔。
- 调整：复用原生 `DisclosureGroup`，普通工作方式、安全限制和隐私范围默认折叠；通知拒绝和授权错误仍直接显示，执行边界仍保持可见。后台偏好、定位授权、通知请求、Live Activity 和运行状态逻辑未改变。
- 调整后截图：`/tmp/background-settings-final-attachments-0831-1/B54EF629-D6D5-4807-BB94-B5330278F214.png`、`/tmp/background-settings-final-attachments-0831-1/92BC714A-DF37-48CC-B663-28E43D2BC0CB.png`。
- 专项测试：`HarnessMobileProgressiveDisclosureUITests/testSettingsGroupsBackgroundStorageAndPrivacyWithoutHidingRoutes` 1/1 通过（`/tmp/hm-background-settings-final/Logs/Test/Test-HarnessMobile-2026.08.31_19-06-42-+0800.xcresult`），覆盖真实设置入口、默认折叠、说明展开、系统投影和执行边界。真实后台调度、系统权限变化、深色、极限 Dynamic Type、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

## 记忆管理空态与边界说明（2026-08-31）

- 调整前截图：`/tmp/memory-management-audit-attachments-0831-1/A9944E61-2C86-4EA0-B7E1-D19256024D7B.png`。空态使用大尺寸 `ContentUnavailableView`，随后又永久展开本机存储和模型发送边界，页面大部分空间被重复空态与说明占据。
- 调整：空态改为紧凑原生 `Label`；会话记忆行为及“本机保存/可能发送到配置服务商”的安全边界改为按需展开。导出 JSON、记录行、删除确认、刷新和会话记忆开关逻辑未改变。
- 调整后截图：`/tmp/memory-management-final-attachments-0831-2/02112642-2CEB-4582-9CFA-2DDE504DE183.png`。
- 专项测试：`HarnessMobileMemoryManagementUITests/testMemoryManagementKeepsSessionScopeAndExportVisible` 1/1 通过（`/tmp/hm-memory-management-final/Logs/Test/Test-HarnessMobile-2026.08.31_19-20-02-+0800.xcresult`），覆盖真实设置入口、当前会话开关、空态、默认折叠、安全说明展开和导出入口。非空记录、删除确认、真实文件导出、深色、极限 Dynamic Type、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

## 插件设置 Host 空态（2026-08-31）

- 调整前截图：`/tmp/plugin-settings-audit-attachments-0831-1/ACEDBBC8-8428-490E-877D-A85D2746AE79.png`。Host 未就绪时使用整屏空态，“启动 Host”只显示播放图标，且没有 namespace 时仍保留无效搜索框。
- 调整：未就绪和无 namespace 状态改为紧凑原生分组；启动按钮显式显示图标与标题；只有真实 namespace 可搜索时才展示搜索。Host 启动、刷新、设置快照、编辑器、保存和冲突逻辑未改变。
- 调整后截图：`/tmp/plugin-settings-final-attachments-0831-1/EACB544D-3D51-4411-B7C0-6A7EA257ED34.png`。
- 专项测试：`HarnessMobilePluginSettingsUITests/testPluginSettingsShowsHostStateFromPluginRoute` 1/1 通过（`/tmp/hm-plugin-settings-final/Logs/Test/Test-HarnessMobile-2026.08.31_19-29-56-+0800.xcresult`），覆盖设置 → Cordis 插件 → 插件设置真实入口、Host 空态、启动标题、刷新和无效搜索隐藏。真机 Host、namespace 列表、编辑器、revision 冲突、深色、极限 Dynamic Type、VoiceOver 和横屏仍为 `VERIFY`。

## 聊天空态与错误恢复复核（2026-08-31）

- 当前截图：空会话 `/tmp/chat-chrome-audit-attachments-0831-1/70BA5F86-8C8F-4F07-A93D-8D5FF05A1A8E.png`；行内错误 `/tmp/chat-chrome-audit-attachments-0831-1/374E5262-8E71-4262-B32E-16D707CAECAB.png`。
- 结论：空会话只保留单一“有什么要处理？”入口和常驻输入栏；错误使用可关闭的行内提示，没有模态弹窗，也没有遮挡会话标题。消息操作按钮保留 44pt 点击区和现有上下文菜单，未为追求更小视觉而牺牲无障碍。
- 本轮不改生产 UI；新增专项证据防止空态、输入栏和错误条后续回归。`HarnessMobileChatChromeUITests` 2/2 通过（`/tmp/hm-chat-chrome-audit/Logs/Test/Test-HarnessMobile-2026.08.31_19-36-38-+0800.xcresult`）。运行中、排队输入、图片/文件、审批、长对话、深色、极限 Dynamic Type、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

## 全界面覆盖清单（截至本轮）

| 界面 | 已检查内容 | 状态 |
| --- | --- | --- |
| 首页 / 项目列表 | 项目优先、搜索、新建会话、工具与设置入口 | DONE |
| 聊天页 | 会话标题、输入栏、会话选项、轨迹切换、工作状态 Dock | VERIFY |
| 模型选择 | 搜索、选中态、空结果、默认/会话覆盖 | DONE |
| 工具总览 | 工作区、终端、任务/轨迹、插件、设置路由 | DONE |
| Console | 任务 / 轨迹分段，移除重复插件入口 | DONE |
| Work State | 目标、计划、待办、恢复和错误状态 | DONE |
| Workspace | 挂载目录、文件列表、空态动作 | DONE |
| iSH 终端 | 模式切换、状态卡、命令空态、底部输入栏 | DONE |
| 轨迹 | 统计、Trace、Duration/Turns/Calls、搜索与折叠 | VERIFY |
| 插件管理 | 运行时摘要、Host、插件库存和搜索 | DONE |
| 原生客户端详情 | 分区标签、命令与设置入口 | DONE |
| 社区插件市场 | 市场/已安装、搜索、目录行和操作菜单 | DONE |
| 插件设置 | Host 状态、namespace 列表、编辑器和冲突态 | VERIFY |
| 服务商配置 | Profile 列表、添加、模型行为和凭据状态 | DONE |
| Setup / Onboarding | 服务商、连接、模型、保存开始 | VERIFY |
| 后台任务设置 | 执行、定位、Live Activity、通知、隐私 | VERIFY |
| 手机权限 | 权限分组、状态刷新和 iOS 设置入口 | VERIFY |
| 记忆管理 | 当前会话开关、记忆列表、导出和删除 | VERIFY |

`DONE` 表示已有代码调整并通过构建或专项证据；`VERIFY` 表示已检查结构但仍缺少完整的深色、极限 Dynamic Type、横屏、VoiceOver 或真机截图证据。当前未将 `VERIFY` 页面冒充为完成。
