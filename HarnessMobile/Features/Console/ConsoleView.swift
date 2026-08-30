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
            .background(HarnessTheme.surface)
            .accessibilityHint("在任务和轨迹之间切换")

            Divider()

            Group {
                switch selection {
                case .tasks:
                    WorkStateView()
                case .trajectory:
                    TrajectoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HarnessTheme.pageBackground)
        .navigationTitle(selection.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ConsoleSection: String, CaseIterable, Identifiable {
    case tasks
    case trajectory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "任务"
        case .trajectory: "轨迹"
        }
    }

    var navigationTitle: String {
        switch self {
        case .tasks: "任务状态"
        case .trajectory: "轨迹"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .trajectory: "point.3.connected.trianglepath.dotted"
        }
    }
}
