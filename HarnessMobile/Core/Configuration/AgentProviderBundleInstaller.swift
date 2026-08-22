import Foundation

enum AgentProviderBundleInstallPhase: String, Sendable, Equatable {
    case unknown
    case checking
    case preparingRuntime = "preparing-runtime"
    case downloading
    case verifying
    case inspectingPackage = "inspecting-package"
    case installingDependencies = "installing-dependencies"
    case validatingExecutable = "validating-executable"
    case committing
    case installed
    case notInstalled = "not-installed"
    case cancelling
    case cancelled
    case failed

    var isActive: Bool {
        switch self {
        case .checking, .preparingRuntime, .downloading, .verifying,
             .inspectingPackage, .installingDependencies,
             .validatingExecutable, .committing, .cancelling:
            true
        case .unknown, .installed, .notInstalled, .cancelled, .failed:
            false
        }
    }
}

struct AgentProviderBundleInstallStatus: Sendable, Equatable {
    let bundleID: AgentProviderBundleID
    let phase: AgentProviderBundleInstallPhase
    let message: String
    let installedVersion: String?
    let didInstall: Bool

    static func unknown(_ id: AgentProviderBundleID) -> Self {
        Self(
            bundleID: id,
            phase: .unknown,
            message: "尚未检查手机 iSH 中的安装状态。",
            installedVersion: nil,
            didInstall: false
        )
    }
}

struct AgentProviderBundleInstallation: Sendable, Equatable {
    let bundleID: AgentProviderBundleID
    let version: String
    let executablePath: String
    let didInstall: Bool
}

enum AgentProviderBundleInstallError: LocalizedError, Sendable, Equatable {
    case alreadyInstalling
    case invalidCatalogContract
    case checksumMismatch
    case packageIdentityMismatch(String)
    case packageDoesNotDeclareCLI(String)
    case unsupportedGuestRuntime(String)
    case installationFailed(String)
    case invalidInstallReceipt

    var errorDescription: String? {
        switch self {
        case .alreadyInstalling:
            "这个 Profile Bundle 已在安装。"
        case .invalidCatalogContract:
            "内置 Profile Bundle 安装清单不一致，已拒绝安装。"
        case .checksumMismatch:
            "下载文件的 SHA-256 与内置清单不一致，已拒绝安装并保留旧版本。"
        case let .packageIdentityMismatch(detail):
            "npm 包身份与内置清单不一致：\(detail)"
        case let .packageDoesNotDeclareCLI(detail):
            "npm 包不能忠实安装为声明的 CLI：\(detail)"
        case let .unsupportedGuestRuntime(detail):
            "这个 CLI 不支持当前手机 iSH 运行时：\(detail)"
        case let .installationFailed(detail):
            "Profile Bundle 本机安装失败：\(detail)"
        case .invalidInstallReceipt:
            "安装事务完成后没有得到可信的本机安装回执。"
        }
    }
}

typealias AgentProviderBundleInstallExecutor = @Sendable (
    _ sessionID: String,
    _ command: String,
    _ workspaceURL: URL,
    _ onOutput: @escaping @Sendable (ISHCommandOutputChunk) async -> Void
) async throws -> ISHCommandResult

typealias AgentProviderBundleInstallCanceller = @Sendable (_ sessionID: String) async -> Void
typealias AgentProviderBundleInstallObserver = @Sendable (
    _ status: AgentProviderBundleInstallStatus
) async -> Void

