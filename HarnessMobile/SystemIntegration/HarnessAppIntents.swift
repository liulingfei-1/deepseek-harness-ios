import AppIntents
import Foundation
import Observation

@MainActor
@Observable
final class AppIntentRouter {
    struct Request: Equatable, Sendable, Identifiable {
        let id = UUID()
        let draft: String
    }

    static let shared = AppIntentRouter()

    var pendingRequest: Request?

    private init() {}

    func enqueueDraft(_ draft: String) {
        pendingRequest = Request(draft: draft)
    }

    func consume(_ id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }
}

struct ComposeHarnessTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "在 Harness 中开始任务"
    static let description = IntentDescription(
        "打开 Harness，并把任务放入输入框。模型请求只会在你确认发送后开始。"
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "任务",
        description: "要交给 Harness 的任务内容",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var task: String?

    func perform() async throws -> some IntentResult {
        let normalized = String(
            (task ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(4_096)
        )
        await MainActor.run {
            AppIntentRouter.shared.enqueueDraft(normalized)
        }
        return .result()
    }
}

struct HarnessAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ComposeHarnessTaskIntent(),
            phrases: [
                "用 \(.applicationName) 开始任务",
                "在 \(.applicationName) 中写任务"
            ],
            shortTitle: "开始 Harness 任务",
            systemImageName: "bolt.horizontal.circle"
        )
    }
}
