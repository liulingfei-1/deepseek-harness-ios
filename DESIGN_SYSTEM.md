# Harness Mobile 设计系统

状态：受控文档
实现源：[`HarnessListChrome.swift`](HarnessMobile/Features/Shared/HarnessListChrome.swift)
审计源：[UI 重设计审计](Docs/UI_REDESIGN_AUDIT_2026-08-30.md)

## 设计目标

界面优先回答三个问题：我在哪个项目、Agent 正在做什么、下一步能做什么。开发者诊断和高级配置按需展开，不与核心任务争夺首屏。

## 视觉令牌

只使用语义系统颜色，自动适配浅色、深色和高对比度：

| 类型 | 当前令牌 |
| --- | --- |
| 页面 | `HarnessTheme.pageBackground` |
| 主表面 | `HarnessTheme.surface` |
| 次表面 | `HarnessTheme.secondarySurface` |
| 弱填充 | `HarnessTheme.subtleFill` |
| 分隔线 | `HarnessTheme.separator` |
| 间距 | 4 / 8 / 12 / 16 / 20 / 24 pt |
| 圆角 | 8 / 12 / 18 / 22 pt |
| 列表最小行高 | 44 pt |

禁止为普通页面新增平行颜色、间距或卡片体系。需要新令牌时先证明现有语义令牌无法表达。

## 共享组件

- `harnessCompactListChrome()`：设置、工具、插件和管理列表的默认页面壳。
- `HarnessIconTile`：行级语义图标；不承载独立文字信息。
- `HarnessStatusPill`：短状态，不用于段落或长错误。
- `harnessCardSurface()`：少量需要独立层级的内容卡。
- `harnessFloatingSurface()`：输入栏等固定浮层；不得遮挡滚动内容。
- `harnessCardListRow()`：仅用于确有卡片层级的列表行。

优先使用 SwiftUI 原生 `List`、`Form`、`Section`、`NavigationStack`、`ContentUnavailableView`、`searchable`、`Picker`、`Toggle` 和系统 Sheet。

## 信息层级

1. 页面标题与当前项目/会话。
2. 当前任务和主要操作。
3. 状态、搜索与必要说明。
4. 高级参数、诊断、导入导出和危险操作。

同一个动作只出现一次。空状态必须给出唯一下一步；已有独立入口的功能不要在 Console、首页或其他页面重复。

## 文案

- 用户界面框架文案使用中文。
- 模型 ID、provider ID、Call ID、namespace、JSON、路径、协议和 API Key 等技术值保留原文。
- 标题说明任务，不写实现名；错误必须给原因和可执行下一步。
- 不用“成功”掩盖 `VERIFY`、降级或系统未授权状态。

## 状态模式

每个异步页面必须明确区分：加载、空、内容、失败、只读/不可用。危险操作使用系统确认；不可逆删除说明范围和不可恢复性。

## 无障碍与适配

- 交互目标至少 44×44 pt，图标按钮提供 label/hint。
- 支持 Dynamic Type，不固定正文高度，不依赖颜色单独表达状态。
- 紧凑宽度用 `ViewThatFits`、换行或纵向布局，不截断关键状态。
- VoiceOver 顺序遵循视觉顺序；组合行只合并真正属于同一语义的信息。
- 支持浅色、深色、横竖屏和项目声明的 iOS 18+ 设备。

## UI 变更门禁

1. 截取调整前真实页面，不凭代码猜布局。
2. 优先删除重复内容并复用共享组件。
3. 保留业务、权限、安全、错误和无障碍语义。
4. 增加或更新最小 UI 测试，保存调整后截图。
5. 在 [UI 审计](Docs/UI_REDESIGN_AUDIT_2026-08-30.md) 记录前后证据和真机边界。
