# Upgrading upstream projects

The port is intentionally split into five layers so that an upstream release
does not require another full rewrite:

1. Unmodified upstream source checkouts under `Vendor/UpstreamSources`.
2. Project patches under `Vendor/**/patches`.
3. Stable Swift protocols and adapters under `HarnessMobile/Core`.
4. Compatibility fixtures and tests that describe required Harness behavior.
5. The pinned on-device Plugin Host under `HarnessMobile/Resources/PluginHost`,
   including its JavaScript entrypoint, npm lockfile and install manifest.

`Dependencies/upstreams.lock.json` pins every source revision, nested Git link,
toolchain version, and the Alpine rootfs SHA-256. Locally built frameworks are
recorded separately in `Dependencies/artifacts.lock.json`; local patch hashes
and their exact base commits are kept in `Dependencies/patches.lock.json`.

The Plugin Host has a separate lock domain. `package.json` pins direct Cordis/DSH
versions, `package-lock.json` pins the transitive npm tree and integrity values,
and `manifest.json` records the audited packages plus Host/protocol versions.
These three files must be reviewed and updated together.

The current mobile Plugin Host is on DeepSeek Harness `v0.1.1-rc.2`. Native
adapters live outside the Host package tree: multimodal image parts are
serialized by `ChatAPIModels`/`OpenAICompatibleClient`, while Codex and Claude
Code Profile Bundles remain local-iSH descriptors until their provider
protocols are ported. Updating the npm tree must not silently turn either
bundle into a remote executor.

## Normal update workflow

Update only one component per change:

```sh
./Scripts/update-upstream.sh openminis <tag-or-commit>
./Scripts/fetch-upstreams.sh openminis
```

Then:

1. Inspect upstream release notes and license changes.
2. Replay the component's patch series without editing the checkout directly.
3. Rebuild XCFrameworks and refresh their SHA-256 entries.
4. Run `./Scripts/regenerate-project.sh`. It downloads the pinned official
   XcodeGen archive, verifies its SHA-256, and regenerates
   `HarnessMobile.xcodeproj` from `project.yml`.
5. Run `./Scripts/upgrade-check.sh`.
6. Build both `generic/platform=iOS` and the iPhone 16 Pro simulator.
7. When the change touches Plugin Host resources or Cordis behavior, run the
   Node Host smoke test and the focused Swift plugin/runtime tests.
8. Run a short real-device terminal, cancellation, background, Plugin Host,
   lifecycle, failure-cleanup and thermal smoke test before accepting the new
   lock.

Do not update DeepSeek Harness, OpenMinis, iSH, and Alpine in one batch. A
single-component update keeps protocol regressions and patch conflicts easy to
identify.

`./Scripts/upgrade-check.sh` currently runs upstream/artifact verification, the
native execution-boundary audit, and `swift test`. It does not build either Xcode
destination, run the Node Host smoke test, install the iSH npm tree on a phone,
or perform real-device background/thermal validation. Those are separate
acceptance steps and must not be inferred from the script's success message.

## Plugin Host update workflow

Keep Plugin Host updates separate from OpenMinis/iSH framework updates:

1. Select one compatible published DSH release train and exact Cordis version.
2. Update exact versions in `HarnessMobile/Resources/PluginHost/package.json`.
3. Regenerate `package-lock.json` with the supported Node/npm toolchain and
   review every transitive package, lifecycle script and integrity change.
4. Copy the reviewed top-level versions and integrity values into
   `manifest.json`; do not treat the manifest as a replacement for the lockfile.
5. Increment `hostVersion` for any Host resource or dependency-tree change so
   the on-phone install stamp forces `npm ci` reconciliation.
6. Increment `protocolVersion` for breaking JSON-RPC fields, limits or semantics.
   Update `ISHPluginHostProtocol.swift`, client/transport tests and Host smoke
   fixtures in the same change. Backward-compatible optional response fields
   must decode with explicit defaults.
