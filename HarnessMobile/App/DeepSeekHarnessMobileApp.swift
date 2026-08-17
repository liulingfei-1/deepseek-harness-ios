import Foundation
import SwiftUI

@main
struct DeepSeekHarnessMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(model)
                .environment(model.backgroundPreferences)
                .task {
                    ISHGuestNetworkMonitor.shared.start()
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-reset-persistent-state-for-ui-testing") {
                        do {
                            try await model.resetPersistentStateForUITesting()
                        } catch {
                            fatalError("UI testing reset failed: \(error.localizedDescription)")
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains("-bootstrap-configuration-for-ui-testing") {
                        do {
                            try await model.saveConfiguration(
                                AgentConfiguration(),
                                apiKey: "ui-test-placeholder-key"
                            )
                        } catch {
                            fatalError("UI testing bootstrap failed: \(error.localizedDescription)")
                        }
                    }
#endif
                    await model.bootstrap()
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-present-plugin-market-for-ui-testing") {
                        model.presentPluginMarketplaceForUITesting()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-present-plan-review-for-ui-testing") {
                        model.presentPlanReviewForUITesting()
                    }
#endif
                }
        }
    }
}
