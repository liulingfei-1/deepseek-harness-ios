# 移动端 → 上游 v0.1.2-alpha.5 升级改造路线图

> 目标：把移动端从 `b150a551`（dsh-v0.1.1-rc.2）推进到 `49a606bc5`（dsh-v0.1.2-alpha.5）。
> 用法：按阶段顺序执行，每完成一条勾选一条。每条独立、可回滚、可单独验证。
> 配套文档：`Docs/UPSTREAM_DRIFT_2026-09-02.md`（漂移分析）、`Docs/DESKTOP_PARITY.md`（当前基线）、`Docs/DESKTOP_PARITY_REMEDIATION.md`（逐项日志）。

## 0. 总览

| 阶段 | 主题 | 条目数 | 是否改实现 | 风险 |
| --- | --- | --- | --- | --- |
| P0 | 准备与审计 | 3 | 否 | 无 |
| P1 | 契约补齐（事件/命令） | 4 | 小 | 低 |
| P2 | 工具面对齐 | 6 | 中 | 中 |
| P3 | Cordis 架构跟进 | 3 | 大 | 高 |
| P4 | 新能力（可选） | 4 | 大 | 中 |
| P5 | fixture 推进与验证 | 3 | 小 | 低 |

**红线（不得违反）**：wire 核心事件保持向后兼容；不破坏 `CompatibilityFixtures/` 现有锚点；不引入远程执行；不扩展产品边界（服务端/webworker 能力维持 `OUT-OF-SCOPE`）。

---

## P0 · 准备与审计（先做完再动代码）

### U-001 建立升级分支与审计快照
- 文件：`Dependencies/upstreams.lock.json`（暂不改）
- 动作：`git switch -c upgrade/dsh-0.1.2-alpha.5`；记录当前 parity 基线输出留档
- 验证：`Scripts/check-upstream-parity.sh` 输出存为 before 快照
- 状态：⬜

### U-002 只审计地切到新上游
- 文件：`Dependencies/upstreams.lock.json` 的 `deepseekHarness.commit` → `49a606bc5`
- 动作：checkout 上游到新 commit，重跑 `Scripts/check-upstream-parity.sh`，产出新增包与 API 差异清单
- 验证：脚本退出 0；差异清单归档
- 风险：此时所有本地 parity 断言会失配——**先只记录不改实现**
- 状态：⬜

### U-003 复核移动端自有扩展（避免误删）
移动端有、上游无的事件（**保留，不要"对齐"掉**）：
`llm/request-audit`、`question/requested`、`question/resolved`、`subagent/lifecycle`、`subagent/output`

移动端有、上游无的工具（**保留**）：
`camera_ocr`、`device_time`、`diagnostics_read`、`browser_use`、`shell_execute`、`terminal_*`、`workspace_*`、`work_state_*`、`subagent_control`、`subagent_list`、`plugin_marketplace`、`session_event_get`、`session_event_types`、`deliverable_write`、`exit_plan_mode`
- 动作：在 parity 清单中显式标记为 `IOS-REPLACEMENT` / 移动端原生能力
- 状态：⬜

---

## P1 · 契约补齐（最高性价比，先做）—— 4/4 已核对，1 项待产品决策

### U-010 新增事件 `model/selection` ⭐ 必补
- 现状：上游 45 个事件类型，移动端 43；`model/selection` 缺失，导致 `/model` 切换不进轨迹
- 文件：`HarnessMobile/Core/Trace/SessionEventTrajectory.swift`（事件常量 + 投影）、`HarnessMobile/App/AppModel.swift`（发送点）
- 动作：新增事件常量；`/model` 执行成功时写入事件；轨迹视图加对应渲染分支
- 验证：SwiftPM 新增单测；UI 测试断言切换模型后轨迹出现该事件
- 状态：✅ 已完成（提交 `U-010` 段）
  - 兼容表补齐上游 v0.1.2 全部新增事件名（7 个），上游 51 项**完全覆盖**
  - `SessionEventVocabulary.modelSelection` 常量 + `/model` 成功后 `recordModelSelection(_:reasoning:)` 写入（payload 对齐上游 `provider`/`model`/`reasoningEffort`）
  - 轨迹页新增中文渲染分支（"模型 · provider / model"，副标题显示推理强度）
  - 新增 2 个测试：事件恢复取值 + 兼容表漂移守卫（含移动端自有 5 项不得丢失）

