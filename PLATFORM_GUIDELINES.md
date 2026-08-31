# Harness Mobile 平台规范

状态：受控文档
目标平台：iOS 18+，当前开发工具链 Xcode 27 Beta / Swift 6

## iOS 原则

- 使用系统导航、列表、Sheet、权限和文件/照片选择器；不仿制系统安全界面。
- App 可以长期保存状态，不能承诺长期占用 CPU、网络或后台执行。
- entitlement、设备能力、地区和系统版本是产品边界，不是待绕过的错误。
- 任何“支持”都区分编译、模拟器、真机安装和真实交互四层证据。

## 架构约束

- 主应用、Share Extension 和 Live Activity 通过受控 App Group 数据交接。
- 主 Agent、工具、存储和权限在 Swift 侧；Linux/Node 只在 iSH guest。
- 模型推理使用用户配置的 HTTPS API；无服务器执行回退。
- 不动态加载下载的 Swift、framework、native addon 或机器码。
- `project.yml` 是 Xcode 工程真源，工程文件变更必须能由其再生成。

## 后台

- Continued Processing、BGProcessing、有限 `beginBackgroundTask`、ActivityKit、通知、音频和定位都服从系统调度与到期回调。
- 音频/定位只用于用户明确启用且真实存在的产品场景，不作为伪 daemon。
- 到期先持久化准确 run identity 和 interrupted 原因，再取消或等待合法恢复机会。
- 系统可能不唤醒、延迟、限制或终止；UI 和文档必须表述为 best effort。
- 后台验证必须在目标 iPhone 上覆盖切屏、锁屏、到期、断网、低电量和热状态。

## 权限与系统控制器

- 延迟请求：仅在功能被真实触发时请求权限。
- Harness 授权不等于 iOS 授权；任一缺失都停止执行。
- 相机、照片、文件、Face ID、NFC、HealthKit 等保留系统可见流程。
- 权限用途字符串、entitlement、生产工具和设置状态必须一致。
- 不把“系统管理”“会话授权”“未接入”和“已拒绝”合并成同一状态。

## 设备与构建

- `HarnessISH.xcframework` 只支持 arm64；Simulator 构建指定 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`。
- 使用 `/Applications/Xcode-beta.app/Contents/Developer`，缓存放 `/tmp`。
- iPhone 安装需要有效 Development Team、证书、provisioning、Developer Mode、配对和解锁状态。
- 安装/启动成功只证明部署，不证明 API、UI、权限、后台或插件验收。

## UI 平台行为

- 支持项目声明的横竖屏；使用 safe area，固定浮层不得遮挡列表或键盘。
- 使用 Dynamic Type、语义颜色、系统材质和 Reduce Motion。
- 系统搜索、Picker、Toggle 和 Sheet 优先于自制控件。
- iPad 允许系统方向，但不能从 iPhone 截图推断 iPad 布局已验收。

## 平台能力分级

- 普通权限：相机、照片、位置、联系人等，按系统授权执行。
- 特殊 entitlement：HealthKit、NFC、Family Controls、Network Extension 等，只有签名和产品场景成立才接入。
- 配件/地区能力：CarPlay、MFi、Side Button 等保持目录状态，不伪装通用工具。
- 不适用能力：服务器 daemon、桌面 host process、任意动态原生代码，标记 `OUT-OF-SCOPE`。

具体能力见 [能力目录](CAPABILITY_CATALOG.md) 和 [移动能力矩阵](Docs/MOBILE_CAPABILITIES.md)。
