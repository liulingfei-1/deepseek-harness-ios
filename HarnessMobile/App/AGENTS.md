# App composition rules

- `AppModel.swift` is an `@MainActor` composition root, not a home for new transport, storage, compiler, or plugin-runtime algorithms. It is about 8,600 lines: locate a symbol with `rg -n`, then expand through relevant callers and dependencies as needed.
- Prefer a focused coordinator in `Core/` for a new domain. Keep AppModel responsible for UI state, lifecycle wiring, persistence handoff, and user-facing error projection.
- Preserve session/run ownership across every async callback; do not publish an event from an old run into the active session.
- Prompt assembly is at `currentSystemPrompt`, `currentCordisRuntimeContext`, and `systemPrompt`; keep the stable `MobileHarnessPrompt.text` prefix byte-stable unless a behavior change requires otherwise.
- Relevant tests: `AppModelModelDiscoveryTests`, `AppModelProviderProfileTests`, affected UI target tests, plus the domain test suite.
