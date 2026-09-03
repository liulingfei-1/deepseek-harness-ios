import Foundation

/// Mirrors the upstream `api` domain's controller split as a protocol
/// surface: upstream hosts one controller per concern (session, settings,
/// workspace) behind the gateway; the mobile app keeps a single `AppModel`
/// actor but exposes the same per-concern boundaries through these
/// protocols, so feature views depend on the boundary, not the monolith.
/// Method shapes match the AppModel implementations exactly — the
/// conformance is asserted by the compiler in the AppModel extension.

/// Upstream `session-controller`: session lifecycle and the run surface.
@MainActor
protocol SessionControlling: AnyObject {
    var activeSessionID: UUID? { get }
    var sessions: [ConversationSessionSummary] { get }
    var isRunning: Bool { get }
    var messages: [AgentMessage] { get }

    func createConversation(title: String) async
    func switchConversation(to id: UUID) async
    func forkConversation(id: UUID) async
    func renameConversation(id: UUID, title: String) async
    func archiveConversation(id: UUID) async
    func restoreConversation(id: UUID) async
    func deleteConversation(id: UUID) async
    func regenerateConversationTitle(id: UUID) async
    func searchConversations(query: String) async -> [ConversationSessionSearchResult]
    func send(_ text: String, disposition: QueuedInputDisposition) async -> Bool
}

/// Upstream `settings-controller`: provider profiles, credentials and
/// user-facing configuration.
@MainActor
protocol SettingsControlling: AnyObject {
    func saveConfiguration(_ configuration: AgentConfiguration, apiKey: String) async throws
    func saveProviderProfile(
        _ profile: ProviderProfile,
        apiKey: String,
        makeActive: Bool,
        existingProfileID: String?
    ) async throws
}

/// Upstream `workspace-controller`: the private workspace file tree.
@MainActor
protocol WorkspaceControlling: AnyObject {
    func workspaceFileData(path: String) async throws -> Data
}
