# DeepSeek Harness iOS 桌面端对齐修补总清单

## 1. 用途

本文档是 iOS 移植的唯一修补进度清单。所有“已完成”必须同时具备：

1. 可定位的生产代码；
2. 对应的自动化测试或明确的真机验收步骤；
3. 与锁定上游版本的契约对比；
4. 没有把 iOS 平台限制、局部实现或测试替身误写成完整对齐。

本文档只记录官方已发布能力和用户明确要求。官方 `proposed` 设计稿、实验性 Agent Teams 和纯 Windows/Web 专属交互不作为核心对齐阻断项。

## 2A. 本轮修补证据（2026-08-22）

- `HarnessJobRegistry.wait()` 不再消费完成通知；完成通知采用 claim/ack/requeue，冷启动后仍可继续投递。
- workflow 结果使用紧凑 JSON，降低工具卡片和轨迹的无意义文本体积。
- workflow 子 Agent 具备可注入的超时/终止宽限窗口；普通分支失败保留为 `null`，取消则在 workflow 边界传播为 `CancellationError`，不会发布“已完成”。
- XCTest 聚焦集已通过：`HarnessJobsTests`、`NativeToolEventPresentationTests`、`WorkflowToolTests` 共 41 项，0 failures（Xcode Beta / iPhone 17 simulator）。
- iSH Host transport 的回调现在携带严格的 transport generation；旧 iSH 进程在自动重启后迟到的 stdout/stderr/exit 不会污染新 Host 的状态、framer 或 pending RPC。`ISHPluginHostTests` 25 项通过（SwiftPM，Xcode Beta toolchain）。
- Harness trace 现在在 run 启动前登记 runID -> sessionID，Cordis/plugin trace 会继承所属会话；诊断导出、Agent diagnostics 和轨迹面板均严格按 sessionID（可再按 runID）过滤，不再把父/子会话或无主全局事件混入。`HarnessTraceStoreTests` 5 项通过（Xcode Beta SwiftPM；真机并发父子 run 仍待验收）。

## 2. 版本基线

