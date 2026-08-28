import Foundation

#if os(iOS) && canImport(MetricKit)
@preconcurrency import MetricKit
#endif

/// Fixed, body-free runtime observations. These records intentionally have no
/// free-form message, URL, header, command, environment, prompt, tool input,
/// tool output, or call-stack field.
enum RuntimeTelemetryKind: String, Codable, Sendable, Equatable {
    case launchMarker = "launch_marker"
    case watchdog
    case hang
    case backgroundTimeout = "background_timeout"
    case metricKit = "metric_kit"
    case performanceSample = "performance_sample"
}

/// A bounded observation safe to include in an explicit diagnostic export.
/// Session/run identity is present only for resource-expiration ownership; it
/// is never included in default diagnostic summaries.
struct RuntimeTelemetryRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: RuntimeTelemetryKind
    let code: String
    let sessionID: UUID?
    let runID: UUID?
    let generation: UInt64?
    let attributes: [String: Int]
}

struct RuntimeTelemetrySummary: Sendable, Equatable {
    let recordCount: Int
    let encodedBytes: Int
    let performanceSamplingEnabled: Bool
}

/// Numeric-only aggregate extracted from MetricKit. Keeping this separate from
/// the framework adapter makes the privacy contract testable on SwiftPM hosts.
struct RuntimeMetricKitExitAggregate: Sendable, Equatable {
    let foregroundWatchdogCount: Int
    let backgroundWatchdogCount: Int
    let backgroundTaskAssertionTimeoutCount: Int
    let foregroundMemoryResourceLimitCount: Int
    let backgroundMemoryResourceLimitCount: Int
    let backgroundCPUResourceLimitCount: Int
    let backgroundMemoryPressureCount: Int

    var attributes: [String: Int] {
        [
            "foreground_watchdog_count": foregroundWatchdogCount,
            "background_watchdog_count": backgroundWatchdogCount,
            "background_task_assertion_timeout_count": backgroundTaskAssertionTimeoutCount,
            "foreground_memory_resource_limit_count": foregroundMemoryResourceLimitCount,
            "background_memory_resource_limit_count": backgroundMemoryResourceLimitCount,
            "background_cpu_resource_limit_count": backgroundCPUResourceLimitCount,
            "background_memory_pressure_count": backgroundMemoryPressureCount
        ]
    }
}

struct RuntimeHangObservation: Sendable, Equatable {
    let gapMilliseconds: Int
}

/// Actor-isolated gate for a main-thread heartbeat. It reports a continuous
/// stall once, then re-arms after the next heartbeat. App lifecycle code must
/// suspend it in the background because an OS suspension is not a hang.
actor RuntimeHangWatchdogGate {
    private let threshold: TimeInterval
    private var isArmed = false
    private var hasReportedCurrentStall = false
    private var lastBeat: Date?

    init(threshold: TimeInterval = 3) {
        self.threshold = min(max(threshold, 1), 15)
    }

    func start(now: Date = .now) {
        isArmed = true
        hasReportedCurrentStall = false
        lastBeat = now
    }

    func suspend() {
        isArmed = false
        hasReportedCurrentStall = false
        lastBeat = nil
    }

    func beat(now: Date = .now) {
        guard isArmed else { return }
        hasReportedCurrentStall = false
        lastBeat = now
    }

    func check(now: Date = .now) -> RuntimeHangObservation? {
        guard isArmed,
              !hasReportedCurrentStall,
              let lastBeat else {
            return nil
        }
        let gap = now.timeIntervalSince(lastBeat)
        guard gap >= threshold else { return nil }
        hasReportedCurrentStall = true
        return RuntimeHangObservation(gapMilliseconds: Int((gap * 1_000).rounded()))
    }
}

