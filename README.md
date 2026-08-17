# Harness Mobile

Harness Mobile 是一个原生 SwiftUI iOS 应用，按 DeepSeek Harness 的 Agent Loop、消息和工具调用语义实现手机端版本。

它采用明确的混合边界：

- 模型推理通过用户配置的 HTTPS API 和 API Key 完成；App 不内置或下载模型权重。
- Agent Loop、工具调度、审批、文件、OCR、iSH 命令和会话持久化都在 iPhone 内执行。
- 不包含 Remote Executor、MCP、通用 HTTP 工具、宿主进程执行或服务器工具；动态脚本只允许在手机内 iSH guest 的 Cordis Host-half 沙箱中运行，不动态链接下载的 Swift/原生机器码。

## 当前能力

- DeepSeek/OpenAI-compatible `chat/completions` 流式 SSE。
- DeepSeek thinking、`reasoning_content` 工具轮回放和交错 tool-call delta 聚合。
- 多模型服务商配置、API 连通性测试、自动模型发现和缓存目录迁移。
- API Key 存入本机 Keychain；模型连接配置与 Key 分开保存。
- 编译期原生工具目录：设备时间、本地工作区列表/读/写、相机或照片 OCR、真实定位/运动、本地通知和设备认证。
- 内嵌 OpenMinis/iSH ARM64 Alpine；`shell_execute`、超时、取消、stdout/stderr 和默认断网均在 App 进程内完成。
- iSH 内安装最小 Node.js/Cordis Host，Cordis npm 依赖按锁文件固定；支持 Host-half JavaScript 插件、官方 Cordis Inspect/Define/Run/Stop 工具，以及动态 Tool/Prompt 和可调用的 handler/service 目录。
- 插件设置复用官方 `dsh-settings`/`dsh-settings-file`，保存在手机 iSH 工作区并支持监听热更新；原生表单保留 defaults/base/user/revision、草稿、重置、保存、冲突重放和密钥脱敏语义。
- 原生 Cordis Runtime 支持服务依赖、隔离标签、Fiber 代次、热启停、失败清理和替换失败回滚；Agent Loop 暴露 Memory、Orchestration、Sandbox、LLM 和 Tool checkpoint，只有固定白名单内的动态 handler/service 会自动接入这些边界。
- checkpoint 轨迹记录 run、turn、step 和精确插件代次/处理链；结构化输入输出会先限长，并脱敏 API Key、Authorization、Bearer 与 `sk-...` 等凭据内容。
- 敏感读取和写入逐次确认，并明确提示工具结果会发往哪个模型域名。
- 本地会话恢复、工具大小/轮次上限、取消与路径逃逸防护。
- iOS 26 Continued Processing、实时活动、完成通知和中断后继续入口；后台资源压力下会主动降低命令并发和模拟器占用。
- 构建时静态审计，阻止网络能力越过模型 provider 边界。

## 使用 Xcode beta

直接打开 `HarnessMobile.xcodeproj`，选择 iPhone 模拟器或已连接设备运行。首次启动需要输入：

1. API Base URL，例如 `https://api.deepseek.com`；
2. API Key；
3. 模型名称；
4. 思考模式。非 DeepSeek 兼容服务建议选择“服务默认”。

命令行构建示例：

```sh
DEVELOPER_DIR=/Users/liulingfei/Downloads/Xcode-beta.app/Contents/Developer \
  xcodebuild -project HarnessMobile.xcodeproj \
  -scheme HarnessMobile \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

运行本地执行边界审计：

```sh
./Scripts/audit-no-remote-execution.sh
```

`project.yml` 是 XcodeGen 的工程真源；仓库同时保留生成后的 `.xcodeproj`，因此使用者无需安装 XcodeGen。

## 安全与产品限制

- BYOK 密钥保存在 Keychain，但移动客户端无法达到自有后端隐藏服务端密钥的隔离强度。建议使用独立、限额、可撤销的 Key。
- 文件或 OCR 文字只有在本地工具获批并执行后，才作为工具结果发给模型 API；图片字节本身不上传。
- iOS 不能直接启动桌面式宿主子进程；本项目使用内嵌 iSH Linux guest 提供本机 `/bin/sh`，不会通过远程服务器模拟命令执行。
- Cordis Host-half 插件已经可用；社区插件市场支持 awesome-dsh-plugin 目录、GitHub 仓库/子目录和本地 ZIP，并提供安装、默认禁用、启停、更新、卸载及缓存清理。安装在 iSH 内使用锁定依赖、禁用 npm lifecycle script，并在替换失败时回滚；Browser Client-half、原生二进制扩展和下载的 Swift/native code 仍会拒绝。模型动态定义的 Package、handler、service 和活动 Fiber 只保存在 Host 进程内，停止或重启 Host 后需要重新定义。
- 当前不宣称覆盖 DeepSeek Harness 的 subagent、LSP、桌面持久交互式 PTY 或 workflow/worker 全部功能。
- Continued Processing 和实时活动都受 iOS 调度、过期与终止规则约束，不承诺永久常驻或精确定时；项目不使用假定位、静音音频、VoIP 或蓝牙冒充后台业务。

架构与威胁边界见 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)，开源来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
