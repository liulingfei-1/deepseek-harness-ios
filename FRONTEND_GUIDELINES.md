# Harness Mobile 前端规范

状态：受控文档
适用范围：`HarnessMobile/App/`、`HarnessMobile/Features/`、Live Activity 与 Share UI

## 技术边界

- 使用 SwiftUI 和系统容器；UIKit 仅用于 SwiftUI 尚未覆盖的系统能力或既有桥接。
- `AppModel` 是 `@MainActor` 组合根；View 不直接拥有网络、Keychain、持久化或插件生命周期。
- 长任务通过 async 状态投影到 UI；View 不阻塞主线程，不用定时轮询替代真实状态。
- 修改 `HarnessMobile/App/` 前先读该目录的 `AGENTS.md`。

## 页面结构

- 根流程使用 `NavigationStack`；深层页面走现有 route、sheet 或 navigation destination。
- 首页只承载项目选择、新建以及工具/设置入口。
- 设置和管理页使用 `List`/`Form` + `harnessCompactListChrome()`。
- Sheet 必须有清晰的取消/完成出口；危险操作使用系统确认。
- 搜索只在存在可搜索内容时出现，且不得遮挡主要行或底部动作。

## 组件复用

先查 [`HarnessListChrome.swift`](HarnessMobile/Features/Shared/HarnessListChrome.swift) 和同类页面。不得为单页创建平行 Theme、Card、Badge、Icon 或 Navigation 抽象。

优先级：删除重复内容 → 复用现有组件 → SwiftUI 原生控件 → 最小局部 View。

## 状态与数据

- View 只保留草稿、选择、展开、焦点和展示状态。
- 持久状态由 model/store/runtime 拥有；不要在 View 复制一份长期真源。
- `task(id:)` 和 `onChange` 必须可取消且防止旧结果覆盖新选择。
- 流式消息、长日志和轨迹使用现有窗口化/分页机制，不一次渲染全部历史。

## 交互与文案

- 一个页面只保留一个主要动作；同一能力不在多个同级位置重复。
- 首屏呈现用户对象和任务，不呈现内部统计或实现术语。
- 用户可见框架文案用中文；技术标识保持真实原文。
- 空状态解释为什么为空并给出下一步；加载、失败、只读和权限受限不得共用同一文案。
- 控件禁用时仍要让用户理解原因，不能仅变灰。

## 无障碍

- 最小点击目标 44 pt；纯图标按钮必须有 `accessibilityLabel`，必要时有 hint/value。
- 行状态不能仅依赖颜色；选中、运行、错误、只读要有文字或符号。
- 支持 Dynamic Type、VoiceOver、Reduce Motion、浅/深色和横屏。
- 测试标识描述语义，不依赖屏幕坐标或易变的层级索引。

## 性能

- 避免在 `body` 中进行 JSON 解析、文件 IO、网络或大集合排序。
- 昂贵投影在 actor/model 层计算并缓存；视图使用稳定 identity。
- 不为可能的性能问题预建缓存或架构；先用现有 telemetry、Instruments 或可复现用例证明。

## 最小验收

1. 目标页面能从真实入口到达。
2. 核心状态和主要动作有 UI 测试。
3. 保存调整前后截图；至少检查当前目标设备尺寸。
4. 编译通过，`git diff --check` 通过。
5. 深色、大字、横屏、VoiceOver 或真机未验证时明确保留 `VERIFY`。
