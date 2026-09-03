# Harness Mobile × 最新 DeepSeek Harness Desktop：实测审计与逐项改造手册

更新时间：2026-09-04  
核对方式：本地源码/测试/构建 + GitHub API（`deepseek-ai/deepseek-harness` `master`）源码核对。文档不是能力证明；每项必须以命令和运行证据收口。

## 1. 可复核基线

| 项目 | 实测值 |
|---|---|
| 上游仓库 | `deepseek-ai/deepseek-harness` |
| 上游最新提交 | `76fda729799fe9b3848dbe2c211d4b231032b81e`（2026-09-03） |
| 上游 package 目录 | `acp`、`subagent`、`jobs`、`hooks`、`e2b`、`llm`、`webhook`、`web` 等均存在 |
| 移动端分支 | `codex/deepseek-parity` |
| 统一 SwiftPM 基线 | 以最近一次完整运行输出为准；不得用单测替代全量门 |
| 统一构建 | `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` + arm64 Simulator |

上游源码已直接核对：ACP 是 `initialize → session/new → session/prompt → session/update` 生命周期；Claude hooks 包含 `SubagentStart`/`SubagentStop`，Codex hooks 仍是五事件子集；jobs、webhook 和 e2b 都是独立 provider/service，而不是仅文档名。

## 2. 当前移动端事实

| ID | 当前状态 | 生产事实 | 必须继续做的事 |
|---|---|---|---|
| 001 | VERIFY | DeepSeek request extension 已接入请求序列化 | 真实 provider/插件注册、重试和回放 |
| 002 | VERIFY | session-log suffix/watermark coordinator 已有单测 | AppModel/真实 endpoint、断网重启 |
| 003 | VERIFY | append telemetry wrapper 已接线 | 设置、feedback release、真实 sink |
| 004 | VERIFY | turn outline 已接入轨迹 rail 与分页 | 长会话、冷启动、VoiceOver、真机 |
| 005 | VERIFY | ACP NDJSON iSH transport、可配置 provider catalog 与 `subagent`/Jobs 路径已接线 | 真实 ACP entrypoint、持久化 provider 选择、cancel/exit/reconnect |
| 006 | VERIFY | reasoning/provider 参数与 listing tool 已有 | 动态 capability、显式 provider、真实多 provider |
| 007 | VERIFY | Claude/Codex command hook runner 已接入；本批次补齐子 Agent生命周期事件 | 真机 iSH/ACP、超时/取消、诊断轨迹 |
| 008 | VERIFY | Exa/Perplexity provider 路由、Keychain origin、设置 UI 和删除/状态反馈已接线；Exa 映射与上游首个非空 highlight 语义一致 | 401/429/timeout、真实 citations、真机 Keychain/UI |
| 009 | IOS-REPLACEMENT | Workflow 提供本机 team 语义替代 | 多成员长时并发/恢复真机证据 |
| 010 | VERIFY | loopback `/health`、`/status`、`/sessions` 已启动并动态投影；`LocalStateHTTPClient` 已用真实 `URLSession` 验证 `/status` 与 `/sessions` GET | 端口冲突、生命周期、真机 |
| 011 | TODO | 静态 provider catalog；缺动态 catalog/OAuth/reload | 先建立 capability cache，再逐 provider 接入 |
| 012 | TODO | 无 e2b/fs/subprocess provider | 先写上游 REST compatibility fixture，再决定本机替代或显式远程适配 |
| 013 | VERIFY | GitHub envelope、loopback POST、持久去重、可选 HMAC、Settings secret 配置和 AppModel→本机 Job 投影已实现；修复 sink 初始化提前 claim 的问题 | rule/重试、可选 Agent 唤醒、后台/公网边界 |
| 014 | TODO | 无桌面浏览器/Windows 发行形态 | 形成 capability matrix，平台不适用项明确收口 |

## 3. 每个 ID 的执行模板

