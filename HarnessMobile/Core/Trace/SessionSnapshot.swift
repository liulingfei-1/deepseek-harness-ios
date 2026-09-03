import Foundation

/// SwiftPM equivalent of the desktop `session-snapshot` support: recorded
/// sessions become closed, normalized, credential-scrubbed fixtures that a
/// test replays against fresh output. Volatile fields (sequence numbers,
/// timestamps, generated ids) are normalized away so only structural and
/// content changes break replay; setting `SNAPSHOT_UPDATE=1` rewrites the
/// fixture instead (the desktop's refresh mode).
enum SessionSnapshot {
    static let updateEnvironmentKey = "SNAPSHOT_UPDATE"

    // MARK: Manifest

    struct Manifest: Codable, Sendable, Equatable {
        let scenario: String
        let fixture: String
        let eventCount: Int
        let recordedAt: String
    }

    // MARK: Normalization

    /// Replaces values that legitimately differ between runs: numeric
    /// sequence/time fields, uuid-shaped strings, and credential-shaped
    /// strings. Structure and human-readable content stay comparable.
    static func normalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .string(text):
            return .string(normalizedString(text))
        case let .number(number):
            // Sequence/time-like numbers are volatile by construction.
            return .string("<number>")
        case let .object(object):
            var normalizedObject: [String: JSONValue] = [:]
            for (key, entry) in object {
                if key == "seq" || key == "time" || key == "id" {
                    normalizedObject[key] = .string("<normalized>")
                } else {
                    normalizedObject[key] = normalized(entry)
                }
            }
            return .object(normalizedObject)
        case let .array(array):
            return .array(array.map(normalized))
        case .bool, .null:
            return value
        }
    }

    static func normalizedString(_ text: String) -> String {
        // Credential-shaped strings (provider keys) never enter a fixture.
        if text.contains("sk-") {
            return "[credential-shaped text removed]"
        }
        // UUID-shaped identifiers are minted per run.
        let uuid = UUID(uuidString: text)
        if uuid != nil {
            return "<uuid>"
        }
        return text
    }

    // MARK: Record / replay

    struct Snapshot: Codable, Sendable, Equatable {
        let scenario: String
        let events: [JSONValue]
    }

    /// Encodes the recorded event list into fixture JSON.
    static func fixtureData(scenario: String, events: [SessionEvent]) throws -> Data {
        let normalizedEvents = events.map { normalizedEvent($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Snapshot(scenario: scenario, events: normalizedEvents))
    }

    static func normalizedEvent(_ event: SessionEvent) -> JSONValue {
        .object([
            "type": .string(event.type),
            "data": normalized(event.data)
        ])
    }

    /// Replays a fixture against fresh events. Returns the first mismatch
    /// description, or nil when the shapes match exactly.
    static func replay(fixture: Data, against events: [SessionEvent]) throws -> String? {
        let decoder = JSONDecoder()
        let recorded = try decoder.decode(Snapshot.self, from: fixture)
        let fresh = events.map { normalizedEvent($0) }
        if recorded.events.count != fresh.count {
            return "event count mismatch: recorded \(recorded.events.count), fresh \(fresh.count)"
        }
        for (index, pair) in zip(recorded.events, fresh).enumerated() {
            if pair.0 != pair.1 {
                return "event \(index) mismatch: recorded \(String(describing: pair.0)) vs fresh \(String(describing: pair.1))"
            }
        }
        return nil
    }

    /// Loads the fixture, or — in refresh mode (`SNAPSHOT_UPDATE=1`) — writes
    /// the fresh events over it and reports that the refresh happened.
    static func loadOrRefreshFixture(
        fixtureURL: URL,
        scenario: String,
        events: [SessionEvent]
    ) throws -> (fixture: Data, refreshed: Bool) {
        let updateRequested = ProcessInfo.processInfo.environment[updateEnvironmentKey] == "1"
        if updateRequested || !FileManager.default.fileExists(atPath: fixtureURL.path) {
            let data = try fixtureData(scenario: scenario, events: events)
            try data.write(to: fixtureURL, options: .atomic)
            return (data, true)
        }
        return (try Data(contentsOf: fixtureURL), false)
    }
}
