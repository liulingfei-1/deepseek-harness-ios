# Plugin and Cordis rules

- Reuse DeepSeek Harness/Cordis and OpenMinis contracts before inventing a mobile substitute. Keep source compatibility claims explicit.
- Native plugins are declarative manifests executed by signed Swift. Host-half JavaScript runs only in embedded iSH. Never dynamically load downloaded Swift or machine code, or expose provider credentials to plugins. Under D-010, Browser/React client-half is an implementation gap to verify against the existing WKWebView backend, not a blanket platform prohibition; this does not claim it is already integrated.
- Preserve generation ownership, rollback, dependency reconnection, bounded/redacted diagnostics, and stable session/run attribution.
- Plugin compiler changes must update the manifest schema, validator, repair facts, prompt, and `NativeAgentPluginTests` together.
- For Host changes run `cd HarnessMobile/Resources/PluginHost && npm run check`; run `./Scripts/audit-no-remote-execution.sh` before handoff.
