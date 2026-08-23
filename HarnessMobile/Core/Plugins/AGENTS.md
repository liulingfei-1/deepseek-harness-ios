# Plugin and Cordis rules

- Reuse DeepSeek Harness/Cordis and OpenMinis contracts before inventing a mobile substitute. Keep source compatibility claims explicit.
- Native plugins are declarative manifests executed by signed Swift. Host-half JavaScript runs only in embedded iSH. Never dynamically load downloaded Swift, machine code, browser Client packages, or provider credentials.
- Preserve generation ownership, rollback, dependency reconnection, bounded/redacted diagnostics, and stable session/run attribution.
- Plugin compiler changes must update the manifest schema, validator, repair facts, prompt, and `NativeAgentPluginTests` together.
- For Host changes run `cd HarnessMobile/Resources/PluginHost && npm run check`; run `./Scripts/audit-no-remote-execution.sh` before handoff.
