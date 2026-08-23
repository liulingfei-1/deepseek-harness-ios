import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var isFileImporterPresented = false
    @State private var isFolderImporterPresented = false
    @State private var reauthorizingMountID: UUID?
    @State private var mountPendingRemoval: WorkspaceStore.MountSnapshot?
    @State private var isRemovalConfirmationPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "workspace-file"

    var body: some View {
        List {
            WorkspaceMountsSection(
                mounts: model.workspaceMounts,
                onToggleWritable: toggleWritable,
                onReauthorize: reauthorize,
                onRemove: requestRemoval
            )

            Section("文件") {
                if model.workspaceFiles.isEmpty {
                    ContentUnavailableView(
                        "还没有文件",
                        systemImage: "folder.badge.plus"
                    )
                } else {
                    ForEach(model.workspaceFiles, id: \.path) { file in
                        WorkspaceFileRow(
                            file: file,
                            onExport: { export(file) }
                        )
                    }
                }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("工作区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导入文件", systemImage: "doc.badge.plus") {
                        isFileImporterPresented = true
                    }
                    Button("挂载文件夹", systemImage: "externaldrive.badge.plus") {
                        reauthorizingMountID = nil
                        isFolderImporterPresented = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加到工作区")
            }
        }
        .refreshable {
            await model.refreshWorkspace(forceMountRefresh: true)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                .plainText,
                .json,
                .commaSeparatedText,
                .xml,
                .yaml
            ]
        ) { result in
            switch result {
            case let .success(url):
                Task {
                    await model.importDocument(url)
                }
            case let .failure(error):
                model.presentError(error)
            }
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case let .success(url):
                let mountID = reauthorizingMountID
                reauthorizingMountID = nil
                Task {
                    if let mountID {
                        await model.reauthorizeWorkspaceMount(id: mountID, url: url)
                    } else {
                        await model.mountWorkspaceFolder(url)
                    }
                }
            case let .failure(error):
                reauthorizingMountID = nil
                model.presentError(error)
            }
        }
        .confirmationDialog(
            "卸载这个文件夹？",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible,
            presenting: mountPendingRemoval
        ) { mount in
            Button("卸载 \(mount.name)", role: .destructive) {
                mountPendingRemoval = nil
                Task {
                    await model.removeWorkspaceMount(id: mount.id)
                }
            }
            Button("取消", role: .cancel) {
                mountPendingRemoval = nil
            }
        } message: { mount in
            Text("源文件夹不会被删除，只会从 /workspace/mounts/\(mount.name) 移除。")
        }
    }

    private func toggleWritable(_ mount: WorkspaceStore.MountSnapshot) {
        Task {
            await model.setWorkspaceMountWritable(
                id: mount.id,
                writable: !mount.access.allowsWriting
            )
        }
    }

    private func reauthorize(_ mount: WorkspaceStore.MountSnapshot) {
        reauthorizingMountID = mount.id
        isFolderImporterPresented = true
    }

    private func requestRemoval(_ mount: WorkspaceStore.MountSnapshot) {
        mountPendingRemoval = mount
        isRemovalConfirmationPresented = true
    }

    private func export(_ file: WorkspaceStore.FileEntry) {
        Task {
            do {
                let data = try await model.workspaceFileData(path: file.path)
                exportDocument = ConversationExportFileDocument(data: data)
                exportContentType = UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension) ?? .data
                exportFilename = URL(fileURLWithPath: file.path).lastPathComponent
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }
}

private struct WorkspaceMountsSection: View {
    let mounts: [WorkspaceStore.MountSnapshot]
    let onToggleWritable: (WorkspaceStore.MountSnapshot) -> Void
    let onReauthorize: (WorkspaceStore.MountSnapshot) -> Void
    let onRemove: (WorkspaceStore.MountSnapshot) -> Void

    var body: some View {
        Section("挂载目录") {
            if mounts.isEmpty {
                Label("未挂载外部文件夹", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mounts) { mount in
                    WorkspaceMountRow(
                        mount: mount,
                        onToggleWritable: { onToggleWritable(mount) },
                        onReauthorize: { onReauthorize(mount) },
                        onRemove: { onRemove(mount) }
                    )
                }
            }
        }
    }
}

private struct WorkspaceMountRow: View {
    let mount: WorkspaceStore.MountSnapshot
    let onToggleWritable: () -> Void
    let onReauthorize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mount.name)
                        .lineLimit(1)
                    Text(mount.effectiveWritable ? "读写" : "只读")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(mount.guestPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Menu {
                Button(
                    mount.access.allowsWriting ? "切换为只读" : "允许写入",
                    systemImage: mount.access.allowsWriting ? "lock" : "lock.open"
                ) {
                    onToggleWritable()
                }
                .disabled(!mount.sourceWritable && !mount.access.allowsWriting)

                Button("重新授权", systemImage: "arrow.clockwise") {
                    onReauthorize()
                }

                Button("卸载", systemImage: "eject", role: .destructive) {
                    onRemove()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("管理挂载 \(mount.name)")
        }
    }

    private var statusIcon: String {
        switch mount.status {
        case .active:
            mount.effectiveWritable
                ? "externaldrive.fill.badge.checkmark"
                : "externaldrive.badge.checkmark"
        case .staleBookmark:
            "externaldrive.badge.exclamationmark"
        case .permissionDenied, .unavailable:
            "externaldrive.badge.xmark"
        }
    }

    private var statusColor: Color {
        switch mount.status {
        case .active: .green
        case .staleBookmark: .orange
        case .permissionDenied, .unavailable: .red
        }
    }

    private var statusText: String {
        switch mount.status {
        case .active:
            mount.sourceDisplayName
        case .staleBookmark:
            mount.failureMessage ?? "授权已过期"
        case .permissionDenied:
            mount.failureMessage ?? "需要重新授权"
        case .unavailable:
            mount.failureMessage ?? "文件夹当前不可用"
        }
    }
}

private struct WorkspaceFileRow: View {
    let file: WorkspaceStore.FileEntry
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.path.hasPrefix("mounts/") ? "doc.on.doc" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .lineLimit(2)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: file.size,
                        countStyle: .file
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("导出文件", systemImage: "square.and.arrow.up", action: onExport)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("导出 \(file.path)")
        }
    }
}
