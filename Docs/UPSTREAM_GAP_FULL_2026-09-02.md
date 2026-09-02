# 移动端 vs DeepSeek Harness v0.1.2-alpha.5 全量差距清单

> 审计日期：2026-09-02。上游 `49a606bc5`（v0.1.2-alpha.5）vs 移动端锚定 `b150a551`（v0.1.1-rc.2）。
> **本文档不做边界筛选**——之前判定为产品边界外、实验性、平台不适用的项目**全部列出**，供完整评估。
> 可行性判断另见 `Docs/UPSTREAM_UPGRADE_ROADMAP_2026-09-02.md`；本文档只回答"差在哪"。

## 0. 规模对照

| 项 | 上游（packages） | 移动端 |
| --- | --- | --- |
| 包/模块 | 256 个 npm 包 | — |
| TS 源文件 | ~2430 个 | — |
| Swift 实现文件 | — | 191 个 / 102,448 行 |
| Swift 测试 | — | 92 个 / 31,749 行 |
| UI 专项测试 | — | 1,879 行（11 个类） |
| 会话事件类型 | 51 | 56（含 5 个移动端自有） |
| Cordis 插件 API 符号 | 847 | 桥接实现，非符号级对齐 |
| 工具/扩展包 | 25 | 53 个生产工具名（自有命名体系） |

差距总量：锁定版至今 **1771 个提交、7696 文件、+389,701 / −171,199 行**。

---

## 1. 域级全量对照（43 个域）

图例：✅ 能力对齐 · 🟡 部分对齐/形态不同 · ❌ 缺失

