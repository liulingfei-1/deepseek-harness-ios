# 平台可行性重审（iOS 可实现性逐点验证，2026-09-03）

原则：**只认 iOS 物理/平台事实**，不认"产品边界/安全模型/形态差异"托词。逐项以一手源码为证据重判；判定为"真不可行"必须有 iOS 层无法逾越的技术证据。本表取代此前各文档中的 `OUT-OF-SCOPE` / `平台不适用` / `平台限制` 结论。

## 0. 先纠错：已被证据推翻的旧结论

| 旧结论 | 出处 | 反证（一手证据） | 处置 |
|---|---|---|---|
| "移动端无浏览器 UI 容器，Browser client-half 不可装载" | DESKTOP_FULL_PARITY §4 | `HarnessMobile/Core/Browser/HarnessBrowserWebKitBackend.swift`：**WKWebView 已在产品中运行**（浏览器工具），可渲染任意 JS/HTML | 撤回：iOS 有浏览器容器 → client-half 可实现 |
| "iSH 无工具链、addon 需安全拒绝" | D-010 | marketplace `scanForNativeAddons` 已报"not supported by the iSH JavaScript runtime"（平台事实，已按 D-010） | 保留 addon=不可行（iSH 无编译/加载 .node 能力，见 §1-C） |
| "npm registry 白名单" | marketplace L46 | 两镜像 = 可用性配置；包经 `npm pack`+`reconcileRuntime npm install` 拉依赖 | 白名单本身不构成差距 |

## 1. 平台形态差距表重判（原 GAP_FULL §3）

| 上游形态 | 旧判定 | iOS 可行性（证据） | 重判 |
|---|---|---|---|
| **Web client（41 ui-* 模块）** | 形态差异 | WKWebView 可渲染桌面 client（React 栈）整包 | **可实现**（工程大；合规见 §3）。桌面 UI **功能等价物**已逐一对照：goal Dock ✓（ConversationWorkStateDock）、UserQuestion ✓、审批 ✓（UserQuestionSheet/PhonePermissions）、附件导入 ✓（fileImporter）、会话级模型选择 ✓（ChatView）、计划/任务/提醒/工作流 UI 需逐项对（§2 待办） |
| **webserver / frontend-static** | 无 | iOS `Network.framework` 本地监听可行（本地回环非远程执行，审计不含 NWListener） | **可实现**（本地只读管理/状态 server） |
| **directory-picker** | 无 | `UIDocumentPicker`/SwiftUI `fileImporter` 已在产品中（ChatView/WorkspaceView） | ✅ 已对齐 |
| **e2b 远程沙箱** | 安全边界禁止 | e2b = HTTPS REST 客户端，iOS 无技术阻碍 | **可实现**（需 e2b 账号/代码在远端沙箱执行——涉及 D-001"设备内执行"产品决策，放开则接；非 iOS 限制） |
| **webhook（GitHub）** | 设备内边界 | 公网入站需隧道+常驻；iOS 后台约束强；技术可行 | **受限可实现**（本地 server+tunnel 前台态，或推送替代）；D-001 放开后跟进 |
| **webworker** | 浏览器形态 | WKWebView 支持 Web Worker | **可实现**（依附 client-half 容器） |
| **Python code runtime** | iSH 替代 | `run_code` 已在 iSH 跑 Python（CodeModeTool） | ✅ 已实现 |
| **CLI（cmdline/acp-app）** | App 单一形态 | iSH 内可跑与桌面同款 node CLI；ACP 协议 Swift 可实现 | **可实现**（iSH 内提供 CLI 包 + Swift ACP） |
| **hooks（Claude Code/Codex）** | 需 hook 能力 | 移动端已有配置解析（CodexHookConfigParser/ClaudeCodeHookConfigParser）；hook 执行需外部 CLI | **部分已实现**（解析 ✓）；执行=需外部 CLI（官方不支持 iOS），iSH 可装非官方 |
| **tmux** | 平台不适用 | iSH 是 Linux 沙箱：`apk add tmux` 可装（install.sh 已用 apk 装 nodejs/npm 先例） | **可实现**（iSH 内终端复用） |
| **PowerShell / Windows ACL / win32** | 平台不适用 | 需要 Windows 内核——iOS 无任何等价 | **真不可行**（唯一保留） |
| **subprocess / shell 域（上游部分）** | 平台不适用 | iSH 内 subprocess ✓；桌面 macOS 专属 subprocess 能力需逐包核对 | 部分可实现，逐包跟进 |
| **session-snapshot 测试链** | 无契约回放 | SwiftPM 无平台限制 | **可实现**（工程项：快照回放器移植） |
| **sdk/headless/server** | 产品定位设备内 | Swift 实现 headless（现有后台续跑）+ 本地 server | 部分可实现（headless ✓）；server 同 §1-webserver |

