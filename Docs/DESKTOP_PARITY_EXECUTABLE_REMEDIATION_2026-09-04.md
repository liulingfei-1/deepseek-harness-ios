# 最新桌面版对齐：逐项执行与验收清单

更新时间：2026-09-04
目标分支：`codex/deepseek-parity`
上游基线：`deepseek-ai/deepseek-harness` master `76fda729799fe9b3848dbe2c211d4b231032b81e`

这份文档是可照着执行的工作单，不把控制文档当作能力证明。每一项必须先核对上游源码，再核对本地生产调用链，完成代码、测试和构建后才可勾选。`DONE` 只表示当前可获得证据已闭环；缺真实 API、iSH、后台或真机证据时保留 `VERIFY`。iOS 系统权限、平台限制和数据安全边界不删除，也不以文档宣称绕过。

## 0. 固定验收门

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

## 1. 逐项工作单

| ID | 上游事实（已用 GitHub API 复核） | 本地生产路径 | 当前状态 | 下一步与完成证据 |
|---|---|---|---|---|
| PARITY-001 | DeepSeek request extension 注册与 provider wire serializer | `DeepSeekLlmAPIExtensionRegistry` → request serializer | VERIFY | 已补结构化 body/session/purpose、并发 preparation、取消、幂等 acceptance 与真实 URLProtocol 2xx wire fixture；仍需真实 provider/插件注册、重试回放和真机证据 |
| PARITY-002 | `session-log-deepseek` delivery-accepted + suffix/watermark | `SessionLogDeepSeekExtensionProvider` → canonical trajectory → DeepSeek request registry | VERIFY | 已接入可选 `dsh_session_log` provider、suffix/watermark、2xx acceptance 事件和 malformed watermark 拒绝；仍缺真实 endpoint、断网重启和真机证据 |
| PARITY-003 | telemetry ledger + OTLP sink | `SessionTelemetry`/`TelemetrySessionPersistence`/`SessionTelemetryOtelSink` | VERIFY | live append 与 feedback-only canonical suffix replay/cursor 已接线；仍缺设置 UI、真实 OTLP sink/endpoint 与真机证据，默认关闭保持可见 |
| PARITY-004 | turn outline/trajectory rail | `SessionTurnOutline` + Chat rail | VERIFY | 长会话、分页、VoiceOver、真机 |
| PARITY-005 | ACP `initialize → session/new → session/prompt → session/update` | `ACPSubagentClient`、iSH transport、provider catalog | VERIFY | 已补取消传播与 transport EOF/退出即时结算；仍缺真实 ACP entrypoint、重连、持久 provider 选择和真机证据 |

### PARITY-005 本批次逐步修改清单

