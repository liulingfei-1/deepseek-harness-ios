# DeepSeek Harness Mobile 对齐与插件迁移

> 更新：2026-08-29。本文只保留当前仍需行动或验收的事项。已经通过自动化门的历史修补不再作为待办重复列出；完整历史证据由 git 提交、测试报告和本文件的归档索引追溯。

## 当前结论

- 插件安装采用 native-first：先生成并校验 NativeAgent 声明清单，只有无法表达或运行时确实依赖 Unix/解释器的插件才进入 iSH Host。
- NativeAgent 允许完整生产工具目录，包括 `shell_execute`、`code_execute`、`run_code`、持久终端、`lsp`、MCP、本地作业、会话查询、图片、网页、文件编辑和交付写入。它们仍按各自生产路径执行：Swift 编排或 iSH 本机 runtime，不是被白名单静默删掉。
- 已移除旧的 OpenMinis `ios_native` 命令桥和 iSH 静态库中的 18 组 `apple-*` capability handlers；原生目录已补入 NaturalLanguage、系统朗读/语音转写、MapKit、Deep Link、PhotoKit 查询、媒体库/播放、HealthKit、BLE 扫描和扩展 Vision 等 12 个 typed Swift tools。未实现部分不会再通过桥接兜底。
- iSH 只保留 shell、终端、LSP、MCP stdio 和 Unix/解释器插件所需的 Linux runtime。重建后的 `HarnessISH.xcframework.zip` 从 `1,483,833` bytes 降至 `993,426` bytes，减少 `490,407` bytes（`33.0%`）；构建门会拒绝旧 capability handler 符号重新进入产物。
- 目前不能宣称“80% 插件已原生编译”：需要真实市场批量样本、iPhone 16 Pro 安装结果和覆盖率统计后才能量化。
- 本轮自动化门已通过；2026-08-31 版本已在 iPhone 16 Pro 完成签名构建、覆盖安装和启动。2026-09-01 最新 UI 产物 `/tmp/hm-device-ui-0901/Build/Products/Debug-iphoneos/HarnessMobile.app` 已签名构建成功，但设备处于 `unavailable`，覆盖安装返回 `CoreDeviceError 4016`，待手机解锁并恢复可信连接后重试；真实 provider、批量覆盖率和长时压力仍标为 `VERIFY`。

## 插件执行后端矩阵

| 后端 | 当前能力 | 说明 |
| --- | --- | --- |
| `swift-native` | 文件/搜索/图片/会话工具，以及日历、提醒、剪贴板、设备状态、联系人、定位、运动、通知、认证、Vision、NLP、语音、地图/Deep Link、照片、媒体、HealthKit 和 BLE 扫描 | 由签名 Swift typed tool 直接执行，权限/系统授权由工具自身处理 |
| `swift-orchestration` | `schedule_*`、`job_*`、`send_message`、工作状态、插件生命周期和诊断 | Swift 负责持久化、生命周期和事件投影 |
| `ish-runtime` | `shell_execute`、`code_execute`、`run_code`、`terminal_*`、`lsp`、本机 MCP stdio、需要 Unix/npm/Python/编译器的插件 | 仍在手机 iSH 沙箱内；这是运行时依赖，不是安装流程失败 |

## 活动事项

### 插件市场与 NativeAgent

| ID | 状态 | 下一步/验收 |
| --- | --- | --- |
| PLUGIN-001 | VERIFY | Host-only 插件在 iSH 中安装、启用、停用、回滚；补 iPhone 长会话验收；Host 冷启动已移除 `--jitless`，市场插件恢复改为最多 4 路受控并发，并记录分阶段/逐插件耗时 |
| PLUGIN-002 | VERIFY | inbox checkpoint 在 Xcode/真机长任务中验证 durable claim/discard 顺序 |
| PLUGIN-003 | VERIFY | `llm/stream` start/event/finish/error/cancel 事件桥补 Node smoke 与真机长流 |
| PLUGIN-004 | VERIFY | Native Code Mode 与 Host 插件共用 checkpoint、授权和 trajectory |
| PLUGIN-005 | VERIFY | generation 替换/失败恢复补 iPhone 动态插件验证 |
| PLUGIN-006 | VERIFY | Host 重启后的 inventory 握手与定义重建补真机验证；无活动会话先完成轻量 ping/inventory，活动会话再同步完整上下文与贡献 |
| PLUGIN-007 | TODO | 按上游版本补齐经过审计的 `dsh.nativeClient` contribution kinds |
| PLUGIN-008 | IOS-REPLACEMENT | React/slots/themes 继续使用受控 native manifest 表达 |
| PLUGIN-009 | VERIFY | 编译失败修正、同 token 重提交流程补 iPhone 复测 |
| PLUGIN-010 | VERIFY | 市场入口与对话入口做真实双入口安装/rollback 验收 |
| PLUGIN-011 | VERIFY | 编译、安装、日志和源码面板补真机失败重试、导出和 VoiceOver 验收 |
| PLUGIN-012 | VERIFY | 用真实市场批量样本测量 native 编译覆盖率；不以候选数代替成功率 |
| PLUGIN-013 | VERIFY | 收集 npm/manifest/patch 失败样本，确认普通兼容失败先走 NativeAgent 候选 |

### 工具、上下文与缓存

| ID | 状态 | 下一步/验收 |
| --- | --- | --- |
| TOOL-001/002/003 | VERIFY | `read_image`、`glob`、`grep` 的真机大文件、二进制、取消和超时验收 |
| TOOL-004 | VERIFY | spill locator 在 Xcode/真机长输出分页验收 |
| TOOL-005 | VERIFY | 持久终端 open/read/send/signal/list/close 做真机交互和冷启验收 |
| TOOL-006 | VERIFY | session search/trace/event 查询做 Xcode target 与真机长轨迹验收 |
| TOOL-007 | VERIFY | schedule BGTask 在真机后台、过期和重新唤醒场景验收 |
| TOOL-008/009 | VERIFY | `ralph`、`subagent_fork` 做真机 trajectory、并发和取消验收 |
| TOOL-010 | VERIFY | 本机 MCP stdio server 安装、重连和工具集替换做真机验证 |
| TOOL-011 | VERIFY | iSH LSP server fixture、per-workspace process pool 和设置页 provider 验收 |
| TOOL-012 | VERIFY | 文件编辑 before/after/line-window presentation meta 与真机大文件验收 |
| IMG-003/004/005/006/007/009 | VERIFY/TODO | 图片预算、Files API、工具结果回灌、`read_image` 和真机多图性能逐项验收 |
| CTX-001/002 | VERIFY | tool-result pruner/spill 在高频长会话中验证完整结果、预览和 locator 一致 |
| CTX-007 | VERIFY | 真实 Anthropic/DeepSeek cache 字段组合和长轨迹验证缓存命中率显示 |
| INS-001/002/003/004 | VERIFY | instructions transition、稳定请求前缀和 compaction cache fixture 完成回归 |

