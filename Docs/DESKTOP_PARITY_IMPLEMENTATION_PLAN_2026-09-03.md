# Harness Mobile × 最新 DeepSeek Harness Desktop：逐项实施计划

更新时间：2026-09-03  
文档类型：审计基线、实施顺序、验收门和状态记录  
适用分支：`codex/deepseek-parity`

## 1. 目标与事实边界

目标是把移动端当前可实现的行为逐项对齐到 `deepseek-ai/deepseek-harness` 最新上游，而不是仅凭控制文档声称“已对齐”。每一项都必须先在源码、上游包和运行路径中复核，再修改、测试、构建，并把结果写回 `Docs/DESKTOP_PARITY_REMEDIATION.md`。

本计划不删除或绕过仓库的产品、平台、权限和质量硬边界。远程执行、下载原生二进制、桌面 Web 容器等能力，即使用户希望“完全一样”，也必须按真实技术和平台事实标成 `IOS-REPLACEMENT`、`VERIFY` 或 `OUT-OF-SCOPE`，不能伪装成 `DONE`。

### 1.1 审计基线

| 项目 | 已验证值 |
|---|---|
| 移动端 HEAD | `9e33cd43` |
| 当前移动端锁定上游 | `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` / `dsh-v0.1.1-rc.2` |
| 最新上游仓库 | `deepseek-ai/deepseek-harness` |
| 最新上游 HEAD | `76fda729799fe9b3848dbe2c211d4b231032b81e`（2026-09-03） |
| 上游 packages | 约 257 个 package manifest |
| SwiftPM 基线 | 895 tests，5 skipped，0 failures |
| Node/Host 基线 | `npm run check` 通过；`ISHPluginHostNodeSmoke.mjs` 通过 |
| 工作树 | 初始审计时干净 |

### 1.2 状态词

- `DONE`：代码、自动化测试、指定构建和可获得的运行证据全部通过。
- `VERIFY`：代码和自动化门通过，但仍缺真实 API、iSH、长会话、系统授权或 iPhone 设备证据。
- `IOS-REPLACEMENT`：以原生 Swift/iSH 行为替代桌面实现，用户可见语义已覆盖，但实现机制不能相同。
- `OUT-OF-SCOPE`：与 iOS 平台、产品决策或当前发行形态冲突，不纳入本产品执行路径。

## 2. 统一执行协议

每个 PARITY 项按以下顺序执行，完成后才进入下一项：

1. **上游核对**：记录 package、commit、入口、wire schema、测试或运行命令；不以文档描述代替源码验证。
2. **移动端定位**：用 `rg` 找到当前实现、调用方、生产注册点和测试；标出“源码存在但未接线”与“部分实现”。
3. **最小补丁**：只改该项所需文件；涉及产品/流程/UI/运行时/依赖时同步相应控制文档。
4. **自动化验证**：运行该项专项测试，再运行全量门。
5. **运行验证**：涉及 UI、iSH、真实 provider、后台、系统授权、插件、图片或长会话时，补 Simulator；有条件时补 iPhone 16 Pro。没有设备证据保持 `VERIFY`。
6. **回写证据**：在 `Docs/DESKTOP_PARITY_REMEDIATION.md` 记录状态、命令、真实输出摘要、失败原因和剩余边界。
7. **收口检查**：`git diff --check`、上游一致性审计和无远程执行审计均通过后才算该项完成。

标准门：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /tmp/hm-xcode build
cd HarnessMobile/Resources/PluginHost && npm run check
node HarnessMobileTests/ISHPluginHostNodeSmoke.mjs HarnessMobile/Resources/PluginHost
cd /Users/liulingfei/Documents/ChatGPT/deepseek
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

## 3. 差距清单与逐项改造

### PARITY-001 · DeepSeek 请求扩展注册表接入

