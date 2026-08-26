import Foundation
import SwiftUI

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import UIKit

final class HarnessMobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScheduleBackgroundController.registerLaunchHandler()
        return true
    }
}
#endif

@main
struct DeepSeekHarnessMobileApp: App {
    @State private var model = AppModel()
#if os(iOS) && canImport(BackgroundTasks)
    @UIApplicationDelegateAdaptor(HarnessMobileAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
                .environment(model.backgroundPreferences)
                .preferredColorScheme(uiTestingPreferredColorScheme)
                .task {
                    ISHGuestNetworkMonitor.shared.start()
                    HarnessLLMNetworkPathMonitor.shared.start()
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-reset-persistent-state-for-ui-testing") {
                        do {
                            try await model.resetPersistentStateForUITesting()
                        } catch {
                            // Test-only cleanup must never terminate the app.
                            // A stale simulator container or an interrupted
                            // previous reset is recoverable; surface it in the
                            // diagnostics UI and let normal bootstrap repair
                            // the remaining state.
                            model.presentError(
                                NSError(
                                    domain: "HarnessMobile.UITesting",
                                    code: 1,
                                    userInfo: [
                                        NSLocalizedDescriptionKey:
                                            "UI test cleanup failed: \(error.localizedDescription)"
                                    ]
                                )
                            )
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-bootstrap-configuration-for-ui-testing") {
                        do {
                            try await model.saveConfiguration(
                                AgentConfiguration(),
                                apiKey: "ui-test-placeholder-key"
                            )
                        } catch {
                            model.presentError(
                                NSError(
                                    domain: "HarnessMobile.UITesting",
                                    code: 2,
                                    userInfo: [
                                        NSLocalizedDescriptionKey:
                                            "UI test configuration failed: \(error.localizedDescription)"
                                    ]
                                )
                            )
                        }
                    }
#endif
                    await model.bootstrap()
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-present-plugin-market-for-ui-testing") {
                        model.presentPluginMarketplaceForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-plugin-compilation-failure-for-ui-testing") {
                        model.presentPluginCompilationFailureForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-plan-review-for-ui-testing") {
                        model.presentPlanReviewForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-long-conversation-for-ui-testing") {
                        model.presentLongConversationForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-concurrent-session-runs-for-ui-testing") {
                        await model.presentConcurrentSessionRunsForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-trajectory-for-ui-testing") {
                        await model.presentTrajectoryForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-markdown-table-for-ui-testing") {
                        model.presentMarkdownTableForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-large-markdown-for-ui-testing") {
                        model.presentLargeMarkdownForUITesting()
                    }
#endif
                }
        }
    }

    private var uiTestingPreferredColorScheme: ColorScheme? {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-force-dark-mode-for-ui-testing")
            ? .dark
            : nil
#else
        nil
#endif
    }
}
