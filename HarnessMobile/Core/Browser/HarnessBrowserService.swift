import Foundation

enum HarnessBrowserAction: String, Codable, Sendable, Equatable {
    case open
    case navigate
    case readText
    case screenshot
    case close
    case listTabs
}

struct HarnessBrowserRequest: Codable, Sendable, Equatable {
    let sessionID: String
    let tabID: UUID
    let action: HarnessBrowserAction
    let url: URL?
}

struct HarnessBrowserResult: Codable, Sendable, Equatable {
    static let maximumTextUTF8Bytes = 48 * 1_024
    static let maximumTitleUTF8Bytes = 512
    static let maximumScreenshotBase64Bytes = 2 * 1_024 * 1_024

    let tabID: UUID?
    let action: HarnessBrowserAction
    let pageURL: URL?
    let title: String?
    let text: String?
    let screenshotBase64: String?
    let tabIDs: [UUID]
    let evictedTabID: UUID?
}

struct HarnessBrowserTabDescriptor: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: String
    let pageURL: URL?
    let lastUsedAt: Date
}

enum HarnessBrowserServiceError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case invalidSession
    case invalidAction
    case invalidURL
    case tabNotFound
    case resultTooLarge
    case backendFailure

    var errorDescription: String? {
        switch self {
        case .unavailable: "本机浏览器服务当前不可用。"
        case .invalidSession: "浏览器会话标识无效。"
        case .invalidAction: "浏览器动作不受支持。"
        case .invalidURL: "浏览器仅允许不含凭据的 HTTP/HTTPS 地址。"
        case .tabNotFound: "找不到当前会话的浏览器标签页。"
        case .resultTooLarge: "浏览器结果超过本机输出上限。"
        case .backendFailure: "本机浏览器页面未能完成动作。"
        }
    }
}

protocol HarnessBrowserBackend: Sendable {
    func perform(_ request: HarnessBrowserRequest) async throws -> HarnessBrowserResult
    func discard(sessionID: String, tabID: UUID) async
}

extension HarnessBrowserBackend {
    func discard(sessionID _: String, tabID _: UUID) async {}
}

struct UnavailableHarnessBrowserBackend: HarnessBrowserBackend {
    func perform(_: HarnessBrowserRequest) async throws -> HarnessBrowserResult {
        throw HarnessBrowserServiceError.unavailable
    }
}

