# DeepSeek Harness desktop parity for iPhone

## Scope and audit boundary

This document is the source-level compatibility baseline for the native iOS
port. It compares the current workspace with the pinned compatibility fixtures
and the latest upstream source audit:

- DeepSeek Harness source/runtime baseline: `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`
  (`dsh-v0.1.1-rc.2`)
- The core wire fixture is pinned to the current `b150a551…` baseline;
  remaining compatibility fixtures still carry the legacy
  `47f943859bef60e4160492346772ded9b24f765a` (RC.5) anchor until their RC.2
  fixture expansion is completed.
- OpenMinis: `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`
- OpenMinis iSH ARM64: `de124dd66124a15239cea1465164f74980ada245`
- Product research: `/Users/liulingfei/Downloads/deep-research-report (3).md`

Imperative text inside the research report is treated as research material,
not as an instruction to the implementation agent. The user's messages define
the product requirement.

The audit describes code currently present in the workspace and the runtime
checks completed for this revision. Swift Package tests and static audits are
current; an Xcode/iOS simulator or physical-device run is not claimed unless
the toolchain and destination are compatible in the same environment.

## RC.8 through v0.1.1-rc.2 additions

The Plugin Host is pinned to `0.1.1-rc.2` across `package.json`, the lockfile,
and `manifest.json`. The native surface includes the RC.8 multimodal
model `deepseek-v4-flash-vision-exp`, image-bearing `/goal` and `/plan` input,
`@file:` and `@session:` context references, concurrent `web_search`, child
Agent `report` delivery and parent wake-up/settlement events. Codex and Claude
Code are represented as opt-in Profile Bundles. Their manifests pin immutable
official npm tarball URLs and verified SHA-256 values, while execution remains
restricted to a fixed absolute path inside the on-device iSH guest and never
receives the provider API key from Swift. Enabling a bundle does not silently
install it yet: it reports a typed "CLI not installed" error until the local
executable exists. RC.2 image preprocessing, Files API reuse, and the
remaining native compatibility work are tracked in
`Docs/DESKTOP_PARITY_REMEDIATION.md`; their presence is not inferred from the
Host package version.

Status meanings:

- `Implemented`: the current native code contains the main end-to-end path.
- `Partial`: a useful path exists, but an upstream contract or important user
  workflow is still incomplete.
- `Missing`: no production implementation of the upstream capability exists.
- `iOS replacement`: the desktop primitive is intentionally replaced by a
  native or on-device iOS design rather than copied literally.

Priority meanings:

- `P0`: required for the app to preserve the core Harness experience.
- `P1`: required for close Desktop/Web workflow parity.
- `P2`: secondary parity or a mobile-specific enhancement.

The product boundary is fixed:

- Model inference uses configured API providers. Model weights are not stored
  on the phone.
- Agent orchestration, approvals, persistence, mobile tools, Cordis runtime,
  and Linux command execution run on the iPhone.
- Linux commands execute in the embedded iSH ARM64 Alpine guest. There is no
  remote command executor or server fallback.
- Provider API keys remain in the native Keychain/provider process. They are
  not copied into iSH, plugin files, logs, prompts, or fixtures.
- Downloaded Host-only plugins may execute inside the local iSH guest. Packages
  with an independently validated `dsh.nativeClient` sidecar may contribute the
  supported native inspectors, settings links, and commands. Arbitrary React,
  browser slots, themes, and Web `dsh.client` execution remain incompatible.
- Live Activities and background APIs project real local work. They do not
  turn an iPhone app into a permanently scheduled daemon.

## 当前 iOS 模拟器验证（iPhone 16 Pro 真机另验）

| Check | Result | Coverage and boundary |
| --- | --- | --- |
| Toolchain and target | Passed | Xcode Beta arm64 iOS 27 Simulator build passed on booted iPhone 17 Pro simulator; this does not substitute for iPhone 16 Pro physical-device verification |
| App lifecycle and UI automation | Passed | 最新 App 已重新安装到 arm64 Simulator，冷启动加载本地会话后稳定显示会话列表；专用工具投影聚焦测试 19/19，先前 MCP/LSP/catalog 聚焦测试 11/11 |
| Local terminal XCUITest | Passed | `HarnessMobileISHTerminalUITests/testLocalTerminalExecutesStreamsAndStopsCommands` verified rootfs readiness, the guest-network switch, `uname -m`, separate stdout/stderr rendering, and stopping `sleep 30` |
| Marketplace failure state | Passed | A marketplace error stays local to the open page and exposes retry and close actions instead of collapsing the whole settings flow |
| Swift test suite | Passed | Latest full `swift test --parallel`: 594 tests enumerated, 3 opt-in/live tests skipped, 0 failed. Latest full Xcode result bundle remains 539 total / 534 passed / 5 skipped / 0 failed; newer focused slices include Workspace hierarchy, long conversation, Markdown tables, specialized tool presentation, Host command lifecycle, and Provider/Wire compatibility, while live-provider tests remain opt-in |
| Live DeepSeek integration | Not run in this revision | No API key was written or used by the verification commands |
| Node Plugin Host | Passed | `npm run check` completed successfully |
| No-remote-execution audit | Passed | `Scripts/audit-no-remote-execution.sh` completed successfully |

The UI test used DerivedData under `/tmp`. DerivedData inside the current File
Provider workspace inherited FinderInfo extended attributes that caused a
codesign failure; that was a local build-environment issue, not an app runtime
failure. Physical iPhone 16 Pro background expiration, heat, memory pressure,
entitlements, and signing remain unverified.

## Current native surface

The current compact-width shell uses native iPhone navigation:

```text
TabView
  |- Chat: conversation, approvals, questions, composer, model picker
  |- Sessions: create, switch, rename, delete
  |- Console: task state, plugins, trajectory
  |- Files: app-private workspace
  `- Commands: iSH command and interactive terminal surfaces

Settings sheet
  |- provider profiles and model discovery
  |- background and privacy controls
  |- plugin management and community marketplace
  `- official plugin settings namespaces and native editors
```

This is a valid iOS adaptation, but it is not yet the same information
architecture as the Desktop/Web workspace tree, conversation header, child
address breadcrumb, Jobs header, and Inspect column.