| 项目 | 当前状态 | 目标 |
| --- | --- | --- |
| iSH Plugin Host npm 依赖 | `0.1.1-rc.2` | 与锁定桌面基线一致 |
| `Dependencies/upstreams.lock.json` | `b150a551...` | `dsh-v0.1.1-rc.2` / `b150a551...` |
| `Vendor/UpstreamSources/deepseekHarness` | `b150a551...` | 官方 `dsh-v0.1.1-rc.2` |
| Swift 兼容性 fixtures | 主要仍指向 RC.5 | 按 RC.2 扩展并保留迁移覆盖 |
| 官方发布证据 | RC.8、RC.1、RC.2 | [Tags](https://github.com/deepseek-ai/deepseek-harness/tags) / [RC.8](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.1.0-rc.8) / [RC.1](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.1.1-rc.1) / [RC.2](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.1.1-rc.2) |

## 3. 状态规则

- `TODO`：尚未实现或未验证。
- `ACTIVE`：正在修补，不能对外声称完成。
- `VERIFY`：代码已存在，但自动化/真机/官方 fixture 仍未全部通过。
- `DONE`：代码、测试和指定验收全部通过。
- `IOS-REPLACEMENT`：无法字面照搬，已经有边界诚实的 iOS 替代。
- `OUT-OF-SCOPE`：不属于官方稳定能力或违反本项目产品边界。

## 4. 实施顺序和依赖

1. `BASE` 上游基线与 fixtures。
2. `WIRE` / `IMG` / `PERM` / `REF` 核心请求与上下文语义。
3. `SUB` / `PROFILE` / `PLUGIN` 子 Agent 和“一切皆插件”能力。
4. `TOOL` / `CMD` 桌面工具与命令契约。
5. `JOB` / `WF` / `UI` 编排、状态投影和专用界面。
6. `PROVIDER` / `CTX` / `UX` 兼容性和体验收口。
7. `VERIFY` 全量测试、模拟器和 iPhone 16 Pro 真机验收。

## 5. BASE：上游和兼容性基线

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| BASE-001 | DONE | 将 DeepSeek Harness lock 更新到官方 RC.2 commit | lock 、文档和测试报告使用同一 commit |
| BASE-002 | DONE | 更新 `Vendor/UpstreamSources/deepseekHarness` | 本地 vendored source HEAD 与 lock 完全一致 |
| BASE-003 | DONE | 将 Plugin Host 依赖统一到目标 release train | `package.json`、lockfile、manifest 一致，`npm run check` 和 Node smoke 通过 |
| BASE-004 | DONE | 扩展 RC.2 固定 fixtures | `reasoning-cancel-v1`、`image-reference-v1`、`subagent-jobs-v1` 锁定 RC.2 tag/commit，并以 6 项 Swift 投影测试覆盖 reasoning、cancel prefix、images、references、subagent、jobs |
| BASE-005 | DONE | 修正 `DESKTOP_PARITY.md` 的过期声明 | `@` sources、Cordis commands、compaction、Profile Bundle、feedback、Jobs/MCP/LSP 与剩余交付顺序均和当前代码相符 |
| BASE-006 | DONE | 增加 upstream-diff 检查脚本 | `Scripts/check-upstream-parity.sh` 校验 lock 与 vendored HEAD，并输出官方 package、手机工具和 slash command 清单 |

## 6. WIRE：DeepSeek / OpenAI-compatible 核心语义

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| WIRE-001 | DONE | 每个含 reasoning 的 assistant 回合都回传 `reasoning_content` | 无 tool call 和有 tool call 两类 wire test 通过 |
| WIRE-002 | DONE | 取消流式时固化已展示 text/reasoning prefix | follow-up、fork、trajectory 都能看到 interrupted assistant prefix |
| WIRE-003 | VERIFY | 对齐 RC.8 custom OpenAI gateway compatibility surface | 三档 wire preset 只作为基线；route 与 model 现在可用 14 个稀疏 pi-ai compatibility 字段逐项覆盖且保留显式 `false`，常用 max-token、developer role、stream usage、reasoning replay、tool-result name/assistant 补位与 chat-template kwargs 已进入 serializer。稀有 thinking format 及当前请求未产生的 store/strict/cache 字段仍需扩展固定快照和真实网关验收 |
| WIRE-004 | DONE | 放宽可证明完整的 SSE 结束变体 | 兼容网关不必同时伪造 semantic finish 和 `[DONE]`，不降低截断检测 |
| WIRE-005 | VERIFY | 提供可配置 provider retry policy | Provider Profile 已持久化官方 nested `normal`/`always` 配置；运行时支持有界错误码重试、下游 recovery 优先的持续重试、Retry-After 上限、本地 Double 退避、空响应与部分流重试、取消边界和精确 trajectory 事件。SwiftPM 全量与 Xcode 聚焦测试通过，真实网关/真机取消压力仍待验收 |
| WIRE-006 | VERIFY | V4 Vision 能力广告与真实 endpoint 可用性解耦 | 内置目录精确声明图片能力；动态 `/models` 只接受合法且明确的 `input`/`input_modalities`，绝不从模型名称猜测图片能力；能力广告不等于 endpoint 可用性，已补 fixture/单元测试，真实 endpoint live test 待执行 |
| WIRE-008 | VERIFY | 输出预算完全遵循选定模型的 API 容量 | 已知内置模型的当前 `maxOutputTokens` 与输入模态覆盖过期 Profile/model 缓存（包括 Vision 的历史 4K 记录）。OpenAI/DeepSeek 兼容 wire 不再发送 App 自设 `max_tokens`，由 API/模型自行解析；容量仅保留给展示、诊断及 Anthropic 等协议必填字段。应用不再对正常模型文字/推理施加字节上限、UI 也不截断。遇到 provider `length`，先完整持久化已收到内容，再以隐藏 continuation 指令续写，绝不重发已执行动作；截断 tool JSON 立即 fail-closed、绝不执行或续写。只有瞬态传输/服务端失败继续遵循 Provider retry policy。SwiftPM 定向回归通过，真实 API 与 iPhone 16 Pro 待验收 |

## 7. IMG：多模态与图片工具

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| IMG-001 | DONE | 修复 `stageImage` UUID 文件名被当作字面量 | 连续添加多图生成不同路径，旧会话图片不被覆盖 |
| IMG-002 | DONE | admission 阶段图片旋转、缩放、格式归一 | 默认最长边不超过 2048px，保留可视品质和正确方向 |
| IMG-003 | VERIFY | 统一 staging、request 和 aggregate payload 限额 | 不再出现“可保存 64 MiB 但请求上限 4 MiB”的互相矛盾 |
| IMG-004 | VERIFY | 实现稳定 oldest-first aggregate image budget | 历史大图被可解释地置换为占位，不静默丢失当前图片 |
| IMG-005 | VERIFY | RC.8 DeepSeek Files API 上传与文件 ID 复用 | 官方且显式声明 image modality 的请求使用 `POST /files`，默认有效期对齐上游 7 天；内存缓存按 endpoint/凭据摘要/图片摘要隔离，文件失效时只对明确的 400/404/422 文件错误回退 inline；真实 endpoint 与真机 API 验收仍待执行 |
| IMG-006 | VERIFY | 工具结果图片回灌模型上下文 | `read_image` 成功结果通过受信任的 `tool-result-image` user message 回灌，复用 attachment 管线并保留 call/path provenance；Xcode/真机多轮图片验收待执行 |
| IMG-007 | VERIFY | 实现模型可调用 `read_image` | `ProductionToolCatalog` 与 Cordis core plugin 注册该工具；成功结果生成受信任的 `tool-result-image` user message，并复用现有 attachment provider 注入下一次 vision request；Xcode/真机验收待执行 |
| IMG-008 | DONE | 统一 Slash command image envelope | `SlashCommandDescriptor.imagePolicy` 显式声明 accept/reject；注册表执行层拒绝未声明图片的命令并保留草稿；`/goal`、`/plan` 接受图片（`/plan off` 明确拒绝）；交互恢复与原生插件命令均保留/传递图片引用 |
| IMG-009 | TODO | 真机图片性能验收 | iPhone 16 Pro 连续多图、HEIC/JPEG/PNG、超大像素和历史会话测试通过 |

## 8. PERM：Harness 授权契约

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| PERM-001 | VERIFY | 恢复真正的 scope/device 持久授权 | 用户选择长期授权后不再反复出现 Harness 弹窗 |
| PERM-002 | VERIFY | 增加授权查看、按工具/范围撤销和全部撤销 UI | 授权可见、可撤销、可审计，不存在无入口的隐性权限 |
| PERM-003 | VERIFY | 将同一策略扩展到 subagent/MCP/Web/Code/mobile tools | 风险类型、资源范围和授权命中一致 |
| PERM-004 | VERIFY | 将 Harness 授权与 iOS 系统隐私权限分层 | 本地长期授权不伪装能跳过 Photos/Contacts/Location 的系统授权 |
| PERM-005 | VERIFY | 为授权迁移、损坏和审计失败增加 fail-closed 测试 | 决策未持久时不进入工具主体 |

## 9. REF / INSTRUCTIONS：引用、上下文与缓存稳定性

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| REF-001 | VERIFY | 支持含空格的 quoted `@file` 语法 | 插入、编辑、解析和删除引用均不截断路径 |
| REF-002 | VERIFY | 使用 canonical session reference identity | 自引用拒绝、去重、最多 3 个来源、稳定 Session ID |
| REF-003 | VERIFY | 对齐会话冻结快照筛选 | 只注入直接 user、assistant text 和 compaction checkpoint，不泄漏 tool/plugin runtime 内容 |
| REF-004 | VERIFY | 对引用内容使用不可信 JSON framing | 被引用文本不能伪造 system/tool 边界 |
| REF-005 | VERIFY | 修复 `@` 前编辑文本时的 token 布局和光标追踪 | RC.1 对应交互用例通过 |
| REF-006 | VERIFY | 补齐 file/session/subagent/skill 参考源及搜索 | 已支持 `@file`、`@session`、`@subagent`、`@skill`、`@plugin` 分类、搜索、过滤、去重和元数据；待 Xcode/真机交互验收 |
| INS-001 | VERIFY | 将 workspace `AGENTS.md` 改为 durable append-only transitions | 文件新增/修改/删除形成带 source metadata 的稳定记录 |
| INS-002 | VERIFY | 稳定 model request 前缀 | 无指令变化时 system/header 字节保持稳定，不无故破坏 KV cache |
| INS-003 | VERIFY | compaction 保留 instructions transition 语义 | 压缩后当前指令有效，旧变更不会重复污染前缀 |
| INS-004 | VERIFY | 增加缓存稳定性回归 fixture | 相同前缀、instructions 变更、tool schema 变更三类情况可定位差异 |

## 10. SUB / PROFILE：子 Agent 和产品 Agent Bundle

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| SUB-001 | VERIFY | 支持受限递归子 Agent | 默认 max depth 与上游对齐，超限显式拒绝，不用删除整套工具替代深度策略 |
| SUB-002 | VERIFY | 实现 `subagent_fork` | 子 Agent 可从受限的父会话/工作区快照启动，不伪造全新上下文 |
| SUB-003 | VERIFY | persona、toolFilter、provider override、maxDepth | schema、系统提示、工具目录和持久化都对齐 |
| SUB-004 | VERIFY | 支持 structured output/schema | 成功和 schema validation failure 均以结构化事件回传 |
| SUB-005 | VERIFY | 完整 `reportDelivery` | 父会话是否当前可见都会收到持久结果并在正确时机唤醒 |
| SUB-006 | VERIFY | child breadcrumb/tree/status 原生导航 | Jobs 面板从当前父会话读取持久子 Agent preorder 树，按 delegation depth 缩进显示状态，可打开子会话或停止活动子 Agent；Xcode/真机交互仍待确认 |
| SUB-007 | VERIFY | 完整 follow-up/wait/interrupt 树语义 | `send_message` 复用稳定 child identity；`wait`/`interrupt` 只作用于当前 activation；Xcode/真机树交互仍待确认 |
| SUB-008 | VERIFY | 明确 jetsam/cold-launch 恢复契约 | 无法续跑的进程恢复为 failed + `interrupted by app restart` 诊断，不伪装运行中；冷启自动化已覆盖，真机 jetsam 仍待确认 |
| PROFILE-001 | VERIFY | 固定 manifest 使用官方 npm 不可变 tarball URL、实测 SHA-256、版本/来源/checksum 校验和 iSH 绝对可执行路径；全 0 占位 checksum 被 fail-closed 拒绝 | 固定、可校验 payload，无随机 PATH fallback；仍需 iSH 安装器与真机执行闭环 |
| PROFILE-002 | VERIFY | 增加 JSON/JSONL final-answer 解析，并保留 legacy CLI fallback；尚未宣称已接入官方 app-server/Agent SDK wire | 使用权威 turn completion/final answer，不仅解析 CLI 文本 |
| PROFILE-003 | VERIFY | bundle 内固定 permissionMode 和参数，调用侧不能覆盖；真机需验证三种模式 | 权限由 profile 静态决定，模型不能通过 tool arguments 升权 |
| PROFILE-004 | VERIFY | 增加规范化命名实例和 actor registry；任务通道继续以 child address 隔离，真机并发取消待验收 | 实例拥有独立身份、任务、输出和取消通道 |
| PROFILE-005 | VERIFY | 增加结构化 failure facts、1500 字符预览、凭据脱敏和 retryable/errorCode；Xcode/真机日志导出待验收 | 不把原始大段 stdout/stderr 直接注入主 Agent |

## 11. PLUGIN：“一切皆插件”完整性

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| PLUGIN-001 | VERIFY | 动态 Tools/Prompts/Services/Settings 基础 | 官方 Host-only fixtures 可在 iSH 中激活、调用、停用和回滚 |
| PLUGIN-002 | VERIFY | 将 Agent inbox 事件纳入可插拔 checkpoint | `agent/inbox/pre-claim` 可改写/丢弃；`agent/inbox/inserted`、`claimed`、`discarded` 在 durable MessageId transition 后可观察；身份稳定、监听器失败局部隔离；仍待 Xcode/真机长任务验收 |
| PLUGIN-003 | VERIFY | 事件确认式 `llm/stream` 流式桥 | Swift 保留原生 `AsyncThrowingStream` 与凭据边界；iSH Host 按 start/event/finish-error-cancel 接收无凭据 envelope，并以 next/drop/replace 提供逐块背压与改写，Host 故障 fail-open，取消和 partial/error 仍由 Swift 传播；待 Node smoke 与真机长流验收 |
| PLUGIN-004 | VERIFY | 将原生 Code Mode dispatcher 纳入统一 checkpoint | Host 和 native 插件使用同一次序、授权和 trajectory |
| PLUGIN-005 | VERIFY | 动态 contribution 原子更新与回滚 | 新 generation 失败时旧 generation 仍有效，依赖可重连 |
| PLUGIN-006 | VERIFY | Host 重启后动态定义恢复策略 | 进程内定义丢失时有明确的重放/重建/不可恢复状态；transport generation 已隔离迟到旧进程回调，动态定义重建/真机 inventory 握手仍待验收 |
| PLUGIN-007 | TODO | 按版本扩展 `dsh.nativeClient` contribution kinds | 只扩展审计过的 inspector/card/command/settings/reference 类型 |
| PLUGIN-008 | IOS-REPLACEMENT | Web `dsh.client` React/slots/themes | 继续明确拒绝任意 Web/native code，通过受控 native manifest 替代 |
| PLUGIN-009 | VERIFY | 主 Agent 插件编译—诊断—修正—重提交流程 | 校验失败返回稳定错误码、阶段、`retryable=false`、同一 prepared_token 和下一步动作；同一份错误清单不会被标作可直接重试，必须由主 Agent 修正后再提交。`prompt_contexts[file].path` 现在指出精确字段、收到的值与合法私有路径模板，compiler policy 同步禁止以 list/contains 预检隐藏路径。`dsh-skillradar` 的本地化 `tool_guards.label` 有 JSON→materialize 回归覆盖；仍需在 iPhone 16 Pro 真机复测。 |
| PLUGIN-010 | VERIFY | 插件市场安装与对话安装使用同一管线 | 两个入口共享下载、校验、native-first、iSH fallback、rollback 和诊断；snapshot 保留上游 `lib/` 运行时代码，prepared native 安装沿 Host 规范化 sourceKey 持久化，不再在保存成功后误报来源不匹配。待真机双入口验收 |
| PLUGIN-011 | VERIFY | 增加代码生成与开发模式可观测性 | 编译页面已有阶段、输入、产物和日志；结构化失败诊断已进入 diagnostics_read。iPhone 17 Pro Simulator 已验证失败阶段、日志、结构化诊断和源码均可见；iPhone 16 Pro 真机失败重试、安装路径和日志导出仍待验收。 |

## 12. TOOL：桌面工具能力

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| TOOL-001 | VERIFY | `read_image` | 见 IMG-007；支持模型直接传入 `/workspace/...` canonical guest path |
| TOOL-002 | VERIFY | `glob` | 受工作区/挂载边界约束，支持官方 glob 语义与限额 |
| TOOL-003 | VERIFY | `grep` / `rg` regex search | 文本/二进制边界、行号、glob filter、超时和取消有测试 |
| TOOL-004 | VERIFY | 超长工具结果 spill locator | `ToolResultOutputPolicy` 在主/子 Agent Runtime 边界统一产生有界摘要与 `ToolResultSpillStore` locator，完整结果仍可读且失败显式；自动化已覆盖，待真机长输出验收 |
| TOOL-005 | VERIFY | 模型可调用持久 PTY `open/read/send/signal/list/close` | 已接入 OpenMinis 持久 iSH `/bin/sh -i` backend；owner 隔离、输出 256 KiB 上限、会话持久化/冷启 interrupted、工具授权与六个工具契约已实现；待真机交互验收 |
| TOOL-006 | VERIFY | `session_search` / `session_trace` / `session_event_*` | 已接入 `ProductionToolCatalog`、主/子 Agent 与 Cordis 注册路径；提供分页、脱敏、稳定 cursor 和事件类型/单事件读取；Xcode target 已补齐，仍待 Xcode 测试与真机验收 |
| TOOL-007 | VERIFY | `schedule_create/list/delete` | 已接入 BGTaskProcessing 唤醒：系统唤醒后原子 claim 到期任务、加载所属会话、启动本机 Agent 回合、处理过期取消并重新安排下一次唤醒；待 iPhone 真机后台验收 |
| TOOL-008 | VERIFY | `ralph` | 已实现官方 fixed fresh-child、多轮 bounded handoff、complete/blocked/budget-limited、取消中断和结构化报告校验；SwiftPM/Xcode 聚焦测试通过后仍待真机 trajectory/恢复验收 |
| TOOL-009 | VERIFY | `subagent_fork` | 已与 SUB-002 共用受限父会话快照、稳定 child identity 和深度策略；待真机并发/取消验收 |
| TOOL-010 | VERIFY | MCP client transports | 已实现有界 MCP JSON-RPC/NDJSON client、initialize、分页 tools/list、tools/call、取消/超时、稳定公开名和 iSH 持久 stdio transport。MCP-001 把受凭据防火墙保护的持久配置映射为每 server 一个 Cordis 插件，启动发现后直接注册 `mcp__server__tool`；本机 transport 退出后会以新 client generation 有界退避重连，并在一个 Cordis tool actor 事务内替换完整工具集。模型不再可调用 connect/list/call/disconnect meta tools。远程 Streamable HTTP/OAuth 不属于产品边界；本地 stdio 的 resources/prompts 需要时另行单列，不作为远程回退。真机实际 MCP server 仍待完成 |
| TOOL-011 | VERIFY | LSP provider/tool | 已按上游 `dsh-lsp` / `dsh-lsp-stdio` / `dsh-tool-lsp` 迁移单一只读 `lsp` 工具：四种闭合操作、一基 UTF-16 坐标、findReferences 含声明、Location/LocationLink/Hover 规范化、4 MiB 文档与 16k/100 条结果边界；language server 和协议 host 均在 iSH `/workspace` 执行，内置 Python/TS/JS/C/C++/Rust/Swift 路由。仍需真机安装 server fixture、持久 per-workspace process pool 和设置页自定义 provider |
| TOOL-012 | VERIFY | 文件编辑契约对齐 | canonical read/write/edit 已支持空文件、删除式 edit、空文件 0 行、字段级错误、NUL 文本拒绝、真正分块 UTF-8 stream、CRLF 编辑回写；legacy workspace aliases 共用同一 freshness。另按官方 Minimal 预设移植 `str_replace_editor` 的 view/create/str_replace/insert、两层目录过滤、唯一匹配行号、零基插入和 16k clipping。仍需把 canonical before/after/line-window 作为 replay-safe presentation meta 持久化，并完成真机大文件验收 |
| TOOL-013 | DONE | deliverable/diff 产物语义 | `workspace_diff` 生成受限 unified diff，`deliverable_write` 写入受保护工作区并返回 canonical path、大小、行数和有界预览；两类结果均有专用可折叠工具卡片和回归测试 |

## 13. CMD：Slash / `@` 命令系统

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| CMD-001 | VERIFY | generic popup-select result | `SlashCommandInteractionRequest.popupSelect` 与 `resumeInteraction` 可返回类型化选择器并继续原调用；待真机交互验收 |
| CMD-002 | VERIFY | generic confirmation result | confirmed/denied/cancelled 均写入可持久命令完成事件；待真机交互验收 |
| CMD-003 | VERIFY | 参数 completion | model、agent、skill、file、session、plugin 均进入原生 completion；待真机键盘/编辑验收 |
| CMD-004 | VERIFY | 统一 Cordis Host/nativeClient/native command merge | 复用官方 `@deepseek-ai/dsh-commands`，iSH Host 动态命令已进入 native/nativeClient 共用的有优先级、按 session 隔离、按 generation 精确撤回的 registry；命令执行仍由原生侧写 durable run/done，避免 Host 镜像会话重复记轨迹。Node smoke、Swift lifecycle 与全量测试已通过；待 iPhone 16 Pro 动态插件、取消及图片命令验收 |
| CMD-005 | DONE | 补齐 `/goal` edit/pause/resume/clear | `/goal` 支持 edit/pause/resume/complete/block/clear，统一调用 `WorkStateCoordinator`，与 WorkState UI/tool 共用状态机 |
| CMD-006 | VERIFY | `/feedback` 与 sidecar contract | `/feedback [message-id] like|dislike|note|clear`（无参数为 show）按显式 UUID 或最新助手消息执行；与消息菜单共用独立 sidecar，命令核心和并发行为测试已补，Xcode/真机交互仍待执行 |
| CMD-007 | DONE | command image capability descriptor | 见 IMG-008 |
| CMD-008 | VERIFY | 完整 reference insertion source | 见 REF-006；待 Xcode/真机交互验收 |

## 14. JOB / WF：后台任务和工作流

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| JOB-001 | VERIFY | 会话头部 Jobs 列表 | 原生 Jobs 面板显示当前会话的持久 jobs，支持输出、停止；另显示子 Agent 树并可定位到子会话；Live Activity/真机交互仍待确认 |
| JOB-002 | VERIFY | 完成结果 durable delivery | Agent 忙时在安全边界注入，空闲时唤醒，且仅投递一次；已实现 claim lease、投递成功 ack、失败 requeue，待真机忙碌/空闲交互验收 |
| JOB-003 | VERIFY | 冷启恢复与可续跑操作分类 | 可重放的任务恢复，无法恢复的 iSH 进程显式 interrupted；已实现冷启清理旧 claim 与 interrupted 分类，待真机冷启动验收 |
| JOB-004 | VERIFY | 输出持久化、上限和 spill | Job 最终输出也经过统一上限策略并支持 spill locator，已补回归测试；待 Xcode/真机长任务验证 |
| WF-001 | VERIFY | Workflow child 递归 tool-event tree | workflow 成员事件持久化 `runId/parentId/childId/depth`，并携带开始时间；仍待 Xcode/真机验证嵌套导航 |
| WF-002 | VERIFY | 专用 workflow card / progress | 已有 phase/member/duration/status/output/error 事件与紧凑结果投影；Xcode/真机交互仍待确认 |
| WF-003 | VERIFY | provider override 和 structured schema | workflow child 支持 Profile Bundle provider override 与 JSON Schema 输出校验，未知 provider/schema failure 显式返回；待真机多 provider 验收 |
| WF-004 | VERIFY | 取消、超时、部分失败和有界 fan-out | 子 Agent 取消/超时会中断 activation；普通分支失败转 `null`；并发、总量和单次 items 上限由 sandbox 固定执行；回归测试已补，真机仍待确认 |
| WF-005 | IOS-REPLACEMENT | 重启后执行边界 | 不承诺恢复任意 Node/iSH 执行栈，但保留可诊断的持久状态 |

## 15. UI：桌面/Web 信息架构的原生适配

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| UI-001 | VERIFY | 原生 Workspace entity 与 tree | 会话首页以 `/workspace` 为根展示当前 Session/运行状态、文件计数与挂载状态，并从同一树进入完整工作区；Simulator UI 通过，待 iPhone 16 Pro 触控/VoiceOver 验收 |
| UI-002 | VERIFY | 子 Agent breadcrumb/header navigation | Job registry 提供 cycle-safe root-to-current lineage；打开 child 后 Chat header 保留父/子地址、状态和逐级返回入口，Jobs 树仍以真正 root 投影；底层测试和 Simulator build 通过，待真机交互验收 |
| UI-003 | VERIFY | Jobs header | 见 JOB-001；待真机 Live Activity/交互验收 |
| UI-004 | VERIFY | diff/search/web/job/workflow/deliverable 专用卡片 | 六类均已使用专用原生卡片：search 覆盖 `workspace_search/glob/grep` 与 spill 定位，web 覆盖 ranked sources/HTTP 正文，job 覆盖 list/output/kill；默认折叠、按 UTF-8/行数限界、损坏结果回退 generic。SwiftUI/Xcode Simulator 编译与投影测试通过，仍待 iPhone 16 Pro 真机触控、Dynamic Type 与 VoiceOver 验收 |
| UI-005 | VERIFY | 对话 Markdown 表格自适应 | 已将问答页既有 Markdown 逻辑提取为共享原生 renderer，并接入正常助手消息；支持 heading/paragraph/list/quote、反引号/波浪号 fence、inline Markdown 与 GFM-style 表格。表格列宽限制为 96–240 pt，保持左右/居中对齐并只在卡片内部横向滚动，不扩张对话时间线；流式阶段仍显示纯文本。完成后的超长 Markdown 从 50k UTF-8 字节起在后台 lossless 语义分段，首尾确定渲染、中间分段按视口 lazy render，不切断 fence/table/quote，复制仍使用 canonical 原文。50k/250k/1M 等价性与 Xcode Beta 百万字符/Accessibility XXXL 模拟器均通过，待 iPhone 16 Pro VoiceOver、完整拖选和触控验收后 DONE |
| UI-006 | VERIFY | 99.x% 缓存命中率精度 | 保留一位小数，不四舍五入成误导的 99%/100%；仅在服务商提供 cached/uncached 字段时计算，字段缺失显示 `—`，显式 0% 保留；自动门通过，待 iPhone 16 Pro 长轨迹视觉/VoiceOver/真实 provider 组合验收 |
| UI-007 | VERIFY | 长对话和流式输出性能验收 | 已实现 `LazyVStack`、80 条稳定窗口分页、稳定 event/message/reasoning/tool/Markdown block/segment identity、完整内容/宽度/Dynamic Type 有界 render/measure cache、超长 Markdown 后台语义分段与可见性 lazy render、100 个回退工具调用分段展示、隐藏上下文与重复 tool row 的 revision-time 投影、流式 text/reasoning 66–160 ms 合并、常数时间 presentation revision、8 Hz 无动画自动跟随，以及实时工具输出 100 ms 有界合并；工具输出先到、terminal 先到和 running event replacement 的 presentation race 已修复，replacement 按 output chunk ID 去重并保留未 flush 输出；完整响应/工具输出仍由 Runtime 与 append-only trajectory 保存。1000 条消息 + 100 tools + tail stream，以及 50k/250k/1M Markdown 场景已通过自动门；仍需 iPhone 16 Pro Instruments hitch/CPU/memory、跨分段拖选、Dynamic Type 和旋转轨迹后才能 DONE |
| UI-008 | VERIFY | Trajectory 完整 Inspect 信息架构 | 顶部显示 Duration/Turns/Calls、Model/Tools、平均 TTFT、Output 与 Cache；三种 ledger 支持搜索、分页和折叠。Turn/Call header 显示局部耗时；事件 Inspect 对 System request header、User、Assistant、Tool call/result 提供语义化输入/输出，并在单步 usage 中显示 uncached input、cache read/write、cache hit 与 thinking tokens，原始 JSON 仍作为完整回退。稳定 JSONL UI 夹具覆盖 request header/context、turn/step、消息、tool call/result 和 usage；iPhone 17 Pro Simulator UI test 已验证统计、Calls/Turns、双事件 Inspect、折叠与搜索。自动/模拟器门已闭合，iPhone 16 Pro 长轨迹 VoiceOver、真实触控、旋转和设备性能仍待验收后 DONE |
| UI-009 | VERIFY | 编译/安装/开发模式可观测面板 | 见 PLUGIN-011；自动/模拟器门已闭合，仍待 iPhone 16 Pro 真机失败重试、安装路径、日志导出、VoiceOver、触控、旋转和性能验收。 |

## 16. PROVIDER / WEB / CTX：兼容性收口

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| PROVIDER-001 | VERIFY | provider/profile route generation、quick test 与 refresh single-flight 基础设施 | `ProviderRequestRoute` 在 Cordis 组装后冻结 profile ID、内存 generation 与 endpoint，并由普通请求、retry/continuation、compaction route 一致携带；adapter 发送前复核 endpoint，变化 fail-closed，不静默 fallback。quick test 复用 production streaming adapter，但不创建 session、trajectory 或 tools。`ProviderRefreshSingleFlight` 已验证同 profile 十个并发调用只执行一次 operation；当前凭据仍仅 API key，未实现或验收 OAuth/401 token refresh。`ProviderRequestLifecycleTests` 4/4、`AppModelProviderProfileTests` 7/7、SwiftPM 全量 760 tests（3 skipped、0 failures）、iPhone 17 Pro Simulator 定向 XCTest 11/11、arm64 generic iOS Simulator build 均通过；真实 provider/API-key 失效、401/OAuth rotation 和 iPhone 16 Pro 仍待验收 |
| PROVIDER-002 | VERIFY | pi-ai/custom gateway 显式兼容配置 | Provider Profile、Provider Model 与请求快照已支持 preset + 稀疏字段级 compatibility、官方 nested retry policy、旧目录迁移、严格校验及设置页编辑；待补 store/strict/cache 实际请求字段、稀有 thinking format 快照与真机私有网关验收 |
| PROVIDER-003 | DONE | 模型发现失败和缓存完整 fixture | 版本化 fixture 与测试已覆盖 401 + request-id、跨 origin/非 HTTPS/credential URL 拒绝、malformed、声明超 4 MiB、TTL expiry、凭据分区和 manual unlisted fallback；生产 client 使用可注入 session/cache seam 做无真实网络回归 |
| WEB-001 | DONE | 对齐 RC.8 multi-query `web_search` schema | 仅接收标准 `queries`，查询上限、错误语义与官方一致 |
| WEB-002 | DONE | exact query 去重、并发和 round-robin source merge | URL 去重、全局结果上限、稳定排序有回归测试 |
| WEB-003 | DONE | 可插拔搜索 provider seam | 不绑死 Bing RSS/DuckDuckGo，但所有请求仍从手机直接发出 |
| CTX-001 | VERIFY | tool-result pruner | `ToolResultOutputPolicy` 在模型消息边界限制 inline 结果，保留 canonical value 与错误状态；高频长会话验收待执行 |
| CTX-002 | VERIFY | tool-result spill policy | 超长结果写入 `ToolResultSpillStore` 并返回受限预览 + 可读 locator，失败时显式报错；Xcode/真机分页验收待执行 |
| CTX-003 | DONE | 可配置 compaction summary route | 设置页可从任意 Provider Profile 选择摘要模型并独立持久化；运行时单独解析凭据，配置/凭据错误或首 token 前传输失败时回退当前会话路由，取消、部分输出和协议错误不做有损重试；实际摘要 provider/model 与回退原因进入 trajectory |
| CTX-004 | DONE | 完整 compaction cross-version fixtures | 固定夹具覆盖完整工具事务、work state、workspace instructions、图片、会话引用、取消留下的不完整 assistant prefix、最近消息和旧大消息裁剪，并锁定上游 commit 与期望投影 |
| CTX-005 | DONE | durable time-context overlay | 默认关闭；开启后按用户选择的 iPhone/UTC 时区和 0/1/5/15 分钟刷新策略，在 pre-step 追加带 `@deepseek-ai/dsh-time-context` 来源的持久快照；system/header 不变，刷新窗口内不重复注入，关闭后不产生动态前缀 |
| CTX-006 | DONE | LLM session title providers | 支持首问和全部提问两个官方 cadence，可跟随会话路由或指定任意 Provider Profile/模型；Key 只由 Keychain 解析，输入/输出/token/15 秒超时有界，无工具调用；失败保留确定性本机标题，手动重命名固定标题，菜单可显式重新生成，并记录 `session/title-llm-request` 与可归因的 `session/title` |

## 17. FEEDBACK / MOBILE / BACKGROUND

| ID | 状态 | 修补项 | 验收标准 |
| --- | --- | --- | --- |
| FEEDBACK-001 | VERIFY | 完整 feedback sidecar identity/revision | `MessageFeedbackSidecarStore` 将反馈写入 `Feedback/feedback-sidecar.json`，记录包含稳定 UUID、session/message identity 和 per-record revision；旧嵌入反馈自动迁移，stale revision fail-closed；真机并发验收待执行 |
| FEEDBACK-002 | VERIFY | 补齐 `/feedback` 命令和行为测试 | 命令与消息菜单操作同一 sidecar，支持 show/like/dislike/note/clear、显式 message UUID 和最新助手消息默认目标；解析、迁移、冲突、tombstone 测试已补，Xcode 聚焦测试待执行 |
| MOBILE-001 | VERIFY | 相机/OCR/位置/运动/联系人/通知/App Intents | App Intents 已以 durable idempotent inbox 接入 List/Status/Open/Retry/SendPrompt，SessionStoreTests 13/13 与 arm64 generic Simulator build 已通过；每项仍需 capability/permission 审核及 iPhone 16 Pro 真机验收 |
| MOBILE-002 | VERIFY | Speech/BLE/Calendar/Reminders/Media/Health/Home/NFC/Maps 桥 | entitlement 不具备时显式 unavailable，不伪装成功 |
| BG-001 | VERIFY | BGContinuedProcessingTask 运行/取消/过期 | 真机切后台、通知中心、锁屏、低电量和热压力测试 |
| BG-002 | VERIFY | UIKit finite background task lease：进程级引用计数、run token、精确 expiration 路由 | 自动门已通过；真机锁屏、低电量、热压力和真实 expiration 仍待验收 |
| BG-003 | VERIFY | 单一音频会话协调器：keepalive/TTS/媒体/录音 intent 引用计数、优先级和系统事件重建 | `HarnessAudioSessionCoordinatorTests` 3/3；已由 BG-004 使用，真实音频设备/电话/蓝牙/锁屏验收待执行 |
| BG-004 | VERIFY | 静音音频保活腿：AVAudioEngine 循环静音缓冲、双健康检查、generation、防抖、有限重试和媒体暂停 refcount | `BackgroundAudioKeepAliveTests` 5/5；已加入 `audio` background mode并接入 AppModel live-root/scene 生命周期；真实 iPhone 锁屏、电话/蓝牙、低电量和热压力仍待验收 |

## 18. 平台边界与不应实现的伪对齐

| ID | 状态 | 边界 |
| --- | --- | --- |
| BOUNDARY-001 | OUT-OF-SCOPE | 不增加服务器/Remote Executor 执行回退 |
| BOUNDARY-002 | OUT-OF-SCOPE | 不下载或保存本地大模型权重 |
| BOUNDARY-003 | OUT-OF-SCOPE | 不通过假定位、假 BLE 或 VoIP 滥用伪造常驻；BG-004 的静音音频仅作为用户显式开启增强后台后的真实 `audio` background mode 保活腿，并受 live-root、generation、健康检查和失败降级约束 |
| BOUNDARY-004 | IOS-REPLACEMENT | 不动态加载下载的 Swift/机器码；使用受审计 native manifest 或 iSH Host JS |
| BOUNDARY-005 | IOS-REPLACEMENT | 不字面加载 React `dsh.client`、Web slots/themes/HMR |
| BOUNDARY-006 | OUT-OF-SCOPE | Windows PowerShell 和桌面浏览器自动打开不是 iOS 缺失 |
| BOUNDARY-007 | OUT-OF-SCOPE | private experimental Agent Teams 在官方稳定前不作为 parity blocker |
| BOUNDARY-008 | OUT-OF-SCOPE | 官方 `proposed` notes 不当作已发布能力 |
| BOUNDARY-009 | OUT-OF-SCOPE | 远程 Streamable HTTP MCP 及其 OAuth/Keychain token 流会把工具执行委托给任意远程 server；MCP 仅允许本机 iSH stdio，配置解析拒绝未知 transport 字段 |

## 19. VERIFY：发布验收门槛

| ID | 状态 | 验收项 |
| --- | --- | --- |
| VERIFY-001 | DONE | `swift test` 全量 606 项完成、0 失败；3 个 live/环境依赖测试按默认策略显式跳过，未使用真实凭据 |
| VERIFY-002 | DONE | Plugin Host `npm run check` 及 Node smoke tests 通过 |
| VERIFY-003 | DONE | `Scripts/audit-no-remote-execution.sh` 通过 |
| VERIFY-004 | DONE | Xcode Beta 指定 Apple Silicon Simulator arm64 build/run 成功 |
| VERIFY-005 | DONE | 模拟器 UI 描述/截图确认启动和关键流程 |
| VERIFY-006 | DONE | generic iOS arm64 真机构建成功 |
| VERIFY-007 | TODO | iPhone 16 Pro 真机安装、启动、API 连通、图片、iSH、插件、后台验收 |
| VERIFY-008 | TODO | 长会话、长 SSE、高频 tool calls、取消、内存警告、热限速压力测试 |
| VERIFY-009 | TODO | iSH/Host 死亡、半安装插件、损坏状态和 App cold launch 恢复测试 |
| VERIFY-010 | TODO | 诊断导出不包含 API Key、Bearer、私密文本和未经脱敏的插件 stderr |

## 20. 已存在、不应重复造轮子的基础

后续修补必须复用以下现有实现，不新建平行体系：

- `AgentRuntime` 原生流式 loop 和冲突感知工具调度器。
- Provider Profile、Keychain、Model Discovery、Anthropic Messages。
- SessionStore 会话搜索/分叉/归档/持久化。
- Goal/Plan/Todo、Ask User、Plan Review、Trajectory、Diagnostics。
- `HarnessFileSystem` 与 iSH `/workspace` 统一文件边界。
- Native Cordis 的 Fiber/service/waterfall/generation rollback。
- iSH Plugin Host、marketplace、native-first compiler 和 `dsh.nativeClient` v1。
- ActivityKit、BGContinuedProcessingTask 和手机能力桥。

## 21. 进度日志

| 日期 | 变更 | 验证 | 状态 |
| --- | --- | --- | --- |
| 2026-08-22 | 根据官方 RC.8、RC.1、RC.2 与当前 Swift/Node 源码建立总清单 | 只读源码审计 | 建立基线 |
| 2026-08-22 | 更新上游 source/lock/Plugin Host 到 `dsh-v0.1.1-rc.2` | `npm run check`、Node Plugin Host smoke 通过 | BASE-001/002/003 DONE |
| 2026-08-22 | 补齐 reasoning passback every turn | `DeepSeekWireTests` 19/19 通过 | WIRE-001 DONE |
| 2026-08-22 | 取消流时把已展示 text/reasoning prefix 写入 append-only trajectory，并供 follow-up/fork/recovery 复用 | 聚焦 `AgentRuntimeTests` 48/48；三类取消回归 3/3 通过 | WIRE-002 DONE |
| 2026-08-22 | 对齐 quoted `@file`、canonical `dsh-session:`、最多 3 个会话、不可信 JSON 与 64 KiB 冻结快照 | `HarnessReferenceSyntaxTests` 5/5、provider-facing normalization 1/1 通过 | REF-001/002/003/004 VERIFY |
| 2026-08-22 | 图片 admission、UUID 路径、EXIF/缩放/格式复验与 `read_image` 原生上下文回灌；补 canonical `/workspace/...` 路径回归 | admission/file tools 25/25；tool-result vision context 1/1 通过；Xcode test runner 当前缺 XCTest | IMG-001/002 DONE，IMG-007/TOOL-001 VERIFY |
| 2026-08-22 | scope/device 长期授权、危险 iSH 精确授权、审计 fail-closed 与子 Agent 共用审批面 | Core 聚焦测试已补；等待统一 App/UI 构建 | PERM-001~005 VERIFY |
| 2026-08-22 | quoted `@"path with spaces` 在 Unicode 前缀和编辑 revision 下保持正确 span | `SlashCommandCoreTests` 聚焦 1/1 通过；等待 Composer UI 构建 | REF-005 VERIFY |
| 2026-08-22 | custom OpenAI-compatible 保守 wire profile、旧 reasoning 别名、RC.2 五次有界重试和 `Retry-After` | 子切片聚焦测试 12/12；显式 profile/retry override 尚未补齐 | WIRE-003/005 ACTIVE |
| 2026-08-22 | 工作区指令 append-only transition、compaction rearm、前缀稳定 fixture，并接入每步 pre-step 持久注入 | Core 测试 5/5、compactor 12/12；主运行时接线等待统一构建 | INS-001~004 VERIFY |
| 2026-08-22 | Code Mode Host checkpoint、动态 generation 原子回滚和 Host 重启恢复协调器 | 独立聚焦测试 5/5、无远端执行审计通过；仍需接入完整 model-driven lifecycle | PLUGIN-004~006 VERIFY |
| 2026-08-22 | 图片持久对象与 1 MiB 请求派生版本分离、20 MiB 精确 aggregate budget、全图省略占位和 24 MiB wire 上限 | 新增 request variant、oldest omission 与全省略回归；等待共享树统一复测 | IMG-003/004 VERIFY |
| 2026-08-22 | 工作区指令、图片预算、durable Jobs/Subagent/Workflow、glob/grep/search spill 首轮合并验证 | Xcode-beta SwiftPM 聚焦集后续扩展为 41/41 通过；子 Agent 上层 composition/delivery 已有代码和测试，仍待真机验收 | TOOL-002/003 VERIFY，TOOL-004 与 SUB-001~005 VERIFY |
| 2026-08-22 | 缓存命中率显示保留一位小数，避免 99.x% 被误读为 99% | 模拟器/真机构建通过；统计仍使用服务商原始 cached/uncached token | UI-006 DONE |
| 2026-08-26 | UI-006 无数据语义复验：`HarnessTraceStore` 不再把仅含 prompt token 的响应显示为 0.0%；有 cached/uncached 字段才计算，显式 cached=0/uncached=prompt 仍显示 0%，Chat/Trajectory/SessionEvent 统一显示一位小数或 `—`。 | `HarnessTraceStoreTests` 新增 2 项；UI-006 聚焦 4/4；SwiftPM 全量 737 tests、3 skipped、0 failures；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `UI-006 VERIFY/CLOSED`（自动门）；iPhone 16 Pro 长轨迹视觉、VoiceOver、真实 provider 字段组合仍待验收；下一项 UI-007 |
| 2026-08-26 | UI-007 长对话/流式输出自动门收口：稳定窗口、内容/宽度/Dynamic Type 有界缓存、超长 Markdown 分段与实时工具输出合并保持现有契约；修复 output-before-event、terminal-before-flush 和 running-event replacement 的 pending output 丢失，replacement 仅按 output chunk ID 去重。 | `SessionRunStateTests` 16/16、`ConversationMessageWindowTests` 6/6、`NativeMarkdownTextTests` 13/13；SwiftPM 全量 740 tests、3 skipped、0 failures；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-ui007-xcode` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` 均 PASS。 | `UI-007 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro Instruments hitch/CPU/memory、跨分段拖选、Dynamic Type、旋转和 VoiceOver 仍待验收；继续保持 `VERIFY` |
| 2026-08-26 | UI-008 Trajectory Inspect 自动/模拟器门收口：新增 `presentTrajectoryForUITesting()` 写入稳定 canonical JSONL 夹具，包含 request header/context、turn/step、user/assistant、tool call/result 和 usage/cache/reasoning；新增 UI 测试通过真实点击检查统计、Calls/Turns、Tool call 与 Tool result 的独立 Inspect、折叠和搜索。 | `HarnessMobileTrajectoryUITests.testTrajectoryLedgersSearchCollapseAndInspect` 在 iPhone 17 Pro Simulator iOS 27.0 通过，结果包 `/tmp/hm-ui008-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_11-32-33-+0800.xcresult`；SwiftPM 全量 740 tests、3 skipped、0 failures。 | `UI-008 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro 长轨迹 VoiceOver、真实触控、旋转和设备性能仍待验收；下一项 UI-009 |
| 2026-08-26 | UI-009 / PLUGIN-011 自动/模拟器门收口：为编译失败路径增加稳定 UI 夹具，覆盖源码获取、分析、适配、模型编译、校验失败及 native/iSH 跳过状态；测试真实展开详细日志并检查结构化诊断与源码。修复 `DisclosureGroup` 可访问性标识继承冲突，并在测试夹具启动时禁止市场页异步刷新覆盖本地固定目录。 | `HarnessMobilePluginManagementUITests.testCompilationFailureTraceExposesStagesLogsAndStructuredDiagnostic` 在 iPhone 17 Pro Simulator iOS 27.0 通过，结果包 `/tmp/hm-ui009-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_12-17-05-+0800.xcresult`（1 passed, 0 failed）；SwiftPM 全量 740 tests、3 skipped、0 failures；Plugin Host check、无远程执行审计、upstream parity、`git diff --check` 均通过。 | `UI-009` / `PLUGIN-011 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro 失败重试、真实安装路径、日志导出、VoiceOver、触控、旋转和性能仍待验收，继续保持 `VERIFY`。 |
| 2026-08-26 | PROVIDER-001 自动/模拟器门收口：`ProviderRequestRoute` 冻结 profile ID、内存 generation 和 endpoint；在 Cordis 组装后提供给普通请求、retry/continuation 与 compaction route，adapter 发送前重新核验 endpoint 并在变更时 fail-closed。quick test 走 production streaming adapter 且严格无 session、trajectory、tools；`ProviderRefreshSingleFlight` 对同 profile 合并并发 operation。当前 credential contract 仍是 API key，因此 single-flight 是未来 OAuth 的基础设施，不是已验收的 token refresh。 | `ProviderRequestLifecycleTests` 4/4；`AppModelProviderProfileTests` 7/7；SwiftPM 全量 760 tests、3 skipped、0 failures；iPhone 17 Pro Simulator iOS 27.0 定向 XCTest 11/11，结果包 `/tmp/hm-provider001-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_15-27-14-+0800.xcresult`；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-provider001-generic` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计和 upstream parity PASS。 | `PROVIDER-001 VERIFY/CLOSED`（自动/模拟器门）；未运行真实 provider quick test、API-key 失效、401/OAuth rotation 或 iPhone 16 Pro，不能写成 `DONE`；下一项 `ATTACH-001`。 |
| 2026-08-26 | ATTACH-001 自动/模拟器门收口：新增 durable `AgentFileAttachmentRef`，旧会话的 `fileAttachments` 解码为 `[]`。`WorkspaceStore` 私有 staging 仅接收 PDF、MP3/WAV/M4A、MP4/MOV，限制 64 MiB，成对释放 security-scoped access，复验文件签名/类型，使用 UUID 私有路径、complete file protection 与 7 天 TTL；读回拒绝过期、符号链接、越界、异常大小和签名失配。Chat 文件选择器、仅附件发送、active-run 拒绝新非图片附件、fork/trajectory/conversation projection metadata 均已接线。OpenAI-compatible 和 Anthropic wire 只发送名称、MIME 类型、字节数的文本 marker，不发送文件字节、data URL、upload 或推测性 `file_id`。 | `WorkspaceStoreTests`、`DeepSeekWireTests`、`AnthropicMessagesWireTests`、`SessionTrajectoryRepositoryTests` 聚焦 64 tests、0 failures；SwiftPM 全量通过；Plugin Host `npm run check`、`./Scripts/audit-no-remote-execution.sh`、`./Scripts/check-upstream-parity.sh` 通过；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-attach001-generic` `BUILD SUCCEEDED`。 | `ATTACH-001 VERIFY/CLOSED`（自动/模拟器门）；仍须在 iPhone 16 Pro 验证 Files picker、安全作用域 URL、PDF/音频/视频选择和 7 天过期行为，并用真实 provider 验证 metadata-only delivery；设备与 provider 证据前不能写成 `DONE`。 |
| 2026-08-26 | RUN-005：以生产 `createConversation`/`switchConversation` 路径覆盖 A/B live root。A 注册并运行后新建 B，A 仍在 registry；B 注册并运行后切回 A，`sessionRunSnapshots` 同时投影两个独立 identity。DEBUG UI fixture 创建两个真实 registry root 并回到 A；UI 回归从首页验证两行 `运行中`、进入 B 显示 `Deep diving...`、返回后两个状态仍存在。 | Xcode Beta arm64 iPhone Simulator 聚焦测试 2/2 通过，结果包 `/tmp/hm-run005-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_12-29-24-+0800.xcresult`；SwiftPM 全量 740 tests、3 skipped、0 failures；Plugin Host `npm run check`、`audit-no-remote-execution`、`check-upstream-parity` 与 `git diff --check` PASS。 | `RUN-005 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro A/B 并发触控、VoiceOver、真实 API/iSH、后台/长会话、100 次切换和双 JSONL 无串写仍未验收，不写成 `DONE`。 |
| 2026-08-26 | AGENT-001：新增锁定 DeepSeek 上游 commit 的 `agent-lifecycle-v1.json`，覆盖 normal/empty/tool/steer/inject/followup/pre-step rejection/request failure-retry/cancellation 九个场景；运行时对 durable event type/order、source-event links、turn/step closure 和 terminal kind 做 fail-loud differential 检查，fixture commit 必须与 `Dependencies/upstreams.lock.json` 相等。 | SwiftPM 聚焦 `AgentRuntimeTests.testPinnedDeepSeekAgentLifecycleDifferentialFixture` 通过，`AgentRuntimeTests` 61/61；Xcode Beta arm64 iPhone 17 Pro Simulator 聚焦 XCTest 1/1 通过，结果包 `/tmp/hm-agent001-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_12-46-04-+0800.xcresult`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` 均 PASS。 | `AGENT-001 VERIFY/CLOSED`（自动/模拟器门）；没有 iPhone 16 Pro 真实 API、iSH、后台、长会话或设备级生命周期证据，仍保留 VERIFY 边界。 |
| 2026-08-26 | AGENT-002：新增锁定 DeepSeek 上游 commit 的 `tool-scheduler-v1.json`，覆盖启动前模式重分类、bounded rolling pool、exclusive barrier、模型顺序提交，以及取消时 started drain 与 skipped synthetic result；`AgentRuntimeTests` 增加 `reclassification-before-launch` 和 `abort-started-vs-skipped` 两个差分场景，错误码分别验证 `TOOL_INTERRUPTED` 与 `TOOL_ABORTED_BEFORE_DISPATCH`，不重复执行副作用工具。 | SwiftPM 聚焦 `AgentRuntimeTests.testPinnedDeepSeekToolSchedulerDifferentialFixture` 通过，`AgentRuntimeTests` 62/62；Xcode Beta arm64 iPhone 17 Pro Simulator 聚焦 XCTest 1/1 通过，结果包 `/tmp/hm-agent002-xcode.xcresult`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` 均 PASS。 | `AGENT-002 VERIFY/CLOSED`（自动/模拟器门）；没有 iPhone 16 Pro 真实 API、iSH、后台、长会话或设备级工具调度证据，仍保留 VERIFY 边界；下一项 `GUARD-001`。 |
| 2026-08-26 | GUARD-001：移植上游 `repeat-tool-reminder` 为 native Cordis advisory plugin。`tools/post-execute` 按 Agent identity 统计连续相同 tool name + 深排序完整 args，3/5/8 阈值生成 gentle/detailed 用户 notice；include/exclude wildcard、用户边界重置、denied/error attempt 计数、下游结果与额外上下文保留、配置 fail-loud 均接入。新增 `RepeatToolReminder.swift`、`CordisToolExecutionResult.additionalContexts` 及 App core plugin 安装，并补齐 Xcode 审计输入清单。 | SwiftPM 全量 745 tests、3 skipped、0 failures；`CordisPluginRuntimeTests` 聚焦 3/3；Xcode Beta arm64 iPhone 17 Pro Simulator `CordisPluginRuntimeTests` 19/19，结果包 `/tmp/hm-guard001-xcode-rerun.xcresult`；Plugin Host `npm run check`、无远程执行审计、upstream parity、`git diff --check` 均 PASS。 | `GUARD-001 VERIFY/CLOSED`（自动/模拟器门）；没有 iPhone 16 Pro 真实 API、iSH、后台、长会话或设备级插件安装证据，仍保留 VERIFY 边界；下一项 `GUARD-002`。 |
| 2026-08-26 | GUARD-002：移植上游 `timeout-policy` 为 native Cordis core plugin。`ToolCancellationSignal` 为 `tools/execute` 临时派生 cooperative deadline，始终等待工具 quiesce；仅 policy 自身 deadline 映射为 `ToolTimeoutError`/`TOOL_TIMEOUT`，外层取消不改写，`tools/post-execute` 看到恢复后的上游 signal。`ModelToolDefinition.timeoutMs` 仅本地可见，Codable wire 明确省略，web fetch/search 从既有 limits 声明 timeout。 | `CordisPluginRuntimeTests` 新增 timeout quiescence、快速结果/上游取消、signal 恢复/禁用与无 timeout passthrough 4 项；定向 SwiftPM 24/24，SwiftPM 全量 749 tests、3 skipped、0 failures；Xcode Beta arm64 iPhone 17 Pro Simulator 定向 XCTest 24/24，结果包 `/tmp/hm-guard002-xcode.xcresult`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `GUARD-002 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro 真实 API/iSH、后台/长会话、真实插件安装与 timeout 后资源清理仍待验收；下一项 `LOG-001`。 |
| 2026-08-22 | `web_search` 对齐 RC.8 多查询契约：去重、并发、round-robin 合并、URL 全局去重、结果上限和可注入 provider | `WebFetchToolTests` 与 provider seam 回归通过；请求仍由手机直接发出 | WEB-001/002/003 DONE |
| 2026-08-22 | RC.8 DeepSeek vision Files API：multipart `purpose=user_data` 上传、7 天默认过期、内存缓存、凭据摘要隔离、文件引用错误 inline 回退；wire 新增 `type=file/file_id` | 初次只完成 `swift build`；后续 Provider 收口已补齐 XCTest 和 Xcode Beta 构建，仍未调用真实 API key | IMG-005 VERIFY，待真实 endpoint 和真机验收 |
| 2026-08-22 | 增加只读上游差异检查：锁定 commit、官方 packages、手机工具和 slash commands 均输出为可审计清单 | `Scripts/check-upstream-parity.sh` 通过 | BASE-006 DONE |
| 2026-08-22 | Jobs 面板接入持久子 Agent 树：当前会话按深度显示 child 状态，支持打开子会话和停止活动 child；复用既有 `HarnessJobRegistry`，不新增存储格式 | `swift build` 通过；需要 Xcode/iOS UI 验证打开/停止路径 | SUB-006/JOB-001 VERIFY |
| 2026-08-22 | Slash command 图片 admission：新增向后兼容 `imagePolicy`，执行层统一拒绝未声明图片的命令；`/goal` 与 `/plan` 明确接收图片，`/plan off` 拒绝图片；交互恢复携带引用；原生客户端 manifest 支持可选 `inputImages` 并向 Host tool 传递 `$imageAttachments` | `swift build`（核心 target）通过；`swift test` 受当前命令行环境缺少 XCTest 阻塞，需 Xcode 真机/模拟器补跑聚焦测试 | IMG-008/CMD-007 DONE (Xcode verification pending) |
| 2026-08-22 | Slash command 状态与反馈补齐：`/goal edit/pause/resume/complete/block/clear` 统一复用 WorkStateCoordinator；`/feedback` 支持消息级 like/dislike/note/clear/show，sidecar 独立持久化并带 revision | `swift build` 通过；`git diff --check` 通过；`swift test` 受当前命令行环境缺少 XCTest 阻塞，需 Xcode 真机/模拟器补跑聚焦测试 | CMD-005 DONE；CMD-006/FEEDBACK-001/002 VERIFY |
| 2026-08-22 | 放宽 OpenAI-compatible SSE 完成条件：semantic finish 或 `[DONE]` 任一即可；仅有 `[DONE]` 时补受限 stop/tool_calls 终止事件，无终止标记仍拒绝 | `DeepSeekWireTests` 21/21 通过；新增两种兼容网关结束形态回归 | WIRE-004 DONE |
| 2026-08-22 | 新增只读 session trajectory 工具：`session_trace`、`session_search`、`session_event_get`、`session_event_types`；统一复用 `SessionTrajectoryRepository`，支持 cursor 分页、类型筛选、稳定序号读取和字段/token 脱敏；补齐 Xcode 工程与测试 target 引用 | `SessionTrajectoryToolsTests` 覆盖分页、搜索、精确读取、类型统计和 API key 脱敏；当前命令行环境未启用 Xcode，待 Xcode Beta 聚焦测试与真机验收 | TOOL-006 VERIFY |
| 2026-08-22 | 增加本机持久 schedule 管线：`schedule_create/list/delete` 共享 `HarnessScheduleStore`，支持磁盘恢复、会话隔离、未来时间校验、幂等取消和原子 due claim；接入 `BGProcessingTask` 唤醒、会话恢复、本机 Agent 回合、过期取消和下一次调度，并接入主 Agent/Cordis 工具目录与原生工具事件 UI | `swift build` 通过；Xcode Beta arm64 Simulator 构建通过，设备审计通过；`HarnessScheduleTests` 已补，命令行环境缺少 XCTest；待 iPhone 真机后台唤醒验收 | TOOL-007 VERIFY |
| 2026-08-22 | 接入持久 PTY 工具：`terminal_open/read/send/signal/list/close` 复用 OpenMinis `ISHShellExecutor.startPersistentExecutable`，运行于手机本机 iSH；补齐 HarnessISH 导入、Int32 PID 转换、Xcode 工程源文件和设备审计清单，并移除 AppModel 重复安装结果转换方法 | `swift build` 通过；`git diff --check` 通过；Xcode Beta arm64 iOS Simulator build 通过；真实 iPhone PTY、冷启动 interrupted 和长输出压力仍待验收 | TOOL-005 VERIFY |
| 2026-08-22 | 后台任务完成通知改为 claim/ack/lease：投递前 claim，目标会话持久接收成功后 ack；主 Agent 忙时安全排队，失败自动 requeue；App 冷启清除旧 claim，避免结果丢失或重复注入 | `HarnessJobsTests` 覆盖失败重投、仅一次 ack、冷启 claim 恢复；`swift build`、`git diff --check` 通过；XCTest/Xcode 真机交互仍待执行 | JOB-002/003 VERIFY |
| 2026-08-22 | 修复设备审计清单漏列 `PluginInstallCoordinatorTests.swift`，补齐 Xcode 工程与边界审计输入的一致性 | `Scripts/audit-no-remote-execution.sh` 通过；`npm run check` 通过；`swift build` 与 `git diff --check` 通过 | VERIFY-002/003 基础校验通过 |
| 2026-08-22 | 用 Xcode Beta 对 HarnessMobile iOS Simulator 工程做实际构建，确认主 App 与 Live Activity target 可编译 | `xcodebuild ... -sdk iphonesimulator ... build` 通过；聚焦 XCTest 因并行 Xcode 构建锁/资源抢占未完成断言执行，不能记为测试通过 | VERIFY-004 build 通过；JOB-002/003 测试仍待串行执行 |
| 2026-08-22 | workflow 成员生命周期事件补齐树关联、delegation depth、开始时间、耗时与局部错误；仍使用同一 trajectory，不增加平行状态存储 | `swift build`、`git diff --check` 通过；`WorkflowToolTests` 新增事件字段断言，Xcode 聚焦 XCTest 已串行通过 | WF-001/WF-002 VERIFY |
| 2026-08-22 | workflow 边界契约补齐：子任务超时/终止宽限可注入，普通分支失败保留 `null`，父 workflow 取消不会误报成功；Jobs `wait` 只观察不消费 completion notice | Xcode Beta iPhone 17 Simulator 聚焦 `HarnessJobsTests`、`NativeToolEventPresentationTests`、`WorkflowToolTests` 共 41/41 通过；`swift build`、`git diff --check` 通过。全量 UI 测试因当前环境 `simctl` 不在默认 PATH 导致 runner 被 kill，不能作为产品失败证据 | WF-002/WF-004 VERIFY；JOB-002/003 VERIFY |
| 2026-08-22 | 串行完成 Xcode Beta 全量测试，并在隔离 DerivedData 路径完成 iPhone 17 Pro Simulator 启动和首屏截图；另完成 generic iOS arm64 构建 | 全量结果包 `/tmp/HarnessMobile-full-outside.xcresult`：539 项、534 通过、5 跳过、0 失败；UI 8 项、0 失败；`npm run check`、Node Plugin Host smoke、无远程执行审计、parity 检查和 `git diff --check` 均通过 | VERIFY-002~006 DONE；真机/后台/真实 API 仍待 VERIFY-007~010 |
| 2026-08-22 | 接入 RC.8 `ralph` 固定多轮循环：每轮 fresh child、不继承父会话，工作区作为长期记忆，以有界 JSON handoff 传递 continue/complete/blocked；支持部署轮次上限、取消中断和失败显式返回 | `swift build` 通过；Xcode/Ralph 聚焦 XCTest 与真机 trajectory/恢复验收待执行 | TOOL-008 VERIFY |
| 2026-08-22 | 接入本机 MCP stdio：复用 iSH persistent process，不引入 host Process/远端 executor；实现 MCP initialize、分页 tools/list、tools/call、取消/超时/尺寸上限、稳定工具名和四个生产控制工具；所有入口共用 AppModel registry，并拒绝把 provider-shaped credential 放入 server env | SwiftPM MCP 聚焦 3/3 通过；Xcode Beta arm64 Simulator build 与 MCPClientTests 3/3 通过；设备边界审计通过。真机 MCP server、动态直出工具 definitions 和 resources/prompts 尚待完成 | TOOL-010 VERIFY |
| 2026-08-22 | 复用上游 LSP capability seam 设计，在 iSH 内实现 `initialize → didOpen → semantic query → didClose → shutdown`；只向模型暴露 definition/references/implementation/hover 四种只读操作，严格使用一基 UTF-16 坐标并规范化 LocationLink/MarkedString | `LSPToolTests` 5/5 通过，`swift build` 通过；真机语言服务器安装、per-workspace 持久池和自定义 provider 设置页待验收 | TOOL-011 VERIFY |
| 2026-08-22 | 对齐官方文件工具与 Minimal editor：修复空 write/删除式 edit、alias freshness 绕过、空文件行数、字段级错误、NUL 拒绝、CRLF 保持和真正分块 UTF-8 读取；新增本机 `str_replace_editor` 四命令与两层目录过滤 | SwiftPM 全量 556 项、3 跳过、0 失败；其中 `FileSystemToolsTests` 24/24、`StrReplaceEditorToolTests` 6/6；Xcode Beta arm64 Simulator 文件/LSP/目录聚焦集 38/38；设备边界审计通过，真机大文件与 replay-safe diff meta 待验收 | TOOL-012 VERIFY |
| 2026-08-22 | 补齐搜索、网页和后台任务的原生专用卡片：复用现有工具返回契约，增加 `workspace_search/glob/grep`、`web_search/web_fetch`、`job_list/output/kill` 的有界投影、折叠显示、溢出提示和损坏数据回退；同时修正 workflow 行摘要插值 | `NativeToolEventPresentationTests` SwiftPM/Xcode Beta Simulator 均 19/19；SwiftPM 全量 563 项、3 跳过、0 失败；Xcode Beta arm64 Simulator build、安装、冷启动后稳定首屏、设备边界审计、Plugin Host check、parity check 和 `git diff --check` 全部通过 | UI-004 VERIFY，待 iPhone 16 Pro 可访问性/触控验收 |
| 2026-08-22 | 长对话渲染移出高频路径：消息去重与 80 条分页只随 `messagesRevision`/翻页计算；流式滚动改看 monotonic revision，尾部达到 8K/4K 上限后仍更新；实时工具输出按 100 ms 合并且复用 64 KiB/UTF-8 截断契约；增加 240 条真实 SwiftUI 分页夹具和 VoiceOver 剩余数量 | `ConversationMessageWindowTests` SwiftPM/Xcode Beta 6/6；SwiftPM 全量 569 项、3 跳过、0 失败；Xcode Beta iPhone 17 Pro Simulator 长会话 UI 1/1；设备边界审计、Plugin Host check、upstream parity 和 `git diff --check` 通过。真机 Instruments 轨迹仍待采集 | UI-007 VERIFY |
| 2026-08-22 | 复用问答页既有 Markdown 解析器并下沉纯文档模型到 Core，正常助手消息支持 heading/list/quote/fence/inline Markdown；新增 GFM-style 表格、转义/inline-code pipe、列对齐、短行补齐、96–240 pt 有界列和卡片内横向滚动，流式阶段避免反复解析不完整 Markdown | `NativeMarkdownTextTests` SwiftPM/Xcode Beta 4/4；SwiftPM 全量 573 项、3 跳过、0 失败；Xcode Beta iPhone 17 Pro Simulator 五列表格在 Accessibility XXXL 下渲染并横向滚动 1/1；设备边界审计、Plugin Host check、upstream parity 和 `git diff --check` 通过。真机 VoiceOver/触控仍待执行 | UI-005 VERIFY |
| 2026-08-26 | 三方主进度 UI-005（渐进披露） | 首页收敛为继续/新建、最近会话和后台状态；工作区、轨迹、iSH 终端、插件与设置进入工具二级页；后台状态直达后台设置；设置按模型、后台、工具插件、存储同步、隐私诊断分组，明确同步未启用与本机执行边界。 | `HarnessMobileProgressiveDisclosureUITests` 2/2；终端 Accessibility XXXL 深色横屏回归通过；SwiftPM 全量 733 tests、3 跳过、0 failures；Xcode UI 结果 `/tmp/hm-ui005-xcode6`，终端回归 `/tmp/hm-ui005-xcode4`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `UI-005 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro VoiceOver、真实触控、完整旋转、Dynamic Type、后台系统回调和设备级性能仍待验收；下一项 `UI-006` |
| 2026-08-22 | 补齐 Trajectory Inspect：Turn/Call header 显示局部耗时；System/User/Assistant/Tool result 显示语义化 payload；单步 usage 展示 uncached、cache read/write、cache hit 和 thinking，同时保留异步格式化的原始 JSON 回退 | Xcode Beta iPhone 17 Pro Simulator build 通过；`SessionEventTrajectoryTests` 覆盖模型/工具耗时、TTFT、去重 usage 与 cache 计算；真机长轨迹交互仍待执行 | UI-008 VERIFY |
| 2026-08-22 | 会话首页增加可展开 `/workspace` 根实体，统一投影当前 Session/运行状态、文件与挂载；Job registry 增加 cycle-safe root-to-current lineage，Chat 打开多级 child 后保留地址、状态与逐级返回入口；修复子 Agent 树深度/状态未插值的问题 | `HarnessJobsTests` 22/22；`swift test --parallel` 574 项、0 失败（3 个 opt-in/live 跳过）；Workspace Simulator UI 1/1；Xcode Beta Simulator build/install/launch、设备边界审计、Plugin Host check、parity check 与 `git diff --check` 通过 | UI-001/002、SUB-006 VERIFY；VERIFY-001 DONE |
| 2026-08-22 | 复用官方 `@deepseek-ai/dsh-commands` 接入 iSH Host 动态 Slash command：贡献按当前 session 合并到 native/nativeClient registry，保留输入策略和优先级，插件停用/替换时按 generation 精确撤回；执行结果回到原生 durable command lifecycle，避免 Host 镜像轨迹重复写入；无附件存储时图片命令显式拒绝 | Node Host `npm run check` 与动态 command smoke 通过；`ISHPluginHostTests` 24/24；`swift test --parallel` 575 项、0 失败（3 个 opt-in/live 跳过）；Xcode Beta Simulator build/install/launch、设备边界审计、upstream parity 与 `git diff --check` 通过 | CMD-004 VERIFY；待 iPhone 16 Pro 动态插件、取消与图片命令验收 |
| 2026-08-22 | 将 custom OpenAI 三档 wire profile 降为 UI preset，补齐 route/model 14 字段稀疏 compatibility 合并与常用 serializer 行为；Provider Profile 增加官方 nested `normal`/`always` retry，持续重试先让下游 recovery 处理，再覆盖任意 adapter failure，并安全丢弃失败部分流；修复截断工具调用后的空答仍保持原安全失败 | Provider/Wire Xcode Beta Simulator 初始聚焦 24/24，最终 retry/截断安全回归 14/14；SwiftPM 全量 584 项、0 失败（3 个 opt-in/live 跳过）；Xcode Beta 最新 App build/install/launch、设备边界审计、upstream parity 与 `git diff --check` 通过 | PROVIDER-002、WIRE-003/005 VERIFY；稀有格式、真实私有网关与 iPhone 16 Pro 待验收 |
| 2026-08-22 | 将共享传输层上方拆成 DeepSeek、OpenAI-compatible、Anthropic 三套 request/stream/error adapter；显式模型模态贯穿 profile 到请求快照，删除名称猜图能力；Anthropic 补 base64 图片块、error type/request-id，DeepSeek 错误映射和 Files 7 天寿命对齐上游 | Provider/Wire 定向 53/53；SwiftPM 全量 591 项、0 失败（3 个 opt-in/live 跳过）；设备边界审计、upstream parity 与 `git diff --check` 通过；未使用真实凭据 | PROVIDER-001、WIRE-006、IMG-005 VERIFY；待真实三类 endpoint 和 iPhone 16 Pro 验收 |
| 2026-08-22 | 增加版本化模型发现失败夹具与无网络 URLProtocol seam：覆盖 401/request-id、畸形模型表、声明超 4 MiB、跨 origin/非 HTTPS/credential URL、TTL 过期、凭据分区与手动未列出模型保留 | `ProviderModelDiscoveryTests` 14/14；SwiftPM 全量 594 项、0 失败（3 个 opt-in/live 跳过）；设备边界审计与 `git diff --check` 通过 | PROVIDER-003 DONE；真实私有网关仍属于 opt-in 验收 |
| 2026-08-22 | 增加独立上下文压缩摘要路由：设置页按 Provider Profile/模型选择并持久化，运行时单独解析凭据；只在首 token 前的配置或传输失败时安全回退主会话，部分输出、取消和协议错误不重复请求；新增锁定上游 commit 的跨版本压缩夹具 | Provider/Profile/Runtime/Fixture 定向 SwiftPM 测试和 iOS Simulator `AppModelProviderProfileTests` 通过；SwiftPM 全量 599 项、3 跳过、0 失败；Xcode Beta Simulator build、设备执行边界审计、parity 和 `git diff --check` 通过 | CTX-003/004 DONE |
| 2026-08-22 | 对齐上游 `time-context`：设置页显式开启并选择 iPhone/UTC 时区和刷新间隔；运行时在 pre-step 追加 durable plugin snapshot，不修改 system/header，刷新窗口内保留稳定前缀 | `TimeContextSettingsTests` 3/3、AgentRuntime durable/header 测试及 Xcode Beta iOS 定向测试通过；设备执行边界审计通过 | CTX-005 DONE |
| 2026-08-22 | 对齐上游 session-title service/两个 LLM provider：首问或全部提问 cadence、独立 Provider Profile/模型、128 token/64 KiB 输入/1 KiB 输出/15 秒超时、无工具请求、Keychain 凭据、离线 fallback、用户标题 pin、显式 regenerate 与 title trajectory 事件 | `SessionTitleSettingsTests` SwiftPM/Xcode Beta 3/3；Provider 删除时路由回退测试已扩展；SwiftPM 全量 606 项、3 跳过、0 失败 | CTX-006 DONE |
| 2026-08-22 | 清理桌面对齐文档的过期缺口：slash continuation/native `@`、Host commands、compaction route、child breadcrumb、feedback sidecar、Jobs delivery、MCP/LSP 当前边界与剩余顺序均改为当前实现；Profile Bundle 安装边界不再写成已完成 | 文档逐项对照当前生产代码与测试；`git diff --check` 纳入本轮收尾 | BASE-005 DONE |
| 2026-08-23 | 重构 AppModel 的插件市场/原生插件协调边界：原生清单物化、runtime/store 注册、回滚和编译追踪迁至 `AppModel+NativePluginLifecycle.swift`；主 Agent 市场工具、prepared-token 交接和 iSH fallback 迁至 `AppModel+PluginMarketplaceTool.swift`；继续复用既有 `PluginInstallCoordinator`、`NativeAgentPluginCompiler`、native store 和 Host。 | Xcode Beta arm64 Simulator build 通过；iPhone 17 Pro Simulator 聚焦 `NativeAgentPluginTests` 18/18、`PluginInstallCoordinatorTests` 10/10 通过；未改变 PLUGIN-009/010/011 的 iPhone 16 Pro 真机 VERIFY 状态。 | PLUGIN-009~011 VERIFY |
| 2026-08-22 | 将 Codex/Claude Code Profile Bundle 从 npm 包主页和全 0 哈希改为官方不可变 tarball URL 与实测 SHA-256；校验器 fail-closed 拒绝占位哈希 | 官方 npm registry metadata 与下载字节交叉核对；`AgentProviderBundleTests` 9/9 | PROFILE-001 VERIFY，仍待 iSH 安装器/真机执行 |
| 2026-08-22 | 扩展锁定 `dsh-v0.1.1-rc.2` / `b150a551...` 的跨版本夹具：reasoning replay、取消前缀、inline/file-id 图片、file/session 引用、continuable subagent descriptor v2、job snapshot/completion notice | `RC2CompatibilityFixtureTests` 6/6、既有上游 fixture 2/2、三份 JSON `jq empty` 与 diff check 通过 | BASE-004 DONE |
| 2026-08-23 | 在 OpenAI/DeepSeek 与 Anthropic Messages 请求编码边界增加 tool transcript 完整性校验：assistant tool call id 必须唯一且每个恰有一个 tool 结果，禁止孤立/无 id/重复结果；失败结果仍作为合法 tool result 传输，错误在本地以结构化 `invalidToolTranscript` 返回，避免远端 400 | `DeepSeekWireTests` 24/24、`CustomOpenAICompatibleWireTests` 6/6、`AnthropicMessagesWireTests` 7/7 通过；`git diff --check` 通过；真实 provider 与 iPhone 16 Pro 尚待验收 | WIRE-007 VERIFY |
| 2026-08-23 | 修复本机子 Agent 首次任务顺序：`initialUserMessage` 在首个 provider request 前按消息 ID 幂等追加到 provider-facing conversation；不再出现只有 system prompt、点开子会话才继续的假卡死 | 新增 `AgentRuntimeTests.testInitialUserMessageIsIncludedInFirstProviderRequestWhenHistoryIsEmpty` 通过；真实 iPhone 子 Agent 冷启动仍待验收 | SUB-007 VERIFY |
| 2026-08-23 | 修复真实诊断暴露的插件与 length 链路：native source snapshot 不再过滤 `lib/`；保存原生插件时沿 prepared canonical sourceKey，成功不会再误报来源不匹配；私有 file context 校验给出字段/实际值/路径模板；Vision 以当前目录覆盖陈旧 4K 模型缓存；移除应用侧正常模型输出字节上限及消息气泡截断，`length` 的纯文字/推理完整持久化并标记为 provider 边界，不自动发起隐藏续写；截断工具调用仍 fail-closed，绝不执行或续写。原生清单校验失败不可原样重试，必须修正后重新提交 | `AgentRuntimeTests` 60/60、`ProviderProfileTests` 12/12、`NativeAgentPluginTests` 19/19、`PluginInstallCoordinatorTests` 11/11、Plugin Host check、无远端执行审计与 diff check 通过；真实 API/iPhone 16 Pro 安装和长输出仍待验收 | WIRE-008、PLUGIN-009~010 VERIFY |
| 2026-08-25 | 按三方主进度 RUN-001 新增 DeepSeek Harness 语义的 `RunIdentity`、actor `MobileAgentHandle` 与唯一 `MobileAgentTerminalOwner`；复用 `QueuedAgentInput`，完整 identity 拒绝旧 generation，cancel 只发信号，dispose 共用 stop/drain/cleanup 边界；生产路径为 `HarnessMobile/Core/Agent/MobileAgentHandle.swift`，当前未接 AppModel/UI。 | `MobileAgentHandleTests` SwiftPM 8/8；iPhone 17 Pro Simulator iOS 27.0 TSan 8/8、无数据竞争报告；SwiftPM 全量 641、3 skipped、0 failed；arm64 generic Simulator build、Plugin Host、upstream verify、device-only audit、parity 和 diff check 均 PASS。 | RUN-001 DONE；未启用多会话/后台保活，真机保活仍待 RUN-002～BG-012；下一项 RUN-002 |
| 2026-08-25 | 按三方主进度 RUN-002 新增 actor `SessionRunRegistry`：以 durable session ID 保证一个 live root，允许不同 session 并存；实现准备配置、同步 publication commit、原子 publish、失败 rollback、结构化 collision/stale 错误、只读 snapshot/aggregate，以及 terminal owner 对 background lease 的唯一交接。生产路径为 `HarnessMobile/Core/Agent/SessionRunRegistry.swift`，当前未接 AppModel/UI。 | `SessionRunRegistryTests` SwiftPM 8/8；iPhone 17 Pro Simulator iOS 27.0 TSan 8/8、`runtimeWarnings` 为空；SwiftPM 全量 649、3 skipped、0 failed；arm64 generic Simulator build、Plugin Host、upstream verify、device-only audit、parity 和 diff check 均 PASS。 | RUN-002 DONE；真正的多 run 状态和后台保活尚未启用，下一项 RUN-003 原子迁移 per-run 可变状态，iPhone 16 Pro 真机仍待后续验收 |
| 2026-08-25 | 按三方主进度 RUN-003 将 AppModel 的 task、审批、问题、inbox claim、stream/tool 投影、run-local trace、prompt summary、后台状态和恢复监控迁入 actor `SessionRunState`/`SessionRunRegistry`/`SessionBackgroundResumeCoordinator`；所有 runtime callback 使用完整 `RunIdentity`，旧 generation 拒绝并诊断，UI 只读当前 session 的 `SessionRunPresentation`；actor 内原子创建 root task，启动失败不遗留 entry。 | SwiftPM 聚焦 22/22；iPhone 17 Pro Simulator iOS 27.0 TSan 22/22、`runtimeWarnings` 为空，结果包 `/tmp/hm-run003-xcode-tsan-final`；SwiftPM 全量 663、3 skipped、0 failed；arm64 generic Simulator build、Plugin Host、upstream lock、device-only audit、parity 和 `git diff --check` 均 PASS。 | RUN-003 VERIFY/CLOSED；`switchConversation` 的多 run 留存与页面切换 registry 数量由 RUN-005 闭合；后台保活和 iPhone 16 Pro 真机仍未完成；下一项 RUN-004 |
| 2026-08-25 | 按三方主进度 RUN-004 统一 terminal owner：取消保持 identity/task，continued worker completion 在真实 runtime 退出后才允许 settle；trajectory flush、精确 session checkpoint、iSH context sync、continued/Live Activity/notification lease release、projection refresh 和 registry removal 由唯一 exactly-once 清理链完成。system expiration 记录 `interrupted` 并把恢复监控置于 registry removal 之后；业务失败回传 continued worker，避免错误 success。 | SwiftPM 全量 666、3 skipped、0 failed；聚焦状态/registry/continued 32/32、取消与 handle 14/14；iPhone 17 Pro Simulator iOS 27.0 TSan 46/46，`runtimeWarnings` 为空，结果包 `/tmp/hm-run004-xcode-tsan/Logs/Test/Test-HarnessMobile-2026.08.25_01-45-59-+0800.xcresult`；arm64 generic Simulator build、Plugin Host、upstream lock、device-only audit、parity 和 `git diff --check` 均 PASS。 | RUN-004 VERIFY/CLOSED；iPhone 16 Pro 真机后台过期、真实 API、iSH、长会话和 10/30/60 分钟保活仍未验证；下一项 RUN-005 |
| 2026-08-25 | SCHED-001 | 按三方主进度实现 schedule durable lease：claim 记录 exact owner/时间/attempt，冷启动和 claim 前回收过期租约（包括旧记录缺失 lease）；新增 ack/requeue/reclaimExpired，`.completed` 终态，旧 JSON 自定义解码兼容；AppModel 对 BG schedule 的每个成功、冲突、取消、失败、expiration 分支都有 owner-scoped ack/requeue，过期不会取消无关前台 run。 | SwiftPM `HarnessScheduleTests` 6/6；全量 671 tests、3 skipped、0 failures；覆盖 ack/requeue、错 owner、lease 过期、冷启动迁移 | SCHED-001 VERIFY/CLOSED（自动门）；iPhone 16 Pro schedule 崩溃/expiration 仍待真机 |
| 2026-08-25 | BG-001 | 将静态 BGProcessing 注册从 SwiftUI `.task` 移到 `HarnessMobileAppDelegate.didFinishLaunching`；新增 `ScheduleBackgroundLaunchCoordinator` 暂存无 root/session 的系统 task，AppModel attach 后交付，pending task 自带 expiration 兜底并 complete(false)，重复注册幂等；Continued Processing 动态标识保持独立。 | `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project HarnessMobile.xcodeproj -scheme HarnessMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /tmp/hm-bg001-xcode build`：`BUILD SUCCEEDED` | BG-001 VERIFY/CLOSED（自动/构建门）；未执行无-root 冷启动夹具、系统 expiration/complete 回调和 iPhone 16 Pro 真机，不等于后台保活 DONE；下一项 BG-002 |
| 2026-08-25 | BG-002 | 新增 `LegacyBackgroundTaskLease` 并接入 AppModel root run：多个 run 共用一个 UIKit finite background task；每 run 以 `SessionRunBackgroundLeaseToken` 持有，重复 release 无副作用；expiration 逐一精确路由完整 `RunIdentity`；Continued Processing 系统任务 attach 后释放 finite lease，exactly-once terminal cleanup 保留兜底释放。 | `LegacyBackgroundTaskLeaseTests` 3/3；SwiftPM 全量 674 tests、3 skipped、0 failures；arm64 generic iOS Simulator build `/tmp/hm-bg002-xcode`：`BUILD SUCCEEDED`；Plugin Host check、`audit-no-remote-execution`、`check-upstream-parity` 通过。 | BG-002 VERIFY/CLOSED（自动门）；未运行 iPhone 16 Pro 锁屏、低电量、热压力、真实 UIKit expiration，不能声称真机后台保活完成；下一项 BG-003 |
| 2026-08-25 | BG-003 | 新增 `HarnessAudioSessionCoordinator`：单一平台适配器负责 `AVAudioSession` category/active；四级 intent 采用引用计数和优先级解析；首次占用保存原始状态，最后释放恢复；interruption、route change、media services reset 统一重建当前 profile；不记录媒体正文，未启用后台 audio mode。 | `HarnessAudioSessionCoordinatorTests` 3/3；聚焦 SwiftPM 使用 `/tmp/hm-build` 通过。 | BG-003 VERIFY/CLOSED（自动门）；当前没有 TTS/录音/keepalive 生产调用点，真实 iPhone 16 Pro 电话、蓝牙、锁屏和后台音频仍待验收；下一项 BG-004 |
| 2026-08-25 | BG-004 | 新增 `BackgroundAudioKeepAlive`：真实 iOS `AVAudioEngine`/`AVAudioPlayerNode` 循环静音缓冲；仅后台、用户开启增强后台且存在 live root 时启动；引擎/player 健康检查；失败 0.5 秒间隔最多 3 次；新 generation 复位尝试预算；中断/媒体服务重置按 generation 重启；前台停止 1.5 秒防抖；媒体暂停嵌套 refcount；AppModel scene/live-root 聚合接入；Info.plist 增加 `audio` background mode。 | `BackgroundAudioKeepAliveTests` 5/5；聚焦 SwiftPM 使用 `/tmp/hm-build` 通过。 | BG-004 VERIFY/CLOSED（自动门）；尚未进行 iPhone 16 Pro 锁屏、电话/蓝牙竞争、低电量、热压力和长时保活验收；下一项 BG-005 |
| 2026-08-25 | BG-005 | 新增 `BackgroundLocationKeepAlive`：独立定位保活开关；仅 Always 授权、后台、live root 和约 15 秒延迟均满足时启动约 3km `CLLocationManager` 与进程级 `CLBackgroundActivitySession`；when-in-use/denied/restricted/unavailable 明确降级；前台、最后 live root、撤权立即停止；generation 防止旧延迟任务反转；冷启动 retract orphan session；AppModel/设置/偏好/Info.plist/project.yml 接入，坐标不写 trajectory/diagnostic/上传。 | `BackgroundLocationKeepAliveTests` 6/6；SwiftPM 全量 688 tests、3 skipped、0 failures；arm64 generic iOS Simulator `/tmp/hm-bg005-xcode` `BUILD SUCCEEDED`；Plugin Host、无远端执行审计、upstream parity、`git diff --check` 通过。 | BG-005 VERIFY/CLOSED（自动门）；真实 iPhone 16 Pro 权限弹窗、锁屏、低电量、热压力和长时保活仍待验收；下一项 BG-006 |
| 2026-08-25 | BG-006 | 新增 `BackgroundKeepAliveCoordinator`/`BackgroundKeepAliveState`，按 generation 汇总 scene/live-root、finite、continued、audio、location、低电量和热约束，发布统一 survival/degraded layers；AppModel 音频/定位刷新与媒体 suspend/resume 接入协调器，Agent loop/terminal owner 不下沉到资源协调器。 | `BackgroundKeepAliveCoordinatorTests` 3/3；SwiftPM 全量 691 tests、3 skipped、0 failures；arm64 generic iOS Simulator `/tmp/hm-bg006-xcode` `BUILD SUCCEEDED`；Plugin Host、无远端执行审计、upstream parity、`git diff --check` 通过。 | BG-006 VERIFY/CLOSED（自动门）；低电量/热压力具体降级策略和真实 iPhone 16 Pro 系统回调、锁屏、长时保活仍待验收；下一项 BG-007 |
| 2026-08-25 | BG-007 | `ContinuedProcessingController` 改为按 runID 的 `ContinuedProcessingRunBook`，每个 request/system task/worker 使用独立状态机；request、attach、expiration、report、finish、cancel、release 均绑定可选完整 `RunIdentity`，AppModel 已显式传入当前 identity，finite lease 只在对应 handoff 释放。 | `ContinuedProcessingStateMachineTests` 12/12；SwiftPM 全量 694 tests、3 skipped、0 failures；arm64 generic iOS Simulator `/tmp/hm-bg007-xcode2` 首次编译发现并修复 `run.identity` 字段错误，最终 `/tmp/hm-bg007-xcode2` `BUILD SUCCEEDED`；Plugin Host、无远端执行审计、upstream parity、`git diff --check` 通过。 | BG-007 VERIFY/CLOSED（自动门）；真实 iPhone 16 Pro Continued Processing 提交/接管/expiration、多 session 长时运行仍待验收；下一项 BG-008 |
| 2026-08-25 | BG-008 | 新增 `BackgroundRunJournal`：独立 application-support 原子 JSON、iOS complete file protection、最小 per-run descriptor；AppModel 在启动/前台/发布/Continued handoff/terminal cleanup 接入。orphan audit 幂等闭合非终态为 interrupted，清空 Continued/finite/audio/location/Live Activity 标识，不恢复 Agent 或工具副作用。 | `BackgroundRunJournalTests` 3/3；arm64 generic iOS Simulator `/tmp/hm-bg008-xcode` `BUILD SUCCEEDED`；`git diff --check`、Plugin Host、无远程执行审计和 upstream parity 见本轮收尾记录。 | BG-008 VERIFY/CLOSED（自动/构建门）；force-quit、系统 expiration、锁屏、低电量/热压力和 iPhone 16 Pro 真机仍待验收 |
| 2026-08-25 | BG-009 | 新增 `HarnessLLMSessionRegistry`/`HarnessLLMNetworkPathMonitor`，按接口集合变化去重并 reset 长期模型 URLSession；当前 SSE 流显式以 `networkPathChanged` 结束，后续连接复用已清空连接池的 session；`SessionRunState` 后台冻结 presentation 发布，前台一次性合并流式文本和工具输出。 | `HarnessLLMSessionRegistryTests` 1/1；`SessionRunStateTests` 后台冻结回归 1/1；Xcode arm64 generic iOS Simulator、SwiftPM 全量和审计收尾见本轮记录。 | BG-009 VERIFY/CLOSED（自动/构建门）；真实 Wi-Fi/蜂窝/VPN、长流重连和 iPhone 16 Pro 后台验收仍待完成 |
| 2026-08-25 | BG-010 | Live Activity 改为按 `runID` 的多 run registry；统一 `BackgroundSystemProjection` 接入 SessionRunRegistry aggregate、keep-alive survival tier、权限、降级原因和隐私模式；首页/设置共享同一投影；投影变化写脱敏 `background_projection_changed` 时间线。 | SwiftPM 全量 701 tests、3 skipped、0 failures；新增多 run 投影隔离和 Continued Processing 优先级回归；Xcode/iPhone 16 Pro 系统权限、锁屏多 run、通知和长时后台仍待设备验收。 | BG-010 VERIFY/CLOSED（自动门）；真机边界 VERIFY |
| 2026-08-25 | BG-011 | 故障注入矩阵收口：权限撤回、音频失败/重置、定位失败、BG expiration owner、network path 去抖、低电量/温度、cancel/success、冷启 orphan、Live Activity 隔离与 100 次 lifecycle jitter；`degradedDetails` 进入脱敏证据时间线。 | `BackgroundKeepAliveCoordinatorTests` 聚焦 5/5；既有 audio/location/lease/network/continued/journal/live-activity fixtures 纳入矩阵；后续 SwiftPM 全量与 Xcode arm64 build 作为收尾门。 | BG-011 VERIFY/CLOSED（自动门）；电话/蓝牙/权限系统回调和 iPhone 16 Pro 长时后台 VERIFY |
| 2026-08-26 | MCP-001/MCP-002 | 受持久化的 stdio 配置启动时映射为 `mcp.<server>` Cordis 插件；配置逐项校验并拒绝 credential-shaped env，发现完成后把 `mcp__server__tool` 作为直接模型工具注册。移除了模型可调用的 connect/list/call/disconnect meta tools；卸载只断开所属 server，注册冲突由 Cordis generation 回滚。transport 退出后以全新 iSH transport/client generation 有界退避重连，先完成发现，再在单个 Cordis tool actor 事务中切换工具集；连续失败耗尽时撤销该 server 工具，在途调用始终停留在旧 generation。配置文件还拒绝顶层或 server 内的未知 transport 字段，防止远程传输形状被静默接受。 | `MCPClientTests` 覆盖配置、namespace、冲突、重连清单、失败上限、在途代际、recovery 卸载及 remote transport 形状拒绝；`swift test --build-path /tmp/hm-build` 全量 756 项、3 跳过、0 失败；arm64 generic iOS Simulator build（`/tmp/hm-mcp001-reconnect-xcode`）通过；设备边界审计、upstream parity、`git diff --check` 均通过。 | MCP-001 VERIFY/RUNNING：自动边界已覆盖；仍未在 iPhone 16 Pro 上运行真实 iSH MCP server。MCP-002 OUT-OF-SCOPE/CLOSED：远程 HTTP/OAuth/Keychain 不进入本机/iSH-only 工具边界。 |
| 2026-08-25 | LOG-001 | 在 SessionEvent canonical JSONL 上增加 model-visible provenance 审计：校验 request header、消息 ID、tool result call ID 和注入上下文均有 durable source event；AgentRuntime 在 provider/Cordis dispatch 前 fail-closed，错误 trace 仅含 kind/index；root/child AppModel runtime 提供 lossless snapshot，保留 unknown required/ignorable gate。 | `SessionEventTrajectoryTests` 21/21；SwiftPM 全量 707 tests、3 skipped、0 failures；Xcode arm64 generic Simulator `/tmp/hm-log001-xcode3` `BUILD SUCCEEDED`；Plugin Host、无远端执行审计、upstream parity、`git diff --check` 通过；正常、缺失消息、缺失工具响应、缺失 header 和脱敏错误回归通过。 | LOG-001 VERIFY/CLOSED（自动门）；真实 Browser/MCP response 注入链路和 iPhone 16 Pro 真机仍待 BROWSER/MCP、BG-012 | 下一项 PLUGIN-001 |
| 2026-08-25 | PLUGIN-001 | `CordisPluginRuntime` 增加 owner + generation 校验、staged replacement、完整新代 commit 后再撤旧代、失败候选 disposer 回滚、service reservation 恢复和 inventory 零残留；in-flight checkpoint/event 在 owner 失效后丢弃陈旧结果；并发 disable/replacement 和重复 replacement 均 fail-closed。 | `CordisPluginRuntimeTests` 16/16；SwiftPM 全量 711 tests、3 skipped、0 failures；Xcode arm64 generic iOS Simulator `/tmp/hm-plugin001-xcode` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、上游 parity、`git diff --check` 均 PASS。 | `PLUGIN-001 VERIFY/CLOSED`（自动门）；真实 iPhone 16 Pro 插件安装/热更新、iSH、Browser/MCP 长会话和设备级 in-flight 竞态仍待验收；上一版 Minis 对比文档保留为 `Docs/OPENMINIS_COMPARATIVE_AUDIT_2026-08-24.md`；下一项 PLUGIN-002 |
| 2026-08-25 | PLUGIN-002 | 复用 `ISHNativeClientProtocol` 的 settings/card/command manifest，新增 `ISHNativeClientSlotRegistry`，将三类贡献投影为固定 Swift `settings.card`、`conversation.renderer`、`sidebar.action` DTO；内部 key 按 plugin namespace 隔离，generation 不匹配、未知贡献和非 allowlist renderer fail-closed；注册 token 纳入 native Cordis activation disposer，卸载即撤 UI 贡献。 | `ISHNativeClientTests` 10/10；SwiftPM 全量 713 tests、3 skipped、0 failures；Xcode arm64 generic iOS Simulator `/tmp/hm-plugin002-xcode` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、上游 parity、`git diff --check` 均 PASS。 | `PLUGIN-002 VERIFY/CLOSED`（自动门）；还未在 iPhone 16 Pro 验收真实插件 UI、settings 写入、conversation renderer 长会话和多插件切换；未知 Web/React/Swift 下载代码仍拒绝；下一项 `STORE-002` |
| 2026-08-25 | STORE-001 | 新增统一 `SessionPersistence` capability seam、opaque `SessionPersistenceRevision`/snapshot 和 session listing；`SessionTrajectoryRepository` 作为 canonical JSONL provider 实现协议。AppModel、原生插件生命周期和 `SessionTrajectoryToolSuite` 改为依赖 `any SessionPersistence`，不引入第二套持久事件类型，SessionStore 的 v4 snapshot 仍只是派生/兼容面。 | `SessionTrajectoryRepositoryTests` 10/10（含 seam append/flush/revision/list/delete）；SwiftPM 全量 714 tests、3 skipped、0 failures；Xcode arm64 generic iOS Simulator `/tmp/hm-store001-xcode` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、上游 parity、`git diff --check` 均 PASS。 | `STORE-001 VERIFY/CLOSED`（自动门）；真实 iPhone file protection、冷启动 repair、锁屏写入失败和外部 writer 竞争仍待 `STORE-002`/真机验收；下一项 `STORE-002` |
| 2026-08-25 | STORE-002 | `SessionEventJSONLStore` 增加 write-behind pending batch queue；logical `nextSequence` 与 durable revision watermark 分离；`flush()` 以 barrier offset/revision 回滚整批失败写入或同步错误并保留 pending，不吞 file-handle 错误；`.synchronized` 自动 flush，prepare/close/delete/read-after-write 走 flush barrier；冷启动 torn-tail repair 和 synthetic interruption closers 继续 append-only、幂等；空 JSONL 不列入 session。canonical SessionEvent/JSONL 仍是唯一权威源。 | `SessionEventTrajectoryTests` 24/24；`SessionTrajectoryRepositoryTests` 11/11；SwiftPM 全量 718 tests、3 skipped、0 failures；Xcode arm64 generic iOS Simulator `/tmp/hm-store002-xcode` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` 均 PASS。 | `STORE-002 VERIFY/CLOSED`（自动门）；真实 iPhone file protection、锁屏写入失败、外部 writer 竞争和强制结束后的设备级 repair 仍待验收；下一项 `STORE-003` |
| 2026-08-25 | STORE-003 | 新增可删除重建的 SQLite FTS5 session query read model：WAL、application ID/schema fail-closed、session/event 派生表、literal phrase 搜索与 snippet、canonical durable sequence watermark 增量索引；append 后 index 前崩溃、watermark 回退、行数不一致触发 session-local rebuild；删除数据库可由 JSONL 全量恢复，canonical 删除会清理 stale rows；AppModel 会话摘要刷新/搜索最小接线，失败回退 SessionStore；不把 SQLite 变成写入权威。参考上游 `session-query`/`session-query-sqlite` 与上一版 Minis ChatStore/SQLite 对比结论。 | `SessionQueryReadModelTests` 6/6；10,000 session rebuild + 1,000 list 基线 14.307s；SwiftPM 全量 724 tests、3 skipped、0 failures；Xcode arm64 generic iOS Simulator `/tmp/hm-store003-xcode6` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `STORE-003 VERIFY/CLOSED`（自动门）；canonical JSONL/SessionPersistence 仍是权威源；iPhone 16 Pro 长列表、冷启、锁屏 file protection 和真实 session 数据仍待设备验收；下一项 `UI-001` |
| 2026-08-25 | UI-001 | 会话创建/切换路径不再取消其他 session 的 run；AppModel 新增由 `SessionRunRegistry.aggregate()` 驱动的 `sessionRunSnapshots`，非选中 live root 的运行/排队/终态投影进入会话列表；presentation callback 按 session 更新，terminal 后精确移除，前后台切换重新聚合；SessionStore 仍只负责 durable metadata。 | `SessionRunRegistryTests` 11/11；新增 AppModel A/B session 回归已纳入 Xcode `HarnessMobileTests` 编译；Xcode arm64 generic iOS Simulator `/tmp/hm-ui001-xcode2` `BUILD SUCCEEDED`；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `UI-001 VERIFY/CLOSED`（自动门）；iPhone 16 Pro 新建/切换/A-B 并行触控、VoiceOver、横屏仍待设备验收；下一项 `UI-002` |
| 2026-08-26 | 三方主进度 UI-002 | 将 conversation event/message/reasoning/tool/Markdown block 改为稳定非下标 ID；render/measure cache 精确绑定完整内容、宽度与 Dynamic Type 且有容量上限；消息保持完整原文，100 个 fallback tool calls 采用末尾 4 个 + 每页 20 个的渐进展示，streaming reasoning 不积累逐 delta 高度缓存；UI 测试会话入口改为点击真实会话按钮。 | `NativeMarkdownTextTests` 8/8；SwiftPM 全量 728 tests、3 skipped、0 failures；arm64 generic iOS Simulator `/tmp/hm-ui002-xcode` `BUILD SUCCEEDED`；iPhone 17 Pro Simulator iOS 27.0 长会话 UI test 1/1 PASS，最终结果包 `/tmp/hm-ui002-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_00-12-53-+0800.xcresult`。两次失败分别保留在 `Test-HarnessMobile-2026.08.25_23-54-39-+0800.xcresult`（误点文本未进聊天）与 `Test-HarnessMobile-2026.08.26_00-04-01-+0800.xcresult`（子按钮 identifier 被容器覆盖），修复后回归通过；Plugin Host、无远程执行审计、upstream lock/parity、`git diff --check` PASS。 | `UI-002 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro Instruments、Dynamic Type、旋转和 VoiceOver 仍待设备验收；下一项 `UI-003` |
| 2026-08-26 | 三方主进度 UI-003 | 将 OpenMinis 的空行/fence-aware 分页改造成 Harness 的 lossless 语义分段：50k UTF-8 字节起后台 O(n) 分段，完整保留原文字节，不切断 fence/table/quote；反引号/波浪号 fence 使用共享匹配 marker；segment ID 为 fingerprint + occurrence。首尾分段明确实例化，中间分段只在滚动可见时 detached 解析并由 `LazyVStack` 承载，复制仍直接使用 canonical `AgentMessage.content`。 | `NativeMarkdownTextTests` 13/13；50k/250k/1M 拼接和解析等价，1M crash gate 0.212s；SwiftPM 全量 733 tests、3 skipped、0 failures。iPhone 17 Pro Simulator iOS 27.0 百万字符尾部首屏、链接、引用、代码、表格和复制动作通过；Markdown UI 2/2，结果包 `/tmp/hm-ui003-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_08-31-44-+0800.xcresult`。失败回归保留：`08-01-03` 旧空会话、`08-18-36` 嵌套 lazy 尾段、`08-28-39` XXXL 套件状态隔离；Plugin Host、无远程执行审计、upstream lock/parity、`git diff --check` PASS。 | `UI-003 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro Instruments、跨分段完整拖选、VoiceOver、Dynamic Type、旋转仍待设备验收；下一项 `UI-004` |
| 2026-08-26 | 三方主进度 UI-004 | 首页、终端、聊天、设置执行 Accessibility XXXL、深色、横屏和关键控件 44pt 回归；补齐终端命令/聊天输入/反馈与工具详情等控件的可访问名称与最小触控尺寸，系统 toolbar 仅验证 AX 存在、命名和可点击，并以 DEBUG `-force-dark-mode-for-ui-testing` 稳定模拟器深色门。 | `HarnessMobileAccessibilityUITests` 4/4（iPhone 17 Pro Simulator，iOS 27.0，XXXL + 深色 + 横屏）；结果包 `/tmp/hm-ui004-xcode/Logs/Test/Test-HarnessMobile-2026.08.26_09-09-42-+0800.xcresult`，四页最终深色截图与 AX 树 `/tmp/hm-ui004-final-dark-0909/`；SwiftPM 全量 733 tests、3 skipped、0 failures；arm64 generic Simulator build、Plugin Host、无远程执行审计、upstream lock/parity、`git diff --check` 均 PASS。 | `UI-004 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro VoiceOver 手势、真实触控、完整旋转、Dynamic Type 和设备级性能仍待验收；下一项 `UI-005` |
| 2026-08-26 | MEMORY-001 | 新增本地 Cordis memory plugin：`memory_write` 只在明确调用时持久化，`memory/record` 仅记录观察；global/session scope、session disable、bounded recall/search、deterministic export、删除和 complete file protection 均在本机 JSON store 中完成。注入保留 durable lowercase `recordIds` provenance，Agent loop 未硬编码 memory 语义；设置页可管理、删除、禁用和导出。 | `MemoryStoreTests` 7/7；SwiftPM 全量 773 tests、3 skipped、0 failures；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-memory001-generic` `BUILD SUCCEEDED`；Plugin Host `npm run check`、`audit-no-remote-execution.sh`、`check-upstream-parity.sh` 与 `git diff --check` 均 PASS。 | `MEMORY-001 VERIFY/CLOSED`（自动/模拟器门）；仍须在 iPhone 16 Pro 验收重启后的持久化、禁用/删除/导出/recall 流程、VoiceOver、旋转和长会话，并以真实 provider 验证模型可见 recall；设备与 provider 证据前不能写成 `DONE`。 |
| 2026-08-26 | SHARE-001 | Share Extension 仅向受限 App Group 写 `ShareHandoffEnvelope`，按 staging→Inbox 原子 rename 发布；Inbox→Processing claim、force-close 恢复、TTL/数量/单项/总字节/队列上限和 consumed ledger 幂等均在 Core `ShareHandoffStore` 中实现。主 App 通过 `WorkspaceStore` deterministic manifest 原子接纳并复用既有图片/文件校验，随后才安装到当前 composer；不创建伪 session，不写 token/env/工具状态。 | `ShareHandoffTests` 5/5；SwiftPM 全量 782 tests、3 skipped、0 failures（首次运行有 1 个未复现失败，随后同命令重跑全绿）；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-share001-generic` build 通过且嵌入 `HarnessMobileShare.appex`，Share activation rule/主扩展 App Group 配置已由产物检查确认；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `SHARE-001 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro 的真实连续分享、force-close/冷启、系统 Share Sheet/Files/Photos、真实 provider、VoiceOver 和触控仍待验收；不能写成 `DONE`，下一项 `WIDGET-001`。 |
| 2026-08-26 | WIDGET-001 | 新增受限 `HarnessWidgetProjection`：主 App 从 `SessionRunRegistry` 原子写 App Group JSON 快照，仅包含 live session/run UUID、preparing/running/cancelling、排队数量、计数和 privacy flag；WidgetKit `StaticConfiguration` 只读读取，最多 32 个 session，privacy mode 不显示 rows。每行 Link 仅生成 `harnessmobile://session/<UUID>`，AppRootView 冷启动/ready/configured 后复用正常 session switch；完成/取消和删除会话刷新快照；Widget 不启动 Agent、不读 prompt/args/output。 | `WidgetProjectionTests` 3/3；SwiftPM 全量 785 tests、3 skipped、0 failures；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-widget001-generic` build 通过，WidgetKit extension point、主 App/Live Activity App Group 配置与 bundle registration 已由产物/源码检查确认；Plugin Host、无远程执行审计、upstream parity、`git diff --check` PASS。 | `WIDGET-001 VERIFY/CLOSED`（自动/模拟器门）；iPhone 16 Pro Widget 添加/刷新、隐私模式、完成/删除、deep link 冷启动、VoiceOver/触控和真实 provider 状态仍待验收；不能写成 `DONE`，下一项 `BROWSER-001`。 |
| 2026-08-27 | BROWSER-001 download/provenance | 在受限 Browser seam 上加入本机会话工作区下载：每个 session 以 SHA-256 派生 `Downloads/session-<digest>`；WebKit 对 `<a download>`、attachment 和不可显示 MIME 转为 `WKDownload`，64 MiB 上限，记录 started/completed/failed，并在 close、LRU discard、页面进程终止时取消活跃下载、删除 partial 文件。模型只收到文件名、状态、字节数和有界的工作区相对路径；响应 URL、headers、设备绝对路径不进入结果。tab descriptor、结果和 provenance 同时剥离 URL query/fragment，service 对回报下载目录、文件名、数量和大小 fail-closed。 | `HarnessBrowserServiceTests` 9/9（原隔离/LRU/输出/termination/provenance/schema 加上下载目录约束与 URL secret canary）；`WorkspaceStoreTests` 覆盖目录哈希、session canary 不泄漏与工作区 containment；SwiftPM 全量 801 tests、3 skipped、0 failures；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-browser001-generic` `BUILD SUCCEEDED`，已编译真实 WebKit download delegate 分支；Plugin Host、无远程执行审计和 upstream parity PASS。 | `BROWSER-001 PARTIAL/BLOCKED`；自动 service/编译门已补，但无 iPhone 16 Pro 对真实 attachment、未知长度/超限、取消、进程终止、Files 可见性和 secret-canary 下载路径的运行证据。不能写成完整 BrowserUse 或 DONE。 |
| 2026-08-27 | SYNC-001 canonical suffix admission | `HarnessSyncEnvelope` 的有界 immutable suffix 契约现接入 `SessionTrajectoryRepository`：从 durable canonical JSONL 导出，并只有 local durable `nextSequence == baseSequence + 1` 时，保留原始 seq/type/data 接纳事件。该路径不 LWW 覆盖、不重写已接纳历史；asset/tombstone 无独立复制/协调策略时 fail-closed。 | `HarnessSyncEnvelopeTests` 3/3；`SessionTrajectoryRepositoryTests` 15/15（精确 handoff、空 suffix、并发冲突保留 local history、asset/tombstone 拒绝且 log 不变）；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-sync001-generic` `BUILD SUCCEEDED`；边界审计、`plutil -lint` 与 `git diff --check` PASS。 | `SYNC-001 PARTIAL/BLOCKED`；仍缺跨设备 transport、并发分支 reconciliation、asset transfer/tombstone reconciliation 与 iPhone 16 Pro 证据，不能写成同步已完成。 |
| 2026-08-27 | RELEASE-001 capability manifest | 新增 `Docs/CAPABILITY_MANIFEST.json` 与 `Scripts/verify-capability-manifest.sh`，固定记录 `compiled/unit/simulator/device/entitlement/experimental/lastVerified`，并校验 production/catalog/UI/boundary surfaces、源文件/test/boundary 路径、AppModel/ProductionToolCatalog 的 SwiftPM exclude、Xcode Sources 和 `device-audit-inputs.xcfilelist` 覆盖；`Scripts/upgrade-check.sh` 已接入清单门。 | 清单验证 PASS；非法 capability ID 负例被拒绝；SwiftPM 全量、Xcode arm64 generic Simulator、Plugin Host、无远程执行审计、upstream parity 和 `git diff --check` 作为本轮收尾门。 | `RELEASE-001 VERIFY/CLOSED`；自动/模拟器覆盖已建立，但 iPhone 16 Pro、签名 entitlement 和长期现场证据仍缺，不能写成 `DONE`；下一项 `RELEASE-002`。 |
| 2026-08-28 | OBS-001 runtime invariant registry | 新增 typed `RuntimeInvariantRegistry`，覆盖一 session 一 root、model-visible durable 记录、background lease owner、terminal 无资源和 durable sequence contiguous；`AppModel.agentDiagnosticSnapshot` 每次读取 durable session events 后刷新 registry。默认 summary 只返回无正文 runtime summary、invariant counts 和脱敏 violation identity/code；error 详情、trace/session 内容仍须显式 scope，默认不含 prompt/body、URL query、cookie、API key、环境变量或命令正文。 | `SessionRunRegistryTests|BackgroundRunJournalTests` 16/16；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-obs001-xcode` `BUILD SUCCEEDED`；自动测试/编译门已闭合。 | `OBS-001 VERIFY/CLOSED`；真实 provider、iSH、插件、后台/长会话和 iPhone 16 Pro 诊断导出仍待验收，不能写成 `DONE`；下一项 `OBS-002`。 |
| 2026-08-28 | OBS-002 bounded runtime observability | 新增 `RuntimeTelemetryStore`：128 条/64 KiB 数值化 ring buffer、默认关闭的性能/资源采样、最小 launch marker、仅前台有效的 heartbeat watchdog、按完整 `RunIdentity` 和 timeout 来源去重的后台超时记录。MetricKit adapter 只接纳退出/卡顿 aggregate，绝不持久 raw payload/JSON/call stacks/prompt/tool args/output/URL/header/cookie/API key/env。显式“导出详细日志”会复用 `WorkspaceStore` 已有哈希会话 Downloads 目录，以固定 `Harness-Diagnostics-YYYYMMDD-HHMMSS.log` 文件名、2 MiB 上限和 containment 校验落盘；无 active session 时仍仅返回用户选择的文件导出。 | 聚焦 `RuntimeTelemetryTests|BackgroundPreferencesTests|HarnessTraceStoreTests` 20/20；SwiftPM 全量 811 tests、3 skipped、0 failures；`AgentRuntimeTests.testPinnedDeepSeekToolSchedulerDifferentialFixture` 单独复跑 1/1 通过；Xcode Beta arm64 generic iOS Simulator `/tmp/hm-obs002-xcode` build 退出码 0；Plugin Host `npm run check`、无远程执行审计、upstream parity、capability manifest、upgrade-check 与 `git diff --check` 全部 PASS。 | `OBS-002 VERIFY/CLOSED`；MetricKit 交付是系统延迟行为，且未在 iPhone 16 Pro 验收真实 MetricKit、前后台/系统 timeout、锁屏/低电量/热压力、长会话或会话 Downloads 导出；不能写成 `DONE`，下一项 `RELEASE-002`。 |
