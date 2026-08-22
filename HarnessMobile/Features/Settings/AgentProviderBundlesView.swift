import SwiftUI

struct AgentProviderBundlesView: View {
    @Environment(AppModel.self) private var model
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(model.providerBundles) { bundle in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: binding(for: bundle)) {
                            Label(bundle.displayName, systemImage: bundle.id == .codex ? "terminal" : "text.bubble")
                        }
                        Text(bundle.enabled ? "已启用；调用只会使用手机 iSH 中的固定入口。" : "未启用")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        installStatus(for: bundle)
                        installActions(for: bundle)
                        Text("固定来源：\(bundle.installPayload.packageName)@\(bundle.installPayload.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("RC.8 Profile Bundles")
            } footer: {
                Text("安装在手机 iSH 内完成：URL、SHA-256、npm 包身份、CLI 名称和命令均来自不可编辑的内置清单。下载会校验后原子替换；失败或取消会保留旧版本。安装器不会读取模型服务 API Key。")
            }
        }
        .navigationTitle("Agent 编排")
        .alert("Bundle 设置失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await model.refreshProviderBundleInstallStatuses()
        }
    }

    @ViewBuilder
    private func installStatus(for bundle: AgentProviderBundle) -> some View {
        let status = model.providerBundleInstallStatus(bundle.id)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if status.phase.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.phase == .installed ? "checkmark.seal.fill" : "shippingbox")
                    .foregroundStyle(status.phase == .installed ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.message)
                    .font(.caption)
                if let version = status.installedVersion {
                    Text("已验证版本 \(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func installActions(for bundle: AgentProviderBundle) -> some View {
        let status = model.providerBundleInstallStatus(bundle.id)
        HStack(spacing: 12) {
            if status.phase.isActive {
                Button("取消") {
                    model.cancelProviderBundleInstall(bundle.id)
                }
                .buttonStyle(.bordered)
            } else {
                Button(status.phase == .installed ? "重新安装" : "安装到手机") {
                    model.startProviderBundleInstall(
                        bundle.id,
                        reinstall: status.phase == .installed
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func binding(for bundle: AgentProviderBundle) -> Binding<Bool> {
        Binding(
            get: { model.providerBundle(bundle.id)?.enabled == true },
            set: { enabled in
                do {
                    try model.setProviderBundleEnabled(bundle.id, enabled: enabled)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
