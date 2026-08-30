import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model

    private let onConversationOpened: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenTools: () -> Void
    private let onOpenBackgroundSettings: () -> Void

    @State private var sessionToRename: ConversationSessionSummary?
    @State private var sessionToDelete: ConversationSessionSummary?
    @State private var isDeleteConfirmationPresented = false
    @State private var operation: SessionOperation?
    @State private var searchText = ""
    @State private var searchResults: [ConversationSessionSearchResult] = []
    @State private var isSearching = false
    @State private var collectionScope = SessionCollectionScope.active
    @State private var sortOrder = SessionSortOrder.updatedNewest

    init(
        onConversationOpened: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onOpenTools: @escaping () -> Void = {},
        onOpenBackgroundSettings: @escaping () -> Void = {}
    ) {
        self.onConversationOpened = onConversationOpened
        self.onOpenSettings = onOpenSettings
        self.onOpenTools = onOpenTools
        self.onOpenBackgroundSettings = onOpenBackgroundSettings
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                if let errorMessage = model.errorMessage {
                    SessionErrorSection(message: errorMessage)
                }

                HomeContinueSection(
                    activeSession: activeSession,
                    status: activeSession.map(status(for:)),
                    onContinue: {
                        if let activeSession {
                            openConversation(activeSession)
                        } else {
                            createConversation()
                        }
                    },
                    onCreate: createConversation
                )

                BackgroundSystemStatusSection(
                    projection: model.backgroundSystemProjection,
                    onOpenSettings: onOpenBackgroundSettings
                )

                if visibleSessions.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    if collectionScope == .all {
                        if !activeSessions.isEmpty {
                            sessionSection("会话", sessions: activeSessions)
                        }
                        if !archivedSessions.isEmpty {
                            sessionSection("已归档", sessions: archivedSessions)
                        }
                    } else {
                        sessionSection(collectionScope == .active ? "最近会话" : collectionScope.sectionTitle, sessions: visibleSessions)
                    }
                }
            }
            // Leave room for the floating new-session control.  A fixed
            // 76-point inset let the control cover the final session row at
            // accessibility text sizes and on compact-height devices.
            .contentMargins(.bottom, 132, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HarnessTheme.pageBackground)

            floatingControls
        }
        .listStyle(.plain)
        .navigationTitle("Harness")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索标题和消息"
        )
        .searchScopes($collectionScope) {
            ForEach(SessionCollectionScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("设置")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("范围", selection: $collectionScope) {
                        ForEach(SessionCollectionScope.allCases) { scope in
                            Label(scope.title, systemImage: scope.systemImage)
                                .tag(scope)
                        }
                    }

                    Picker("排序", selection: $sortOrder) {
                        ForEach(SessionSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage)
                                .tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("筛选与排序")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenTools) {
                    Image(systemName: "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("工具")
            }
        }
        .task(id: searchTaskID) {
            await refreshSearch()
        }
        .sheet(item: $sessionToRename) { session in
            RenameConversationSheet(session: session)
        }
        .confirmationDialog(
            "删除会话？",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: sessionToDelete
        ) { session in
            Button("删除“\(session.title)”", role: .destructive) {
                deleteConversation(session)
            }
            Button("取消", role: .cancel) {
                sessionToDelete = nil
            }
        } message: { session in
            if session.id == model.activeSessionID, model.isRunning {
                Text("当前执行会先停止，然后删除这个会话。工作区文件不会被删除。")
            } else {
                Text("会删除这个会话在本机保存的消息、任务状态和恢复检查点；工作区文件不受影响。")
            }
        }
    }

    private var floatingControls: some View {
        HStack(spacing: 10) {
            Button(action: createConversation) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            }
            .accessibilityLabel("新建会话")
            .disabled(operation != nil)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeSession: ConversationSessionSummary? {
        guard let activeSessionID = model.activeSessionID else { return nil }
        return model.sessions.first { $0.id == activeSessionID }
    }

    private var searchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(
            query: normalizedSearchText,
            revisions: model.sessions.map {
                SessionSearchRevision(
                    id: $0.id,
                    revision: $0.revision,
                    archivedAt: $0.archivedAt
                )
            }
        )
    }

    private var sourceSessions: [ConversationSessionSummary] {
        normalizedSearchText.isEmpty
            ? model.sessions
            : searchResults.map(\.session)
    }

    private var visibleSessions: [ConversationSessionSummary] {
        sort(
            sourceSessions.filter { session in
                switch collectionScope {
                case .active:
                    !session.isArchived
                case .archived:
                    session.isArchived
                case .all:
                    true
                }
            }
        )
    }

    private var activeSessions: [ConversationSessionSummary] {
        visibleSessions.filter { !$0.isArchived }
    }

    private var archivedSessions: [ConversationSessionSummary] {
        visibleSessions.filter(\.isArchived)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            HStack {
                Spacer()
                ProgressView("正在搜索…")
                Spacer()
            }
        } else if !normalizedSearchText.isEmpty {
            ContentUnavailableView.search(text: normalizedSearchText)
        } else if collectionScope == .archived {
            ContentUnavailableView(
                "没有已归档会话",
                systemImage: "archivebox",
                description: Text("归档会话会保留消息和任务状态，并可随时恢复。")
            )
        } else {
            ContentUnavailableView {
                Label("还没有会话", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("新建会话后，消息、任务状态与恢复检查点都会保存在本机。")
            } actions: {
                Button("新建会话", action: createConversation)
                    .disabled(operation != nil)
            }
        }
    }

    private func sessionSection(
        _ title: String,
        sessions: [ConversationSessionSummary]
    ) -> some View {
        Section {
            ForEach(sessions) { session in
                sessionRow(session)
                    .harnessCardListRow()
            }
        } header: {
            Label(title, systemImage: title == "已归档" ? "archivebox" : "bubble.left.and.bubble.right")
        }
    }

    private func sessionRow(_ session: ConversationSessionSummary) -> some View {
        Button {
            openConversation(session)
        } label: {
            SessionRow(
                session: session,
                matchSnippet: searchResult(for: session.id)?.titleMatched == false
                    ? searchResult(for: session.id)?.matchSnippet
                    : nil,
                status: status(for: session),
                isBusy: operation?.sessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(operation != nil)
        .accessibilityHint(accessibilityHint(for: session))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if session.isArchived {
                Button {
                    restoreConversation(session)
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            } else {
                Button {
                    archiveConversation(session)
                } label: {
                    Label("归档", systemImage: "archivebox")
                }
                .tint(.orange)
            }

            Button {
                forkConversation(session)
            } label: {
                Label("分叉", systemImage: "arrow.triangle.branch")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) {
                requestDeletion(of: session)
            }

            Button {
                sessionToRename = session
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button {
                regenerateConversationTitle(session)
            } label: {
                Label("重新生成标题", systemImage: "text.badge.star")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                forkConversation(session)
            } label: {
                Label("分叉会话", systemImage: "arrow.triangle.branch")
            }

            if session.isArchived {
                Button {
                    restoreConversation(session)
                } label: {
                    Label("恢复会话", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    archiveConversation(session)
                } label: {
                    Label("归档会话", systemImage: "archivebox")
                }
            }

            Button {
                sessionToRename = session
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button {
                regenerateConversationTitle(session)
            } label: {
                Label("重新生成标题", systemImage: "text.badge.star")
            }

            Button(role: .destructive) {
                requestDeletion(of: session)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func regenerateConversationTitle(_ session: ConversationSessionSummary) {
        operation = .titling(session.id)
        Task { @MainActor in
            await model.regenerateConversationTitle(id: session.id)
            operation = nil
        }
    }

    private func createConversation() {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .creating
        Task { @MainActor in
            await model.createConversation()
            if model.activeSessionID != nil, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .creating {
                operation = nil
            }
        }
    }

    private func openConversation(_ session: ConversationSessionSummary) {
        if session.isArchived {
            restoreConversation(session, openAfterRestore: true)
        } else {
            switchConversation(to: session)
        }
    }

    private func switchConversation(to session: ConversationSessionSummary) {
        guard operation == nil else { return }
        if session.id == model.activeSessionID {
            onConversationOpened()
            return
        }
        model.errorMessage = nil
        operation = .switching(session.id)
        Task { @MainActor in
            await model.switchConversation(to: session.id)
            if model.activeSessionID == session.id, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .switching(session.id) {
                operation = nil
            }
        }
    }

    private func forkConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .forking(session.id)
        Task { @MainActor in
            await model.forkConversation(id: session.id)
            if model.activeSessionID != session.id, model.errorMessage == nil {
                onConversationOpened()
            }
            if operation == .forking(session.id) {
                operation = nil
            }
        }
    }

    private func archiveConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .archiving(session.id)
        Task { @MainActor in
            await model.archiveConversation(id: session.id)
            if operation == .archiving(session.id) {
                operation = nil
            }
        }
    }

    private func restoreConversation(
        _ session: ConversationSessionSummary,
        openAfterRestore: Bool = false
    ) {
        guard operation == nil else { return }
        model.errorMessage = nil
        operation = .restoring(session.id)
        Task { @MainActor in
            await model.restoreConversation(id: session.id)
            if openAfterRestore,
               model.sessions.first(where: { $0.id == session.id })?.isArchived == false {
                await model.switchConversation(to: session.id)
                if model.activeSessionID == session.id, model.errorMessage == nil {
                    onConversationOpened()
                }
            }
            if operation == .restoring(session.id) {
                operation = nil
            }
        }
    }

    private func requestDeletion(of session: ConversationSessionSummary) {
        guard operation == nil else { return }
        sessionToDelete = session
        isDeleteConfirmationPresented = true
    }

    private func deleteConversation(_ session: ConversationSessionSummary) {
        guard operation == nil else { return }
        sessionToDelete = nil
        model.errorMessage = nil
        operation = .deleting(session.id)
        Task { @MainActor in
            await model.deleteConversation(id: session.id)
            if operation == .deleting(session.id) {
                operation = nil
            }
        }
    }

    private func refreshSearch() async {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        isSearching = true
        let results = await model.searchConversations(query: query)
        guard !Task.isCancelled else { return }
        searchResults = results
        isSearching = false
    }

    private func searchResult(for id: UUID) -> ConversationSessionSearchResult? {
        searchResults.first { $0.id == id }
    }

    private func sort(
        _ sessions: [ConversationSessionSummary]
    ) -> [ConversationSessionSummary] {
        switch sortOrder {
        case .updatedNewest:
            sessions.sorted { $0.updatedAt > $1.updatedAt }
        case .createdNewest:
            sessions.sorted { $0.createdAt > $1.createdAt }
        case .title:
            sessions.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private func status(for session: ConversationSessionSummary) -> SessionDisplayStatus {
        if session.isArchived {
            return .archived
        }
        if let run = model.sessionRunSnapshots[session.id] {
            switch run.phase {
            case .idle, .maintenance, .running, .cancelling:
                return .running
            case .terminal:
                if !run.presentation.queuedInputs.isEmpty {
                    return .waiting(run.presentation.queuedInputs.count)
                }
            }
        }
        if session.queuedInputCount > 0 {
            return .waiting(session.queuedInputCount)
        }
        if session.isResumable {
            return .resumable
        }
        if session.id == model.activeSessionID {
            return .current
        }
        return session.messageCount == 0 ? .ready : .completed
    }

    private func accessibilityHint(for session: ConversationSessionSummary) -> String {
        if session.isArchived {
            return "恢复并打开此会话"
        }
        return session.id == model.activeSessionID ? "当前会话" : "切换到此会话"
    }
}

private struct HomeContinueSection: View {
    let activeSession: ConversationSessionSummary?
    let status: SessionDisplayStatus?
    let onContinue: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Section {
            Button(action: onContinue) {
                HStack(spacing: 12) {
                    Image(systemName: activeSession == nil ? "play.fill" : "arrow.forward.circle.fill")
                        .font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeSession == nil ? "开始任务" : "继续当前任务")
                            .font(.body.weight(.semibold))
                        Text(activeSession?.title ?? "创建一个新的本机会话")
                            .font(.caption)
                            .opacity(0.82)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HarnessTheme.Spacing.large)
                .padding(.vertical, HarnessTheme.Spacing.medium)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .harnessCardListRow()
            .accessibilityIdentifier("home-continue-task")

            Button(action: onCreate) {
                HStack(spacing: 10) {
                    HarnessIconTile(systemImage: "plus.bubble", tint: .accentColor, size: 28)
                    Text("新建会话")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HarnessTheme.Spacing.large)
                .padding(.vertical, HarnessTheme.Spacing.medium)
                .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous)
                        .stroke(HarnessTheme.separator, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .harnessCardListRow()
            .accessibilityIdentifier("home-new-session")
        } header: {
            Label("任务", systemImage: "bolt.fill")
                .foregroundStyle(.secondary)
        } footer: {
            if let activeSession, let status {
                Text("当前：\(activeSession.title) · \(status.title)")
            } else {
                Text("从本机保存的会话继续，或开始一个新的任务。")
            }
        }
    }
}

private struct BackgroundSystemStatusSection: View {
    let projection: BackgroundSystemProjection
    let onOpenSettings: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HarnessTheme.Spacing.medium) {
                HStack(spacing: HarnessTheme.Spacing.medium) {
                    HarnessIconTile(
                        systemImage: "bolt.horizontal.circle.fill",
                        tint: statusTint,
                        size: 36
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台任务")
                            .font(.body.weight(.semibold))
                        Text("\(projection.activeRunCount) 个活动任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: HarnessTheme.Spacing.small)
                    HarnessStatusPill(
                        title: tierLabel,
                        systemImage: statusSystemImage,
                        tint: statusTint
                    )
                }

                if !projection.degradedReasons.isEmpty {
                    Label(
                        "降级：" + projection.degradedReasons.map(degradedLabel).sorted().joined(separator: "、"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                Divider()

                Button(action: onOpenSettings) {
                    HStack {
                        Text("状态与恢复设置")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-background-status")
            }
            .harnessCardSurface(padding: HarnessTheme.Spacing.large)
            .harnessCardListRow()
        } header: {
            Label("系统状态", systemImage: "waveform.path.ecg")
        } footer: {
            Text("这里汇总所有并行任务的真实状态；详细权限、通知和恢复设置在后台任务页。")
        }
    }

    private var tierLabel: String {
        switch projection.survivalTier {
        case .foreground: "前台"
        case .finiteBackgroundTask: "短时后台"
        case .continuedProcessing: "Continued Processing"
        case .extendedAudio: "音频延展"
        case .extendedLocation: "定位延展"
        case .degraded: "降级"
        }
    }

    private var statusTint: Color {
        switch projection.survivalTier {
        case .foreground: .secondary
        case .finiteBackgroundTask: .blue
        case .continuedProcessing, .extendedAudio, .extendedLocation: .green
        case .degraded: .orange
        }
    }

    private var statusSystemImage: String {
        switch projection.survivalTier {
        case .foreground: "iphone"
        case .finiteBackgroundTask: "timer"
        case .continuedProcessing: "bolt.fill"
        case .extendedAudio: "speaker.wave.2.fill"
        case .extendedLocation: "location.fill"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private func degradedLabel(_ reason: BackgroundKeepAliveDegradedReason) -> String {
        switch reason {
        case .lowPowerMode: "低电量模式"
        case .thermalPressure: "温度压力"
        case .audioUnavailable: "音频不可用"
        case .locationUnavailable: "定位不可用"
        }
    }
}

private struct WorkspaceHierarchySection: View {
    @Binding var isExpanded: Bool
    let files: [WorkspaceStore.FileEntry]
    let mounts: [WorkspaceStore.MountSnapshot]
    let activeSessionTitle: String?
    let isRunning: Bool
    let onOpenWorkspace: () -> Void

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let activeSessionTitle {
                    hierarchyRow(
                        title: activeSessionTitle,
                        detail: isRunning ? "当前会话 · Agent 运行中" : "当前会话 · 等待输入",
                        systemImage: isRunning ? "waveform" : "bubble.left",
                        tint: isRunning ? .green : .blue,
                        depth: 1
                    )
                }

                Button(action: onOpenWorkspace) {
                    hierarchyRow(
                        title: "文件",
                        detail: "\(files.count) 个本机文件",
                        systemImage: "folder",
                        tint: .orange,
                        depth: 1,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace-hierarchy-files")

                ForEach(mounts.prefix(4)) { mount in
                    hierarchyRow(
                        title: mount.name,
                        detail: "\(mount.effectiveWritable ? "读写" : "只读") · \(mountStatusTitle(mount.status))",
                        systemImage: mountStatusIcon(mount.status),
                        tint: mountStatusColor(mount.status),
                        depth: 2
                    )
                }

                if mounts.count > 4 {
                    Text("另有 \(mounts.count - 4) 个挂载目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }

                Button(action: onOpenWorkspace) {
                    Label("打开完整工作区", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.medium))
                        .padding(.leading, 28)
                }
                .accessibilityIdentifier("workspace-hierarchy-open")
            } label: {
                HStack(spacing: 12) {
                    HarnessIconTile(systemImage: "folder.fill", tint: .orange, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("/workspace")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(files.count) 个文件 · \(mounts.count) 个挂载 · \(isRunning ? "正在运行" : "本机就绪")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("workspace-hierarchy-root")
            }
        } header: {
            Label("Workspace", systemImage: "folder")
        }
    }

    private func hierarchyRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        depth: Int,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            HarnessIconTile(systemImage: systemImage, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func mountStatusTitle(_ status: WorkspaceStore.MountStatus) -> String {
        switch status {
        case .active: "已连接"
        case .staleBookmark: "需重新授权"
        case .permissionDenied: "权限被拒绝"
        case .unavailable: "不可用"
        }
    }

    private func mountStatusIcon(_ status: WorkspaceStore.MountStatus) -> String {
        switch status {
        case .active: "externaldrive.badge.checkmark"
        case .staleBookmark: "externaldrive.badge.exclamationmark"
        case .permissionDenied, .unavailable: "externaldrive.badge.xmark"
        }
    }

    private func mountStatusColor(_ status: WorkspaceStore.MountStatus) -> Color {
        switch status {
        case .active: .green
        case .staleBookmark: .orange
        case .permissionDenied, .unavailable: .red
        }
    }
}

private enum SessionOperation: Equatable {
    case creating
    case switching(UUID)
    case deleting(UUID)
    case forking(UUID)
    case archiving(UUID)
    case restoring(UUID)
    case titling(UUID)

    var sessionID: UUID? {
        switch self {
        case .creating:
            nil
        case let .switching(id), let .deleting(id), let .forking(id),
             let .archiving(id), let .restoring(id), let .titling(id):
            id
        }
    }
}

private struct SessionSearchTaskID: Equatable {
    let query: String
    let revisions: [SessionSearchRevision]
}

private struct SessionSearchRevision: Equatable {
    let id: UUID
    let revision: Int
    let archivedAt: Date?
}

private enum SessionCollectionScope: String, CaseIterable, Identifiable {
    case active
    case archived
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "当前"
        case .archived: "归档"
        case .all: "全部"
        }
    }

    var sectionTitle: String {
        switch self {
        case .active: "会话"
        case .archived: "已归档"
        case .all: "全部会话"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "rectangle.stack"
        case .archived: "archivebox"
        case .all: "square.grid.2x2"
        }
    }
}

private enum SessionSortOrder: String, CaseIterable, Identifiable {
    case updatedNewest
    case createdNewest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedNewest: "最近更新"
        case .createdNewest: "最近创建"
        case .title: "标题"
        }
    }

    var systemImage: String {
        switch self {
        case .updatedNewest: "clock.arrow.circlepath"
        case .createdNewest: "calendar.badge.plus"
        case .title: "textformat"
        }
    }
}

private enum SessionDisplayStatus: Equatable {
    case running
    case waiting(Int)
    case resumable
    case completed
    case ready
    case current
    case archived

    var title: String {
        switch self {
        case .running: "运行中"
        case let .waiting(count): "排队 \(count)"
        case .resumable: "可继续"
        case .completed: "已完成"
        case .ready: "就绪"
        case .current: "当前"
        case .archived: "已归档"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "waveform"
        case .waiting: "clock"
        case .resumable: "pause.fill"
        case .completed: "checkmark"
        case .ready: "circle"
        case .current: "checkmark.circle.fill"
        case .archived: "archivebox.fill"
        }
    }

    var leadingIcon: String {
        switch self {
        case .running:
            "waveform"
        case .waiting:
            "text.line.last.and.arrowtriangle.forward"
        case .resumable:
            "play.fill"
        case .completed:
            "checkmark"
        case .ready:
            "sparkles"
        case .current:
            "bubble.left.fill"
        case .archived:
            "archivebox.fill"
        }
    }

    var color: Color {
        switch self {
        case .running, .current: .blue
        case .waiting, .resumable: .orange
        case .completed: .green
        case .ready, .archived: .secondary
        }
    }
}

private struct SessionRow: View {
    let session: ConversationSessionSummary
    let matchSnippet: String?
    let status: SessionDisplayStatus
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 13) {
            HarnessIconTile(systemImage: status.leadingIcon, tint: status.color, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    Text(
                        session.updatedAt.formatted(
                            .relative(presentation: .named, unitsStyle: .abbreviated)
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let matchSnippet, !matchSnippet.isEmpty {
                    Text(matchSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: HarnessTheme.Spacing.small) {
                    HarnessStatusPill(
                        title: status.title,
                        systemImage: status.systemImage,
                        tint: status.color
                    )
                    Text("\(session.messageCount) 条消息")
                    if session.forkedFromSessionID != nil {
                        Text("·").accessibilityHidden(true)
                        Label("分叉", systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在处理会话")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, HarnessTheme.Spacing.medium)
        .background(
            status == .current ? Color.accentColor.opacity(0.10) : HarnessTheme.surface,
            in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: HarnessTheme.Radius.card, style: .continuous)
                .stroke(
                    status == .current ? Color.accentColor.opacity(0.24) : HarnessTheme.separator,
                    lineWidth: 0.5
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(status == .current ? .isSelected : [])
    }
}

private struct SessionErrorSection: View {
    @Environment(AppModel.self) private var model

    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Button("关闭") {
                model.errorMessage = nil
            }
        } header: {
            Label("操作失败", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct RenameConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let session: ConversationSessionSummary

    @State private var title: String
    @State private var isSaving = false
    @FocusState private var isTitleFocused: Bool

    init(session: ConversationSessionSummary) {
        self.session = session
        _title = State(initialValue: session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("会话名称", text: $title)
                        .focused($isTitleFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    HStack {
                        Text("名称保存在本机，最多 80 个字符。")
                        Spacer()
                        Text("\(title.count)/80")
                            .monospacedDigit()
                            .foregroundStyle(title.count > 80 ? .red : .secondary)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Label("无法重命名", systemImage: "pencil.slash")
                    }
                }
            }
            .navigationTitle("重命名会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
            .task {
                isTitleFocused = true
            }
        }
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving
            && !normalizedTitle.isEmpty
            && normalizedTitle.count <= 80
            && normalizedTitle != session.title
    }

    private func save() {
        guard canSave else { return }
        let savedTitle = normalizedTitle
        model.errorMessage = nil
        isSaving = true
        Task { @MainActor in
            await model.renameConversation(id: session.id, title: savedTitle)
            isSaving = false
            if model.sessions.first(where: { $0.id == session.id })?.title == savedTitle {
                dismiss()
            }
        }
    }
}