### 原生系统能力迁移

| ID | 状态 | 下一步/验收 |
| --- | --- | --- |
| MOBILE-001 | VERIFY | 相机/OCR、位置、运动、联系人、通知和 App Intents 逐项做系统授权与真机验收 |
| MOBILE-002 | VERIFY | 已迁移 Vision/NLP/语音/地图/Deep Link/照片查询/媒体/HealthKit/BLE 扫描；继续补 PhotoKit 修改/导出和按设备协议的 BLE connect/read/write。HomeKit/NFC 待当前签名取得 entitlement 后接入，不能用旧桥伪装可用 |
| PERM-001/002/003/004/005 | VERIFY | 完成长效授权、查看/撤销 UI、subagent/MCP/Web/Code/mobile 统一策略及迁移故障测试 |
| BG-001/002/003/004 | VERIFY | continued-processing 到期时，若静音音频或已授权后台定位仍健康，则结束已到期的系统 task、补上有限 UIKit lease，并让同一 worker/上下文继续；否则发布 `interrupted/system_expiration`，立即提交一次已有 BGProcessing handler 的本地恢复机会，并在前台恢复。继续做锁屏/电话/蓝牙/低电量/热压力和长时切屏真机验收 |

### UI 与 Provider

| ID | 状态 | 下一步/验收 |
| --- | --- | --- |
| UI-001/002/003/004 | VERIFY | 首页 workspace、子 Agent breadcrumb、Jobs 和工具卡片做 iPhone 触控、Dynamic Type、VoiceOver 验收 |
| UI-005/006/007/008/009 | VERIFY | Markdown、缓存命中率、长会话、Trajectory 和插件观测面板做真机性能/无障碍验收 |
| UI-010/011 | VERIFY | Minis 风格聊天、首页、工具、设置的真机布局/旋转/无障碍收口；用户/助手消息已统一显示复制、重试/重新生成、编辑和反馈操作栏 |
| UI-012 | ACTIVE | 按 `Docs/UI_REDESIGN_AUDIT.md` 的 12 步清单逐页推进；共享视觉基础、首页、设置、聊天、首次配置、插件市场、Provider、终端、轨迹、工具事件卡片、手机权限、记忆和插件设置已完成多轮收口。Section 标题与工具卡片图标统一复用语义组件，不删减开发者操作。继续做真机/无障碍验收 |
| WIRE-003/005/006/008 | VERIFY | 稀有 gateway 字段、retry、Vision endpoint 和真实 API 验收 |
| PROVIDER-001/002 | VERIFY | 401/OAuth rotation、稀疏 compatibility 字段和私有网关真实请求验收 |
| REF-001..006 | VERIFY | quoted `@file`、session reference、搜索和输入光标做 Xcode/真机交互验收 |
| SUB-001..008 | VERIFY | 递归、structured output、report delivery、jetsam/cold-launch 真机验收 |

## 保留的产品边界

这些不是插件安装失败，也不应通过“原生化”文字掩盖：

- 不增加服务器或 Remote Executor 执行回退；模型推理可走用户配置的 API，但工具、插件和命令仍在手机本机或 iSH。
- 不下载本地模型权重，不动态加载下载的 Swift/机器码，不把任意 Web/React 插件变成可执行代码。
- MCP 只支持本机 iSH stdio；远程 Streamable HTTP/OAuth 不纳入本产品执行路径。
- Windows PowerShell、桌面浏览器自动打开和官方稳定版之外的实验性 Agent Teams 不作为 iOS parity 阻断项。

## 最近验证命令

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /tmp/hm-native-tools-xcode build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphoneos -destination 'id=C650014D-7034-5FD7-A35B-D96BF7E488CE' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /tmp/hm-native-tools-device build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./Scripts/build-ish-sandbox.sh libraries
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./Scripts/build-ish-sandbox.sh rootfs
cd HarnessMobile/Resources/PluginHost && npm run check
node HarnessMobileTests/ISHPluginHostNodeSmoke.mjs HarnessMobile/Resources/PluginHost
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

### Host 启动优化（2026-08-29）

- iSH Cordis Host 不再使用 Node `--jitless`；该选项会让冷启动和长期插件执行都失去 JIT，且没有为当前 Host 带来实际收益。
- `MarketplaceManager.start()` 对启用记录采用最多 4 路受控并发；单个插件失败只更新自己的记录，不阻塞其他插件恢复。Host stderr 会输出 `layout/registry/runtime/restore` 阶段耗时及每个插件的恢复耗时。
- AppModel 的首次 Host 握手在无活动会话时只执行 `ping + inventory`，市场列表按需读取；存在活动会话时才执行轨迹、设置、动态贡献和 native-client 同步。
- Node smoke 和 Host `npm run check` 已通过；Swift 与 iPhone 冷启动仍需在目标设备上复测，故本项保持 `VERIFY`。

### 切屏恢复与消息操作（2026-08-29）

