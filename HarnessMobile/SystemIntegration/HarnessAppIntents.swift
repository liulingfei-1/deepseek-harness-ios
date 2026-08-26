import AppIntents
import Foundation
import Observation

@MainActor
@Observable
final class AppIntentInboxNotifier {
    static let shared = AppIntentInboxNotifier()

    /// This is a wake-up signal only. Intent payloads are durably stored by
    /// `AppIntentInboxStore`, so concurrent invocations cannot overwrite one
    /// another while the app is suspended or not yet running.
    private(set) var revision = 0

    private init() {}

    func signalWorkAvailable() {
        revision &+= 1
    }
}

private enum HarnessAppIntentInbox {
    static let store = AppIntentInboxStore()

    static func enqueue(_ request: AppIntentInboxRequest) async throws {
        _ = try await store.enqueue(request)
        await MainActor.run {
            AppIntentInboxNotifier.shared.signalWorkAvailable()
        }
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
        let request = try AppIntentInboxRequest(
            action: .sendPrompt,
            prompt: task
        )
        try await HarnessAppIntentInbox.enqueue(request)
        return .result()
    }
}

struct ListHarnessSessionsIntent: AppIntent {
    static let title: LocalizedStringResource = "列出 Harness 会话"
    static let description = IntentDescription("列出本机 Harness 会话的标题、ID 和更新时间。")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let sessions = try await SessionStore().listSessions(includeArchived: false)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !sessions.isEmpty else {
            return .result(value: "没有可用会话。")
        }
        let formatter = ISO8601DateFormatter()
        let output = sessions.map { session in
            "\(session.title) | \(session.id.uuidString) | \(formatter.string(from: session.updatedAt))"
        }.joined(separator: "\n")
        return .result(value: output)
    }
}

struct GetHarnessSessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "获取 Harness 会话状态"
    static let description = IntentDescription("读取某个本机 Harness 会话的持久化状态和当前运行投影。")
    static let openAppWhenRun = false

    @Parameter(title: "会话 ID")
    var sessionID: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try Self.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        let isRunning = try await HarnessAppIntentInbox.store.isSessionRunning(id)
        let state = isRunning ? "运行中" : "空闲"
        return .result(
            value: "\(session.title) | \(id.uuidString) | \(state) | 消息 \(session.summary.messageCount) | \(ISO8601DateFormatter().string(from: session.updatedAt))"
        )
    }

    fileprivate static func parseSessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AppIntentInboxError.invalidRequest
        }
        return id
    }
}

struct OpenHarnessSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Harness 会话"
    static let description = IntentDescription("在 Harness 中打开指定的本机会话。")
    static let openAppWhenRun = true

    @Parameter(title: "会话 ID")
    var sessionID: String

    func perform() async throws -> some IntentResult {
        let id = try GetHarnessSessionStatusIntent.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        guard !session.isArchived else { throw SessionStoreError.sessionArchived(id) }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(action: .openSession, sessionID: id)
        )
        return .result()
    }
}

struct RetryHarnessSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "重试 Harness 会话"
    static let description = IntentDescription("从指定本机会话的最后一条用户消息重新执行。")
    static let openAppWhenRun = true

    @Parameter(title: "会话 ID")
    var sessionID: String

    func perform() async throws -> some IntentResult {
        let id = try GetHarnessSessionStatusIntent.parseSessionID(sessionID)
        let session = try await SessionStore().session(id: id)
        guard !session.isArchived else { throw SessionStoreError.sessionArchived(id) }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(action: .retryLatestUserMessage, sessionID: id)
        )
        return .result()
    }
}

struct SendHarnessPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "发送 Harness 任务"
    static let description = IntentDescription("在 Harness 中创建任务并按既有权限和审批策略执行。")
    static let openAppWhenRun = true

    @Parameter(title: "任务")
    var prompt: String

    @Parameter(title: "会话 ID", default: nil)
    var sessionID: String?

    func perform() async throws -> some IntentResult {
        let resolvedSessionID = try sessionID.map(GetHarnessSessionStatusIntent.parseSessionID)
        if let resolvedSessionID {
            let session = try await SessionStore().session(id: resolvedSessionID)
            guard !session.isArchived else { throw SessionStoreError.sessionArchived(resolvedSessionID) }
        }
        try await HarnessAppIntentInbox.enqueue(
            AppIntentInboxRequest(
                action: .sendPrompt,
                sessionID: resolvedSessionID,
                prompt: prompt
            )
        )
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
        AppShortcut(
            intent: SendHarnessPromptIntent(),
            phrases: [
                "用 \(.applicationName) 发送任务",
                "在 \(.applicationName) 中执行任务"
            ],
            shortTitle: "发送 Harness 任务",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: ListHarnessSessionsIntent(),
            phrases: ["列出 \(.applicationName) 会话"],
            shortTitle: "列出 Harness 会话",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: GetHarnessSessionStatusIntent(),
            phrases: ["获取 \(.applicationName) 会话状态"],
            shortTitle: "会话状态",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: OpenHarnessSessionIntent(),
            phrases: ["打开 \(.applicationName) 会话"],
            shortTitle: "打开 Harness 会话",
            systemImageName: "arrow.up.right.square"
        )
        AppShortcut(
            intent: RetryHarnessSessionIntent(),
            phrases: ["重试 \(.applicationName) 会话"],
            shortTitle: "重试 Harness 会话",
            systemImageName: "arrow.clockwise"
        )
    }
}