/// In-memory bounded ring plus a deliberately tiny durable launch marker.
/// The marker is only a prior-bootstrap-completion hint; it does not diagnose
/// a crash and never contains user content or execution context.
actor RuntimeTelemetryStore {
    private struct LaunchMarker: Codable {
        let version: Int
        let launchedAt: Date
    }

    private static let markerVersion = 1
    private static let maximumAttributeMagnitude = 1_000_000_000
    private static let dedupWindow: TimeInterval = 60
    private static let allowedAttributeKeys: Set<String> = [
        "gap_ms",
        "thermal_level",
        "low_power_mode",
        "is_backgrounded",
        "foreground_watchdog_count",
        "background_watchdog_count",
        "background_task_assertion_timeout_count",
        "foreground_memory_resource_limit_count",
        "background_memory_resource_limit_count",
        "background_cpu_resource_limit_count",
        "background_memory_pressure_count",
        "hang_duration_ms"
    ]

    private let markerURL: URL
    private let capacity: Int
    private let maximumEncodedBytes: Int
    private var records: [RuntimeTelemetryRecord] = []
    private var encodedBytes = 0
    private var performanceSamplingEnabled: Bool
    private var lastDeduplicationAt: [String: Date] = [:]

    init(
        markerURL: URL = RuntimeTelemetryStore.applicationMarkerURL(),
        capacity: Int = 128,
        maximumEncodedBytes: Int = 64 * 1_024,
        performanceSamplingEnabled: Bool = false
    ) {
        self.markerURL = markerURL
        self.capacity = min(max(capacity, 1), 512)
        self.maximumEncodedBytes = min(max(maximumEncodedBytes, 1_024), 256 * 1_024)
        self.performanceSamplingEnabled = performanceSamplingEnabled
    }

    nonisolated static func applicationMarkerURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("runtime-launch-marker-v1.json", isDirectory: false)
    }

    func configurePerformanceSampling(enabled: Bool) {
        performanceSamplingEnabled = enabled
    }

    func beginBootstrap(now: Date = .now) {
        if FileManager.default.fileExists(atPath: markerURL.path) {
            append(
                kind: .launchMarker,
                code: "previous_bootstrap_unfinished",
                now: now
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let marker = LaunchMarker(version: Self.markerVersion, launchedAt: now)
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            append(kind: .launchMarker, code: "launch_marker_write_failed", now: now)
        }
    }

    func markBootstrapCompleted() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: markerURL)
        } catch {
            append(kind: .launchMarker, code: "launch_marker_clear_failed")
        }
    }

    func recordBackgroundTimeout(
        identity: RunIdentity,
        source: RuntimeBackgroundTimeoutSource,
        now: Date = .now
    ) {
        append(
            kind: .backgroundTimeout,
            code: source.rawValue,
            identity: identity,
            now: now,
            deduplicationKey: "background_timeout|\(source.rawValue)|\(identity.sessionID.uuidString)|\(identity.runID.uuidString)|\(identity.generation)"
        )
    }

    func recordHang(_ observation: RuntimeHangObservation, now: Date = .now) {
        append(
            kind: .hang,
            code: "main_heartbeat_gap",
            attributes: ["gap_ms": observation.gapMilliseconds],
            now: now,
            deduplicationKey: "watchdog|main_heartbeat_gap"
        )
    }

    func recordMetricKit(_ aggregate: RuntimeMetricKitExitAggregate, now: Date = .now) {
        append(
            kind: .metricKit,
            code: "exit_aggregate",
            attributes: aggregate.attributes,
            now: now
        )
    }

    func recordMetricKitHang(durationMilliseconds: Int, now: Date = .now) {
        append(
            kind: .metricKit,
            code: "hang_diagnostic",
            attributes: ["hang_duration_ms": durationMilliseconds],
            now: now
        )
    }

    func recordPerformanceSample(_ signals: RuntimeResourceSignals, now: Date = .now) {
        guard performanceSamplingEnabled else { return }
        append(
            kind: .performanceSample,
            code: "resource_signals",
            attributes: [
                "thermal_level": Self.thermalLevelCode(signals.thermalLevel),
                "low_power_mode": signals.isLowPowerModeEnabled ? 1 : 0,
                "is_backgrounded": signals.isBackgrounded ? 1 : 0
            ],
            now: now
        )
    }

    /// Internal seam used by tests and tightly controlled callers. Even here,
    /// arbitrary text is discarded rather than redacted into a new payload.
    func record(
        kind: RuntimeTelemetryKind,
        code: String,
        identity: RunIdentity? = nil,
        attributes: [String: Int] = [:],
        now: Date = .now
    ) {
        append(kind: kind, code: code, identity: identity, attributes: attributes, now: now)
    }

    func snapshot() -> [RuntimeTelemetryRecord] {
        records
    }

    func summary() -> RuntimeTelemetrySummary {
        RuntimeTelemetrySummary(
            recordCount: records.count,
            encodedBytes: encodedBytes,
            performanceSamplingEnabled: performanceSamplingEnabled
        )
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(records)
    }

    private func append(
        kind: RuntimeTelemetryKind,
        code: String,
        identity: RunIdentity? = nil,
        attributes: [String: Int] = [:],
        now: Date = .now,
        deduplicationKey: String? = nil
    ) {
        if let deduplicationKey,
           let prior = lastDeduplicationAt[deduplicationKey],
           now.timeIntervalSince(prior) < Self.dedupWindow {
            return
        }
        if let deduplicationKey {
            lastDeduplicationAt[deduplicationKey] = now
        }

        let record = RuntimeTelemetryRecord(
            id: UUID(),
            timestamp: now,
            kind: kind,
            code: Self.sanitizedCode(code),
            sessionID: identity?.sessionID,
            runID: identity?.runID,
            generation: identity?.generation,
            attributes: Self.sanitizedAttributes(attributes)
        )
        let recordBytes = Self.encodedByteCount(record)
        guard recordBytes <= maximumEncodedBytes else { return }
        records.append(record)
        encodedBytes += recordBytes

        while records.count > capacity || encodedBytes > maximumEncodedBytes {
            let removed = records.removeFirst()
            encodedBytes -= Self.encodedByteCount(removed)
        }
    }

    private static func sanitizedCode(_ code: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !code.isEmpty,
              code.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              code.utf8.count <= 96 else {
            return "invalid_code"
        }
        return code
    }

    private static func sanitizedAttributes(_ attributes: [String: Int]) -> [String: Int] {
        attributes.reduce(into: [:]) { result, item in
            guard allowedAttributeKeys.contains(item.key) else { return }
            result[item.key] = min(
                max(item.value, -maximumAttributeMagnitude),
                maximumAttributeMagnitude
            )
        }
    }

    private static func encodedByteCount(_ record: RuntimeTelemetryRecord) -> Int {
        (try? JSONEncoder().encode(record).count) ?? 0
    }

    private static func thermalLevelCode(_ level: RuntimeThermalLevel) -> Int {
        switch level {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}

enum RuntimeBackgroundTimeoutSource: String, Sendable, Equatable {
    case finiteBackgroundLease = "finite_background_lease_timeout"
    case continuedProcessing = "continued_processing_timeout"
}

/// Lifecycle-owned watchdog. It samples only the main-queue heartbeat and
/// does not suspend threads or collect stack symbols.
@MainActor
final class RuntimeHangWatchdog {
    private let gate: RuntimeHangWatchdogGate
    private let telemetryStore: RuntimeTelemetryStore
    private var mainHeartbeatTimer: Timer?
    private var monitorTimer: DispatchSourceTimer?
    private var isActive = false

    init(
        telemetryStore: RuntimeTelemetryStore,
        threshold: TimeInterval = 3
    ) {
        self.telemetryStore = telemetryStore
        gate = RuntimeHangWatchdogGate(threshold: threshold)
    }

    func setApplicationActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        let gate = gate
        let telemetryStore = telemetryStore
        Task { await gate.start() }
        mainHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { await gate.beat() }
        }

        let monitor = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.llf.harnessmobile.runtime-watchdog")
        )
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler {
            Task {
                guard let observation = await gate.check() else { return }
                await telemetryStore.recordHang(observation)
            }
        }
        monitor.resume()
        monitorTimer = monitor
    }

    private func stop() {
        mainHeartbeatTimer?.invalidate()
        mainHeartbeatTimer = nil
        monitorTimer?.setEventHandler {}
        monitorTimer?.cancel()
        monitorTimer = nil
        let gate = gate
        Task { await gate.suspend() }
    }
}

