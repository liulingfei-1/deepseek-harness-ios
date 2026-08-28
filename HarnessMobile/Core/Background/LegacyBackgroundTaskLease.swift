import Foundation

#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// Process-level UIKit finite background execution lease.
///
/// UIKit exposes one expiring task handle per process. The Agent runtime has
/// several independent root runs, so this coordinator keeps per-run ownership
/// tokens while sharing one system handle. Releasing a token is idempotent;
/// the system handle ends only after the final token is gone.
@MainActor
final class LegacyBackgroundTaskLease {
    typealias SystemTaskIdentifier = UInt64
    typealias BeginSystemTask = (@escaping @Sendable () -> Void) -> SystemTaskIdentifier?
    typealias EndSystemTask = (SystemTaskIdentifier) -> Void
    typealias ExpirationHandler = (RunIdentity) -> Void

    private struct Owner {
        let identity: RunIdentity
        let expirationHandler: ExpirationHandler
    }

    private let beginSystemTask: BeginSystemTask
    private let endSystemTask: EndSystemTask
    private var owners: [SessionRunBackgroundLeaseToken: Owner] = [:]
    private var systemTaskIdentifier: SystemTaskIdentifier?

    init(
        beginSystemTask: @escaping BeginSystemTask = LegacyBackgroundTaskLease.defaultBeginSystemTask,
        endSystemTask: @escaping EndSystemTask = LegacyBackgroundTaskLease.defaultEndSystemTask
    ) {
        self.beginSystemTask = beginSystemTask
        self.endSystemTask = endSystemTask
    }

    @discardableResult
    func acquire(
        identity: RunIdentity,
        onExpiration: @escaping ExpirationHandler
    ) -> SessionRunBackgroundLeaseToken {
        let token = SessionRunBackgroundLeaseToken()
        owners[token] = Owner(identity: identity, expirationHandler: onExpiration)
        if systemTaskIdentifier == nil {
            beginSharedSystemTask()
        }
        return token
    }

    /// Idempotently releases one run's ownership. This is safe to call from
    /// both survival-leg handoff and terminal cleanup.
    func release(_ token: SessionRunBackgroundLeaseToken) {
        guard owners.removeValue(forKey: token) != nil else { return }
        endSharedSystemTaskIfUnused()
    }

    func releaseAll(for identity: RunIdentity) {
        let tokens = owners.compactMap { token, owner in
            owner.identity == identity ? token : nil
        }
        tokens.forEach(release)
    }

    var activeTokenCount: Int { owners.count }

    var hasSystemTask: Bool { systemTaskIdentifier != nil }

    /// Content-free ownership projection for runtime invariant audits.
    var ownershipSnapshot: [SessionRunBackgroundLeaseToken: RunIdentity] {
        owners.mapValues(\.identity)
    }

    private func beginSharedSystemTask() {
        guard systemTaskIdentifier == nil else { return }
        systemTaskIdentifier = beginSystemTask { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExpiration()
            }
        }
    }

    private func endSharedSystemTaskIfUnused() {
        guard owners.isEmpty, let identifier = systemTaskIdentifier else { return }
        systemTaskIdentifier = nil
        endSystemTask(identifier)
    }

    private func handleExpiration() {
        guard systemTaskIdentifier != nil else { return }
        // UIKit has already expired the handle. Clear only the OS handle;
        // ownership tokens remain until terminal cleanup so registry invariants
        // and later idempotent release calls stay intact.
        systemTaskIdentifier = nil
        let callbacks = owners.values.map { ($0.identity, $0.expirationHandler) }
        callbacks.forEach { identity, callback in
            callback(identity)
        }
    }

    private static let defaultBeginSystemTask: BeginSystemTask = { expiration in
#if os(iOS) && canImport(UIKit)
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Harness Mobile Agent",
            expirationHandler: expiration
        )
        guard identifier != .invalid else { return nil }
        return UInt64(identifier.rawValue)
#else
        _ = expiration
        return nil
#endif
    }

    private static let defaultEndSystemTask: EndSystemTask = { identifier in
#if os(iOS) && canImport(UIKit)
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: Int(identifier))
        )
#else
        _ = identifier
#endif
    }
}
