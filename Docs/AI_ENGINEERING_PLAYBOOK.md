# Harness Mobile AI Engineering Playbook

This repository is large enough that the main efficiency problem is usually not model intelligence: it is feeding an agent irrelevant code, duplicate instructions, and unstable request prefixes. This playbook keeps the shared project memory small, makes changes local, and preserves Harness behavior.

## Canonical configuration

`AGENTS.md` is the source of truth for shared rules. `CLAUDE.md` imports it, and `.github/copilot-instructions.md` is a short entry point for Copilot. Do not maintain three long copies. Store personal machine choices in ignored `CLAUDE.local.md`, never in tracked instructions.

Nearest-directory `AGENTS.md` files are intentionally short and load only for the relevant module:

| Scope | Why it exists | First verification |
| --- | --- | --- |
| `HarnessMobile/App/` | UI/lifecycle composition and the AppModel boundary | affected AppModel/UI tests |
| `HarnessMobile/Core/Agent/` | ordered model loop, compaction, cancellation, caching | `AgentRuntimeTests`, `ConversationCompactorTests` |
| `HarnessMobile/Core/Plugins/` | manifest/Host/Cordis safety and compatibility | `NativeAgentPluginTests`, Host check |
| `HarnessMobileTests/` | characterization and real-device evidence rules | narrow target, then package suite |

When using Claude Code, path-scoped rules may later be added under `.claude/rules/` only for a rule that cannot fit in the relevant `AGENTS.md`. Do not add unconditional rule files: they consume context on every request.

## Standard AI change loop

1. Read root `AGENTS.md`, the nearest scoped `AGENTS.md`, the existing test, and the smallest upstream/fixture contract.
2. Search before reading: `rg -n 'TypeName|functionName|error code'`. Read a small `sed -n` window only.
3. Write a one-sentence contract: input, durable state, output/error, and required device boundary.
4. Make one reversible domain change. Do not combine a refactor, a wire change, and a UI redesign.
5. Run the narrowest relevant test. Inspect failures before changing behavior.
6. Update `Docs/DESKTOP_PARITY_REMEDIATION.md` as `TODO`, `VERIFY`, or `DONE`; only device evidence can close a device requirement.
7. Finish with `git diff --check`, the boundary audit, and the targeted/full suite required by root instructions.

For a failure report, give an AI only: error text, relevant trajectory IDs (redacted), the smallest source window, the contract test, and the specific parity row. Do not attach all logs or an 8,000-line file.

## Current code audit

### Highest-return maintainability work

| Priority | Evidence | Safe extraction order | Acceptance |
| --- | --- | --- | --- |
| P0 | `AppModel.swift` was about 8,643 lines and mixed provider, marketplace and native-plugin coordination | extract one bounded domain at a time; provider and marketplace/native lifecycle are now split, leaving session lifecycle and diagnostics as later seams | public behavior and session/run ownership unchanged |
| P0 | `AgentRuntime.swift` is about 4,534 lines and mixes loop, context, tools and trace | context policy and route-only request assembly are now isolated; tool execution and trace recording remain later seams | identical request/message/event characterization tests |
| P1 | AppModel mixes marketplace installation, native compilation and UI error projection | split the UI-owned lifecycle and Agent adapter into focused extensions over existing Core coordinators | keep the main-Agent compiler flow, install state and diagnostics ownership intact |
| P1 | several app-facing features have their own persistence/lifecycle coordination | extract session lifecycle and diagnostics coordinators one domain at a time | no callback from an old run can update the active session |
| P2 | each model request includes tool schemas, generated SDK and Skill catalog text | keep provider request economics as a separately measured product concern | tool names, permission filtering and plugin tools remain available |

Do **not** start with a blanket AppModel or AgentRuntime rewrite. First write characterization tests, extract one dependency group with unchanged API, and only then move the next group.

### Completed source-boundary work