7. Run `node --check` for `host.mjs`, the Node Host smoke test,
   `ISHPluginHostTests`, `CordisPluginRuntimeTests`,
   `CordisAgentServicesTests`, and the AgentRuntime plugin tests.
8. Verify on the iPhone that install networking is restored to its prior state,
   provider credentials never enter the Host, Client halves remain rejected,
   and stopping the Host removes all process-memory definitions.

## Compatibility contracts

The compatibility suite protects behavior rather than implementation details:

- DeepSeek thinking and `reasoning_content` replay around tool calls.
- Streaming tool-call aggregation by index.
- Complete assistant/tool transaction persistence and compaction.
- Provider model discovery and cached catalog schema migration.
- Shell approval, cancellation, bounded output, and process-group cleanup.
- iSH guest network policy, defaulting to enabled while retaining a user-controlled offline switch.
- Persistent conversation checkpoint migration and continued-processing
  recovery.
- Cordis service dependency/isolation semantics, generation-owned effects,
  failure cleanup, hot replacement rollback and dependant reconciliation.
- Agent Loop checkpoint names and typed contracts for Memory, Orchestration,
  Sandbox, LLM and Tool interception.
- Plugin Host JSON-RPC framing/limits, credential firewall, Host-only lifecycle,
  Tool/Prompt/handler/service contribution DTOs, post-lifecycle synchronization,
  exact package versions and Node smoke behavior.
- Tool, handler and service invoke targets, including exact active-run/Fiber
  ownership, stale-run rejection, callable service discovery and lossless JSON
  results. The bundled Host exporter/dispatcher and Node smoke fixture must
  exercise both the contribution metadata and invocation lifecycle.
- The handler/service checkpoint allowlist, provider-route mutation firewall,
  per-boundary failure policy, ordered plugin-generation trajectory chain and
  checkpoint input/output redaction. Swift runtime tests must cover these typed
  adapters and ensure credential-shaped content never enters trajectory data.
- Official plugin Settings namespaces, redacted schema/layer descriptors,
  revision-checked path writes, conflict mapping, watcher shutdown, and the
  native staged draft/reset/rebase semantics. The Node smoke fixture must cover
  persistence, stale revisions, schema fail-closed behavior, and secret refusal.
- The iSH allowlist must remain explicit about unsupported semantics. Do not
  expose `llm/stream` through a single-response JSON-RPC shim. The native
  `run_code` producer owns `tools/code-dispatch-log`; the Host must not expose
  that event as a standalone capability. Track upstream Agent inbox events
  separately from checkpoints already emitted by the native loop.
- Keep plugin settings on the upstream `dsh-settings` and `dsh-settings-file`
  contracts. Every wire read must stay secret-redacted; writes must carry
  `expectedRevision`, and redacted configuration surfaces must use path mutation
  so unchanged secrets cannot be deleted by a reconstructed replacement document.
- Treat official dynamic `run(mode: "update")` as retract-then-start, not an
  atomic rollback. A failed start may reactivate the retained old Package via
  a separate official `run`, and tests/documentation must not claim otherwise.

Cordis waterfall checkpoints are runtime extension APIs, not persisted dynamic
Package snapshots. Renaming a checkpoint or changing its input/output type is a
plugin protocol break and requires fixture/test updates. Conversation snapshot
schema changes instead require decode compatibility or an explicit migration;
do not conflate the two forms of "checkpoint".

When upstream behavior changes intentionally, update the fixture and the port
in the same change and explain the compatibility decision in
`Docs/DESKTOP_PARITY.md`.

## Patch policy

- Prefer a Swift adapter over a source patch when the boundary can remain
  external.
- Keep each unavoidable patch small and single-purpose.
- Name patches in deterministic application order (`0001-...patch`).
- Include the upstream commit in the patch header or companion README.
- Never patch downloaded source silently during an Xcode build.
- Fail closed if a patch, rootfs, or linked binary hash does not match.

The App Store is not the target, but GPL notices, corresponding source, and
reproducible build information remain part of the private-device build.