| # | 上游域（包数） | 移动端 | 状态 | 具体差距 |
|---|---|---|---|---|
| 1 | **acp**（1） | 无 | ❌ | 无 Agent Client Protocol 客户端 |
| 2 | **api**（5：gateway/remotes/session-controller/settings-controller/workspace-controller） | `AppModel`（约 8600 行单体） | 🟡 | 上游按职责拆 5 个控制器；移动端单体 AppModel |
| 3 | **attachment**（2） | `AgentImageAttachment` | ✅ | — |
| 4 | **boot**（2：app-boot/cmdline） | App 启动流程 | 🟡 | 无 CLI 形态（cmdline） |
| 5 | **bundle**（6：acp-app/base/headless/sdk-app/sdk-minimal/web-app） | `AgentProviderBundle` | 🟡 | 上游 6 种发行形态，移动端 1 种 |
| 6 | **client**（**49 个 UI 包**） | SwiftUI 原生重写 | ❌ | 上游 Web 客户端 49 包：`ui-chat`/`ui-session`/`ui-trajectory`/`ui-model-selection`/`ui-approval`/`ui-goal`/`ui-plan`/`ui-subagent`/`ui-workspace`/`ui-settings-*` 等；移动端是独立原生实现，**不是端口** |
| 7 | **code-runtime**（2） | `code_execute`/`run_code`/`CodeModeTool` | 🟡 | 上游有独立 worker-thread 运行时 |
| 8 | **compaction**（4：含 tool-result-pruner） | `ConversationCompactor` | 🟡 | 上游拆策略包（工具结果剪枝） |
| 9 | **context**（6：含 tmux-context） | `ContextInjection`/`HarnessReference` | 🟡 | 缺 tmux-context（终端会话上下文） |
| 10 | **core**（11：agent/agent-loop/scope/session/system-prompt/tools…） | `AgentRuntime`（约 4600 行） | 🟡 | 上游拆 11 包（含 `scope`、`agent-tool-presentation`、`agent-default-model`） |
| 11 | **credentials**（3：含 authorization） | `CredentialStore` | 🟡 | **缺 authorization**（OAuth/授权流） |
| 12 | **e2b**（3：e2b/fs-e2b/subprocess-e2b） | 无 | ❌ | 远程沙箱全缺（移动端产品边界：禁远程执行） |
| 13 | **experimental**（9：agent-team×3/code-runtime-python/inspector/webworker×2/client-ui-agent-team） | inspector 类部分 | ❌ | agent-team、Python 运行时、webworker 全缺 |
| 14 | **extensions**（4：tool-cordis/ui-cordis/cordis-host-runner/cordis-client-runner） | `CordisPluginRuntime`+`CordisAgentServices`+`CordisHarnessTraceProjection` | 🟡 | 上游 host/client runner 分离；API 847 符号 vs 移动端桥接 |
| 15 | **feedback**（2） | `MessageFeedbackSidecar` | ✅ | — |
| 16 | **fs**（7：含 fs-observation-policy/fs-sandbox） | `FileSystemTools`/`WorkspaceTools`/`StrReplaceEditorTool` | 🟡 | 上游有观察策略与 fs-sandbox 层 |
| 17 | **goal**（4：goal/goal-round-driver/command-goal/tool-goal） | `WorkStateCoordinator` | 🟡 | **缺 `goal-round-driver`**（目标驱动的自动续行）；`get_goal` 已由 `work_state_get` 补齐 |
| 18 | **guard**（2） | `RepeatToolReminder`/`TimeoutPolicy` | ✅ | — |
| 19 | **hooks**（3：hook-protocol/hooks-claude-code/hooks-codex） | 仅 `hook/invoked`、`hook/result` 事件名在兼容表 | ❌ | **无 hook 执行能力**（上游可挂 Claude Code / Codex 钩子） |
| 20 | **host**（6：directory-picker×4/frontend-static/plugin-inventory/webserver） | 无 | ❌ | 桌面宿主能力（目录选择器、静态前端、webserver）；移动端用系统文件选择器 |
| 21 | **identity**（1） | 无 | ❌ | 匿名 ID 遥测身份 |
| 22 | **interaction**（5：commands/permission-presets/tool-ask-user/user-approval/user-questions） | `UserInteractionTools`/审批/`ToolApprovalRequest` | 🟡 | **缺 permission-presets**（权限预设集） |
| 23 | **jobs**（3） | `HarnessJobs` | ✅ | — |
| 24 | **llm**（7：llm/llm-deepseek/llm-pi-ai/llm-retry/**deepseek-llm-api-extensions**/token-meter/plugin-package-inventory-deepseek） | `ModelProviderCatalog` | 🟡 | **缺**：请求扩展机制（插件注入请求字段）、`llm-pi-ai`（第三方模型库适配）、`token-meter`（token 计量）、插件包清单 |
| 25 | **lsp**（3） | `LSPTool` | ✅ | — |
| 26 | **mcp**（1） | `MCPClient` | ✅ | — |
| 27 | **plan**（1） | `exit_plan_mode` | ✅ | — |
| 28 | **preset**（2：agent-presets/persona） | `AgentPresets` | 🟡 | **缺 `persona`**（角色/人格）；预设组合化（Composition/Roster）未跟进 |
| 29 | **runtime-diagnostics**（1：invariants） | `RuntimeTelemetry` | 🟡 | 上游有运行时不变量校验框架 |
| 30 | **sandbox**（4：含 sandbox-policy/sandbox-windows-acl） | `ISHSandboxCoordinator` | 🟡 | 上游有独立策略层；移动端 iSH 沙箱 |
| 31 | **schedule**（1） | `HarnessSchedules` | ✅ | — |
| 32 | **sdk**（3：client/protocol/server） | 无 | ❌ | **服务端 SDK 全缺**（headless 服务形态） |
| 33 | **session**（**14**：persistence/projection/stats/telemetry/telemetry-otel/checkpoint-policy/**session-turn-outline**/**session-log-deepseek**/session-title×4） | `SessionStore` | 🟡 | **缺**：turn-outline（回合大纲）、stats、telemetry（OTel 导出）、checkpoint-policy、projection-cache、三个 LLM 标题实现 |
| 34 | **session-query**（4：含 session-query-sqlite/session-log-export） | `SessionQueryReadModel` | 🟡 | **缺** sqlite 查询后端与日志导出包 |
| 35 | **settings**（2） | `SettingsStore` | ✅ | — |
| 36 | **shell**（9：bash/pwsh × local/sandbox/persistent + shell-env） | `ISHShellTool` | 🟡 | 上游 4 种 shell 形态（含 pwsh、持久化会话）；移动端 1 种（iSH） |
| 37 | **skill**（4：含 skill-badge/skill-filesystem） | `MobileSkillRegistry` | 🟡 | **缺 skill-badge**（技能徽标/市场展示） |
| 38 | **spill**（3：含 spill-policy） | `ToolResultSpillStore` | 🟡 | 上游有独立策略层 |
| 39 | **storage**（4：含 storage-sqlite） | `WorkspaceStore`/`SessionStore` | 🟡 | 上游有 sqlite 后端；移动端 JSON/自有持久化 |
| 40 | **subagent**（**10**：subagent/**subagent-acp**/**subagent-claude-code**/**subagent-codex**/**subagent-dsh-sdk**/in-process×3/tool-subagent/tool-subagent-control） | `JobTools`/`LocalSubagentRunner` | 🟡 | **缺多后端**（ACP / Claude Code / Codex / DSH SDK）与 in-process 驱动；移动端单一本地实现 |
| 41 | **subprocess**（3：含 win32-process） | 无（iSH 内执行） | 🟡 | 无原生子进程；移动端走 iSH（产品边界） |
| 42 | **terminal**（3：含 terminal-bash） | `ISHTerminalProvider` | 🟡 | 上游有 bash 会话终端包 |
| 43 | **test-support**（6：agent-loop-testkit/llm-mock-server/llm-replay/loader-smoke/session-snapshot/client-runtime） | 无对应 | ❌ | **缺上游的契约测试工具链**（快照、回放、mock server、loader 冒烟） |