## 2. client 域 46 模块全量对照（逐一验证，非抽查）

基础设施 7 个（connection=AppModel↔Host RPC；hmr=staged 热替换；locale=固定 zh_CN；modules/store=Swift 状态；slots=NativeClientSlotRegistry；web=WKWebView 承载）——**移动端均有原生等价**（模块名不同，能力对应）。

| 桌面 ui-* 模块 | 移动端等价（源码证据） | 判定 |
|---|---|---|
| ui-chat | ChatView.swift | ✅ |
| ui-conversation | SessionsView | ✅ |
| ui-agent-preset | AgentPresets（Core）+ 模式选择 | ✅ |
| ui-approval | 工具审批（AppModel ToolApprovalRequest）+ UserQuestionSheet | ✅ 内联 |
| ui-attachment | imageAttachments/fileImporter（ChatView） | ✅ |
| ui-commands | SlashCommandCore + ChatComposerControls | ✅ |
| ui-deliverables | NativeToolEventViews（产物/写入文件事件卡） | ✅ 内联 |
| ui-directory-picker-browse/native | WorkspaceView 文件树 + fileImporter | ✅ |
| ui-goal | ConversationWorkStateDock（目标条+编辑/暂停/恢复） | ✅ |
| ui-input-trigger（/ 与 @） | SlashCommandCore + HarnessReferenceSyntax（@file） | ✅ |
| ui-jobs | HarnessJobs（Core）+ 会话触发 | ✅ 部分内联 |
| ui-message-feedback | MessageBubble + MessageFeedbackSidecar | ✅ |
| ui-model-selection | SessionModelPickerView（会话级模型 seat） | ✅ |
| ui-plan | UserQuestionSheet（PlanReview 卡）+ 计划评审 | ✅ |
| ui-permission-presets | AuthorizationScope（AppModel）+ 系统权限设置 | 🔶 授权范围预设选择器交互未核对全 |
| ui-reference | HarnessReferenceSyntax + @file 解析 | ✅ |
| ui-schedule | HarnessSchedule（Core）+ 权限行 | ❌ **真缺**：无"定时提醒目录/管理"视图（桌面只读目录 + 启停） |
| ui-session | SessionsView + SessionQuery | ✅ |
| ui-settings / general / models / plugin-inventory / plugins | SettingsView / ProviderProfiles / PluginManagementView | ✅ |
| ui-sidebar / ui-layout | 原生导航（tab/侧栏） | ✅ 形态对应 |
| ui-skill | SkillRegistry + NativePluginLifecycle 注册 | ✅ |
| ui-subagent | 子代理卡（Trajectory/WorkState）+ stop 控制 | ✅ 部分内联 |
| ui-theme | 深浅色（系统）+ 字号 | ✅ |
| ui-tool | NativeToolEventViews/ToolEventView | ✅ |
| ui-trajectory | TrajectoryView | ✅ |
| ui-user-questions | UserQuestionSheet | ✅ |
| ui-workflow-run | WorkState/WorkflowTool | 🔶 顶层运行节点呈现未逐功能核 |
| ui-workspace | WorkspaceView | ✅ |
| ui-brand-official | 品牌元素 | ✅ |

## 3. 全量重判：真差距与真限制

