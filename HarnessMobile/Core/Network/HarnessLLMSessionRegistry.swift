import Foundation

/// Owns the network-transition boundary for long-lived model sessions. The
/// registry does not know provider credentials or requests; it only calls a
/// provider's local rotation hook once when the active interface set changes.
final class HarnessLLMSessionRegistry: @unchecked Sendable {
    static let shared = HarnessLLMSessionRegistry()

    private struct Registration {
        let session: URLSession
        let onTransition: @Sendable (String) -> Void
    }

    private let lock = NSLock()
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var lastInterfaceSet: Set<String>?
    private var generation: UInt64 = 0

    private init() {}

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func register(
        _ session: URLSession,
        onTransition: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        registrations[ObjectIdentifier(session)] = Registration(
            session: session,
            onTransition: onTransition
        )
        lock.unlock()
    }

    func unregister(_ session: URLSession) {
        lock.lock()
        registrations.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    /// Returns true only for a real interface-set change. Repeated path ticks
    /// and signal-strength updates leave all model sessions untouched.
    @discardableResult
    func observe(
        interfaceSet: Set<String>,
        isSatisfied: Bool,
        reason: String? = nil
    ) -> Bool {
        let callbacks: [@Sendable (String) -> Void]
        let transitionReason = reason
            ?? (isSatisfied ? "interface-change" : "connectivity-lost")
        lock.lock()
        if lastInterfaceSet == interfaceSet {
            lock.unlock()
            return false
        }
        lastInterfaceSet = interfaceSet
        generation &+= 1
        callbacks = registrations.values.map(\.onTransition)
        lock.unlock()

        callbacks.forEach { $0(transitionReason) }
        return true
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock()
        registrations.removeAll()
        lastInterfaceSet = nil
        generation = 0
        lock.unlock()
    }
    #endif
}

#if canImport(Network)
import Network

/// Bridges NWPathMonitor to the model-session registry. iSH DNS refresh stays
/// in `ISHGuestNetworkMonitor`; this monitor owns only LLM connection rotation.
final class HarnessLLMNetworkPathMonitor: @unchecked Sendable {
    static let shared = HarnessLLMNetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.llf.harnessmobile.llm-network")
    private let lock = NSLock()
    private var started = false

    private init() {}

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        handle(monitor.currentPath)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        HarnessLLMSessionRegistry.shared.observe(
            interfaceSet: Self.activeInterfaceSet(path),
            isSatisfied: path.status == .satisfied
        )
    }

    static func activeInterfaceSet(_ path: NWPath) -> Set<String> {
        let candidates: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"),
            (.cellular, "cellular"),
            (.wiredEthernet, "wired"),
            (.loopback, "loopback"),
            (.other, "other")
        ]
        return Set(candidates.compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil })
    }
}
#else
final class HarnessLLMNetworkPathMonitor: @unchecked Sendable {
    static let shared = HarnessLLMNetworkPathMonitor()
    private init() {}
    func start() {}
}
#endif
