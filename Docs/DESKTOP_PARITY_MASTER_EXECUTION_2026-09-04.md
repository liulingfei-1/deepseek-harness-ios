# Harness Mobile × 最新 DeepSeek Harness Desktop：实测差异与逐项执行手册

更新时间：2026-09-04  
本地分支：`codex/deepseek-parity`  
上游基线：`deepseek-ai/deepseek-harness` master `76fda729799fe9b3848dbe2c211d4b231032b81e`

## 1. 证据规则

这份文档只记录可以复跑的事实，不把其他控制文档当成能力证明。每项差异必须同时核对：

1. 上游源码/测试（GitHub API 或锁定 commit）；
2. 本地生产注册点、调用方和测试；
3. 实际 SwiftPM、Xcode、Plugin Host、Node smoke 结果。

没有真实 API、iSH、后台或 iPhone 16 Pro 证据的项目只能写 `VERIFY`，不能写 `DONE`。平台机制不同但用户语义覆盖的项目写 `IOS-REPLACEMENT`；Windows 内核能力不在 iOS 可实现范围，写 `OUT-OF-SCOPE`。安全、凭据、路径和本机执行边界保留，不以“个人开发者”理由删除。

## 2. 已核对的上游事实

| 能力 | 上游源码事实 | 本地实测事实 | 状态 |
|---|---|---|---|
| ACP 子 Agent | `initialize → session/new → session/prompt → session/update`，支持取消和 transport 终止 | `ACPSubagentClient`、iSH NDJSON transport、取消/EOF 回归已接线 | `VERIFY` |
| Hooks | Claude 有 `SubagentStart/Stop`；Codex 为五事件子集 | Hook runner 与 child activation 已接线 | `VERIFY` |
| Web 搜索 | `web` seam 按配置或唯一可用 provider 选择，结果上限由 seam 执行 | Exa/Perplexity provider、设置和 citation 映射已接线 | `VERIFY` |
| Webhook | provider-neutral delivery，rule 只内建创建 Session | loopback POST、持久规则、claim/complete/requeue、可选唤醒已接线 | `VERIFY` |
| E2B | 官方 `e2b` SDK 的共享 Sandbox；`fs-e2b` 与 `subprocess-e2b` 复用同一 sandbox | 无官方 SDK/远端账号配置；iSH 仅能作语义替代 | `IOS-REPLACEMENT/VERIFY` |
| Credential records | `CredentialRecord = ApiKeyRecord | GrantRecord`；授权 flow 观察到 record commit 才算成功；刷新使用 read-modify-write | 本地已有 API-key/OAuth Keychain records、single-flight、RFC 6749 refresh client 与手动 grant 录入；缺 provider-specific 授权 flow/401 retry | `VERIFY` |
| Provider reload | 上游 route 可在设置变化后无重启生效；模型/凭据按请求解析 | 本地有 profile generation、模型 capability cache；缺 OAuth 生命周期闭环 | `VERIFY` |
| Local web UI | 桌面 web server/client-half 独立存在 | loopback API/WKWebView 可用，桌面 frontend bundle 尚未接入 | `VERIFY` |
| Windows host | PowerShell/win32/ACL 依赖 Windows 内核 | iOS 无等价内核能力 | `OUT-OF-SCOPE` |

## 3. 逐项执行顺序

按以下顺序逐项完成；每项完成后必须更新本文件、`Docs/DESKTOP_PARITY_REMEDIATION.md` 与 `Docs/DESKTOP_PARITY_IMPLEMENTATION_PLAN_2026-09-03.md`，并单独提交。

### P1：凭据记录与授权/刷新（PARITY-011）

- [x] 增加可持久化的 OAuth/grant record（access token、refresh token、过期时间、token type、scope）。
- [x] `CredentialStore` 提供 OAuth record 的 save/read/delete；旧 API-key schema 保持可读。
- [x] 实现每 profile refresh single-flight：并发 refresh 只执行一次，且 refresh 前重新读取 record。
- [x] access token 只在请求读取 seam 短暂返回；refresh metadata 不进入配置、轨迹、诊断或 UI 文本。
- [x] provider request credential lookup 可读取 OAuth access token；profile generation reload 复用既有路径。
- [x] 编辑 Profile 时允许已有 OAuth grant 作为凭据；删除 Profile 同时清理 API-key 与 OAuth record。
- [x] 设置页可手动录入 OAuth access/refresh token 与 ISO 8601 过期时间，并随 Profile 保存事务写入。
- [x] 设置页可选录入 HTTPS token endpoint 与 public client ID；过期 grant 在 provider request credential lookup 中按 RFC 6749 自动刷新并持久化轮换 token。
- [x] 添加纯 Swift 回归测试：编码 round-trip、过期判断、并发 refresh、旧 API-key 兼容。
- [ ] provider-specific OAuth authorization UI 和真实授权 flow。
- [x] 401 响应在存在 API-key resolver 时重新读取凭据；仅在 access token 实际轮换后对同一请求重试一次。
- [ ] 真实 OAuth/API/iSH/真机证据取得前保持 `VERIFY`。

