import Foundation
#if os(iOS) && canImport(WidgetKit)
import WidgetKit
#endif

extension AppModel {
    /// Publishes only the bounded, privacy-safe live-run projection consumed by
    /// WidgetKit. The widget never receives conversation text or an execution
    /// capability, and a write failure cannot affect the Agent run.
    func refreshWidgetProjection() {
        let projection = HarnessWidgetProjectionStore.make(
            snapshots: sessionRunSnapshots.values.map { snapshot in
                HarnessWidgetRunSnapshotInput(
                    sessionID: snapshot.identity.sessionID,
                    runID: snapshot.identity.runID,
                    phase: Self.widgetPhase(for: snapshot.phase),
                    queuedInputCount: snapshot.presentation.queuedInputs.count
                )
            },
            privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled
        )
        do {
            try HarnessWidgetProjectionStore.write(projection)
        } catch {
            // Widget delivery is auxiliary. Keep the main app/session state
            // authoritative and record only a bounded diagnostic fact.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await traceStore.record(
                    HarnessTraceDraft(
                        kind: .error,
                        name: "widget_projection_write_failed",
                        error: String(describing: error)
                    )
                )
            }
        }
#if os(iOS) && canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "HarnessSessionWidget")
#endif
    }

    private static func widgetPhase(for phase: MobileAgentPhase) -> HarnessWidgetRunPhase {
        switch phase {
        case .idle: .idle
        case .maintenance: .maintenance
        case .running: .running
        case .cancelling: .cancelling
        case .terminal: .terminal
        }
    }
}
