# iPhone native capability matrix

This matrix separates Harness approval from iOS authorization. The personal
sideload build records a device-wide local-tool grant without repeated Harness
prompts. iOS still owns its
privacy dialogs and may require visible interaction for every operation where
the platform deliberately does not provide a permanent silent grant.

The implementation reuses the pinned OpenMinis Native Offload layer where it
already has a complete provider. The offloads execute in the embedded iSH
process on the phone; they are not remote commands.

## General-purpose capabilities

| Capability | iOS boundary | Agent surface | State |
|---|---|---|---|
| Camera and local OCR | Camera permission; visible camera UI | `camera_ocr`, `apple-vision` | Implemented |
| Photo selection and workspace import | System Photos/File picker grants selected items | Chat composer, Workspace importer | Implemented |
| Photo library query and changes | PhotoKit read/write or add-only permission | `ios_native` -> `apple-photos` | Integrated from OpenMinis |
| Current location and geocoding | When-in-use location permission | `location_current`, `apple-location`, `apple-maps` | Implemented |
| Motion activity | Motion & Fitness permission | `motion_activity` | Implemented |
| Notifications | Notification authorization | `notification_schedule`, `apple-notification` | Implemented |
| Device owner authentication | Face ID, Touch ID, or device passcode UI per check | `secure_authenticate` | Implemented |
| Microphone transcription | Microphone plus Speech Recognition permissions | `ios_native` -> `apple-speech` | Integrated from OpenMinis |
| Text-to-speech | No privacy permission; active audio session | `ios_native` -> `apple-speak` | Integrated from OpenMinis |
| Bluetooth LE | Bluetooth permission | `ios_native` -> `apple-bluetooth` | Integrated from OpenMinis |
| Contacts | Contacts permission, including limited access where available | `contacts_search` | Native typed provider |
| Calendar | EventKit full or write-only access | `ios_native` -> `apple-calendar` | Integrated from OpenMinis |
| Reminders | EventKit reminders access | `ios_native` -> `apple-reminders` | Integrated from OpenMinis |
| Clipboard | iOS paste privacy can still present system UI | `ios_native` -> `apple-clipboard` | Integrated from OpenMinis |
| Health data | HealthKit entitlement plus per-type read/write authorization | `ios_native` -> `apple-healthkit` | Entitlement-gated |
| Smart home | HomeKit entitlement and home authorization | `ios_native` -> `apple-homekit` | Entitlement-gated |
| NFC | NFC entitlement; every scan/write opens a visible NFC session | `ios_native` -> `apple-nfc` | Entitlement-gated |
| Music library and playback | Media library permission | `ios_native` -> `apple-media` | Integrated from OpenMinis |
| Device, battery, storage, thermal state | No privacy permission | `ios_native` -> `apple-device` | Integrated from OpenMinis |
| On-device text analysis | No privacy permission | `ios_native` -> `apple-nlp` | Integrated from OpenMinis |
| Public or LAN HTTP(S) fetch | Native URLSession; LAN destinations may trigger Local Network privacy | `web_fetch` | Implemented |
| Local Linux commands | App sandbox plus iSH guest policy | `shell_execute` | Implemented |
| Siri, Spotlight, Shortcuts, Action Button | App Intents; no legacy Siri permission required | App Shortcuts | Implemented |
| Long task status | ActivityKit and continued-processing budget | Live Activity | Implemented |

## Platform-scoped capabilities

The following are real iOS capabilities, but they are not general permissions
that an app can silently turn on. They require a special Apple entitlement,
managed-device context, accessory program, region, or an explicit foreground
system controller. They remain catalogued rather than falsely reported as
available.

| Capability | Constraint | Harness policy |
|---|---|---|
| Always/background location | Must serve a real location feature; cannot be used as generic keep-alive | Not enabled for fake background execution |
| Background Bluetooth | Must serve a real BLE workflow | Not used as a keep-alive mechanism |
| Critical alerts | Apple-approved entitlement | Not enabled |
| Family Controls / Screen Time | Family Controls entitlement and user authorization | Deferred until a concrete workflow exists |
| Network Extension / VPN / Hotspot Helper | Restricted entitlements and system configuration approval | Not exposed as a general Agent tool |
| Side Button conversational app access | Region and Apple entitlement restrictions | Build-flag placeholder only |
| CarPlay, External Accessory, DriverKit | Product or MFi-specific entitlement | Not applicable to the general build |
| Nearby Interaction accessory sessions | Accessory protocol and entitlement requirements | Deferred |
| SensorKit research sensors | Research entitlement | Not enabled |
| Tracking transparency | Advertising cross-app tracking only | Intentionally excluded; Harness has no advertising tracker |
| ReplayKit screen capture | User-driven foreground broadcast/capture UI | Candidate future visible tool, never silent capture |
| AlarmKit | New SDK capability and visible alarm semantics | Candidate after device/entitlement verification |
| WeatherKit | Service entitlement rather than a personal-data permission | Candidate native information tool |

## Authorization behavior

- Harness grants are permanent until revoked in Settings and are bound to the
  tool, risk level, model API destination, and resource scope.
- iOS privacy decisions are requested only when the user or Agent first invokes
  the related capability. The app does not show a wall of prompts at launch.
- A Harness grant cannot bypass an iOS denial or restriction.
- Face ID/passcode checks, NFC sessions, document pickers, Photos pickers, and
  other system-mediated foreground operations keep their required visible UI.
- No location, audio, Bluetooth, or notification mode is used to fake daemon
  execution. Background work remains subject to iOS scheduling and expiration.
