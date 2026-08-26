import Foundation

/// Cooperative cancellation reasons are kept separate from Swift task
/// cancellation so a policy can distinguish its own deadline from an outer
/// run cancellation.
enum ToolCancellationReason: Sendable, Equatable {
    case upstream
    case timeout(code: String)
}

/// A small, on-device signal shared by the Cordis execution seam and tool
/// bodies. It notifies listeners but never force-kills work; the execution
/// bridge cancels and awaits a child task so cooperative tools quiesce before a
/// result is returned.
final class ToolCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationReason: ToolCancellationReason?
    private var handlers: [UUID: @Sendable (ToolCancellationReason) -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationReason != nil
    }

    var reason: ToolCancellationReason? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationReason
    }

    init(parent: ToolCancellationSignal? = nil) {
        if let parent {
            parent.observe { [weak self] reason in
                self?.cancel(reason: .upstreamFrom(reason))
            }
        }
    }

    @discardableResult
    func observe(
        _ handler: @escaping @Sendable (ToolCancellationReason) -> Void
    ) -> UUID {
        let id = UUID()
        let existing: ToolCancellationReason?
        lock.lock()
        existing = cancellationReason
        if existing == nil {
            handlers[id] = handler
        }
        lock.unlock()
        if let existing {
            handler(existing)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    @discardableResult
    func cancel(reason: ToolCancellationReason) -> Bool {
        let callbacks: [@Sendable (ToolCancellationReason) -> Void]
        lock.lock()
        guard cancellationReason == nil else {
            lock.unlock()
            return false
        }
        cancellationReason = reason
        callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0(reason) }
        return true
    }

    /// Runs the operation in a child task and waits for it after either signal
    /// or outer task cancellation. A non-cooperative operation therefore stays
    /// pending instead of being abandoned with a delayed side effect.
    func runCooperatively<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let child = Task {
            try await operation()
        }
        let observerID = observe { _ in
            child.cancel()
        }
        defer { removeObserver(observerID) }
        return try await withTaskCancellationHandler(operation: {
            try await child.value
        }, onCancel: {
            _ = cancel(reason: .upstream)
            child.cancel()
        })
    }
}

private extension ToolCancellationReason {
    static func upstreamFrom(_: ToolCancellationReason) -> ToolCancellationReason {
        .upstream
    }
}

/// Copies of `CordisToolExecution` share this box. A tools/execute interceptor
/// can temporarily replace the signal and the default dispatch closure sees
/// that replacement without changing the value passed to post-execute.
final class ToolCancellationSignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ToolCancellationSignal

    init(_ value: ToolCancellationSignal = ToolCancellationSignal()) {
        self.value = value
    }

    func get() -> ToolCancellationSignal {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ value: ToolCancellationSignal) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
