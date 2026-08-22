# Harness Mobile 协作规范

## 项目边界

- 这是 DeepSeek Harness 的 iOS 原生移植；模型通过用户配置的 API 推理，工具、插件和命令只允许在手机本机或 iSH 沙箱执行。
- 不增加服务器执行回退，不把真机未验收写成完成，不把模拟器通过当成 iPhone 16 Pro 通过。
- 先查 `Vendor/`、`Dependencies/`、上游 DeepSeek Harness 和 OpenMinis 现成实现，再写新代码；避免重复造轮子。

## 构建与测试

- 必须使用：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`；否则 `swift test` 会报 `no such module 'XCTest'`。
- SwiftPM 测试：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build`。
- 项目内 `.build` 会触发 resource fork 错误；不要在项目根生成构建缓存，若历史缓存已存在先 `xattr -cr .build`，日常统一使用 `/tmp/hm-build`。
- Xcode 构建必须带 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`，因为 `HarnessISH.xcframework` 没有 `x86_64` 切片。示例：`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build`。
- Plugin Host：`cd HarnessMobile/Resources/PluginHost && npm run check`；Node smoke 使用同目录锁定依赖。
- 边界审计：`./Scripts/audit-no-remote-execution.sh`；上游一致性：`./Scripts/check-upstream-parity.sh`；收尾执行 `git diff --check`。
- 构建缓存只放 `/tmp`，不在项目根新建 `DerivedData*`、`build` 或 `.build`。

## 验证标准

- `TODO`：未实现；`VERIFY`：代码存在但自动化、真机或上游契约仍未全部通过；`DONE`：代码、测试和指定验收全部通过；`IOS-REPLACEMENT`：有边界诚实的原生替代；`OUT-OF-SCOPE`：不属于稳定能力或违反产品边界。
- 每次修补同步维护 `Docs/DESKTOP_PARITY_REMEDIATION.md`：状态、生产路径、测试命令、结果和剩余真机边界都要写清楚。
- 真实 API、图片、iSH、插件、后台、长会话和诊断导出属于真机验收；没有设备证据只能保留 `VERIFY`。
- 测试失败要记录真实错误文本和触发命令，先定位根因再改实现；不要用放宽校验、吞异常或 mock 成功掩盖失败。

## 核心文件地图

| 模块 | 路径 | 职责 |
| --- | --- | --- |
| App/UI 状态 | `HarnessMobile/App/` | AppModel、根视图、生命周期和安装入口；`AppModel.swift` 约 8600 行，先 grep 定位，禁止整读 |
| Agent loop | `HarnessMobile/Core/Agent/AgentRuntime.swift` | 请求组装、流式回合、工具循环、取消、压缩和 inbox；约 4600 行，先 grep |
| 网络协议 | `HarnessMobile/Core/Network/` | DeepSeek、OpenAI-compatible、Anthropic、Files API、重试和 SSE |
| 配置/凭据 | `HarnessMobile/Core/Configuration/`、`Core/Security/` | Provider/Profile/Bundle、Keychain 引用、模型发现和设置迁移 |
| 工具 | `HarnessMobile/Core/Tools/` | 文件、搜索、终端、MCP/LSP、Jobs、Workflow、移动能力；生产目录在 `ProductionToolCatalog.swift` |
| 插件/Cordis | `HarnessMobile/Core/Plugins/` | Native Agent compiler/runtime/store、Cordis runtime、iSH Host/nativeClient bridge |
| 持久化 | `HarnessMobile/Core/Storage/`、`Core/Trace/` | Workspace/Session、trajectory、spill、诊断和脱敏；`WorkspaceStore.swift` 约 2240 行 |
| UI 特化卡片 | `HarnessMobile/Features/Chat/`、`Features/Trajectory/` | 工具事件、Markdown、长对话窗口、轨迹 Inspect；大文件先 grep |
| Host 资源 | `HarnessMobile/Resources/PluginHost/` | iSH Node Host、安装脚本、marketplace 和锁文件 |
| 测试/夹具 | `HarnessMobileTests/`、`CompatibilityFixtures/` | Swift/XCTest、Node smoke、上游 wire/compaction/image/subagent/jobs fixtures |
| 文档/脚本 | `Docs/`、`Scripts/` | parity 清单、架构、升级说明、边界审计和构建脚本 |

## 大文件纪律

- 超过 1500 行的文件至少包括：`AppModel.swift`、`AgentRuntime.swift`、`WorkspaceStore.swift`、`SessionEventTrajectory.swift`、`SlashCommandCore.swift`、`ISHPluginHostDynamicHarnessBridge.swift`、`CordisPluginRuntime.swift`、`TrajectoryView.swift`、`ChatView.swift`、`NativeToolEventViews.swift` 及对应测试。
- 读取大文件前先用 `rg -n`、`sed -n` 定位相关类型/方法；只读取必要窗口，不整文件灌入上下文。

## 工作纪律

- 先读规则、上游契约和现有测试；每个修补保持小步、可回滚，完成一个 parity ID 就更新文档日志。
- 不覆盖用户已有改动，不执行 `git reset --hard`、`git checkout --` 或宽范围删除；提交前检查 `git status`、`git diff --check`、测试和边界审计。
- 新增 API key、日志或 fixtures 时只保存凭据引用/脱敏摘要，绝不写入源码、测试输出或导出文件。
- 动态插件只走审计过的 native manifest 或 iSH Host JS；不动态加载下载的 Swift/机器码，不暴露任意 Web/React 插槽。
