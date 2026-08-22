import Foundation

/// Stable identity for one composition entry. This corresponds to Cordis loader `id`,
/// not to a downloaded module path.
struct CordisPluginID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }
}

/// Fiber lifecycle mirrored from the vendored Cordis runtime.
enum CordisPluginState: String, Codable, Sendable, Equatable {
    case pending
    case loading
    case active
    case failed
    case unloading
    case disposed
}

/// Cordis isolates individual service names instead of cloning the whole container.
/// Plugins that share the same label for a service see the same isolated provider.
struct CordisServiceIsolation: Codable, Sendable, Equatable {
    static let root = CordisServiceIsolation()

    var labels: [String: String]

    init(labels: [String: String] = [:]) {
        self.labels = labels
    }

    func label(for serviceName: String) -> String? {
        labels[serviceName]
    }
}

/// A typed view over Cordis' flat, string-named service namespace.
struct CordisServiceKey<Value: Sendable>: Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// A type-safe waterfall checkpoint. Listeners wrap `next`, may transform its result,
/// or deliberately short-circuit it, matching Cordis waterfall semantics.
struct CordisCheckpointKey<Input: Sendable, Output: Sendable>: Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// A typed Cordis event with no waterfall continuation. Events are routed by
/// dispatch mode at the call site, matching the upstream event bus rather than
/// creating one bespoke callback API per lifecycle edge.
struct CordisEventKey<Input: Sendable>: Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

/// A typed event whose listeners can stop a bail dispatch with a value.
struct CordisBailEventKey<Input: Sendable, Output: Sendable>: Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

enum CordisEventScope: Sendable, Hashable, Equatable {
    case global
    case agent(UUID)
}

enum CordisDispatchTarget: Sendable, Equatable {
    case global
    case agent(UUID)
    /// Used by global inventory notifications such as `tools/change`.
    case unfiltered
}

/// Correlates a Cordis dispatch with the native Agent trajectory. Calls outside
/// an Agent run, such as plugin installation or manual management, may omit it.
struct CordisTraceContext: Sendable, Equatable {
    let runID: UUID
    let turn: Int?
    let step: Int?

    init(runID: UUID, turn: Int? = nil, step: Int? = nil) {
        self.runID = runID
        self.turn = turn
        self.step = step
    }
}

enum CordisBailDecision<Output: Sendable>: Sendable {
    case `continue`
    case stop(Output)
}

struct CordisNoPayload: Sendable, Equatable {
    static let value = CordisNoPayload()
}

typealias CordisCheckpointNext<Output: Sendable> = @Sendable () async throws -> Output
typealias CordisCheckpointInterceptor<Input: Sendable, Output: Sendable> = @Sendable (
    Input,
    CordisCheckpointNext<Output>
) async throws -> Output
typealias CordisEventListener<Input: Sendable> = @Sendable (Input) async throws -> Void
typealias CordisBailEventListener<Input: Sendable, Output: Sendable> = @Sendable (
    Input
) async throws -> CordisBailDecision<Output>
typealias CordisDisposer = @Sendable () async throws -> Void

/// Native plugin factory registered by the app or by a built-in module catalog.
/// iOS can hot-reconfigure instances of these factories, but cannot dynamically link
/// newly downloaded Swift machine code. Script/process plugins belong behind an iSH service.
struct CordisPluginDefinition: Sendable {
    let id: CordisPluginID
    let version: String
    let dependencies: Set<String>
    let provides: Set<String>
    let isolation: CordisServiceIsolation
    let activate: @Sendable (CordisPluginContext) async throws -> Void

    init(
        id: CordisPluginID,
        version: String,
        dependencies: Set<String> = [],
        provides: Set<String> = [],
        isolation: CordisServiceIsolation = .root,
        activate: @escaping @Sendable (CordisPluginContext) async throws -> Void
    ) {
        self.id = id
        self.version = version
        self.dependencies = dependencies
        self.provides = provides
        self.isolation = isolation
        self.activate = activate
    }
}

struct CordisPluginSnapshot: Codable, Sendable, Equatable {
    let id: CordisPluginID
    let version: String
    let state: CordisPluginState
    let isEnabled: Bool
    let dependencies: [String]
    let provides: [String]
    let missingDependencies: [String]
    let generation: UInt64
    let error: String?
}

/// An effect remains owned by its plugin even when the caller drops this handle.
/// The handle only enables early disposal, as Cordis registration APIs do.
struct CordisEffectHandle: Sendable {
    private let disposeAction: @Sendable () async -> Void

    fileprivate init(disposeAction: @escaping @Sendable () async -> Void) {
        self.disposeAction = disposeAction
    }

    func dispose() async {
        await disposeAction()
    }
}

