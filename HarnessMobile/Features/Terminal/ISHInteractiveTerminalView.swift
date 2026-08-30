import Combine
import SwiftUI
import UIKit
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

enum ISHInteractiveTerminalState: Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

@MainActor
final class ISHInteractiveTerminalViewModel: ObservableObject {
    @Published private(set) var state = ISHInteractiveTerminalState.idle
    @Published private(set) var isGuestNetworkEnabled = true

    let emulator = TerminalEmulator()

    private let coordinator: ISHSandboxCoordinator
    private let inputQueue = DispatchQueue(label: "com.llf.harnessmobile.terminal.input")
    private var startTask: Task<Void, Never>?
    private var isShellStarted = false

    init(coordinator: ISHSandboxCoordinator = .shared) {
        self.coordinator = coordinator
    }

    func activate(store: WorkspaceStore) {
        installOutputCallback()
        guard !isShellStarted, startTask == nil else { return }

        state = .preparing
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startTask = nil }

            do {
                let workspaceURL = try await store.rootURL()
                try await coordinator.prepare(workspaceURL: workspaceURL)
                isGuestNetworkEnabled = await coordinator.isGuestNetworkEnabled()
                try startLoginShell()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func retry(store: WorkspaceStore) {
        guard startTask == nil else { return }
        state = .idle
        activate(store: store)
    }

    func sendInput(_ data: Data) {
#if os(iOS) && canImport(HarnessISH)
        guard !data.isEmpty else { return }
        inputQueue.async {
            ISHKernel.shared.sendInput(data)
        }
#endif
    }

    func clearScreen() {
        emulator.activeBuffer.clearScrollback()
        if let data = "clear\r".data(using: .utf8) {
            sendInput(data)
        }
    }

    func handleResize(cols: Int, rows: Int) {
        emulator.resize(cols: cols, rows: rows)
#if os(iOS) && canImport(HarnessISH)
        ISHKernel.shared.setTerminalSize(Int32(cols), rows: Int32(rows))
#endif
    }

    func setGuestNetworkEnabled(_ enabled: Bool) {
        isGuestNetworkEnabled = enabled
        Task { await coordinator.setGuestNetworkEnabled(enabled) }
    }

    private func installOutputCallback() {
#if os(iOS) && canImport(HarnessISH)
        let emulator = emulator
        let batcher = ISHTerminalOutputBatcher()
        ISHKernel.shared.outputCallback = { data in
            batcher.append(data) { drained in
                emulator.feed(drained)
            }
        }
        emulator.onResponse = { [weak self] data in
            self?.sendInput(data)
        }
#endif
    }

    private func startLoginShell() throws {
#if os(iOS) && canImport(HarnessISH)
        installOutputCallback()
        ISHKernel.shared.customEnvironment = [
            "HARNESS_WORKSPACE": "/workspace",
            "GOMAXPROCS": "2",
            "NODE_OPTIONS": "--jitless"
        ]
        let result = ISHKernel.shared.executeCommand(["/bin/sh", "-l"])
        guard result >= 0 else {
            throw ISHSandboxError.execFailed
        }

        isShellStarted = true
        state = .ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let data = "cd /workspace && clear\r".data(using: .utf8) else { return }
            self?.sendInput(data)
        }
#else
        throw ISHSandboxError.unavailable
#endif
    }
}

private final class ISHTerminalOutputBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var isDrainScheduled = false

    func append(_ data: Data, drain: @escaping @MainActor (Data) -> Void) {
        lock.lock()
        pending.append(data)
        let shouldSchedule = !isDrainScheduled
        isDrainScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            guard let drained = self?.takePending(), !drained.isEmpty else { return }
            drain(drained)
        }
    }

    private func takePending() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        isDrainScheduled = false
        return drained
    }
}

private enum ISHInteractiveTerminalSheet: String, Identifiable {
    case workspace
    case environment

    var id: String { rawValue }
}

