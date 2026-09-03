# Harness Mobile 决策记录

状态：受控、追加式
规则：已接受决策不静默改写；新证据改变结论时新增“取代”记录。

## 决策索引

| ID | 决策 | 状态 | 采用日期 |
| --- | --- | --- | --- |
| D-001 | 工具、插件和命令仅在设备或 iSH 执行 | Amended by D-011 | 2026-09-03 |
| D-002 | Swift 原生 Agent + iSH Node Host-half | Accepted | 2026-08-31 |
| D-003 | BYOK 凭据只保存在 Keychain | Accepted | 2026-08-31 |
| D-004 | 当前以会话标题表达项目名称 | Accepted | 2026-08-31 |
| D-005 | SwiftUI 原生控件与共享语义主题优先 | Accepted | 2026-08-31 |
| D-006 | `VERIFY` 与真机证据分离 | Accepted | 2026-08-31 |
| D-007 | `project.yml` 是 Xcode 工程真源 | Accepted | 2026-08-31 |
| D-008 | 不支持下载原生代码与 Browser Client-half | Superseded by D-010 | 2026-09-03 |
| D-009 | 12 份控制文档由 `AGENTS.md` 路由 | Accepted | 2026-08-31 |

## D-001 · 设备内执行边界

模型推理可访问用户配置的 HTTPS API；工具、插件和命令默认在设备或 iSH 执行。D-011 允许用户显式配置的远程执行后端（e2b 沙箱、webhook 出站、ACP 远端）。

## D-011 · 可配置远程执行后端（修改 D-001）

状态：Accepted
日期：2026-09-03
修改：D-001

背景：
桌面版通过 e2b 沙箱执行代码、接收 webhook、经 ACP 连接子 agent。iOS 技术上可做相同出站（HTTPS）；旧 D-001 把"本机执行"当安全模型一刀切，阻止了这些能力。平台可行性重审（Docs/PLATFORM_FEASIBILITY_REAUDIT_2026-09-03.md）确认这些是产品/隐私决策而非 iOS 限制。

决策：
本机执行是默认；用户可显式配置以下远程执行后端，配置后可用：
1. e2b 代码沙箱（创建/执行/读取远端沙箱代码运行）。
2. webhook 入站（本地 server 通过隧道暴露可配端点，事件转入任务队列）。
3. ACP/子 agent 远端（经协议连接用户配置的远端 agent）。
每条都要用户界面可见的启用状态与数据披露；未配置的通道不存在、不产生网络请求、工具不注册。凭据仅存 Keychain。

后果：
SECURITY_GUIDELINES 第 5 条与相关边界行更新（默认本机 + 显式远程后端）。e2b/webhook/ACP 从"边界外"转为"配置驱动后端"。

验证：
e2b 客户端接入框架在无 key 时不注册工具、配置 key 后沙箱创建/执行通过（模拟器网络）。webhook 本地 server 端点回环可达；隧道接入留真实配置验证。

## D-002 · Swift + iSH Host-half

安全敏感的 Agent loop、Provider、权限、存储和 UI 使用 Swift；需要 Node/Linux 语义的 Cordis Host-half 和命令运行于内嵌 iSH。避免在 JavaScriptCore 重新实现残缺 Node，也不把桌面 runtime 整体塞入 App。

## D-003 · BYOK 与 Keychain

API Key 使用设备专属 Keychain 引用，只有 Provider 请求路径在需要时解析。插件、iSH、会话、轨迹和导出不得持有凭据值。

## D-004 · 会话标题即当前项目名

现有持久化没有独立 Project 模型；首页复用 `ConversationSessionSummary.title` 作为项目名称，避免为了 UI 新建迁移和双重真源。若未来项目具有独立成员、文件根、权限或多会话生命周期，再用新 ADR 取代本决策。

## D-005 · 原生 UI 与共享主题

优先 SwiftUI 系统组件和 `HarnessTheme`；先删除重复内容，再考虑新增组件。这样保留 Dynamic Type、VoiceOver、系统交互和较小维护面。

## D-006 · 证据状态

模拟器、单元测试、签名构建、设备安装和真实交互是不同证据。没有需求指定的真机证据时状态保持 `VERIFY`，不得为了进度改成 `DONE`。

## D-007 · 工程生成

`project.yml` 是 XcodeGen 真源，生成的 `.xcodeproj` 同时提交以便直接打开。Target、权限、资源或构建脚本变化必须先在 `project.yml` 表达，并验证再生成结果。

## D-008 · 动态代码限制

允许验证后的原生清单和 iSH Host-half JavaScript；不支持 Browser Client-half、React slot、`.node` addon、下载的 Swift/framework 或机器码。无法安全适配时显示明确不兼容。

> **Superseded by D-010（2026-09-03）**：插件面改为桌面级对齐——host 运行时动态 define/run + 任意 Cordis/npm JS 包；native 清单降为可选后端；平台工具链限制报明确错误而非安全拒绝。

## D-009 · Harness 控制文档

`AGENTS.md` 是控制入口；PRD、设计、流程、前后端、安全、能力、技术、质量、平台、实施和决策文档按变更类型加载。详细事实保留在源码、测试和已有 `Docs/` 真源，控制文档不复制长清单。

## D-010 · 桌面级插件对齐（取代 D-008）

状态：Accepted
日期：2026-09-03
取代：D-008

背景：
D-008 以移动端自设安全模型限制插件面（只走 native 清单或 iSH Host-half JS）。桌面版通过本地 host 运行时（cordis-host-runner + tool-cordis）让模型动态 define/run/update/stop/undefine Cordis 包并加载任意 npm 生态依赖。设备上 host.mjs 已 import 上游全栈，通路存在，差异只在默认路径与工具面仍被旧模型主导。

决策：
插件面完全对齐桌面：模型可见并可用 `cordis_inspect_list/query/self/define/run/stop/undefine` 7 工具；市场与模型安装默认走本地 host 运行时装载，不再「先 native 编译」；允许加载任意 Cordis/npm JS 生态包。native 声明式清单保留为可选后端，非默认非前置。执行只在设备本地，不引入远程 executor（D-001 不变）。

平台工具链限制（非安全模型）：Browser/React client-half 因无浏览器容器不装载；`.node` 原生 addon、下载的 Swift/framework 二进制受 iOS/iSH 工具链限制；均报明确平台限制错误。

后果：
AGENTS.md、SECURITY_GUIDELINES.md 相应条款按本文档修订（见 `Docs/DESKTOP_FULL_PARITY_2026-09-03.md` §1）。默认路径改变影响市场安装 UI 与安装协调器行为。native 编译相关代码保留可选、逐步退出默认路由。

验证：
P1：模拟器 iSH host 运行，模型工具目录出现 7 工具，`cordis_inspect_list` 真实返回注册表。
P2：市场安装走 host 装载；真实插件 define→run→stop 全链路通过。
P3：带 npm 依赖的真实 cordis 插件安装成功。


## 新决策模板

```md
## D-XXX · 标题

状态：Proposed / Accepted / Superseded
日期：YYYY-MM-DD
取代/被取代：可选

背景：
决策：
后果：
验证：
```
