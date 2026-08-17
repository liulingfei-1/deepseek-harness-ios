import ActivityKit
import SwiftUI
import WidgetKit

struct HarnessLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HarnessActivityAttributes.self) { context in
            HarnessLockScreenActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Harness", systemImage: context.state.phase.systemImage)
                        .font(.caption.bold())
                        .foregroundStyle(context.state.phase.tint)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase.isTerminal {
                        Text(context.state.phase.shortTitle)
                            .font(.caption.bold())
                            .foregroundStyle(context.state.phase.tint)
                            .padding(.trailing, 4)
                    } else {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HarnessActivityDetailView(state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.systemImage)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                if context.state.phase.isTerminal {
                    Image(systemName: context.state.phase == .completed ? "checkmark" : "exclamationmark")
                        .foregroundStyle(context.state.phase.tint)
                } else {
                    Text(context.state.progressFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                Image(systemName: context.state.phase.systemImage)
                    .foregroundStyle(context.state.phase.tint)
            }
            .keylineTint(.cyan)
        }
    }
}

private struct HarnessLockScreenActivityView: View {
    let context: ActivityViewContext<HarnessActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: context.state.phase.systemImage)
                    .foregroundStyle(context.state.phase.tint)
                Text(context.state.sessionTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if context.state.phase.isTerminal {
                    Text(context.state.phase.shortTitle)
                        .font(.caption.bold())
                        .foregroundStyle(context.state.phase.tint)
                } else {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HarnessActivityDetailView(state: context.state)
        }
        .padding(16)
    }
}

private struct HarnessActivityDetailView: View {
    let state: HarnessLiveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: state.progressFraction)
                .tint(state.phase.tint)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let toolName = state.toolName {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text(toolName)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                Text(state.toolSummary ?? state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(state.completedUnitCount)/\(state.totalUnitCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension HarnessLiveActivityPhase {
    var systemImage: String {
        switch self {
        case .preparing:
            "hourglass"
        case .working:
            "brain.head.profile"
        case .usingTool:
            "wrench.and.screwdriver"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .interrupted:
            "pause.circle.fill"
        }
    }

    var shortTitle: String {
        switch self {
        case .preparing:
            "准备中"
        case .working:
            "执行中"
        case .usingTool:
            "工具"
        case .completed:
            "已完成"
        case .failed:
            "未完成"
        case .interrupted:
            "已中断"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .failed:
            .red
        case .interrupted:
            .yellow
        case .preparing, .working, .usingTool:
            .cyan
        }
    }
}
