# Harness Mobile 技术栈

状态：受控文档
构建真源：[`project.yml`](project.yml)、[`Package.swift`](Package.swift)、[`package-lock.json`](HarnessMobile/Resources/PluginHost/package-lock.json)

## 平台与语言

| 层 | 技术 | 当前约束 |
| --- | --- | --- |
| App | Swift 6.0、SwiftUI、Observation、Swift Concurrency | iOS 18+，strict concurrency complete |
| 工程 | XcodeGen、Xcode 27 Beta、SwiftPM | `project.yml` 是工程真源 |
| 测试 | XCTest、XCUITest、SwiftPM tests | arm64 Simulator 与真机分开验收 |
| 持久化 | Foundation 文件 API、SQLite3、Keychain | App-private + file protection |
| 网络 | URLSession、SSE、自有 Provider adapters | 模型 API 使用受验证 HTTPS |
| 系统能力 | ActivityKit、WidgetKit、App Intents、Photos/Contacts/EventKit 等 | 权限和 entitlement 由 iOS 控制 |
| Linux guest | HarnessISH.xcframework、OpenMinis/iSH ARM64 Alpine | 仅设备内 guest 进程 |
| Plugin Host | Node.js >= 20.17、ES modules、Cordis 4.0.1 | 运行于 iSH；依赖锁定 |

## Targets

- `HarnessMobile`：主 SwiftUI 应用。
- `HarnessMobileShare`：分享扩展，通过 App Group 交接数据。
- `HarnessMobileLiveActivity`：Live Activity / WidgetKit 扩展。
- `HarnessMobileTests`：iOS 单元测试。
- `HarnessMobileUITests`：端到端界面测试。
- `HarnessMobileCore`：SwiftPM 可测试核心库。

## 关键系统 Framework

SwiftUI、Foundation、Security、SQLite3、HealthKit、SystemConfiguration、ActivityKit、WidgetKit、AppIntents，以及按能力使用的 Photos、Contacts、EventKit、CoreLocation、CoreMotion、Speech、AVFoundation、CoreBluetooth、MediaPlayer、NaturalLanguage、Vision 和 WebKit。

不得因为某 Framework 可用就自动增加 entitlement 或产品能力；先满足 [平台规范](PLATFORM_GUIDELINES.md) 和 [能力目录](CAPABILITY_CATALOG.md)。

## 第三方与上游

- DeepSeek Harness：Agent/Cordis 语义对照与锁定依赖。
- OpenMinis/iSH ARM64：本机 Linux guest 与 HarnessISH 产物。
- Cordis 与 `@deepseek-ai/dsh-*`：iSH Host-half 运行时，版本由 lockfile 固定。
- `yauzl`：受控 ZIP 读取；归档安全由项目额外校验。

采用上游前检查 `Vendor/`、`Dependencies/`、许可证、锁文件和本地补丁；不要重新实现已有方案。

## 构建约束

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --build-path /tmp/hm-build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

- `HarnessISH.xcframework` 没有 x86_64 slice；所有 Xcode 构建显式使用 arm64。
- 构建缓存放 `/tmp`，不在仓库创建 `.build`、`build` 或 `DerivedData*`。
- 使用 Xcode Beta 路径；不要静默切换稳定版工具链。
- Plugin Host 使用自身锁定依赖运行 `npm run check`。

## 选型规则

优先顺序：现有项目实现 → Swift/iOS 原生 API → 已锁定依赖 → 最小新代码。新增依赖必须说明现有方案为何不足、安全边界、许可证、体积、离线影响和移除路径。
