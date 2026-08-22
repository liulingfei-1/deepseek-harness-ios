import Foundation
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

enum ISHOutputChannel: String, Sendable, Codable {
    case stdout
    case stderr
}

struct ISHCommandOutputChunk: Sendable, Equatable {
    let channel: ISHOutputChannel
    let text: String
}

struct ISHCommandResult: Sendable, Equatable {
    let pid: Int32
    let exitCode: Int
    let stdout: String
    let stderr: String
    let duration: TimeInterval

    var combinedOutput: String {
        let sections = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sections.isEmpty ? "(命令执行完成，没有输出)" : sections.joined(separator: "\n")
    }
}

/// OpenMinis reports the POSIX wait status for guest processes. Normalize the
/// common exited-process form (for example 256 means exit code 1) before it is
/// shown to the model or the conversation UI.
enum ISHExitStatus {
    static func normalized(_ rawValue: Int) -> Int {
        guard rawValue > 255 else { return rawValue }
        return rawValue & 0x7f == 0 ? rawValue >> 8 : rawValue
    }
}

struct ISHGuestNetworkLease: Sendable, Hashable {
    fileprivate let id: UUID
}

/// File-effect policy carried by one iSH invocation.  The policy deliberately
/// lives on the call rather than on the long-lived coordinator so that two
/// consumers cannot accidentally inherit one another's access mode.
enum ISHSandboxFileMode: String, Sendable, Codable, Equatable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

struct ISHSandboxExecutionPolicy: Sendable, Equatable {
    let mode: ISHSandboxFileMode
    let workspaceRoot: String

    init(mode: ISHSandboxFileMode, workspaceRoot: URL) {
        self.mode = mode
        self.workspaceRoot = workspaceRoot.standardizedFileURL.path
    }
}

enum ISHSandboxError: LocalizedError, Sendable, Equatable {
    case unavailable
    case bootFailed(Int32)
    case workspaceMountFailed(Int32)
    case processCreationFailed
    case execFailed
    case timedOut(TimeInterval)
    case cancelled
    case sessionBusy
    case capacityReached
    case invalidCommand
    case policyUnavailable(ISHSandboxFileMode)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前构建没有包含 iSH 本机沙箱。"
        case let .bootFailed(code):
            return "iSH 内核启动失败（\(code)）。"
        case let .workspaceMountFailed(code):
            return "无法把 App 工作区挂载到 iSH（\(code)）。"
        case .processCreationFailed:
            return "iSH 无法创建进程。"
        case .execFailed:
            return "iSH 无法执行 /bin/sh。"
        case let .timedOut(seconds):
            return "命令超过 \(Int(seconds)) 秒，已终止整个进程组。"
        case .cancelled:
            return "命令已取消。"
        case .sessionBusy:
            return "这个会话已有命令在运行。"
        case .capacityReached:
            return "iSH 已达到同时执行两条命令的上限。"
        case .invalidCommand:
            return "命令为空或超过 64 KiB。"
        case let .policyUnavailable(mode):
            return "iSH 当前无法按 \(mode.rawValue) 文件策略隔离本次调用，已拒绝执行（不会降级为未隔离执行）。"
        }
    }
}