- **上游参考**：DeepSeek provider request extension、provider-native wire serializer。
- **当前证据**：`HarnessMobile/Core/Network/DeepSeekLlmAPIExtensionRegistry.swift` 只有 registry；`ChatAPIModels.swift:280` 请求序列化没有扩展入口；AppModel/AgentRuntime/HTTP dispatch 未实例化或调用 registry。
- **目标行为**：扩展可由 provider/profile 注册；每次请求按当前会话解析扩展字段；未知扩展可诊断失败，不静默丢弃；SSE、重试、取消和 replay metadata 保持一致。
- **影响文件**：`Core/Network/DeepSeekLlmAPIExtensionRegistry.swift`、`ChatAPIModels.swift`、DeepSeek client、`AgentRuntime.swift`、配置/设置模型、相关 fixtures/tests。
- **步骤**：定义不可变 request extension snapshot；在请求组装点注入；在真实 DeepSeek HTTP dispatch 发送；补重试与日志脱敏；增加 profile reload 测试。
- **验收**：编码序列化、未知字段、SSE、重试、取消、真实 provider 请求；Simulator build；真机 provider 请求未验证则 `VERIFY`。
- **完成条件**：生产路径能看到并发送扩展字段，且请求/重放/诊断均可回溯。

### PARITY-002 · `session-log-deepseek` 增量日志协议

- **上游参考**：`session-log-deepseek` package、`delivery-accepted` event、watermark/suffix upload。
- **当前证据**：移动端只有事件名 `session-log-deepseek/delivery-accepted`，没有 `dsh_session_log` 字段、水位线、suffix 上传或 accepted cursor。
- **目标行为**：按会话增量序列化事件，携带稳定 cursor/watermark；服务端 2xx 后推进水位线；失败可重试且不重复确认；诊断显示 pending/accepted。
- **影响文件**：`Core/Trace`、DeepSeek request models/client、Workspace/session persistence、settings、tests。
- **步骤**：建立 durable watermark store；实现 suffix encoder/decoder；接入请求扩展；实现 2xx/非 2xx/超时/取消路径；补迁移和重启恢复。
- **完成条件**：连续会话、重启、重复提交和网络失败均保持事件顺序与 accepted cursor 正确。

### PARITY-003 · Session telemetry / OTel 生产接线

- **上游参考**：`SessionTelemetry`、OTLP sink、`FEEDBACK_ONLY`/disabled 模式。
- **当前证据**：`SessionTelemetry.swift` 有 capture、OTLP sink 和模式；生产代码未调用 `capture`，`AppModel.swift:5355` 初始化 AgentRuntime 时没有 sink；移动端默认 `.disabled`，上游桌面 base 默认 `FEEDBACK_ONLY`。
- **目标行为**：session append、tool、model、error、cancel 事件进入 coordinator；反馈模式只在用户触发反馈时释放；flush/shutdown 可观测；不泄露凭据和原文敏感字段。
- **影响文件**：`Core/Trace/SessionTelemetry.swift`、`AppModel.swift`、AgentRuntime、settings/UI、diagnostic export、tests。
- **步骤**：注入 coordinator/sink；定义事件映射和采样；实现 feedback release、flush、shutdown；补 offline queue、重启恢复和脱敏断言。
- **完成条件**：生产 append 事件可被 sink 捕获，模式切换和反馈释放有自动化证据；无设备证据仍为 `VERIFY`。

### PARITY-004 · Session turn outline UI 与分页跳转

- **上游参考**：桌面 turn outline/session query UI。
- **当前证据**：`SessionTurnOutline.swift` fold 和测试存在，但生产 UI 未引用；`TrajectoryView.swift:620` 使用自己的窗口分组逻辑。
- **目标行为**：从全日志生成稳定 turn outline，支持折叠、定位、分页加载、工具/子 Agent 标记，跨冷启动保持。
- **影响文件**：`Core/Trace/SessionTurnOutline.swift`、`Features/Trajectory/TrajectoryView.swift`、Chat UI、session query、tests。
- **步骤**：统一 outline 数据源；把分页 cursor 与 outline node 绑定；实现跳转/加载更多；处理流式追加、压缩和事件缺口；补 VoiceOver/Dynamic Type。
- **完成条件**：长会话、压缩后会话、冷启动和缺页状态均可稳定导航。

### PARITY-005 · ACP 子 Agent 真实 transport/provider