### U-011 事件 `subagent/model-selection-policy` —— 兼容层已补齐，能力层待决策
- **兼容层**：✅ 已完成（事件名已进 `upstreamKnown`，读到上游日志不会被拒）
- **能力层**：⏸ 待产品决策，原因（已核对上游契约）：
  - 上游语义是**子 agent 模型选择的 opt-in 开关**：payload `{ allowedModels: [{provider, model}] }`，在首个模型请求前 append 一次，log-only，投影状态 `AllowedModelRoute[] | null`
  - **缺失该事件在上游即表示"固定路由"**（子 agent 继承父会话模型）
  - 移动端现状：子 agent 描述符事件（AppModel 4832-4833）只记录继承的 `agentProvider`/`agentModel`，无 `allowedModels`、无 `list_subagent_models` 工具 → **当前语义与"固定路由"一致，不写该事件是正确行为**
  - 要补此事件，必须先实现能力：子 agent 可用模型白名单 + `list_subagent_models` 工具 + 委派时的路由校验（属 P2 U-020）
- 决策选项：① 保持固定路由（推荐，移动端模型目录小、无必要让子 agent 换模型）② 实现可选模型能力（见 U-020）
- 状态：兼容层 ✅ / 能力层 ⏸

### U-012 评估事件 `agent/inbox/spliced`
- ~~动作：判断是否需要补该事件~~
- 状态：✅ **无需改动**（核对更正）
  - 初次自动化 diff 用 `"[a-z]+/[a-z-]+"` 正则，漏掉了含双斜杠的 `agent/inbox/spliced`，误报为缺失
  - 实际 `SessionEventVocabulary.upstreamKnown` 原本就已包含该名字；本轮已用完整范围重新核对，上游 51 项全部覆盖
  - inbox 语义移动端为自有实现，保持 `IOS-REPLACEMENT` 标注即可

### U-013 slash 命令词汇核对（预期无变化，用于回归）
- 现状：上游命令词汇 17 项，锁定版同为 17 项，**本次无变化**；移动端 10 个命令为有意精简
- 动作：升级后重跑命令词汇对比，确认仍为 17 且移动端 10 个未被上游语义变更影响
- 验证：`Scripts/check-upstream-parity.sh` 的 Slash commands 段
- 状态：✅ 已核对（无变化）
  - 命令分包（`command-compact`/`command-feedback`/`command-goal`）清单 lock→new **完全一致**
  - 全仓 `'/xxx'` 命令 token 对比：**新增 0、移除 0**
  - `command-goal` 有改动但无行为变化：删除的 `invariant.ts` 是空实现样板；README 为文档扩充
  - `/goal` 语义与移动端对齐（create/edit/pause/resume/clear）；移动端另有自有 `complete`/`block` 子命令，保留

---

## P2 · 工具面对齐（按能力域，不按字符串）

> 移动端工具命名是自有体系（iSH/原生替代），**不做字符串级改名**。按能力域核对覆盖度。

### U-020 子 agent 模型枚举：`list_subagent_models`
- 上游：`packages/subagent/tool-subagent/src/list-models.ts`
- 移动端：无对应工具（有 `subagent`/`subagent_fork`/`subagent_control`/`subagent_list`）
- 动作：新增 `list_subagent_models` 工具（读取可用子 agent 模型与策略）
- 状态：⬜

### U-021 会话查询工具命名收敛
- 上游：`session_search`、`session_event_search`、`session_trace`、`session_event_trace`、`session_event_read`
- 移动端：`session_search`、`session_trace`、`session_event_get`、`session_event_types`
- 动作：评估是否补 `session_event_search`/`session_event_trace`（或保持 `session_event_get` 并在 parity 标注 IOS-REPLACEMENT）
- 状态：⬜

### U-022 子 agent 多后端（ACP / Codex / Claude）
- 上游新增：`subagent_acp`、`subagent_codex`、`subagent_claude_code` 等后端
- 移动端：仅自有实现
- 动作：**评估**。若属产品边界外，标注 `OUT-OF-SCOPE`；若纳入，需单独能力项与真机验证
- 状态：⬜

### U-023 交互控制工具：`interrupt_agent` / `wait_agent` / `steer_next` / `abort_step`
- 上游：`tool-subagent-control`、`experimental/tool-agent-team`
- 移动端：有 `subagent_control`（对应 `/agent` 与停止能力）
- 动作：核对 `steer_next`（排队输入分流）与移动端 `onSteerQueuedInput` 的语义是否等价；不等价则补齐
- 状态：⬜

### U-024 Cordis 工具面（`cordis_mount/unmount/define/undefine/run/stop/inspect`）
- 上游：Cordis 工具族（部分随 CordisRuntime 新增）
- 移动端：`plugin_marketplace` + `CordisPluginRuntime.swift`
- 动作：列入 P3 与 Cordis 架构一起处理
- 状态：⬜（依赖 U-030）

