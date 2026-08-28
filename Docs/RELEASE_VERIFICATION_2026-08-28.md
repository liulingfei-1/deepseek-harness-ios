# RELEASE-002 发布验证报告（2026-08-28）

状态：`VERIFY / BLOCKED`

本报告只记录当前可定位的证据。自动测试、模拟器或 generic device build 不替代 iPhone 16 Pro 的真实 API、权限、后台、插件、长会话和热压力验收。

## 被验证版本

- 代码提交：`251b70e fix: prevent watchdog startup trap`
- 上一提交：`3e8d424 feat: add bounded runtime telemetry`
- 工具链：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
- 真实设备：iPhone 16 Pro，iOS 27.0，UDID `00008140-00161C9836E3001C`
- CoreDevice 状态：paired、booted、Developer Mode enabled

## 自动门与构建

| 门 | 命令/产物 | 结果 |
| --- | --- | --- |
| SwiftPM 全量 | `DEVELOPER_DIR=... swift test --build-path /tmp/hm-build` | PASS：812 tests、3 skipped、0 failures；日志 `/tmp/hm-release002-swift-test-after-fix.log` |
| watchdog 回归 | `swift test --filter RuntimeTelemetryTests` | PASS：8/8；新增测试覆盖 DispatchSource 私有队列回调不触发 executor trap |
| Plugin Host | `(cd HarnessMobile/Resources/PluginHost && npm run check)` | PASS：`node --check host.mjs`、`marketplace.mjs` |
| 执行边界 | `./Scripts/audit-no-remote-execution.sh` | PASS |
| 上游 lock | `./Scripts/verify-upstreams.sh` | PASS；DeepSeek Harness lock `b150a551b8d465e31e418e1b2eaf5e79bbb7d28e` |
| 上游 parity | `./Scripts/check-upstream-parity.sh` | PASS |
| capability manifest | `./Scripts/verify-capability-manifest.sh` | PASS |
| upgrade compatibility | `DEVELOPER_DIR=... HARNESS_SWIFT_SCRATCH_PATH=/tmp/hm-release002-upgrade ./Scripts/upgrade-check.sh` | PASS：812 tests、3 skipped、0 failures；`Upgrade compatibility checks passed.` |
| Xcode generic Simulator | `xcodebuild ... -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build` | PASS：`/tmp/hm-release002-simulator` |
| Xcode real device | `xcodebuild ... -destination 'id=00008140-00161C9836E3001C' -allowProvisioningUpdates ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build` | PASS：`/tmp/hm-release002-device`；真实签名与嵌入扩展均通过 |
| 差异检查 | `git diff --check` | PASS |

## 真实设备启动回归

1. 修复前安装包在 10:10:14、10:10:16、10:11:57 三次启动均产生 `EXC_BREAKPOINT/SIGTRAP`。触发栈稳定包含 `_dispatch_assert_queue_fail → _swift_task_checkIsolatedSwift → closure #3 in RuntimeHangWatchdog.start()`；原始 `.ips` 从设备 `systemCrashLogs` 取回到 `/tmp/hm-release002-crashes/`，未提交原始诊断文件。
2. 根因是 DispatchSource watchdog handler 从 `@MainActor` 词法上下文继承了错误的 executor 隔离；修复提交 `251b70e` 显式使用 `@Sendable` handler，并在私有队列中创建 detached task。
3. 修复后重新安装 `com.llf.harnessmobile` 成功，`devicectl device info processes` 显示主 App 进程保持运行，未产生新的 HarnessMobile crash log。
4. 启动后的真实设备首页截图已归档：[release002-iphone16pro-launch-2026-08-28.png](Evidence/release002-iphone16pro-launch-2026-08-28.png)。

## 尚未闭合的发布边界

- 真实 provider/API、图片、iSH、插件安装与动态更新尚未执行。
- MetricKit 延迟投递、前后台切换与系统 expiration、锁屏、低电量、热压力、长 SSE/长会话尚未执行。
- 诊断日志在真实会话工作区中的导出与 Files 可见性尚未执行。
- 因此 `RELEASE-002` 继续保持 `VERIFY / BLOCKED`，本报告不能作为发布完成声明。
