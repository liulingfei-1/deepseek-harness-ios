# Harness Mobile 能力目录

状态：受控文档
可执行真源：[`ProductionToolCatalog.swift`](HarnessMobile/Core/Tools/ProductionToolCatalog.swift)
机器清单：[`Docs/CAPABILITY_MANIFEST.json`](Docs/CAPABILITY_MANIFEST.json)
平台明细：[移动能力矩阵](Docs/MOBILE_CAPABILITIES.md)

## 状态定义

- `TODO`：没有生产实现。
- `PARTIAL`：只有部分操作或边界成立。
- `VERIFY`：实现存在，但自动化、真实 API、真机或上游契约未全部通过。
- `DONE`：代码、测试和指定设备验收全部成立。
- `IOS-REPLACEMENT`：采用边界诚实的 iOS 原生替代。
- `OUT-OF-SCOPE`：违反产品边界或没有稳定的 iOS 等价能力。

## 产品能力总览

| 领域 | 当前生产能力 | 控制状态 | 事实源 |
| --- | --- | --- | --- |
| App Shell | Setup、项目首页、对话、工具、设置和深链 | VERIFY | `AppRootView.swift`、机器清单 |
| Provider | DeepSeek、OpenAI-compatible、Anthropic、SSE、模型发现、重试 | VERIFY | `Core/Network/`、Provider tests |
| Agent loop | 多轮工具、取消、压缩、计划、用户选择、会话/子 Agent | VERIFY | `AgentRuntime.swift`、Agent tests |
| 工作区 | 私有文件、导入、读写、搜索、编辑、导出和引用 | VERIFY | `Core/Storage/`、Workspace tests |
| 原生工具 | OCR、位置、运动、通知、认证、通讯录、日历、语音等 | PARTIAL | 移动能力矩阵、生产工具目录 |
| iSH | Alpine guest、shell、文件、网络开关、Host Node | VERIFY | `Core/Tools/ISH/`、Host smoke、真机证据 |
| 插件 | 原生清单、Cordis Host-half、市场、设置、生命周期与回滚 | VERIFY | `Core/Plugins/`、Plugin tests |
| 轨迹/诊断 | run/turn/step、工具、插件链、使用量、脱敏导出 | VERIFY | `Core/Trace/`、Trace tests |
| 后台 | Continued Processing、有限 lease、journal、Live Activity、通知 | VERIFY | `Core/Background/`、真机切屏验收 |
| 浏览器 | 本机 WebKit tab、读取、点击和下载边界 | PARTIAL | 机器清单、Browser tests |
| Sync contract | 本地 envelope 与轨迹持久化契约 | PARTIAL | 机器清单、Sync tests |
| Share/App Intents | 分享扩展、Shortcuts、Widget/深链进入会话 | VERIFY | Extension/App Intent tests |

本表不取代具体工具清单；工具名、schema、权限模式和生产注册以 `ProductionToolCatalog.swift` 的实际编译结果为准。

## 原生能力分组

- 已有 typed provider：相机/OCR、照片选择、定位/地图、运动、通知、认证、语音、联系人、日历、提醒、剪贴板、媒体、设备状态、自然语言和系统 URL。
- 受设备/权限约束：HealthKit、蓝牙、照片图库写入、本地网络和后台定位。
- 未接入或平台受限：HomeKit、NFC、Family Controls、Network Extension、CarPlay、External Accessory、SensorKit 等。

详细操作级状态只在 [移动能力矩阵](Docs/MOBILE_CAPABILITIES.md) 维护，避免两份表漂移。

## 明确禁止的能力

- 远程 shell、Remote Executor、服务器工具回退或服务器 scheduler。
- 下载并执行 Swift/framework、native addon 或机器码。
- 无审批的任意工具注册、凭据访问或跨 sandbox 文件访问。
- 假后台常驻、静默系统权限或不透明数据上传。

## 新增能力合同

新增或扩大能力时必须同时给出：

1. 用户任务与 PRD 对应项。
2. 生产注册路径和唯一数据真源。
3. Harness 授权、iOS 权限、资源范围和模型数据出口。
4. 输入/输出大小、取消、超时、错误和脱敏规则。
5. 最小单元/集成测试，以及需要的模拟器/真机验收。
6. 本目录、机器清单或移动矩阵的状态更新。
