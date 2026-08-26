import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

enum HarnessLiveActivityPhase: String, Codable, Hashable, Sendable {
    case preparing
    case working
    case usingTool
    case completed
    case failed
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted:
            true
        case .preparing, .working, .usingTool:
            false
        }
    }
}

struct HarnessLiveActivityState: Codable, Hashable, Sendable {
    var sessionTitle: String
    var phase: HarnessLiveActivityPhase
    var detail: String
    var toolName: String?
    var toolSummary: String?
    var completedUnitCount: Int64
    var totalUnitCount: Int64
    var privacyModeEnabled: Bool
    var updatedAt: Date

    var progressFraction: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }

    static func make(
        sessionTitle: String,
        phase: HarnessLiveActivityPhase,
        detail: String,
        toolName: String? = nil,
        toolSummary: String? = nil,
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        privacyModeEnabled: Bool,
        updatedAt: Date = .now
    ) -> HarnessLiveActivityState {
        let normalizedTotal = max(1, totalUnitCount)
        let normalizedCompleted = min(normalizedTotal, max(0, completedUnitCount))

        if privacyModeEnabled {
            return HarnessLiveActivityState(
                sessionTitle: "Harness 任务",
                phase: phase,
                detail: phase.privateDetail,
                toolName: nil,
                toolSummary: nil,
                completedUnitCount: normalizedCompleted,
                totalUnitCount: normalizedTotal,
                privacyModeEnabled: true,
                updatedAt: updatedAt
            )
        }

        return HarnessLiveActivityState(
            sessionTitle: normalized(sessionTitle, fallback: "Harness 任务", limit: 80),
            phase: phase,
            detail: normalized(detail, fallback: phase.privateDetail, limit: 160),
            toolName: normalizedOptional(toolName, limit: 48),
            toolSummary: normalizedOptional(toolSummary, limit: 160),
            completedUnitCount: normalizedCompleted,
            totalUnitCount: normalizedTotal,
            privacyModeEnabled: false,
            updatedAt: updatedAt
        )
    }

    func hasSamePresentation(as other: HarnessLiveActivityState) -> Bool {
        var lhs = self
        var rhs = other
        lhs.updatedAt = .distantPast
        rhs.updatedAt = .distantPast
        return lhs == rhs
    }

    private static func normalized(
        _ value: String,
        fallback: String,
        limit: Int
    ) -> String {
        normalizedOptional(value, limit: limit) ?? fallback
    }

    private static func normalizedOptional(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }
}

/// Process-local projection cache used by the ActivityKit adapter. Keeping the
/// cache value-based makes multi-run isolation testable without requiring an
/// ActivityKit host or a real device.
struct HarnessLiveActivityProjectionStore: Sendable, Equatable {
    private(set) var states: [UUID: HarnessLiveActivityState] = [:]

    var activeRunIDs: Set<UUID> { Set(states.keys) }

    mutating func upsert(_ state: HarnessLiveActivityState, for runID: UUID) {
        states[runID] = state
    }

    @discardableResult
    mutating func remove(runID: UUID) -> HarnessLiveActivityState? {
        states.removeValue(forKey: runID)
    }

    mutating func removeAll() {
        states.removeAll(keepingCapacity: false)
    }
}

private extension HarnessLiveActivityPhase {
    var privateDetail: String {
        switch self {
        case .preparing:
            "正在准备本机任务"
        case .working:
            "任务正在本机执行"
        case .usingTool:
            "正在执行已批准的本机工具"
        case .completed:
            "任务已完成"
        case .failed:
            "任务未完成"
        case .interrupted:
            "任务已被系统中断"
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
struct HarnessActivityAttributes: ActivityAttributes {
    let runID: String
    let sessionID: String?
    let startedAt: Date

    typealias ContentState = HarnessLiveActivityState
}
#endif