- **2026-08-23 — Provider bundles:** `AppModel+ProviderBundles.swift` now owns provider Bundle installation and model discovery. The composition root keeps only the narrow dependency seams; the focused provider tests passed on the booted simulator.
- **2026-08-23 — Context policy:** `AgentContextPipeline.swift` now owns normalized user-instruction and append-only runtime-context snapshot rules. `AgentRuntime` still owns durable writes, event ordering, compaction, and streaming. The 62-test `AgentRuntimeTests` suite passed on the booted simulator.
- **2026-08-23 — Plugin marketplace/native lifecycle:** `AppModel+NativePluginLifecycle.swift` now owns native manifest materialization, store/runtime registration, rollback, and compilation-trace projection; `AppModel+PluginMarketplaceTool.swift` owns the conversation marketplace adapter and prepared-source handoff. Both retain the existing `PluginInstallCoordinator`, `NativeAgentPluginCompiler`, native store, and iSH Host paths rather than creating a parallel installer.
- **2026-08-23 — Request assembly:** `AgentRuntime` now isolates the two Cordis route-only request checkpoints in `AssembledStepRequest` / `assembleStepRequest`. Prompt assembly, runtime snapshots, header/context events, credentials, images, compaction, trace/checkpoint, streaming and tool execution retain their original ordered ownership.

This round deliberately stops at proven boundaries rather than turning the loop into a generic mutable request builder. Any later extraction must preserve: Cordis assembly → tail snapshot → request hooks → header/context events → credentials/images → compaction → trace/checkpoint.

## Separate concern: end-user model-request token budget

There are two different budgets that must not be confused:

- **Coding-agent context**: files, instructions, logs, diffs, and chat sent to Codex/Claude/Copilot. Nested rules, symbol-first reading, and small changes reduce this budget.
- **End-user model request**: system prompt, schemas, conversation, tool results, images, and plugin context sent to the configured provider. `ConversationTokenMeter` is a pressure estimator; provider-reported usage/cache fields remain billing truth.

Current strengths: `MobileHarnessPrompt.text` is a stable prefix; tool definitions are sorted; long tool results use spill locators; context compaction exists; and request headers are only re-recorded when changed. Preserve these properties.

Near-term instrumentation before any tool hiding:

1. Record estimated `system`, `tools`, and `messages` token buckets beside each model request in the redacted trajectory.
2. Show the three buckets in Diagnostics/Trajectory, alongside provider prompt/cache usage.
3. Add a regression test that dynamic runtime context is appended after the stable prompt and that tool ordering is deterministic.
4. Capture a real iPhone trace for text, code mode, plugin-heavy, and long-session turns.

Only after those measurements should the project consider progressive tool discovery. It must be an opt-in policy with a stable core catalog, a bounded discovery tool, explicit enablement, plugin compatibility, and a fallback to the full catalog. Removing schemas blindly saves tokens but breaks tool discovery and desktop parity.

## Prompt and cache rules

- Keep `MobileHarnessPrompt.text` deterministic and remove only exact duplication; it is a cacheable policy prefix.
- Append changing work-state, plugin context, session reference content, and skill bodies as typed deltas/snapshots after the stable prefix.
- Keep tools deterministically sorted. A schema change should be a deliberate request-header change, not incidental dictionary order.
- Do not encode API keys, raw logs, complete source archives, or full tool output into prompts. Use redacted diagnostics, workspace paths, pagination, and spill locators.
- Code mode is intentionally more expensive because it supplies its generated SDK. Measure it separately; do not weaken its only-direct-tool contract merely to reduce tokens.

## Build and proof gates

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

For an Xcode device build add `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`. Store build caches in `/tmp`, not the repository.

## First implementation backlog: coding-agent context and maintainability

1. DONE — Extract `AgentContextPipeline` from `AgentRuntime` behind the existing context/header characterization tests.
2. DONE — Split `AppModel` provider bundles plus marketplace/native lifecycle and conversation adapter, retaining the existing main-Agent compiler flow.
3. DONE — Isolate route-only request assembly inside `AgentRuntime` without broadening the Cordis request contract.
4. TODO — Extract session lifecycle or diagnostics coordination from `AppModel`, never both in one change.
5. Keep every future extraction in a small file with an explicit input/output contract and nearest-directory rules.

The optional request-token telemetry work belongs **after** these source-boundary
splits. It is useful product diagnostics, but it is not a prerequisite for
reducing the context, ambiguity, or maintenance cost of coding agents.
