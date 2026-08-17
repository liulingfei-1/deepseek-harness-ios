import Foundation

#if os(iOS)
import Network

/// Mirrors OpenMinis' iSH DNS refresh behavior so guest networking survives
/// Wi-Fi/cellular/VPN changes without restarting the app or plugin Host.
final class ISHGuestNetworkMonitor: @unchecked Sendable {
    static let shared = ISHGuestNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.llf.harnessmobile.ish-network")
    private let lock = NSLock()
    private var isStarted = false

    private init() {}

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        Task {
            await ISHSandboxCoordinator.shared.refreshGuestDNS()
        }
        monitor.pathUpdateHandler = { _ in
            Task {
                await ISHSandboxCoordinator.shared.refreshGuestDNS()
            }
        }
        monitor.start(queue: queue)
    }
}
#else
final class ISHGuestNetworkMonitor: @unchecked Sendable {
    static let shared = ISHGuestNetworkMonitor()

    private init() {}

    func start() {}
}
#endif