- 诊断 `Harness-Diagnostics-20260829-194802.log` 显示 continued-processing 超时后，轨迹被写成 `aborted/user`；根因是系统到期回调与 runtime 的 `CancellationError` 竞争，系统中断尚未发布就被按用户取消持久化。
- 对照 OpenMinis 当前实现后，补齐了它的关键续接顺序：有限 UIKit lease 到期时先 `endBackgroundTask` 旧 identifier；若用户开启的静音音频或后台定位层仍健康，立即申请新 lease，并保留同一 Agent worker、run identity 和上下文，不重放请求。
- `BGContinuedProcessingTaskRequest` 仍只由用户前台动作提交，不在后台违规循环重提。continued-processing 到期时会先结束该系统 task；若真实延展层健康，就切换到“音频/定位 + 新有限 lease”继续同一任务；延展层不可用时才发布 `.interrupted/system_expiration` 并取消 worker，由现有前台恢复协调器续跑。
- UIKit expiration handler 现在无论是否续接都会结束旧系统 identifier，避免遗留已过期 task 导致系统强杀；所有续接都要求精确的 live run snapshot，完成、取消或已替换的 run 不会被复活。
- 聊天消息操作不再只藏在长按菜单：用户消息直接提供复制、重试、编辑；助手消息提供复制、重新生成、赞/踩。助手的重新生成稳定定位到最近一个可见用户回合，工具消息不错误暴露重试入口，并补齐 44pt 触控目标和无障碍标签。
- 新增 state-machine、有限 lease 重臂和延展层健康检查回归；专项测试通过，arm64 generic simulator 已构建成功，Host check、Node smoke、无远程执行审计、upstream parity 与 `git diff --check` 均通过。完整 SwiftPM 套件当前为 `822` tests、`3` skipped、`1` 个固定的并发/调度抖动失败（`AgentRuntimeTests.testPinnedDeepSeekToolSchedulerDifferentialFixture`，单独复跑通过），因此不能记为全量 0 failures。长时间后台到期后的真实续接与消息操作仍需在 iPhone 16 Pro 上交互复测，所以 BG/UI 状态保持 `VERIFY`。
- 这里的“额度到期”仅指 iOS 后台执行时间配额；它不能延长 DeepSeek/OpenAI 等服务商的账户额度。服务商返回 `429` 时仍按 Provider `Retry-After` 和重试策略处理，后台续接不会伪造或绕过服务商配额。

### UI-013 · 插件管理层级收口（2026-08-30）

- `PluginManagementView` 将 Cordis Runtime 统计从五行诊断列表压为首屏摘要，插件行统一图标块与状态胶囊，保留 Host 控制、动态插件启动/停止/卸载、原生插件重启、诊断 stderr 和设置入口。
- 新增 `plugin-runtime-summary` UI 夹具标识并接入 Host 控件专项测试；arm64 generic iOS Simulator build succeeded。深色、大字、VoiceOver、真实 iSH Host 和真机触控仍为 `VERIFY`。

### UI-014 · 插件设置与记忆层级收口（2026-08-30）

- `PluginSettingsView` 和 `MemoryManagementView` 复用统一语义背景、图标块、状态胶囊和 44pt 操作目标；只压缩首屏噪声，不改变 schema 编辑、冲突处理、导出或删除语义。
- arm64 generic iOS Simulator build succeeded；真实 Host/存储数据、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-015 · 手机权限与 Agent 编排层级收口（2026-08-30）

- `PhonePermissionsView` 权限状态行和 `AgentProviderBundlesView` Bundle 行复用统一语义图标、状态胶囊和列表背景；保留权限刷新、系统设置跳转、Bundle 开关、安装/重装/取消和固定来源说明。
- arm64 generic iOS Simulator build succeeded；真实权限回调、iSH 安装、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-016 · 原生 Client 贡献详情层级收口（2026-08-30）

- `NativeClientContributionsView` 统一列表背景和设置图标块，Inspector 刷新入口固定为 44pt 触控目标；数据读取、命令展示、设置导航和错误状态均未删减。
- arm64 generic iOS Simulator build succeeded；真实 Client 调用、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-017 · 任务状态层级收口（2026-08-30）

- `WorkStateView` 复用统一列表背景、状态图标块和状态胶囊，目标操作菜单固定为 44pt；恢复、计划、待办、上下文治理和错误投影未删减。
- arm64 generic iOS Simulator build succeeded；真实运行/恢复状态、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-018 · 终端与轨迹表面收口（2026-08-30）

- `ISHTerminalView` 命令模式和 `TrajectoryView` 时间线复用共享语义背景、卡片表面和浮动输入层；保留黑色交互终端、执行/停止/网络、搜索/折叠/刷新/分页和 Inspector 全部能力。
- arm64 generic iOS Simulator build succeeded；真实 iSH 输出、长列表、横屏、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-019 · Workspace 与 Console 表面收口（2026-08-30）

- `WorkspaceView` 挂载/文件行与 `ConsoleView` segmented 壳层复用共享语义组件，保留导入、挂载、授权、读写、导出、卸载及任务/插件/轨迹导航。
- arm64 generic iOS Simulator build succeeded；真实文件提供器、长列表、横屏、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-020 · 诊断日志与工具事件表面收口（2026-08-30）

- `DiagnosticLogView`、`ToolEventView` 和 `NativeToolEventViews` 复用统一语义列表/卡片表面与图标块；保留脱敏日志导出、stderr、性能采样、参数、输出、错误和 Inspector。
- arm64 generic iOS Simulator build succeeded；长日志/输出、深色、大字、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-021 · 全局视觉细节收口（2026-08-30）

- 清理聊天统计、Markdown 代码块和社区插件行的剩余硬编码背景与 32pt 图标，统一共享语义表面；不改变数据与操作语义。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；深色、大字、VoiceOver、横屏和真机触控仍为 `VERIFY`。

### UI-022 · 会话模型与 iSH 环境第二轮（2026-08-30）

- `SessionModelPickerView` 接入共享列表 chrome；默认模型、Provider 和模型候选统一图标块/状态胶囊，保留搜索、模型发现、手动模型 ID、能力信息和保存流程。
- `ISHInteractiveEnvironmentView` 统一系统/工作目录/执行位置行级表面；网络开关和 iSH 语义说明保持原有行为。
- arm64 generic iOS Simulator build succeeded；深色、大字、VoiceOver、横屏、真实模型发现和真实 iSH 仍为 `VERIFY`。

### BG-011 · 系统到期后的本地恢复机会（2026-08-30）

- `SessionBackgroundResumeCoordinator` 增加一次性 pending identity claim，避免前台 scene 与 `BGProcessingTask` 同时恢复同一个 run。
- continued-processing 到期且没有健康音频/定位延展层时，先持久发布 `system_expiration`，再复用已注册的 schedule-processing handler 提交一次尽快唤醒请求；后台窗口内优先恢复当前会话的可续跑上下文，再处理普通 schedule。
- 这是 iOS 调度的 best-effort 恢复，不伪造无限后台时间；系统仍可能不唤醒、因资源压力终止或要求前台恢复。SwiftPM 定向后台测试通过，iOS arm64 模拟器构建仍需本轮最终复核。

### BG-012 · 后台唤醒恢复不重复提交 continued-processing（2026-08-30）

