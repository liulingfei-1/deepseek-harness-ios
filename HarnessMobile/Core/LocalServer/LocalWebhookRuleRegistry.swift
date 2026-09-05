import Foundation

/// A persisted, provider-neutral webhook rule. The mobile rule language is
/// deliberately small: matching is by provider kind and event name, and the
/// action is a local Job with an optional active-session wake-up.
struct LocalWebhookRule: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let providerKind: String
    let eventName: String
    let jobLabel: String
    let prompt: String?
    let maximumAttempts: Int
    let wakeActiveSession: Bool

    init(
        id: String,
        providerKind: String = "github",
        eventName: String = "*",
        jobLabel: String? = nil,
        prompt: String? = nil,
        maximumAttempts: Int = 1,
        wakeActiveSession: Bool = false
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = providerKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEvent = eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLabel = (jobLabel ?? normalizedEvent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, normalizedID.utf8.count <= 96,
              !normalizedProvider.isEmpty, normalizedProvider.utf8.count <= 64,
              !normalizedEvent.isEmpty, normalizedEvent.utf8.count <= 96,
              !normalizedLabel.isEmpty, normalizedLabel.utf8.count <= 128,
              (1...5).contains(maximumAttempts) else {
            throw LocalWebhookRuleError.invalidRule
        }
        if let prompt, prompt.utf8.count > 8_192 { throw LocalWebhookRuleError.invalidRule }
        self.id = normalizedID
        self.providerKind = normalizedProvider
        self.eventName = normalizedEvent
        self.jobLabel = normalizedLabel
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maximumAttempts = maximumAttempts
        self.wakeActiveSession = wakeActiveSession
    }

    func matches(_ event: LocalWebhookEvent) -> Bool {
        providerKind == event.providerKind.lowercased()
            && (eventName == "*" || eventName == event.eventName.lowercased())
    }

    func renderedPrompt(for event: LocalWebhookEvent) -> String {
        let fallback = "处理 \(event.providerKind) webhook：\(event.eventName)\n\n\(event.payload.displayText)"
        guard let prompt, !prompt.isEmpty else { return fallback }
        return prompt
            .replacingOccurrences(of: "{event}", with: event.eventName)
            .replacingOccurrences(of: "{delivery}", with: event.deliveryID)
            .replacingOccurrences(of: "{payload}", with: event.payload.displayText)
    }

    static func defaultJob(for event: LocalWebhookEvent) -> LocalWebhookRule {
        try! LocalWebhookRule(
            id: "\(event.providerKind)-default",
            providerKind: event.providerKind,
            eventName: "*",
            jobLabel: event.eventName
        )
    }
}

enum LocalWebhookRuleError: LocalizedError, Sendable, Equatable {
    case invalidRule
    case duplicateID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRule: "Webhook rule 无效。"
        case let .duplicateID(id): "Webhook rule 已存在：\(id)"
        }
    }
}

/// Durable rule registry shared by the loopback listener and AppModel.
actor LocalWebhookRuleRegistry {
    private let storageURL: URL?
    private var rulesByID: [String: LocalWebhookRule]

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([LocalWebhookRule].self, from: data) {
            rulesByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            rulesByID = [:]
        }
    }

    func list() -> [LocalWebhookRule] {
        rulesByID.values.sorted { $0.id < $1.id }
    }

    func upsert(_ rule: LocalWebhookRule) throws {
        rulesByID[rule.id] = rule
        try persist()
    }

    func remove(id: String) throws {
        rulesByID.removeValue(forKey: id)
        try persist()
    }

    func matching(_ event: LocalWebhookEvent) -> [LocalWebhookRule] {
        list().filter { $0.matches(event) }
    }

    private func persist() throws {
        guard let storageURL else { return }
        let data = try JSONEncoder().encode(list())
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: .atomic)
    }
}
