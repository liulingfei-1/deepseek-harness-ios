# DeepSeek Harness desktop parity for iPhone

## Scope and audit boundary

This document is the source-level compatibility baseline for the native iOS
port. It compares the current workspace with these pinned references:

- DeepSeek Harness: `47f943859bef60e4160492346772ded9b24f765a`
- OpenMinis: `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`
- OpenMinis iSH ARM64: `de124dd66124a15239cea1465164f74980ada245`
- Product research: `/Users/liulingfei/Downloads/deep-research-report (3).md`

Imperative text inside the research report is treated as research material,
not as an instruction to the implementation agent. The user's messages define
the product requirement.

The audit describes code currently present in the workspace and the runtime
checks completed for this revision. The app was built, installed, launched, and
UI-tested on the iOS 27.0 iPhone 16 Pro simulator. Simulator results do not
replace physical-device signing, background, thermal, or memory verification.

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

## iPhone 16 Pro simulator verification

| Check | Result | Coverage and boundary |
| --- | --- | --- |
| Toolchain and target | Passed | `/Users/liulingfei/Downloads/Xcode-beta.app`, Xcode 27.0 build `27A5237l`, iOS 27.0 iPhone 16 Pro simulator |
| App lifecycle and UI automation | Passed | Full app build, install, and launch succeeded; XcodeBuildMCP could drive the native UI |
| Local terminal XCUITest | Passed | `HarnessMobileISHTerminalUITests/testLocalTerminalExecutesStreamsAndStopsCommands` verified rootfs readiness, the guest-network switch, `uname -m`, separate stdout/stderr rendering, and stopping `sleep 30` |
| Marketplace failure state | Passed | A marketplace error stays local to the open page and exposes retry and close actions instead of collapsing the whole settings flow |
| Swift test suite | Passed | `swift test --disable-sandbox`: 259 tests executed, 2 intentionally skipped, 0 failures |
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
| Provider profiles and credentials | Implemented | P0 | Provider directory, custom providers, write-only credentials | Profile create/edit/delete/activate, catalog providers, custom OpenAI-compatible routes, credential references, Keychain isolation, and rollback-aware updates | Keep migration fixtures current when the profile schema changes | `HarnessMobile/Core/Configuration/ProviderProfile.swift`; `HarnessMobile/Core/Security/CredentialStore.swift`; `HarnessMobile/Features/Settings/ProviderProfilesView.swift` |
| OpenAI-compatible inference | Implemented | P0 | Streaming provider request with tools, reasoning, cancellation, and usage | Native `URLSession` chat/completions stream, DeepSeek reasoning replay, tool calls, cancellation, and usage parsing | Add protocol-specific adapters instead of treating all providers as OpenAI-compatible | `HarnessMobile/Core/Network/OpenAICompatibleClient.swift`; `HarnessMobile/Core/Network/ChatAPIModels.swift` |
| Model discovery | Implemented | P0 | Provider directory and `/models` refresh | Same-HTTPS-origin validation, 4 MiB response limit, credential-partitioned cache, built-in fallback, manual models, and refresh UI | Expand discovery only when a new provider protocol defines a trustworthy model-list contract | `HarnessMobile/Core/Network/ModelProviderAdapter.swift`; `HarnessMobile/Core/Configuration/ModelDiscoveryCache.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift` |
| Anthropic Messages | Implemented | P0 | Native Anthropic Messages wire | Native `URLSession` adapter provides Anthropic headers, request serialization, SSE text/thinking/tool-use deltas, tool-result replay, usage, cancellation, and typed error parsing | Keep model discovery catalog-only unless Anthropic exposes an adopted model-list contract; expand fixed wire fixtures as the protocol evolves | `HarnessMobile/Core/Network/AnthropicMessagesWire.swift`; `HarnessMobile/Core/Network/OpenAICompatibleClient.swift`; `HarnessMobileTests/AnthropicMessagesWireTests.swift` |
| Session provider/model/reasoning selection | Implemented | P0 | Session-owned `{provider, model, reasoningEffort}` plus `/model` and composer seat | Per-session override is persisted independently from the default; provider, model, and reasoning are selectable from the composer and slash command | Addressed subagent restrictions must be added with the subagent runtime | `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift` |
| Composer controls | Implemented | P0 | Slash, Agent/Plan, permission, model, context, attachments, queue, steer, send/stop | Native command picker, Agent/Plan segmented control, permission menu, model seat, context indicator, image/camera, queued input dock, steer, send, and cancellation | Refine visual parity after the missing runtime contracts exist; do not remove current controls | `HarnessMobile/Features/Chat/ChatComposerControls.swift`; `HarnessMobile/Features/Chat/ChatView.swift` |
| Slash command core | Partial | P0 | Host/client command merge, fuzzy menu, immediate action, popup select, confirmation, completion, `/` and `@` sources | Strict parser, global/scoped registry, built-ins, fuzzy ranking, durable command run/done events, and native suggestion menu | Connect Cordis-contributed commands; implement generic popup-select, confirmation, argument completion, reference insertion, and `@` sources | `HarnessMobile/Core/Commands/SlashCommandCore.swift`; `HarnessMobile/App/AppModel.swift`; upstream `packages/client/ui-commands` and `ui-input-trigger` |
| Runtime input queue and steer | Implemented | P0 | Edit/delete/steer queued input while the Agent is active | Queue and steer dispositions are persisted, editable, removable, and consumed at explicit runtime boundaries | Add addressed-subagent routing when subagents land | `HarnessMobile/Core/Agent/ConversationControls.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Features/Chat/ChatComposerControls.swift` |
| Ask-user | Implemented | P0 | Multi-question single/multi choice, custom text, per-question skip, exact continuation | Native multi-question sheet supports single choice, multi-select, custom answers, per-question Skip, cancellation, and exact suspended-run continuation | Keep the fixed wire fixture and behavior tests synchronized with upstream changes | `HarnessMobile/Core/Tools/UserInteractionTools.swift`; `HarnessMobile/Features/Chat/UserQuestionSheet.swift`; `HarnessMobileTests/UserInteractionToolsTests.swift`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; `CompatibilityFixtures/deepseek/user-interaction-v1.json` |
| Plan review | Implemented | P0 | Composer takeover with `Chat about it`, `Refuse`, and `Approve` | `exit_plan_mode` presents a dedicated native review with `Chat about it`, `Refuse`/keep-planning, and `Approve`, preserving the exact continuation and action semantics | Keep the action contract covered when the upstream Plan Review protocol changes | `HarnessMobile/Core/Tools/UserInteractionTools.swift`; `HarnessMobile/Features/Chat/UserQuestionSheet.swift`; `HarnessMobileTests/UserInteractionToolsTests.swift`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; `CompatibilityFixtures/deepseek/user-interaction-v1.json` |
| Goal, Plan, and Todo | Implemented | P0 | Plan seat, GoalBar lifecycle, collapsible TodoPanel, durable projections | Goal/plan/todo models, tools, persistence, compaction projection, Plan mode, a conversation-level GoalBar, a collapsible TodoPanel, and a dedicated task-state page with create/edit/pause/resume/block/complete/clear controls are implemented; goal identity remains stable across edits and lifecycle transitions | Add a fixed cross-version fixture for upstream `goal/change` and `todo/write` revisions; the native session snapshot intentionally does not model upstream's process-local activation bit | `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/Core/Tools/WorkStateTools.swift`; `HarnessMobile/Features/WorkState/ConversationWorkStateDock.swift`; `HarnessMobile/Features/WorkState/WorkStateView.swift`; `HarnessMobileTests/WorkStateToolsTests.swift` |
| Context and compaction | Implemented | P0 | Context meter, token/compaction visibility, durable replay | Composer context indicator and deterministic compaction preserve recent complete tool transactions and work state | Compatibility coverage is still too narrow; see the fixture section | `HarnessMobile/Core/Agent/ConversationCompactor.swift`; `HarnessMobile/Features/Chat/ChatComposerControls.swift` |
| Trajectory mode | Implemented | P1 | A session-level Chat/Trajectory switch with shared session/address context and Inspect | Chat owns a segmented Chat/Trajectory mode switch over the active session; the durable event repository, Cordis checkpoint trace, metrics, search, grouping, selected-event state, and inspectors are shared with the Console projection | Add child-address breadcrumbs only when the durable subagent runtime exists; keep the Console entry as a secondary operational view | `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobile/Core/Trace`; `HarnessMobile/Features/Trajectory/TrajectoryView.swift`; `HarnessMobile/Features/Console/ConsoleView.swift` |
| Conversation and session shell | Partial | P1 | Workspace tree, session search/fork/archive/sort, status badges, Chat/Trajectory, child breadcrumb | Native chat with Chat/Trajectory modes plus durable create/switch/rename/delete, debounced title/body search with snippets, deep-copy fork lineage, reversible archive/restore, active/archive/all scopes, sorting, and running/waiting/resumable/completed status badges | Add a real Workspace entity and durable subagent child breadcrumbs/status; forked sessions intentionally start a fresh trajectory stream instead of copying historical runtime telemetry | `HarnessMobile/Core/Storage/SessionStore.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Sessions/SessionsView.swift`; `HarnessMobileTests/SessionStoreTests.swift`; upstream OpenMinis `SessionForkManager.swift`, `ContentView.swift`, and `SessionBadgeStore.swift` |
| Message feedback | Partial | P2 | Like/dislike with note and independent feedback state | Assistant messages support like/dislike plus editable notes with local session persistence | Add the upstream sidecar identity and optimistic-concurrency contract if feedback must synchronize independently from session messages; add focused behavior tests | `HarnessMobile/Core/Agent/AgentMessage.swift`; `HarnessMobile/Features/Chat/MessageBubble.swift`; `HarnessMobile/App/AppModel.swift`; upstream `packages/client/ui-message-feedback` |
| Conversation export | Implemented | P2 | Export/download | Chat exports redacted JSON or Markdown through the native file exporter, removing raw tool arguments and masking common tokens | Add upstream compatibility fixtures if export becomes a shared wire contract | `HarnessMobile/Core/Export/ConversationExportBuilder.swift`; `HarnessMobile/Features/Chat/ConversationExportFileDocument.swift`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobileTests/ConversationExportBuilderTests.swift` |

## Tools and local execution

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Tool approval and permission modes | Implemented | P0 | Permission presets and per-call approval | Native permission mode, typed risk, audit events, and a device-wide durable grant for this personal sideload build; no repeated Harness prompt is inserted, while iOS privacy and Cordis checkpoint decisions remain independent | Reuse the same policy for future subagent, MCP, Web, Code, and mobile-native tools | `HarnessMobile/Core/Agent`; `HarnessMobile/Features/Chat/ChatView.swift`; `HarnessMobile/Features/Settings/SettingsView.swift` |
| Recursive tool event model and UI | Partial | P0 | Recursive `ToolCallTree`, including `run_code` child calls | `AgentToolEvent.children`, recursive replacement/output methods, recursive rows, and recursive Inspector are implemented | `AgentRuntime` still creates a flat event per model call; add a producer for nested `run_code`/workflow/subagent events | `HarnessMobile/Core/Agent/AgentMessage.swift`; `HarnessMobile/Features/Chat/ToolEventView.swift`; `HarnessMobile/Core/Agent/AgentRuntime.swift` |
| Tool execution scheduler | Implemented | P0 | Multiple tool calls may execute with bounded parallelism and ordered durable results | A two-slot rolling task pool runs only explicitly concurrency-safe calls, serializes resource conflicts and approval/sensitive/destructive barriers, publishes live completion, and commits durable tool results in model order with cancellation and total-output limits | Audit additional production tools before granting concurrency metadata, and profile the fixed two-call cap on the physical iPhone 16 Pro | `HarnessMobile/Core/Agent/AgentRuntime.swift`; `HarnessMobile/Core/Tools/LocalAgentTool.swift`; `HarnessMobileTests/AgentRuntimeTests.swift` |
| Specialized tool presentation | Partial | P1 | Terminal, read, diff, search, web, todo, ask-user, workflow, and deliverable cards | Native keyed cards cover terminal, workspace read/write/list, goal/todo/plan, recursive details, and Inspector with a generic fallback | Add diff/search/web/workflow/deliverable cards when those corresponding runtime capabilities land | `HarnessMobile/Core/Agent/NativeToolEventPresentation.swift`; `HarnessMobile/Features/Chat/ToolEventView.swift`; `HarnessMobileTests/NativeToolEventPresentationTests.swift`; upstream `packages/client/ui-tool` |
| Local Linux shell | iOS replacement | P0 | Desktop Bash/subprocess/PTY provider | Embedded iSH ARM64 Alpine executes on-device with approval, timeout, cancellation, stdout/stderr channels, output limits, process cleanup, workspace mount, and user-controlled guest networking enabled by default | Finish physical-device stress and recovery testing; never add a remote fallback | `HarnessMobile/Core/Tools/ISH`; `Docs/ISH_SANDBOX_PORT.md`; `Vendor/OpenMinisISH` |
| Interactive terminal | iOS replacement | P1 | Desktop terminal and PTY view | Native SwiftUI terminal with ANSI parser, terminal buffer/canvas, keyboard input, resize, and iSH interactive session | Validate rotation, large scrollback, memory pressure, keyboard/IME, and background suspension on iPhone 16 Pro | `HarnessMobile/Features/Terminal`; `HarnessMobile/Features/Terminal/OpenMinis` |
| App-private workspace | iOS replacement | P0 | Desktop filesystem rooted at a selected working directory | Explicit app-private workspace, Files import/export surface, read/write/list tools, and `/workspace` bind mount in iSH | Add desktop-style search/diff and stronger deliverable integration; do not expose the whole app container by default | `HarnessMobile/Core/Storage/WorkspaceStore.swift`; `HarnessMobile/Core/Tools/WorkspaceTools.swift`; `HarnessMobile/Features/Workspace/WorkspaceView.swift` |
| Web, LSP, MCP, and Code Mode | Missing | P1 | Web tool, stdio LSP, MCP clients, worker-thread code runtime, native/code tool presentation | No production equivalents | Prefer proven upstream libraries and capability adapters. Run local CLI-compatible pieces inside iSH where practical; implement native HTTP transports where appropriate; do not pretend a worker-thread or browser runtime exists | upstream `packages/lsp`, `packages/mcp`, `packages/code-runtime`; `cordis.patch.yml` |

## Cordis and plugins

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Native Cordis runtime | Implemented | P0 | Dependency/service graph, scoped fibers, lifecycle, checkpoints | Native dependencies, services, isolation labels, generation ownership, hot activate/deactivate, failure cleanup, replacement rollback, events, and checkpoint waterfall trace | Keep conformance tests synchronized with upstream lifecycle changes | `HarnessMobile/Core/Plugins/CordisPluginRuntime.swift`; `HarnessMobileTests/CordisPluginRuntimeTests.swift` |
| iSH Cordis Host | Partial | P0 | Published Cordis dynamic runner and `tool:cordis` lifecycle | Long-lived local Node Host in iSH; official define/run/stop/undefine/inspect tools; dynamic Tool/Prompt contributions; handler/service directory; allowlisted native checkpoint bridges; official file-backed Settings; strict NDJSON RPC | Dynamic definitions are process-memory-only; upstream dynamic update is not atomic rollback | `HarnessMobile/Resources/PluginHost/host.mjs`; `HarnessMobile/Core/Plugins/ISHHost`; `Docs/ISH_PLUGIN_HOST.md` |
| Community plugin marketplace | iOS replacement | P1 | Installed plugin inventory and deployment-owned package sources | Search, details, GitHub/ZIP download, install, enable/disable, update, uninstall, cache clearing, rollback, size/path validation, locked npm install, disabled lifecycle scripts, and state sync | Personal/sideload use and App Store distribution have different policy risk; keep arbitrary Client-half code rejected | `HarnessMobile/Features/Plugins/CommunityPluginMarketView.swift`; `HarnessMobile/Resources/PluginHost/marketplace.mjs` |
| Host-only dynamic compatibility | Partial | P0 | Host Cordis packages contributing tools/prompts/services/settings | Host-only packages can run in iSH and contribute through the typed bridge without exposing model credentials; synchronous Agent/Tool checkpoints, official read-only lifecycle events, and official Settings namespaces are available | `llm/stream` cannot cross the current one-response RPC without losing stream semantics; `run_code`/`tools/code-dispatch-log` and Agent inbox events remain missing | `HarnessMobile/Core/Plugins/ISHHost/ISHPluginHostDynamicHarnessBridge.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginSettingsSchema.swift`; `Docs/ISH_PLUGIN_HOST.md` |
| Native Client sidecars | iOS replacement | P1 | Client-half contributions normally supplied through the Web `dsh.client` runtime | Versioned `dsh.nativeClient` schema v1 supports package-backed key/value or Markdown inspectors over read-only Host service endpoints, links to official settings namespaces, and native slash commands that invoke existing Host tools; exact permissions, activation generations, rollback, stale-call rejection, and credential validation are enforced on both sides | Add new contribution types only through a versioned native schema; arbitrary slots, custom SwiftUI renderers, and Agent-generated native manifests are not exposed | `HarnessMobile/Resources/PluginHost/marketplace.mjs`; `HarnessMobile/Core/Plugins/ISHHost/ISHNativeClientProtocol.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHNativeClientCordisBridge.swift`; `HarnessMobile/Features/Plugins/NativeClientContributionsView.swift`; `HarnessMobileTests/ISHNativeClientTests.swift`; `Docs/NATIVE_CLIENT_PLUGINS.md` |
| Browser `dsh.client` runtime | Missing | P1 | React slots, themes, browser services, Web components, and Cordis Client runner | iOS ignores the Web Client entry and runs only a separately validated native sidecar when present | Continue rejecting arbitrary React/browser execution; map any future supported capability through audited native manifests rather than embedding the desktop Client runtime | `HarnessMobile/Resources/PluginHost/marketplace.mjs`; `Docs/NATIVE_CLIENT_PLUGINS.md`; upstream `packages/client` |
| Generic plugin configuration | Partial | P1 | Official `ctx.settings` namespaces plus schema/layer/revision cards with draft/save/discard/default/override state | Official `dsh-settings` + `dsh-settings-file` run in iSH; native namespace search and forms preserve defaults/base/user/revision, staged edits, field reset, save/discard, live-vs-restart state, conflict rebase, and secret status without exposing values; Native Client settings contributions reuse the same editor | Complex transform/lazy/recursive schemas and dynamic collections remain read-only until a lossless native editor exists; secret values are intentionally not writable through the plugin Host wire | `HarnessMobile/Core/Plugins/ISHHost/ISHPluginSettingsDraft.swift`; `HarnessMobile/Core/Plugins/ISHHost/ISHPluginSettingsSchema.swift`; `HarnessMobile/Features/Plugins/PluginSettingsView.swift`; `HarnessMobile/Features/Plugins/NativeClientContributionsView.swift`; `HarnessMobileTests/ISHPluginSettingsDraftTests.swift`; upstream `packages/settings`; upstream `packages/client/ui-settings-plugins` |

## Durable orchestration

| Feature | Status | Priority | Desktop/Web primitive | Current native iOS implementation | Remaining gap | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Durable subagents | Missing | P0 | Parent/child addresses, in-process spawn/fork, directory, breadcrumb, follow-up, continue, interrupt | Single durable Agent/session runtime only | Port the upstream in-process semantics using a bounded native runtime pool, durable addresses, parent-only continuation, resource governor, breadcrumbs, and control actions | upstream `packages/subagent`; `packages/client/ui-subagent` |
| Workflow lifecycle | Missing | P1 | Durable workflow run nodes and worker-thread execution | No workflow domain or recovery store | Implement workflow definitions and lifecycle independently of one tool result; use iSH/native execution providers instead of Node worker threads | upstream `packages/workflow`; `packages/client/ui-workflow-run` |
| Background Jobs | Missing | P1 | Per-agent job registry, background tool controls, session-header Jobs list | No durable Jobs registry or Jobs header | Add durable job ownership, recovery, cancellation, result delivery, and header projection; integrate with iOS background state honestly | upstream `packages/jobs`; `packages/client/ui-jobs` |
| Agent presets | Partial | P1 | Preset registry, per-session mounted Agent plane, settings default | Per-session selection, persisted default, system/user preset registry, prompt/tool/permission composition, `/agent`, standard/minimal/Cordis presets, and an explicit unavailable Code preset are implemented | Import/edit UI for user preset manifests is still narrower than Desktop; Code Mode remains correctly unavailable until its real runtime is ported | `HarnessMobile/Core/Presets/AgentPresets.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobile/Features/Chat/SessionModelPickerView.swift`; `HarnessMobileTests/AgentPresetTests.swift`; upstream `packages/preset` and `ui-agent-preset` |
| Skills | Partial | P1 | Layered Skill registry, filesystem discovery, user invocation, and `skill` tool | On-device roots `.dsh/skills`, `.agents/skills`, and `Skills` support direct Markdown and one-level `SKILL.md` bundles, upstream-style precedence and invocation policy, a model-facing on-demand `skill` tool, `/skill-name` user invocation, and durable trajectory source records | No arbitrary external filesystem roots/watcher, native `@` reference picker, or browser Skill UI; discovery is refreshed at every model step and tool load instead | `HarnessMobile/Core/Skills/MobileSkillRegistry.swift`; `HarnessMobile/Core/Tools/SkillTools.swift`; `HarnessMobile/Core/Storage/WorkspaceStore.swift`; `HarnessMobile/App/AppModel.swift`; `HarnessMobileTests/MobileSkillRegistryTests.swift`; upstream `packages/skill` |

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

- Generic slash popup-select, confirmation, completion, and native `@`
  reference sources.
- Remaining specialized tool cards, broader compatibility fixtures, and
  physical-device performance tests.
- Real nested event production, native subagents, workflows, and Jobs. These
  are substantial runtime projects, but they are not prohibited by iOS.

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
- Trajectory and Harness Trace refresh by durable sequence cursor. Assistant
  token chunks remain available for diagnostics but do not force a SwiftUI
  timeline projection rebuild for every streamed delta.
- The plugin Host uses a pinned npm tree, disabled lifecycle scripts, and a
  credential firewall.

Remaining performance work:

1. Profile the current two-slot conflict-aware scheduler on the physical iPhone
   16 Pro. Keep tools exclusive unless their implementation explicitly declares
   concurrency safety and stable resource identities.
2. Add durable nested event production without rebuilding an entire recursive
   tree for every output byte.
3. Measure peak memory, thermal throttling, terminal scrollback, rootfs install,
   plugin install, long SSE streams, cancellation, and background expiration on
   the physical iPhone 16 Pro.
4. Add recovery tests for iSH process death, app suspension, jetsam, Host
   restart, and partially installed marketplace packages.
5. Keep model API traffic native. Do not route inference through iSH merely to
   make a plugin appear more compatible.

## Compatibility fixture reality

The fixture directory is currently much smaller than the implemented feature
surface.

| Fixture family | Status | Current files | Required expansion |
| --- | --- | --- | --- |
| Provider profiles and model discovery | Implemented | `provider-directory-v1.json`, `provider-profile-migration-v1.json`, `credential-ref-v1.json`, `openai-models-v1.json` | Add 401, malformed, missing-data, oversized, cache expiry, and protocol-specific fixtures |
| Basic Harness wire | Partial | `deepseek/harness-wire-v1.json` | Split into request header, messages, tool calls/results, queue/steer, usage, error, and compaction fixtures |
| Tool tree and scheduler | Partial | Scheduler behavior is covered in `HarnessMobileTests/AgentRuntimeTests.swift`, but there is no fixed cross-version fixture | Add real nested-child/`run_code` fixtures plus compatibility fixtures for conflict serialization, approval barriers, cancellation, completion order, deterministic commit, and truncation |
| Ask-user and plan review | Implemented | `deepseek/user-interaction-v1.json`; `HarnessMobileTests/UserInteractionCompatibilityFixtureTests.swift`; behavior coverage in `HarnessMobileTests/UserInteractionToolsTests.swift` | The fixed fixture covers multi-question single/multi-select, skipped and custom answers, exact resume output, and discuss/refuse/approve semantics; cancellation races are covered by behavior tests and can gain a fixed fixture when the cross-version wire contract requires one |
| Goal/Plan/Todo | Partial | Lifecycle, identity, persistence, and compaction behavior are covered by `WorkStateToolsTests`, `SessionStoreTests`, and `ConversationCompactorTests` | Add a fixed JSON/JSONL cross-version fixture for upstream `goal/change`/`todo/write`, including parallel in-progress todo policy |
| Skills and Agent Presets | Partial | `MobileSkillRegistryTests`, `AgentPresetTests`, and an AgentRuntime injection test cover local precedence, invocation policy, on-demand reload, session injection, and system preset composition | Add a versioned upstream Skill/preset fixture corpus, user manifest import/edit coverage, and native `@` reference-source behavior |
| Subagents, workflows, and jobs | Missing | None | Add address tree, follow-up, continue, interrupt, workflow recovery, and background job recovery fixtures |
| iSH | Missing | None | Add command, timeout, cancel, process-tree kill, UTF-8 split, output limit, mount, and network-policy fixtures |
| Cordis Host and marketplace | Partial | Swift and Node tests exist, but no cross-version compatibility fixture corpus | Add inventory/contribution revisions, stale run IDs, rollback, Client-half rejection, install recovery, and redaction fixtures |
| Background and Live Activity | Missing | Unit tests cover state machines, but no shared compatibility fixtures | Add activity projection, privacy redaction, expiration, notification, and relaunch fixtures |

Passing unit tests is necessary but does not by itself prove Desktop/Web
compatibility. Each upstream contract named above should have fixed JSON/JSONL
input and an expected Swift projection so future upstream upgrades produce an
intentional diff.

## Remaining delivery order

1. Complete slash popup-select, confirmation, completion, Cordis command
   contribution, and native `@` reference-source details that block normal
   provider and command workflows.
2. Add real nested tool-event producers for `run_code`, workflows, and future
   subagents; expand scheduler resource annotations and compatibility fixtures
   without weakening the current fail-closed concurrency policy.
3. Port durable in-process subagents with parent/child addresses, breadcrumbs,
   follow-up, continue, and interrupt.
4. Add workflow lifecycle and the durable Jobs registry/header with recovery.
5. Extend the existing versioned `dsh.nativeClient` adapter only for additional
   audited native contribution kinds. Continue rejecting arbitrary React/browser
   packages and downloaded native code.
6. Add Web, MCP, LSP, and Code Mode through proven libraries or iSH/native
   providers, with the same approval and event model as existing tools.
7. Add specialized tool cards, feedback, export, and remaining mobile tools;
   extend session badges with child-agent state when durable subagents land.
8. Expand the compatibility corpus, then run simulator, Node Host, and physical
   iPhone 16 Pro performance/background verification.

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
27.0 build `27A5237l` and exposes the iOS 27.0 iPhone 16 Pro simulator. The
system-selected command-line Xcode remains 26.6, so command-line builds and tests
must set `DEVELOPER_DIR=/Users/liulingfei/Downloads/Xcode-beta.app/Contents/Developer`.