- `BGProcessingTask` 恢复被系统中断的 run 时显式使用有限后台窗口执行，不再从后台再次提交用户发起的 continued-processing 请求；前台恢复仍保留原有 continued-processing 路径。
- 系统到期处理先以 run identity 提交一次 `.interrupted`，再写超时遥测与恢复标记，避免 cancellation callback 与 operation completion 竞态造成重复计数或重复恢复。
- 定向后台 SwiftPM 测试 26/26 通过，arm64 generic iOS Simulator build succeeded；系统调度、真实额度、锁屏和真机长时运行仍为 `VERIFY`。服务商账户额度（如 429/配额）不属于可由 App 延长的 iOS 后台时间。

### BG-013 · 冷启动挂载 BGProcessing 恢复 handler（2026-08-30）

- 诊断复核发现 `HarnessMobileAppDelegate` 只注册了系统启动回调，`AppModel` 的 `ScheduleBackgroundController` handler 没有在 SwiftUI model bootstrap 前挂载，导致系统到期后提交的本地恢复请求可能一直停在 launch queue，表现为 Minis 能继续而 Harness 到期后不再执行。
- 在 `DeepSeekHarnessMobileApp` 的 `.task` 中先调用 `model.registerBackgroundTasksIfNeeded()`，再执行 `bootstrap()`；这样冷启动、系统到期唤醒和普通 schedule 都能接入同一个 model-owned bounded handler，仍保持一次性 identity claim 和不重复提交 continued-processing 的约束。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --build-path /tmp/hm-bg-recovery --filter 'Background|SessionBackgroundResumeCoordinatorTests'`：41/41 通过；arm64 generic iOS Simulator build succeeded；真实系统是否实际唤醒、后台时间额度和 iPhone 长时切屏仍为 `VERIFY`。

### UI-023 · 工具事件卡片第三轮（2026-08-30）

- Search/Web/Job/Diff/Deliverable/Workspace/Work Items/Workflow 标题行统一图标块与间距；终端输出继续使用独立黑色终端表面。
- 本轮只改变视觉组件复用，不改变工具数据、展开、错误、复制、文本选择和 Inspector 行为；arm64 generic iOS Simulator build succeeded。

### UI-024 · 设置与权限分组第二轮（2026-08-30）

- 后台设置、手机权限、记忆管理和插件 Settings Provider 分组标题统一使用语义图标，降低默认 Form 的视觉噪声并保留全部开发者状态和操作。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；真实权限、Host、存储和无障碍仍保持 `VERIFY`。

### UI-025 · 设置、Provider、Workspace 与插件管理第三轮（2026-08-30）

- 设置首页、Provider Profiles、Workspace 和 Cordis 插件管理的 Section 标题统一语义图标；所有开发者操作、导航和状态投影保留。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；真实设备与无障碍矩阵仍为 `VERIFY`。

### UI-026 · 聊天输入与消息身份第三轮（2026-08-30）

- 输入栏附件状态、输入建议和助手身份标记统一复用共享视觉组件；消息和开发者操作不变。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；键盘、旋转、Dynamic Type、VoiceOver 和真机触控仍为 `VERIFY`。

### UI-027 · 首页会话列表第三轮（2026-08-30）

- 首页任务入口、Workspace 层级、会话行和系统状态标题统一语义图标块与间距；搜索、筛选、排序和会话管理行为不变。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；长列表、真机和无障碍矩阵仍为 `VERIFY`。

### UI-028 · 插件详情与创建表单第二轮（2026-08-30）

- iSH/原生插件详情与实验插件创建表单统一语义分组标题；启停、版本、卸载、Prompt 和 Host-half JavaScript 能力保持完整。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；Host 真机和无障碍验收仍为 `VERIFY`。

### UI-029 · 轨迹与工作状态第二轮（2026-08-30）

- 轨迹事件/折叠分组与工作状态分组、目标/计划/待办条目统一语义图标组件；恢复、编辑、分页、折叠和 Inspector 能力保持完整。
- arm64 generic iOS Simulator build succeeded，`git diff --check` 通过；长列表、真机和无障碍矩阵仍为 `VERIFY`。

### UI-030 · 首次配置渐进披露（2026-08-31）

- `SetupView` 的 onboarding 模式只显示服务商、连接、模型和安全边界；高级推理继续保留在保存后的服务商编辑模式，未删除 Provider 能力或安全说明。
- 首次配置的连接与模型 footer 改为短说明，服务商 Picker 标签和值分列对齐；完整的域名绑定、模型目录刷新和兼容参数说明仍保留在编辑模式。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-onboarding-ui ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobileOnboardingUITests`：2/2 通过；服务商对齐专项复跑 1/1 通过，调整后截图为 `/tmp/harness-setup-provider-aligned-0831.png`。iPhone 16 Pro 新产物覆盖安装、深色、大字、VoiceOver 和横屏仍为 `VERIFY`。

### UI-031 · 轨迹框架语言一致性（2026-08-31）

- `TrajectoryView` 的统计、耗时/回合/调用视图、运行时摘要、事件角色和常用 Inspector 字段统一为中文；provider/model、工具名、Call ID、原始事件类型、JSON、路径和参数不翻译。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-trajectory-localized-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobileTrajectoryUITests/testTrajectoryLedgersSearchCollapseAndInspect`：1/1 通过；前后截图为 `/tmp/harness-trajectory-live-audit-2.png`、`/tmp/harness-trajectory-localized-0831-2.png`。深色、大字、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

### UI-032 · 本会话模型直接选择（2026-08-31）

- `SessionModelPickerView` 删除跟随默认模式下重复的当前模型卡，模型候选始终可见；点选其他模型时自动进入本会话覆盖，服务商、凭据与推理设置仍按原有范围展开。
- 搜索改用系统导航栏抽屉，框架文案统一为中文；模型 ID、API Key、Keychain 和协议名保持技术原文。没有新增组件或数据抽象。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-model-picker-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobileSessionModelPickerUITests/testSessionModelPickerShowsScopeAndSearchableModels`：1/1 通过；前后截图见 UI 审计文档。深色、大字、VoiceOver、横屏、真实目录刷新和 iPhone 16 Pro 仍为 `VERIFY`。

### UI-033 · 手机权限状态与用途分层（2026-08-31）

