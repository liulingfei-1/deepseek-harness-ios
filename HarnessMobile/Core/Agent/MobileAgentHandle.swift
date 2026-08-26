import Foundation

/// Complete identity for one mobile runtime generation.
///
/// A callback is current only when all three fields match. In particular, a
/// reused session/run pair cannot accept callbacks from an older generation.
struct RunIdentity: Hashable, Codable, Sendable {
    let sessionID: UUID
    let runID: UUID
    let generation: UInt64

    func accepts(_ candidate: RunIdentity) -> Bool {
        self == candidate
    }
}

enum MobileAgentTerminalOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case succeeded
    case cancelled
    case failed
    case interrupted
    case disposed
}

enum MobileAgentPhase: Codable, Sendable, Equatable {
    case idle
    case maintenance
    case running
    case cancelling
    case terminal(MobileAgentTerminalOutcome)

    var isQuiescent: Bool {
        switch self {
        case .idle, .terminal:
            true
        case .maintenance, .running, .cancelling:
            false
        }
    }
}

enum MobileAgentDeliveryKind: String, Codable, Sendable, Equatable {
    case followup
    case steer
    case inject
}

/// Identified input routed through one of the upstream Agent inbox boundaries.
///
/// `QueuedAgentInput` remains the canonical local input value. The kind here is
/// authoritative for routing, so the existing disposition does not need to be
/// rewritten merely to deliver steering or injected context.
struct MobileAgentDelivery: Codable, Sendable, Equatable {
    let kind: MobileAgentDeliveryKind
    let input: QueuedAgentInput
}

struct MobileAgentHandleSnapshot: Codable, Sendable, Equatable {
    let identity: RunIdentity
    let phase: MobileAgentPhase
    let isDisposing: Bool
}

/// Owns the single terminal cleanup path for one run generation.
///
/// The winning outcome is claimed before the async handler is called. Actor
/// reentrancy therefore cannot run cleanup twice; concurrent finishers await
/// the same claimed outcome.
actor MobileAgentTerminalOwner {
    typealias TerminalHandler = @Sendable (
        _ identity: RunIdentity,
        _ outcome: MobileAgentTerminalOutcome
    ) async -> Void

    private enum State: Sendable {
        case open
        case finishing(MobileAgentTerminalOutcome)
        case terminal(MobileAgentTerminalOutcome)
    }

    nonisolated let identity: RunIdentity

    private let terminalHandler: TerminalHandler
    private var state: State = .open
    private var waiters: [CheckedContinuation<MobileAgentTerminalOutcome, Never>] = []

    init(identity: RunIdentity, terminalHandler: @escaping TerminalHandler) {
        self.identity = identity
        self.terminalHandler = terminalHandler
    }

    func finish(_ proposed: MobileAgentTerminalOutcome) async -> MobileAgentTerminalOutcome {
        switch state {
        case .open:
            state = .finishing(proposed)
        case .finishing:
            return await waitForTerminal()
        case let .terminal(outcome):
            return outcome
        }

        await terminalHandler(identity, proposed)

        state = .terminal(proposed)
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: proposed)
        }
        return proposed
    }

    private func waitForTerminal() async -> MobileAgentTerminalOutcome {
        await withCheckedContinuation { continuation in
            switch state {
            case let .terminal(outcome):
                continuation.resume(returning: outcome)
            case .open, .finishing:
                waiters.append(continuation)
            }
        }
    }
}

