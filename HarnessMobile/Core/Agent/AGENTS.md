# Agent runtime rules

- `AgentRuntime.swift` owns the ordered local Agent loop. Preserve durable message identity, cancellation, tool transaction balance, and request-header/trajectory semantics.
- It is about 4,500 lines. Start with `rg -n` for the run-loop checkpoint or helper, then inspect the relevant flow; expand to the full file when necessary for a correct change.
- Keep stable system prompt and tool ordering deterministic for provider prompt caching. Dynamic context belongs in runtime snapshots, not by mutating the stable base prompt.
- Do not add artificial total-step, total-tool-call, or output-token limits. Provider-declared output capacity is authoritative.
- Tool-result truncation must retain a readable spill locator; incomplete tool JSON must never execute.
- First tests: `AgentRuntimeTests`, `ConversationCompactorTests`, the matching wire tests, then `swift test --build-path /tmp/hm-build`.
