import Foundation
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

struct ISHPluginHostTransportExit: Sendable, Equatable {
    let exitCode: Int
    let errorCode: Int
}

#if os(iOS) && canImport(HarnessISH)
/// Bridges the Objective-C iSH completion callback into Swift concurrency.
///
/// HarnessISH invokes completion on its main dispatch queue. A closure created
/// directly inside the transport actor is implicitly actor-isolated by Swift 6,
/// so entering that closure from the iSH queue can abort with
/// `swift_task_checkIsolated`. This relay has no actor isolation; it only copies
/// the Objective-C result and schedules the actor hop explicitly.
private final class ISHPluginHostProcessExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private weak var transport: ISHPersistentPluginHostTransport?
    private let onExit: @Sendable (ISHPluginHostTransportExit) -> Void

    init(
        transport: ISHPersistentPluginHostTransport,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) {
        self.transport = transport
        self.onExit = onExit
    }

    func receive(_ result: ISHShellExecutionResult) {
        lock.lock()
        guard !delivered else {
            lock.unlock()
            return
        }
        delivered = true
        lock.unlock()

        let exit = ISHPluginHostTransportExit(
            exitCode: Int(result.exitCode),
            errorCode: result.error.rawValue
        )
        let pid = Int32(result.pid)
        let transport = transport
        let onExit = onExit
        Task {
            await transport?.handleProcessExit(pid: pid, exit: exit)
            onExit(exit)
        }
    }
}

/// Delivers raw iSH pipe chunks without retaining an actor-isolated closure in
/// HarnessISH's Objective-C callback. The callback itself is deliberately a
/// regular instance method, so Swift does not attach the transport actor's
/// executor to the C/Objective-C entry point.
private final class ISHPluginHostOutputRelay: @unchecked Sendable {
    private let onStdout: @Sendable (Data) -> Void
    private let onStderr: @Sendable (Data) -> Void

    init(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void
    ) {
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    func receive(_ data: Data, isStandardError: Bool) {
        if isStandardError {
            onStderr(data)
        } else {
            onStdout(data)
        }
    }
}
#endif

protocol ISHPluginHostTransport: Sendable {
    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32

    func write(_ data: Data) async throws
    func stop() async
}

actor ISHPersistentPluginHostTransport: ISHPluginHostTransport {
    static let defaultEntrypoint = "/workspace/.harness-mobile/plugin-host/host.mjs"
    private static let stdinReadinessBackoff: [Duration] = [
        .milliseconds(25),
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800),
        .milliseconds(1_600)
    ]

    private let workspaceURL: URL
    private let entrypoint: String
    private let coordinator: ISHSandboxCoordinator

#if os(iOS) && canImport(HarnessISH)
    private var process: ISHShellProcess?
#endif

    init(
        workspaceURL: URL,
        entrypoint: String = ISHPersistentPluginHostTransport.defaultEntrypoint,
        coordinator: ISHSandboxCoordinator = .shared
    ) {
        self.workspaceURL = workspaceURL
        self.entrypoint = entrypoint
        self.coordinator = coordinator
    }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32 {
#if os(iOS) && canImport(HarnessISH)
        guard process == nil else {
            throw ISHPluginHostError.invalidState("The iSH plugin host process is already running.")
        }
        try await coordinator.prepare(workspaceURL: workspaceURL)

        let environment = [
            "HOME": "/root",
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "NODE_ENV": "production",
            // Some iSH/network combinations return an unreachable IPv6
            // address first. Prefer IPv4 for the Host's public HTTPS fetches;
            // this does not affect the native model networking path.
            "NODE_OPTIONS": "--jitless --dns-result-order=ipv4first",
            "HARNESS_PLUGIN_HOST_ON_DEVICE": "1"
        ]
        let outputRelay = ISHPluginHostOutputRelay(onStdout: onStdout, onStderr: onStderr)
        let exitRelay = ISHPluginHostProcessExitRelay(transport: self, onExit: onExit)
        guard let started = ISHShellExecutor.startPersistentExecutable(
            "/usr/bin/node",
            arguments: ["--expose-internals", entrypoint],
            environment: environment,
            fsContext: 0,
            outputCallback: outputRelay.receive,
            completion: exitRelay.receive
        ) else {
            throw ISHPluginHostError.invalidState("iSH could not start /usr/bin/node for the plugin host.")
        }
        process = started
        // The Objective-C bridge can publish the process handle a moment before
        // its persistent stdin pipe is writable. Probe with a real blank JSONL
        // line so the Objective-C bridge must exercise the pipe; the Host
        // deliberately ignores blank lines. This keeps the first JSON-RPC ping
        // from losing a startup race; bounded client-side retry remains
        // responsible for later backpressure.
        let readinessProbe = Data("\n".utf8)
        var stdinReady = started.writeStdin(readinessProbe)
        do {
            for delay in Self.stdinReadinessBackoff where !stdinReady {
                try Task.checkCancellation()
                guard started.isRunning else {
                    process = nil
                    throw ISHPluginHostError.invalidState(
                        "The iSH plugin host exited before stdin became ready."
                    )
                }
                try await Task.sleep(for: delay)
                stdinReady = started.writeStdin(readinessProbe)
            }
            guard stdinReady else {
                process = nil
                started.terminate()
                throw ISHPluginHostError.invalidState(
                    "The iSH plugin host stdin did not become ready after startup."
                )
            }
        } catch {
            process = nil
            started.terminate()
            throw error
        }
        return Int32(started.pid)
#else
        _ = onStdout
        _ = onStderr
        _ = onExit
        throw ISHPluginHostError.unavailable
#endif
    }

    func write(_ data: Data) async throws {
#if os(iOS) && canImport(HarnessISH)
        guard let process, process.isRunning else {
            throw ISHPluginHostError.invalidState("The iSH plugin host process is not running.")
        }
        guard process.writeStdin(data) else {
            throw ISHPluginHostError.transportRejectedWrite
        }
#else
        _ = data
        throw ISHPluginHostError.unavailable
#endif
    }

    func stop() async {
#if os(iOS) && canImport(HarnessISH)
        let running = process
        process = nil
        running?.terminate()
#endif
    }

#if os(iOS) && canImport(HarnessISH)
    fileprivate func handleProcessExit(pid: Int32, exit: ISHPluginHostTransportExit) {
        // A stopped process may report its exit after a new host has already
        // started. Only clear the process that actually produced this result.
        if process?.pid == pid {
            process = nil
        }
    }
#endif
}