enum CordisPluginRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidPluginID(String)
    case invalidServiceName(String)
    case duplicatePlugin(CordisPluginID)
    case unknownPlugin(CordisPluginID)
    case inactivePluginContext(CordisPluginID)
    case duplicateService(String)
    case serviceUnavailable(String)
    case serviceTypeMismatch(name: String, expected: String, actual: String)
    case checkpointTypeMismatch(String)
    case eventTypeMismatch(String)
    case eventDispatchFailed(name: String, errors: [String])
    case replacementIDMismatch(expected: CordisPluginID, actual: CordisPluginID)
    case replacementRolledBack(plugin: CordisPluginID, error: String)
    case rollbackFailed(plugin: CordisPluginID, replacementError: String, rollbackError: String)

    var errorDescription: String? {
        switch self {
        case let .invalidPluginID(id):
            return "Invalid Cordis plugin id: \(id)"
        case let .invalidServiceName(name):
            return "Invalid Cordis service name: \(name)"
        case let .duplicatePlugin(id):
            return "Cordis plugin \(id.rawValue) is already installed."
        case let .unknownPlugin(id):
            return "Cordis plugin \(id.rawValue) is not installed."
        case let .inactivePluginContext(id):
            return "Cordis plugin \(id.rawValue) no longer owns an active context."
        case let .duplicateService(name):
            return "Cordis service \(name) already has a provider in this isolation scope."
        case let .serviceUnavailable(name):
            return "Cordis service \(name) is unavailable in this isolation scope."
        case let .serviceTypeMismatch(name, expected, actual):
            return "Cordis service \(name) has type \(actual), expected \(expected)."
        case let .checkpointTypeMismatch(name):
            return "Cordis checkpoint \(name) was registered or invoked with conflicting types."
        case let .eventTypeMismatch(name):
            return "Cordis event \(name) was registered or dispatched with conflicting types."
        case let .eventDispatchFailed(name, errors):
            return "Cordis event \(name) had \(errors.count) listener failure(s): \(errors.joined(separator: " | "))"
        case let .replacementIDMismatch(expected, actual):
            return "Replacement plugin id \(actual.rawValue) does not match \(expected.rawValue)."
        case let .replacementRolledBack(plugin, error):
            return "Cordis replacement for \(plugin.rawValue) failed and was rolled back: \(error)"
        case let .rollbackFailed(plugin, replacementError, rollbackError):
            return "Cordis replacement for \(plugin.rawValue) failed (\(replacementError)); rollback also failed (\(rollbackError))."
        }
    }
}

/// Plugin-scoped capability surface. Every registration is tied to the exact
/// plugin generation, so stale async work cannot mutate a reloaded instance.
struct CordisPluginContext: Sendable {
    let pluginID: CordisPluginID

    private let runtime: CordisPluginRuntime
    private let owner: CordisPluginOwner

    fileprivate init(runtime: CordisPluginRuntime, owner: CordisPluginOwner) {
        self.runtime = runtime
        self.owner = owner
        pluginID = owner.id
    }

    @discardableResult
    func effect(
        _ label: String,
        acquire: @escaping @Sendable () async throws -> CordisDisposer?
    ) async throws -> CordisEffectHandle {
        let disposer = try await acquire()
        guard let disposer else {
            return CordisEffectHandle(disposeAction: {})
        }
        do {
            return try await runtime.registerCleanup(owner: owner, label: label, disposer: disposer)
        } catch {
            try? await disposer()
            throw error
        }
    }

    @discardableResult
    func onDispose(
        _ label: String,
        _ disposer: @escaping CordisDisposer
    ) async throws -> CordisEffectHandle {
        try await runtime.registerCleanup(owner: owner, label: label, disposer: disposer)
    }

    @discardableResult
    func provide<Value: Sendable>(
        _ key: CordisServiceKey<Value>,
        value: Value
    ) async throws -> CordisEffectHandle {
        try await runtime.registerService(owner: owner, key: key, value: value)
    }

    func service<Value: Sendable>(_ key: CordisServiceKey<Value>) async throws -> Value {
        try await runtime.service(owner: owner, key: key)
    }

    func optionalService<Value: Sendable>(_ key: CordisServiceKey<Value>) async throws -> Value? {
        try await runtime.optionalService(owner: owner, key: key)
    }

    /// Register an event listener owned by this plugin generation. The listener
    /// is removed automatically when the plugin unloads.
    @discardableResult
    func on<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        scope: CordisEventScope = .global,
        prepend: Bool = false,
        label: String? = nil,
        _ listener: @escaping CordisEventListener<Input>
    ) async throws -> CordisEffectHandle {
        try await runtime.registerEventListener(
            owner: owner,
            event: event,
            scope: scope,
            prepend: prepend,
            label: label ?? "on(\(event.name))",
            listener: listener
        )
    }

    /// Register a listener for a bail-style event. Returning `.stop` ends the
    /// dispatch and returns its payload to the caller.
    @discardableResult
    func on<Input: Sendable, Output: Sendable>(
        _ event: CordisBailEventKey<Input, Output>,
        scope: CordisEventScope = .global,
        prepend: Bool = false,
        label: String? = nil,
        _ listener: @escaping CordisBailEventListener<Input, Output>
    ) async throws -> CordisEffectHandle {
        try await runtime.registerBailEventListener(
            owner: owner,
            event: event,
            scope: scope,
            prepend: prepend,
            label: label ?? "on(\(event.name))",
            listener: listener
        )
    }

    func emit<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async {
        await runtime.emit(event, input: input, target: target)
    }

    func parallel<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws {
        try await runtime.parallel(event, input: input, target: target)
    }

    func serial<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws {
        try await runtime.serial(event, input: input, target: target)
    }

    func bail<Input: Sendable, Output: Sendable>(
        _ event: CordisBailEventKey<Input, Output>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws -> Output? {
        try await runtime.bail(event, input: input, target: target)
    }

    /// Invoke a plugin-defined waterfall from an active plugin context. This is
    /// the consumer-side counterpart to `intercept` and keeps optional policy
    /// plugins decoupled from the service or tool that emits the decision point.
    func waterfall<Input: Sendable, Output: Sendable>(
        _ checkpoint: CordisCheckpointKey<Input, Output>,
        input: Input,
        target: CordisDispatchTarget = .global,
        default defaultHandler: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await runtime.run(
            checkpoint,
            input: input,
            target: target,
            default: defaultHandler
        )
    }

    @discardableResult
    func intercept<Input: Sendable, Output: Sendable>(
        _ checkpoint: CordisCheckpointKey<Input, Output>,
        scope: CordisEventScope = .global,
        prepend: Bool = false,
        label: String? = nil,
        _ interceptor: @escaping CordisCheckpointInterceptor<Input, Output>
    ) async throws -> CordisEffectHandle {
        try await runtime.registerInterceptor(
            owner: owner,
            checkpoint: checkpoint,
            scope: scope,
            prepend: prepend,
            label: label ?? "intercept(\(checkpoint.name))",
            interceptor: interceptor
        )
    }
}