actor ISHSandboxCoordinator {
    static let shared = ISHSandboxCoordinator()

    private let installer: ISHRootfsInstaller
    private var isPrepared = false
    private var mountedWorkspacePath: String?
    private var configuredWorkspaceMounts: [String: WorkspaceStore.MountBinding] = [:]
    private var mountedWorkspaceMounts: [String: WorkspaceStore.MountBinding] = [:]
    private var workspaceMountFailures: [String: Int32] = [:]
    private var guestNetworkEnabled = true
    private var guestNetworkLeases: Set<UUID> = []
    private var isBackgrounded = false
    private var activeSessionIDs: Set<String> = []
    private var activeExecutions: [UUID: ISHCommandExecutionBox] = [:]
    private var activeExecutionsBySessionID: [String: ISHCommandExecutionBox] = [:]

    init(installer: ISHRootfsInstaller = .shared) {
        self.installer = installer
    }

    var isAvailable: Bool {
#if os(iOS) && canImport(HarnessISH)
        true
#else
        false
#endif
    }

    func prepare(workspaceURL: URL) async throws {
#if os(iOS) && canImport(HarnessISH)
        let normalizedWorkspace = workspaceURL.standardizedFileURL.path
        if isPrepared, mountedWorkspacePath == normalizedWorkspace {
            reconcileWorkspaceMounts()
            applyExecutionLimits(currentLimits())
            return
        }

        let installation = try await installer.installIfNeeded()
        if !ISHKernel.shared.isBooted {
            let result = ISHKernel.shared.boot(withRootPath: installation.rootURL.path)
            guard result >= 0 else {
                throw ISHSandboxError.bootFailed(result)
            }
        }

        let mkdirResult = ISHShellExecutor.executeCommandSync(
            "mkdir -p /workspace",
            timeout: 10,
            lineCallback: nil
        )
        guard mkdirResult.exitCode == 0 else {
            throw ISHSandboxError.workspaceMountFailed(Int32(mkdirResult.exitCode))
        }

        if let mountedWorkspacePath,
           mountedWorkspacePath != normalizedWorkspace {
            unmountAllWorkspaceMounts()
            _ = ISHKernel.shared.bindUnmountPath("/workspace")
        }
        if mountedWorkspacePath != normalizedWorkspace {
            let result = ISHKernel.shared.bindMountPath(
                "/workspace",
                toHostPath: normalizedWorkspace
            )
            guard result >= 0 else {
                throw ISHSandboxError.workspaceMountFailed(result)
            }
            mountedWorkspacePath = normalizedWorkspace
        }
        reconcileWorkspaceMounts()
        applyGuestNetworkPolicy()
        refreshGuestDNS()
        isPrepared = true
        applyExecutionLimits(currentLimits())
#else
        throw ISHSandboxError.unavailable
#endif
    }

    func setWorkspaceMounts(_ mounts: [WorkspaceStore.MountBinding]) {
        configuredWorkspaceMounts = Dictionary(
            uniqueKeysWithValues: mounts.map { ($0.guestPath, $0) }
        )
#if os(iOS) && canImport(HarnessISH)
        if isPrepared, ISHKernel.shared.isBooted {
            reconcileWorkspaceMounts()
        }
#endif
    }

    func currentWorkspaceMountFailures() -> [String: Int32] {
        workspaceMountFailures
    }

    func execute(
        sessionID: String,
        command: String,
        workspaceURL: URL,
        timeout: TimeInterval = 300,
        maximumOutputBytes: Int? = nil,
        policy: ISHSandboxExecutionPolicy,
        onOutput: @escaping @Sendable (ISHCommandOutputChunk) async -> Void = { _ in }
    ) async throws -> ISHCommandResult {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, command.utf8.count <= 64 * 1_024 else {
            throw ISHSandboxError.invalidCommand
        }
        let canonicalWorkspace = workspaceURL.standardizedFileURL.path
        guard policy.workspaceRoot == canonicalWorkspace else {
            // A caller must not claim a different root than the mounted root.
            // Treat this as an unavailable policy instead of silently widening
            // the call to the coordinator's existing mount.
            throw ISHSandboxError.policyUnavailable(policy.mode)
        }
        guard policy.mode == .dangerFullAccess else {
            // The pinned HarnessISH bridge currently exposes one process-wide
            // writable guest root and does not expose a per-process file-policy
            // backend. It therefore cannot truthfully promise read-only or
            // workspace-only writes. Fail closed until that backend is present.
            throw ISHSandboxError.policyUnavailable(policy.mode)
        }
        guard isAvailable else {
            throw ISHSandboxError.unavailable
        }
        try await prepare(workspaceURL: workspaceURL)
        let limits = currentLimits()
        applyExecutionLimits(limits)
        guard !activeSessionIDs.contains(sessionID) else {
            throw ISHSandboxError.sessionBusy
        }
        guard activeExecutions.count < limits.maximumConcurrentCommands else {
            throw ISHSandboxError.capacityReached
        }

#if os(iOS) && canImport(HarnessISH)
        let executionID = UUID()
        let box = ISHCommandExecutionBox()
        activeSessionIDs.insert(sessionID)
        activeExecutions[executionID] = box
        activeExecutionsBySessionID[sessionID] = box
        defer {
            activeExecutions.removeValue(forKey: executionID)
            activeExecutionsBySessionID.removeValue(forKey: sessionID)
            activeSessionIDs.remove(sessionID)
        }

        let script = "cd /workspace\n({ exec 0</dev/null; } 2>/dev/null || true; \(command)\n)\n"
        let environment = [
            "HOME": "/root",
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM": "xterm-256color",
            "GOMAXPROCS": "\(limits.maximumConcurrentCommands)",
            "NODE_OPTIONS": "--jitless"
        ]
        return try await box.start(
            script: script,
            environment: environment,
            timeout: limits.effectiveCommandTimeout(requested: timeout),
            maximumOutputBytes: limits.effectiveInlineOutputBytes(
                requested: maximumOutputBytes
            ),
            onOutput: onOutput
        )
#else
        throw ISHSandboxError.unavailable
#endif
    }

    func cancelAll() {
        for execution in activeExecutions.values {
            execution.cancel()
        }
    }

    /// Cancel one fixed subsystem session without terminating unrelated Agent,
    /// terminal, plugin-host, or background commands in the same guest.
    func cancel(sessionID: String) {
        activeExecutionsBySessionID[sessionID]?.cancel()
    }

    func setGuestNetworkEnabled(_ enabled: Bool) {
        guestNetworkEnabled = enabled
        applyGuestNetworkPolicy()
    }

    func beginTemporaryGuestNetworkAccess() -> ISHGuestNetworkLease {
        let lease = ISHGuestNetworkLease(id: UUID())
        guestNetworkLeases.insert(lease.id)
        applyGuestNetworkPolicy()
        return lease
    }

    func endTemporaryGuestNetworkAccess(_ lease: ISHGuestNetworkLease) {
        guestNetworkLeases.remove(lease.id)
        applyGuestNetworkPolicy()
    }

    func isGuestNetworkEnabled() -> Bool {
        guestNetworkEnabled
    }

    func isGuestNetworkEffectivelyEnabled() -> Bool {
        guestNetworkEnabled || !guestNetworkLeases.isEmpty
    }

    func refreshGuestDNS() {
#if os(iOS) && canImport(HarnessISH)
        guard ISHKernel.shared.isBooted,
              guestNetworkEnabled || !guestNetworkLeases.isEmpty else { return }
        ISHKernel.shared.refreshDns()
#endif
    }

    private func applyGuestNetworkPolicy() {
#if os(iOS) && canImport(HarnessISH)
        if ISHKernel.shared.isBooted {
            let enabled = guestNetworkEnabled || !guestNetworkLeases.isEmpty
            let wasEnabled = ISHKernel.shared.guestNetworkEnabled
            ISHKernel.shared.guestNetworkEnabled = enabled
            if enabled, !wasEnabled {
                refreshGuestDNS()
            }
        }
#endif
    }

    func updateExecutionEnvironment(isBackgrounded: Bool) {
        self.isBackgrounded = isBackgrounded
        applyExecutionLimits(currentLimits())
    }

    private func currentLimits() -> RuntimeResourceLimits {
        RuntimeResourceGovernor.limits(
            for: RuntimeResourceGovernor.currentSignals(isBackgrounded: isBackgrounded)
        )
    }

    private func applyExecutionLimits(_ limits: RuntimeResourceLimits) {
#if os(iOS) && canImport(HarnessISH)
        guard ISHKernel.shared.isBooted else { return }
        if limits.emulatorDutyCycle >= 0.99 {
            ISHKernel.shared.disableCPUThrottle()
        } else {
            ISHKernel.shared.enableCPUThrottle(
                withDutyCycle: Float(limits.emulatorDutyCycle)
            )
        }
#endif
    }

#if os(iOS) && canImport(HarnessISH)
    private func reconcileWorkspaceMounts() {
        guard ISHKernel.shared.isBooted, mountedWorkspacePath != nil else { return }

        for guestPath in Array(mountedWorkspaceMounts.keys) {
            guard let mounted = mountedWorkspaceMounts[guestPath],
                  configuredWorkspaceMounts[guestPath] != mounted else { continue }
            _ = ISHKernel.shared.bindUnmountPath(guestPath)
            mountedWorkspaceMounts.removeValue(forKey: guestPath)
        }

        workspaceMountFailures = workspaceMountFailures.filter {
            configuredWorkspaceMounts[$0.key] != nil
        }
        for (guestPath, binding) in configuredWorkspaceMounts.sorted(by: {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }) {
            guard mountedWorkspaceMounts[guestPath] != binding else {
                workspaceMountFailures.removeValue(forKey: guestPath)
                continue
            }
            let mkdirResult = ISHShellExecutor.executeCommandSync(
                "mkdir -p -- \(Self.shellQuoted(guestPath))",
                timeout: 10,
                lineCallback: nil
            )
            guard mkdirResult.exitCode == 0 else {
                workspaceMountFailures[guestPath] = Int32(mkdirResult.exitCode)
                continue
            }
            let result = ISHKernel.shared.bindMountPath(
                guestPath,
                toHostPath: binding.hostURL.standardizedFileURL.path,
                readOnly: binding.readOnly
            )
            guard result >= 0 else {
                workspaceMountFailures[guestPath] = result
                continue
            }
            mountedWorkspaceMounts[guestPath] = binding
            workspaceMountFailures.removeValue(forKey: guestPath)
        }
    }

    private func unmountAllWorkspaceMounts() {
        for guestPath in Array(mountedWorkspaceMounts.keys) {
            _ = ISHKernel.shared.bindUnmountPath(guestPath)
        }
        mountedWorkspaceMounts.removeAll()
        workspaceMountFailures.removeAll()
    }
#endif

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ISHBoundedOutput: Sendable, Equatable {
    let stdout: String
    let stderr: String
}

final class ISHOutputLimiter: @unchecked Sendable {
    static let truncationMarker = "\n[output truncated by device resource limit]\n"

    private let lock = NSLock()
    private let maximumBytes: Int
    private let contentBudget: Int
    private let marker: String
    private var forwardedBytes = 0
    private var didTruncate = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(maximumBytes, 1)
        marker = Self.prefix(
            Self.truncationMarker,
            maximumUTF8Bytes: self.maximumBytes
        )
        contentBudget = max(self.maximumBytes - marker.utf8.count, 0)
    }

    func consume(channel: ISHOutputChannel, text: String) -> ISHCommandOutputChunk? {
        guard !text.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard !didTruncate else { return nil }

        let remainingBytes = max(contentBudget - forwardedBytes, 0)
        let boundedText = Self.prefix(text, maximumUTF8Bytes: remainingBytes)
        forwardedBytes += boundedText.utf8.count
        if boundedText.utf8.count < text.utf8.count {
            didTruncate = true
            return ISHCommandOutputChunk(channel: channel, text: boundedText + marker)
        }
        guard !boundedText.isEmpty else { return nil }
        return ISHCommandOutputChunk(channel: channel, text: boundedText)
    }

    static func boundedOutputs(
        stdout: String,
        stderr: String,
        maximumBytes: Int
    ) -> ISHBoundedOutput {
        let maximumBytes = max(maximumBytes, 1)
        let stdoutBytes = stdout.utf8.count
        let stderrBytes = stderr.utf8.count
        guard stdoutBytes + stderrBytes > maximumBytes else {
            return ISHBoundedOutput(stdout: stdout, stderr: stderr)
        }

        let firstHalf = maximumBytes / 2
        var stdoutLimit = min(stdoutBytes, firstHalf)
        var stderrLimit = min(stderrBytes, maximumBytes - firstHalf)
        var remaining = maximumBytes - stdoutLimit - stderrLimit

        let stdoutNeed = stdoutBytes - stdoutLimit
        let stderrNeed = stderrBytes - stderrLimit
        if stdoutNeed >= stderrNeed {
            let addition = min(stdoutNeed, remaining)
            stdoutLimit += addition
            remaining -= addition
            stderrLimit += min(stderrNeed, remaining)
        } else {
            let addition = min(stderrNeed, remaining)
            stderrLimit += addition
            remaining -= addition
            stdoutLimit += min(stdoutNeed, remaining)
        }

        return ISHBoundedOutput(
            stdout: bounded(stdout, maximumUTF8Bytes: stdoutLimit),
            stderr: bounded(stderr, maximumUTF8Bytes: stderrLimit)
        )
    }

    private static func bounded(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        let marker = prefix(truncationMarker, maximumUTF8Bytes: maximumUTF8Bytes)
        let contentLimit = max(maximumUTF8Bytes - marker.utf8.count, 0)
        return prefix(text, maximumUTF8Bytes: contentLimit) + marker
    }

    private static func prefix(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard text.utf8.count > maximumUTF8Bytes else { return text }

        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result
    }
}