- `PhonePermissionsView` 使用原生 `DisclosureGroup` 将 16 项权限用途改为按需展开，默认列表保留名称与真实状态；权限查询、刷新、系统设置跳转和请求时机没有改变。
- `HarnessStatusPill` 显式使用“图标 + 标题”样式，修复外层环境导致状态文字消失的共享根因，没有新增组件或依赖。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-phone-permissions-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobilePhonePermissionsUITests/testPhonePermissionsShowsGroupedStatusAndSystemSettingsLink`：1/1 通过；前后截图见 UI 审计文档。真实权限变化、深色、大字、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

### UI-034 · 后台任务说明渐进披露（2026-08-31）

- `BackgroundSettingsView` 将后台执行、定位、实时活动、通知、隐私、运行状态和系统投影的普通说明改为原生折叠行；通知拒绝/授权错误和执行边界继续直接显示。
- 没有改变后台偏好、定位授权、通知请求、Live Activity、运行状态或系统投影逻辑，也没有新增依赖。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-background-settings-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobileProgressiveDisclosureUITests/testSettingsGroupsBackgroundStorageAndPrivacyWithoutHidingRoutes`：1/1 通过；前后截图见 UI 审计文档。真实后台调度、系统权限变化、深色、大字、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

### UI-035 · 记忆管理空态收口（2026-08-31）

- `MemoryManagementView` 将大尺寸空态替换为紧凑原生行，并将会话记忆说明及存储/发送边界改为原生渐进披露；安全文字未删除。
- 导出 JSON、记录行、删除确认、刷新、会话开关和本机存储逻辑没有改变，也没有新增依赖。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-memory-management-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobileMemoryManagementUITests/testMemoryManagementKeepsSessionScopeAndExportVisible`：1/1 通过；前后截图见 UI 审计文档。非空记录、删除确认、真实导出、深色、大字、VoiceOver、横屏和 iPhone 16 Pro 仍为 `VERIFY`。

### UI-036 · 插件设置 Host 空态收口（2026-08-31）

- `PluginSettingsView` 将 Host 未就绪和无 namespace 的整屏空态改为紧凑原生分组，强制“启动 Host”显示文字，并仅在已有 namespace 时展示搜索。
- Host 启动、刷新、设置快照、namespace 编辑器、保存和 revision 冲突逻辑没有改变，也没有新增依赖。
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -quiet -project HarnessMobile.xcodeproj -scheme HarnessMobile -destination 'platform=iOS Simulator,id=C87C4D99-A29A-45EE-9214-5FDB7D1F6EAD' -derivedDataPath /tmp/hm-plugin-settings-final ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test -only-testing:HarnessMobileUITests/HarnessMobilePluginSettingsUITests/testPluginSettingsShowsHostStateFromPluginRoute`：1/1 通过；前后截图见 UI 审计文档。真机 Host、namespace 列表/编辑器/冲突、深色、大字、VoiceOver 和横屏仍为 `VERIFY`。

### UI-037 · 聊天空态与错误恢复证据（2026-08-31）

- 真实入口截图确认空会话只保留单一输入提示和常驻输入栏，错误使用可关闭行内提示且不弹系统 Alert；消息操作继续保留 44pt 点击区。
- 本项没有生产 UI 改动；新增 `HarnessMobileChatChromeUITests` 空态与错误截图/交互断言，2/2 通过（`/tmp/hm-chat-chrome-audit/Logs/Test/Test-HarnessMobile-2026.08.31_19-36-38-+0800.xcresult`）。运行中、排队输入、附件、审批、长对话和真机矩阵仍为 `VERIFY`。

### UI-038 · 核心页面无障碍布局矩阵（2026-08-31）

- 首页、聊天、设置和 iSH 终端在深色模式、横屏、辅助功能 XXXL 字号组合下完成真实入口复核；项目、设置/工具、输入/发送、设置路由和终端运行均保持可达，主要操作至少 44pt。
- `HarnessMobileAccessibilityUITests` 4/4 通过（`/tmp/hm-accessibility-matrix-0831/Logs/Test/Test-HarnessMobile-2026.08.31_22-23-36-+0800.xcresult`），截图见 UI 审计文档。没有截图证据支持新增自定义布局，因此本项不改生产 UI；VoiceOver、其他设备尺寸和 iPhone 16 Pro 真机触控仍为 `VERIFY`。
- 当前签名构建 `/tmp/hm-device-ui-0831/Build/Products/Debug-iphoneos/HarnessMobile.app` 已通过 `devicectl` 覆盖安装到 iPhone 16 Pro，`com.llf.harnessmobile` 启动成功。安装/启动不代替逐页真机触控、真实权限、插件 Host 和 VoiceOver 验收。

### UI-039 · 轨迹首屏空诊断收口（2026-08-31）

- 轨迹页只在存在真实 Harness Trace 事件时显示运行时入口，删除“0 个检查点 · 0 个插件”占据首屏的无动作空态；Inspector、错误摘要和真实 Trace 内容路径保持不变。
- 搜索复用 SwiftUI 导航栏抽屉和 `avoidHidingContent`，避免自行维护搜索栏或固定底部高度。`HarnessMobileTrajectoryUITests/testTrajectoryLedgersSearchCollapseAndInspect` 1/1 通过（`/tmp/hm-trajectory-final3-0831/Logs/Test/Test-HarnessMobile-2026.08.31_22-54-22-+0800.xcresult`）；前后截图见 UI 审计。真实 Harness Trace、无障碍完整矩阵和真机仍为 `VERIFY`。

### UI-040 · 诊断日志说明收口（2026-08-31）

- 详细日志页将永久展开的导出清单/脱敏字段和采样隐私说明改为原生按需展开，同时保留本机脱敏、保存位置、默认关闭和有限系统数值摘要。刷新、导出、工作区副本、采样配置与错误路径不变。
- `HarnessMobileProgressiveDisclosureUITests/testDiagnosticLogKeepsRuntimeAndExportActionsReachable` 1/1 通过（`/tmp/hm-diagnostic-final-0831/Logs/Test/Test-HarnessMobile-2026.08.31_23-03-43-+0800.xcresult`）；前后截图见 UI 审计。真实导出、Host stderr、采样内容、无障碍矩阵和真机仍为 `VERIFY`。

### UI-041 · 工具授权空态收口（2026-08-31）

- 工具授权在没有长期授权时改为紧凑“暂无长期工具授权”，不再用大尺寸卡片错误显示“已记住”；始终允许保存条件、iOS 权限边界、非空授权范围和撤销逻辑保持不变。
- `HarnessMobileProgressiveDisclosureUITests/testToolApprovalsShowsRememberedGrantState` 1/1 通过（`/tmp/hm-approvals-final-0831/Logs/Test/Test-HarnessMobile-2026.08.31_23-15-53-+0800.xcresult`）；前后截图见 UI 审计。非空授权、撤销确认、无障碍矩阵和真机仍为 `VERIFY`。

### UI-042 · Agent Bundle 层级收口（2026-08-31）