#if os(iOS) && canImport(MetricKit)
/// Receives Apple's delayed aggregate reports locally. Raw MetricKit payloads,
/// including call stacks and JSON representations, are never persisted.
final class RuntimeMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let telemetryStore: RuntimeTelemetryStore
    private var isSubscribed = false

    init(telemetryStore: RuntimeTelemetryStore) {
        self.telemetryStore = telemetryStore
        super.init()
    }

    func start() {
        guard !isSubscribed else { return }
        isSubscribed = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let foreground = exits.foregroundExitData
            let background = exits.backgroundExitData
            let aggregate = RuntimeMetricKitExitAggregate(
                foregroundWatchdogCount: foreground.cumulativeAppWatchdogExitCount,
                backgroundWatchdogCount: background.cumulativeAppWatchdogExitCount,
                backgroundTaskAssertionTimeoutCount: background.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                foregroundMemoryResourceLimitCount: foreground.cumulativeMemoryResourceLimitExitCount,
                backgroundMemoryResourceLimitCount: background.cumulativeMemoryResourceLimitExitCount,
                backgroundCPUResourceLimitCount: background.cumulativeCPUResourceLimitExitCount,
                backgroundMemoryPressureCount: background.cumulativeMemoryPressureExitCount
            )
            Task { [telemetryStore] in
                await telemetryStore.recordMetricKit(aggregate)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.hangDiagnostics ?? [] {
                let milliseconds = Int(
                    diagnostic.hangDuration.converted(to: .milliseconds).value.rounded()
                )
                Task { [telemetryStore] in
                    await telemetryStore.recordMetricKitHang(durationMilliseconds: milliseconds)
                }
            }
        }
    }
}
#else
final class RuntimeMetricKitSubscriber {
    init(telemetryStore _: RuntimeTelemetryStore) {}
    func start() {}
}
#endif