#if os(iOS) && canImport(HarnessISH)
/// Serializes native stdout callbacks with the async parser that consumes them.
/// The shell bridge invokes completion independently from line callbacks, so a
/// command is not considered settled until the callbacks already accepted by
/// this drain have finished. The wait is bounded to avoid making cancellation
/// depend on a broken consumer.
private final class ISHOutputDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var queue: [@Sendable () async -> Void] = []
    private var workerRunning = false
    private var pending = 0
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waiterID: UUID?
    private var timeoutTask: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        queue.append(operation)
        pending += 1
        let startWorker = !workerRunning
        workerRunning = true
        lock.unlock()
        if startWorker {
            Task { await drainLoop() }
        }
    }

    func closeAndWait(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            guard pending > 0 else {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiter = continuation
            waiterID = id
            let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            timeoutTask = Task.detached { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                self?.timeoutWaiter(id: id)
            }
            lock.unlock()
        }
    }

    private func drainLoop() async {
        while true {
            guard let operation = takeNext() else { return }
            await operation()
            completeOne()
        }
    }

    private func takeNext() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            workerRunning = false
            return nil
        }
        return queue.removeFirst()
    }

    private func completeOne() {
        let continuation: CheckedContinuation<Bool, Never>?
        let timeoutTask: Task<Void, Never>?
        lock.lock()
        pending -= 1
        if pending == 0, !accepting {
            continuation = waiter
            waiter = nil
            waiterID = nil
            timeoutTask = self.timeoutTask
            self.timeoutTask = nil
        } else {
            continuation = nil
            timeoutTask = nil
        }
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(returning: true)
    }

    private func timeoutWaiter(id: UUID) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        guard waiterID == id else {
            lock.unlock()
            return
        }
        continuation = waiter
        waiter = nil
        waiterID = nil
        timeoutTask = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }
}

