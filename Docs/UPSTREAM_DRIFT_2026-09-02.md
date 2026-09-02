# DeepSeek Harness 上游漂移分析（2026-09-02）

## 1. 版本对比

| 项 | 当前锁定 | 上游最新 | 差距 |
| --- | --- | --- | --- |
| commit | `b150a551b`（PR #2908） | `49a606bc5`（PR #3456） | **落后 1771 个提交** |
| 版本标签 | `dsh-v0.1.1-rc.2` | `dsh-v0.1.2-alpha.5` | 12 天内 5 个 alpha |
| 日期 | 2026-08-21 20:03 | **2026-09-02 17:47**（当天） | 12 天 |
| 变更规模 | — | — | 7696 文件，+389701 / −171199 行 |

上游仓库：`https://github.com/deepseek-ai/deepseek-harness.git`
锁定来源：`Dependencies/upstreams.lock.json`（`deepseekHarness.commit`）
本次核对方式：`git fetch origin` 后按 `origin/master` 检索，**未改动工作树与锁文件**（parity 脚本仍按锁定 commit 通过）。

## 2. 分维度差距矩阵

| 维度 | 锁定版 | 新版 | 对移动端影响 |
| --- | --- | --- | --- |
| 包总数 | 234 | 256（+31 / −9） | 结构重组，需重跑 parity 清单 |
| 工具/扩展包 | 26 | 25（仅删 `tool-subagent-report`） | **无影响**（移动端本就没有该工具） |
| 会话事件类型 | 43 | 45（+2，零移除） | **差距 #1**：2 个新类型未实现 |
| 核心 wire 事件（10 个） | 全有 | 全有 | 无影响，fixtures 仍有效 |
| Slash 命令词汇 | 17 | 17 | 无影响 |
| Cordis 插件 API 符号 | 685 | 847（+191 / −29） | **差距 #2**：架构级扩张 |
| 持久化后端 | 含 `session-persistence-sqlite` | 已删除 | 无影响（移动端自有 `WorkspaceStore`） |

## 3. 上游新增能力（移动端未对齐）

**架构级变化**

1. **CordisRuntime 重构**：新增 `CordisRuntimeRealm/Node/Fiber/Tree/Source` 系列 API，同时移除 `Rpc*`、`Inbox*`、`ApprovalService` 等旧契约层。
2. **请求扩展机制**：新增 `llm/deepseek-llm-api-extensions`，允许 Cordis 插件向 DeepSeek 请求 body 注入顶层字段，并带 2xx 后事务提交（`accept()`）。
3. **客户端模块化**：`client/runtime` 拆为 `api/session-controller`、`api/settings-controller`、`api/workspace-controller`；新增 `client/store`、`client/ui-chat`、`client/ui-session`、`client/ui-approval`、`client/ui-schedule`。
4. **Agent 预设组合化**：新增 `AgentPresetComposition/Roster/Document` 系列（从单一 preset 走向组合模型）。

**新增包（按相关性）**

- 会话：`session/session-turn-outline`、`session/session-log-deepseek`
- 集成：`webhook/webhook`、`webhook/webhook-github`
- 工具库：`util/crypto`、`util/deque`、`util/time`、`util/values`、`util/workspace-path`
- 实验性：`experimental/agent-team-profile`、`agent-team-web-profile`、`client-ui-agent-team`、`webworker-runtime`、`webworker-packer`、`code-runtime-python`、`inspector`
- 测试：`test-support/session-snapshot`（新增 541 个快照文件，上游契约测试显著增强）

## 4. 移动端差距清单

### 差距 #1 · 会话事件类型（契约，中优先级）

上游新版新增两个事件类型，移动端 `SessionEventTrajectory` 未覆盖：

- `model/selection` —— 模型选择事件
- `subagent/model-selection-policy` —— 子 agent 模型选择策略

影响：上游写的会话日志若含这两个事件，移动端轨迹回放时**不认识**；上游的 `ignorable` 标记机制保证不会重建出错（非破坏性），但会丢信息（`/model` 切换与子 agent 模型策略不进轨迹）。

### 差距 #2 · Cordis 插件 API（架构，需评估）

插件 API 符号 685 → 847（+191 / −29）。移动端自有实现（`CordisPluginRuntime.swift`、`CordisAgentServices.swift`、`CordisHarnessTraceProjection.swift`）基于锁定版契约建造，与新版 CordisRuntime 模型不同。

**关键核对（已做）**：移动端**不依赖**上游已移除的 `RpcError/RpcId/RpcReceipt/Inbox/InboxTarget/ApprovalService` 等符号；`LocalSubagentReportDelivery` 是移动端自有本地实现，与上游删除的 `tool-subagent-report` 无耦合。**当前无破坏性风险**。

待评估：用户安装的 Cordis 插件若按新版 API 编写，在移动端旧契约桥接上是否可用（需插件契约兼容矩阵，真机验证）。

### 差距 #3 · 新增能力未对齐（可选）

- DeepSeek 请求扩展机制（插件注入请求字段）
- Agent 预设组合模型（移动端为单一 preset）
- webhook / webhook-github
- 会话 turn outline、DeepSeek 会话日志

### 产品边界外（不建议跟进）

`webworker-runtime`、`webworker-packer`、`code-runtime-python`、桌面端 `ui-chat/ui-session` 等——属桌面/服务端形态，与 iOS 原生产品边界不符，维持 `OUT-OF-SCOPE`。

## 5. 结论与建议

**红线状态：未破坏。** 现有 `CompatibilityFixtures/`（锚定 `b150a551`）继续有效：
wire 核心事件全部保留、slash 命令词汇不变、工具集未扩张、移动端无已移除 API 依赖。**不需要紧急升级**。

**但漂移在扩大**：12 天 1771 提交、包结构重组、Cordis 架构换代。拖得越久，后续受控升级的合并成本越高。

建议按此顺序行动（每项独立、可回滚）：

1. **补差距 #1**（成本最低、收益明确）：在 `SessionEventTrajectory` 增加 `model/selection`、`subagent/model-selection-policy` 两个事件常量与轨迹投影，并扩展对应 fixture 场景。
2. **受控升级准备**：新建分支 → 更新 `Dependencies/upstreams.lock.json` 的 `deepseekHarness.commit` → checkout 上游 → 重跑 `Scripts/check-upstream-parity.sh` → 逐条比对新增包与 Cordis API，产出 parity 差异清单（此步只审计不改实现）。
3. **Cordis 契约评估**：用新版 `api-catalog.ts` 与移动端桥接做符号级比对，判定现有插件的兼容边界，再决定是否跟随 CordisRuntime 重构。
4. **fixture 升级**：关键 wire fixture 从 `b150a551` 锚点推进到新基线时，先扩展后切换，保持旧锚点可回滚。

> 本次核对仅执行 `git fetch`（只读）。工作树、锁文件与 `Docs/DESKTOP_PARITY.md` 基线**均未改动**，parity 检查仍按锁定 commit 通过。
