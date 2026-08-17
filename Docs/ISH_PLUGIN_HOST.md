# iSH Cordis Plugin Host

The mobile plugin Host is a long-lived Node.js process inside the embedded iSH Alpine guest. It does not execute commands on a server. Model inference remains in the native provider client; provider credentials are intentionally excluded from this process.

## Runtime ownership

- Static Host files and pinned npm packages live under `/workspace/.harness-mobile/plugin-host`.
- Model-defined Cordis Packages live only in `DynamicCordisRunnerService` memory. The session ID establishes upstream Agent ownership, but the native app does not persist Package source as part of its conversation checkpoint.
- Stopping or restarting the Host process drops every dynamic definition and active Fiber. Starting the Host again restores only the pinned baseline packages and official Cordis tools.
- `define`, `run`, `stop`, and `undefine` call the published DeepSeek runner. The bridge does not implement a second lifecycle.
- The Host loads the published `@deepseek-ai/dsh-tool-cordis` namespace plugin. The model therefore uses the upstream self-inspection and lifecycle tools rather than mobile reimplementations of those tools.
- Every active Package is a real Cordis Fiber, so effects are disposed by upstream Cordis on stop, update, failure, or process exit.
- Host-half Packages may use Tools, Prompt sections/contexts/variables, Cordis services/events, and private `harness.handle` methods inside the Host process. The bundled Host publishes Tool/Prompt contributions plus active handler/service metadata. The Swift DTO/bridge maps only a fixed handler/service allowlist to native Memory, Orchestration, Agent, Sandbox and Tool checkpoints.
- Browser Client halves are rejected by both the RPC adapter and the model-facing Tool guard until a native mobile Client runner is available.

## Model-facing self modification

The Host contributes the official DSH tools to the native Agent after a successful native synchronization:

- `cordis_inspect_list`
- `cordis_inspect_query`
- `cordis_inspect_self`
- `cordis_define`
- `cordis_run`
- `cordis_stop`
- `cordis_undefine`

The official `tool:cordis` prompt section is preserved. A second mobile policy section states that this deployment has no browser Client runner, has no desktop Skill registry mounted inside the minimal Host, keeps definitions only in process memory, and never accepts provider credentials. This policy prevents the upstream dual-plane tool from entering a Client-pending state that the native app cannot complete. The model uses Inspect as the exact contract for the services actually mounted on the phone.

Lifecycle actions issued through `AppModel` synchronize inventory and contributions immediately. After a successful model-facing `cordis_define`, `cordis_run`, `cordis_stop`, or `cordis_undefine`, `ISHHostedCordisTool` waits for the aggregate native bridge to synchronize before it returns control to the next Agent step. Ordinary hosted tools do not trigger a redundant refresh.

Host-private methods registered with `harness.handle` and callable methods on plugin-owned Cordis services are dynamically callable through the `invoke` RPC. Both targets require the session ID, plugin ID and exact active plugin run ID. If the Host advertises a handler or service method with a recognized checkpoint identity, `ISHPluginHostDynamicHarnessBridge` attaches it to that typed native boundary. Unknown names remain management RPC endpoints; they do not automatically become model tools or enter the native checkpoint chain.

## Wire protocol

stdin and stdout use newline-delimited JSON-RPC 2.0. stdout is reserved for protocol frames. Cordis and Package console output is redirected to stderr.

Supported methods:

| Method | Purpose |
| --- | --- |
| `ping` | Protocol, Host, and pinned package versions |
| `inventory` | Source-free dynamic Plugin and Package lifecycle state |
| `define` | Define an immutable in-memory Package version |
| `run` | Start or update a Host-only Package through `DynamicCordisRunnerService` |
| `stop` | Dispose the active Fiber but keep Package definitions |
| `undefine` | Stop and forget a Plugin and every Package version |
| `contributions` | Current Tool/Prompt snapshot and active handler/service directory |
| `invoke` | Execute a dynamic Tool, registered `harness.handle` method, or plugin-owned service method |
| `settings/describe` | Secret-redacted official Settings namespace/schema/layer/revision snapshot |
| `settings/mutate` | Revision-checked path set/delete operations |
| `settings/update` | Revision-checked official namespace update |
| `settings/replace` | Revision-checked official namespace replacement |

The JSON-RPC lifecycle methods remain available for native management UI and recovery. They are not alternate implementations of the model-facing Cordis tools; both paths delegate to the same upstream `DynamicCordisRunnerService` registry.

The bundled dispatcher implements `tool`, `handler`, and `service` invoke targets. `contributions` exports active handlers and plugin-owned service methods with their plugin and run identities. Handler invocation rejects a missing, stopped, or stale activation. Service invocation additionally requires the exact active Fiber, verifies that the requested service belongs to that Fiber, and accepts only a callable method discovered from the service implementation. Handler and service return values must be representable as lossless JSON before they cross the process boundary.