### 其余域

| 域 | 移动端 | 状态 | 差距 |
|---|---|---|---|
| **todo** | `work_state_replace_todos` | ✅ | 命名差异（IOS-REPLACEMENT） |
| **typert**（4：generator/loader/protocol/registry） | 无 | ❌ | TS 类型化 RPC 框架（桌面协议层） |
| **util**（12：crypto/deque/time/values/workspace-path/atomic-write/output-retention/launch-environment/native-command/home-paths/brand/timeout） | 零散实现 | 🟡 | 无独立工具库分层（`crypto`/`deque`/`values`/`workspace-path` 等） |
| **web**（6：含 web-search-exa/web-search-perplexity） | `WebFetchTool`/`WebSearchTool`/`HarnessBrowserTool` | 🟡 | **缺 Exa / Perplexity 搜索后端**（有 DeepSeek search） |
| **webhook**（2：webhook/webhook-github） | 无 | ❌ | 全缺 |
| **workflow**（4：含 workflow-worker-thread） | `WorkflowTool`/`RalphTool` | 🟡 | 上游有 worker-thread |
| **workspace**（1） | `WorkspaceView` | ✅ | — |

---

## 2. 跨切面差距

### 2.1 会话事件（已精确 diff）
- 上游 51 / 移动端 56（含 5 个移动端自有：`llm/request-audit`、`question/requested`、`question/resolved`、`subagent/lifecycle`、`subagent/output`）
- **兼容表已全覆盖**（U-010 完成）；语义层仍缺：`subagent/model-selection-policy`（待能力决策）、`model/selection` 已完成
- `team/*` 4 个（agent-team）仅在兼容表，无实现

### 2.2 Cordis 插件 API
- 685 → 847 符号（+191 / −29）
- **架构换代**：`CordisRuntime(Realm/Node/Fiber/Tree/Source)` 取代 `Rpc*`/`Inbox*`/`ApprovalService`
- 已核对：移动端不依赖被移除符号 → 无破坏，但有**契约代差**

### 2.3 工具面
- 上游 25 个工具包，无新增（仅删 `tool-subagent-report`）
- 移动端 53 个生产工具，属自有命名体系（IOS-REPLACEMENT）
- 真缺的工具能力：`list_subagent_models`、Cordis 工具族（`cordis_mount/define/run/inspect`）、`team_task_*`/`spawn_teammate`、`create_goal/get_goal/update_goal`（部分已补）

### 2.4 命令
- 命令分包与 `'/xxx'` token：**零增零减**
- `/goal` 语义对齐（移动端多 `complete`/`block`）

### 2.5 测试基础设施（差距显著）
- 上游新增 `test-support/session-snapshot`，全仓新增 541 个快照文件
- 上游有 `llm-mock-server`、`llm-replay`、`agent-loop-testkit`、`loader-smoke`
- 移动端：823 SwiftPM 测试 + 11 类 UI 专项，**无契约快照回放工具链**

---

## 3. 平台形态差距（先前标为边界外，此处如实列出）

| 上游形态 | 移动端 | 说明 |
| --- | --- | --- |
| Web 客户端（client 域 49 包） | 无（原生重写） | 形态差异，非缺陷 |
| 桌面宿主（directory-picker / webserver / frontend-static） | 无 | 移动端用系统选择器 / 无本地 webserver |
| 服务端 SDK（sdk / headless / server） | 无 | 产品定位为设备内执行 |
| 远程沙箱（e2b） | 无 | 安全边界：禁止远程执行 |
| webworker 运行时 | 无 | 浏览器形态 |
| Python 代码运行时 | 无 | 移动端用 iSH / 原生代码执行 |
| CLI（cmdline / acp-app / sdk-app） | 无 | 移动端 App 单一形态 |
| hook 扩展（Claude Code / Codex） | 无 | 需 hook 执行能力 |
| webhook（GitHub） | 无 | 设备内执行边界 |
| tmux / PowerShell / Windows ACL / win32 进程 | 无 | 平台不适用 |

---

## 4. 一句话总结

移动端在**核心 Agent 循环、工具执行、会话持久化、凭据、任务调度、LSP/MCP、技能、工作流**这些主干能力上与上游**基本对齐**（且有一批 iOS 原生增强：相机 OCR、设备时间、诊断、iSH 终端/沙箱、后台续跑、灵动岛/锁屏、工作区状态）；差距集中在：

1. **架构分层**（上游 256 包细粒度拆分 vs 移动端单体大文件）
2. **插件生态契约**（Cordis 847 符号 + CordisRuntime 换代 + 请求扩展机制）
3. **子 agent 多后端**（ACP/Claude/Codex/SDK）
4. **可观测性**（session-stats / telemetry-OTel / turn-outline / token-meter）
5. **测试工具链**（快照回放 / mock server）
6. **桌面与服务端形态**（此处列出的全部平台形态差距）
