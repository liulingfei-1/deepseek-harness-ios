import SwiftUI

struct ProviderProfilesView: View {
    @Environment(AppModel.self) private var model

    @State private var presentedEditor: ProviderEditorRoute?
    @State private var pendingDeletion: ProviderProfile?
    @State private var workingProfileID: String?
    @State private var operationError: String?

    var body: some View {
        List {
            Section {
                if model.providerProfiles.isEmpty {
                    ContentUnavailableView(
                        "没有服务商",
                        systemImage: "server.rack",
                        description: Text("添加目录服务商或自定义 OpenAI-compatible 服务商。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.providerProfiles) { profile in
                        ProviderProfileListRow(
                            profile: profile,
                            credentialStatus: model.credentialStatus(for: profile),
                            isActive: model.providerDirectory.activeProfileID == profile.id,
                            isWorking: workingProfileID == profile.id,
                            onEdit: { presentedEditor = .edit(profile.id) },
                            onActivate: { activate(profile) }
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if model.providerDirectory.activeProfileID != profile.id {
                                Button {
                                    activate(profile)
                                } label: {
                                    Label("设为默认", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                                .disabled(!canActivate(profile))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = profile
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                presentedEditor = .edit(profile.id)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            if model.providerDirectory.activeProfileID != profile.id {
                                Button("设为默认", systemImage: "checkmark.circle") {
                                    activate(profile)
                                }
                                .disabled(!canActivate(profile))
                            }
                            Button("编辑", systemImage: "pencil") {
                                presentedEditor = .edit(profile.id)
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                pendingDeletion = profile
                            }
                        }
                    }
                }
            } header: {
                Text("Provider Profiles")
            } footer: {
                Text("默认 Profile 用于新请求；当前正在运行的请求不会在中途切换。API Key 只保存在各自的本机 Keychain 项中。")
            }

            Section("添加") {
                ForEach(catalogProviders) { descriptor in
                    Button {
                        presentedEditor = .addCatalog(descriptor.id)
                    } label: {
                        LabeledContent {
                            if hasCatalogProfile(descriptor.id) {
                                Text("已添加")
                                    .foregroundStyle(.secondary)
                            } else if !descriptor.supportsCurrentInferenceWire {
                                Text("协议待接入")
                                    .foregroundStyle(.orange)
                            }
                        } label: {
                            Label(descriptor.displayName, systemImage: descriptor.systemImage)
                        }
                    }
                    .disabled(
                        hasCatalogProfile(descriptor.id)
                            || !descriptor.supportsCurrentInferenceWire
                    )
                }

                Button {
                    presentedEditor = .addCustom
                } label: {
                    Label("自定义 OpenAI-compatible", systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
        .navigationTitle("模型与服务商")
        .task {
            await model.refreshProviderCredentialStatuses()
        }
        .sheet(item: $presentedEditor) { route in
            SetupView(mode: route.setupMode)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button("删除 Profile 与 API Key", role: .destructive) {
                deletePendingProfile()
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("本地会话和工作区文件会保留。引用该 Profile 的旧会话需要重新选择模型后才能继续请求。")
        }
        .alert("服务商操作失败", isPresented: operationErrorPresented) {
            Button("好") {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "")
        }
    }

    private var catalogProviders: [ModelProviderDescriptor] {
        ModelProviderCatalog.providers.filter { $0.id != .customOpenAICompatible }
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "删除 Provider Profile？" }
        return "删除“\(pendingDeletion.displayName)”？"
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { presented in
                if !presented {
                    operationError = nil
                }
            }
        )
    }

    private func hasCatalogProfile(_ providerID: ModelProviderID) -> Bool {
        model.providerProfiles.contains { profile in
            !profile.isCustom && profile.providerID == providerID
        }
    }

    private func canActivate(_ profile: ProviderProfile) -> Bool {
        profile.descriptor.supportsCurrentInferenceWire
            && model.credentialStatus(for: profile) == .configured
            && workingProfileID == nil
            && !model.isRunning
    }

    private func activate(_ profile: ProviderProfile) {
        guard canActivate(profile) else { return }
        workingProfileID = profile.id
        operationError = nil
        Task {
            do {
                try await model.activateProviderProfile(id: profile.id)
            } catch {
                operationError = error.localizedDescription
            }
            workingProfileID = nil
        }
    }

    private func deletePendingProfile() {
        guard let profile = pendingDeletion else { return }
        pendingDeletion = nil
        workingProfileID = profile.id
        operationError = nil
        Task {
            do {
                try await model.removeProviderProfile(id: profile.id)
            } catch {
                operationError = error.localizedDescription
            }
            workingProfileID = nil
        }
    }
}

private enum ProviderEditorRoute: Identifiable {
    case edit(String)
    case addCatalog(ModelProviderID)
    case addCustom

    var id: String {
        switch self {
        case let .edit(profileID):
            return "edit-\(profileID)"
        case let .addCatalog(providerID):
            return "add-\(providerID.rawValue)"
        case .addCustom:
            return "add-custom"
        }
    }

    var setupMode: SetupMode {
        switch self {
        case let .edit(profileID):
            return .profile(profileID)
        case let .addCatalog(providerID):
            return .addingCatalog(providerID)
        case .addCustom:
            return .addingCustom
        }
    }
}

private struct ProviderProfileListRow: View {
    let profile: ProviderProfile
    let credentialStatus: ProviderCredentialStatus
    let isActive: Bool
    let isWorking: Bool
    let onEdit: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    Image(systemName: profile.descriptor.systemImage)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(.body.weight(.medium))
                            if profile.isCustom {
                                Text("自定义")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(profile.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(profile.defaultModel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 5) {
                ProviderCredentialStatusLabel(
                    status: credentialStatus,
                    supportsInference: profile.descriptor.supportsCurrentInferenceWire
                )

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("默认服务商")
                } else {
                    Button(action: onActivate) {
                        Image(systemName: "circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(
                        credentialStatus != .configured
                            || !profile.descriptor.supportsCurrentInferenceWire
                    )
                    .accessibilityLabel("设为默认服务商")
                    .help("设为默认服务商")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderCredentialStatusLabel: View {
    let status: ProviderCredentialStatus
    let supportsInference: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(foregroundStyle)
            .labelStyle(.titleAndIcon)
    }

    private var title: String {
        guard supportsInference else { return "协议待接入" }
        switch status {
        case .unknown:
            return "检查中"
        case .configured:
            return "已配置"
        case .missing:
            return "缺少 Key"
        case .originMismatch:
            return "需更新 Key"
        }
    }

    private var systemImage: String {
        guard supportsInference else { return "exclamationmark.triangle.fill" }
        switch status {
        case .unknown:
            return "ellipsis.circle"
        case .configured:
            return "checkmark.circle.fill"
        case .missing:
            return "key.slash"
        case .originMismatch:
            return "arrow.trianglehead.2.clockwise.rotate.90.circle"
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        guard supportsInference else { return AnyShapeStyle(.orange) }
        switch status {
        case .unknown:
            return AnyShapeStyle(.secondary)
        case .configured:
            return AnyShapeStyle(.green)
        case .missing:
            return AnyShapeStyle(.red)
        case .originMismatch:
            return AnyShapeStyle(.orange)
        }
    }
}

private extension ModelProviderDescriptor {
    var systemImage: String {
        switch id {
        case .deepSeekOfficial:
            return "brain.head.profile"
        case .openAI:
            return "sparkles"
        case .anthropic:
            return "text.bubble"
        case .openRouter:
            return "arrow.triangle.branch"
        case .customOpenAICompatible:
            return "server.rack"
        }
    }
}
