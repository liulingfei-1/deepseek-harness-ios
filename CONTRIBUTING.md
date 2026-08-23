# Contributing to Harness Mobile

Thanks for helping improve the on-device iOS Harness runtime. This project accepts bug reports, compatibility evidence, plugin-adaptation proposals, tests, documentation, and focused implementation changes.

## Before changing code

1. Check `Vendor/`, `Dependencies/`, upstream DeepSeek Harness, and OpenMinis first. Reuse a proven upstream design whenever it fits the iOS boundary.
2. Read the nearest `AGENTS.md` before editing that module.
3. Keep the product boundary intact: model inference may use the user-configured API, but tools, plugins, and commands must execute on-device or in the embedded iSH guest.
4. Do not claim a physical-device behavior from simulator-only evidence.

## Build and verification

Use Xcode Beta and keep caches outside the repository:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --build-path /tmp/hm-build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project HarnessMobile.xcodeproj \
  -scheme HarnessMobile -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

(cd HarnessMobile/Resources/PluginHost && npm run check)
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

`HarnessISH.xcframework` has no x86_64 slice. Do not use the repository-local `.build` or `DerivedData*` as a cache.

## Pull requests

- Keep each change focused and add a regression test when fixing a bug.
- Never commit API keys, Authorization values, unredacted diagnostics, private workspace files, generated build output, or `node_modules`.
- Update `Docs/DESKTOP_PARITY_REMEDIATION.md` for any desktop-parity item: implementation state, evidence, command, result, and remaining device boundary.
- Use the following status honestly: `TODO`, `VERIFY`, `DONE`, `IOS-REPLACEMENT`, or `OUT-OF-SCOPE`. `DONE` requires the specified automated and device acceptance evidence.
- Describe the user-visible result, validation performed, and any remaining limitation in the PR body.

## Reporting a bug

Include reproducible steps, device/iOS version, app revision, provider type, foreground/background state, and a redacted `Harness-Diagnostics-*.log` when available. Do not include credentials or private data.
