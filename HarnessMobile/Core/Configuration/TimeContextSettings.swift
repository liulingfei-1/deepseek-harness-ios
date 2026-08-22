import Foundation

struct TimeContextSettings: Codable, Sendable, Equatable {
    static let defaultRefreshIntervalMilliseconds = 60_000
    static let maximumRefreshIntervalMilliseconds = 86_400_000

    var isEnabled: Bool
    var timeZoneIdentifier: String?
    var refreshIntervalMilliseconds: Int

    init(
        isEnabled: Bool = false,
        timeZoneIdentifier: String? = nil,
        refreshIntervalMilliseconds: Int = Self.defaultRefreshIntervalMilliseconds
    ) {
        self.isEnabled = isEnabled
        self.timeZoneIdentifier = timeZoneIdentifier
        self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
    }

    func validated() throws -> Self {
        guard refreshIntervalMilliseconds >= 0,
              refreshIntervalMilliseconds <= Self.maximumRefreshIntervalMilliseconds else {
            throw TimeContextSettingsError.invalidRefreshInterval
        }
        if let timeZoneIdentifier {
            guard timeZoneIdentifier == "UTC" || TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw TimeContextSettingsError.invalidTimeZone(timeZoneIdentifier)
            }
        }
        return self
    }
}

enum TimeContextSettingsError: LocalizedError, Equatable {
    case invalidRefreshInterval
    case invalidTimeZone(String)

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval:
            return "时间上下文刷新间隔必须在 0 到 24 小时之间。"
        case let .invalidTimeZone(identifier):
            return "无法识别时区“\(identifier)”。"
        }
    }
}

enum TimeContextOverlay {
    static let pluginID = "@deepseek-ai/dsh-time-context"

    static func injection(
        settings: TimeContextSettings,
        messages: [AgentMessage],
        turn: Int,
        step: Int,
        now: Date
    ) throws -> AgentRuntimeInstructionInjection? {
        let settings = try settings.validated()
        guard settings.isEnabled else { return nil }

        let latestInjection = messages.last(where: { message in
            message.source?.objectValue?["plugin"]?.stringValue == pluginID
        })
        if settings.refreshIntervalMilliseconds > 0,
           let latestInjection,
           now.timeIntervalSince(latestInjection.createdAt) >= 0,
           now.timeIntervalSince(latestInjection.createdAt) * 1_000
            < Double(settings.refreshIntervalMilliseconds) {
            return nil
        }

        let timeZone = try resolvedTimeZone(settings.timeZoneIdentifier)
        let precedingDate: Date?
        let baseline: String
        if step == 1 {
            precedingDate = messages.last(where: { message in
                message.source?.objectValue?["plugin"]?.stringValue != pluginID
            })?.createdAt
            baseline = "model-visible message"
        } else {
            precedingDate = latestInjection?.createdAt
            baseline = "step context"
        }
        let elapsed = precedingDate.map { formatDuration(now.timeIntervalSince($0)) } ?? "unavailable"
        let zoneIdentifier = settings.timeZoneIdentifier ?? timeZone.identifier
        let text = [
            "Time sampled while preparing turn \(turn), step \(step): \(formatTimestamp(now, timeZone: timeZone))[\(zoneIdentifier)]",
            "Browser time zone for this request: \(zoneIdentifier). Interpret otherwise-unqualified dates and times in this zone.",
            "Elapsed since the preceding \(baseline): \(elapsed)."
        ].joined(separator: "\n")
        return AgentRuntimeInstructionInjection(
            content: text,
            source: .object([
                "kind": .string("plugin"),
                "plugin": .string(pluginID),
                "form": .string("snapshot"),
                "sections": .array([
                    .object([
                        "name": .string("time-context"),
                        "text": .string(text)
                    ])
                ])
            ])
        )
    }

    private static func resolvedTimeZone(_ identifier: String?) throws -> TimeZone {
        guard let identifier else { return .current }
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw TimeContextSettingsError.invalidTimeZone(identifier)
        }
        return timeZone
    }

    private static func formatTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        let formatted = formatter.string(from: date)
        return formatted.hasSuffix("Z")
            ? String(formatted.dropLast()) + "+00:00"
            : formatted
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        var seconds = max(0, Int(interval.rounded(.down)))
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3_600
        seconds %= 3_600
        let minutes = seconds / 60
        seconds %= 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }
}
