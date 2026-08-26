import Foundation

/// Privacy-safe data shared by the main app and the WidgetKit extension.
///
/// This deliberately contains aggregate run state only. There is no session
/// title, prompt, tool argument, model output, credential, environment or
/// filesystem field, so the widget cannot become a second conversation store.
enum HarnessWidgetRunStatus: String, Codable, Sendable, Equatable {
    case preparing
    case running
    case cancelling
}

enum HarnessWidgetRunPhase: Sendable, Equatable {
    case idle
    case maintenance
    case running
    case cancelling
    case terminal
}

struct HarnessWidgetRunSnapshotInput: Sendable, Equatable {
    let sessionID: UUID
    let runID: UUID
    let phase: HarnessWidgetRunPhase
    let queuedInputCount: Int
}

struct HarnessWidgetSessionProjection: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let status: HarnessWidgetRunStatus
    let queuedInputCount: Int
}

struct HarnessWidgetProjection: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let maximumSessions = 32

    let version: Int
    let updatedAt: Date
    let activeRunCount: Int
    let privacyModeEnabled: Bool
    let sessions: [HarnessWidgetSessionProjection]

    static let empty = HarnessWidgetProjection(
        updatedAt: Date(timeIntervalSince1970: 0),
        activeRunCount: 0,
        privacyModeEnabled: true,
        sessions: []
    )

    init(
        updatedAt: Date = .now,
        activeRunCount: Int,
        privacyModeEnabled: Bool,
        sessions: [HarnessWidgetSessionProjection]
    ) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.activeRunCount = max(0, min(activeRunCount, Self.maximumSessions))
        self.privacyModeEnabled = privacyModeEnabled
        self.sessions = Array(sessions.prefix(Self.maximumSessions))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw HarnessWidgetProjectionError.unsupportedVersion
        }
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let activeRunCount = try container.decode(Int.self, forKey: .activeRunCount)
        let privacyModeEnabled = try container.decode(Bool.self, forKey: .privacyModeEnabled)
        let sessions = try container.decode([HarnessWidgetSessionProjection].self, forKey: .sessions)
        guard activeRunCount >= 0,
              sessions.count <= Self.maximumSessions,
              sessions.count == Set(sessions.map(\.id)).count,
              sessions.allSatisfy({ $0.queuedInputCount >= 0 }) else {
            throw HarnessWidgetProjectionError.invalidProjection
        }
        self.init(
            updatedAt: updatedAt,
            activeRunCount: activeRunCount,
            privacyModeEnabled: privacyModeEnabled,
            sessions: sessions
        )
    }
}

enum HarnessWidgetProjectionError: Error, Sendable, Equatable {
    case unavailable
    case unsupportedVersion
    case invalidProjection
}

enum HarnessWidgetProjectionStore {
    static let appGroupID = "group.com.llf.harnessmobile.share"
    private static let directoryName = "HarnessWidget"
    private static let filename = "projection.json"

    static func make(
        snapshots: [HarnessWidgetRunSnapshotInput],
        privacyModeEnabled: Bool,
        now: Date = .now
    ) -> HarnessWidgetProjection {
        let sessions = snapshots
            .sorted { lhs, rhs in
                if lhs.sessionID != rhs.sessionID {
                    return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                }
                return lhs.runID.uuidString < rhs.runID.uuidString
            }
            .compactMap { snapshot -> HarnessWidgetSessionProjection? in
                let status: HarnessWidgetRunStatus
                switch snapshot.phase {
                case .maintenance:
                    status = .preparing
                case .running:
                    status = .running
                case .cancelling:
                    status = .cancelling
                case .idle, .terminal:
                    return nil
                }
                return HarnessWidgetSessionProjection(
                    id: snapshot.sessionID,
                    runID: snapshot.runID,
                    status: status,
                    queuedInputCount: snapshot.queuedInputCount
                )
            }
        return HarnessWidgetProjection(
            updatedAt: now,
            activeRunCount: sessions.count,
            privacyModeEnabled: privacyModeEnabled,
            sessions: sessions
        )
    }

    @discardableResult
    static func write(
        _ projection: HarnessWidgetProjection,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let directory = containerDirectory(fileManager: fileManager) else {
            throw HarnessWidgetProjectionError.unavailable
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(projection)
        try data.write(to: url, options: protectedWritingOptions)
        return url
    }

    static func read(fileManager: FileManager = .default) -> HarnessWidgetProjection {
        guard let directory = containerDirectory(fileManager: fileManager) else { return .empty }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(HarnessWidgetProjection.self, from: data)
        } catch {
            return .empty
        }
    }

    static func deepLink(for sessionID: UUID) -> URL {
        URL(string: "harnessmobile://session/\(sessionID.uuidString.lowercased())")!
    }

    static func sessionID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "harnessmobile",
              url.host?.lowercased() == "session",
              url.query == nil,
              url.fragment == nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else { return nil }
        return UUID(uuidString: components[0])
    }

    private static func containerDirectory(fileManager: FileManager) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }
}
