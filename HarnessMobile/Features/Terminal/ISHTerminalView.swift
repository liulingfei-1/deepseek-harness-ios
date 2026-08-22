import Combine
import SwiftUI

private enum ISHConsolePreparationState: Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

private enum ISHConsoleRunState: Equatable {
    case running
    case completed(Int)
    case failed(String)
    case cancelled
}

private struct ISHConsoleRecord: Identifiable, Equatable {
    let id: UUID
    let command: String
    let startedAt: Date
    var stdout: String
    var stderr: String
    var duration: TimeInterval?
    var state: ISHConsoleRunState
}

@MainActor
private final class ISHCommandConsoleViewModel: ObservableObject {
    @Published var preparationState: ISHConsolePreparationState = .idle
    @Published var records: [ISHConsoleRecord] = []
    @Published var isGuestNetworkEnabled = true
    @Published private(set) var isRunning = false

    private let coordinator: ISHSandboxCoordinator
    private var commandTask: Task<Void, Never>?
    private var pendingChunks: [UUID: [ISHCommandOutputChunk]] = [:]
    private var flushTask: Task<Void, Never>?

    init(coordinator: ISHSandboxCoordinator = .shared) {
        self.coordinator = coordinator
    }

    func prepare(store: WorkspaceStore) {
        guard preparationState != .preparing, preparationState != .ready else { return }
        preparationState = .preparing
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let workspaceURL = try await store.rootURL()
                try await coordinator.prepare(workspaceURL: workspaceURL)
                isGuestNetworkEnabled = await coordinator.isGuestNetworkEnabled()
                preparationState = .ready
            } catch {
                preparationState = .failed(error.localizedDescription)
            }
        }
    }

    func run(command: String, sessionID: String, store: WorkspaceStore) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isRunning else { return }
        let recordID = UUID()
        records.append(
            ISHConsoleRecord(
                id: recordID,
                command: command,
                startedAt: .now,
                stdout: "",
                stderr: "",
                duration: nil,
                state: .running
            )
        )
        if records.count > 40 {
            records.removeFirst(records.count - 40)
        }

        isRunning = true
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                commandTask = nil
                isRunning = false
            }
            do {
                let workspaceURL = try await store.rootURL()
                let result = try await coordinator.execute(
                    sessionID: sessionID,
                    command: command,
                    workspaceURL: workspaceURL,
                    policy: ISHSandboxExecutionPolicy(
                        mode: .dangerFullAccess,
                        workspaceRoot: workspaceURL
                    ),
                    onOutput: { [weak self] chunk in
                        await self?.enqueue(chunk, for: recordID)
                    }
                )
                flushPendingChunks()
                updateRecord(id: recordID) { record in
                    if record.stdout.isEmpty {
                        record.stdout = Self.sanitized(result.stdout)
                    }
                    if record.stderr.isEmpty {
                        record.stderr = Self.sanitized(result.stderr)
                    }
                    record.duration = result.duration
                    record.state = .completed(result.exitCode)
                }
            } catch is CancellationError {
                flushPendingChunks()
                updateRecord(id: recordID) { $0.state = .cancelled }
            } catch let error as ISHSandboxError where error == .cancelled {
                flushPendingChunks()
                updateRecord(id: recordID) { $0.state = .cancelled }
            } catch {
                flushPendingChunks()
                updateRecord(id: recordID) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    func stop() {
        commandTask?.cancel()
    }

    func clearCompleted() {
        records.removeAll { record in
            if case .running = record.state { return false }
            return true
        }
    }

    func setGuestNetworkEnabled(_ enabled: Bool) {
        isGuestNetworkEnabled = enabled
        Task { await coordinator.setGuestNetworkEnabled(enabled) }
    }

    private func enqueue(_ chunk: ISHCommandOutputChunk, for recordID: UUID) {
        pendingChunks[recordID, default: []].append(chunk)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flushPendingChunks()
        }
    }

    private func flushPendingChunks() {
        flushTask?.cancel()
        flushTask = nil
        let pending = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        for (recordID, chunks) in pending {
            updateRecord(id: recordID) { record in
                for chunk in chunks {
                    switch chunk.channel {
                    case .stdout:
                        record.stdout = Self.appendingBounded(
                            Self.sanitized(chunk.text),
                            to: record.stdout
                        )
                    case .stderr:
                        record.stderr = Self.appendingBounded(
                            Self.sanitized(chunk.text),
                            to: record.stderr
                        )
                    }
                }
            }
        }
    }

    private func updateRecord(
        id: UUID,
        mutation: (inout ISHConsoleRecord) -> Void
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }

    private static func appendingBounded(_ fragment: String, to existing: String) -> String {
        let maximumBytes = 256 * 1_024
        let combined = existing + fragment
        guard combined.utf8.count > maximumBytes else { return combined }
        return String(combined.suffix(maximumBytes / 2))
            + "\n[earlier terminal output discarded]\n"
    }

    private static func sanitized(_ text: String) -> String {
        var output = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar.value == 0x1B {
                guard let next = iterator.next(), next.value == 0x5B else { continue }
                while let code = iterator.next() {
                    if (0x40...0x7E).contains(code.value) { break }
                }
                continue
            }
            if scalar.value == 0x08 || scalar.value == 0x0D { continue }
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value >= 0x20 {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

private enum ISHTerminalMode: String, CaseIterable, Identifiable {
    case commands
    case terminal

    var id: Self { self }

    var title: String {
        switch self {
        case .commands:
            return "命令"
        case .terminal:
            return "终端"
        }
    }
}

struct ISHTerminalView: View {
    @State private var mode = ISHTerminalMode.commands
    @StateObject private var commandConsole = ISHCommandConsoleViewModel()
    @StateObject private var interactiveTerminal = ISHInteractiveTerminalViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Picker("iSH 模式", selection: $mode) {
                ForEach(ISHTerminalMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("ish-terminal-mode-picker")

            switch mode {
            case .commands:
                ISHCommandConsoleView(terminal: commandConsole)
            case .terminal:
                ISHInteractiveTerminalView(terminal: interactiveTerminal)
            }
        }
        .navigationTitle("iSH")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ISHCommandConsoleView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var terminal: ISHCommandConsoleViewModel
    @State private var command = ""
    @FocusState private var isCommandFocused: Bool

    private let bottomID = "ish-console-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ISHSandboxStatusView(
                        state: terminal.preparationState,
                        isGuestNetworkEnabled: Binding(
                            get: { terminal.isGuestNetworkEnabled },
                            set: { terminal.setGuestNetworkEnabled($0) }
                        )
                    )

                    if terminal.records.isEmpty {
                        ContentUnavailableView(
                            "iSH 命令沙箱",
                            systemImage: "terminal",
                            description: Text("ARM64 Alpine 在手机本机运行；工作目录是 /workspace。")
                        )
                        .padding(.top, 48)
                    } else {
                        ForEach(terminal.records) { record in
                            ISHConsoleRecordView(record: record)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                commandBar
            }
            .onChange(of: terminal.records) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    terminal.clearCompleted()
                } label: {
                    Label("清除已完成记录", systemImage: "trash")
                }
                .disabled(terminal.records.allSatisfy { record in
                    if case .running = record.state { return true }
                    return false
                })
            }
        }
        .task {
            terminal.prepare(store: model.workspaceStore)
        }
    }

    private var commandBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入 Alpine 命令", text: $command, axis: .vertical)
                .accessibilityIdentifier("ish-command-field")
                .focused($isCommandFocused)
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 8))
                .submitLabel(.send)
                .onSubmit(runCommand)

            if terminal.isRunning {
                Button {
                    terminal.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.red, in: Circle())
                }
                .accessibilityLabel("停止命令")
                .accessibilityIdentifier("ish-stop-command")
            } else {
                Button(action: runCommand) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor, in: Circle())
                }
                .disabled(!canRun)
                .accessibilityLabel("执行命令")
                .accessibilityIdentifier("ish-run-command")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var canRun: Bool {
        terminal.preparationState == .ready
            && !terminal.isRunning
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runCommand() {
        guard canRun else { return }
        let submitted = command
        command = ""
        terminal.run(
            command: submitted,
            sessionID: model.activeSessionID?.uuidString ?? "interactive-terminal",
            store: model.workspaceStore
        )
    }
}

private struct ISHSandboxStatusView: View {
    let state: ISHConsolePreparationState
    @Binding var isGuestNetworkEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                switch state {
                case .idle, .preparing:
                    ProgressView()
                    Text("正在准备 Alpine")
                case .ready:
                    Label("ARM64 Alpine 已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("ish-ready-status")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Label("Linux 网络", systemImage: "network")

                Spacer()

                Toggle("Linux 网络", isOn: $isGuestNetworkEnabled)
                    .labelsHidden()
                    .accessibilityLabel("Linux 网络")
                    .accessibilityIdentifier("ish-network-toggle")
                    .disabled(state != .ready)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct ISHConsoleRecordView: View {
    let record: ISHConsoleRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("$ \(record.command)")
                    .font(.callout.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                status
            }

            if !record.stdout.isEmpty {
                Text(record.stdout)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !record.stderr.isEmpty {
                Text(record.stderr)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch record.state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("运行中")
        case let .completed(code):
            Text("exit \(code)")
                .foregroundStyle(code == 0 ? .green : .orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("执行失败")
        case .cancelled:
            Text("已停止")
                .foregroundStyle(.secondary)
        }
    }
}