/// Installs one immutable Profile Bundle entirely inside the phone's iSH
/// guest. Public callers choose only a catalog id and whether this is an
/// explicit reinstall; the URL, digest, package identity, executable and shell
/// transaction cannot be supplied by a model or UI field.
actor AgentProviderBundleInstaller {
    static let shared = AgentProviderBundleInstaller()

    private static let sessionPrefix = "ish-profile-bundle-installer."
    private let execute: AgentProviderBundleInstallExecutor
    private let cancelExecution: AgentProviderBundleInstallCanceller
    private var activeBundleIDs: Set<AgentProviderBundleID> = []
    private var statuses: [AgentProviderBundleID: AgentProviderBundleInstallStatus] = [:]

    init(coordinator: ISHSandboxCoordinator = .shared) {
        execute = { sessionID, command, workspaceURL, onOutput in
            let lease = await coordinator.beginTemporaryGuestNetworkAccess()
            do {
                let result = try await coordinator.execute(
                    sessionID: sessionID,
                    command: command,
                    workspaceURL: workspaceURL,
                    timeout: 1_800,
                    maximumOutputBytes: 256 * 1_024,
                    policy: ISHSandboxExecutionPolicy(
                        mode: .dangerFullAccess,
                        workspaceRoot: workspaceURL
                    ),
                    onOutput: onOutput
                )
                await coordinator.endTemporaryGuestNetworkAccess(lease)
                return result
            } catch {
                await coordinator.endTemporaryGuestNetworkAccess(lease)
                throw error
            }
        }
        cancelExecution = { sessionID in
            await coordinator.cancel(sessionID: sessionID)
        }
    }

    init(
        execute: @escaping AgentProviderBundleInstallExecutor,
        cancel: @escaping AgentProviderBundleInstallCanceller = { _ in }
    ) {
        self.execute = execute
        cancelExecution = cancel
    }

    func status(for id: AgentProviderBundleID) -> AgentProviderBundleInstallStatus {
        statuses[id] ?? .unknown(id)
    }

    func inspect(
        _ id: AgentProviderBundleID,
        workspaceURL: URL,
        onEvent: @escaping AgentProviderBundleInstallObserver = { _ in }
    ) async -> AgentProviderBundleInstallStatus {
        guard !activeBundleIDs.contains(id),
              let bundle = Self.catalogBundle(id),
              Self.hasConsistentCatalogContract(bundle) else {
            return statuses[id] ?? .unknown(id)
        }
        let checking = Self.status(id, .checking, "正在检查手机 iSH 固定安装目录。")
        await publish(checking, observer: onEvent)
        do {
            let result = try await execute(
                Self.sessionID(id),
                Self.inspectCommand(bundle),
                workspaceURL,
                { _ in }
            )
            let inspected = Self.inspectionStatus(bundle, result: result)
            await publish(inspected, observer: onEvent)
            return inspected
        } catch {
            let failed = Self.status(
                id,
                .failed,
                "无法检查手机 iSH：\(Self.safeDetail(error.localizedDescription))"
            )
            await publish(failed, observer: onEvent)
            return failed
        }
    }

    func install(
        _ id: AgentProviderBundleID,
        workspaceURL: URL,
        reinstall: Bool = false,
        onEvent: @escaping AgentProviderBundleInstallObserver = { _ in }
    ) async throws -> AgentProviderBundleInstallation {
        guard !activeBundleIDs.contains(id) else {
            throw AgentProviderBundleInstallError.alreadyInstalling
        }
        guard let bundle = Self.catalogBundle(id),
              Self.hasConsistentCatalogContract(bundle) else {
            throw AgentProviderBundleInstallError.invalidCatalogContract
        }
        try bundle.installPayload.validate()
        activeBundleIDs.insert(id)
        defer { activeBundleIDs.remove(id) }

        await publish(
            Self.status(id, .preparingRuntime, "正在手机 iSH 中准备受约束安装事务。"),
            observer: onEvent
        )
        let command = Self.installCommand(bundle, reinstall: reinstall)
        let result: ISHCommandResult
        do {
            result = try await execute(
                Self.sessionID(id),
                command,
                workspaceURL,
                { [weak self] chunk in
                    guard chunk.channel == .stdout,
                          let event = Self.eventStatus(id, line: chunk.text) else { return }
                    await self?.publish(event, observer: onEvent)
                }
            )
        } catch is CancellationError {
            let cancelled = Self.status(id, .cancelled, "安装已取消；旧版本已保留或恢复。")
            await publish(cancelled, observer: onEvent)
            throw CancellationError()
        } catch let error as ISHSandboxError where error == .cancelled {
            let cancelled = Self.status(id, .cancelled, "安装已取消；旧版本已保留或恢复。")
            await publish(cancelled, observer: onEvent)
            throw CancellationError()
        } catch {
            let failed = Self.status(
                id,
                .failed,
                "安装进程未完成：\(Self.safeDetail(error.localizedDescription))"
            )
            await publish(failed, observer: onEvent)
            throw error
        }

        guard result.exitCode == 0 else {
            let error = Self.installError(result)
            await publish(
                Self.status(id, .failed, error.localizedDescription),
                observer: onEvent
            )
            throw error
        }
        guard let receipt = Self.installReceipt(bundle, output: result.stdout) else {
            let error = AgentProviderBundleInstallError.invalidInstallReceipt
            await publish(Self.status(id, .failed, error.localizedDescription), observer: onEvent)
            throw error
        }
        let installed = Self.status(
            id,
            .installed,
            receipt.didInstall ? "已在手机 iSH 中安装并验证。" : "手机 iSH 中的固定版本已经验证。",
            version: receipt.version,
            didInstall: receipt.didInstall
        )
        await publish(installed, observer: onEvent)
        return receipt
    }

    func cancel(_ id: AgentProviderBundleID, onEvent: AgentProviderBundleInstallObserver = { _ in }) async {
        guard activeBundleIDs.contains(id) else { return }
        await publish(Self.status(id, .cancelling, "正在取消并回滚安装事务。"), observer: onEvent)
        await cancelExecution(Self.sessionID(id))
    }

    private func publish(
        _ status: AgentProviderBundleInstallStatus,
        observer: AgentProviderBundleInstallObserver
    ) async {
        statuses[status.bundleID] = status
        await observer(status)
    }

    private static func catalogBundle(_ id: AgentProviderBundleID) -> AgentProviderBundle? {
        AgentProviderBundle.catalog.first { $0.id == id }
    }

    private static func hasConsistentCatalogContract(_ bundle: AgentProviderBundle) -> Bool {
        bundle.installPayload.bundleID == bundle.id
            && bundle.installPayload.executable == bundle.executable
            && bundle.installPayload.arguments == bundle.nonInteractiveArguments
    }

    private static func sessionID(_ id: AgentProviderBundleID) -> String {
        sessionPrefix + id.rawValue
    }

    private static func status(
        _ id: AgentProviderBundleID,
        _ phase: AgentProviderBundleInstallPhase,
        _ message: String,
        version: String? = nil,
        didInstall: Bool = false
    ) -> AgentProviderBundleInstallStatus {
        AgentProviderBundleInstallStatus(
            bundleID: id,
            phase: phase,
            message: safeDetail(message),
            installedVersion: version,
            didInstall: didInstall
        )
    }

    private static func eventStatus(
        _ id: AgentProviderBundleID,
        line: String
    ) -> AgentProviderBundleInstallStatus? {
        let marker = "HARNESS_PROFILE_EVENT:"
        guard let range = line.range(of: marker) else { return nil }
        let value = line[range.upperBound...]
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let phase = AgentProviderBundleInstallPhase(rawValue: parts[0]) else { return nil }
        return status(id, phase, parts[1])
    }

    private static func inspectionStatus(
        _ bundle: AgentProviderBundle,
        result: ISHCommandResult
    ) -> AgentProviderBundleInstallStatus {
        guard result.exitCode == 0,
              result.stdout.contains("HARNESS_PROFILE_INSPECT:installed:\(bundle.installPayload.version)") else {
            return status(bundle.id, .notInstalled, "手机 iSH 中尚未安装这个固定版本。")
        }
        return status(
            bundle.id,
            .installed,
            "手机 iSH 中已安装并验证固定版本。",
            version: bundle.installPayload.version
        )
    }

    private static func installReceipt(
        _ bundle: AgentProviderBundle,
        output: String
    ) -> AgentProviderBundleInstallation? {
        let installed = "HARNESS_PROFILE_RESULT:installed:\(bundle.installPayload.version)"
        let existing = "HARNESS_PROFILE_RESULT:already-installed:\(bundle.installPayload.version)"
        let didInstall: Bool
        if output.contains(installed) { didInstall = true }
        else if output.contains(existing) { didInstall = false }
        else { return nil }
        return AgentProviderBundleInstallation(
            bundleID: bundle.id,
            version: bundle.installPayload.version,
            executablePath: bundle.resolvedExecutablePath,
            didInstall: didInstall
        )
    }

    private static func installError(_ result: ISHCommandResult) -> AgentProviderBundleInstallError {
        let combined = result.stderr + "\n" + result.stdout
        let marker = "HARNESS_PROFILE_ERROR:"
        let markedLine = combined.split(whereSeparator: \.isNewline).first {
            $0.contains(marker)
        }.map(String.init)
        let payload = markedLine.flatMap { line -> (String, String)? in
            guard let range = line.range(of: marker) else { return nil }
            let parts = line[range.upperBound...]
                .split(separator: ":", maxSplits: 1)
                .map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], safeDetail(parts[1]))
        }
        guard let payload else {
            return .installationFailed(
                safeDetail(result.stderr.isEmpty ? result.stdout : result.stderr)
            )
        }
        switch payload.0 {
        case "checksum-mismatch": return .checksumMismatch
        case "package-identity": return .packageIdentityMismatch(payload.1)
        case "missing-declared-cli": return .packageDoesNotDeclareCLI(payload.1)
        case "unsupported-runtime": return .unsupportedGuestRuntime(payload.1)
        default: return .installationFailed(payload.1)
        }
    }

    private static func inspectCommand(_ bundle: AgentProviderBundle) -> String {
        let root = bundleRoot(bundle)
        let executable = shellQuote(bundle.resolvedExecutablePath)
        let stamp = shellQuote(root + "/install.stamp")
        let expected = [
            "bundle=\(bundle.id.rawValue)",
            "version=\(bundle.installPayload.version)",
            "sha256=\(bundle.installPayload.sha256.lowercased())",
            "executable=\(bundle.installPayload.executable)"
        ].map(shellQuote)
        return [
            "set -eu",
            "if [ -x \(executable) ] && [ -f \(stamp) ]",
            "  && grep -Fqx \(expected[0]) \(stamp)",
            "  && grep -Fqx \(expected[1]) \(stamp)",
            "  && grep -Fqx \(expected[2]) \(stamp)",
            "  && grep -Fqx \(expected[3]) \(stamp); then",
            "  printf '%s\\n' \(shellQuote("HARNESS_PROFILE_INSPECT:installed:\(bundle.installPayload.version)"))",
            "else",
            "  printf '%s\\n' 'HARNESS_PROFILE_INSPECT:not-installed'",
            "  exit 3",
            "fi"
        ].joined(separator: "\n")
    }

    private static func installCommand(_ bundle: AgentProviderBundle, reinstall: Bool) -> String {
        let payload = bundle.installPayload
        let root = bundleRoot(bundle)
        let parent = "/usr/local/lib/harness-mobile/provider-bundles"
        let stage = parent + "/.staging-" + bundle.id.rawValue
        let backup = parent + "/.rollback-" + bundle.id.rawValue
        let archive = stage + "/package.tgz"
        let unpacked = stage + "/unpacked/package"
        let runtime = stage + "/runtime"
        let executable = stage + "/bin/" + payload.executable
        let stamp = stage + "/install.stamp"
        let installedExecutable = bundle.resolvedExecutablePath
        let force = reinstall ? "1" : "0"
        let nodeInspector = #"const fs=require('node:fs'),path=require('node:path');const [dir,name,version,exe]=process.argv.slice(1);const p=JSON.parse(fs.readFileSync(path.join(dir,'package.json'),'utf8'));if(p.name!==name||p.version!==version){console.error(`HARNESS_PROFILE_ERROR:package-identity:expected ${name}@${version}`);process.exit(71)}const b=typeof p.bin==='string'?{[name.split('/').pop()]:p.bin}:p.bin;const e=b&&b[exe];if(typeof e!=='string'){console.error(`HARNESS_PROFILE_ERROR:missing-declared-cli:${name}@${version} does not declare bin.${exe}`);process.exit(72)}if(path.isAbsolute(e)||e.split(/[\\/]/).includes('..')||!fs.existsSync(path.join(dir,e))){console.error(`HARNESS_PROFILE_ERROR:missing-declared-cli:bin.${exe} is not a safe packaged entry`);process.exit(72)}"#
        let stampBody = [
            "bundle=\(bundle.id.rawValue)",
            "version=\(payload.version)",
            "sha256=\(payload.sha256.lowercased())",
            "executable=\(payload.executable)"
        ].joined(separator: "\\n") + "\\n"
        return [
            "set -eu",
            "TARGET=\(shellQuote(root))",
            "STAGE=\(shellQuote(stage))",
            "BACKUP=\(shellQuote(backup))",
            "FORCE=\(shellQuote(force))",
            "swapped=0",
            "cleanup() {",
            "  rc=$?",
            "  if [ \"$swapped\" = 1 ]; then",
            "    [ ! -e \"$TARGET\" ] || rm -rf -- \"$TARGET\"",
            "    [ ! -e \"$BACKUP\" ] || mv -- \"$BACKUP\" \"$TARGET\"",
            "  fi",
            "  [ ! -e \"$STAGE\" ] || rm -rf -- \"$STAGE\"",
            "  exit \"$rc\"",
            "}",
            "trap cleanup EXIT HUP INT TERM",
            "mkdir -p -- \(shellQuote(parent))",
            "if [ ! -e \"$TARGET\" ] && [ -e \"$BACKUP\" ]; then mv -- \"$BACKUP\" \"$TARGET\"; fi",
            "[ ! -e \"$BACKUP\" ] || rm -rf -- \"$BACKUP\"",
            "[ ! -e \"$STAGE\" ] || rm -rf -- \"$STAGE\"",
            "if [ \"$FORCE\" = 0 ] && [ -x \(shellQuote(installedExecutable)) ]",
            "  && [ -f \"$TARGET/install.stamp\" ]",
            "  && grep -Fqx \(shellQuote("version=\(payload.version)")) \"$TARGET/install.stamp\"",
            "  && grep -Fqx \(shellQuote("sha256=\(payload.sha256.lowercased())")) \"$TARGET/install.stamp\"; then",
            "  printf '%s\\n' \(shellQuote("HARNESS_PROFILE_RESULT:already-installed:\(payload.version)"))",
            "  trap - EXIT HUP INT TERM",
            "  exit 0",
            "fi",
            "mkdir -p -- \(shellQuote(stage + "/unpacked")) \(shellQuote(stage + "/bin"))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:preparing-runtime:正在准备 iSH Node.js 运行时。'",
            "apk add --no-cache nodejs npm ca-certificates >/dev/null",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:downloading:正在 iSH 本机下载内置清单指定的官方 tarball。'",
            "wget -q -O \(shellQuote(archive)) \(shellQuote(payload.sourceURL))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:verifying:正在核对内置 SHA-256。'",
            "actual=$(sha256sum \(shellQuote(archive)) | awk '{print $1}')",
            "if [ \"$actual\" != \(shellQuote(payload.sha256.lowercased())) ]; then",
            "  printf '%s\\n' 'HARNESS_PROFILE_ERROR:checksum-mismatch:downloaded tarball digest differs from catalog' >&2",
            "  exit 70",
            "fi",
            "tar -xzf \(shellQuote(archive)) -C \(shellQuote(stage + "/unpacked"))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:inspecting-package:正在验证 npm 包身份和声明的 CLI。'",
            "node -e \(shellQuote(nodeInspector)) -- \(shellQuote(unpacked)) \(shellQuote(payload.packageName)) \(shellQuote(payload.version)) \(shellQuote(payload.executable))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:installing-dependencies:正在安装该固定 npm 包声明的运行依赖（禁用生命周期脚本）。'",
            "mkdir -p -- \(shellQuote(runtime))",
            "npm install --prefix \(shellQuote(runtime)) --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error \(shellQuote(archive))",
            "if [ ! -x \(shellQuote(runtime + "/node_modules/.bin/" + payload.executable)) ]; then",
            "  printf '%s\\n' \(shellQuote("HARNESS_PROFILE_ERROR:missing-declared-cli:npm did not materialize bin.\(payload.executable)")) >&2",
            "  exit 72",
            "fi",
            "ln -s \(shellQuote("../runtime/node_modules/.bin/" + payload.executable)) \(shellQuote(executable))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:validating-executable:正在 iSH 中执行无凭据版本探针。'",
            "if ! \(shellQuote(executable)) --version >/dev/null 2>\(shellQuote(stage + "/probe.err")); then",
            "  detail=$(head -n 1 \(shellQuote(stage + "/probe.err")) | tr '\\r\\n' ' ' | cut -c1-240)",
            "  printf 'HARNESS_PROFILE_ERROR:unsupported-runtime:%s\\n' \"${detail:-declared CLI failed its on-device version probe}\" >&2",
            "  exit 73",
            "fi",
            "printf \(shellQuote(stampBody)) > \(shellQuote(stamp))",
            "rm -f -- \(shellQuote(archive)) \(shellQuote(stage + "/probe.err"))",
            "printf '%s\\n' 'HARNESS_PROFILE_EVENT:committing:正在原子替换固定安装目录。'",
            "if [ -e \"$TARGET\" ]; then mv -- \"$TARGET\" \"$BACKUP\"; fi",
            "swapped=1",
            "mv -- \"$STAGE\" \"$TARGET\"",
            "swapped=0",
            "[ ! -e \"$BACKUP\" ] || rm -rf -- \"$BACKUP\"",
            "trap - EXIT HUP INT TERM",
            "printf '%s\\n' \(shellQuote("HARNESS_PROFILE_RESULT:installed:\(payload.version)"))"
        ].joined(separator: "\n")
    }

    private static func bundleRoot(_ bundle: AgentProviderBundle) -> String {
        "/usr/local/lib/harness-mobile/provider-bundles/" + bundle.id.rawValue
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeDetail(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return HarnessTraceRedactor.string(firstLine, maximumUTF8Bytes: 512)
    }
}
