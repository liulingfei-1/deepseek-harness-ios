# Harness Mobile 协作规范

## Harness 控制入口

本仓库使用 `AGENTS.md` + 12 份根级控制文档约束产品、设计、实现和验收。所有任务先读本文件。产品或实现改动前读 [PRD](PRD.md) 和 [决策记录](DECISIONS.md)，再按下表加载直接相关文档；纯配置、文档或只读任务只加载其涉及的规则。不要为了“完整上下文”一次灌入所有大文件。

| 控制文档 | 控制内容 | 何时必读 |
| --- | --- | --- |
| [PRD.md](PRD.md) | 产品目标、用户任务、范围与成功标准 | 所有产品/能力改动 |
| [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) | 视觉令牌、组件、层级与 UI 门禁 | 所有界面改动 |
| [APP_FLOW.md](APP_FLOW.md) | 启动、项目、对话、工具、插件与恢复流程 | 路由、状态流、交互改动 |
| [FRONTEND_GUIDELINES.md](FRONTEND_GUIDELINES.md) | SwiftUI、状态、交互、无障碍与性能 | `App/`、`Features/`、扩展 UI |
| [BACKEND_STRUCTRUE.md](BACKEND_STRUCTRUE.md) | 设备内业务层、数据真源、并发与执行边界 | Runtime、Store、Network、Tools、Plugins |
| [SECURITY_GUIDELINES.md](SECURITY_GUIDELINES.md) | 凭据、路径、网络、插件、权限与脱敏 | 任何信任边界改动 |
| [CAPABILITY_CATALOG.md](CAPABILITY_CATALOG.md) | 产品能力、生产注册与状态 | 新增/扩大/下线能力 |
| [TECH_STACK.md](TECH_STACK.md) | 平台、Target、依赖和构建真源 | 工程、依赖、工具链改动 |
| [QUALITY_GUIDELINES.md](QUALITY_GUIDELINES.md) | 测试、证据、失败处理与 Done | 所有实现和验收 |
| [PLATFORM_GUIDELINES.md](PLATFORM_GUIDELINES.md) | iOS 权限、后台、设备、entitlement 和 UI 行为 | iOS 系统能力与真机工作 |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | 阶段、顺序、验收门与真机矩阵 | 规划、选下一项、收尾 |
| [DECISIONS.md](DECISIONS.md) | 已接受架构与产品决策 | 所有可能改变既有方向的改动 |

### 控制优先级

1. `AGENTS.md`、安全与平台硬边界不能被实现便利绕过。
2. 已接受的 `DECISIONS.md` 约束方向；要改变它先新增取代决策。
3. `PRD.md`、`APP_FLOW.md` 和 `CAPABILITY_CATALOG.md` 定义产品行为。
4. 设计、前后端、技术栈和质量文档约束实现方式。
5. `IMPLEMENTATION_PLAN.md` 只控制顺序，不能降低上面的验收标准。

源码、测试和设备结果是“当前实现事实”的最终证据。遇到文档冲突，指出冲突并暂停依赖该决策的改动，继续其他已授权工作；已明确取代的旧规则按新决策同步。涉及产品范围、安全或远程执行的未解决冲突，不以模型升级为由扩大权限。

### 文档同步

- 产品范围或用户流程变化：更新 `PRD.md`、`APP_FLOW.md`、`CAPABILITY_CATALOG.md`，必要时追加决策。
- UI 变化：更新设计/UI 审计与最小 UI 证据。
- Runtime、存储或网络边界变化：更新后端结构、安全和相应决策。
- Target、依赖、entitlement 或工具链变化：更新技术栈与平台规范。
- 每个实现补丁仍必须更新 `Docs/DESKTOP_PARITY_REMEDIATION.md`；阶段变化再更新 `IMPLEMENTATION_PLAN.md`。

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
- 检查范围按 [质量规范](QUALITY_GUIDELINES.md) 选择。仅修改 Codex 配置或协作 Markdown 时，验证配置解析、实际加载、链接与 diff；涉及脚本时做语法/执行检查。没有产品代码或构建输入变化时不启动 Swift、Node 或真机全套验收；实现改动仍完成其规定门禁。

## 验证标准

- `TODO`：未实现；`VERIFY`：代码存在但自动化、真机或上游契约仍未全部通过；`DONE`：代码、测试和指定验收全部通过；`IOS-REPLACEMENT`：有边界诚实的原生替代；`OUT-OF-SCOPE`：不属于稳定能力或违反产品边界。
- 每次修补同步维护 `Docs/DESKTOP_PARITY_REMEDIATION.md`：状态、生产路径、测试命令、结果和剩余真机边界都要写清楚。
- 真实 API、图片、iSH、插件、后台、长会话和诊断导出属于真机验收；没有设备证据只能保留 `VERIFY`。
- 测试失败要记录真实错误文本和触发命令，先定位根因再改实现；不要用放宽校验、吞异常或 mock 成功掩盖失败。

## 核心文件地图

| 模块 | 路径 | 职责 |
| --- | --- | --- |
| App/UI 状态 | `HarnessMobile/App/` | AppModel、根视图、生命周期和安装入口；大文件先定位相关符号，按理解调用链所需范围展开 |
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
- 读取大文件前先用 `rg -n`、`sed -n` 定位相关类型/方法，随后按调用者、被调用者和状态流展开；理解或检查需要全文件时可以读取，避免无关内容反复加载。
- 修改 `HarnessMobile/App/`、`HarnessMobile/Core/Agent/`、`HarnessMobile/Core/Plugins/` 或 `HarnessMobileTests/` 前，先读该目录最近的 `AGENTS.md`；它只补充该模块的入口、边界和最小验证，不重复本文件。

## 工作纪律

- 先读规则、上游契约和现有测试；每个修补保持小步、可回滚，完成一个 parity ID 就更新文档日志。
- 不覆盖用户已有改动，不执行 `git reset --hard`、`git checkout --` 或宽范围删除；提交前检查 `git status`、`git diff --check`、测试和边界审计。
- 新增 API key、日志或 fixtures 时只保存凭据引用/脱敏摘要，绝不写入源码、测试输出或导出文件。
- 插件与桌面版对齐（决策 D-010）：模型可用本地 host 运行时动态 define/run/update/stop/undefine Cordis 包，加载任意 Cordis/npm JS 生态包；执行只在设备本地（iSH node / JavaScriptCore），不引入远程 executor。现有 WKWebView 可承载 Browser/React client-half，但桌面 bundle 尚未接入；`.node` 原生 addon、下载的 Swift/framework 二进制仍属 iOS/iSH 工具链限制（见 `Docs/DESKTOP_FULL_PARITY_2026-09-03.md` §4），报明确平台限制错误，不以安全模型拒绝。
