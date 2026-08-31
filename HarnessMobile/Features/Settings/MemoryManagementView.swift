import SwiftUI
import UniformTypeIdentifiers

struct MemoryManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var recordPendingDeletion: MemoryRecord?
    @State private var isPreparingExport = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?

    var body: some View {
        List {
            sessionSection

            Section {
                if model.memoryRecords.isEmpty {
                    Label("没有已保存的记忆", systemImage: "brain")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memoryRecords) { record in
                        MemoryRecordRow(record: record) {
                            recordPendingDeletion = record
                        }
                    }
                }
                DisclosureGroup("存储与发送范围") {
                    Text("记忆只会在本机保存。模型通过 memory_write 显式保存的内容才会写入；不会自动复制整段对话。读取或注入的内容可能会发送给你配置的模型服务商。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, HarnessTheme.Spacing.xSmall)
                }
            } header: {
                Label("已保存的记忆", systemImage: "brain.head.profile")
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label(isPreparingExport ? "正在准备导出" : "导出 JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingExport)
                .accessibilityIdentifier("memory-export-json")
            } header: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.activeSessionID) {
            await model.refreshMemory()
        }
        .refreshable {
            await model.refreshMemory()
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: recordPendingDeletion
        ) { record in
            Button("删除", role: .destructive) {
                Task { await model.deleteMemory(id: record.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { record in
            Text("这会永久删除此\(scopeLabel(for: record))记忆，无法撤销。")
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Harness-Memory"
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
    }

    private func prepareExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task { @MainActor in
            defer { isPreparingExport = false }
            do {
                exportDocument = ConversationExportFileDocument(data: try await model.memoryExportData())
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }

    private var sessionSection: some View {
        Section {
            Toggle("允许使用已保存的记忆", isOn: memoryEnabledBinding)
                .disabled(!hasActiveSession)
                .accessibilityHint("关闭后，本会话不会注入或读取已保存的记忆。")
            DisclosureGroup("会话记忆说明") {
                Text(sessionExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, HarnessTheme.Spacing.xSmall)
            }
        } header: {
            Label("当前会话", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private var hasActiveSession: Bool {
        model.activeSessionID != nil
    }

    private var sessionExplanation: String {
        hasActiveSession
            ? "关闭后，本会话不会注入或读取已保存的记忆。重新开启不会删除任何记录。"
            : "当前没有可用会话，因此不能更改此开关。"
    }

    private var memoryEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isMemoryEnabledForActiveSession },
            set: { isEnabled in
                Task { await model.setMemoryEnabledForActiveSession(isEnabled) }
            }
        )
    }

    private func scopeLabel(for record: MemoryRecord) -> String {
        switch record.scope {
        case .global:
            "全局"
        case .session:
            "会话范围"
        }
    }
}

private struct MemoryRecordRow: View {
    let record: MemoryRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HarnessTheme.Spacing.medium) {
            HarnessIconTile(
                systemImage: record.scope == .global ? "globe" : "bubble.left.and.bubble.right",
                tint: record.scope == .global ? .accentColor : .secondary
            )

            VStack(alignment: .leading, spacing: HarnessTheme.Spacing.small) {
                Text(record.content)
                    .lineLimit(4)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HarnessTheme.Spacing.small) {
                        metadataPill
                        metadataText
                    }

                    VStack(alignment: .leading, spacing: HarnessTheme.Spacing.xSmall) {
                        metadataPill
                        metadataText
                    }
                }
            }

            Spacer(minLength: HarnessTheme.Spacing.small)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("删除记忆")
            .accessibilityHint("删除这条已保存的记忆。")
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    private var scopeLabel: String {
        switch record.scope {
        case .global:
            "全局"
        case .session:
            "会话范围"
        }
    }

    private var metadataPill: some View {
        HarnessStatusPill(
            title: scopeLabel,
            systemImage: record.scope == .global ? "globe" : "bubble.left",
            tint: record.scope == .global ? .accentColor : .secondary
        )
    }

    private var metadataText: some View {
        Text("\(record.provenance == .explicitModelWrite ? "模型显式保存" : "用户管理") · \(record.createdAt, format: .dateTime.year().month().day().hour().minute())")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