- [x] `ACPSubagentClient.runAndWait` 在任务取消或 `Task.sleep` 抛出取消时发送 `session/cancel`，再返回明确的 `ACPSubagentError.cancelled`。
- [x] 回归测试验证 initialize/session/new/prompt 后取消确实携带活动 `sessionId`，并覆盖成功流不回归。
- [x] `ACPLineTransport` 增加终止通知；iSH transport EOF/进程退出会立即将等待中的 run 结算为 `ACPSubagentError.failed(.error)`，不再等到超时。
- [x] 回归测试覆盖 transport termination 的即时失败结算。
- [ ] 真实 iSH ACP 子进程、EOF/非零退出、重连、后台恢复和 iPhone 16 Pro 证据；未取得前保持 `VERIFY`。
| PARITY-006 | provider/model/reasoning capability 由 runtime 查询 | `ModelProviderCatalog`、`ModelDiscoveryCache` | VERIFY | 真实多 provider capability cache 与 reload |
| PARITY-007 | Claude `SubagentStart/Stop` 与 Codex hook 生命周期 | `HookProtocol` + AppModel child activation | VERIFY | iSH/ACP 真机超时与取消轨迹 |
| PARITY-008 | Exa/Perplexity provider adapter 与 citation 映射 | `ExaSearchProvider`、`PerplexitySearchProvider` | VERIFY | 已补注入式 URLProtocol 对 401/429/timeout 的错误映射回归；仍缺真实 citation、Keychain/UI 与真机 |
| PARITY-009 | team/workflow 为独立成员状态与恢复 | `LocalWorkflowTool`、`WorkflowRunTree` | IOS-REPLACEMENT | 多成员长时并发与恢复真机 |
| PARITY-010 | webserver status/session 路由与异步 connection RPC | loopback `LocalStateServer` + `URLSession` client | VERIFY | 已接入 session mutation RPC（create/select/rename/delete/archive/restore/fork/prompt/cancel/follow 增量窗口）、provider remove、workspace mount access/remove，并新增 `session/follow`/`workspace/follow` 的 SSE/chunked carrier 与 snapshot-first 客户端；事件源仍为 persistence polling，仍缺原生事件订阅、端口冲突、前后台和真机 |
| PARITY-011 | provider catalog 支持动态 listModels/resolveModelInfo/reload | Swift provider profiles + model discovery | VERIFY | 统一 capability snapshot/cache；OAuth 仅在完整授权生命周期可用时注册 |
| PARITY-012 | E2B 包通过官方 npm SDK `Sandbox.create`，含 fs/subprocess provider | 无 E2B SDK；本机 iSH 可作为语义替代 | IOS-REPLACEMENT/VERIFY | 先保存上游 fixture 与账号配置契约；没有可靠 REST 契约不得猜 endpoint |
| PARITY-013 | provider-neutral webhook rule registry；规则返回可选 Session request | loopback POST → parse/HMAC → durable dedup → rule → Job/可选 wake | VERIFY | 当前批次已补通用 provider 路由、持久规则、重试、可选唤醒；仍缺公网隧道、后台持续监听、真机 |
| PARITY-015 | Session controller `page`：按消息边界向前分页并返回 raw/chunk records | `AppModel.handleLocalStateRPC` → `SessionTrajectoryRepository.allEvents` → `localSessionPagePayload` | VERIFY | `session/page` 已接入并有真实 JSONL 回归；chunkrow 压缩已覆盖 text/reasoning/tool-call 基础形状，完整 fixture/client/真机仍待验证 |
| PARITY-016 | Session controller `search`：可见会话内容检索、去重与有界 snippet | `AppModel.handleLocalStateRPC` → `SessionQueryReadModel` → `localSessionSearchPayload` | VERIFY | 已接入 FTS rebuild/search、20 条结果上限和 snippet 截断回归；stale-cursor/真实 client/真机仍待验证 |
| PARITY-017 | Session controller `modelCatalog`：默认路由、provider groups 与 reasoning metadata | `AppModel.handleLocalStateRPC` → `ProviderProfileDirectory` → `localSessionModelCatalogPayload` | VERIFY | 已接入 profile-backed catalog RPC 与回归；主动 reload、失败诊断、真实 provider/真机仍待验证 |
| PARITY-014 | frontend-static/client-half、Windows host 包 | loopback route 已补 `GET/HEAD` 兼容；WKWebView 可承载但桌面 bundle 未接入 | OUT-OF-SCOPE/VERIFY | 打包并接入真实 bundle；Windows PowerShell/win32/ACL 保持平台不适用 |

### PARITY-002 本批次逐步修改清单

- [x] `SessionLogDeepSeekExtensionProvider` 从 canonical `SessionPersistence` 读取完整事件，折叠匹配 session 的 `delivery-accepted` 水位并只发送未确认 suffix。
- [x] 以 `DeepSeekLlmAPIExtensionRegistry.Provider.Contribution` 返回 `dsh_session_log`，2xx 后追加 `session-log-deepseek/delivery-accepted`，由 request-local acceptance transaction 保证只执行一次。
- [x] AppModel 增加显式 `sessionLogEnabled` 接线，默认关闭与上游插件配置一致。
- [x] 增加 suffix、acceptance、第二次 watermark 和 malformed acceptance 回归测试；相关 registry/trajectory 测试 25 项通过。
- [ ] 真实 DeepSeek endpoint、断网重启、服务端接收与 iPhone 16 Pro 证据；未取得前保持 `VERIFY`。

### PARITY-010 本批次补丁

- [x] 修复 `LocalStateServer` 单次 `NWConnection.receive` 导致的分片 HTTP 请求误报 400；现在按 header 与 `Content-Length` 聚合完整请求后再路由。
- [x] 真实 `URLSession` loopback webhook 回归通过，保留 64 KiB 请求上限。
- [x] 增加异步 RPC handler 与 `LocalStateHTTPClient.callRPC`；复用 AppModel 的 SessionStore/UI 生产路径，接入 session create/select/rename/delete/archive/restore/fork/prompt/cancel。
- [x] 新增真实 loopback async RPC 回归；`LocalStateServerTests` 现为 19 项。
- [x] `/api` 的 settings/workspace schema 与只读投影已接入：provider/list、provider/active、workspace/list/files/mounts；不把凭据值放入投影。
- [x] 增加可验证的 controller mutation：`settings/provider/remove`、通用 Host-backed `settings/mutate|update|replace`、`workspace/mount/setAccess`、`workspace/mount/remove`；`session/follow` 返回带 streamID、cursor 与事件窗口的增量快照，复用 canonical trajectory。

