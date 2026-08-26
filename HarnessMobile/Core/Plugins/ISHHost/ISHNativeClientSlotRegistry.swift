import Foundation

private let ishNativeClientSlotMaximumJSONSafeInteger: UInt64 = 9_007_199_254_740_991

enum ISHNativeClientSlotKind: String, Codable, Sendable, Equatable {
    case settingsCard = "settings.card"
    case conversationRenderer = "conversation.renderer"
    case sidebarAction = "sidebar.action"
}

enum ISHNativeClientSlotRegistryError: LocalizedError, Sendable, Equatable {
    case invalidContribution(pluginID: String, reason: String)
    case duplicateContribution(String)
    case staleContribution(String)

    var errorDescription: String? {
        switch self {
        case let .invalidContribution(pluginID, reason):
            return "Native client slot contribution for \(pluginID) is invalid: \(reason)"
        case let .duplicateContribution(id):
            return "Native client slot contribution \(id) is already registered."
        case let .staleContribution(id):
            return "Native client slot contribution \(id) is no longer active."
        }
    }
}

struct ISHNativeClientSettingsCard: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let pluginID: String
    let generation: UInt64
    let title: String
    let namespace: String
    let order: Int
}

struct ISHNativeClientConversationRenderer: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let pluginID: String
    let generation: UInt64
    let title: String
    let description: String?
    let order: Int
    let renderer: ISHNativeClientRenderer
    let value: JSONValue
}

struct ISHNativeClientSidebarAction: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let pluginID: String
    let generation: UInt64
    let title: String
    let description: String
    let order: Int
    let action: ISHNativeClientActionDescriptor
}

struct ISHNativeClientSlotSnapshot: Codable, Sendable, Equatable {
    let revision: UInt64
    let settingsCards: [ISHNativeClientSettingsCard]
    let conversationRenderers: [ISHNativeClientConversationRenderer]
    let sidebarActions: [ISHNativeClientSidebarAction]

    static let empty = ISHNativeClientSlotSnapshot(
        revision: 0,
        settingsCards: [],
        conversationRenderers: [],
        sidebarActions: []
    )
}

struct ISHNativeClientSlotToken: Sendable, Equatable {
    let contributionID: String
    let activationID: UUID
}

/// Native replacement for the web client's queried slot tree. It stores only
/// fixed Swift DTOs and never accepts executable UI, React, or downloaded code.
actor ISHNativeClientSlotRegistry {
    private struct ActiveContribution: Sendable {
        let activationID: UUID
        let kind: ISHNativeClientSlotKind
        let value: ISHNativeClientSlotValue
    }

    private enum ISHNativeClientSlotValue: Sendable {
        case settings(ISHNativeClientSettingsCard)
        case conversation(ISHNativeClientConversationRenderer)
        case sidebar(ISHNativeClientSidebarAction)
    }

    private var active: [String: ActiveContribution] = [:]
    private var revision: UInt64 = 0

    func register(
        plugin: ISHNativeClientPlugin,
        contributionID: String,
        kind: ISHNativeClientSlotKind,
        generation: UInt64? = nil
    ) throws -> ISHNativeClientSlotToken {
        let generation = generation ?? plugin.activationGeneration
        guard generation == plugin.activationGeneration,
              generation > 0,
              generation <= ishNativeClientSlotMaximumJSONSafeInteger else {
            throw invalid(plugin.pluginId, "generation does not match active plugin")
        }
        let scopedID = "\(plugin.pluginId)/\(contributionID)"
        guard active[scopedID] == nil else {
            throw ISHNativeClientSlotRegistryError.duplicateContribution(scopedID)
        }

        let value: ISHNativeClientSlotValue
        switch kind {
        case .settingsCard:
            guard let settings = plugin.contributions.settings.first(where: { $0.id == contributionID }) else {
                throw invalid(plugin.pluginId, "settings card is not declared")
            }
            value = .settings(ISHNativeClientSettingsCard(
                id: settings.id,
                pluginID: plugin.pluginId,
                generation: generation,
                title: settings.title,
                namespace: settings.namespace,
                order: settings.order
            ))
        case .conversationRenderer:
            guard let card = plugin.contributions.cards.first(where: { $0.id == contributionID }) else {
                throw invalid(plugin.pluginId, "conversation renderer is not declared")
            }
            guard card.renderer == .keyValue || card.renderer == .markdown else {
                throw invalid(plugin.pluginId, "renderer is not in the native allowlist")
            }
            value = .conversation(ISHNativeClientConversationRenderer(
                id: card.id,
                pluginID: plugin.pluginId,
                generation: generation,
                title: card.title,
                description: card.description,
                order: card.order,
                renderer: card.renderer,
                value: card.value
            ))
        case .sidebarAction:
            guard let command = plugin.contributions.commands.first(where: { $0.name == contributionID }) else {
                throw invalid(plugin.pluginId, "sidebar action is not declared")
            }
            value = .sidebar(ISHNativeClientSidebarAction(
                id: command.name,
                pluginID: plugin.pluginId,
                generation: generation,
                title: command.name,
                description: command.description,
                order: command.order,
                action: command.action
            ))
        }

        let activationID = UUID()
        active[scopedID] = ActiveContribution(
            activationID: activationID,
            kind: kind,
            value: value
        )
        revision &+= 1
        return ISHNativeClientSlotToken(
            contributionID: scopedID,
            activationID: activationID
        )
    }

    func dispose(_ token: ISHNativeClientSlotToken) {
        guard active[token.contributionID]?.activationID == token.activationID else { return }
        active.removeValue(forKey: token.contributionID)
        revision &+= 1
    }

    func snapshot() -> ISHNativeClientSlotSnapshot {
        var settings: [ISHNativeClientSettingsCard] = []
        var conversations: [ISHNativeClientConversationRenderer] = []
        var actions: [ISHNativeClientSidebarAction] = []
        for contribution in active.values {
            switch contribution.value {
            case let .settings(value): settings.append(value)
            case let .conversation(value): conversations.append(value)
            case let .sidebar(value): actions.append(value)
            }
        }
        settings.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        conversations.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        actions.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        return ISHNativeClientSlotSnapshot(
            revision: revision,
            settingsCards: settings,
            conversationRenderers: conversations,
            sidebarActions: actions
        )
    }

    private func invalid(_ pluginID: String, _ reason: String) -> ISHNativeClientSlotRegistryError {
        .invalidContribution(pluginID: pluginID, reason: reason)
    }
}