- Agent 编排将内部英文分区标题统一为中文，删除与原生 Toggle 重复的启用状态胶囊，并将完整安装安全说明改为按需展开；固定来源、安装/重装/取消、校验、启用和错误逻辑不变。
- `HarnessMobileProgressiveDisclosureUITests/testAgentBundlesKeepsInstallControlsReachable` 1/1 通过（`/tmp/hm-agent-bundles-final-0831/Logs/Test/Test-HarnessMobile-2026.08.31_23-23-57-+0800.xcresult`）；前后截图见 UI 审计。真实 iSH 安装、取消/重装、启用、无障碍矩阵和真机仍为 `VERIFY`。

### UI-043 · 模型行为双态证据（2026-09-01）

- 模型行为页现有原生分组已经清楚：时间上下文默认只显示唯一开关，开启后按需显示时区与刷新间隔，因此不为改动而新增生产 UI。
- `HarnessMobileProgressiveDisclosureUITests/testProviderManagementMovesRequestBehaviorToFocusedSubpage` 1/1 通过（`/tmp/hm-provider-behavior-final4-0901/Logs/Test/Test-HarnessMobile-2026.09.01_08-26-39-+0800.xcresult`）；双态截图见 UI 审计。真实服务商请求、运行中禁用态、无障碍完整矩阵和真机仍为 `VERIFY`。

### UI-044 · 后台任务空态收口（2026-09-01）

- 聊天后台任务面板将整屏居中的空态改为顶部紧凑原生分组，继续复用 `harnessCompactListChrome()`；刷新、任务、输出、停止和子 Agent 路径不变。
- `HarnessMobileProgressiveDisclosureUITests/testJobsPanelKeepsEmptyStateAndRefreshReachable` 1/1 通过（`/tmp/hm-jobs-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_08-34-51-+0800.xcresult`）；前后截图见 UI 审计。非空任务、停止/输出、子 Agent、无障碍矩阵和真机仍为 `VERIFY`。

### UI-045 · 会话选项 Sheet 收口（2026-09-01）

- 会话选项复用 SwiftUI 原生 medium/large detent 和拖拽指示，默认不再铺满整屏，同时可上拉以容纳大字号；对话/轨迹、预设、运行、权限、模型、设置、任务和导出路径不变。
- `HarnessMobileProgressiveDisclosureUITests/testSessionOptionsKeepsConversationControlsReachable` 1/1 通过（`/tmp/hm-session-options-final2-0901/Logs/Test/Test-HarnessMobile-2026.09.01_08-46-10-+0800.xcresult`）；前后证据见 UI 审计。运行中禁用态、导出、无障碍完整矩阵和真机仍为 `VERIFY`。

### UI-046 · Agent 预设选择证据（2026-09-01）

- Agent 预设现有原生 medium/large sheet、共享图标、说明和选择态已清楚呈现四个系统预设，本项不为改动而新增生产 UI。
- `HarnessMobileProgressiveDisclosureUITests/testAgentPresetPickerShowsAllSystemPresets` 1/1 通过（`/tmp/hm-agent-preset-audit-0901/Logs/Test/Test-HarnessMobile-2026.09.01_08-49-58-+0800.xcresult`）；截图见 UI 审计。用户预设、损坏/锁定、运行中禁用、无障碍矩阵和真机仍为 `VERIFY`。

### UI-047 · 对话导出确认证据（2026-09-01）

- 原生导出确认框已清楚呈现脱敏任务、安全边界和 JSON/Markdown 两种格式，本项不新增自定义导出页或生产 UI。
- `HarnessMobileProgressiveDisclosureUITests/testConversationExportExplainsRedactionBeforeChoosingFormat` 1/1 通过（`/tmp/hm-export-audit2-0901/Logs/Test/Test-HarnessMobile-2026.09.01_08-56-51-+0800.xcresult`）；截图见 UI 审计。真实文件生成、脱敏抽检、文件选择器、无障碍矩阵和真机仍为 `VERIFY`。

### UI-048 · 项目重命名语义统一（2026-09-01）

- 首页项目的重命名页将“会话”显示文案统一为“项目”，不改变底层 Session、本机存储、80 字校验、取消或保存逻辑。
- `HarnessMobileProgressiveDisclosureUITests/testRenameConversationKeepsTitleValidationVisible` 1/1 通过（`/tmp/hm-rename-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_09-03-29-+0800.xcresult`）；前后截图见 UI 审计。实际保存、空值/超长/错误态、无障碍矩阵和真机仍为 `VERIFY`。

### UI-049 · 项目删除确认语义统一（2026-09-01）

- 首页项目的删除确认将标题和两种状态说明从“会话”统一为“项目”，保留原生危险操作层级、项目名、本机删除范围、工作区文件边界及原删除逻辑。
- `HarnessMobileProgressiveDisclosureUITests/testDeleteProjectExplainsLocalDataAndWorkspaceBoundary` 1/1 通过（`/tmp/hm-delete-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_09-10-31-+0800.xcresult`）；前后截图见 UI 审计。包含该 UI 提交的当前工作树产物 `/tmp/hm-device-ui-0901-cca9271/Build/Products/Debug-iphoneos/HarnessMobile.app` 已签名构建、覆盖安装并启动到 iPhone 16 Pro；实际删除、运行中停止、真实工作区保留、无障碍矩阵和逐页真机触控仍为 `VERIFY`。

### UI-050 · 首页新建项目入口统一（2026-09-01）

- 首页底部主操作从双气泡改为原生 `folder.badge.plus`，无障碍名称及空态统一为“新建项目”，并同步 `APP_FLOW.md`；Session 创建、存储、自动标题和 `/new` 命令逻辑不变。
- `HarnessMobileProgressiveDisclosureUITests/testHomeNewProjectEntryUsesProjectLanguage` 1/1 通过（`/tmp/hm-home-new-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_13-48-31-+0800.xcresult`）；前后截图见 UI 审计。空存储态、实际创建、自动标题、无障碍完整矩阵和真机触控仍为 `VERIFY`。

### UI-051 · 项目归档与恢复语义统一（2026-09-01）

- 首页项目的分叉、归档、恢复菜单、归档空态、范围标题和操作中无障碍提示统一为“项目”；SwiftUI 原生菜单、滑动操作及 Session 数据方法不变。
- `HarnessMobileProgressiveDisclosureUITests/testArchivedProjectActionsUseProjectLanguage` 1/1 通过（`/tmp/hm-archive-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_13-55-39-+0800.xcresult`）；前后截图见 UI 审计。真实恢复/分叉结果、空归档态、无障碍完整矩阵和真机触控仍为 `VERIFY`。