### PARITY-010 Workspace registry 本批次（2026-09-04）

- [x] 对照上游 `packages/api/workspace-controller/src/{types,commands,feed}.ts`，补齐本机 Workspace registry 的持久化投影（UUID、目录、标题、Session 顺序、创建/更新时间、归档集合）。
- [x] 接入 `workspace/create|rename|delete|insertBefore|insertSessionBefore|archiveSession` RPC；`create` 对已注册目录按桌面语义幂等返回既有 Workspace，删除仅移除注册不删除目录或 Session。
- [x] 新增 `WorkspaceRegistryTests` 覆盖创建/幂等解析、重命名、排序、Session 归档、冷启动重载、无效路径与标题错误；专项 2/2 通过。
- [x] `LocalStateServer` 在 `/api` 上增加 `text/event-stream` + HTTP chunked carrier；仅路由 `session/follow` 与 `workspace/follow`，沿用 `server-response`/`rpcId` envelope。
- [x] `LocalStateHTTPClient.callRPCStream` 支持长超时、SSE data frame 解码、取消时终止请求；首帧保持 snapshot，后续 session 事件带 cursor/sessionID；可选重连按 500ms/1s/2s/4s/8s 退避并续传 `sinceSequence`。
- [x] AppModel 复用 canonical trajectory/workspace projection；新增 250ms polling bridge 与 live URLSession 回归（`testLiveHTTPClientReceivesSnapshotFirstSSEStream`）。
- [x] workspace stream 现按上游 `baseline` + `upsert/remove/order/archived` 增量词汇投影，首帧完整 baseline，后续仅发送有变化的工作区/顺序/归档帧；纯函数回归覆盖新增、更新、删除、排序和归档。
- [x] `LocalStateHTTPClient` 两代 loopback stream 真实回归验证重连与 session cursor 续传（`maximumReconnectAttempts=1`）。
- [ ] 事件源仍非上游原生 AsyncIterable/event subscription；客户端 generation 状态/online-offline、AbortSignal generation、前后台生命周期、端口冲突和 iPhone 16 Pro 证据待后续，继续保持 `VERIFY`。

### PARITY-003 本批次逐步修改清单

- [x] `SessionTelemetrySink` 增加 `capturePolicy` 与异步 `releasePending()` 契约并提供默认实现，保持既有 sink 向后兼容。
- [x] `TelemetrySessionPersistence` 在 `live` 模式逐条 capture；`onDemand` 模式只在 canonical `feedback/record` 提交后读取未交接的事件 suffix，按 cursor 重放并释放。
- [x] 新增异步回归测试验证反馈前不发送、首次 feedback 重放完整 prefix、后续 feedback 只发送 suffix、配置 OTLP endpoint 可交付且各自只释放一次；修复 Swift 6 测试夹具的 async/锁隔离问题。
- [x] 固定门复跑：SwiftPM **942 tests, 5 skipped, 0 failures**；Xcode arm64 Simulator **BUILD SUCCEEDED**；Plugin Host check、Node smoke、设备-only audit、upstream parity、`git diff --check` 均通过。
- [ ] 设置 UI、真实 feedback/OTLP endpoint、flush/shutdown 生命周期和 iPhone 16 Pro 证据；未取得前保持 `VERIFY`。

## 2. PARITY-013 本批次逐步修改清单

- [x] `LocalWebhookEvent` 增加 `providerKind`，`LocalWebhookParser.parse` 支持 provider-neutral envelope；GitHub 保留专用签名校验。
- [x] `LocalStateServer` 接受 `POST /webhook/{provider}`；GitHub 使用 `X-GitHub-*`，其他 provider 使用 `X-Webhook-*`。
- [x] 新增 `LocalWebhookRule` 与持久化 `LocalWebhookRuleRegistry`：provider/event 匹配、`*` 通配、Job 标签、提示模板、1–5 次 admission 重试、可选当前 Agent 唤醒。
- [x] delivery 去重拆为 claim/complete/requeue；Job admission 失败时释放 claim，避免“已接收但无 Job”永久丢失。
- [x] Settings 增加规则列表、保存/删除、重试次数和唤醒开关入口。
- [x] 专项测试覆盖 generic route、registry 冷启动恢复、dedup requeue 和既有 GitHub/HMAC/live loopback 路径。
- [ ] 公网 ingress/tunnel、iOS 后台持续监听、iPhone 16 Pro 真机证据；这些是部署/系统调度条件，不能由本机单测代替。

