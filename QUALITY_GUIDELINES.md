# Harness Mobile 质量规范

状态：受控文档
协作流程：[AI Engineering Playbook](Docs/AI_ENGINEERING_PLAYBOOK.md)

## 质量原则

- 从真实失败和生产路径出发，不以 mock 成功替代行为。
- 修根因和共享入口，不在每个调用者复制补丁。
- 每批改动单一、可回滚；重构、协议变化和 UI 重设计分开。
- 自动化证明其覆盖的范围，真机证明平台行为；两者不能互相冒充。

## 状态门

| 状态 | 最低证据 |
| --- | --- |
| TODO | 明确缺口、目标路径和验收 |
| PARTIAL | 已实现子集与未覆盖操作清楚列出 |
| VERIFY | 生产代码存在，至少有窄测试；缺少的设备/契约证据明确 |
| DONE | 需求规定的代码、测试、构建、边界审计和设备验收全部通过 |
| IOS-REPLACEMENT | 原生替代行为、差异和验收均有证据 |
| OUT-OF-SCOPE | 与 PRD/平台/安全边界冲突且理由记录 |

## 测试层级

1. 纯模型/解析/状态机：SwiftPM 单元测试。
2. AppModel、权限、目录和持久化集成：iOS XCTest。
3. 页面路由、布局和交互：XCUITest + 截图/可访问性树。
4. Plugin Host：`npm run check` + Node smoke + Swift bridge tests。
5. API、图片、文件选择、iSH、权限、插件、后台和长会话：目标 iPhone 验收。

非平凡分支或修复必须留下一个最小回归检查。不要为一行样式或文案创建无价值测试。

## 标准命令

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --build-path /tmp/hm-build

(cd HarnessMobile/Resources/PluginHost && npm run check)
node HarnessMobileTests/ISHPluginHostNodeSmoke.mjs HarnessMobile/Resources/PluginHost
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
./Scripts/verify-capability-manifest.sh
git diff --check
```

先运行受影响的窄测试；跨模块、共享协议或收尾版本再运行完整套件。Xcode 构建命令遵循 [技术栈](TECH_STACK.md)。

## 失败处理

- 记录原始命令、错误文本、环境和结果包路径。
- 先区分代码失败、测试假设错误、模拟器/Xcode 故障和设备离线。
- 不放宽断言、吞异常、增加盲目重试或改 mock 来制造绿色。
- 进程仍在时轮询同一 handle；观察超时不等于任务失败。
- 固定抖动必须有可复现证据和根因记录，不能在总数中隐藏。

## UI 质量

- 先截调整前页面，再按 [设计系统](DESIGN_SYSTEM.md) 做最小改造。
- 覆盖内容、空、加载、失败、只读和危险操作。
- 检查浅/深色、Dynamic Type、横屏、VoiceOver、键盘和 44pt 目标。
- UI 测试必须从真实入口到达，不用直接注入页面替代导航，除非夹具目的已说明。

## 文档质量

- 文档只记录已从源码、测试或设备确认的事实。
- 详细状态只维护一个真源，其他文档链接过去。
- 代码变更同步 `Docs/DESKTOP_PARITY_REMEDIATION.md`；产品/能力/决策变化同步对应控制文档。
- Markdown 链接、命令、文件名和状态在提交前检查。

## Definition of Done

需求、生产路径、测试、构建、边界审计、文档和指定设备证据全部成立；工作树中没有意外文件，`git diff --check` 通过，剩余限制没有被写成完成。