### UI-052 · 聊天添加内容菜单收口（2026-09-01）

- “添加内容”菜单删除与输入栏常驻按钮重复的“命令”，仅保留系统图片、相机和文件选择；常驻命令、附件处理和系统权限逻辑不变。
- `HarnessMobileChatChromeUITests/testAddContentMenuOnlyContainsAttachments` 1/1 通过（`/tmp/hm-chat-add-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_14-02-09-+0800.xcresult`）；前后截图见 UI 审计。真实照片/相机/文件选择、系统权限、取消路径和真机仍为 `VERIFY`。

### UI-053 · 聊天命令建议面板证据（2026-09-01）

- 命令建议现有内联列表在键盘展开时仍完整保留 5 个命令、滚动余量、输入和发送动作，复用共享图标与原生滚动，本项不新增生产 UI。
- `HarnessMobileChatChromeUITests/testCommandPaletteKeepsSuggestionsAboveComposer` 1/1 通过（`/tmp/hm-command-palette-audit-0901/Logs/Test/Test-HarnessMobile-2026.09.01_18-52-46-+0800.xcresult`）；截图见 UI 审计。命令筛选、参数补全、极限 Dynamic Type、VoiceOver、横屏和真机仍为 `VERIFY`。

### UI-054 · 运行中排队输入操作收口（2026-09-01）

- 排队输入逐条编辑、steer 和移除从三个 28×28 图标收成单一 44×44 原生菜单，保留禁用态、危险角色、全量 steer 和停止运行逻辑。
- `HarnessMobileConcurrentRunsUITests/testQueuedInputKeepsActionsReachableWhileRunning` 1/1 通过（`/tmp/hm-queued-final-0901/Logs/Test/Test-HarnessMobile-2026.09.01_19-03-34-+0800.xcresult`）；前后截图见 UI 审计。实际编辑/steer/移除、多条队列、无障碍矩阵和真机仍为 `VERIFY`。

### UI-055 · 轨迹事件检查器信息密度（2026-09-01）

- 工具调用与结果的事件检查器改为原生大尺寸 sheet，事件时间统一为中文年月日；原字段、技术值、JSON、滚动和关闭行为不变。
- `HarnessMobileTrajectoryUITests/testTrajectoryLedgersSearchCollapseAndInspect` 1/1 通过（`/tmp/hm-trajectory-inspector-final2-0901.xcresult`）；前后工具调用/结果截图见 UI 审计。深色、极限 Dynamic Type、VoiceOver、横屏和真机仍为 `VERIFY`。

### UI-056 · 插件编译失败详情语义（2026-09-01）

- 编译失败总摘要改用红色“失败”，日志统一中文 24 小时格式，结构化诊断改为纵向层级，并用系统搜索内容避让保证诊断可滚动到可点击区域；编译、安全拒绝、日志和目录逻辑不变。
- `HarnessMobilePluginManagementUITests/testCompilationFailureTraceExposesStagesLogsAndStructuredDiagnostic` 1/1 通过（`/tmp/hm-plugin-failure-final-0901.xcresult`）；前后截图见 UI 审计。真实下载/编译/重试、无障碍矩阵和真机仍为 `VERIFY`。

### UI-057 · GitHub 仓库安装 Sheet 收口（2026-09-01）

- GitHub 安装 Sheet 补充原生优先、iSH 回退和 API Key 隔离说明，并将默认高度收为 340pt；原仓库输入、覆盖开关、禁用态和安装逻辑不变。
- `HarnessMobilePluginManagementUITests/testGitHubInstallSheetKeepsRepositoryAndReplaceControlsClear` 1/1 通过（`/tmp/hm-plugin-github-final-0901.xcresult`）；前后截图见 UI 审计。真实下载/安装、覆盖结果、无障碍矩阵和真机仍为 `VERIFY`。

### UI-058 · 社区插件详情去重（2026-09-01）

- 删除与导航标题重复的插件名称行，让分类、兼容性和安装路径直接进入首个分区；说明、来源、安全确认和安装逻辑不变。
- `HarnessMobilePluginManagementUITests/testCommunityPluginCatalogDetailKeepsSourceAndInstallBoundaryVisible` 1/1 通过（`/tmp/hm-plugin-detail-final-0901.xcresult`）；前后截图见 UI 审计。真实安装、确认操作、无障碍矩阵和真机仍为 `VERIFY`。

### UI-059 · 已安装插件详情语言统一（2026-09-02）

- 将运行状态分区唯一残留的 `Loader entries` 用户标签改为“入口数”；技术值、启停、设置、更新和卸载逻辑不变。
- `HarnessMobilePluginManagementUITests/testInstalledPluginDetailKeepsRuntimeAndManagementClear` 1/1 通过（`/tmp/hm-installed-plugin-final-0902.xcresult`）；前后截图见 UI 审计。真实启停、更新、卸载、无障碍矩阵和真机仍为 `VERIFY`。

### UI-060 · 原生插件设置去重（2026-09-02）

- 删除与导航标题重复的插件名称行，让生效方式、存储和 schema 配置直接进入首屏；草稿、保存、放弃和默认值逻辑不变。
- `HarnessMobilePluginManagementUITests/testNativeAgentPluginSettingsKeepsRuntimeAndValueControlsClear` 1/1 通过（`/tmp/hm-native-plugin-settings-final-0902.xcresult`）；前后截图见 UI 审计。真实修改/保存/放弃、错误态、无障碍矩阵和真机仍为 `VERIFY`。

### UI-061 · 插件设置 Host 空态收口（2026-09-02）

- 将 Host 未就绪/启动中的三个普通列表行改为系统 `ContentUnavailableView` 空态和带可访问标识的 `ProgressView`；刷新、自动启动、失败重试和命名空间逻辑不变。
- `HarnessMobilePluginSettingsUITests/testPluginSettingsShowsHostStateFromPluginRoute` 1/1 通过（`/tmp/hm-plugin-settings-final2-0902.xcresult`）；前后截图见 UI 审计。真实 Host 启动结果、命名空间、无障碍矩阵和真机仍为 `VERIFY`。

### UI-062 · 插件设置命名空间语言统一（2026-09-02）