This callable directory is intentionally broader than automatic Agent integration. Only recognized handler names and service-name/method pairs are adapted to the compiled native checkpoint allowlist. Unrecognized handlers and services remain available to explicit management RPC callers but are not inserted into the model tool catalog or the native Agent loop. Cordis events and all other Host-only effects stay inside the iSH Host process.

### Native checkpoint coverage

The typed iSH bridge currently forwards these waterfall checkpoints:

- `memory/recall`, `orchestration/pre-step`, and `agent/pre-step`;
- `orchestration/request` and `agent/request`;
- `orchestration/request-error` and `agent/request-error`;
- `sandbox/pre-execute`, `tools/pre-execute`, `tools/execute`, and `tools/post-execute`.

It also forwards `memory/record`, `orchestration/turn-stopping`, and `agent/turn-stopping`, plus the official read-only lifecycle events `agent/created`, `agent/disposed`, `agent/status`, `agent/session-start`, `agent/error`, `tools/result`, and `tools/change`. Payloads expose only fields actually owned by the corresponding Swift type. In particular, `memory/record` has no invented agent or turn coordinate, while turn-stopping payloads include their agent, run, turn, step, and messages.

The following upstream surfaces are deliberately not advertised as Host-half compatible:

- `llm/stream` is an `AsyncIterable<StreamChunk>` waterfall. A one-response JSON-RPC invocation cannot preserve incremental `next()`, per-chunk yield, cancellation, or backpressure, so the bridge does not invent a lookalike stream protocol. Native Swift plugins can still intercept the in-process `llm/stream` checkpoint.
- `tools/code-dispatch-log` belongs to real `run_code` child dispatch. The mobile Agent has no production `run_code` producer yet, so forwarding the event alone would expose an inert capability.
- `agent/inbox/inserted`, `agent/inbox/claimed`, and `agent/inbox/discarded` are not yet represented by the native Agent inbox.

The maximum Swift-to-iSH request frame is 512 KiB, below the persistent bridge's 1 MiB pending stdin bound. Responses are framed up to 4 MiB.

### Plugin settings

The Host mounts the published `@deepseek-ai/dsh-settings` and `@deepseek-ai/dsh-settings-file` providers. The user document is `/workspace/.harness-mobile/settings.yaml`; the file provider watches it and publishes official document revisions, so compatible plugin settings can update without restarting the native Agent.

`settings/describe` uses the official secret-redacted descriptor and projects the upstream schema into a bounded wire form. Swift preserves the upstream defaults/base/user layers and treats an explicit value equal to the default as an override. Editing is staged locally; Save emits one batch of path mutations with `expectedRevision`. A revision mismatch returns `-32012` with `reason: settings-conflict`, and the UI keeps the draft so it can be rebased onto the new revision.

Secret schema nodes and credential-shaped keys or values never cross the Swift/iSH wire. Secret fields show only configured/not-configured state and cannot be written through these RPC methods. Transform, lazy, recursive, lossy union, and secret-bearing dynamic collection schemas fail closed; arrays and dictionaries that cannot be edited losslessly remain visible but read-only.

## Hot update and fault containment

- `run` accepts upstream `run` and `update` modes. Cordis owns the active Fiber and disposes its effects during stop, update, failure and process exit.
- The published dynamic runner retracts the old Fiber before an `update` starts the new Package and does not automatically reactivate the old Fiber when startup fails. The old Package definition remains addressable and can be run again, but this is recovery, not an atomic rollback guarantee.
- Each synchronized Host revision is represented by the native `ish.dynamic-contributions` plugin. Updating contributions hot-replaces that bridge without restarting the native Agent.
- Successful official Cordis lifecycle Tool calls synchronize that revision before the next model step, so newly added or removed Tool/Prompt contributions and handler/service bindings do not require a manual Plugin-screen refresh.
- Native plugin effects are tied to a plugin generation. Stale asynchronous work cannot register into a newer generation, and an activation failure removes every partial Tool, Prompt, service, event and checkpoint effect owned by that generation.
- `CordisPluginRuntime.replace` restores the previous active native factory when a replacement cannot activate. Dependants disconnect and reconnect through service reconciliation.
- If the iSH process, JSON-RPC framing, credential firewall or bridge synchronization fails, `AppModel` stops the Host, removes the aggregate bridge and reports the Host as failed. Stale dynamic tools are not left registered in the native Agent.
- Service isolation labels apply to the native Cordis runtime. The iSH Host remains one long-lived process and is not a separate OS sandbox per Package.
- The dynamic harness adapter is allowlisted and typed. Optional memory/orchestration and observer failures fall back to the native chain, hosted Tool execution failures become Tool errors, and an unavailable hosted Sandbox policy denies execution.

