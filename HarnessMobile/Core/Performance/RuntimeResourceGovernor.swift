import Foundation

enum RuntimeThermalLevel: Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

struct RuntimeResourceSignals: Sendable, Equatable {
    var thermalLevel: RuntimeThermalLevel
    var isLowPowerModeEnabled: Bool
    var isBackgrounded: Bool
}

struct RuntimeResourceLimits: Sendable, Equatable {
    let maximumConcurrentCommands: Int
    let maximumInlineOutputBytes: Int
    let commandTimeoutSeconds: Int
    let emulatorDutyCycle: Double

    func effectiveCommandTimeout(requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return TimeInterval(commandTimeoutSeconds) }
        return min(max(requested, 1), TimeInterval(commandTimeoutSeconds))
    }

    func effectiveInlineOutputBytes(requested: Int? = nil) -> Int {
        min(max(requested ?? maximumInlineOutputBytes, 1_024), maximumInlineOutputBytes)
    }
}

enum RuntimeResourceGovernor {
    static func limits(for signals: RuntimeResourceSignals) -> RuntimeResourceLimits {
        if signals.thermalLevel == .critical {
            return RuntimeResourceLimits(
                maximumConcurrentCommands: 1,
                maximumInlineOutputBytes: 128 * 1_024,
                commandTimeoutSeconds: 60,
                emulatorDutyCycle: 0.25
            )
        }

        if signals.isBackgrounded || signals.thermalLevel == .serious {
            return RuntimeResourceLimits(
                maximumConcurrentCommands: 1,
                maximumInlineOutputBytes: 256 * 1_024,
                commandTimeoutSeconds: 180,
                emulatorDutyCycle: 0.5
            )
        }

        if signals.isLowPowerModeEnabled || signals.thermalLevel == .fair {
            return RuntimeResourceLimits(
                maximumConcurrentCommands: 1,
                maximumInlineOutputBytes: 384 * 1_024,
                commandTimeoutSeconds: 240,
                emulatorDutyCycle: 0.7
            )
        }

        return RuntimeResourceLimits(
            maximumConcurrentCommands: 2,
            maximumInlineOutputBytes: 512 * 1_024,
            commandTimeoutSeconds: 300,
            emulatorDutyCycle: 1
        )
    }

    static func currentSignals(isBackgrounded: Bool) -> RuntimeResourceSignals {
        RuntimeResourceSignals(
            thermalLevel: thermalLevel(ProcessInfo.processInfo.thermalState),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isBackgrounded: isBackgrounded
        )
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> RuntimeThermalLevel {
        switch state {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .serious
        }
    }
}