- **上游参考**：ACP subagent lifecycle、stdio transport/provider registry。
- **当前证据**：`ACPSubagentClient.swift` 只有注入式 `ACPLineTransport` 和 5 个测试；生产源码没有 transport conformer、iSH stdio bridge 或 provider 注册。
- **目标行为**：真实子进程/stdio 生命周期、initialize、prompt、cancel、shutdown、错误映射和轨迹投影与桌面 wire 兼容。
- **影响文件**：`Core/Subagent/ACPSubagentClient.swift`、iSH bridge、Jobs/provider catalog、trajectory、tests。
- **步骤**：实现本机 iSH line transport；注册 ACP provider；加入超时、退出码、信号和重连；统一 session/job identity；补并发与取消。
- **完成条件**：真实 iSH fixture 能完成完整生命周期；无真机运行证据标 `VERIFY`。

### PARITY-006 · 子 Agent 模型/Provider/reasoning 选择

- **上游参考**：桌面 subagent model catalog、provider route policy、dynamic reasoning discovery。
- **当前证据**：`JobTools.swift:523` 仅有 `prompt`、`label`、`model`、`provider_bundle`、`run_in_background`；缺 provider、reasoning_effort、`list_subagent_models` 和动态路由策略。
- **目标行为**：列出可用 provider/model/reasoning，按显式参数和默认策略路由；将选择写入 job/trajectory/replay metadata。
- **影响文件**：`Core/Tools/JobTools.swift`、`ModelProviderCatalog.swift`、AgentRuntime、设置 UI、tests。
- **步骤**：新增 schema 与 listing tool；实现 provider/model capability cache；校验 reasoning；保存并展示最终路由；补失效和 provider 错误。
- **完成条件**：用户可查询、选择、重放并审计子 Agent 的真实路由。

### PARITY-007 · Claude/Codex Hooks runner

- **上游参考**：`ClaudeCodeHookConfigParser`、`CodexHookConfigParser`、桌面 hook runner。
- **当前证据**：parser/protocol 存在，但没有 runner、命令执行器、生命周期触发器；`HookPoint` 仅用于解析。
- **目标行为**：加载配置、匹配 hook point、stdin/stdout JSON、超时、退出码、allow/deny/modify 决策和 Agent 生命周期接线。
- **影响文件**：`Core/Hooks`、AgentRuntime、process/iSH runner、diagnostic/UI、tests。
- **步骤**：实现配置加载和匹配；执行本机命令/脚本；定义超时、取消、输出上限和结果映射；接入 turn/tool/session 生命周期；补重启恢复。
- **完成条件**：fixture hook 可真实改变决策并记录轨迹；平台不支持项给明确 `IOS-REPLACEMENT`。

### PARITY-008 · Exa / Perplexity 搜索 Provider 生产化

- **上游参考**：桌面 search provider registry/settings。
- **当前证据**：provider 文件和单测存在；`AppModel+NativePluginLifecycle.swift:62` 只配置 `DeepSeekSearchProvider`。
- **目标行为**：Exa、Perplexity 可在设置中配置、存储 Keychain 引用、发现 capability、路由请求、处理限流/错误并回灌 citations。
- **影响文件**：provider 实现、`AppModel+NativePluginLifecycle.swift`、configuration/Keychain、settings UI、tool catalog、tests。
- **步骤**：注册 provider；加入配置迁移与凭据引用；接入搜索工具路由；补结果 schema/citation；用无密钥 fixture 和真实 API 分离验证。
- **完成条件**：生产目录可选择 provider；真实 key 未配置时明确可操作错误，不伪造成功。

### PARITY-009 · Agent team orchestration

- **上游参考**：桌面 agent-team runtime、member/task/message protocol。
- **当前证据**：`SessionEventTrajectory.swift:85` 只有 team 事件词汇；注释明确移动端没有 team orchestration。
- **目标行为**：team 创建、成员生命周期、任务分发、消息投递、取消、失败、汇总和轨迹/通知投影。
- **影响文件**：Agent runtime、Jobs、trajectory、subagent/ACP、UI、persistence、tests。
- **步骤**：先定义移动端可执行拓扑（本机 worker/ACP）；实现 team state machine 和 durable claims；接入 provider/model 选择；补并发、取消、恢复和 UI。
- **完成条件**：真实多成员 fixture 可运行并恢复；若受 iOS 资源限制，标注 `IOS-REPLACEMENT` 而非宣称机制相同。

