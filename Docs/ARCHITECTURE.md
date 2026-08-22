# Architecture and execution boundary

## Runtime shape

```text
SwiftUI
  -> AppModel (@MainActor)
      -> AgentRuntime (actor)
          -> OpenAICompatibleClient -> configured model HTTPS API
          -> CordisPluginRuntime
              -> CordisAgentServices
                  -> compiled native Tool and Prompt contributions
                  -> Memory / Orchestration / Sandbox / LLM / Tool checkpoints
              -> ISHPluginHostCordisBridge
                  -> persistent Node.js/Cordis Host inside iSH
                      -> process-memory Host-half Packages
                      -> dynamic Tool/Prompt contributions and handler/service directory
                      -> allowlisted handler/service checkpoint adapters
                      -> official file-backed Settings namespaces and watcher
          -> LocalToolRegistry (no-plugin fallback)
              -> shell_execute -> embedded OpenMinis/iSH ARM64 Alpine
              -> workspace / OCR / device capabilities
      -> Keychain / local session snapshot / app-private workspace
      -> Continued Processing / ActivityKit / local completion notification
```

Only `OpenAICompatibleClient.swift` owns native model-provider networking. Local tools cannot call arbitrary native host URLs, invoke selectors by name, dynamically link downloaded machine code, or reach a remote executor. `shell_execute` and the Cordis Plugin Host start Linux guest processes only through the pinned in-process HarnessISH boundary. Guest networking defaults to enabled inside the on-device iSH sandbox and can be disabled by the user; this never introduces a remote executor. `Scripts/audit-no-remote-execution.sh` enforces the native boundary during every Xcode build.

## Why Node is isolated inside iSH

The reviewed DeepSeek Harness revision targets Node and its complete desktop runtime depends on facilities including `async_hooks`, filesystem providers, SQLite, workers, subprocesses and desktop sandbox implementations. JavaScriptCore on iOS is not a Node runtime, and a partial native shim would not preserve its async context or security properties.

The app therefore keeps the primary Agent, provider client, approval policy, storage and mobile UI in Swift, while installing a minimal Node.js/Cordis Host inside the ARM64 iSH Alpine guest. The Cordis npm dependency tree is pinned by `package-lock.json`; the Alpine `nodejs/npm` packages remain part of the guest distribution. The Host implements the published Cordis Host-half lifecycle and never receives provider credentials. It is not the complete desktop Harness runtime.

Swift owns the durable and security-sensitive semantics:

- ordered model turns and local tool-result round trips;
- assistant/tool message history;
- DeepSeek reasoning replay rules;
- tool-call aggregation by stream index;
- bounded loop, output and tool execution;
- local capability registry and user approval;
- session checkpoints, continued-processing recovery and ActivityKit projection;
- typed Cordis services, events and Agent Loop waterfalls.

The iSH Host adds process-memory Host-half JavaScript Packages, official Cordis inspection/lifecycle tools, dynamic Tool/Prompt contributions, an active handler/service directory, and official file-backed Settings namespaces without importing desktop execution providers or a browser Client runner. Its dispatcher can invoke Tools, private handlers and plugin-owned service methods. The Swift protocol and bridge adapt only explicitly advertised, recognized handler/service identities into a fixed Memory, Orchestration, Agent, Sandbox and Tool checkpoint allowlist; every other method remains an explicit management RPC endpoint and is never attached to the native loop or model tool catalog automatically.

Plugin settings are persisted by upstream `@deepseek-ai/dsh-settings-file` at `/workspace/.harness-mobile/settings.yaml`. Swift receives only redacted namespace descriptors and writes through revision-checked official Settings operations. Provider credentials remain native Keychain data and are never copied into this document or reconstructed from a redacted snapshot.

Conversation checkpoints are durable session snapshots. Cordis waterfall checkpoints are typed runtime extension calls and trajectory boundaries; they do not persist or restore Host Package source, handlers, services or Fibers.

## Data flow

The API request can contain the user prompt, prior conversation, system prompt, registered tool schemas, and approved textual tool results. The API Key is read from Keychain immediately before the request and is never written into the conversation snapshot, UserDefaults, tool registry, OCR workspace or logs.

Camera/photo bytes are staged in the app container. Vision performs OCR locally; only the resulting text can become an approved model tool result.

## Guardrails

- HTTPS-only endpoint validation; user info, query and fragment are rejected.
- Redirects are accepted only within the same HTTPS origin and port.
- Ephemeral URLSession without cookies, credential storage or URL cache.
- 4 MiB request, 1 MiB SSE event/turn, 64 KiB arguments, 128 KiB result and 32-call limits.
- Native tools come from the compiled catalog. Dynamic tools can enter the Agent only through validated Cordis registrations and the iSH bridge; hosted tools are classified as side effects and remain subject to permission mode, approval and the credential firewall.
- The personal sideload build records a device-wide local-tool grant without
  repeated Harness prompts; iOS privacy authorization and Cordis checkpoint
  guards remain independent.
- Workspace paths are relative, canonicalized, sandbox-contained and checked against symlink escapes.
- Keychain accessibility is `WhenUnlockedThisDeviceOnly`; local session/workspace writes use complete file protection.
- Streaming partial text is UI-only until a complete assistant turn is committed.
- Plugin effects are generation-owned. Failed activation retracts partial contributions, dependants return to pending, and active native replacements roll back to the previous factory when activation fails.
- Plugin Host JSON-RPC rejects credential-shaped keys and values on both request and response paths. Handler/service results must be lossless JSON, and invocation is bound to the requested session, exact active plugin run and owning Fiber. Dynamic definitions remain process-memory-only.
- Plugin Settings reads are secret-redacted. Writes require `expectedRevision`, operate on explicit paths, and fail closed for secret paths or schema constructs the native form cannot preserve losslessly.
- Checkpoint trajectory events retain run/turn/step and the ordered plugin generation chain. Structured inputs and outputs are bounded and redacted before storage, including credential-shaped fields, bearer values and `sk-...` strings.
- Host request hooks may change bounded model/loop settings but cannot change provider identity or Base URL. An unavailable hosted Sandbox policy fails closed; optional memory/orchestration hooks and event observers are isolated so a stopped contribution does not take down the native Agent.

## Deliberately absent

- Remote Executor, E2B, MCP, server-hosted execution tools and server scheduler.
- Host-process execution, LSP, and a persistent interactive PTY UI. Linux commands and installed guest runtimes execute inside iSH.
- Browser Client-half Cordis Packages, desktop worker-thread workflows/jobs, and desktop Skill registry integration. Mobile subagents are implemented as durable local sessions; optional Codex/Claude Code bundles invoke only fixed CLIs inside iSH.
- General web/HTTP tool, downloaded Swift/native code and unrestricted native dynamic loading. The community marketplace installs validated Host-half JavaScript packages only inside the on-device iSH Cordis process; Browser Client-half packages, native addons, unsafe patches and archive traversal are rejected. Repository-internal ZIP symlinks are resolved inside the selected source and copied as ordinary files; escaping, missing or cyclic links remain rejected. npm lifecycle scripts are disabled.
- Local LLM weights or model-image downloads.