private struct CordisPluginOwner: Hashable, Sendable {
    let id: CordisPluginID
    let generation: UInt64
}

private struct CordisServiceSlot: Hashable, Sendable {
    let name: String
    let isolationLabel: String?
}

private struct CordisServiceValue: Sendable {
    let value: any Sendable
    let typeName: String
}

private struct AnyCordisEventListener: Sendable {
    let id: UUID
    let owner: CordisPluginOwner
    let eventName: String
    let scope: CordisEventScope
    let prepend: Bool
    let invoke: @Sendable (any Sendable) async throws -> Void
}

private struct AnyCordisBailEventListener: Sendable {
    let id: UUID
    let owner: CordisPluginOwner
    let eventName: String
    let scope: CordisEventScope
    let prepend: Bool
    let invoke: @Sendable (any Sendable) async throws -> (any Sendable)?
}

private struct CordisServiceRegistration: Sendable {
    let owner: CordisPluginOwner
    let value: CordisServiceValue
}

private struct AnyCordisInterceptor: Sendable {
    let id: UUID
    let owner: CordisPluginOwner
    let checkpointName: String
    let scope: CordisEventScope
    let prepend: Bool
    let label: String
    let invoke: @Sendable (
        any Sendable,
        @escaping @Sendable () async throws -> any Sendable
    ) async throws -> any Sendable
}

/// Retains the downstream outcome so a stale interceptor can be removed from a
/// running waterfall without executing the remaining chain a second time.
private enum CordisCheckpointContinuationOutcome: Sendable {
    case notInvoked
    case succeeded(any Sendable)
    case failed(any Error)
}

private actor CordisCheckpointContinuationCapture {
    private var outcome = CordisCheckpointContinuationOutcome.notInvoked

    func recordSuccess(_ value: any Sendable) {
        outcome = .succeeded(value)
    }

    func recordFailure(_ error: any Error) {
        outcome = .failed(error)
    }

    func snapshot() -> CordisCheckpointContinuationOutcome {
        outcome
    }
}

private enum CordisPluginEffectKind: Sendable {
    case cleanup(CordisDisposer)
    case service(slot: CordisServiceSlot, value: CordisServiceValue)
    case event(AnyCordisEventListener)
    case bailEvent(AnyCordisBailEventListener)
    case interceptor(AnyCordisInterceptor)
}

private struct CordisPluginEffect: Sendable {
    let id: UUID
    let label: String
    var isCommitted: Bool
    let kind: CordisPluginEffectKind
}

private struct CordisPluginRecord: Sendable {
    var definition: CordisPluginDefinition
    var state: CordisPluginState
    var isEnabled: Bool
    var generation: UInt64
    var effects: [CordisPluginEffect]
    var boundServices: [CordisServiceSlot: CordisPluginOwner]
    var error: String?
}