### P2：Provider wire 与真实端点（PARITY-001/002/003/006/008）

- [ ] 为 DeepSeek、OpenAI、Anthropic、OpenRouter、Exa、Perplexity 保存锁定 wire fixtures。
- [x] Exa/Perplexity transport 用注入式 URLProtocol 验证 401/429/timeout 映射；DeepSeek/通用 provider 已有 401/403/413/429/5xx fixtures。
- [ ] 完成所有 provider 的断网恢复和重试回放，并以真实 endpoint 与 iPhone 16 Pro 运行证据将相应项改为 `DONE`。
- [ ] 真实 endpoint 与 iPhone 16 Pro 运行后再把相应项改为 `DONE`。

### P3：ACP/Hooks/后台（PARITY-004/005/007/013）

- [ ] 真实 iSH ACP 子进程、非零退出、重连和后台恢复。
- [ ] Claude/Codex hook 的超时、取消、诊断轨迹。
- [ ] webhook 公网 ingress/tunnel 仅作为部署项；本机规则、去重和 Job admission 保持 durable。

### P4：LocalStateServer 与前端（PARITY-010/014）

- [x] 增加 `/api` Connection RPC envelope（`client-request`/`server-response`、rpcId correlation、统一错误形状），接入 session mutation 与 settings/workspace 只读投影。
- [x] settings/workspace 的现有本机 mutation（provider remove、Host-backed settings mutate/update/replace、mount access/remove）与 `session/follow` 增量窗口 RPC。
- [x] session/workspace follow 的 SSE/chunked carrier 与 `URLSession` stream client；session 首帧 snapshot、后续事件 cursor 已有 live loopback 回归；workspace 首帧 baseline、后续 upsert/remove/order/archived 增量已有纯函数回归；客户端可选指数退避重连并续传 session cursor。
- [ ] 原生事件订阅（当前为 250ms persistence polling bridge）、客户端 generation/online-offline 状态、AbortSignal generation、WebSocket、端口冲突、前后台启停和 iPhone 16 Pro 证据。
- [x] 新增 `session/page` RPC：按 `throughSeq`/`beforeSeq`/`maxMessages` 做 message-aligned backwards pagination，复用 canonical trajectory 并输出 raw event records；专项 JSONL 回归通过。
- [x] 新增 `session/search` 与 `session/modelCatalog` RPC：复用本地 FTS/Profile 真源，输出有界去重 snippets、默认 provider/model、reasoning metadata；953 项 SwiftPM 与 arm64 Simulator 构建通过。
- [ ] 将上游 `frontend-static/client-half` 接入现有 WKWebView；UI 状态仍由本地 projection 提供。
- [x] loopback route 补齐上游静态宿主的 `HEAD` 请求语义（200 + 空 body），并加入路由回归。
- [ ] Windows PowerShell/win32/ACL 保持 `OUT-OF-SCOPE`，不得伪造 iOS 实现。

### P5：E2B（PARITY-012）

- [ ] 先锁定上游 SDK 版本和官方 REST/SDK 契约，再实现配置与错误映射。
- [ ] 没有真实 E2B 账号和 SDK 契约时不得猜 endpoint；iSH 语义替代保持显式标签。

## 4. 固定验收门

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

## 5. 当前批次记录

2026-09-04：已用 `agent-reach doctor --json`、`gh search code`、GitHub API 和本地源码/测试核对上游 authorization、credential record、E2B、webhook、ACP、client connection 入口；并将 upstream checkout/lock 对齐到 master `76fda729799fe9b3848dbe2c211d4b231032b81e`。当前批次完成 OAuth record + refresh single-flight、RFC 6749 自动刷新、401 token-rotation retry、OAuth-backed Profile 生命周期、手动 grant 录入、异步 Session controller RPC、provider/workspace mutation 和 `session/follow` 增量窗口 projection；真正 follow stream/SSE/WebSocket、provider-specific authorization UI、真实授权和设备/API 证据仍保持 `VERIFY`。

2026-09-04 Workspace registry：根据上游 `workspace-controller` 的 types/commands/feed 实现，本地新增可持久化 Workspace registry 及 `create|rename|delete|insertBefore|insertSessionBefore|archiveSession` RPC。创建同一路径幂等解析，删除保留目录与 Session；专项 `WorkspaceRegistryTests` 2/2 通过。随后补上 `session/follow`/`workspace/follow` 的 SSE/chunked carrier、snapshot-first 客户端和 session 增量事件回归，并将 workspace follow 投影为 baseline + upsert/remove/order/archived 增量；客户端可选指数退避重连并续传 session cursor。当前事件源仍是 250ms persistence polling bridge，客户端 generation 状态、AbortSignal generation 和真机生命周期仍未完全承载，继续标记 `VERIFY`。