/// Consumer-owned lifecycle handle for one mobile Agent run generation.
///
/// Cancellation only sends a signal. Runtime/session/plugin cleanup is reached
/// exclusively through `finish`, after the runtime has exited. `dispose`
/// memoizes that stop-and-drain boundary so every owner observes one outcome.
actor MobileAgentHandle {
    typealias DeliveryHandler = @Sendable (MobileAgentDelivery) async -> Void
    typealias CancellationHandler = @Sendable () async -> Void
    typealias QuiescenceHandler = @Sendable () async -> Void
    typealias TerminalHandler = MobileAgentTerminalOwner.TerminalHandler

    nonisolated let identity: RunIdentity

    private let deliveryHandler: DeliveryHandler
    private let cancellationHandler: CancellationHandler
    private let quiescenceHandler: QuiescenceHandler
    private let terminalOwner: MobileAgentTerminalOwner

    private var phase: MobileAgentPhase = .idle
    private var cancellationSignalled = false
    private var disposalStarted = false
    private var disposalOutcome: MobileAgentTerminalOutcome?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var disposalWaiters: [CheckedContinuation<MobileAgentTerminalOutcome, Never>] = []

    init(
        identity: RunIdentity,
        deliveryHandler: @escaping DeliveryHandler = { _ in },
        cancellationHandler: @escaping CancellationHandler = {},
        quiescenceHandler: @escaping QuiescenceHandler = {},
        terminalHandler: @escaping TerminalHandler = { _, _ in }
    ) {
        self.identity = identity
        self.deliveryHandler = deliveryHandler
        self.cancellationHandler = cancellationHandler
        self.quiescenceHandler = quiescenceHandler
        terminalOwner = MobileAgentTerminalOwner(
            identity: identity,
            terminalHandler: terminalHandler
        )
    }

    func snapshot() -> MobileAgentHandleSnapshot {
        MobileAgentHandleSnapshot(
            identity: identity,
            phase: phase,
            isDisposing: disposalStarted
        )
    }

    @discardableResult
    func beginRunning(for callbackIdentity: RunIdentity) -> Bool {
        begin(.running, for: callbackIdentity)
    }

    @discardableResult
    func beginMaintenance(for callbackIdentity: RunIdentity) -> Bool {
        begin(.maintenance, for: callbackIdentity)
    }

    @discardableResult
    func markIdle(for callbackIdentity: RunIdentity) -> Bool {
        guard identity.accepts(callbackIdentity), !disposalStarted else {
            return false
        }
        switch phase {
        case .maintenance, .running:
            phase = .idle
            cancellationSignalled = false
            resumeIdleWaiters()
            return true
        case .idle, .cancelling, .terminal:
            return false
        }
    }

    @discardableResult
    func followup(_ input: QueuedAgentInput) async -> Bool {
        await deliver(input, as: .followup)
    }

    @discardableResult
    func steer(_ input: QueuedAgentInput) async -> Bool {
        await deliver(input, as: .steer)
    }

    @discardableResult
    func inject(_ input: QueuedAgentInput) async -> Bool {
        await deliver(input, as: .inject)
    }

    /// Signals cancellation at most once for the current activity.
    ///
    /// Idle cancellation is intentionally a no-op and does not arm later work.
    @discardableResult
    func cancel() async -> Bool {
        guard !disposalStarted, !cancellationSignalled else {
            return false
        }
        switch phase {
        case .maintenance, .running:
            phase = .cancelling
            cancellationSignalled = true
        case .idle, .cancelling, .terminal:
            return false
        }

        await cancellationHandler()
        return true
    }

    /// Resolves when no driver/maintenance activity remains or the run is terminal.
    func whenIdle() async {
        guard !phase.isQuiescent else { return }
        await withCheckedContinuation { continuation in
            if phase.isQuiescent {
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
            }
        }
    }

    /// Claims the terminal outcome for the current generation and performs its
    /// cleanup once. Stale runtime callbacks are rejected before they can win.
    @discardableResult
    func finish(
        _ proposed: MobileAgentTerminalOutcome,
        for callbackIdentity: RunIdentity
    ) async -> MobileAgentTerminalOutcome? {
        guard identity.accepts(callbackIdentity) else {
            return nil
        }

        let outcome: MobileAgentTerminalOutcome
        switch phase {
        case let .terminal(existing):
            outcome = existing
        case .idle, .maintenance, .running, .cancelling:
            outcome = proposed
            phase = .terminal(proposed)
            resumeIdleWaiters()
        }
        return await terminalOwner.finish(outcome)
    }

    /// Stops, drains, and terminalizes through one memoized owner path.
    @discardableResult
    func dispose() async -> MobileAgentTerminalOutcome {
        if let disposalOutcome {
            return disposalOutcome
        }
        if disposalStarted {
            return await waitForDisposal()
        }
        disposalStarted = true

        if case let .terminal(outcome) = phase {
            let settled = await terminalOwner.finish(outcome)
            completeDisposal(with: settled)
            return settled
        }

        let shouldSignalCancellation: Bool
        switch phase {
        case .maintenance, .running:
            phase = .cancelling
            shouldSignalCancellation = !cancellationSignalled
            cancellationSignalled = true
        case .cancelling:
            shouldSignalCancellation = !cancellationSignalled
            cancellationSignalled = true
        case .idle:
            shouldSignalCancellation = false
        case .terminal:
            shouldSignalCancellation = false
        }

        if shouldSignalCancellation {
            await cancellationHandler()
        }
        await quiescenceHandler()

        // This is the only disposal cleanup edge. A runtime finish that won
        // while stop/drain was awaiting is preserved by `finish`'s CAS.
        let settled = await finish(.disposed, for: identity) ?? .disposed
        completeDisposal(with: settled)
        return settled
    }

    private func begin(
        _ newPhase: MobileAgentPhase,
        for callbackIdentity: RunIdentity
    ) -> Bool {
        guard identity.accepts(callbackIdentity), !disposalStarted, phase == .idle else {
            return false
        }
        phase = newPhase
        cancellationSignalled = false
        return true
    }

    private func deliver(
        _ input: QueuedAgentInput,
        as kind: MobileAgentDeliveryKind
    ) async -> Bool {
        guard !disposalStarted else { return false }
        if case .terminal = phase { return false }
        await deliveryHandler(MobileAgentDelivery(kind: kind, input: input))
        return true
    }

    private func waitForDisposal() async -> MobileAgentTerminalOutcome {
        await withCheckedContinuation { continuation in
            if let outcome = disposalOutcome {
                continuation.resume(returning: outcome)
            } else {
                disposalWaiters.append(continuation)
            }
        }
    }

    private func resumeIdleWaiters() {
        guard phase.isQuiescent else { return }
        let pending = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func completeDisposal(with outcome: MobileAgentTerminalOutcome) {
        disposalOutcome = outcome
        let pending = disposalWaiters
        disposalWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: outcome)
        }
    }
}