1. 用 `rg` 定位生产注册点、调用方和测试；再读上游对应 package 的 `src` 与 `tests`。
2. 先复用 `Vendor/`、`Dependencies/`、现有 Swift/iSH transport 和已有 fixture；不另造相同 runtime。
3. 只实现本 ID 的最小生产路径；schema、持久化、UI、轨迹和错误语义一起改，禁止只加类型不接线。
4. 添加一个能失败的专项测试，再运行全量 Swift、Host check、Node smoke、arm64 Simulator build。
5. 真实 API、iSH、后台、权限、插件、长会话和 iPhone 16 Pro 没有证据时，状态只能是 `VERIFY`；平台机制不同但语义覆盖时写 `IOS-REPLACEMENT`。
6. 运行 `./Scripts/audit-no-remote-execution.sh`、`./Scripts/check-upstream-parity.sh` 和 `git diff --check`，把真实输出摘要写回 `Docs/DESKTOP_PARITY_REMEDIATION.md`。

## 4. 逐项改造顺序

### P3：ACP、hooks、搜索 provider

- **005 ACP**：在 `ACPSubagentClient.swift` 保持协议层与 transport 分离；已增加 `ACPSubagentProviderDescriptor/Catalog`、自定义 command/args/env transport、可等待结果接口，并由 `subagent`/Jobs 的 `acp_provider` 参数调用；下一步为真实 iSH entrypoint、持久化 provider 选择和设备生命周期证据。上游 `subagent-acp/src/index.ts` 的 provider 不继承父上下文，移动端要在轨迹中保留 parent/child/run identity。
- **007 hooks**：Claude 配置可解析 `SubagentStart`/`SubagentStop`；在创建/结算子 Agent 的同一 activation 周期调用 runner。阻断 start 必须不启动 child；stop 失败只写诊断，不伪造 child 结果。
- **008 搜索**：设置页提供 provider 选择和 Keychain 引用；网络层保留 provider-specific 状态码/限流/超时；引用只接受 provider 返回的 URL/title/snippet，不能把错误响应渲染成 citation。

### P4：本机 server、webhook、team

- **010 LocalStateServer**：保留 loopback-only；已补 `LocalStateHTTPClient` 真实 URLSession GET，并修复发送完成前取消连接的生命周期 bug；继续补 controller JSON schema、端口冲突和 App 前后台启停测试。现有 WKWebView 可承载前端，但 `frontend-static` 桌面 bundle 尚未接入。
- **013 webhook**：按上游 `webhook` runtime 的 rule/dispatch 语义，把已验证 GitHub delivery 投影成 Agent/Job 请求；delivery ID 去重必须先于触发，失败可重试且不能重复确认。
- **009 team**：继续复用 `LocalWorkflowTool`/`WorkflowRunTree`；只有当有独立成员状态、durable claim 和恢复测试时才扩大实现。

### P5/P6：动态 provider、e2b、平台矩阵

- **011**：新增 provider capability snapshot/cache、协议选择和 runtime reload；每个 provider 用 wire fixture 对比上游，OAuth 只在平台能完成完整授权生命周期时注册。
- **012**：先核对 `packages/e2b/e2b/src/index.ts`、`fs-e2b`、`subprocess-e2b` 与公开 REST 契约；无真实契约不得猜 endpoint。不能提供同机制时实现本机 iSH 语义替代并标 `IOS-REPLACEMENT`，远程后端另行记录配置和数据披露。
- **014**：Browser/React client-half 已由现有 WKWebView 证明可承载，保留为待接入工程项；Windows PowerShell/win32/ACL 仍是平台不适用。原生 UI/API 替代与桌面同 runtime 必须分开记录。

## 5. 统一验收命令

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /tmp/hm-xcode-parity build
cd HarnessMobile/Resources/PluginHost && npm run check
node HarnessMobileTests/ISHPluginHostNodeSmoke.mjs HarnessMobile/Resources/PluginHost
cd /Users/liulingfei/Documents/ChatGPT/deepseek
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

## 6. 完成定义

“全部改完”不是把所有桌面包强行塞进 iOS，而是：可实现项有生产接线、自动化和运行证据；机制不同但用户语义覆盖的项标 `IOS-REPLACEMENT`；缺真实设备/API/系统能力的项保留 `VERIFY`；桌面浏览器、Windows 和不适用发行形态明确 `OUT-OF-SCOPE`。任何文档与源码冲突，以源码、测试和实际运行结果为准，并立即回写本手册和 remediation 日志。
