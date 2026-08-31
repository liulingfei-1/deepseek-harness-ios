# Harness Mobile 安全规范

状态：受控文档
报告策略：[SECURITY.md](SECURITY.md)
实现边界：[架构文档](Docs/ARCHITECTURE.md)

## 受保护资产

- 模型 API Key、Authorization header 和 provider 凭据。
- 私人会话、工作区文件、附件、位置、联系人、健康和媒体数据。
- 工具授权、插件来源、签名配置和设备身份。
- 轨迹、诊断、导出和后台 journal 中的派生数据。

## 信任边界

| 边界 | 信任策略 |
| --- | --- |
| Swift App | 承载安全敏感真源；仍需输入验证和最小权限 |
| 模型 API | 外部数据处理方；只发送当前请求所需内容 |
| iSH guest | 本机但不受信任；不得接收 provider 凭据 |
| 插件源码/Host | 不受信任；校验来源、归档、清单、方法和结果 |
| iOS 系统服务 | 由系统权限和可见控制器约束 |
| 导入文件/URL/ZIP | 不受信任；限制大小、类型、路径和重定向 |

## 不可破坏的安全约束

1. API Key 使用 `WhenUnlockedThisDeviceOnly` Keychain，不写入源码、日志、会话、插件或导出。
2. Provider 地址要求 HTTPS，拒绝 user info、query/fragment 异常和跨源凭据重定向。
3. 工作区路径必须相对、规范化、位于 sandbox 内，并防止 symlink/archive traversal。
4. 模型只能调用生产工具目录或验证后的动态贡献；未知工具失败关闭。
5. iSH/插件不得启动 host 或远程 executor，也不得加载下载的 Swift、framework、native addon 或机器码。
6. Harness 授权与 iOS 权限独立；任一拒绝都必须阻止操作。
7. 危险操作使用精确资源范围，不能用设备级通配授权替代确认。
8. 轨迹、设置、JSON-RPC 和导出在持久化/传输前做大小限制与凭据脱敏。

## 插件与供应链

- 先检查 `Vendor/`、`Dependencies/`、锁文件、来源摘要和许可证。
- ZIP 拒绝绝对路径、目录逃逸、循环/缺失 symlink 和不允许的 payload。
- npm lifecycle scripts 禁用；依赖版本由 `package-lock.json` 固定。
- generation 激活失败必须撤回部分贡献并回滚，不保留幽灵工具。
- Settings 写入需要 `expectedRevision`，secret path 和无法无损表达的 schema 失败关闭。

## 隐私与权限

- 只在用户或 Agent 首次真实使用能力时请求系统权限，不在启动时集中弹窗。
- 相机、照片、文件、NFC、认证等系统介面保持可见，不能静默模拟。
- 发送模型前在审批/轨迹中明确资源范围和目标 host。
- 不用定位、音频、蓝牙或通知伪造永久后台执行。

## 日志与导出

- 日志只记录必要的 ID、状态、大小、耗时和脱敏错误。
- 不记录 Authorization、Keychain 值、完整私人文件或未脱敏工具参数。
- 诊断和导出必须复用现有 redaction；失败时不删除原始本地数据。
- 测试 fixture 使用假的、明显不可用的凭据和域名。

## 安全验收

涉及网络、凭据、路径、插件、权限、导出或远程执行边界时至少运行：

```sh
./Scripts/audit-no-remote-execution.sh
./Scripts/check-upstream-parity.sh
git diff --check
```

并执行该模块的窄测试。真实权限、iSH、插件和敏感数据路径必须保留真机证据；模拟器不能关闭对应 `VERIFY`。