### PARITY-010 · LocalStateServer 与 API gateway

- **上游参考**：桌面 `webserver`、session/settings/workspace controller、frontend-static、api-remotes。
- **当前证据**：`LocalStateServer.swift` 有 NWListener、`/health` 和注入式 GET endpoint；生产没有实例化，也不是完整 webserver/API gateway。
- **目标行为**：本机 server 启停、路由注册、session/settings/workspace controller、事件流和错误 schema；Web 前端仅在平台可承载时实现。
- **影响文件**：`Core/LocalServer/LocalStateServer.swift`、App lifecycle、session/settings/workspace controllers、tests、平台文档。
- **步骤**：明确 bind/lifecycle；注册只读和写入 controller；接入 auth/session identity；实现 SSE/WebSocket（若平台可行）；补并发、重启和端口冲突。
- **完成条件**：本机 API 可被 fixture 客户端调用；桌面 frontend-static/client connection 可由现有 WKWebView 承载，但 bundle 未接入时保持 `VERIFY`。

### PARITY-011 · `llm-pi-ai` 等价能力

- **上游参考**：最新上游 `llm-pi-ai` provider/model catalog、native protocol、OAuth、runtime reload、replay metadata、wire protocol。
- **当前证据**：`ModelProviderCatalog.swift` 支持 DeepSeek/OpenAI/Anthropic/OpenRouter/custom OpenAI-compatible；已接入 OpenAI/enriched 与 Anthropic 原生动态 listing、exact model identity resolution、description、逐模型 reasoning metadata（含上游 `reasoning_options` effort values、`limit` 与 `modalities` 嵌套字段）与持久 capability cache。2026-09-04 已新增 `ProviderOAuthCredential`、Keychain OAuth record、`ProviderOAuthRefreshCoordinator`、RFC 6749 form refresh client，补齐 OAuth-backed Profile 保存/删除、过期 grant 请求前自动刷新，并在 `SetupView` 提供手动 OAuth grant 录入（专项测试覆盖）；仍缺 provider-specific 浏览器/device-code 授权、401 自动重试和真实设备证据。
- **目标行为**：provider/model 动态发现、协议选择、授权生命周期、能力协商、运行时 reload、重放 metadata 和错误语义一致。
- **影响文件**：configuration/network/auth/settings/UI/AgentRuntime/tests。
- **步骤**：建立 provider plugin protocol；迁移静态 provider；实现 capability/cache；补 OAuth record/refresh（record、single-flight、RFC 6749 自动刷新已完成，待 provider-specific flow 与 401 retry）；统一 request/replay metadata；逐 provider fixture 对比上游。
- **完成条件**：支持列表中每个 provider 有协议、错误和重放证据；未支持项保持明确状态。

### PARITY-012 · e2b / fs-e2b / subprocess-e2b

- **上游参考**：上游 e2b、filesystem 和 subprocess packages。
- **当前证据**：移动端 package/生产目录没有等价实现；当前执行模型为 Swift 本地执行和 iSH/JS runtime。
- **目标行为**：先完成能力映射：文件、进程、代码执行、会话、结果回灌、取消和清理。
- **步骤**：对照上游 wire/API 写 compatibility fixture；实现本机 iSH replacement；如用户配置外部 E2B 服务，单独设计 provider adapter，不把它伪装成本机执行；补超时、资源和恢复。
- **状态规则**：远程 E2B executor 与当前产品边界冲突时 `OUT-OF-SCOPE`；本机语义替代可标 `IOS-REPLACEMENT`。
- **完成条件**：能力映射有测试和错误文案；不以“忽略安全”跳过平台/产品事实。

### PARITY-013 · webhook / webhook-github

