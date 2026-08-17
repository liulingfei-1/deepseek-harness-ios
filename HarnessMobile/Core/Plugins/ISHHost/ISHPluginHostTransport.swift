import Foundation
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

struct ISHPluginHostTransportExit: Sendable, Equatable {
    let exitCode: Int
    let errorCode: Int
}

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
        guard let started = ISHShellExecutor.startPersistentExecutable(
            "/usr/bin/node",
            arguments: ["--expose-internals", entrypoint],
            environment: environment,
            fsContext: 0,
            outputCallback: { data, isStandardError in
                if isStandardError {
                    onStderr(data)
                } else {
                    onStdout(data)
                }
            },
            completion: { result in
                let exit = ISHPluginHostTransportExit(
                    exitCode: Int(result.exitCode),
                    errorCode: result.error.rawValue
                )
                Task {
                    self.clearProcessAfterExit()
                    onExit(exit)
                }
            }
        ) else {
            throw ISHPluginHostError.invalidState("iSH could not start /usr/bin/node for the plugin host.")
        }
        process = started
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
    private func clearProcessAfterExit() {
        process = nil
    }
#endif
}