## Checkpoint trajectory and redaction

Native Cordis waterfall execution records `checkpointStarted`, `checkpointFinished`, and `checkpointFailed` trajectory events. Agent-loop calls carry the run ID, turn and step. Each event also records the exact ordered interceptor chain, including native plugin ID, generation, label, scope and prepend order; labels for iSH adapters retain the Host plugin/run endpoint identity.

Structured checkpoint inputs and successful outputs are projected into bounded JSON before entering the trajectory ledger. Strings, arrays, objects and nesting depth are limited, and credential-shaped fields such as `apiKey`, `authorization`, `accessToken`, `refreshToken`, `secretKey`, `clientSecret`, and `password` are replaced with `<redacted>`. DeepSeek/OpenAI-style `sk-...` values and bearer tokens are also removed from free-form strings. `HarnessMobileTests/CordisPluginRuntimeTests.swift` covers the generation chain, structured checkpoint projection and credential redaction.

These waterfall checkpoints are runtime extension boundaries. They are separate from the persisted conversation checkpoint used for session recovery; dynamic Packages, handlers, services and Fibers are not restored after the Host process exits.

## Credential boundary

The native transport passes an explicit environment allowlist. It never forwards the app process environment or provider configuration. Swift and JavaScript both reject:

- credential-shaped keys such as `apiKey`, `authorization`, `accessToken`, or `clientSecret`;
- DeepSeek/OpenAI-style `sk-...` values;
- bearer authorization values.

This means dynamic tools cannot ask the native layer to pass the model provider key into iSH. A plugin that needs network credentials requires a separate, explicit capability design rather than reusing model credentials.

## Installation and mirrors

`ISHPluginHostInstaller.installIfNeeded` stages the bundled resources, ensures guest networking remains available for the installation lease, and runs `install.sh` inside iSH. The script installs Alpine Node.js/npm and then runs `npm ci` with lifecycle scripts disabled.

`package.json` pins every direct DeepSeek package to one version, including `@deepseek-ai/dsh-tool-cordis`. `package-lock.json` locks the full transitive tree and package integrity. `manifest.json` records the audited top-level versions, integrity values, the primary registry, and optional mirror addresses.

Only this bundled, version-locked npm tree is installed. Model-defined Host-half Package source is evaluated as process-memory code by the published Cordis runner; it is not a persistent marketplace installation and cannot request arbitrary npm packages.

The installer accepts an HTTPS registry and mirror URL. It tries the selected primary registry first and retries the mirror only when the primary download fails. npm cache data is kept in `/tmp` and removed after installation.

## Native wiring

The minimum AppModel ownership is one installer and one client for the shared workspace:

```swift
let installation = try await ISHPluginHostInstaller.shared.installIfNeeded(
    workspaceURL: workspaceURL,
    mirrorURL: URL(string: "https://registry.npmmirror.com")
)
let transport = ISHPersistentPluginHostTransport(workspaceURL: workspaceURL)
let client = ISHPluginHostClient(transport: transport)
try await client.start()
_ = try await client.ping()
let current = try await client.contributions(sessionId: sessionID)
```

`AppModel` retains `ISHPluginHostClient`, stops it during explicit teardown, and synchronizes `inventory` plus `contributions` after App-owned or official model-facing lifecycle calls. `ISHPluginHostCordisBridge` converts Tool/Prompt DTOs and allowlisted handler/service metadata into native Cordis contributions, so `AgentRuntime` does not know about `ISHShellProcess` or NDJSON framing.

## Upgrade procedure

1. Select one published DSH release train and exact Cordis version.
2. Update exact versions in `package.json`.
3. Regenerate `package-lock.json` with npm and review all transitive changes.
4. Update `manifest.json` versions and integrity fields from the lockfile.
5. Increment `hostVersion` when Host behavior, bundled resources, `package.json`, or `package-lock.json` changes. Increment `protocolVersion` for a breaking JSON-RPC shape or semantic change and update the Swift DTO/client in the same change.
6. Run Swift protocol/runtime tests and the Node Host smoke test before staging on the phone.
7. Install on the iPhone and verify first install, mirror fallback, restart loss of dynamic definitions, lifecycle operations, contribution refresh, Settings persistence/watch/revision conflicts, cancellation and Host failure cleanup.

The install stamp includes Host and protocol versions. A changed stamp causes `npm ci` to reconcile the on-phone dependency tree; dynamic Package definitions are intentionally not migrated because they are process-memory-only.