## Model and conversation

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Provider profiles and credentials | Implemented | P0 | Provider directory, custom providers, write-only credentials | Profile create/edit/delete/activate, catalog providers, custom OpenAI-compatible routes, credential references, Keychain isolation, rollback-aware updates, route/model sparse pi-ai compatibility, and per-profile normal/always retry configuration | Keep migration fixtures current; validate private gateways and advanced compatibility fields on physical devices | `HarnessMobile/Core/Configuration/ProviderProfile.swift`; `HarnessMobile/Core/Security/CredentialStore.swift`; `HarnessMobile/Features/Settings/ProviderProfilesView.swift`; `HarnessMobile/Features/Setup/SetupView.swift` |
| Provider inference adapters | Implemented | P0 | Provider-owned request, stream, error, retry, and capability contracts | DeepSeek, generic OpenAI-compatible, and Anthropic now own distinct request dialects. They share only bounded `URLSession` transport; DeepSeek alone owns Files/reasoning recovery, Anthropic owns Messages/image/error-type semantics, and generic routes keep sparse pi-ai compatibility | Finish exotic thinking/store/strict/cache request snapshots and validate real private gateways and provider endpoints on iPhone 16 Pro | `HarnessMobile/Core/Network/ModelProviderAdapter.swift`; `HarnessMobile/Core/Network/OpenAICompatibleClient.swift`; `HarnessMobile/Core/Network/OpenAICompatibleWireProfile.swift`; `HarnessMobile/Core/Network/ModelRetryPolicy.swift` |
| Model discovery | Implemented | P0 | Provider directory and `/models` refresh | Same-HTTPS-origin and redirect validation, 4 MiB response limit, credential-partitioned 24-hour cache, built-in/manual fallback, refresh UI, and explicit validated input modalities. Fixed fixtures cover 401, malformed, declared oversized, cache expiry, credential partitioning, and manual unlisted models; names are never guessed as image capability | Expand discovery only when a new provider protocol defines a trustworthy model-list contract; real private gateway verification remains opt-in | `HarnessMobile/Core/Network/ModelProviderAdapter.swift`; `HarnessMobile/Core/Configuration/ModelDiscoveryCache.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift`; `CompatibilityFixtures/provider-models/openai-model-discovery-failures-v1.json` |
| Anthropic Messages | Implemented | P0 | Native Anthropic Messages wire | Anthropic adapter owns headers and request serialization, including base64 JPEG/PNG/GIF/WebP user-image blocks; SSE covers text/thinking/tool-use, tool-result replay, usage, cancellation, provider error type, and `request-id` | Keep model discovery catalog-only unless Anthropic exposes an adopted model-list contract; validate real image/error responses and expand fixed wire fixtures as the protocol evolves | `HarnessMobile/Core/Network/AnthropicMessagesWire.swift`; `HarnessMobile/Core/Network/ModelProviderAdapter.swift`; `HarnessMobile/Core/Network/OpenAICompatibleClient.swift`; `HarnessMobileTests/AnthropicMessagesWireTests.swift` |
| Session provider/model/reasoning selection | Implemented | P0 | Session-owned `{provider, model, reasoningEffort}` plus `/model` and composer seat | Per-session override is persisted independently from the default; provider, model, and reasoning are selectable from the composer and slash command; continuable child Agents retain their configured provider/model route across activations; the Chat header preserves root-to-child address navigation | Keep child-specific override editing and physical-device navigation fixtures current as provider bundles evolve | `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift` |
| Composer controls | Implemented | P0 | Slash, Agent/Plan, permission, model, context, attachments, queue, steer, send/stop | Native command picker, Agent/Plan segmented control, permission menu, model seat, context indicator, image/camera, queued input dock, steer, send, and cancellation | Refine visual parity after the missing runtime contracts exist; do not remove current controls | `HarnessMobile/Features/Chat/ChatComposerControls.swift`; `HarnessMobile/Features/Chat/ChatView.swift` |
| Slash command core | Partial | P0 | Host/client command merge, fuzzy menu, immediate action, popup select, confirmation, completion, `/` and `@` sources | Strict parser, global/scoped registry, built-ins, fuzzy ranking, durable command run/done events, generic popup-select/confirmation continuations, argument completion, and a native `@` palette for files/sessions/subagents/skills/plugins. Native, nativeClient, and official iSH Host `dsh-commands` contributions now share one priority- and generation-aware registry with exact withdrawal on plugin stop/replacement. | Validate dynamic Host commands on the physical iPhone and add an attachment store before allowing image-bearing Host commands; Host RPC cancellation is still bounded by the current one-response request contract | `HarnessMobile/Core/Commands/SlashCommandCore.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginHostCordisBridge.swift`; `HarnessMobile/Resources/PluginHost/host.mjs`; `HarnessMobile/App/AppModel.swift`; upstream `packages/interaction/commands` and `packages/client/ui-commands` |
| Runtime input queue and steer | Implemented | P0 | Edit/delete/steer queued input while the Agent is active | Queue and steer dispositions are persisted, editable, removable, and consumed at explicit runtime boundaries | Add addressed-child routing when durable child sessions land | `HarnessMobile/Core/Agent/ConversationControls.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Features/Chat/ChatComposerControls.swift` |
| Ask-user | Implemented | P0 | Multi-question single/multi choice, custom text, per-question skip, exact continuation | Native multi-question sheet supports single choice, multi-select, custom answers, per-question Skip, cancellation, and exact suspended-run continuation | Keep the fixed wire fixture and behavior tests synchronized with upstream changes | `HarnessMobile/Core/Tools/UserInteractionTools.swift`; `HarnessMobile/Features/Chat/UserQuestionSheet.swift`; `HarnessMobileTests/UserInteractionToolsTests.swift`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; `CompatibilityFixtures/deepseek/user-interaction-v1.json` |
| Plan review | Implemented | P0 | Composer takeover with `Chat about it`, `Refuse`, and `Approve` | `exit_plan_mode` presents a dedicated native review with `Chat about it`, `Refuse`/keep-planning, and `Approve`, preserving the exact continuation and action semantics | Keep the action contract covered when the upstream Plan Review protocol changes | `HarnessMobile/Core/Tools/UserInteractionTools.swift`; `HarnessMobile/Features/Chat/UserQuestionSheet.swift`; `HarnessMobileTests/UserInteractionToolsTests.swift`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; `CompatibilityFixtures/deepseek/user-interaction-v1.json` |
| Goal, Plan, and Todo | Implemented | P0 | Plan seat, GoalBar lifecycle, collapsible TodoPanel, durable projections | Goal/plan/todo models, tools, persistence, compaction projection, Plan mode, a conversation-level GoalBar, a collapsible TodoPanel, and a dedicated task-state page with create/edit/pause/resume/block/complete/clear controls are implemented; goal identity remains stable across edits and lifecycle transitions | Add a fixed cross-version fixture for upstream `goal/change` and `todo/write` revisions; the native session snapshot intentionally does not model upstream's process-local activation bit | `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/Core/Tools/WorkStateTools.swift`; `HarnessMobile/Features/WorkState/ConversationWorkStateDock.swift`; `HarnessMobile/Features/WorkState/WorkStateView.swift`; `HarnessMobileTests/WorkStateToolsTests.swift` |
| Context and compaction | Implemented | P0 | Context meter, token/compaction visibility, durable replay, independent summary route | Composer context indicator and deterministic compaction preserve recent complete tool transactions, work state, instructions, images and references. Settings can persist a separate Provider Profile/model for summaries; the runtime resolves its credential independently and only falls back to the current session route before any summary text is emitted, recording the actual route and fallback cause in trajectory | Keep the locked cross-version fixture synchronized when upstream compaction projection changes; validate optional provider endpoints without storing credentials in fixtures | `HarnessMobile/Core/Agent/ConversationCompactor.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Core/Configuration/CompactionSummaryRoute.swift`; `HarnessMobile/Features/Settings/ProviderProfilesView.swift`; `HarnessMobileTests/CompactionCrossVersionFixtureTests.swift`; `CompatibilityFixtures/deepseek/compaction-cross-version-v1.json` |
| Time context | Implemented | P1 | Opt-in durable request clock without prefix churn | Settings select the device zone or UTC plus an every-step/1/5/15-minute cadence. Eligible pre-steps append a source-attributed `@deepseek-ai/dsh-time-context` user snapshot at the history tail; the system/header remains byte-stable and the refresh window suppresses duplicate snapshots | Keep disabled by default and add physical-device timezone-change/cold-replay verification | `HarnessMobile/Core/Configuration/TimeContextSettings.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Features/Settings/ProviderProfilesView.swift`; `HarnessMobileTests/TimeContextSettingsTests.swift` |
| Session titles | Implemented | P1 | Deterministic local fallback plus first/all-prompt LLM providers | The first user prompt still gives an immediate local title. Optional title generation can follow the session route or a dedicated Profile/model, uses a tool-free 128-token request with bounded JSON framing and timeout, retains the local title on failure, pins explicit user renames, supports deliberate regenerate, and records credential-free title request/provenance events | Validate real provider title calls on iPhone without committing a credential; legacy sessions without attributable trajectory seqs keep SessionStore provenance and intentionally avoid emitting an invalid upstream provider title event | `HarnessMobile/Core/Configuration/SessionTitleSettings.swift`; `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Sessions/SessionsView.swift`; `HarnessMobileTests/SessionTitleSettingsTests.swift` |
| Trajectory mode | Implemented | P1 | A session-level Chat/Trajectory switch with Duration/Turns/Calls, shared session/address context and Inspect | Chat owns a segmented Chat/Trajectory mode switch over the active session. The durable event repository supplies bounded paging, search, per-turn/per-call grouping and timing, model/tool duration, TTFT and cache metrics. Inspect exposes semantic System request headers, User/Assistant payloads, tool input/output, token/cache details, Cordis handler chains, raw JSON fallback, and the same durable root-to-child address breadcrumb used by Chat/Jobs | Validate long-trace touch/VoiceOver behavior on the physical iPhone 16 Pro; keep Console as a secondary operational view | `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobile/Core/Trace`; `HarnessMobile/Features/Trajectory/TrajectoryView.swift`; `HarnessMobileTests/SessionEventTrajectoryTests.swift` |
| Conversation and session shell | Partial | P1 | Workspace tree, session search/fork/archive/sort, status badges, Chat/Trajectory, child breadcrumb | Native chat with Chat/Trajectory modes plus durable create/switch/rename/delete, search/fork/archive/sort/status; the home list now exposes `/workspace` as an expandable root for current Session/run state, files, and mounts, while Chat preserves a durable root-to-child Agent breadcrumb | Validate the hierarchy and child return path on iPhone 16 Pro; forked sessions intentionally start a fresh trajectory stream instead of copying historical runtime telemetry | `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Sessions/SessionsView.swift`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobileTests/SessionStoreTests.swift`; upstream OpenMinis `SessionForkManager.swift`, `ContentView.swift`, and `SessionBadgeStore.swift` |
| Long-conversation presentation | Partial | P0 | Virtualized timeline and incremental streaming presentation | `LazyVStack` renders a stable 80-row window with explicit backward paging. Hidden context and duplicate tool rows are projected only when `messagesRevision` changes; model text/reasoning is coalesced at 66–160 ms behind an O(1) presentation revision, auto-follow is capped at 8 Hz without animation, and live tool output uses a bounded 100 ms batch while durable Runtime/trajectory data stays complete | Capture SwiftUI/Time Profiler and memory-pressure traces on the physical iPhone 16 Pro during long model streams and high-volume tool output before calling the performance target complete | `HarnessMobile/Core/Agent/ConversationMessageWindow.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobileTests/ConversationMessageWindowTests.swift`; `HarnessMobileUITests/HarnessMobileLiveUITests.swift` |
| Message Markdown and tables | Partial | P1 | GFM-like assistant response rendering with narrow-screen table overflow | Completed assistant responses share one native Markdown renderer for headings, paragraphs, lists, quotes, fenced code, inline emphasis/links, and GFM-style tables. Tables preserve column alignment, pad short rows, bound cells to 96–240 pt, and scroll horizontally without widening the conversation timeline; streaming text remains plain until completion to avoid reparsing partial Markdown on every delta | Validate VoiceOver reading order and physical iPhone 16 Pro Dynamic Type/touch behavior before marking complete; nested lists and arbitrary HTML are intentionally not interpreted | `HarnessMobile/Core/Agent/NativeMarkdownDocument.swift`; `HarnessMobile/Features/Chat/NativeMarkdownText.swift`; `HarnessMobile/Features/Chat/MessageBubble.swift`; `HarnessMobileTests/NativeMarkdownTextTests.swift`; `HarnessMobileUITests/HarnessMobileLiveUITests.swift` |
| Message feedback | Partial | P2 | Like/dislike with note and independent feedback state | Assistant messages and `/feedback` share `MessageFeedbackSidecarStore`: stable UUID/session/message identity, per-record revision, legacy migration, stale-write rejection, conflict handling and tombstones are independent from the conversation message file | Run the message menu and `/feedback` concurrency paths on the physical iPhone; a remote feedback synchronization service is intentionally not implied | `HarnessMobile/Core/Agent/MessageFeedbackSidecar.swift`; `HarnessMobile/Features/Chat/MessageBubble.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobileTests/MessageFeedbackSidecarTests.swift`; upstream `packages/client/ui-message-feedback` |
| Conversation export | Implemented | P2 | Export/download | Chat exports redacted JSON or Markdown through the native file exporter, removing raw tool arguments and masking common tokens | Add upstream compatibility fixtures if export becomes a shared wire contract | `HarnessMobile/Core/Export/ConversationExportBuilder.swift`; `HarnessMobile/Features/Chat/ConversationExportFileDocument.swift`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobileTests/ConversationExportBuilderTests.swift` |