### U-025 目标/反馈工具
- 上游：`create_goal`/`get_goal`/`update_goal`、`message_feedback`、`report_view`、`todo_write`
- 移动端：`work_state_set_goal` / `work_state_replace_todos` / `work_state_replace_plan`、`/feedback` 命令
- 动作：核对事件与命令覆盖；补齐缺失的查询语义（`get_goal`）
- 状态：⬜

---

## P3 · Cordis 架构跟进（最大、最慢，最后做）

### U-030 Cordis API 符号级比对
- 现状：上游 685 → 847 符号（+191 / −29）
- 文件：`HarnessMobile/Core/Plugins/CordisPluginRuntime.swift`、`CordisAgentServices.swift`、`CordisHarnessTraceProjection.swift`、`ISHNativeClientCordisBridge.swift`
- 动作：导出新版 `api-catalog.ts` 与移动端桥接做符号比对，产出兼容矩阵
- 验证：矩阵文档 + 现有插件回归
- 状态：⬜

### U-031 CordisRuntime 模型（Realm/Node/Fiber/Tree/Source）
- 上游新增架构，取代 `Rpc*`/`Inbox*`/`ApprovalService`
- 已核对：移动端**不依赖**被移除的 `RpcError/RpcId/RpcReceipt/Inbox/InboxTarget/ApprovalService` → **无破坏性风险**
- 动作：评估是否跟随重构；若不跟随，标注为契约代差并限制插件 API 版本
- 状态：⬜

### U-032 DeepSeek 请求扩展机制
- 上游新增：`llm/deepseek-llm-api-extensions`，插件可注入请求顶层字段（带 `accept()` 2xx 事务）
- 移动端：无
- 动作：若 U-030 判定需要，实现插件注册点；否则标注未支持
- 状态：⬜

---

## P4 · 新能力（可选，按产品决策）

### U-040 Agent 预设组合化
- 上游：`AgentPresetComposition/Roster/Document`（单一 preset → 组合模型）
- 移动端：`AgentPresetDefinition` 单一模型，定义在 `HarnessMobile/Core/Presets/AgentPresets.swift`（选择器 UI 在 `HarnessMobile/Features/Chat/ChatView.swift`）
- 动作：产品决策后决定是否引入组合模型
- 状态：⬜

### U-041 会话 turn outline / DeepSeek 会话日志
- 上游新增包：`session/session-turn-outline`、`session/session-log-deepseek`
- 动作：评估对轨迹 UX 的价值（移动端轨迹已有 Turn/Tool/Result 检查器）
- 状态：⬜

### U-042 webhook / webhook-github
- 上游新增
- 移动端：**产品边界外**（后台远程回调与"设备内执行"边界冲突）→ 建议 `OUT-OF-SCOPE`
- 状态：⬜

### U-043 agent-team（实验性）
- 上游：`experimental/tool-agent-team` + 事件 `team/member`、`team/task`、`team/message/queued`、`team/message/delivered`
- 移动端：无
- 动作：列入观察；上游 experimental 稳定后再评估
- 状态：⬜

---

## P5 · fixture 推进与验证收尾

### U-050 wire fixture 锚点推进
- 现状：`CompatibilityFixtures/deepseek/*.json` 锚定 `b150a551`
- 动作：**先扩展后切换**——新增新锚点场景，验证通过后切默认，保留旧锚点可回滚
- 状态：⬜

### U-051 会话事件 fixture 覆盖新增事件
- 动作：为 `model/selection`、`subagent/model-selection-policy` 增加 fixture 场景
- 状态：⬜

### U-052 全量回归
- 动作：`swift test`（全量）+ 11 类 UI 专项 + 边界审计 + upstream parity + `git diff --check`
- 状态：⬜

---

## 执行建议

1. **先做 P1**（U-010 / U-011）：成本最低、收益最明确（补 2 个事件，消除跨版本轨迹信息缺失）。
2. **P0 的 U-002 可以在 P1 之后立刻做**：审计完就知道 P2/P3 哪些条目是真需求。
3. **P3 最贵**：Cordis 架构换代，建议单独排期，先用 U-030 的兼容矩阵决定是否跟随。
4. **不要为了"对齐字符串"改移动端工具名**：`shell_execute`、`workspace_*`、`work_state_*` 是 iOS 原生替代，改名会破坏现有 parity 与测试。

## 已知不需要跟进（边界外）

`webworker-runtime`、`webworker-packer`、`code-runtime-python`（桌面/服务端）、`client/ui-chat`、`client/ui-session`（桌面 UI 形态）、`session-persistence-sqlite`（移动端用自有 `WorkspaceStore`）、`tool-subagent-report`（已删除，移动端本就没有）。
