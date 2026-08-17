import SwiftUI

struct ConsoleView: View {
    @State private var selection: ConsoleSection = .tasks

    var body: some View {
        VStack(spacing: 0) {
            Picker("控制台页面", selection: $selection) {
                ForEach(ConsoleSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            Group {
                switch selection {
                case .tasks:
                    WorkStateView()
                case .plugins:
                    PluginManagementView()
                case .trajectory:
                    TrajectoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selection.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case tasks
    case plugins
    case trajectory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "任务"
        case .plugins: "插件"
        case .trajectory: "轨迹"
        }
    }

    var navigationTitle: String {
        switch self {
        case .tasks: "任务状态"
        case .plugins: "插件"
        case .trajectory: "轨迹"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .plugins: "puzzlepiece.extension"
        case .trajectory: "point.3.connected.trianglepath.dotted"
        }
    }
}