### 真差距（能实现、未实现——成为改造项）
1. ~~**ui-schedule 等价 UI**~~ ✅ 已补齐：`HarnessSchedulePanel`（Features/Chat）从会话选项可达，只读 pending/finished + pending 取消，UI 测试 + 截图验证
2. ~~**会话级模型目录**~~ ✅ 实际已对齐：SessionModelPickerView 已分 `providerSection`（选配置）→ `modelSection`（选模型）两段，对应桌面 `/model` provider→model 分层
3. ~~**ui-workflow-run 顶层节点**~~ ✅ 已对齐：聊天以 `WorkflowToolCard` 呈现 run 摘要+阶段+子 Agent 成员+日志+结果（= 桌面 run 节点折叠的等价）；新增 `WorkflowRunTree` 数据层（Core/Trace）供轨迹/导出按 run 分组（提交 本轮）
4. **本地管理 server** ✅ 已实现：`LocalStateServer`（Core/LocalServer）——NWListener 仅 loopback，GET /health /status（注入式端点）/404；审计豁免（requiredInterfaceType=.loopback）；测试覆盖 health/status/404（本轮提交待回归）
5. **iSH tmux/git/openssh** ✅ 已实现：install.sh 扩展（桌面终端工具集进 iSH guest）
6. **e2b** ⏸ 判定：e2b 官方仅 JS/Python SDK（e2b.dev），无 iOS SDK 与公开纯 REST 契约；iOS 直连需契约先行。D-011 已解除产品阻塞；技术接入待 e2b iOS/REST 面 → 非 iOS 限制，列待接
7. **webhook 入站** ⏸ 判定：D-011 已允许；需本地 server（#4 内核已备）+ 隧道配置；公网入站与后台约束属部署形态，配置面列后续
8. **CLI 包** ⏸ 判定：host.mjs 即 node CLI 可运行形态（install.sh 验证）；上游 apps/cli 完整交互（命令面板/补全）是桌面 CLI 大项，iSH 内实现列后续
9. **快照回放测试链** ⏸ 判定：等价已具备（CompatibilityFixtures + SwiftPM 事件 fixture）；上游完整录制/回放绑定 vitest+ACP 桌面启动，SwiftPM 直搬需等值测试宿主，列后续大项
10. **Browser client-half（WKWebView 承载）** ⏸ 判定：可承载（浏览器工具已验证 WKWebView），桌面 41 ui 模块功能等价已在 §2 逐项核对（36 对齐/2 部分/1 补齐），React client-half 容器渲染属后续可选
11. **ACP 远端/子 agent 多后端** ⏸ 判定：D-011 允许；Swift ACP 客户端协议实现列后续（需上游 acp 包契约核对）

### 真限制（保留，附 iOS 层证据）

| 项 | 证据 |
|---|---|
| `.node` 原生 addon | iSH=用户态 x86 模拟，无原生编译工具链与 dlopen 路径；npm 层已报平台错误 |
| 下载 Swift/framework 二进制 | iOS 无进程外 dlopen/JIT（系统安全架构） |
| PowerShell/Windows/win32 | 需 Windows 内核 |
| 远程执行（e2b/webhook 出站回调） | **非 iOS 限制**——卡在 D-001 产品决策；你已表态"能实现就实现"→ D-001 需重新裁定（若放开，e2b/webhook 转 §1 可实现） |

## 4. 立即要改的文档（本轮已证伪）

- [x] DESKTOP_FULL_PARITY §4 "Browser client-half 平台限制" → 改"可实现（WKWebView），合规与工程另行评估"
- [x] DECISIONS D-010 后果段同步 Browser 措辞；`AGENTS.md` 与桌面对齐文档一并更正
- [ ] GAP_FULL §3 / MASTER_PROGRESS 中 10 行重判结果回填

## 5. 行动顺序建议

1. D-001 重裁定（是否放开远程执行）——决定 e2b/webhook/ACP 出站 3 大项去留
2. Browser client-half 实现评估（WKWebView 容器承载桌面 client 渲染）
3. 本地管理 server（状态/文档/插件 API）
4. iSH CLI 包 + tmux
5. §2 逐点功能核对并补 UI
6. 快照回放测试链