- 删除与导航标题重复的命名空间行，并将搜索、列表版本、状态、冲突、只读和通知中的 namespace/revision 用户文案统一为中文；命名空间 ID、revision fence、rebase 和 256 操作上限不变。
- `HarnessMobilePluginSettingsUITests/testPluginSettingsNamespaceKeepsStatusAndEditorVisible` 1/1 通过（`/tmp/hm-plugin-namespace-final-0902.xcresult`）；前后截图见 UI 审计。真实修改/冲突/只读/秘密字段、无障碍矩阵和真机仍为 `VERIFY`。

### UI-063 · 工具总览语言与主题收口（2026-09-02）

- 将任务说明中的 `Goal、Plan、Todo` 统一为“目标、计划、待办”，并删除共享列表壳后的重复背景覆盖；五个工具路由和页面结构不变。
- `HarnessMobileProgressiveDisclosureUITests/testHomePrioritizesProjectsAndMovesSecondaryToolsToToolsRoute` 1/1 通过（`/tmp/hm-tools-final-0902.xcresult`）；前后截图见 UI 审计。真实路由操作、无障碍矩阵和真机逐页触控仍为 `VERIFY`。

### UI-064 · Plan Review 框架标题中文化（2026-09-02）

- 将 Plan Review 弹层的 App 框架标题改为“计划审阅”；模型原始计划 Markdown、讨论/拒绝/批准动作及回调不变。
- `HarnessMobilePlanReviewUITests/testPlanReviewPresentsAllDesktopActions` 1/1 通过（`/tmp/hm-plan-review-final-0902.xcresult`）；前后截图见 UI 审计。真实动作回调、无障碍矩阵和真机触控仍为 `VERIFY`。

### UI-065 · 聊天运行状态中文化（2026-09-02）

- 将聊天运行状态 `Deep diving...` 及对应 VoiceOver 标签统一为“正在深入处理…”；计时、并发会话、停止和排队输入逻辑不变。
- `HarnessMobileConcurrentRunsUITests/testCreatingAndSwitchingSessionsKeepsBothRootRunsVisible` 1/1 通过（`/tmp/hm-chat-running-final-0902.xcresult`）；前后截图见 UI 审计。真实流式输出、运行计时、无障碍矩阵和真机切换仍为 `VERIFY`。

### UI-066 · 推理折叠标题中文化（2026-09-02）

- 将共享推理折叠标题 `Think` 改为“思考”；原始 reasoning、摘要、展开/折叠、流式进度和无障碍语义不变。
- `HarnessMobileChatChromeUITests/testReasoningDisclosureKeepsModelContentReachable` 1/1 通过（`/tmp/hm-reasoning-final-0902.xcresult`）；前后截图与首次错误断言说明见 UI 审计。真实流式/长推理、无障碍矩阵和真机仍为 `VERIFY`。

### DOC-001 · Harness 控制文档基线（2026-08-31）

- 新增 `PRD.md`、`DESIGN_SYSTEM.md`、`APP_FLOW.md`、`FRONTEND_GUIDELINES.md`、`BACKEND_STRUCTRUE.md`、`SECURITY_GUIDELINES.md`、`CAPABILITY_CATALOG.md`、`TECH_STACK.md`、`QUALITY_GUIDELINES.md`、`PLATFORM_GUIDELINES.md`、`IMPLEMENTATION_PLAN.md` 和 `DECISIONS.md`。
- `AGENTS.md` 作为唯一控制入口，定义必读路由、冲突优先级和文档同步规则；详细事实继续引用源码、测试和既有 `Docs/`，不复制 parity 长清单。
- 已验证 13 个入口文件存在且非空、全部相对链接可解析、`git diff --check` 通过。本项仅建立协作控制，不改变生产行为，因此不需要模拟器或真机验收。

### BG-014 · 到期恢复唤醒不依赖网络条件（2026-08-30）

- 系统 continued-processing 到期后的恢复请求改为提交一个不要求联网的 `BGProcessingTaskRequest`。固定要求网络会让 iOS 在短暂断网时连本地恢复 handler 都不唤醒，导致切屏后只能等用户重新打开 App；恢复 handler 仍在本机执行，模型请求由现有 Provider 重试策略等待网络恢复。
- 普通 schedule 任务继续保持 `requiresNetworkConnectivity = true`，避免改变定时任务的原有调度语义；恢复请求与普通 schedule 共用一次性 pending identity claim，不会重复启动同一个 run。
- 后台 SwiftPM 定向测试 26/26 通过；真实 iOS 调度、系统后台时间额度、断网后恢复和 iPhone 16 Pro 长时切屏仍为 `VERIFY`。该改动不能延长服务商账户额度，也不能绕过 iOS 的系统后台限制。

### BG-015 · 冷启动恢复重新挂载完整 RunIdentity（2026-08-30）

- 修复后台进程被系统回收后的恢复缺口：`BackgroundRunJournal` 审计现在返回完整 `RunIdentity`，启动/前台审计会重新登记到 `SessionBackgroundResumeCoordinator`；会话状态恢复后立即尝试挂载前台恢复监视器，BGProcessing 唤醒也能领取同一身份，避免“日志显示可恢复但没有恢复对象”。
- 保留一次性 identity claim 和 durable interrupted 状态；没有新增无限后台循环，也不能延长服务商 API 额度或绕过 iOS 系统调度。新增 journal 回归断言，真机冷启动、jetsam、锁屏与长时后台仍为 `VERIFY`。

当前工作树最近一轮：SwiftPM `822` tests、`3` skipped、`0` failures；Xcode arm64 generic simulator 与已签名 iPhone device build succeeded；iSH libraries/rootfs 重建、Host check、Node smoke、无远程执行审计、upstream parity 和 `git diff --check` 均通过。新增的 12 个 typed capability tools 已进入当前 production/NativeAgent 目录。当前 UI 签名构建已通过 `devicectl` 覆盖安装到 iPhone 16 Pro 并成功启动；逐页真机触控、切屏、各系统权限弹窗后的真实数据结果、插件批量覆盖率和长时压力测试仍待逐项执行。产物审计确认没有旧 offload handler 源对象或注册符号。

## 已归档完成能力（不再作为待办）

`BASE-001..006`、`WIRE-001/002/004`、`IMG-001/002/008`、`TOOL-013`、`CMD-005/007`、`PROVIDER-003`、`WEB-001..003`、`CTX-003..006`、以及已通过自动化门的 Cordis generation/Prompt 单例、凭据误报修复、trace session 归属、UI-010/011 基础实现，均已从活动清单移除。它们的实现和测试仍保留在工作树与 git 历史中；只有真机边界仍在上面的 VERIFY 项中追踪。
