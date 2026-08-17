# Native Client Plugin Sidecars

Harness Mobile supports a declarative iOS sidecar for community Cordis plugins. The sidecar lets a running Host plugin contribute native inspectors, links into the official settings editor, and slash commands without loading React, browser JavaScript, downloaded Swift, or native machine code.

This is the first native Client-half protocol. It is intentionally smaller than the desktop `dsh.client` runtime, but it is dynamically installable, replaceable, disposable, and rollback-aware.

## Package Declaration

Declare the sidecar independently from `dsh.client` in `package.json`:

```json
{
  "dsh": {
    "bundle": {
      "patch": "./cordis.patch.yml"
    },
    "nativeClient": {
      "schemaVersion": 1,
      "platform": "ios-native",
      "manifest": "./native-client.json",
      "inject": [],
      "immediately": false
    }
  }
}
```

`manifest` must remain inside the package directory. Unknown fields, unsupported versions, duplicate injections, and malformed service names fail installation. A package may also declare `dsh.client`, but iOS ignores that Web Client entry and only installs the package when the independent native sidecar validates successfully.

## Manifest

```json
{
  "schemaVersion": 1,
  "minimumRuntime": 1,
  "contributions": {
    "inspectors": [
      {
        "id": "status",
        "title": "Status",
        "description": "Read the active Host service state.",
        "order": 10,
        "renderer": "keyValue",
        "endpoint": "status"
      }
    ],
    "settings": [
      {
        "id": "settings",
        "title": "Plugin Settings",
        "namespace": "example-plugin",
        "order": 20
      }
    ],
    "commands": [
      {
        "name": "example_status",
        "description": "Invoke the existing Host tool.",
        "inputHint": "<query>",
        "order": 30,
        "action": {
          "kind": "hostTool",
          "name": "example_status_tool",
          "arguments": {},
          "inputKey": "query"
        }
      }
    ]
  },
  "endpoints": [
    {
      "id": "status",
      "kind": "hostService",
      "entry": "example-plugin",
      "service": "exampleInspector",
      "method": "status",
      "readOnly": true
    }
  ],
  "permissions": [
    "host.service:exampleInspector.status",
    "host.tool:example_status_tool",
    "settings.read:example-plugin",
    "ui.command",
    "ui.inspector",
    "ui.settings-link"
  ]
}
```

The manifest must contain at least one contribution. IDs and command names must be stable because the native UI and command registry use them as identity across updates.

### Inspectors

An inspector renders a bounded JSON result as native key/value rows or Markdown. Its endpoint must refer to a non-group Loader entry in the same plugin bundle and to an existing plugin-owned Cordis service method. Every endpoint is read-only and every endpoint must be exposed by an inspector.

Supported renderers:

- `keyValue`
- `markdown`

### Settings Links

A settings contribution opens the same native schema editor used by the Host's official `ctx.settings` namespaces. The namespace must already be registered by the running Host plugin. Schema validation, drafts, save/discard, revision conflicts, read-only fallback, and secret status therefore remain centralized in one editor.

The sidecar only links to a namespace. It cannot supply a second settings implementation or read secret values.

### Commands

A command registers a native slash command and invokes an existing Host tool. `inputHint` and `action.inputKey` must either both be present or both be absent. Static `arguments` must be JSON and are limited to 16 KiB.

The sidecar cannot register executable Swift code. The command action is only a typed reference to a tool already provided by the active Host plugin.

## Permissions

Permissions are exact declarations, not optional grants. The manifest must list every capability implied by its contributions and no unused capability:

- `ui.inspector`
- `ui.settings-link`
- `ui.command`
- `host.service:<service>.<method>`
- `host.tool:<tool>`
- `settings.read:<namespace>`

Installation fails closed when permissions are missing, duplicated, unsupported, or broader than the declaration. Credential-shaped field names and values are rejected in the manifest, command arguments, endpoint requests, and endpoint responses. API keys stay in the native credential store and model networking path; they never enter the Plugin Host.

## Lifecycle And Rollback

1. Installation validates the ZIP, package, Cordis patch, native declaration, native manifest, exact permissions, and dependency tree before publishing a registry record. New plugins remain disabled by default.
2. Enabling the plugin creates its Loader group in the on-device iSH Host. The Host assigns a monotonically increasing `activationGeneration` and publishes the normalized native directory.
3. Swift validates the directory again, then maps each plugin to an isolated `ish.native-client.<plugin-id>` Cordis plugin generation. Commands and UI contributions are registered as disposable effects.
4. Replacement activates a new Cordis definition. If validation or activation fails, Cordis keeps the previous active definition and its contributions.
5. Disable, uninstall, or successful replacement disposes command registrations and registry entries owned by the old activation.

Endpoint calls include the exact `activationGeneration`. The Host rejects calls from stale screens or tasks after disable, reload, update, or rollback. Duplicate plugin IDs in a directory fail closed and do not remove or replace the currently active generation.

The generation is restricted to JavaScript's safe integer range on both sides of the RPC boundary so its identity cannot change during JSON encoding.

## Current Limits

- No React components, browser services, themes, arbitrary desktop slots, or Web Client execution.
- No downloaded Swift, dynamic frameworks, native addons, or other machine code.
- Native service endpoints are read-only and must belong to the exact active Loader generation.
- Native commands can invoke existing Host tools only.
- Native settings contributions reuse registered Host namespaces only.
- Native UI declarations are currently package-backed. Arbitrary in-memory generation of new native contribution schemas is not yet exposed as an Agent tool.
- Schema version 1 does not provide arbitrary custom SwiftUI renderers. Add new contribution kinds through a future versioned runtime instead of weakening validation.

These constraints preserve dynamic install, hot replacement, rollback, and local fault isolation while keeping all command execution inside the phone's iSH sandbox and all iOS UI inside audited native code.

## Upgrade Rules

- Keep `schemaVersion` and `minimumRuntime` explicit. Do not reinterpret an existing field in place.
- Add capabilities through a new runtime/schema version with dual Host and Swift validation.
- Preserve stable plugin, contribution, endpoint, namespace, and command IDs across compatible releases.
- Test installation, enable/disable, successful replacement, failed replacement rollback, stale-generation rejection, credential rejection, and disposal.
- Run `HarnessMobileTests/ISHPluginHostNodeSmoke.mjs`, `ISHNativeClientTests`, `ISHPluginHostTests`, the no-remote-execution audit, and an Xcode build after protocol changes.
