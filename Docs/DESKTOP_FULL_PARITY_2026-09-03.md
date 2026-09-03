# 桌面全对齐改造方案（Deskparity 2026-09-03）

目标：移除移动端自设的插件安全模型与能力前置，插件定义、运行、工具面与 DeepSeek Harness 桌面版完全对齐。控制文档硬边界同步修订。本文档是改造的单一真源；按节执行，每节验证通过再进下一节。

## 0. 现状核对（证据）

- iSH Host（`HarnessMobile/Resources/PluginHost/host.mjs`）**已 import 上游完整栈**：`@deepseek-ai/cordis`、`dsh-agent`、`dsh-session`、`dsh-commands`、`dsh-skill`、`dsh-session-query`、`dsh-tools`、`dsh-cordis-host-runner`、`dsh-tool-cordis`（L64-75）。
- Host 系统提示（host.mjs L163）已声明模型可用 `cordis_inspect_list/query/self/define/run/stop/undefine` 7 工具。
- 移动端桥接 `ISHHostedCordisTool`（`ISHPluginHostCordisBridge.swift`）已能暴露 Host 贡献工具，`contributionMutationTools` 含 `cordis_define/run/stop/undefine`，risk `.sideEffect`——即**7 工具到模型的通路已存在**。
- 移动端模型工具目录（`ProductionToolCatalog`）目前只注册 `plugin_marketplace` 一个插件工具；`plugin_marketplace` 的默认路径是「先 native 编译，不适配才 iSH」。

**结论**：桌面对齐的执行面已在设备上，差距在「默认路径与工具面仍被移动端自设模型主导」，而非能力缺失。

## 1. 控制文档修订（先改，后按新文执行）

### AGENTS.md
| 位置 | 原文 | 改后 |
|---|---|---|
| L90 项目边界末条 | `动态插件只走审计过的 native manifest 或 iSH Host JS；不动态加载下载的 Swift/机器码，不暴露任意 Web/React 插槽。` | `插件与桌面版一致：模型可用 host 运行时动态 define/run/stop/undefine Cordis 包；执行发生在本地 host（iSH node）或 JavaScriptCore，加载任意 Cordis/npm 生态包。不加载下载的 Swift/framework 原生二进制（平台工具链限制，见 §4）；不引入远程 executor。` |
| L9-12 控制文档表「何时必读」 | — | DECISIONS.md 增加 D-010（见下）。 |

### SECURITY_GUIDELINES.md
| 位置 | 原文 | 改后 |
|---|---|---|
| L30 | `模型只能调用生产工具目录或验证后的动态贡献；未知工具失败关闭。` | `模型可调用生产工具目录与 host 动态贡献（cordis_* 生命周期工具、插件贡献工具）；host 贡献随运行状态同步，未同步的旧贡献失败关闭。` |
| L31 | `iSH/插件不得启动 host 或远程 executor，也不得加载下载的 Swift、framework、native addon 或机器码。` | `iSH/插件不得启动远程 executor 或加载下载的 Swift/framework/机器码；允许加载 Cordis/npm JS 生态包。.node 原生 addon 受 iSH 工具链限制（§4），在设备上明确报平台限制错误而非安全拒绝。` |

### DECISIONS.md
| 决策 | 处理 |
|---|---|
| D-008「动态代码限制」 | 由新决策 **D-010「桌面级插件对齐」取代**。D-010：插件执行模型 = 本地 host 运行时（iSH node），模型可用 cordis_* 7 工具动态 define/run/update/stop/undefine；可加载任意 Cordis/npm JS 包；native 声明式清单保留为可选后端（A3 决策），不再是默认或前置。Browser Client-half/React slot/.node addon 因移动端无浏览器容器与工具链列平台限制（§4），非安全拒绝。 |
| D-001「设备内执行边界」 | 保留并重述：对齐桌面也是本机执行；禁止远程 executor 不构成能力差异。 |

## 2. 能力差距与改造设计

## 执行状态（2026-09-03 更新）

| 阶段 | 状态 | 证据/提交 |
|---|---|---|
| P0 | ✅ 提交 | `7fa2030f`（方案+AGENTS/SECURITY/DECISIONS D-010） |
| P1 host 侧 | ✅ 已验证 | Mac node 真实栈 assemble = 7 工具；`ISHPluginHostNodeSmoke` exit=0（含 contributions 7 工具 + cordis_inspect_list/query 真实调用断言，已有） |
| P1 移动端同步 | 🔶 代码完整 | `synchronizeISHPluginHost → contributions → bridge definition → registerTool` 链路存在；模拟器端到端 = VERIFY |
| P2 默认路由 | ✅ 模型层+UI | `0300d228`（install 默认 hostLoad、native 显式 opt-in）+ 本提交（UI 文案/策略语义）；市场 UI 测试绿 |
| P3 npm 生态 | ✅ 已实现 | `marketplace.reconcileRuntime` npm install（registry 镜像 + `healHostPackages` 宿主包复用 + addon **平台限制错误**（D-010 语义，非安全拒绝）+ 依赖树上限）；安装即 `npm pack`→runtime。无需新增 |
| P4 UI 面 | ✅ 已对齐 | 市场装载 + 已安装启/停/卸管理 + 模型 cordis_* 7 工具动态管理 = 桌面工具型管理同构；运行状态可视化为可选增强 |

