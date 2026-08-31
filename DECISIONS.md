# Harness Mobile 决策记录

状态：受控、追加式
规则：已接受决策不静默改写；新证据改变结论时新增“取代”记录。

## 决策索引

| ID | 决策 | 状态 | 采用日期 |
| --- | --- | --- | --- |
| D-001 | 工具、插件和命令仅在设备或 iSH 执行 | Accepted | 2026-08-31 |
| D-002 | Swift 原生 Agent + iSH Node Host-half | Accepted | 2026-08-31 |
| D-003 | BYOK 凭据只保存在 Keychain | Accepted | 2026-08-31 |
| D-004 | 当前以会话标题表达项目名称 | Accepted | 2026-08-31 |
| D-005 | SwiftUI 原生控件与共享语义主题优先 | Accepted | 2026-08-31 |
| D-006 | `VERIFY` 与真机证据分离 | Accepted | 2026-08-31 |
| D-007 | `project.yml` 是 Xcode 工程真源 | Accepted | 2026-08-31 |
| D-008 | 不支持下载原生代码与 Browser Client-half | Accepted | 2026-08-31 |
| D-009 | 12 份控制文档由 `AGENTS.md` 路由 | Accepted | 2026-08-31 |

## D-001 · 设备内执行边界

模型推理可访问用户配置的 HTTPS API；工具、插件和命令不得转发到远程 executor 或项目服务器。这样保持用户可审计的数据与执行边界，代价是受 iOS sandbox、资源和后台额度限制。

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

## D-009 · Harness 控制文档

`AGENTS.md` 是控制入口；PRD、设计、流程、前后端、安全、能力、技术、质量、平台、实施和决策文档按变更类型加载。详细事实保留在源码、测试和已有 `Docs/` 真源，控制文档不复制长清单。

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