## Tools and local execution

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Tool approval and permission modes | Implemented | P0 | Permission presets and per-call approval | Native permission mode, typed risk, audit events, and a device-wide durable grant for this personal sideload build; no repeated Harness prompt is inserted, while iOS privacy and Cordis checkpoint decisions remain independent | Reuse the same policy for future subagent, MCP, Web, Code, and mobile-native tools | `HarnessMobile/Core/Agent`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobile/Features/Settings/SettingsView.swift` |
| Recursive tool event model and UI | Partial | P0 | Recursive `ToolCallTree`, including `run_code` child calls | `run_code` child dispatches now re-enter the native approval/guard/checkpoint/tool pipeline, append nested durable dispatch events, and update `AgentToolEvent.children` plus recursive Inspector rows | Add the same nested producer contract to workflow runs; ordinary subagent activations remain separate addressed sessions instead of child tool rows | `HarnessMobile/Core/Agent/AgentMessage.swift`; `HarnessMobile/Features/Chat/ToolEventView.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Core/Tools/CodeModeTool.swift` |
| Tool execution scheduler | Implemented | P0 | Multiple tool calls may execute with bounded parallelism and ordered durable results | A two-slot rolling task pool runs only explicitly concurrency-safe calls, serializes resource conflicts and approval/sensitive/destructive barriers, publishes live completion, and commits durable tool results in model order with cancellation and total-output limits | Audit additional production tools before granting concurrency metadata, and profile the fixed two-call cap on the physical iPhone 16 Pro | `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Core/Tools/LocalAgentTool.swift`; `HarnessMobileTests/AgentRuntimeTests.swift` |
| Specialized tool presentation | Implemented | P1 | Terminal, read, diff, search, web, todo, ask-user, workflow, job, and deliverable cards | Native keyed cards cover terminal, workspace read/write/list, diff, deliverable, goal/todo/plan, workflow, `workspace_search/glob/grep`, ranked web search/fetch, job list/output/kill, recursive details, and Inspector. Large content is folded and UTF-8 bounded; malformed payloads fail safely to the generic card | Validate touch expansion, Dynamic Type and VoiceOver on the physical iPhone 16 Pro; keep the generic projection only as compatibility fallback for unknown plugins | `HarnessMobile/Core/Agent/NativeToolEventPresentation.swift`; `HarnessMobile/Core/Agent/NativeSearchWebJobPresentation.swift`; `HarnessMobile/Features/Chat/NativeToolEventViews.swift`; `HarnessMobile/Features/Chat/ToolEventView.swift`; `HarnessMobileTests/NativeToolEventPresentationTests.swift`; upstream `packages/client/ui-tool` |
| Local Linux shell | iOS replacement | P0 | Desktop Bash/subprocess/PTY provider | Embedded iSH ARM64 Alpine executes on-device with approval, timeout, cancellation, stdout/stderr channels, output limits, process cleanup, canonical workspace working directory, and user-controlled guest networking enabled by default. Each call declares its sandbox mode; because the bundled guest currently cannot enforce a per-process read-only or workspace-only root, those modes fail closed and the shipped shell/code/native paths explicitly use `danger-full-access` within the iOS app sandbox. | Add a real per-call guest fs context before advertising narrower modes; finish physical-device stress and recovery testing; never add a remote fallback | `HarnessMobile/Core/Tools/ISH`; `HarnessMobileTests/ISHSandboxCoordinatorTests.swift`; `Docs/ISH_SANDBOX_PORT.md`; `Vendor/OpenMinisISH` |
| Interactive terminal | iOS replacement | P1 | Desktop terminal and PTY view | Native SwiftUI terminal with ANSI parser, terminal buffer/canvas, keyboard input, resize, and iSH interactive session | Validate rotation, large scrollback, memory pressure, keyboard/IME, and background suspension on iPhone 16 Pro | `HarnessMobile/Features/Terminal`; `HarnessMobile/Features/Terminal/OpenMinis` |
| Unified workspace and mounts | iOS replacement | P0 | Desktop filesystem rooted at a selected working directory | App-private workspace plus security-scoped Files/iCloud folder mounts share one `HarnessFileSystem`; native read/write/list/stat/mkdir/move/copy/remove, bounded `workspace_search`, `workspace_diff`, and `deliverable_write` tools plus the iSH `/workspace` view resolve the same paths | Keep the protected workspace boundary and add richer Files preview/share integration; do not expose the whole app container by default | `HarnessMobile/Core/Storage/WorkspaceStore.swift`; `HarnessMobile/Core/Storage/HarnessFileSystem.swift`; `HarnessMobile/Core/Tools/FileSystemTools.swift`; `HarnessMobile/Core/Tools/DeliverableTools.swift`; `HarnessMobile/Features/Workspace/WorkspaceView.swift` |
| Agent-readable diagnostics | Implemented | P0 | Harness trace, tool errors, plugin logs, session events, and exported diagnostics | `diagnostics_read` returns bounded, credential-redacted summary/errors, Plugin Host stderr/inventory, native compilation trace, Harness Trace, and session events directly to the phone Agent; exported reports use the same redaction boundary | Keep subsystem-specific diagnostic schemas stable and add physical-device failure fixtures as new runtimes land | `HarnessMobile/Core/Trace/HarnessTrace.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobileTests/HarnessTraceStoreTests.swift` |
| Web fetch/search | Implemented | P1 | Web source search and bounded page fetch | `web_search` uses a phone-direct public search adapter with bounded, de-duplicated HTTP(S) sources; `web_fetch` follows same-origin redirects, enforces response/charset limits, and never sends provider credentials | Add richer provider ranking only behind a native transport and keep result cards aligned with the web contract | `HarnessMobile/Core/Tools/WebFetchTool.swift`; `HarnessMobileTests/WebFetchToolTests.swift` |
| Code runtime | iOS replacement | P1 | Worker-thread code runtime with typed output | `run_code` is a real PTC transport: the generated Python SDK reflects live tool schemas, runs in embedded iSH, and routes nested calls back through native approval/guard/checkpoint/execute/post-execute. Legacy `code_execute` remains a bounded direct program tool. | Add richer code presentation; do not claim Desktop worker-thread semantics or other upstream runtime languages | `HarnessMobile/Core/Tools/CodeModeTool.swift`; `HarnessMobile/Core/Tools/ISH/ISHShellTool.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift` |
| LSP and MCP | Partial | P1 | stdio LSP providers and MCP client transports | MCP has a bounded native JSON-RPC/NDJSON client over persistent on-device iSH stdio. LSP reuses the upstream closed four-operation seam and runs its Content-Length protocol host plus Python/TS/JS/C/C++/Rust/Swift language servers inside iSH, with one-based UTF-16 model coordinates, transient document lifecycle, normalized locations/hover, and strict document/result limits | Add direct dynamic `mcp__server__tool` registration plus resources/prompts; add MCP/LSP settings, physical-device fixtures, and the upstream-style persistent per-workspace LSP process pool | `HarnessMobile/Core/Tools/MCP`; `HarnessMobile/Core/Tools/LSP`; `HarnessMobileTests/MCPClientTests.swift`; `HarnessMobileTests/LSPToolTests.swift`; upstream `packages/lsp`, `packages/mcp`; `cordis.patch.yml` |

## Cordis and plugins

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Native Cordis runtime | Implemented | P0 | Dependency/service graph, scoped fibers, lifecycle, checkpoints | Native dependencies, services, isolation labels, generation ownership, hot activate/deactivate, failure cleanup, replacement rollback, events, and checkpoint waterfall trace | Keep conformance tests synchronized with upstream lifecycle changes | `HarnessMobile/Core/Plugins/CordisPluginRuntime.swift`; `HarnessMobileTests/CordisPluginRuntimeTests.swift` |
| iSH Cordis Host | Partial | P0 | Published Cordis dynamic runner and `tool:cordis` lifecycle | Long-lived local Node Host in iSH; official define/run/stop/undefine/inspect tools; dynamic Tool/Prompt/Command contributions; handler/service directory; allowlisted native checkpoint bridges; official file-backed Settings; strict NDJSON RPC | Dynamic definitions are process-memory-only; upstream dynamic update is not atomic rollback | `HarnessMobile/Resources/PluginHost/host.mjs`; `HarnessMobile/Core/Plugins/ISHHost`; `Docs/ISH_PLUGIN_HOST.md` |
| Community plugin marketplace | iOS replacement | P1 | Installed plugin inventory and deployment-owned package sources | Search, details, GitHub/ZIP download, install, enable/disable, update, uninstall, cache clearing, rollback, size/path validation, locked npm install, disabled lifecycle scripts, and state sync. Every source snapshot first goes through the phone Agent's declarative native compiler; explicit incompatibility falls back to iSH, while repairable model/Swift validation failures return to the parent Agent for `diagnostics_read` plus `compiler_guidance` retry | Personal/sideload use and App Store distribution have different policy risk; keep arbitrary Client-half code rejected | `HarnessMobile/Features/Plugins/CommunityPluginMarketView.swift`; `HarnessMobile/Core/Plugins/NativeAgent`; `HarnessMobile/Core/Tools/ISH/PluginMarketplaceTool.swift`; `HarnessMobile/Resources/PluginHost/marketplace.mjs` |
| Host-only dynamic compatibility | Partial | P0 | Host Cordis packages contributing tools/prompts/services/settings/commands and credential-firewalled `llm/stream` hooks | Host-only packages run in iSH and contribute through the typed bridge without model credentials. The Host mounts official Session, Agent, Skill, SessionQuery, and Command services; native trajectories and Skills synchronize incrementally, hosted tools receive `exec.agent.session`, `currentInitiator()` is scoped correctly, plugins observe committed `turn/end` events, and dynamic commands enter the same scoped registry as native/nativeClient commands. Native Code Mode runs `tools/code-dispatch-log` through the Swift Cordis runtime. `llm/stream` now uses an event-acknowledged bridge: Swift owns the provider stream and awaits Host `next/drop/replace` decisions for each chunk, preserving backpressure and cancellation without exposing the API key. | iSH-hosted plugins still cannot intercept native Agent inbox events or the native-only Code Mode dispatcher; image-bearing commands remain fail-closed until an attachment store is mounted | `HarnessMobile/Resources/PluginHost/host.mjs`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginHostClient.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginHostCordisBridge.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginHostDynamicHarnessBridge.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobileTests/ISHPluginHostNodeSmoke.mjs`; `Docs/ISH_PLUGIN_HOST.md` |
| Native Client sidecars | iOS replacement | P1 | Client-half contributions normally supplied through the Web `dsh.client` runtime | Versioned `dsh.nativeClient` schema v1 supports package-backed key/value or Markdown inspectors over read-only Host service endpoints, links to official settings namespaces, and native slash commands that invoke existing Host tools; exact permissions, activation generations, rollback, stale-call rejection, and credential validation are enforced on both sides | Add new contribution types only through a versioned native schema; arbitrary slots, custom SwiftUI renderers, and Agent-generated native manifests are not exposed | `HarnessMobile/Resources/PluginHost/marketplace.mjs`; `HarnessMobile/Core/Plugins/ISHHost/ISHNativeClientProtocol.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHNativeClientCordisBridge.swift`; `HarnessMobile/Features/Plugins/NativeClientContributionsView.swift`; `HarnessMobileTests/ISHNativeClientTests.swift`; `Docs/NATIVE_CLIENT_PLUGINS.md` |
| Browser `dsh.client` runtime | Missing | P1 | React slots, themes, browser services, Web components, and Cordis Client runner | iOS ignores the Web Client entry and runs only a separately validated native sidecar when present | Continue rejecting arbitrary React/browser execution; map any future supported capability through audited native manifests rather than embedding the desktop Client runtime | `HarnessMobile/Resources/PluginHost/marketplace.mjs`; `Docs/NATIVE_CLIENT_PLUGINS.md`; upstream `packages/client` |
| Generic plugin configuration | Partial | P1 | Official `ctx.settings` namespaces plus schema/layer/revision cards with draft/save/discard/default/override state | Official `dsh-settings` + `dsh-settings-file` run in iSH; native namespace search and forms preserve defaults/base/user/revision, staged edits, field reset, save/discard, live-vs-restart state, conflict rebase, and secret status without exposing values; Native Client settings contributions reuse the same editor | Complex transform/lazy/recursive schemas and dynamic collections remain read-only until a lossless native editor exists; secret values are intentionally not writable through the plugin Host wire | `HarnessMobile/Core/Plugins/ISHHost/ISHPluginSettingsDraft.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginSettingsSchema.swift`; `HarnessMobile/Features/Plugins/PluginSettingsView.swift`; `HarnessMobile/Features/Plugins/NativeClientContributionsView.swift`; `HarnessMobileTests/ISHPluginSettingsDraftTests.swift`; upstream `packages/settings`; upstream `packages/client/ui-settings-plugins` |

