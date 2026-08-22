import Foundation
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

/// The MCP process boundary is deliberately backed by the vendored iSH
/// persistent-process bridge. There is no host `Process`/fork fallback.
actor ISHMCPStdioTransport: MCPStdioTransport {
    private static let stdinReadinessBackoff: [Duration] = [
        .milliseconds(25),
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800)
    ]

    private let configuration: MCPStdioServerConfiguration
    private let workspaceURL: URL
    private let coordinator: ISHSandboxCoordinator

#if os(iOS) && canImport(HarnessISH)
    private var process: ISHShellProcess?
#endif

    init(
        configuration: MCPStdioServerConfiguration,
        workspaceURL: URL,
        coordinator: ISHSandboxCoordinator = .shared
    ) {
        self.configuration = configuration
        self.workspaceURL = workspaceURL
        self.coordinator = coordinator
    }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
    ) async throws -> Int32 {
        try configuration.validate()
#if os(iOS) && canImport(HarnessISH)
        guard process == nil else {
            throw MCPClientError.invalidState("MCP iSH 进程已经在运行")
        }
        try await coordinator.prepare(workspaceURL: workspaceURL)

        let outputRelay = ISHMCPOutputRelay(
            onStdout: onStdout,
            onStderr: onStderr
        )
        let exitRelay = ISHMCPExitRelay(transport: self, onExit: onExit)
        let environment = Self.guestEnvironment(configuration.env)
        let script = try Self.makeExecScript(
            command: configuration.command,
            args: configuration.args,
            cwd: configuration.cwd
        )

        guard let started = ISHShellExecutor.startPersistentExecutable(
            "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            fsContext: 0,
            outputCallback: outputRelay.receive,
            completion: exitRelay.receive
        ) else {
            throw MCPClientError.transportFailure("iSH 无法启动 MCP 进程")
        }
        process = started

        // The bridge may publish its process handle before the guest stdin
        // queue is ready. An empty write probes that queue without injecting a
        // protocol line into the MCP server.
        var stdinReady = started.writeStdin(Data())
        do {
            for delay in Self.stdinReadinessBackoff where !stdinReady {
                try Task.checkCancellation()
                guard started.isRunning else {
                    process = nil
                    throw MCPClientError.transportEOF
                }
                try await Task.sleep(for: delay)
                stdinReady = started.writeStdin(Data())
            }
            guard stdinReady else {
                process = nil
                started.terminate()
                throw MCPClientError.transportFailure("iSH MCP stdin 未在启动窗口内就绪")
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
        throw MCPClientError.unavailable
#endif
    }

    func write(_ data: Data) async throws {
#if os(iOS) && canImport(HarnessISH)
        guard let process, process.isRunning else {
            throw MCPClientError.transportEOF
        }
        guard process.writeStdin(data) else {
            throw MCPClientError.transportFailure("iSH MCP stdin 拒绝写入")
        }
#else
        _ = data
        throw MCPClientError.unavailable
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
    fileprivate func handleProcessExit(pid: Int32) {
        if process?.pid == pid {
            process = nil
        }
    }
#endif

    private static func guestEnvironment(_ configured: [String: String]) -> [String: String] {
        var environment = [
            "HOME": "/root",
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM": "xterm-256color",
            "MCP_ON_DEVICE": "1"
        ]
        for (key, value) in configured {
            environment[key] = value
        }
        return environment
    }

    private static func makeExecScript(
        command: String,
        args: [String],
        cwd: String?
    ) throws -> String {
        let workingDirectory = (cwd?.isEmpty == false ? cwd! : "/workspace")
        let commandLine = ([command] + args).map(shellQuote).joined(separator: " ")
        // `exec` keeps the PID and stdio owned by the actual MCP server. The
        // shell wrapper only supplies a bounded, validated working directory.
        return "cd -- \(shellQuote(workingDirectory)) && exec -- \(commandLine)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#if os(iOS) && canImport(HarnessISH)
private final class ISHMCPOutputRelay: @unchecked Sendable {
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

private final class ISHMCPExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private weak var transport: ISHMCPStdioTransport?
    private let onExit: @Sendable (MCPTransportExit) -> Void

    init(
        transport: ISHMCPStdioTransport,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
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

        let exit = MCPTransportExit(
            exitCode: Int(result.exitCode),
            errorCode: result.error.rawValue
        )
        let pid = Int32(result.pid)
        let transport = transport
        let onExit = onExit
        Task {
            await transport?.handleProcessExit(pid: pid)
            onExit(exit)
        }
    }
}
#endif
