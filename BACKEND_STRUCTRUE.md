# Harness Mobile 后端结构

状态：受控文档
说明：文件名按项目约定保留 `BACKEND_STRUCTRUE.md`；本项目没有自建远程执行后端。

## 定义

这里的“后端”指 iPhone 上的业务、运行时、存储和沙箱层。唯一允许离开设备的主业务请求是用户配置的模型 HTTPS API，以及用户明确调用的网络信息工具；工具执行本身不转发到项目服务器。

## 运行结构

```text
SwiftUI
  → AppModel (@MainActor，组合与 UI 投影)
    → AgentRuntime (actor，回合/工具循环/取消/压缩)
      → Provider adapters → 用户模型 HTTPS API
      → LocalToolRegistry → 原生 iOS 工具
      → CordisPluginRuntime → 受控原生贡献
      → HarnessISH → 本机 Alpine / Node Cordis Host
    → Workspace / Session / Trace stores
    → Background coordinators / ActivityKit / notifications
```

完整说明见 [架构文档](Docs/ARCHITECTURE.md)。

## 模块所有权

| 层 | 路径 | 只负责 |
| --- | --- | --- |
| 组合根 | `HarnessMobile/App/` | 生命周期、路由、UI 状态投影、依赖装配 |
| Agent | `Core/Agent/` | 有序回合、上下文、工具循环、取消、压缩 |
| 网络 | `Core/Network/` | Provider wire、SSE、请求限制、重试和同源策略 |
| 配置/凭据 | `Core/Configuration/`、`Core/Security/` | Provider/Profile、迁移、Keychain 引用 |
| 工具 | `Core/Tools/` | 编译目录、资源范围、原生/iSH 工具适配 |
| 插件 | `Core/Plugins/` | 清单、generation、Cordis、Host bridge、设置 |
| 存储 | `Core/Storage/`、`Core/Trace/` | 工作区、会话、轨迹、spill、导出与脱敏 |
| 后台 | `Core/Background/` | iOS 后台窗口、journal、恢复、通知和 Live Activity |
| Guest Host | `Resources/PluginHost/` | iSH 内 Node/Cordis Host-half 生命周期 |

## 数据真源

- 配置：`SettingsStore` 与 Provider/Profile 模型；API Key 只在 Keychain。
- 会话：`SessionStore`/`WorkspaceStore`；消息完成后才持久提交。
- 工作区：App-private 根目录，路径规范化并检查 symlink escape。
- 轨迹：append-only Session/Harness trace，存储前限制大小并脱敏。
- 插件设置：iSH 内官方 file-backed Settings；Swift 只接收脱敏描述并用 revision 写入。
- 后台恢复：`BackgroundRunJournal` 与精确 `RunIdentity`，不是 UI 状态副本。

## 并发规则

- UI 状态只在 `@MainActor` 更新。
- Agent、Store、Host transport 等共享可变状态使用现有 actor/串行边界。
- 旧 run、旧请求和旧插件 generation 的回调不能更新当前对象。
- 取消是正式结果；不得吞掉 `CancellationError` 后写成成功。
- 不用全局锁、无界 Task 或后台轮询替代清晰所有权。

## 网络与执行边界

- Provider endpoint 必须是受验证的 HTTPS；redirect 只允许同源规则。
- API Key 不进入 iSH、插件、Prompt、轨迹、UserDefaults 或导出。
- Linux 命令只经固定 HarnessISH 边界启动 guest 进程。
- 动态插件只能是验证后的原生清单或 iSH Host-half JavaScript。
- 不增加 Remote Executor、服务器 scheduler 或下载原生代码执行。

## 修改门禁

修改一个层前先定位所有调用者和最近 `AGENTS.md`，保持单一所有权；跨层变更必须说明数据真源、取消语义、持久化顺序、安全边界和最小回归测试。
