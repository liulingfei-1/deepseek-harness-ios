import Combine
import Foundation
import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath: [AppRoute] = []
    @State private var intentRouter = AppIntentRouter.shared

    private var stateTransitionAnimation: Animation? {
        ProcessInfo.processInfo.arguments.contains("-disable-animations-for-ui-testing")
            ? nil
            : .default
    }

    private var isPluginMarketPreviewRequested: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-present-plugin-market-for-ui-testing")
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
        .onChange(of: intentRouter.pendingRequest) {
            handlePendingIntent()
        }
        .onChange(of: model.isReady) {
            handlePendingIntent()
        }
        .onChange(of: model.isConfigured) {
            handlePendingIntent()
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
                onOpenTerminal: { navigationPath.append(.terminal) },
                onOpenWorkspace: { navigationPath.append(.workspace) },
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
                }
            }
        }
    }

    private func handlePendingIntent() {
        guard model.isReady, model.isConfigured,
              let request = intentRouter.pendingRequest else { return }
        model.pendingDraft = request.draft
        openChat()
        intentRouter.consume(request.id)
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
        model.updateApplicationActivity(isActive: phase == .active)
        refreshISHExecutionEnvironment(isBackgrounded: phase != .active)
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
}

private struct HarnessToolsView: View {
    let navigate: (AppRoute) -> Void

    var body: some View {
        List {
            Section("工作") {
                toolRow(
                    title: "任务与轨迹",
                    detail: "Goal、Plan、Todo 与 Harness 调用链",
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
                toolRow(
                    title: "iSH 终端",
                    detail: "在手机 Alpine 沙箱中执行命令",
                    systemImage: "terminal.fill",
                    tint: .black,
                    accessibilityIdentifier: "tool-route-terminal",
                    route: .terminal
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
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