- **上游参考**：webhook package、GitHub event/schema handlers。
- **当前证据**：移动端没有生产 webhook listener、签名/事件解析或 delivery state。
- **目标行为**：本机可启动 listener、解析标准事件、去重、重试、投影为 Agent/Job 触发；GitHub event fixture 与上游兼容。
- **步骤**：实现 listener lifecycle、事件 schema、delivery cursor、触发策略和 UI 状态；补本机网络可达性、后台限制和恢复测试。
- **状态规则**：公网 ingress、持续后台监听和服务器托管不属于 iOS 原生能力，标 `IOS-REPLACEMENT` 或 `OUT-OF-SCOPE`；仅本机可达 fixture 不得宣称公网可用。

### PARITY-014 · Web、发行形态和 Windows 专属能力

- **上游参考**：`web-app`、server/headless/sdk 发行包、Windows PowerShell/win32/ACL。
- **当前证据**：移动端为 SwiftUI + iSH；`HarnessBrowserWebKitBackend` 已有 WKWebView 容器，LocalStateServer 已提供 loopback server，但仍没有桌面 client bundle、独立 headless/sdk 发行形态或 Windows API。
- **目标行为**：建立逐项 capability matrix，能替代的提供原生 UI/本机 API，不能替代的给平台限制错误。
- **完成条件**：不把 Browser Client-half、React slot、`.node` addon、Swift/framework 下载执行、PowerShell/win32 宣称为移动端 `DONE`。

## 4. 依赖顺序与阶段门

| 阶段 | 项目 | 阶段门 |
|---|---|---|
| P0 | 本计划、基线和 remediation 模板 | 文档审阅、`git diff --check` |
| P1 | PARITY-001/002/003 | 请求、session log、telemetry 有生产接线和专项测试 |
| P2 | PARITY-004/006 | outline UI 与子 Agent 路由可查询、分页、重放 |
| P3 | PARITY-005/007/008 | ACP、hooks、搜索 provider 有真实生产注册 |
| P4 | PARITY-009/010 | team state machine、本机 API server 可用 |
| P5 | PARITY-011 | 动态多 provider catalog 和协议适配 |
| P6 | PARITY-012/013/014 | e2b/webhook/platform matrix 完成，冲突项诚实收口 |

## 5. 变更记录模板

每完成一项，在 `Docs/DESKTOP_PARITY_REMEDIATION.md` 增加：

```text
### PARITY-xxx · 标题（YYYY-MM-DD）
- 状态：TODO / VERIFY / IOS-REPLACEMENT / DONE / OUT-OF-SCOPE
- 上游证据：仓库、commit、package、入口
- 移动端变更：文件与生产注册点
- 测试命令与真实结果：保留失败原文摘要
- Simulator：构建/交互结果
- iPhone 16 Pro：安装/授权/真实 API/长会话结果；无证据写 VERIFY
- 剩余平台限制或后续动作：
```

## 6. 首轮执行清单

按 `P1 → P2 → P3 → P4 → P5 → P6` 顺序执行；每一项完成后立即运行对应专项测试和统一执行协议。任何失败都记录根因并修复，不通过放宽校验、吞异常或 mock 成功来“完成”。“全部完成”的最终含义是：所有可实现项达到 `DONE`，平台替代项达到 `IOS-REPLACEMENT`，不可实现项明确 `OUT-OF-SCOPE`，所有仍缺设备/API 证据的项保持 `VERIFY`。

## 7. 执行进度（2026-09-03）