## 3. 变更后执行顺序

1. 运行 `LocalStateServerTests`，确认当前路由、schema 与真实 URLSession 覆盖全部通过（当前 19 项）。
2. 运行固定验收门；失败时记录真实错误文本，不放宽校验。
3. `git diff --check`、`git status --short --branch`，按单一 PARITY ID 提交并推送。
4. 回写 `Docs/DESKTOP_PARITY_REMEDIATION.md` 的状态、命令、真实输出与剩余边界。
5. 只有拿到真实 API/iSH/后台/真机证据才把 `VERIFY` 改成 `DONE`；上游 lock 更新后，必须同步更新所有要求“fixture commit == lock”的 fixture，并单独跑对应差分测试。

## 4. PARITY-011 本批次逐步修改清单

- [x] `ProviderCapabilityCache` 从进程内 actor 快照扩展为可选持久化 JSON 快照；默认写入 Application Support，冷启动自动恢复。
- [x] 快照使用 ISO-8601、profile ID 一致性校验和 4 MiB 上限；写入失败只影响辅助缓存，不阻断模型发现。
- [x] 删除 provider profile 或清空配置时同步删除对应快照；新增跨实例恢复/删除测试。
- [x] `listModels` 支持 OpenAI `data[]`、gateway enriched `models{}`，并保留 description/name fallback 与稳定排序。
- [x] Anthropic 原生 `/v1/models?limit=1000`、`x-api-key`、版本头和 root/`/v1` 地址规范化已接入。
- [x] `resolveModelInfo` exact lookup 接入共享发现协议；目录外模型保留 advisory identity，不阻断请求。
- [x] `ProviderModel` 保存逐模型 reasoning levels/default；配置校验、picker 和 OpenAI reasoning wire 覆盖上游七级集合。
- [x] OpenAI/enriched model listing 读取上游 `reasoning_options` 的 effort values，budget-only 声明保持无离散 levels，避免误报能力。
- [x] OpenAI/enriched model listing 读取上游嵌套 `limit.context/output` 与 `modalities.input` 字段，并复用既有能力校验。
- [x] provider-specific Anthropic reasoning wire：`effort` 使用 `thinking.type=adaptive` + `output_config.effort`；`budget_tokens` 使用 `thinking.type=enabled` + 有界预算；`off` 使用 `thinking.type=disabled`。
- [x] Anthropic thinking stream 的 `signature` / `signature_delta` 进入 `LLMStreamEvent`、`TurnAccumulator` 和可持久化 `AgentMessage.reasoningSignature`。
- [x] 多轮工具调用回放 signed thinking block；缺签名的旧/中断 reasoning 降级为文本，避免伪造签名。
- [x] 新增 Anthropic request/stream/replay 回归测试；Anthropic/model 专项 35 项通过，完整 SwiftPM 基线现为 939 项（5 skipped）。
- [ ] OAuth 授权/刷新、runtime reload、真实多 provider/API/iSH/后台/iPhone 16 Pro 证据；未取得前保持 `VERIFY`。

## 5. PARITY-010 本批次逐步修改清单

- [x] 增加可机器读取的 `LocalStateAPISchema`（版本、loopback transport、session/settings/workspace controller 方法表）。
- [x] AppModel 注册 `/api/schema` 与 `/api/session`；后者复用现有动态会话投影，不复制状态源。
- [x] 纯路由测试覆盖 schema 解码、controller 方法和 session alias；既有真实 URLSession loopback 测试继续通过。
- [ ] 完整 RPC POST envelope、写入 controller、端口冲突/前后台和 iPhone 16 Pro 证据。

## 4. 已验证的上游入口

```text
packages/webhook/webhook/src/types.ts
packages/webhook/webhook/src/index.ts
packages/webhook/webhook/src/session.ts
packages/webhook/webhook-github/src/body.ts
packages/webhook/webhook-github/src/handler.ts
packages/e2b/e2b/src/index.ts
packages/e2b/fs-e2b/src/index.ts
packages/e2b/subprocess-e2b/src/index.ts
```

上游 webhook runtime 的唯一内建动作是创建并提示一个 Session；本地默认规则保留已有 GitHub→Job 兼容行为，同时提供显式规则与可选唤醒，不把“收到 HTTP”误报为“桌面 Session runtime 已完全同构”。