/// Actor-owned browser lifecycle. The backend is the only place allowed to
/// touch the platform renderer; this actor owns session isolation, tab caps
/// and eviction.
actor HarnessBrowserService {
    static let shared = HarnessBrowserService(backend: HarnessBrowserPlatformBackend())
    static let maximumTabsPerSession = 3
    static let maximumTotalTabs = 6
    static let maximumSessionIDUTF8Bytes = 256

    private struct Tab: Sendable {
        let id: UUID
        let sessionID: String
        var pageURL: URL?
        var lastUsedAt: Date
    }

    private let backend: any HarnessBrowserBackend
    private var tabs: [UUID: Tab] = [:]

    init(backend: any HarnessBrowserBackend = HarnessBrowserPlatformBackend()) {
        self.backend = backend
    }

    func execute(
        sessionID rawSessionID: String,
        action: HarnessBrowserAction,
        tabID: UUID? = nil,
        url: URL? = nil,
        now: Date = .now
    ) async throws -> HarnessBrowserResult {
        let sessionID = try Self.normalizeSessionID(rawSessionID)
        switch action {
        case .listTabs:
            guard tabID == nil, url == nil else { throw HarnessBrowserServiceError.invalidAction }
            let ids = tabs.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.lastUsedAt < $1.lastUsedAt }
                .map(\.id)
            return try Self.validatedResult(
                HarnessBrowserResult(
                    tabID: nil,
                    action: action,
                    pageURL: nil,
                    title: nil,
                    text: nil,
                    screenshotBase64: nil,
                    tabIDs: ids,
                    evictedTabID: nil
                )
            )

        case .open:
            guard tabID == nil, let url else { throw HarnessBrowserServiceError.invalidAction }
            let pageURL = try Self.validateURL(url)
            let evictedTabID = evictIfNeeded(for: sessionID, now: now)
            if let evictedTabID {
                await backend.discard(sessionID: sessionID, tabID: evictedTabID)
            }
            let newTabID = UUID()
            tabs[newTabID] = Tab(
                id: newTabID,
                sessionID: sessionID,
                pageURL: pageURL,
                lastUsedAt: now
            )
            let request = HarnessBrowserRequest(
                sessionID: sessionID,
                tabID: newTabID,
                action: action,
                url: pageURL
            )
            do {
                let result = try await backend.perform(request)
                return try Self.validatedResult(Self.withEviction(result, evictedTabID: evictedTabID))
            } catch {
                tabs.removeValue(forKey: newTabID)
                throw Self.mapBackendError(error)
            }

        case .navigate:
            guard let tabID, let url else { throw HarnessBrowserServiceError.invalidAction }
            let pageURL = try Self.validateURL(url)
            var tab = try tab(for: tabID, sessionID: sessionID)
            tab.pageURL = pageURL
            tab.lastUsedAt = now
            tabs[tabID] = tab
            do {
                let result = try await backend.perform(
                    HarnessBrowserRequest(
                        sessionID: sessionID,
                        tabID: tabID,
                        action: action,
                        url: pageURL
                    )
                )
                return try Self.validatedResult(result)
            } catch {
                throw Self.mapBackendError(error)
            }

        case .readText, .screenshot:
            guard let tabID, url == nil else { throw HarnessBrowserServiceError.invalidAction }
            var tab = try tab(for: tabID, sessionID: sessionID)
            tab.lastUsedAt = now
            tabs[tabID] = tab
            do {
                return try Self.validatedResult(
                    try await backend.perform(
                        HarnessBrowserRequest(
                            sessionID: sessionID,
                            tabID: tabID,
                            action: action,
                            url: nil
                        )
                    )
                )
            } catch {
                throw Self.mapBackendError(error)
            }

        case .close:
            guard let tabID, url == nil else { throw HarnessBrowserServiceError.invalidAction }
            _ = try tab(for: tabID, sessionID: sessionID)
            do {
                let result = try await backend.perform(
                    HarnessBrowserRequest(
                        sessionID: sessionID,
                        tabID: tabID,
                        action: action,
                        url: nil
                    )
                )
                tabs.removeValue(forKey: tabID)
                return try Self.validatedResult(result)
            } catch {
                throw Self.mapBackendError(error)
            }
        }
    }

    func descriptors(sessionID rawSessionID: String) throws -> [HarnessBrowserTabDescriptor] {
        let sessionID = try Self.normalizeSessionID(rawSessionID)
        return tabs.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
            .map {
                HarnessBrowserTabDescriptor(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    pageURL: $0.pageURL,
                    lastUsedAt: $0.lastUsedAt
                )
            }
    }

    private func tab(for id: UUID, sessionID: String) throws -> Tab {
        guard let tab = tabs[id], tab.sessionID == sessionID else {
            throw HarnessBrowserServiceError.tabNotFound
        }
        return tab
    }

    @discardableResult
    private func evictIfNeeded(for sessionID: String, now: Date) -> UUID? {
        let sessionTabs = tabs.values.filter { $0.sessionID == sessionID }
        let candidate: Tab?
        if sessionTabs.count >= Self.maximumTabsPerSession {
            candidate = sessionTabs.min { $0.lastUsedAt < $1.lastUsedAt }
        } else if tabs.count >= Self.maximumTotalTabs {
            candidate = tabs.values.min { $0.lastUsedAt < $1.lastUsedAt }
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        tabs.removeValue(forKey: candidate.id)
        _ = now
        return candidate.id
    }

    private static func normalizeSessionID(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumSessionIDUTF8Bytes,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HarnessBrowserServiceError.invalidSession
        }
        return normalized
    }

    private static func validateURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= 4_096 else {
            throw HarnessBrowserServiceError.invalidURL
        }
        return url
    }

    private static func validatedResult(_ result: HarnessBrowserResult) throws -> HarnessBrowserResult {
        if let text = result.text, text.utf8.count > HarnessBrowserResult.maximumTextUTF8Bytes {
            throw HarnessBrowserServiceError.resultTooLarge
        }
        if let title = result.title, title.utf8.count > HarnessBrowserResult.maximumTitleUTF8Bytes {
            throw HarnessBrowserServiceError.resultTooLarge
        }
        if let screenshot = result.screenshotBase64,
           screenshot.utf8.count > HarnessBrowserResult.maximumScreenshotBase64Bytes {
            throw HarnessBrowserServiceError.resultTooLarge
        }
        guard result.tabIDs.count <= maximumTabsPerSession else {
            throw HarnessBrowserServiceError.resultTooLarge
        }
        return result
    }

    private static func withEviction(
        _ result: HarnessBrowserResult,
        evictedTabID: UUID?
    ) -> HarnessBrowserResult {
        HarnessBrowserResult(
            tabID: result.tabID,
            action: result.action,
            pageURL: result.pageURL,
            title: result.title,
            text: result.text,
            screenshotBase64: result.screenshotBase64,
            tabIDs: result.tabIDs,
            evictedTabID: evictedTabID
        )
    }

    private static func mapBackendError(_ error: Error) -> Error {
        if let typed = error as? HarnessBrowserServiceError { return typed }
        return HarnessBrowserServiceError.backendFailure
    }
}