| 项目 | 状态 | 本轮证据 |
|---|---|---|
| PARITY-001 请求扩展 | VERIFY | 生产 client 接线、顶层字段序列化、保留字段保护；29 项 DeepSeek wire tests 通过；全量 897 tests/5 skipped/0 failures；Simulator build 通过；真实 provider/插件注册待验证 |
| PARITY-002 session-log | VERIFY | 新增 `SessionLogDeliveryCoordinator`：durable watermark、`dsh_session_log` suffix body、accepted cursor 与重复抑制；专项测试通过；尚未接入 AppModel/真实 endpoint |
| PARITY-003 telemetry | VERIFY | `TelemetrySessionPersistence` 接入 AppModel append；5 项 telemetry tests 通过；全量 897 tests/5 skipped/0 failures；模式设置、feedback release、真机 OTLP 待验证 |
| PARITY-006 子 Agent reasoning | VERIFY | schema 与 LocalSubagentRequest 支持 reasoning_effort，并应用到 child configuration；新增 `list_subagent_models`；HarnessJobs 专项通过；provider listing/真实多 provider 仍待实现 |
| PARITY-007 hooks | VERIFY | `AgentRuntime` 已接入 SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop；AppModel 另在子 Agent activation 接入 Claude `SubagentStart/SubagentStop`，Start 可阻断、Stop 失败写诊断；全量 905 tests/5 skipped/0 failures，真机 iSH 命令执行仍待验证 |
| PARITY-004 turn outline UI | VERIFY | 全日志 outline 折叠接入 AppModel；Trajectory rail 支持预览、按 seq 分页加载和滚动定位；4 项 outline tests 通过；Simulator 被既有 Device-only tool audit 的 URLRequest 误报阻断，真机 UI 未验收 |
| PARITY-005 ACP transport | VERIFY | `ISHACPLineTransport` 复用 iSH transport，并新增 `ACPSubagentProviderDescriptor/Catalog`、自定义 command/args/env、`runAndWait`，且 `acp_provider` 已接入 `subagent`/Jobs；ACP/Jobs 专项通过；真实 iSH agent、持久化选择与真机仍待验证 |
| PARITY-008 Exa/Perplexity | VERIFY | AppModel 统一路由、Keychain origin 存取/删除、显式 provider 选择和 Settings UI 已接入；Exa 映射已按上游丢弃无 highlight 并取首个非空 highlight；Exa 3 tests 通过、Simulator build 通过；真实 API 与真机引用仍待验证 |
| PARITY-009 agent team | IOS-REPLACEMENT | 现有 workflow tool 提供本机编排、并行/流水线、成员生命周期与可恢复轨迹树；桌面后台 team daemon 机制不适用于 iOS，保留前台语义等价实现 |
| PARITY-010 LocalStateServer | VERIFY | AppModel 启动 loopback server 并注册 health/status/sessions；新增线程安全快照盒、真实 `LocalStateHTTPClient` GET 与发送完成后再 cancel 的连接修复；LocalStateServer 10 tests 通过；真机 HTTP 仍待验证 |
| PARITY-011/012/014 | VERIFY/TODO | PARITY-011 已实现动态 listing、exact resolution、capability cache、OAuth record 与 refresh single-flight；provider-specific OAuth UI/401 自动重试/真实设备仍 VERIFY；PARITY-012/014 仍按下方边界处理 |
| PARITY-013 webhook | VERIFY | GitHub delivery/event/payload envelope、loopback POST `/webhook/github`、有界去重及跨重启 delivery state 已实现；Settings 可配置/删除 Keychain secret，listener 支持运行时 secret 与真实 POST/HMAC；修复 AppModel sink 初始化时提前 claim delivery 的 bug，Job 投影路径已接通；11 个 LocalStateServer 测试通过；rule/重试/Agent 唤醒仍待实现 |

本表只记录可复核证据，不把“计划存在”或“源码类型存在”当作能力完成。

### 2026-09-04 增量：Anthropic extended thinking

1. 先完成 `ModelReasoningWireStyle` 与模型目录能力合并，区分 `effort` 和 `budget_tokens`。
2. 在 Anthropic request builder 发出 adaptive/effort、enabled/budget、disabled 三种原生字段组合。
3. 在 SSE decoder、AgentRuntime accumulator、持久化消息和多轮工具回放之间传递签名；缺签名历史只按文本回放。
4. 用 wire/stream/replay 专项测试锁定字段和事件顺序，再执行固定全量验收门。
5. 当前结果：Anthropic/model 专项 35 项通过，另有 TurnAccumulator 签名回归；完整 SwiftPM 934 项、5 skipped、0 failures；真实 API、OAuth、runtime reload、iSH/后台/真机仍为 VERIFY。
