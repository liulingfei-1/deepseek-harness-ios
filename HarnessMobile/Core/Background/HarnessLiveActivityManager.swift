#if os(iOS) && canImport(ActivityKit)
@preconcurrency import ActivityKit
import Foundation
import os

@MainActor
final class HarnessLiveActivityManager {
    static let shared = HarnessLiveActivityManager()

    static var isSystemSupported: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        !ProcessInfo.processInfo.isiOSAppOnMac
#endif
    }

    var areActivitiesEnabled: Bool {
        Self.isSystemSupported && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.llf.harnessmobile",
        category: "LiveActivity"
    )
    private var activities: [UUID: Activity<HarnessActivityAttributes>] = [:]
    private var projections = HarnessLiveActivityProjectionStore()

    private init() {}

    func cleanupStaleActivities(activeRunIDs: Set<UUID> = []) async {
        guard Self.isSystemSupported else { return }
        for activity in Activity<HarnessActivityAttributes>.activities {
            guard let runID = UUID(uuidString: activity.attributes.runID),
                  activeRunIDs.contains(runID) else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            activities[runID] = activity
        }
        let staleRunIDs = Set(activities.keys).subtracting(activeRunIDs)
        for runID in staleRunIDs {
            clear(runID: runID)
        }
    }

    func start(
        runID: UUID,
        sessionID: UUID?,
        sessionTitle: String,
        status: ContinuedProcessingStatus,
        privacyModeEnabled: Bool,
        isEnabled: Bool
    ) async {
        guard isEnabled else {
            await end(runID: runID)
            return
        }
        guard areActivitiesEnabled else {
            logger.info("Live Activity start skipped because the system has disabled activities")
            return
        }

        let state = HarnessLiveActivityState.make(
            sessionTitle: sessionTitle,
            phase: .preparing,
            detail: status.subtitle,
            completedUnitCount: status.completedUnitCount,
            totalUnitCount: status.totalUnitCount,
            privacyModeEnabled: privacyModeEnabled
        )

        if activity(for: runID) != nil {
            await push(state, runID: runID)
            return
        }

        let attributes = HarnessActivityAttributes(
            runID: runID.uuidString.lowercased(),
            sessionID: sessionID?.uuidString.lowercased(),
            startedAt: .now
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: runningContent(for: state),
                pushType: nil
            )
            activities[runID] = activity
            projections.upsert(state, for: runID)
        } catch {
            logger.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(
        runID: UUID,
        sessionID: UUID?,
        sessionTitle: String,
        phase: HarnessLiveActivityPhase,
        status: ContinuedProcessingStatus,
        toolName: String? = nil,
        toolSummary: String? = nil,
        privacyModeEnabled: Bool,
        isEnabled: Bool
    ) async {
        guard isEnabled else {
            await end(runID: runID)
            return
        }
        guard areActivitiesEnabled else { return }

        if activity(for: runID) == nil {
            await start(
                runID: runID,
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                status: status,
                privacyModeEnabled: privacyModeEnabled,
                isEnabled: isEnabled
            )
        }

        let state = HarnessLiveActivityState.make(
            sessionTitle: sessionTitle,
            phase: phase,
            detail: status.subtitle,
            toolName: toolName,
            toolSummary: toolSummary,
            completedUnitCount: status.completedUnitCount,
            totalUnitCount: status.totalUnitCount,
            privacyModeEnabled: privacyModeEnabled
        )
        await push(state, runID: runID)
    }

    func finish(
        runID: UUID,
        phase: HarnessLiveActivityPhase,
        privacyModeEnabled: Bool
    ) async {
        guard phase.isTerminal else { return }
        guard let activity = activity(for: runID) else {
            clear(runID: runID)
            return
        }

        let previous = projections.states[runID] ?? HarnessLiveActivityState.make(
            sessionTitle: "Harness 任务",
            phase: phase,
            detail: "",
            completedUnitCount: 0,
            totalUnitCount: 1,
            privacyModeEnabled: privacyModeEnabled
        )
        let terminalState = HarnessLiveActivityState.make(
            sessionTitle: previous.sessionTitle,
            phase: phase,
            detail: "",
            completedUnitCount: phase == .completed
                ? previous.totalUnitCount
                : previous.completedUnitCount,
            totalUnitCount: previous.totalUnitCount,
            privacyModeEnabled: privacyModeEnabled
        )
        let dismissalDate = Date().addingTimeInterval(45)
        let content = ActivityContent(state: terminalState, staleDate: nil)
        await activity.end(content, dismissalPolicy: .after(dismissalDate))
        clear(runID: runID)
    }

    func applyPrivacyMode(_ privacyModeEnabled: Bool) async {
        for runID in Array(activities.keys) {
            guard let state = projections.states[runID] else { continue }
            let projected = HarnessLiveActivityState.make(
                sessionTitle: state.sessionTitle,
                phase: state.phase,
                detail: state.detail,
                toolName: state.toolName,
                toolSummary: state.toolSummary,
                completedUnitCount: state.completedUnitCount,
                totalUnitCount: state.totalUnitCount,
                privacyModeEnabled: privacyModeEnabled
            )
            await push(projected, runID: runID)
        }
    }

    func end(runID: UUID) async {
        guard let activity = activity(for: runID) else {
            clear(runID: runID)
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
        clear(runID: runID)
    }

    func endAll() async {
        guard Self.isSystemSupported else { return }
        for activity in Activity<HarnessActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activities.removeAll(keepingCapacity: false)
        projections.removeAll()
    }

    private func push(_ state: HarnessLiveActivityState, runID: UUID) async {
        guard let activity = activity(for: runID) else { return }
        if let lastState = projections.states[runID], lastState.hasSamePresentation(as: state) {
            return
        }
        await activity.update(runningContent(for: state))
        projections.upsert(state, for: runID)
    }

    private func activity(for runID: UUID) -> Activity<HarnessActivityAttributes>? {
        if let activity = activities[runID] {
            return activity
        }
        let identifier = runID.uuidString.lowercased()
        guard let restored = Activity<HarnessActivityAttributes>.activities.first(where: {
            $0.attributes.runID == identifier
        }) else {
            return nil
        }
        activities[runID] = restored
        return restored
    }

    private func runningContent(
        for state: HarnessLiveActivityState
    ) -> ActivityContent<HarnessLiveActivityState> {
        ActivityContent(
            state: state,
            staleDate: state.phase.isTerminal ? nil : Date().addingTimeInterval(5 * 60)
        )
    }

    private func clear(runID: UUID) {
        activities.removeValue(forKey: runID)
        projections.remove(runID: runID)
    }
}
#endif
