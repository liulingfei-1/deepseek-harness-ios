# Security policy

Harness Mobile is a personal sideload/development project. It handles user-provided model credentials, private workspaces, on-device tools, and untrusted plugin source, so security reports deserve private handling.

## Report privately

Do **not** open a public issue for a suspected credential leak, sandbox escape, path escape, arbitrary native-code execution, unauthorised model request, or data disclosure. Contact the repository owner privately through the GitHub security-advisory channel when it is enabled, or through the contact method on the repository profile.

Please include a minimal reproduction, affected revision, impact, and any safe proof. Remove API keys, Authorization headers, personal files, exact locations, and unredacted diagnostic logs.

## Boundaries worth testing

- Provider credentials must remain in native Keychain and never enter iSH, plugin files, prompts, traces, or exported diagnostics.
- Linux commands and Host-half plugin JavaScript must stay inside the embedded, on-device iSH guest.
- Workspace paths must remain inside the app-private workspace, including through symlinks and archive extraction.
- Downloaded Swift code, dynamic frameworks, native addons, and arbitrary machine code are not valid plugin payloads.
- User-approved data sent to a model API must be visible in the local trajectory/approval surface and follow the selected provider route.

No security guarantee is implied by this policy. Use a separate, limited, revocable API key for testing.
