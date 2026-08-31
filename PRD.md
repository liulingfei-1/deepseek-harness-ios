# Harness Mobile 产品需求

状态：受控文档
适用范围：`HarnessMobile` iOS 应用、扩展、iSH Host 与配套工具
事实源：[README](README.md)、[架构](Docs/ARCHITECTURE.md)、[能力矩阵](Docs/MOBILE_CAPABILITIES.md)、[桌面对齐](Docs/DESKTOP_PARITY.md)

## 产品定义

Harness Mobile 是原生 iPhone Agent 客户端。用户通过自己配置的模型 API 完成推理；Agent loop、会话、工作区、工具、插件和命令在手机进程或内嵌 iSH 沙箱执行。

产品不是网页壳、远程终端或服务器执行代理，也不承诺绕过 iOS 权限、后台额度和前台交互限制。

## 目标用户与核心任务

- 需要在 iPhone 上持续完成真实文件、设备能力和命令任务的个人开发者。
- 需要自带 API Key，并能明确控制模型服务商、权限、数据和插件来源的高级用户。
- 需要查看 Agent 计划、工具调用、轨迹、失败证据与恢复状态的审慎用户。

核心任务按优先级排序：

1. 从首页选择或新建项目，并继续本地会话。
2. 与模型对话，审查计划，批准本机工具和处理用户选择。
3. 管理工作区文件、iSH 命令、任务状态和轨迹。
4. 管理服务商、权限、后台行为和插件。
5. 在失败、切屏或系统中断后保留证据并安全恢复。

## 产品原则

- 项目优先：首页主内容是项目名称；运行诊断、权限和工具属于二级入口。
- 本机行动：除用户选择的模型推理 API 外，不增加远程执行回退。
- 明确授权：Harness 授权不能绕过 iOS 系统权限或系统控制器。
- 可观察：模型回合、工具、插件链、后台状态和错误必须有本地证据。
- 诚实降级：平台不支持或尚未真机验证时显示原因，不伪装成功。
- 原生优先：优先 Swift/iOS 能力，其次是受控 iSH Host-half；不加载下载的原生代码。

## 必须能力

| ID | 需求 | 验收依据 |
| --- | --- | --- |
| PRD-001 | 首次启动配置服务商、API Key、模型和安全边界 | Setup UI 测试与 Keychain 测试 |
| PRD-002 | 首页以项目名称为主，支持搜索、新建、归档和会话进入 | Sessions UI 测试与截图 |
| PRD-003 | 对话支持流式输出、工具循环、取消、恢复、附件和会话模型覆盖 | Agent/Network 测试与真机 API |
| PRD-004 | 本机工具受编译目录、用户授权、iOS 权限和资源范围约束 | ProductionToolCatalog 测试与权限测试 |
| PRD-005 | 工作区路径限制在 App 容器，支持导入、读写、搜索和导出 | Storage/Workspace 测试与真机文件选择 |
| PRD-006 | Linux 命令和 Host-half 插件只在内嵌 iSH guest 执行 | Host smoke、边界审计与真机 iSH |
| PRD-007 | 轨迹记录 run/turn/step、工具、插件链、耗时和脱敏摘要 | Trace 测试与 Inspector UI |
| PRD-008 | 后台工作遵守 iOS 额度，支持可恢复状态、Live Activity 和通知 | Background 测试与真机切屏 |
| PRD-009 | 凭据只在 Keychain；日志、轨迹和导出不得泄漏密钥 | Security/Redaction 测试与审计脚本 |
| PRD-010 | 所有主要路径满足浅色/深色、大字、横屏、VoiceOver 和 44pt 触控基线 | UI 测试矩阵与真机截图 |

## 明确不做

- Remote Executor、E2B、服务器工具执行或服务器调度回退。
- 本地模型权重、模型镜像下载或后台常驻 daemon。
- 任意 Web/React Client slot、下载的 Swift/framework、`.node` addon 或机器码。
- 绕过系统权限、后台时限、NFC/认证/文件选择等可见系统交互。
- 用模拟器、mock 或安装成功替代真实 API、iSH、后台和真机交互验收。

## 成功标准

- 用户可在目标 iPhone 上完成“项目 → 对话 → 本机工具/文件 → 轨迹 → 恢复”的闭环。
- API Key、私密文件和工具原始敏感参数不进入不受信任边界。
- 每个能力都有生产路径、状态、最小自动化证据和明确的真机剩余项。
- 当前差距以 [实施计划](IMPLEMENTATION_PLAN.md) 和 [修补日志](Docs/DESKTOP_PARITY_REMEDIATION.md) 为准。

## 变更控制

改动产品范围时必须同步：本文件、[能力目录](CAPABILITY_CATALOG.md)、[决策记录](DECISIONS.md) 和相应验收。仅实现细节变化不应重写产品目标。
