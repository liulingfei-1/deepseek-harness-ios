import Combine
import Foundation
import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath: [AppRoute] = []
    @State private var intentInboxNotifier = AppIntentInboxNotifier.shared
    @State private var pendingWidgetSessionDeepLink: UUID?

    private var stateTransitionAnimation: Animation? {
        ProcessInfo.processInfo.arguments.contains("-disable-animations-for-ui-testing")
            ? nil
            : .default
    }

    private var isPluginMarketPreviewRequested: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-present-plugin-market-for-ui-testing")
            || arguments.contains("-present-plugin-compilation-failure-for-ui-testing")
#else
        false
#endif
    }

    var body: some View {
        Group {
            if !model.isReady {
                ProgressView("正在载入本地会话…")
            } else if isPluginMarketPreviewRequested {
                NavigationStack {
                    CommunityPluginMarketView()
                }
            } else if !model.isConfigured {
                SetupView(mode: .onboarding)
            } else {
                appShell
            }
        }
        .animation(stateTransitionAnimation, value: model.isReady)
        .animation(stateTransitionAnimation, value: model.isConfigured)
        .task {
            handlePendingIntent()
        }
        .onOpenURL { url in
            pendingWidgetSessionDeepLink = HarnessWidgetProjectionStore.sessionID(from: url)
            handlePendingIntent()
        }
        .onChange(of: intentInboxNotifier.revision) {
            handlePendingIntent()
        }
        .onChange(of: model.isReady) {
            handlePendingIntent()
        }
        .onChange(of: model.isConfigured) {
            handlePendingIntent()
        }
        .onChange(of: model.backgroundPreferences.isEnhancedBackgroundEnabled) {
            model.refreshBackgroundAudioKeepAlive()
        }
        .onChange(of: model.backgroundPreferences.isBackgroundLocationKeepAliveEnabled) {
            model.refreshBackgroundLocationKeepAlive()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            handleScenePhase(phase)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ProcessInfo.thermalStateDidChangeNotification
            )
        ) { _ in
            refreshISHExecutionEnvironment()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSProcessInfoPowerStateDidChange
            )
        ) { _ in
            refreshISHExecutionEnvironment()
        }
    }

    @ViewBuilder
    private var appShell: some View {
        NavigationStack(path: $navigationPath) {
            SessionsView(
                onConversationOpened: openChat,
                onOpenSettings: { navigationPath.append(.settings) },
                onOpenTools: { navigationPath.append(.tools) }
            )
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .chat:
                    ChatView()
                case .tools:
                    HarnessToolsView(navigate: { navigationPath.append($0) })
                case .console:
                    ConsoleView()
                case .workspace:
                    WorkspaceView()
                case .terminal:
                    ISHTerminalView()
                case .plugins:
                    PluginManagementView()
                case .settings:
                    SettingsView()
                case .backgroundSettings:
                    BackgroundSettingsView(
                        runtimeStatus: model.backgroundRuntimeStatus,
                        locationSnapshot: model.backgroundLocationKeepAliveSnapshot,
                        systemProjection: model.backgroundSystemProjection,
                        requestLocationAuthorization: model.requestBackgroundLocationAuthorization
                    )
                }
            }
        }
    }

    private func handlePendingIntent() {
        Task { @MainActor in
            let consumedIntent = await model.consumeAppIntentInbox()
            let consumedShare = await model.consumeShareHandoffs()
            var consumedWidgetDeepLink = false
            if let sessionID = pendingWidgetSessionDeepLink,
               model.isReady,
               model.isConfigured {
                await model.switchConversation(to: sessionID)
                consumedWidgetDeepLink = model.activeSessionID == sessionID
                pendingWidgetSessionDeepLink = nil
            }
            if consumedIntent || consumedShare || consumedWidgetDeepLink {
                openChat()
            }
        }
    }

    private func openChat() {
        if navigationPath.last != .chat {
            navigationPath = [.chat]
        }
    }

    private func refreshISHExecutionEnvironment(isBackgrounded: Bool? = nil) {
        let isBackgrounded = isBackgrounded ?? (scenePhase != .active)
        Task {
            await ISHSandboxCoordinator.shared.updateExecutionEnvironment(
                isBackgrounded: isBackgrounded
            )
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        model.updateApplicationActivity(
            isActive: phase == .active,
            isBackgrounded: phase == .background
        )
        refreshISHExecutionEnvironment(isBackgrounded: phase != .active)
        if phase == .active {
            handlePendingIntent()
        }
    }
}

private enum AppRoute: Hashable {
    case chat
    case tools
    case console
    case workspace
    case terminal
    case plugins
    case settings
    case backgroundSettings
}

private struct HarnessToolsView: View {
    let navigate: (AppRoute) -> Void

    var body: some View {
        List {
            Section("工作") {
                toolRow(
                    title: "iSH 终端",
                    detail: "在手机 Alpine 沙箱中执行命令",
                    systemImage: "terminal.fill",
                    tint: .black,
                    accessibilityIdentifier: "tool-route-terminal",
                    route: .terminal
                )
                toolRow(
                    title: "任务与轨迹",
                    detail: "目标、计划、待办与 Harness 调用链",
                    systemImage: "rectangle.3.group",
                    tint: .blue,
                    accessibilityIdentifier: "tool-route-console",
                    route: .console
                )
                toolRow(
                    title: "工作区",
                    detail: "导入、查看与导出本机会话文件",
                    systemImage: "folder.fill",
                    tint: .orange,
                    accessibilityIdentifier: "tool-route-workspace",
                    route: .workspace
                )
            }

            Section("扩展") {
                toolRow(
                    title: "Cordis 插件",
                    detail: "管理原生插件、社区插件与动态贡献",
                    systemImage: "puzzlepiece.extension.fill",
                    tint: .purple,
                    accessibilityIdentifier: "tool-route-plugins",
                    route: .plugins
                )
                toolRow(
                    title: "设置",
                    detail: "模型服务商、权限、后台任务与运行环境",
                    systemImage: "gearshape.fill",
                    tint: .gray,
                    accessibilityIdentifier: "tool-route-settings",
                    route: .settings
                )
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("工具")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toolRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        accessibilityIdentifier: String,
        route: AppRoute
    ) -> some View {
        Button {
            navigate(route)
        } label: {
            HStack(spacing: 12) {
                HarnessIconTile(systemImage: systemImage, tint: tint, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