private final class ISHCommandExecutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ISHCommandResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pid: Int32 = 0
    private var completed = false
    private var cancelRequested = false
    private let outputDrain: ISHOutputDrain

    init() {
        outputDrain = ISHOutputDrain()
    }

    func start(
        script: String,
        environment: [String: String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        onOutput: @escaping @Sendable (ISHCommandOutputChunk) async -> Void
    ) async throws -> ISHCommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                guard let input = script.data(using: .utf8) else {
                    finish(.failure(ISHSandboxError.invalidCommand))
                    return
                }
                let outputLimiter = ISHOutputLimiter(maximumBytes: maximumOutputBytes)

                let startedPID = ISHShellExecutor.executeExecutable(
                    "/bin/sh",
                    arguments: nil,
                    environment: environment,
                    stdinData: input,
                    fsContext: 0,
                    lineCallback: { [self] line, isStandardError in
                        guard let chunk = outputLimiter.consume(
                            channel: isStandardError ? .stderr : .stdout,
                            text: line + "\n"
                        ) else { return }
                        self.outputDrain.enqueue {
                            await onOutput(chunk)
                        }
                    },
                    completion: { result in
                        let boundedOutput = ISHOutputLimiter.boundedOutputs(
                            stdout: result.output,
                            stderr: result.errorOutput,
                            maximumBytes: maximumOutputBytes
                        )
                        let commandResult = ISHCommandResult(
                            pid: Int32(result.pid),
                            exitCode: ISHExitStatus.normalized(Int(result.exitCode)),
                            stdout: boundedOutput.stdout,
                            stderr: boundedOutput.stderr,
                            duration: result.duration
                        )
                        self.finish(.success(commandResult))
                    }
                )
                guard startedPID >= 0 else {
                    switch ISHShellExecutorError(rawValue: Int(startedPID)) {
                    case .processCreationFailed:
                        finish(.failure(ISHSandboxError.processCreationFailed))
                    case .execFailed:
                        finish(.failure(ISHSandboxError.execFailed))
                    case .timeout:
                        finish(.failure(ISHSandboxError.timedOut(timeout)))
                    case .cancelled:
                        finish(.failure(ISHSandboxError.cancelled))
                    default:
                        finish(.failure(ISHSandboxError.processCreationFailed))
                    }
                    return
                }
                guard setPID(Int32(startedPID)) else { return }
                scheduleTimeout(seconds: timeout)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let processID = pid
        lock.unlock()
        if processID > 1 {
            ISHShellExecutor.killProcessGroup(processID)
        }
        finish(.failure(ISHSandboxError.cancelled))
    }

    private func install(_ continuation: CheckedContinuation<ISHCommandResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    private func setPID(_ pid: Int32) -> Bool {
        lock.lock()
        self.pid = pid
        let shouldTerminate = completed || cancelRequested
        lock.unlock()
        if shouldTerminate, pid > 1 {
            // Cancellation can win the race with do_execve. Re-check after
            // storing the PID so a process created in that window is killed.
            ISHShellExecutor.killProcessGroup(pid)
        }
        return !shouldTerminate
    }

    private func currentPID() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    private func scheduleTimeout(seconds: TimeInterval) {
        lock.lock()
        let shouldSchedule = !completed && !cancelRequested
        lock.unlock()
        guard shouldSchedule else { return }

        let nanoseconds = UInt64(seconds * 1_000_000_000)
        let task = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            let processID = self.currentPID()
            if processID > 1 {
                ISHShellExecutor.killProcessGroup(processID)
            }
            self.finish(.failure(ISHSandboxError.timedOut(seconds)))
        }
        lock.lock()
        if completed || cancelRequested {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    private func finish(_ result: Result<ISHCommandResult, Error>) {
        let continuation: CheckedContinuation<ISHCommandResult, Error>?
        let task: Task<Void, Never>?
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        task = timeoutTask
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        guard let continuation else { return }

        Task {
            // The process completion callback can race the last stdout line.
            // Keep the result/temporary run directory alive until all lines
            // already accepted above have reached their parser/tracker.
            _ = await outputDrain.closeAndWait(timeout: 5)
            continuation.resume(with: result)
        }
    }
}
#else
private final class ISHCommandExecutionBox: @unchecked Sendable {
    func cancel() {}
}
#endif
