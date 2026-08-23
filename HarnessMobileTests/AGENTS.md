# Test rules

- Add or update a characterization test before moving behavior out of a large production file. Tests must cover the observable contract, not private implementation details.
- Keep test credentials synthetic. Diagnostics assertions must verify redaction rather than injecting real keys.
- Use a focused test filter while iterating; before handoff run `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build` when the package target covers the change.
- A passing simulator/unit test is not evidence for iPhone-only behavior such as iSH, photos, background execution, permissions, or plugin installation.