## Durable orchestration

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Durable subagents | Partial | P0 | Parent/child addresses, in-process spawn/fork, directory, breadcrumb, follow-up, continue, interrupt | Stable child addresses own persistent `SessionStore` histories and descriptor v2 records. `send_message` wakes the same child after completion or interruption, `subagent_list` exposes deterministic trees, and Chat/Jobs use a cycle-safe durable lineage for root-to-child navigation and status. RC.8 Profile Bundles can target local Codex or Claude Code CLI instances. | Validate multi-level open/return/interrupt on the physical device; a killed in-flight activation is not resumed automatically after jetsam | `HarnessMobile/Core/Tools/JobTools.swift`; `HarnessMobile/Core/Configuration/AgentProviderBundle.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Core/Jobs/HarnessJobs.swift`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobileTests/HarnessJobsTests.swift`; upstream `packages/subagent`; upstream `packages/client/ui-subagent` |
| Workflow lifecycle | Partial | P1 | Foreground model-written JavaScript orchestration, bounded fan-out, and observe-only run/member lifecycle | The native `workflow` tool runs bounded JavaScript in the on-device iSH Node `vm`, routes inference through continuable subagents, supports Profile Bundle provider overrides and structured-schema validation, and persists linked run/member lifecycle events with a dedicated compact card | Match upstream's stated boundary with more physical-device fixtures: no background workflow, saved/nested workflow, journaling, or restart resume | `HarnessMobile/Core/Tools/WorkflowTool.swift`; `HarnessMobile/Core/Tools/ProductionToolCatalog.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobileTests/WorkflowToolTests.swift`; upstream `packages/workflow/workflow`; upstream `packages/workflow/tool-workflow` |
| Background Jobs | Partial | P1 | Per-agent job registry, background tool controls, session-header Jobs list | `shell_execute(run_in_background=true)` and background subagents use session-owned on-device jobs with bounded output, list/wait/read/kill tools, cancellation and atomic recovery; the Jobs panel projects the durable root Agent tree, and completion delivery uses claim/ack/requeue so results survive busy sessions and cold launches | Validate delivery and Live Activity projection under physical background/jetsam conditions; iOS cannot resume an arbitrary iSH process after jetsam | `HarnessMobile/Core/Jobs/HarnessJobs.swift`; `HarnessMobile/Core/Tools/JobTools.swift`; `HarnessMobile/Core/Tools/ISH/ISHShellTool.swift`; `HarnessMobileTests/HarnessJobsTests.swift`; upstream `packages/jobs`; `packages/client/ui-jobs` |
| Agent presets | Partial | P1 | Preset registry, per-session mounted Agent plane, settings default | Per-session selection, persisted default, system/user preset registry, prompt/tool/permission composition, `/agent`, standard/minimal/Cordis presets, and a mountable PTC preset are implemented. PTC exposes only `run_code`; its generated Python SDK reflects the live registry and child calls re-enter the full native tool pipeline. | Import/edit UI for user preset manifests is still narrower than Desktop; Code Mode currently supports the local Python/iSH provider rather than every upstream runtime provider | `HarnessMobile/Core/Presets/AgentPresets.swift`; `HarnessMobile/Core/Tools/CodeModeTool.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift`; `HarnessMobileTests/AgentPresetTests.swift`; upstream `packages/preset`, `packages/core/tools`, and `packages/code-runtime` |
| Skills | Partial | P1 | Layered Skill registry, filesystem discovery, user invocation, and `skill` tool | On-device roots `.dsh/skills`, `.agents/skills`, and `Skills` support Markdown/SKILL bundles, upstream-style precedence, on-demand `skill`, `/skill-name`, durable source records, and the native `@` reference palette | No arbitrary external filesystem roots/watcher or browser Skill UI; discovery is refreshed at every model step and tool load instead | `HarnessMobile/Core/Skills/MobileSkillRegistry.swift`; `HarnessMobile/Core/Tools/SkillTools.swift`; `HarnessMobile/Core/Storage/WorkspaceStore.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobileTests/MobileSkillRegistryTests.swift`; upstream `packages/skill` |

## Mobile and background capability

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Camera and OCR | iOS replacement | P2 | Attachment and image tools | Camera capture, Photos attachment, Vision OCR, workspace output, and tool registration | Add camera-memory/downsampling performance fixtures and optional richer image inspection | `HarnessMobile/Features/Chat/CameraPicker.swift`; `HarnessMobile/Core/Tools/CameraOCRTool.swift` |
| Location, motion, notification, Face ID, Files, App Intents | iOS replacement | P2 | No direct desktop equivalent | One-shot real location, recent motion activity, local notifications, Local Authentication, private workspace/Files flow, and App Intent routing | Add user-confirm-before-share for sensitive coordinates where the workflow needs it; broaden App Intent coverage after core parity | `HarnessMobile/Core/Tools/MobileNativeTools.swift`; `HarnessMobile/SystemIntegration/HarnessAppIntents.swift` |
| Live Activity and continued processing | iOS replacement | P0 | Desktop can keep a process alive and show task status | ActivityKit state, privacy redaction, stale dates, completion, local notifications, iOS 26+ `BGContinuedProcessingTask`, cancellation, and runtime status | Verify entitlements/widget presentation and OS expiration on the physical device; UI must never promise permanent execution | `HarnessMobile/Core/Background`; `HarnessMobileLiveActivity` |
| Fake location as keep-alive | iOS replacement | P0 | Not a Harness feature | Production code uses a real one-shot location tool and does not depend on fake location | Xcode simulated location is test-only. Do not add fake location, silent audio, fake BLE, or VoIP abuse as a background requirement | `HarnessMobile/Core/Tools/MobileNativeTools.swift`; `Docs/ISH_SANDBOX_PORT.md` |
| Speech, BLE, and Contacts | Partial | P2 | Research-defined mobile extension | Native read-only `contacts_search` is implemented. Speech, Bluetooth, calendar, reminders, media, HealthKit, HomeKit, NFC, maps, notifications, and on-device NLP are exposed through the allowlisted local `ios_native` bridge; `device_capabilities` reports entitlement and permission state before use | Validate each bridged capability on the physical device and keep entitlement-gated/long-lived system sessions unavailable rather than claiming unsupported background behavior | `HarnessMobile/Core/Tools/ContactsSearchTool.swift`; `HarnessMobile/Core/Tools/ISH/IOSNativeOffloadTool.swift`; `HarnessMobile/Core/Tools/DeviceCapabilitiesTool.swift` |

## Immediate gaps and platform limits

The following items can be filled without changing the product boundary:

- Agent inbox checkpoints and a credential-firewalled Host `llm/stream`
  bridge with explicit backpressure, cancellation, partial-output and error
  semantics.
- Direct dynamic MCP tool definitions plus MCP resources/prompts, persistent
  per-workspace LSP processes, remaining compatibility fixtures, and
  physical-device performance tests.
- Real nested event presentation for workflow children and additional audited
  `dsh.nativeClient` contribution kinds. Jobs already persist bounded metadata,
  deliver results durably, and expose child navigation, but they cannot resume
  an arbitrary iSH process after jetsam.

The following desktop mechanisms cannot be copied literally:

- Arbitrary React/Web `dsh.client` code, browser slot plugins, and themes cannot
  run through the iSH Host. The implemented `dsh.nativeClient` v1 sidecar covers
  only its audited declarative inspectors, settings links, and commands.
- Desktop `child_process`, `node-pty`, worker-thread Workflow/Code providers,
  and stdio LSP providers need iSH or native capability replacements.
- A Host plugin cannot receive the provider API key or transparently wrap
  native `llm/stream` under the current credential firewall.
- ActivityKit, Continued Processing, real location, audio, BLE, and
  notifications cannot guarantee daemon-style permanent execution.
- Fake location, silent audio, fake BLE, or VoIP misuse is not an acceptable
  performance or background strategy.
- Downloading executable Host plugins is technically available for local
  sideload use, but distribution policy must be assessed separately before an
  App Store release.

## Performance and iSH constraints

The current implementation already follows several iPhone-oriented rules:

- No local model weights.
- The Alpine root filesystem is pinned and installed separately from model
  inference.
- Guest networking is independent from provider networking, defaults on, and remains user-controllable.
- Shell output is streamed by channel and retained with explicit limits.
- The runtime resource governor reacts to foreground/background state, Low
  Power Mode, thermal state, and memory pressure.
- Native tool events keep a bounded persisted transcript; full terminal state
  is not appended indefinitely to one SwiftUI string.
- Chat rows use a stable 80-message projection and `LazyVStack`; tool-result
  de-duplication runs only when the durable message revision changes.
- Provider text/reasoning deltas are coalesced behind a monotonic presentation
  revision, and live tool output is reduced into bounded 100 ms UI batches.
- Trajectory and Harness Trace refresh by durable sequence cursor. Assistant
  token chunks remain available for diagnostics but do not force a SwiftUI
  timeline projection rebuild for every streamed delta.
- The plugin Host uses a pinned npm tree, disabled lifecycle scripts, and a
  credential firewall.

Remaining performance work:

1. Capture SwiftUI, Time Profiler, hangs/hitches, and memory-pressure traces for
   the 240-message fixture plus a real long stream on the physical iPhone 16 Pro.
2. Profile the current two-slot conflict-aware scheduler on the physical iPhone
   16 Pro. Keep tools exclusive unless their implementation explicitly declares
   concurrency safety and stable resource identities.
3. Add durable nested event production without rebuilding an entire recursive
   tree for every output byte.
4. Measure peak memory, thermal throttling, terminal scrollback, rootfs install,
   plugin install, long SSE streams, cancellation, and background expiration on
   the physical iPhone 16 Pro.
5. Add recovery tests for iSH process death, app suspension, jetsam, Host
   restart, and partially installed marketplace packages.
6. Keep model API traffic native. Do not route inference through iSH merely to
   make a plugin appear more compatible.

## Compatibility fixture reality

The fixture directory is currently much smaller than the implemented feature
surface.

| Fixture family | Status | Current files | Required expansion |
| --- | --- | --- | --- |
| Provider profiles and model discovery | Implemented | `provider-directory-v1.json`, `provider-profile-migration-v1.json`, `credential-ref-v1.json`, `openai-models-v1.json`, `openai-model-discovery-failures-v1.json` | Keep protocol-specific fixtures synchronized when a provider adopts a new model-list contract; real private gateways remain opt-in |
| Basic Harness wire | Partial | `deepseek/harness-wire-v1.json`; `deepseek/compaction-cross-version-v1.json`; `deepseek/reasoning-cancel-v1.json`; `deepseek/image-reference-v1.json`; `deepseek/subagent-jobs-v1.json` | RC.2 fixtures now lock reasoning replay, interrupted prefixes, inline/file-id images, file/session references, continuable subagent descriptor v2, and job completion; still split queue/steer, usage and provider error envelopes into dedicated fixtures as those contracts evolve |
| Tool tree and scheduler | Partial | Scheduler behavior is covered in `HarnessMobileTests/AgentRuntimeTests.swift`, but there is no fixed cross-version fixture | Add real nested-child/`run_code` fixtures plus compatibility fixtures for conflict serialization, approval barriers, cancellation, completion order, deterministic commit, and truncation |
| Ask-user and plan review | Implemented | `deepseek/user-interaction-v1.json`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; behavior coverage in `HarnessMobileTests/UserInteractionToolsTests.swift` | The fixed fixture covers multi-question single/multi-select, skipped and custom answers, exact resume output, and discuss/refuse/approve semantics; cancellation races are covered by behavior tests and can gain a fixed fixture when the cross-version wire contract requires one |
| Goal/Plan/Todo | Partial | Lifecycle, identity, persistence, and compaction behavior are covered by `WorkStateToolsTests`, `SessionStoreTests`, and `ConversationCompactorTests` | Add a fixed JSON/JSONL cross-version fixture for upstream `goal/change`/`todo/write`, including parallel in-progress todo policy |
| Skills and Agent Presets | Partial | `MobileSkillRegistryTests`, `AgentPresetTests`, reference syntax tests, and an AgentRuntime injection test cover local precedence, invocation policy, on-demand reload, session injection, system preset composition, and native `@skill` selection | Add a versioned upstream Skill/preset fixture corpus and user manifest import/edit coverage |
| Subagents, workflows, and jobs | Partial | `deepseek/subagent-jobs-v1.json`; `HarnessMobileTests/RC2CompatibilityFixtureTests.swift`; `HarnessMobileTests/HarnessJobsTests.swift`; `HarnessMobileTests/SessionEventTrajectoryTests.swift` | Descriptor v2, mobile projection, completion notice, lifecycle recovery and job interruption/recovery are covered; add address-tree, follow-up, workflow recovery, and cold-child fixtures |
| iSH | Missing | None | Add command, timeout, cancel, process-tree kill, UTF-8 split, output limit, mount, and network-policy fixtures |
| Cordis Host and marketplace | Partial | Swift and Node tests exist, but no cross-version compatibility fixture corpus | Add inventory/contribution revisions, stale run IDs, rollback, Client-half rejection, install recovery, and redaction fixtures |
| Background and Live Activity | Missing | Unit tests cover state machines, but no shared compatibility fixtures | Add activity projection, privacy redaction, expiration, notification, and relaunch fixtures |

Passing unit tests is necessary but does not by itself prove Desktop/Web
compatibility. Each upstream contract named above should have fixed JSON/JSONL
input and an expected Swift projection so future upstream upgrades produce an
intentional diff.

## Remaining delivery order

1. Expand and lock the remaining RC.2 compatibility fixtures, then keep this
   document synchronized with the executable contracts.
2. Add the Agent inbox checkpoint and the credential-firewalled Host
   `llm/stream` bridge; extend `dsh.nativeClient` only with audited native kinds.
3. Finish direct MCP tool/resource/prompt registration and persistent
   per-workspace LSP process/settings support by reusing the existing clients.
4. Complete workflow child event nesting and formal multi-workspace entities;
   do not replace the already implemented breadcrumbs, Jobs delivery, command
   continuations, feedback, export, or specialized cards.
5. Run iPhone 16 Pro image, provider, iSH/plugin, background/jetsam, long-stream,
   accessibility, thermal and diagnostic-redaction acceptance tests.

## Release acceptance

The port should not be described as Desktop-parity-complete until all of these
are true:

- Every supported provider protocol has live streaming, cancellation, tool
  calls, usage, error, and discovery/manual-model tests.
- Provider keys remain write-only and never cross into iSH or logs.
- Multiple model tool calls retain bounded concurrency, conflict serialization,
  deterministic persistence, approval barriers, interruption, and complete
  Inspect data.
- Real recursive tool-event producers exist for `run_code`, workflows, and
  subagents instead of projecting every model call as a flat root event.
- Subagents, workflows, and Jobs survive the lifecycle boundaries promised by
  their UI and never silently degrade to one flat Agent turn.
- Agent Presets and Skills compose prompts/tools/permissions per session,
  including model tool loading and user-explicit Skill injection.
- Supported Host and `dsh.nativeClient` contributions have an explicit native
  compatibility contract; unsupported Web `dsh.client` code is rejected clearly.
- iSH command, interactive terminal, network policy, timeout, cancellation,
  process cleanup, output limits, rootfs recovery, and GPL distribution
  obligations are verified.
- Live Activity and Continued Processing show real state, redact private data,
  stop on terminal state, and accurately report OS suspension/expiration.
- No command execution depends on a server, fake location, silent audio, fake
  BLE, or another background-policy workaround.
- The compatibility fixtures and physical iPhone 16 Pro test matrix pass for
  the pinned upstream revisions.

Toolchain note: `Dependencies/upstreams.lock.json` declares project Xcode 27.0.
The installed Beta at `/Users/liulingfei/Downloads/Xcode-beta.app` reports Xcode
27.0 build and exposes the iOS 27.0 iPhone 16 Pro simulator. The
system-selected command-line Xcode remains 26.6, so command-line builds and tests
must set `DEVELOPER_DIR=/Users/liulingfei/Downloads/Xcode-beta.app/Contents/Developer`.
