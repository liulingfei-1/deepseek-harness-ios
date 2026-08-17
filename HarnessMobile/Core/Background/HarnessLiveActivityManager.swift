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
    private var currentActivity: Activity<HarnessActivityAttributes>?
    private var currentRunID: UUID?
    private var lastState: HarnessLiveActivityState?

    private init() {}

    func cleanupStaleActivities() async {
        guard Self.isSystemSupported else { return }
        for activity in Activity<HarnessActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        currentRunID = nil
        lastState = nil
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
            await endAll()
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

        if currentRunID == runID, currentActivity != nil {
            await push(state, runID: runID)
            return
        }

        await endAll()
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
            currentActivity = activity
            currentRunID = runID
            lastState = state
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

        if currentRunID != runID || activity(for: runID) == nil {
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
            clearIfMatching(runID)
            return
        }

        let previous = lastState ?? HarnessLiveActivityState.make(
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
        clearIfMatching(runID)
    }

    func applyPrivacyMode(_ privacyModeEnabled: Bool) async {
        guard let runID = currentRunID,
              let state = lastState,
              activity(for: runID) != nil else {
            return
        }
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

    func end(runID: UUID) async {
        guard let activity = activity(for: runID) else {
            clearIfMatching(runID)
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
        clearIfMatching(runID)
    }

    func endAll() async {
        guard Self.isSystemSupported else { return }
        for activity in Activity<HarnessActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        currentRunID = nil
        lastState = nil
    }

    private func push(_ state: HarnessLiveActivityState, runID: UUID) async {
        guard let activity = activity(for: runID) else { return }
        if let lastState, lastState.hasSamePresentation(as: state) { return }
        await activity.update(runningContent(for: state))
        self.lastState = state
    }

    private func activity(for runID: UUID) -> Activity<HarnessActivityAttributes>? {
        if currentRunID == runID, let currentActivity {
            return currentActivity
        }
        let identifier = runID.uuidString.lowercased()
        guard let restored = Activity<HarnessActivityAttributes>.activities.first(where: {
            $0.attributes.runID == identifier
        }) else {
            return nil
        }
        currentActivity = restored
        currentRunID = runID
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

    private func clearIfMatching(_ runID: UUID) {
        guard currentRunID == runID else { return }
        currentActivity = nil
        currentRunID = nil
        lastState = nil
    }
}
#endif