/// Actor-owned Cordis-like kernel. It keeps mutable plugin/service/interceptor state
/// off the main actor and validates every callback against its fiber generation.
actor CordisPluginRuntime {
    typealias TraceHandler = @Sendable (HarnessTraceDraft) async -> Void

    private var plugins: [CordisPluginID: CordisPluginRecord] = [:]
    private var services: [CordisServiceSlot: CordisServiceRegistration] = [:]
    private var serviceReservations: [CordisServiceSlot: CordisPluginOwner] = [:]
    private var eventListeners: [String: [AnyCordisEventListener]] = [:]
    private var bailEventListeners: [String: [AnyCordisBailEventListener]] = [:]
    private var interceptors: [String: [AnyCordisInterceptor]] = [:]
    private let traceHandler: TraceHandler

    private var isReconciling = false
    private var reconcileRequested = false

    init(traceHandler: @escaping TraceHandler = { _ in }) {
        self.traceHandler = traceHandler
    }

    @discardableResult
    func install(
        _ definition: CordisPluginDefinition,
        enabled: Bool = true
    ) async throws -> CordisPluginSnapshot {
        try Self.validate(definition)
        guard plugins[definition.id] == nil else {
            throw CordisPluginRuntimeError.duplicatePlugin(definition.id)
        }
        plugins[definition.id] = CordisPluginRecord(
            definition: definition,
            state: .pending,
            isEnabled: enabled,
            generation: 0,
            effects: [],
            boundServices: [:],
            error: nil
        )
        await emitPluginState(definition.id, from: nil, to: .pending, error: nil)
        await reconcile()
        return try snapshot(for: definition.id)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for id: CordisPluginID) async throws -> CordisPluginSnapshot {
        guard var record = plugins[id] else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        record.isEnabled = enabled
        if enabled, record.state == .failed {
            record.state = .pending
            record.error = nil
        }
        plugins[id] = record
        await reconcile()
        return try snapshot(for: id)
    }

    @discardableResult
    func restart(_ id: CordisPluginID) async throws -> CordisPluginSnapshot {
        guard plugins[id] != nil else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        await unload(id, nextState: .pending)
        if var record = plugins[id] {
            record.error = nil
            plugins[id] = record
        }
        await reconcile()
        return try snapshot(for: id)
    }

    /// Replace one native factory without restarting the whole host. If a currently
    /// active plugin's replacement fails during activation, the prior factory is
    /// restored and its dependants reconnect through normal service reconciliation.
    @discardableResult
    func replace(
        _ id: CordisPluginID,
        with replacement: CordisPluginDefinition,
        rollbackOnFailure: Bool = true
    ) async throws -> CordisPluginSnapshot {
        guard replacement.id == id else {
            throw CordisPluginRuntimeError.replacementIDMismatch(expected: id, actual: replacement.id)
        }
        try Self.validate(replacement)
        guard let original = plugins[id] else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        let shouldRollback = rollbackOnFailure && original.state == .active && original.isEnabled

        await unload(id, nextState: .pending)
        guard var candidate = plugins[id] else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        candidate.definition = replacement
        candidate.state = .pending
        candidate.error = nil
        plugins[id] = candidate
        await reconcile()

        guard shouldRollback,
              let failed = plugins[id],
              failed.state == .failed else {
            return try snapshot(for: id)
        }

        let replacementError = failed.error ?? "unknown activation failure"
        await unload(id, nextState: .pending)
        guard var rollback = plugins[id] else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        rollback.definition = original.definition
        rollback.state = .pending
        rollback.error = nil
        rollback.isEnabled = original.isEnabled
        plugins[id] = rollback
        await reconcile()

        if let restored = plugins[id], restored.state == .active {
            throw CordisPluginRuntimeError.replacementRolledBack(
                plugin: id,
                error: replacementError
            )
        }
        throw CordisPluginRuntimeError.rollbackFailed(
            plugin: id,
            replacementError: replacementError,
            rollbackError: plugins[id]?.error ?? "rollback did not become active"
        )
    }

    @discardableResult
    func uninstall(_ id: CordisPluginID) async throws -> CordisPluginSnapshot {
        guard plugins[id] != nil else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        await unload(id, nextState: .disposed)
        let result = try snapshot(for: id)
        plugins.removeValue(forKey: id)
        await reconcile()
        return result
    }

    func snapshot(for id: CordisPluginID) throws -> CordisPluginSnapshot {
        guard let record = plugins[id] else {
            throw CordisPluginRuntimeError.unknownPlugin(id)
        }
        return makeSnapshot(id: id, record: record)
    }

    func snapshots() -> [CordisPluginSnapshot] {
        plugins.map { makeSnapshot(id: $0.key, record: $0.value) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Resolve a root or explicitly isolated service from host code. Plugin code
    /// should use `CordisPluginContext.service` so dependency generation checks
    /// remain attached to its fiber.
    func resolveService<Value: Sendable>(
        _ key: CordisServiceKey<Value>,
        isolationLabel: String? = nil
    ) throws -> Value {
        try Self.validateServiceName(key.name)
        let slot = CordisServiceSlot(name: key.name, isolationLabel: isolationLabel)
        guard let service = services[slot]?.value else {
            throw CordisPluginRuntimeError.serviceUnavailable(key.name)
        }
        guard let typed = service.value as? Value else {
            throw CordisPluginRuntimeError.serviceTypeMismatch(
                name: key.name,
                expected: String(reflecting: Value.self),
                actual: service.typeName
            )
        }
        return typed
    }

    func run<Input: Sendable, Output: Sendable>(
        _ checkpoint: CordisCheckpointKey<Input, Output>,
        input: Input,
        target: CordisDispatchTarget = .global,
        traceContext: CordisTraceContext? = nil,
        default defaultHandler: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let hooks = (interceptors[checkpoint.name] ?? []).filter {
            Self.matches(scope: $0.scope, target: target)
        }
        let startedAt = Date.now
        var traceAttributes = Self.checkpointTraceAttributes(
            hooks: hooks,
            target: target,
            input: input
        )
        if let projectedInput = CordisHarnessTraceProjection.value(input) {
            traceAttributes["input"] = projectedInput
        }
        await traceHandler(
            HarnessTraceDraft(
                kind: .checkpointStarted,
                timestamp: startedAt,
                runID: traceContext?.runID,
                turn: traceContext?.turn,
                step: traceContext?.step,
                name: checkpoint.name,
                attributes: traceAttributes
            )
        )

        let next: @Sendable () async throws -> any Sendable = {
            try await defaultHandler()
        }

        do {
            let result = try await invokeCheckpoint(
                hooks,
                input: input,
                fallback: next
            )
            guard let typed = result as? Output else {
                throw CordisPluginRuntimeError.checkpointTypeMismatch(checkpoint.name)
            }
            var finishedAttributes = traceAttributes
            finishedAttributes["outputType"] = .string(String(reflecting: Output.self))
            if let projectedOutput = CordisHarnessTraceProjection.value(typed) {
                finishedAttributes["output"] = projectedOutput
            }
            await traceHandler(
                HarnessTraceDraft(
                    kind: .checkpointFinished,
                    timestamp: .now,
                    runID: traceContext?.runID,
                    turn: traceContext?.turn,
                    step: traceContext?.step,
                    name: checkpoint.name,
                    durationMilliseconds: Date.now.timeIntervalSince(startedAt) * 1_000,
                    attributes: finishedAttributes
                )
            )
            return typed
        } catch {
            await traceHandler(
                HarnessTraceDraft(
                    kind: .checkpointFailed,
                    timestamp: .now,
                    runID: traceContext?.runID,
                    turn: traceContext?.turn,
                    step: traceContext?.step,
                    name: checkpoint.name,
                    durationMilliseconds: Date.now.timeIntervalSince(startedAt) * 1_000,
                    attributes: traceAttributes,
                    error: String(describing: error)
                )
            )
            throw error
        }
    }

    /// Fire-and-forget notification mode. Every matching listener gets its own
    /// task; failures are contained and written to the local trace ledger.
    func emit<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) {
        let listeners = (eventListeners[event.name] ?? []).filter {
            Self.matches(scope: $0.scope, target: target)
        }
        let traceHandler = traceHandler
        for listener in listeners {
            Task { [runtime = self] in
                do {
                    try await runtime.invokeEventListener(listener, input: input)
                } catch {
                    await traceHandler(
                        HarnessTraceDraft(
                            kind: .error,
                            pluginID: listener.owner.id.rawValue,
                            name: "cordis/event/\(event.name)",
                            error: String(describing: error)
                        )
                    )
                }
            }
        }
    }

    /// Await all matching listeners and report every failure after all have
    /// settled, mirroring Cordis `parallel` rather than fail-fast task groups.
    func parallel<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws {
        let listeners = (eventListeners[event.name] ?? []).filter {
            Self.matches(scope: $0.scope, target: target)
        }
        let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for listener in listeners {
                group.addTask { [runtime = self] in
                    do {
                        try await runtime.invokeEventListener(listener, input: input)
                        return nil
                    } catch {
                        return "\(listener.owner.id.rawValue): \(error)"
                    }
                }
            }
            var errors: [String] = []
            for await failure in group {
                if let failure { errors.append(failure) }
            }
            return errors
        }
        guard failures.isEmpty else {
            throw CordisPluginRuntimeError.eventDispatchFailed(
                name: event.name,
                errors: failures
            )
        }
    }

    /// Await matching listeners in registration order. This is the mode used by
    /// `agent/turn-stopping`, where a listener may schedule more work before the
    /// agent examines its inbox again.
    func serial<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws {
        let listeners = (eventListeners[event.name] ?? []).filter {
            Self.matches(scope: $0.scope, target: target)
        }
        for listener in listeners {
            try await invokeEventListener(listener, input: input)
        }
    }

    /// Await bail listeners in registration order and return the first explicit
    /// stop value. `nil` means every listener delegated.
    func bail<Input: Sendable, Output: Sendable>(
        _ event: CordisBailEventKey<Input, Output>,
        input: Input,
        target: CordisDispatchTarget = .global
    ) async throws -> Output? {
        let listeners = (bailEventListeners[event.name] ?? []).filter {
            Self.matches(scope: $0.scope, target: target)
        }
        for listener in listeners {
            let raw = try await invokeBailEventListener(listener, input: input)
            guard let raw else { continue }
            guard let decision = raw as? CordisBailDecision<Output> else {
                throw CordisPluginRuntimeError.eventTypeMismatch(event.name)
            }
            if case let .stop(value) = decision {
                return value
            }
        }
        return nil
    }

    fileprivate func registerCleanup(
        owner: CordisPluginOwner,
        label: String,
        disposer: @escaping CordisDisposer
    ) throws -> CordisEffectHandle {
        try registerEffect(
            owner: owner,
            label: label,
            kind: .cleanup(disposer)
        )
    }

    fileprivate func registerService<Value: Sendable>(
        owner: CordisPluginOwner,
        key: CordisServiceKey<Value>,
        value: Value
    ) throws -> CordisEffectHandle {
        try Self.validateServiceName(key.name)
        let slot = try serviceSlot(owner: owner, name: key.name)
        if let reserved = serviceReservations[slot], reserved != owner {
            throw CordisPluginRuntimeError.duplicateService(key.name)
        }
        if serviceReservations[slot] == owner {
            throw CordisPluginRuntimeError.duplicateService(key.name)
        }

        let service = CordisServiceValue(
            value: value,
            typeName: String(reflecting: Value.self)
        )
        serviceReservations[slot] = owner
        do {
            return try registerEffect(
                owner: owner,
                label: "provide(\(key.name))",
                kind: .service(slot: slot, value: service)
            )
        } catch {
            if serviceReservations[slot] == owner {
                serviceReservations.removeValue(forKey: slot)
            }
            throw error
        }
    }

    fileprivate func registerEventListener<Input: Sendable>(
        owner: CordisPluginOwner,
        event: CordisEventKey<Input>,
        scope: CordisEventScope,
        prepend: Bool,
        label: String,
        listener: @escaping CordisEventListener<Input>
    ) throws -> CordisEffectHandle {
        try Self.validateServiceName(event.name)
        let erased = AnyCordisEventListener(
            id: UUID(),
            owner: owner,
            eventName: event.name,
            scope: scope,
            prepend: prepend,
            invoke: { rawInput in
                guard let input = rawInput as? Input else {
                    throw CordisPluginRuntimeError.eventTypeMismatch(event.name)
                }
                try await listener(input)
            }
        )
        return try registerEffect(
            owner: owner,
            label: label,
            kind: .event(erased),
            prependEvent: prepend
        )
    }

    fileprivate func registerBailEventListener<Input: Sendable, Output: Sendable>(
        owner: CordisPluginOwner,
        event: CordisBailEventKey<Input, Output>,
        scope: CordisEventScope,
        prepend: Bool,
        label: String,
        listener: @escaping CordisBailEventListener<Input, Output>
    ) throws -> CordisEffectHandle {
        try Self.validateServiceName(event.name)
        let erased = AnyCordisBailEventListener(
            id: UUID(),
            owner: owner,
            eventName: event.name,
            scope: scope,
            prepend: prepend,
            invoke: { rawInput in
                guard let input = rawInput as? Input else {
                    throw CordisPluginRuntimeError.eventTypeMismatch(event.name)
                }
                return try await listener(input)
            }
        )
        return try registerEffect(
            owner: owner,
            label: label,
            kind: .bailEvent(erased),
            prependEvent: prepend
        )
    }

    fileprivate func service<Value: Sendable>(
        owner: CordisPluginOwner,
        key: CordisServiceKey<Value>
    ) throws -> Value {
        guard let value: Value = try optionalService(owner: owner, key: key) else {
            throw CordisPluginRuntimeError.serviceUnavailable(key.name)
        }
        return value
    }

    fileprivate func optionalService<Value: Sendable>(
        owner: CordisPluginOwner,
        key: CordisServiceKey<Value>
    ) throws -> Value? {
        try Self.validateServiceName(key.name)
        let slot = try serviceSlot(owner: owner, name: key.name)
        guard let record = plugins[owner.id],
              record.generation == owner.generation,
              record.state == .loading || record.state == .active else {
            throw CordisPluginRuntimeError.inactivePluginContext(owner.id)
        }

        let ownValue = record.effects.reversed().compactMap { effect -> CordisServiceValue? in
            guard case let .service(candidate, value) = effect.kind,
                  candidate == slot else { return nil }
            return value
        }.first
        let resolved = ownValue ?? services[slot]?.value
        guard let resolved else { return nil }
        guard let typed = resolved.value as? Value else {
            throw CordisPluginRuntimeError.serviceTypeMismatch(
                name: key.name,
                expected: String(reflecting: Value.self),
                actual: resolved.typeName
            )
        }
        return typed
    }

    fileprivate func registerInterceptor<Input: Sendable, Output: Sendable>(
        owner: CordisPluginOwner,
        checkpoint: CordisCheckpointKey<Input, Output>,
        scope: CordisEventScope,
        prepend: Bool,
        label: String,
        interceptor: @escaping CordisCheckpointInterceptor<Input, Output>
    ) throws -> CordisEffectHandle {
        let erased = AnyCordisInterceptor(
            id: UUID(),
            owner: owner,
            checkpointName: checkpoint.name,
            scope: scope,
            prepend: prepend,
            label: label,
            invoke: { rawInput, rawNext in
                guard let input = rawInput as? Input else {
                    throw CordisPluginRuntimeError.checkpointTypeMismatch(checkpoint.name)
                }
                let output = try await interceptor(input) {
                    let rawOutput = try await rawNext()
                    guard let typed = rawOutput as? Output else {
                        throw CordisPluginRuntimeError.checkpointTypeMismatch(checkpoint.name)
                    }
                    return typed
                }
                return output
            }
        )
        return try registerEffect(
            owner: owner,
            label: label,
            kind: .interceptor(erased),
            prependInterceptor: prepend
        )
    }

    private func registerEffect(
        owner: CordisPluginOwner,
        label: String,
        kind: CordisPluginEffectKind,
        prependInterceptor: Bool = false,
        prependEvent: Bool = false
    ) throws -> CordisEffectHandle {
        guard var record = plugins[owner.id],
              record.generation == owner.generation,
              record.isEnabled,
              record.state == .loading || record.state == .active else {
            throw CordisPluginRuntimeError.inactivePluginContext(owner.id)
        }

        let effect = CordisPluginEffect(
            id: UUID(),
            label: label,
            isCommitted: record.state == .active,
            kind: kind
        )
        record.effects.append(effect)
        plugins[owner.id] = record

        if effect.isCommitted {
            commit(
                effect,
                owner: owner,
                prependInterceptor: prependInterceptor,
                prependEvent: prependEvent
            )
            reconcileRequested = true
        }

        return CordisEffectHandle { [runtime = self] in
            await runtime.disposeEffect(owner: owner, effectID: effect.id)
        }
    }

    private func disposeEffect(owner: CordisPluginOwner, effectID: UUID) async {
        guard var record = plugins[owner.id],
              record.generation == owner.generation,
              let index = record.effects.firstIndex(where: { $0.id == effectID }) else {
            return
        }
        let effect = record.effects.remove(at: index)
        plugins[owner.id] = record
        removeCommittedContribution(effect, owner: owner)
        await runCleanup(effect, pluginID: owner.id)
        await reconcile()
    }

    private func reconcile() async {
        reconcileRequested = true
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        while reconcileRequested {
            reconcileRequested = false
            var madeProgress = true
            while madeProgress {
                madeProgress = false

                let invalidActive = plugins.compactMap { id, record -> CordisPluginID? in
                    guard record.state == .active else { return nil }
                    if !record.isEnabled || !dependenciesStillBound(record) {
                        return id
                    }
                    return nil
                }.sorted { $0.rawValue < $1.rawValue }
                for id in invalidActive {
                    await unload(id, nextState: .pending)
                    madeProgress = true
                }

                let ready = plugins.compactMap { id, record -> CordisPluginID? in
                    guard record.state == .pending,
                          record.isEnabled,
                          missingDependencies(for: record).isEmpty else {
                        return nil
                    }
                    return id
                }.sorted { $0.rawValue < $1.rawValue }
                for id in ready {
                    await activate(id)
                    madeProgress = true
                }
            }
        }
    }

    private func activate(_ id: CordisPluginID) async {
        guard var record = plugins[id],
              record.state == .pending,
              record.isEnabled,
              missingDependencies(for: record).isEmpty else { return }

        let oldState = record.state
        record.generation &+= 1
        record.state = .loading
        record.error = nil
        record.effects.removeAll(keepingCapacity: true)
        record.boundServices = resolvedDependencies(for: record)
        plugins[id] = record
        let owner = CordisPluginOwner(id: id, generation: record.generation)
        await emitPluginState(id, from: oldState, to: .loading, error: nil)

        do {
            try await record.definition.activate(
                CordisPluginContext(runtime: self, owner: owner)
            )
        } catch {
            await failActivation(id, owner: owner, error: error)
            return
        }

        guard var current = plugins[id],
              current.generation == owner.generation,
              current.state == .loading else { return }
        guard current.isEnabled,
              missingDependencies(for: current).isEmpty,
              dependenciesMatch(current.boundServices) else {
            await unload(id, nextState: .pending)
            return
        }

        for index in current.effects.indices {
            current.effects[index].isCommitted = true
            commit(current.effects[index], owner: owner)
        }
        current.state = .active
        current.error = nil
        plugins[id] = current
        await emitPluginState(id, from: .loading, to: .active, error: nil)
        reconcileRequested = true
    }

    private func failActivation(
        _ id: CordisPluginID,
        owner: CordisPluginOwner,
        error: Error
    ) async {
        guard var record = plugins[id], record.generation == owner.generation else { return }
        let effects = record.effects.reversed()
        record.effects.removeAll(keepingCapacity: true)
        record.generation &+= 1
        record.state = .failed
        record.boundServices.removeAll(keepingCapacity: true)
        record.error = String(describing: error)
        plugins[id] = record
        for effect in effects {
            removeCommittedContribution(effect, owner: owner)
            await runCleanup(effect, pluginID: id)
        }
        await emitPluginState(id, from: .loading, to: .failed, error: record.error)
        reconcileRequested = true
    }

    private func unload(_ id: CordisPluginID, nextState: CordisPluginState) async {
        guard var record = plugins[id] else { return }
        if record.state == .disposed { return }

        let previousState = record.state
        let owner = CordisPluginOwner(id: id, generation: record.generation)
        record.generation &+= 1
        record.state = .unloading
        let effects = Array(record.effects.reversed())
        record.effects.removeAll(keepingCapacity: true)
        record.boundServices.removeAll(keepingCapacity: true)
        plugins[id] = record

        for effect in effects {
            removeCommittedContribution(effect, owner: owner)
        }
        await emitPluginState(id, from: previousState, to: .unloading, error: nil)
        for effect in effects {
            await runCleanup(effect, pluginID: id)
        }

        guard var current = plugins[id], current.generation == record.generation else { return }
        current.state = nextState
        if nextState != .failed {
            current.error = nil
        }
        plugins[id] = current
        await emitPluginState(id, from: .unloading, to: nextState, error: current.error)
        reconcileRequested = true
    }

    private func commit(
        _ effect: CordisPluginEffect,
        owner: CordisPluginOwner,
        prependInterceptor: Bool = false,
        prependEvent: Bool = false
    ) {
        switch effect.kind {
        case .cleanup:
            break
        case let .service(slot, value):
            services[slot] = CordisServiceRegistration(owner: owner, value: value)
        case let .event(listener):
            var values = eventListeners[listener.eventName] ?? []
            if prependEvent || listener.prepend {
                values.insert(listener, at: 0)
            } else {
                values.append(listener)
            }
            eventListeners[listener.eventName] = values
        case let .bailEvent(listener):
            var values = bailEventListeners[listener.eventName] ?? []
            if prependEvent || listener.prepend {
                values.insert(listener, at: 0)
            } else {
                values.append(listener)
            }
            bailEventListeners[listener.eventName] = values
        case let .interceptor(interceptor):
            var values = interceptors[interceptor.checkpointName] ?? []
            if prependInterceptor || interceptor.prepend {
                values.insert(interceptor, at: 0)
            } else {
                values.append(interceptor)
            }
            interceptors[interceptor.checkpointName] = values
        }
    }

    private func removeCommittedContribution(
        _ effect: CordisPluginEffect,
        owner: CordisPluginOwner
    ) {
        switch effect.kind {
        case .cleanup:
            break
        case let .service(slot, _):
            if services[slot]?.owner == owner {
                services.removeValue(forKey: slot)
            }
            if serviceReservations[slot] == owner {
                serviceReservations.removeValue(forKey: slot)
            }
        case let .event(listener):
            eventListeners[listener.eventName]?.removeAll { $0.id == listener.id }
            if eventListeners[listener.eventName]?.isEmpty == true {
                eventListeners.removeValue(forKey: listener.eventName)
            }
        case let .bailEvent(listener):
            bailEventListeners[listener.eventName]?.removeAll { $0.id == listener.id }
            if bailEventListeners[listener.eventName]?.isEmpty == true {
                bailEventListeners.removeValue(forKey: listener.eventName)
            }
        case let .interceptor(interceptor):
            guard effect.isCommitted else { return }
            interceptors[interceptor.checkpointName]?.removeAll { $0.id == interceptor.id }
            if interceptors[interceptor.checkpointName]?.isEmpty == true {
                interceptors.removeValue(forKey: interceptor.checkpointName)
            }
        }
    }

    private func runCleanup(_ effect: CordisPluginEffect, pluginID: CordisPluginID) async {
        guard case let .cleanup(disposer) = effect.kind else { return }
        do {
            try await disposer()
        } catch {
            await traceHandler(
                HarnessTraceDraft(
                    kind: .pluginCleanupFailed,
                    timestamp: .now,
                    pluginID: pluginID.rawValue,
                    name: effect.label,
                    error: String(describing: error)
                )
            )
        }
    }

    private func dependenciesStillBound(_ record: CordisPluginRecord) -> Bool {
        guard missingDependencies(for: record).isEmpty else { return false }
        return dependenciesMatch(record.boundServices)
    }

    private func dependenciesMatch(
        _ bound: [CordisServiceSlot: CordisPluginOwner]
    ) -> Bool {
        bound.allSatisfy { services[$0.key]?.owner == $0.value }
    }

    private func resolvedDependencies(
        for record: CordisPluginRecord
    ) -> [CordisServiceSlot: CordisPluginOwner] {
        Dictionary(uniqueKeysWithValues: record.definition.dependencies.compactMap { name in
            let slot = CordisServiceSlot(
                name: name,
                isolationLabel: record.definition.isolation.label(for: name)
            )
            guard let owner = services[slot]?.owner else { return nil }
            return (slot, owner)
        })
    }

    private func missingDependencies(for record: CordisPluginRecord) -> [String] {
        record.definition.dependencies.filter { name in
            let slot = CordisServiceSlot(
                name: name,
                isolationLabel: record.definition.isolation.label(for: name)
            )
            return services[slot] == nil
        }.sorted()
    }

    private func serviceSlot(
        owner: CordisPluginOwner,
        name: String
    ) throws -> CordisServiceSlot {
        guard let record = plugins[owner.id],
              record.generation == owner.generation,
              record.state == .loading || record.state == .active else {
            throw CordisPluginRuntimeError.inactivePluginContext(owner.id)
        }
        return CordisServiceSlot(
            name: name,
            isolationLabel: record.definition.isolation.label(for: name)
        )
    }

    private func makeSnapshot(
        id: CordisPluginID,
        record: CordisPluginRecord
    ) -> CordisPluginSnapshot {
        CordisPluginSnapshot(
            id: id,
            version: record.definition.version,
            state: record.state,
            isEnabled: record.isEnabled,
            dependencies: record.definition.dependencies.sorted(),
            provides: record.definition.provides.sorted(),
            missingDependencies: missingDependencies(for: record),
            generation: record.generation,
            error: record.error
        )
    }

    private func emitPluginState(
        _ id: CordisPluginID,
        from oldState: CordisPluginState?,
        to state: CordisPluginState,
        error: String?
    ) async {
        await traceHandler(
            HarnessTraceDraft(
                kind: .pluginStateChanged,
                timestamp: .now,
                pluginID: id.rawValue,
                name: state.rawValue,
                attributes: oldState.map { ["previousState": .string($0.rawValue)] } ?? [:],
                error: error
            )
        )
    }

    private func invokeEventListener<Input: Sendable>(
        _ listener: AnyCordisEventListener,
        input: Input
    ) async throws {
        guard isActiveOwner(listener.owner) else { return }
        do {
            try await listener.invoke(input)
        } catch {
            guard isActiveOwner(listener.owner) else { return }
            throw error
        }
        guard isActiveOwner(listener.owner) else { return }
    }

    private func invokeBailEventListener<Input: Sendable>(
        _ listener: AnyCordisBailEventListener,
        input: Input
    ) async throws -> (any Sendable)? {
        guard isActiveOwner(listener.owner) else { return nil }
        do {
            let result = try await listener.invoke(input)
            guard isActiveOwner(listener.owner) else { return nil }
            return result
        } catch {
            guard isActiveOwner(listener.owner) else { return nil }
            throw error
        }
    }

    private func invokeCheckpoint(
        _ hooks: [AnyCordisInterceptor],
        input: any Sendable,
        fallback: @escaping @Sendable () async throws -> any Sendable
    ) async throws -> any Sendable {
        guard let hook = hooks.first else {
            return try await fallback()
        }
        let tail = Array(hooks.dropFirst())
        guard isActiveOwner(hook.owner) else {
            return try await invokeCheckpoint(tail, input: input, fallback: fallback)
        }

        let continuation = CordisCheckpointContinuationCapture()
        do {
            let result = try await hook.invoke(input) { [runtime = self] in
                do {
                    let downstream = try await runtime.invokeCheckpoint(
                        tail,
                        input: input,
                        fallback: fallback
                    )
                    await continuation.recordSuccess(downstream)
                    return downstream
                } catch {
                    await continuation.recordFailure(error)
                    throw error
                }
            }
            guard isActiveOwner(hook.owner) else {
                return try await resumeAfterStaleInterceptor(
                    continuation,
                    remainingHooks: tail,
                    input: input,
                    fallback: fallback
                )
            }
            return result
        } catch {
            guard isActiveOwner(hook.owner) else {
                return try await resumeAfterStaleInterceptor(
                    continuation,
                    remainingHooks: tail,
                    input: input,
                    fallback: fallback
                )
            }
            throw error
        }
    }

    private func resumeAfterStaleInterceptor(
        _ continuation: CordisCheckpointContinuationCapture,
        remainingHooks: [AnyCordisInterceptor],
        input: any Sendable,
        fallback: @escaping @Sendable () async throws -> any Sendable
    ) async throws -> any Sendable {
        switch await continuation.snapshot() {
        case .notInvoked:
            return try await invokeCheckpoint(
                remainingHooks,
                input: input,
                fallback: fallback
            )
        case let .succeeded(value):
            return value
        case let .failed(error):
            throw error
        }
    }

    private func isActiveOwner(_ owner: CordisPluginOwner) -> Bool {
        guard let record = plugins[owner.id],
              record.generation == owner.generation,
              record.isEnabled else { return false }
        return record.state == .loading || record.state == .active
    }

    private nonisolated static func matches(
        scope: CordisEventScope,
        target: CordisDispatchTarget
    ) -> Bool {
        switch target {
        case .unfiltered:
            return true
        case .global:
            return scope == .global
        case let .agent(agentID):
            switch scope {
            case .global:
                return true
            case let .agent(scopedID):
                return scopedID == agentID
            }
        }
    }

    private nonisolated static func checkpointTraceAttributes(
        hooks: [AnyCordisInterceptor],
        target: CordisDispatchTarget,
        input: any Sendable
    ) -> [String: JSONValue] {
        let chain = hooks.map { hook in
            JSONValue.object([
                "pluginId": .string(hook.owner.id.rawValue),
                "generation": .number(Double(hook.owner.generation)),
                "label": .string(hook.label),
                "scope": .string(scopeDescription(hook.scope)),
                "prepend": .bool(hook.prepend)
            ])
        }
        return [
            "target": .string(targetDescription(target)),
            "handlerCount": .number(Double(hooks.count)),
            "handlers": .array(chain),
            "inputType": .string(String(reflecting: type(of: input)))
        ]
    }

    private nonisolated static func scopeDescription(_ scope: CordisEventScope) -> String {
        switch scope {
        case .global:
            return "global"
        case let .agent(agentID):
            return "agent:\(agentID.uuidString)"
        }
    }

    private nonisolated static func targetDescription(_ target: CordisDispatchTarget) -> String {
        switch target {
        case .global:
            return "global"
        case let .agent(agentID):
            return "agent:\(agentID.uuidString)"
        case .unfiltered:
            return "unfiltered"
        }
    }

    private static func validate(_ definition: CordisPluginDefinition) throws {
        guard !definition.id.rawValue.isEmpty,
              definition.id.rawValue.utf8.count <= 128 else {
            throw CordisPluginRuntimeError.invalidPluginID(definition.id.rawValue)
        }
        for name in definition.dependencies
            .union(definition.provides)
            .union(definition.isolation.labels.keys) {
            try validateServiceName(name)
        }
    }

    private static func validateServiceName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-"
                      || scalar == "_"
                      || scalar == "."
                      || scalar == "/"
              }) else {
            throw CordisPluginRuntimeError.invalidServiceName(name)
        }
    }
}