### A1 模型插件工具面：7 工具直通（P1）
- 目标：模型看到 `cordis_inspect_list / cordis_inspect_query / cordis_inspect_self / cordis_define / cordis_run / cordis_stop / cordis_undefine`（与桌面一致），不经 native 编译前置。
- 设计：Host 装载 `tool-cordis` 后把 7 工具贡献给移动端；`ISHHostedCordisTool` 已支持，需确认贡献同步链路（host 启动后贡献枚举 → AppModel 工具目录注册）在 7 工具上实际生效；补端到端验证（P1 门）。
- 修改点：`AppModel+NativePluginLifecycle` / `ISHPluginHostDynamicLifecycleCoordinator` 的贡献同步；必要时 `ProductionToolCatalog` 增直通 stub（host 未运行时给明确错误）。

### A2 默认安装路径去 native 前置（P2）
- 目标：市场/来源安装 = host 全栈装载（同桌面 npm 包装载）；不再「先 native 编译」。
- 修改点：`AppModel+PluginMarketplaceTool.swift` 的 `installISHMarketplacePlugin` 默认分支；UI 文案（CommunityPluginMarketView「安装先尝试原生编译…」改为桌面装载语义）；`ISHMarketplaceNativeInstallStrategy` 默认值。

### A3 native manifest 后端的存废（P2 决策点）
- 事实：native 是移动端独有的 LLM 编译声明式路径（上游无）。
- 方案（文档默认采纳）：**保留为可选后端**，通过 `cordis_define` 的 code.client/纯 prompt 插件仍可走它；市场安装不再默认。若你倾向彻底移除（只留 host 全栈），执行 P2 时把 `installNative`/`NativeAgentPluginCompiler` 从默认路由摘除并标记退役，代码暂留供回滚。

### A4 Cordis/npm 生态包安装（P3）
- 目标：插件可 `npm install` 任意 cordis 生态依赖（与桌面一致，桌面也装 npm 包）。
- 事实核对（P3 前置）：`PluginHost/install.sh` 现有锁定依赖安装；需扩展为「包清单 + npm install + integrity 记录」并维持锁文件。
- 边界审计脚本（audit-no-remote-execution.sh）相应更新（JS 生态网络安装属于 host 构建行为，非运行时远程执行）。

### A5 动态注册表状态可见（P1 内）
- `cordis_inspect_list/query` 提供注册表/当前 run 状态；确认跨模型请求保持（host 进程内 registry），补验证。

## 3. 保留现有（不构成差异）

- 目标自动续行、会话统计、输出保留、压缩剪枝、遥测：上游能力，已对齐（见 UPSTREAM_UPGRADE_ROADMAP 实现级复核）。
- iSH 沙箱边界（ISHSandboxCoordinator）：保持（与桌面 sandbox 同职责）。

## 4. 平台物理限制（如实列出，非安全拒绝，执行时给明确平台错误文案）

| 限制 | 原因 | 处理 |
|---|---|---|
| Browser Client-half / React slot | 移动端无浏览器 UI 容器 | 桌面 client 包在移动端不装载；报「桌面 Web UI 不适用」 |
| `.node` 原生 addon | iSH 无对应工具链、iOS 无 dlopen 动态库 | 报平台限制错误，不静默 |
| 下载的 Swift/framework 二进制 | iOS 无运行时 JIT/dlopen | 保持禁止（平台限制而非安全模型） |

## 5. 实施顺序（阶段门）

| 阶段 | 内容 | 验证门 |
|---|---|---|
| P0 | 本文档 + AGENTS.md/SECURITY/DECISIONS D-010 修订提交 | `git diff --check`；文档一致性 |
| P1 | A1+A5：7 工具直通 + inspect 状态跨请求 | 模拟器 iSH host 运行，模型目录见 7 工具；`cordis_inspect_list` 真实返回 |
| P2 | A2+A3：去 native 前置；native 保留可选/退役决策执行 | 市场安装走 host；真实插件 define→run→stop 全链路 |
| P3 | A4：npm 生态安装 | 带依赖的真实 cordis 插件安装成功 |
| P4 | UI 面：贡献/库存/运行状态管理对齐桌面 | UI 截图 + 无障碍走查 |

每阶段小步提交、可回滚；测试失败记录真实错误文本再定位。真实 API/iSH/插件属真机验收项，无设备证据保持 `VERIFY`。

## 6. 待你拍板（P2 前确认）

1. A3：native manifest **保留为可选后端**（默认建议）还是**整体退役**？
2. A2：市场里已有的「原生优先」徽章/文案是否直接改为 host 装载，还是保留双标签（原生可选）？
3. §4 平台限制文案语言（中/英）与展示位置（详情页 compatibility 区）。