struct ISHInteractiveTerminalView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var terminal: ISHInteractiveTerminalViewModel

    @State private var ctrlActive = false
    @State private var keyboardActive = true
    @State private var softwareKeyboardVisible = false
    @State private var presentedSheet: ISHInteractiveTerminalSheet?

    var body: some View {
        ZStack {
            TerminalCanvasView(
                emulator: terminal.emulator,
                onResize: terminal.handleResize,
                onPaste: terminal.sendInput,
                onTap: toggleKeyboard,
                onDoubleTap: {
                    terminal.sendInput(Data([0x09]))
                }
            )

            TerminalInputView(
                onInput: terminal.sendInput,
                applicationCursorKeys: terminal.emulator.applicationCursorKeys,
                isActive: $keyboardActive,
                ctrlActive: $ctrlActive,
                isTerminalVisible: presentedSheet == nil
            )
            .frame(width: 1, height: 1)
            .opacity(0)

            stateOverlay
        }
        .accessibilityIdentifier("ish-interactive-terminal")
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if terminal.state == .ready {
                TerminalKeyboardAccessory(
                    onInput: terminal.sendInput,
                    ctrlActive: $ctrlActive,
                    onShowFileBrowser: {
                        presentedSheet = .workspace
                    },
                    onShowRootfsManagement: {
                        presentedSheet = .environment
                    },
                    keyboardActive: $keyboardActive,
                    softwareKeyboardVisible: softwareKeyboardVisible,
                    onPaste: paste
                )
            }
        }
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    terminal.clearScreen()
                } label: {
                    Label("清屏", systemImage: "paintbrush")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(terminal.state != .ready)
                .accessibilityIdentifier("ish-terminal-clear")
            }
        }
        .onAppear {
            keyboardActive = true
            terminal.activate(store: model.workspaceStore)
        }
        .onDisappear {
            keyboardActive = false
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in
            softwareKeyboardVisible = true
            if presentedSheet == nil {
                keyboardActive = true
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in
            softwareKeyboardVisible = false
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .workspace:
                NavigationStack {
                    WorkspaceView()
                }
            case .environment:
                NavigationStack {
                    ISHInteractiveEnvironmentView(terminal: terminal)
                }
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch terminal.state {
        case .idle, .preparing:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("正在启动 ARM64 Alpine")
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("ish-terminal-preparing")
        case .ready:
            EmptyView()
        case let .failed(message):
            VStack(spacing: 12) {
                HarnessIconTile(systemImage: "exclamationmark.triangle.fill", tint: .orange, size: 40)
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    terminal.retry(store: model.workspaceStore)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .accessibilityIdentifier("ish-terminal-error")
        }
    }

    private func toggleKeyboard() {
        if softwareKeyboardVisible {
            keyboardActive = false
        } else if keyboardActive {
            keyboardActive = false
            DispatchQueue.main.async {
                keyboardActive = true
            }
        } else {
            keyboardActive = true
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string,
              !text.isEmpty,
              let data = text.data(using: .utf8) else { return }
        terminal.sendInput(data)
    }
}

private struct ISHInteractiveEnvironmentView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var terminal: ISHInteractiveTerminalViewModel

    var body: some View {
        Form {
            Section {
                environmentRow("cpu", "系统", "Alpine Linux ARM64", .black)
                environmentRow("folder", "工作目录", "/workspace", .blue)
                environmentRow("iphone", "执行位置", "本机 iSH", .orange)
            } header: {
                Label("运行环境", systemImage: "terminal")
            }

            Section {
                Toggle(
                    "允许 Linux 命令联网",
                    isOn: Binding(
                        get: { terminal.isGuestNetworkEnabled },
                        set: { terminal.setGuestNetworkEnabled($0) }
                    )
                )
                Text("模型 API 由原生网络层访问，不受这个开关影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Label("网络", systemImage: "network")
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("iSH 环境")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }

    private func environmentRow(
        _ systemImage: String,
        _ title: String,
        _ value: String,
        _ tint: Color
    ) -> some View {
        HStack(spacing: HarnessTheme.Spacing.medium) {
            HarnessIconTile(systemImage: systemImage, tint: tint, size: 30)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HarnessTheme.Spacing.small) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
