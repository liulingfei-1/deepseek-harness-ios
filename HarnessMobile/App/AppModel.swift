import Foundation
import Observation
import UIKit
#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
#endif

struct DirectCommandOutput: Identifiable, Sendable, Equatable {
    let id = UUID()
    let title: String
    let text: String
    let isError: Bool
}

struct PendingSlashCommandInteraction: Identifiable, Sendable, Equatable {
    var id: String { commandID }

    let commandID: String
    let commandName: String
    let sessionID: UUID
    let request: SlashCommandInteractionRequest
}

struct HarnessSessionPathNode: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let depth: Int
    let status: HarnessJobStatus?
    let isCurrent: Bool
}

enum ISHPluginMarketplaceOperation: Sendable, Equatable {
    case preparingHost
    case loadingCatalog
    case preparingNativePlugin
    case installingPlugin
    case updatingPlugin
    case compilingNativePlugin
    case enablingPlugin
    case disablingPlugin
    case uninstallingPlugin
    case clearingCache
}

enum ISHPluginMarketplaceRetry: Sendable, Equatable {
    case refreshCatalog(forceRefresh: Bool)
    case install(
        source: ISHMarketplacePluginSource,
        replace: Bool,
        compilerGuidance: String?
    )
    case setEnabled(id: String, enabled: Bool)
    case uninstall(id: String)
    case clearCache(includeNpm: Bool)
}

struct ISHPluginMarketplaceFailure: Sendable, Equatable {
    let message: String
    fileprivate let retry: ISHPluginMarketplaceRetry?

    var canRetry: Bool { retry != nil }
}

struct PendingAgentPluginPreparation: Sendable, Equatable {
    let source: ISHMarketplacePluginSource
    let replace: Bool
    let preparedToken: String
    let candidate: NativeAgentPluginSourceSnapshot?
    let createdAt: Date
}

enum NativePluginCompilationStage: String, CaseIterable, Identifiable, Sendable {
    case sourceAcquisition
    case sourceAnalysis
    case adaptability
    case modelCompilation
    case validation
    case nativeInstallation
    case ishFallback

    var id: Self { self }

    var title: String {
        switch self {
        case .sourceAcquisition: "下载源码"
        case .sourceAnalysis: "分析源码"
        case .adaptability: "判断原生适配"
        case .modelCompilation: "Agent 编译"
        case .validation: "Swift 校验"
        case .nativeInstallation: "注册原生工具"
        case .ishFallback: "iSH 回退安装"
        }
    }
}

enum NativePluginCompilationStageState: String, Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

struct NativePluginCompilationStep: Identifiable, Sendable, Equatable {
    var id: NativePluginCompilationStage { stage }
    let stage: NativePluginCompilationStage
    var state: NativePluginCompilationStageState
    var detail: String
    var updatedAt: Date
}

struct NativePluginCompilationLogEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let stage: NativePluginCompilationStage
    let state: NativePluginCompilationStageState
    let message: String
}

struct NativePluginCompilationTrace: Identifiable, Sendable, Equatable {
    let id: UUID
    let source: String
    let startedAt: Date
    var finishedAt: Date?
    var outcome: String?
    var diagnostic: NativeAgentCompilationDiagnostic?
    var steps: [NativePluginCompilationStep]
    var logs: [NativePluginCompilationLogEntry]

    init(source: String, now: Date = .now) {
        id = UUID()
        self.source = source
        startedAt = now
        finishedAt = nil
        outcome = nil
        diagnostic = nil
        steps = NativePluginCompilationStage.allCases.map {
            NativePluginCompilationStep(
                stage: $0,
                state: .pending,
                detail: "等待开始",
                updatedAt: now
            )
        }
        logs = []
    }

    var isFinished: Bool { finishedAt != nil }
}

@MainActor
@Observable
final class AppModel: ObservableObject, SessionControlling, SettingsControlling, WorkspaceControlling {
    private static let maximumConcurrentRootRuns = 2

    private struct RunExecutionSnapshot: Sendable {
        let controlState: ConversationControlState
        let agentPreset: AgentPresetRuntimeProjection?
        let contextWindowTokens: Int?

        var interactionMode: ConversationInteractionMode { controlState.interactionMode }
        var permissionMode: ToolPermissionMode { controlState.permissionMode }
        var contextLimitUTF8Bytes: Int { controlState.contextLimitUTF8Bytes ?? 384 * 1_024 }
    }

    private static let creativeModeLifecycleTools: Set<String> = [
        "cordis_inspect_list",
        "cordis_inspect_query",
        "cordis_inspect_self",
        "cordis_define",
        "cordis_run",
        "cordis_stop",
        "cordis_undefine"
    ]

    var providerDirectory: ProviderProfileDirectory
    var compactionSummaryRoute: CompactionSummaryRoute?
    var timeContextSettings: TimeContextSettings
    var sessionTitleSettings: SessionTitleSettings
    var providerBundles: [AgentProviderBundle] = AgentProviderBundle.catalog
    var providerBundleInstallStatuses: [AgentProviderBundleID: AgentProviderBundleInstallStatus] =
        Dictionary(uniqueKeysWithValues: AgentProviderBundleID.allCases.map {
            ($0, .unknown($0))
        })
    var credentialStatuses: [String: ProviderCredentialStatus] = [:]
    var isReady = false
    var isConfigured = false
    /// Monotonic invalidation token for the chat projection. Comparing the
    /// full message array on every SwiftUI update is quadratic in the number
    /// of retained messages during long sessions; the property observer also
    /// covers in-place element edits such as feedback changes.
    var messages: [AgentMessage] = [] {
        didSet {
            messagesRevision &+= 1
        }
    }
    private(set) var messagesRevision = 0
    var selectedRunPresentation: SessionRunPresentation?
    var streamingText: String { selectedRunPresentation?.streamingText ?? "" }
    var streamingReasoning: String { selectedRunPresentation?.streamingReasoning ?? "" }
    var streamingPresentationRevision: UInt64 {
        selectedRunPresentation?.streamingPresentationRevision ?? 0
    }
    var isSubmitting = false
    var submissionStatus: String?
    var isRunning: Bool {
        guard let selectedRunPresentation else { return false }
        switch selectedRunPresentation.phase {
        case .idle, .maintenance, .running, .cancelling:
            return true
        case .terminal:
            return false
        }
    }
    var runStartedAt: Date? { selectedRunPresentation?.runStartedAt }
    var currentStep: Int { selectedRunPresentation?.currentStep ?? 0 }
    var activeContextInjections: [AgentContextInjection] {
        selectedRunPresentation?.activeContextInjections ?? []
    }
    var activeToolStatus: String? { selectedRunPresentation?.activeToolStatus }
    var activeToolEvents: [AgentToolEvent] { selectedRunPresentation?.activeToolEvents ?? [] }
    var pendingApproval: ToolApprovalRequest? { selectedRunPresentation?.pendingApproval }
    var trustedToolApprovals: [ToolApprovalGrant] = []
    var pendingUserQuestion: ContinuationUserQuestionProvider.Pending? {
        selectedRunPresentation?.pendingUserQuestion
    }
    var errorMessage: String?
    var latestUsage: ModelTokenUsage? { selectedRunPresentation?.latestUsage }
    var workspaceFiles: [WorkspaceStore.FileEntry] = []
    var workspaceMounts: [WorkspaceStore.MountSnapshot] = []
    var hasStagedImage = false
    private var stagedImageReference: AgentImageAttachmentRef?
    var hasStagedFile = false
    private var stagedFileReference: AgentFileAttachmentRef?
    private var stagedShareAdmission: WorkspaceShareAdmission?
    var sessions: [ConversationSessionSummary] = []
    var activeSessionID: UUID?
    /// Read-only projection of every live root. Durable session summaries do
    /// not contain transient run state for non-selected sessions.
    private(set) var sessionRunSnapshots: [UUID: SessionRunSnapshot] = [:]
    var workState = ConversationWorkState()
    var controlState = ConversationControlState()
    var omittedContextMessages = 0
    var hasResumableRun = false
    var continuedProcessingSubmission: ContinuedProcessingSubmission? {
        selectedRunPresentation?.continuedProcessingSubmission
    }
    private var scheduleBackgroundEvent = "idle"
    var lastBackgroundEvent: String {
        selectedRunPresentation?.lastBackgroundEvent ?? scheduleBackgroundEvent
    }
    var pendingDraft: String?
    private var allStagedImageReferences: [AgentImageAttachmentRef] {
        (stagedImageReference.map { [$0] } ?? [])
            + (stagedShareAdmission?.imageAttachments ?? [])
    }
    private var allStagedFileReferences: [AgentFileAttachmentRef] {
        (stagedFileReference.map { [$0] } ?? [])
            + (stagedShareAdmission?.fileAttachments ?? [])
    }
    var backgroundRuntimeStatus: BackgroundRuntimeStatus {
        selectedRunPresentation?.backgroundRuntimeStatus ?? .idle
    }
    /// Unified, privacy-safe projection consumed by home/settings/system
    /// surfaces. It is refreshed from the durable run registry and the
    /// process-level keep-alive coordinator rather than from the selected UI
    /// session.
    private(set) var backgroundSystemProjection = BackgroundSystemProjection.empty
    var directCommandOutput: DirectCommandOutput?
    var pendingSlashCommandInteraction: PendingSlashCommandInteraction?
    var isSessionModelPickerRequested = false
    var isSessionAgentPresetPickerRequested = false
    var agentPresets = AgentPresetRegistry.systemPresets
    var defaultAgentPresetID = AgentPresetRegistry.defaultID
    var pluginSnapshots: [CordisPluginSnapshot] = []
    var pluginToolContributions: [CordisToolContributionSnapshot] = []
    var pluginPromptContributions: [CordisPromptContributionSnapshot] = []
    var ishPluginHostState: ISHPluginHostRuntimeState = .stopped
    var ishPluginHostInventory: [ISHPluginHostInventoryEntry] = []
    var ishPluginHostPackages: [String: String] = [:]
    var ishPluginHostDiagnostics: ISHPluginHostClient.Diagnostics?
    var ishPluginSettingsSnapshot: ISHPluginSettingsSnapshot?
    var ishPluginMarketplaceCatalog: ISHMarketplaceCatalog?
    var ishMarketplacePlugins: [ISHMarketplacePlugin] = []
    var ishNativeClientPlugins: [ISHNativeClientPlugin] = []
    var ishNativeClientFailures: [ISHNativeClientSynchronizationFailure] = []
    var nativeAgentPlugins: [NativeAgentCompiledPlugin] = []
    var ishPluginMarketplaceOperation: ISHPluginMarketplaceOperation?
    var ishPluginMarketplaceFailure: ISHPluginMarketplaceFailure?
    var nativePluginCompilationTrace: NativePluginCompilationTrace?
    var isISHPluginMarketplaceWorking: Bool {
        ishPluginMarketplaceOperation != nil
    }
    /// The complete trajectory is persisted in the session JSONL store. Keep a
    /// small raw tail in observable state because retaining every token-sized
    /// delta here caused memory spikes and expensive SwiftUI invalidations on
    /// long conversations.
    var trajectoryEvents: [SessionEvent] = []
    var trajectoryVisibleEvents: [SessionEvent] = []
    /// Whole-log turn outline used by the trajectory rail. Unlike the bounded
    /// event window above, this projection is folded from the durable stream
    /// on session load and then advanced incrementally as new events arrive.
    var trajectoryOutline: SessionTurnOutlineState = .empty
    var trajectoryEventCount = 0
    var isLoadingOlderTrajectory = false
    var canLoadOlderTrajectory: Bool {
        guard trajectoryEventCount > 0 else { return false }
        return (trajectoryLoadedFromSequence ?? UInt64(trajectoryEventCount)) > 0
    }
    var trajectoryMetrics: SessionTrajectoryMetrics?
    var trajectoryRecoveredTornTail = false
    var harnessTraceEvents: [HarnessTraceEvent] = []
    var harnessTraceSummary: HarnessTraceSummary?
    /// Observable projection for the native Jobs panel. The registry remains
    /// the durable source of truth; this is only the current-session snapshot.
    var visibleJobs: [HarnessJobSnapshot] = []
    /// Child Agent tree rooted at the active conversation. This projection is
    /// intentionally separate from jobs because one child can have many
    /// sequential activations.
    var visibleSubagents: [HarnessSubagentSnapshot] = []
    /// Root-to-current address path for the active conversation. Unlike the
    /// flattened child tree this remains useful after navigating into a child.
    var visibleSessionPath: [HarnessSessionPathNode] = []
    var memoryRecords: [MemoryRecord] = []
    var isMemoryEnabledForActiveSession = true

    let workspaceStore: WorkspaceStore
    let memoryStore: MemoryStore
    let backgroundPreferences: BackgroundPreferencesModel
    let pluginRuntime: CordisPluginRuntime
    let agentServices: CordisAgentServices

    var configuration: AgentConfiguration {
        providerDirectory.activeProfile?.configuration() ?? AgentConfiguration()
    }

    var providerProfiles: [ProviderProfile] {
        providerDirectory.profiles
    }

    var activeProviderProfile: ProviderProfile? {
        providerDirectory.activeProfile
    }

    var effectiveConfiguration: AgentConfiguration {
        // A session may have been saved before the provider catalog learned a
        // model's actual capacity. Resolve that snapshot again at use time so
        // an old 4K/8K UI value cannot become an app-imposed API limit.
        ModelProviderCatalog.applyingKnownModelContract(
            to: controlState.modelConfiguration ?? configuration
        )
    }

    var queuedInputs: [QueuedAgentInput] {
        selectedRunPresentation?.queuedInputs ?? controlState.queuedInputs
    }

    var interactionMode: ConversationInteractionMode {
        controlState.interactionMode
    }

    var permissionMode: ToolPermissionMode {
        controlState.permissionMode
    }

    var activeAgentPreset: AgentPresetDefinition? {
        agentPresets.first { $0.id == controlState.agentPresetID }
    }

    var isAgentPresetLocked: Bool {
        controlState.isAgentPresetLocked
    }

    private func defaultConversationControlState() -> ConversationControlState {
        let preset = agentPresets.first {
            $0.id == defaultAgentPresetID && $0.isMountable
        } ?? agentPresets.first {
            $0.id == AgentPresetRegistry.defaultID && $0.isMountable
        } ?? AgentPresetRegistry.systemPresets[0]

        return ConversationControlState(
            interactionMode: .agent,
            permissionMode: preset.composition.defaultPermissionMode,
            agentPresetID: preset.id
        )
    }

    var availablePermissionModes: [ToolPermissionMode] {
        guard let maximum = activeAgentPreset?.composition.maximumPermissionMode else {
            return []
        }
        return ToolPermissionMode.allCases.filter { $0.isAllowed(by: maximum) }
    }

    var isPlanModeAvailable: Bool {
        activeAgentPreset?.composition.allowsCommand("plan") == true
    }

    var contextWindowTokens: Int? {
        contextWindow(for: effectiveConfiguration)
    }

    var contextUsageFraction: Double? {
        guard let promptTokens = latestUsage?.promptTokens,
              let contextWindowTokens,
              contextWindowTokens > 0 else { return nil }
        return min(1, Double(promptTokens) / Double(contextWindowTokens))
    }

    func refreshVisibleJobs() async {
        guard let activeSessionID else {
            visibleJobs = []
            visibleSubagents = []
            visibleSessionPath = []
            return
        }
        let activeAddress = activeSessionID.uuidString.lowercased()
        let lineage = await jobRegistry.subagentLineage(sessionID: activeAddress)
        let rootSession = lineage.first?.parentSession ?? activeAddress
        // Jobs stay scoped to the active conversation. Only the child-Agent
        // directory expands to the family root; otherwise opening a child
        // would hide that child's own shell/workflow jobs behind its parent.
        async let jobs = jobRegistry.list(ownerSession: activeAddress)
        async let subagents = jobRegistry.listSubagents(rootSession: rootSession, descendants: true)
        visibleJobs = await jobs
        visibleSubagents = await subagents
        visibleSessionPath = makeVisibleSessionPath(
            rootSession: rootSession,
            lineage: lineage,
            activeAddress: activeAddress
        )
    }

    private func makeVisibleSessionPath(
        rootSession: String,
        lineage: [HarnessSubagentSnapshot],
        activeAddress: String
    ) -> [HarnessSessionPathNode] {
        let rootUUID = UUID(uuidString: rootSession)
        let rootTitle = sessions.first(where: { $0.id == rootUUID })?.title ?? "主会话"
        var path = [
            HarnessSessionPathNode(
                id: rootSession,
                label: rootTitle,
                depth: 0,
                status: nil,
                isCurrent: rootSession == activeAddress
            )
        ]
        path += lineage.map { child in
            HarnessSessionPathNode(
                id: child.id,
                label: child.label,
                depth: child.delegationDepth,
                status: child.status,
                isCurrent: child.id == activeAddress
            )
        }
        return path
    }

    func openVisibleSessionPathNode(_ node: HarnessSessionPathNode) async {
        guard !node.isCurrent else { return }
        guard let sessionID = UUID(uuidString: node.id) else {
            presentError(HarnessJobError.unknownSubagent(node.id))
            return
        }
        await switchConversation(to: sessionID)
        await refreshVisibleJobs()
    }

    func openVisibleSubagent(_ subagent: HarnessSubagentSnapshot) async {
        guard let sessionID = UUID(uuidString: subagent.id) else {
            presentError(HarnessJobError.unknownSubagent(subagent.id))
            return
        }
        await switchConversation(to: sessionID)
    }

    func stopVisibleSubagent(_ subagent: HarnessSubagentSnapshot) async throws {
        guard activeSessionID != nil else {
            throw HarnessJobError.foreignJob(subagent.id)
        }
        let requester = visibleSessionPath.first?.id
            ?? subagent.parentSession
        _ = try await jobRegistry.interruptSubagent(
            id: subagent.id,
            requesterSession: requester,
            reason: "stopped from Jobs panel"
        )
        await refreshVisibleJobs()
    }

    func readVisibleJob(_ id: String) async throws -> HarnessJobRead {
        guard let activeSessionID else {
            throw HarnessJobError.foreignJob(id)
        }
        return try await jobRegistry.read(
            id: id,
            ownerSession: activeSessionID.uuidString.lowercased()
        )
    }

    func stopVisibleJob(_ id: String) async throws {
        guard let activeSessionID else {
            throw HarnessJobError.foreignJob(id)
        }
        _ = try await jobRegistry.kill(
            id: id,
            ownerSession: activeSessionID.uuidString.lowercased(),
            reason: "stopped from Jobs panel"
        )
        await refreshVisibleJobs()
    }

    @ObservationIgnored private let settingsStore: SettingsStore
    // Internal only so `AppModel+ProviderBundles.swift` can own the provider
    // installation coordination without reopening the full composition root.
    @ObservationIgnored let providerBundleStore: AgentProviderBundleStore
    @ObservationIgnored let providerBundleInstaller: AgentProviderBundleInstaller
    @ObservationIgnored private let agentPresetStore: AgentPresetRegistryStore
    @ObservationIgnored private let credentialStore: CredentialStore
    @ObservationIgnored private let oauthRefreshCoordinator = ProviderOAuthRefreshCoordinator()
    @ObservationIgnored private let oauthRefreshClient = ProviderOAuthRefreshClient()
    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let appIntentInboxStore: AppIntentInboxStore
    @ObservationIgnored private let sessionQueryReadModel: SessionQueryReadModel
    @ObservationIgnored private let feedbackSidecarStore: MessageFeedbackSidecarStore
    // Narrow internal seams for the focused native-plugin and marketplace
    // extensions. The implementations remain AppModel-owned UI coordination.
    @ObservationIgnored let modelClient: OpenAICompatibleClient
    @ObservationIgnored let nativeAgentPluginCompiler: NativeAgentPluginCompiler
    @ObservationIgnored let nativeAgentPluginStore: NativeAgentPluginStore
    @ObservationIgnored let pluginInstallCoordinator: PluginInstallCoordinator
    @ObservationIgnored let modelCatalogDiscoverer: any ModelCatalogDiscovering
    @ObservationIgnored let providerCapabilityCache = ProviderCapabilityCache()
    @ObservationIgnored let traceStore: HarnessTraceStore
    @ObservationIgnored let trajectoryRepository: any SessionPersistence
    @ObservationIgnored private let sessionTelemetrySink: SessionTelemetryOtelSink
    @ObservationIgnored private let slashCommandRegistry: SlashCommandRegistry
    @ObservationIgnored let skillRegistry: MobileSkillRegistry
    @ObservationIgnored private let workspaceInstructionTransitions: WorkspaceInstructionTransitionEngine
    @ObservationIgnored let jobRegistry = HarnessJobRegistry(
        persistenceURL: HarnessJobRegistry.applicationPersistenceURL()
    )
    @ObservationIgnored let scheduleStore: any HarnessScheduleManaging = HarnessScheduleStore()
    @ObservationIgnored let sessionRunRegistry = SessionRunRegistry()
    @ObservationIgnored let runtimeInvariantRegistry = RuntimeInvariantRegistry()
    @ObservationIgnored let runtimeTelemetryStore = RuntimeTelemetryStore()
    @ObservationIgnored private let runtimeHangWatchdog: RuntimeHangWatchdog
    @ObservationIgnored private let runtimeMetricKitSubscriber: RuntimeMetricKitSubscriber
    @ObservationIgnored private let localStateSnapshotStore = LocalStateSnapshotStore()
    @ObservationIgnored private let localWebhookDeduplicator = LocalWebhookDeduplicator(
        storageURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessMobile/Webhooks/github-deliveries.json")
    )
    @ObservationIgnored private let localWebhookRuleRegistry = LocalWebhookRuleRegistry(
        storageURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessMobile/Webhooks/rules.json")
    )
    @ObservationIgnored private var loadedHookConfiguration: AgentHookConfiguration?
    @ObservationIgnored private var localStateServer: LocalStateServer?
    @ObservationIgnored private let backgroundResumeCoordinator = SessionBackgroundResumeCoordinator()
    @ObservationIgnored let terminalProvider: any ISHTerminalProviding
    @ObservationIgnored let mcpRegistry: MCPClientRegistry
    @ObservationIgnored let mcpConfigurationStore: MCPConfigurationStore
    @ObservationIgnored private let ishNativeClientRegistry: ISHNativeClientContributionRegistry
    @ObservationIgnored private let ishNativeClientSlotRegistry: ISHNativeClientSlotRegistry
    @ObservationIgnored private let ishNativeClientCoordinator: ISHNativeClientCordisCoordinator
    @ObservationIgnored var ishPluginHostClient: ISHPluginHostClient?
    @ObservationIgnored private var ishPluginHostLifecycleTask: Task<Bool, Never>?
    @ObservationIgnored private var ishPluginHostRefreshTask: Task<Void, Never>?
    @ObservationIgnored var activeISHPluginMarketplaceRetry: ISHPluginMarketplaceRetry?
    @ObservationIgnored var pendingAgentPluginPreparation: PendingAgentPluginPreparation?
    @ObservationIgnored private let fallbackUserQuestionProvider: ContinuationUserQuestionProvider
    @ObservationIgnored let fallbackUserQuestionService: UserQuestionService
    @ObservationIgnored let planModeState = PlanModeStateStore()
    @ObservationIgnored let workStateCoordinator = WorkStateCoordinator()
    @ObservationIgnored private let continuedProcessingController = try! ContinuedProcessingController(
        identifierPrefix: "com.llf.harnessmobile.continued-processing"
    )
    @ObservationIgnored private let legacyBackgroundTaskLease = LegacyBackgroundTaskLease()
    @ObservationIgnored private let backgroundKeepAliveCoordinator = BackgroundKeepAliveCoordinator()
    @ObservationIgnored private let backgroundRunJournal: BackgroundRunJournal
    @ObservationIgnored private var appIsBackgrounded = false
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var finiteBackgroundLeaseTokens: [RunIdentity: SessionRunBackgroundLeaseToken] = [:]
#if os(iOS) && canImport(BackgroundTasks)
    @ObservationIgnored private let scheduleBackgroundController = ScheduleBackgroundController()
    @ObservationIgnored private var scheduleMutationObserver: NSObjectProtocol?
    @ObservationIgnored private var scheduleBackgroundTasksRegistered = false
#endif
    @ObservationIgnored private let completionNotifier = BackgroundCompletionNotifier()
    var activeRunID: UUID? { selectedRunPresentation?.identity.runID }
    @ObservationIgnored private var pendingLegacyConfiguration: AgentConfiguration?
    /// In-memory routing revisions distinguish requests made before and after
    /// an accepted profile change without persisting any secret.
    @ObservationIgnored private var providerRouteGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var trajectorySessionID: UUID?
    @ObservationIgnored private var trajectoryCursor: SessionTrajectoryCursor?
    @ObservationIgnored private var trajectoryLoadedFromSequence: UInt64?
    @ObservationIgnored private var trajectoryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var inputSkillCatalogCache: (loadedAt: Date, skills: [MobileSkillSummary])?
    @ObservationIgnored var providerBundleInstallTasks: [
        AgentProviderBundleID: Task<Void, Never>
    ] = [:]
#if DEBUG
    @ObservationIgnored private var didResetPersistentStateForUITesting = false
#endif

    init(
        settingsStore: SettingsStore = SettingsStore(),
        providerBundleStore: AgentProviderBundleStore = AgentProviderBundleStore(),
        providerBundleInstaller: AgentProviderBundleInstaller = .shared,
        agentPresetStore: AgentPresetRegistryStore = AgentPresetRegistryStore(),
        credentialStore: CredentialStore = CredentialStore(),
        sessionStore: SessionStore = SessionStore(),
        appIntentInboxStore: AppIntentInboxStore = AppIntentInboxStore(),
        sessionQueryReadModel: SessionQueryReadModel? = nil,
        feedbackSidecarStore: MessageFeedbackSidecarStore = MessageFeedbackSidecarStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        memoryStore: MemoryStore = MemoryStore(),
        modelClient: OpenAICompatibleClient = OpenAICompatibleClient(),
        sessionLogEnabled: Bool = false,
        modelCatalogDiscoverer: (any ModelCatalogDiscovering)? = nil,
        trajectoryRepository: any SessionPersistence = SessionTrajectoryRepository(),
        slashCommandRegistry: SlashCommandRegistry = SlashCommandRegistry(),
        backgroundPreferences: BackgroundPreferencesModel = BackgroundPreferencesModel(),
        backgroundRunJournal: BackgroundRunJournal = BackgroundRunJournal(),
        mcpConfigurationStore: MCPConfigurationStore = MCPConfigurationStore(),
        nativeAgentPluginStore: NativeAgentPluginStore = NativeAgentPluginStore(),
        pluginInstallCoordinator: PluginInstallCoordinator = PluginInstallCoordinator()
    ) {
        self.settingsStore = settingsStore
        self.providerBundleStore = providerBundleStore
        self.providerBundleInstaller = providerBundleInstaller
        self.agentPresetStore = agentPresetStore
        self.credentialStore = credentialStore
        self.sessionStore = sessionStore
        self.appIntentInboxStore = appIntentInboxStore
        self.sessionQueryReadModel = sessionQueryReadModel ?? SessionQueryReadModel()
        self.feedbackSidecarStore = feedbackSidecarStore
        self.workspaceStore = workspaceStore
        self.memoryStore = memoryStore
        self.mcpRegistry = MCPClientRegistry(
            workspaceURLProvider: { try await workspaceStore.rootURL() }
        )
        self.mcpConfigurationStore = mcpConfigurationStore
        self.terminalProvider = ISHTerminalSessionProvider(
            factories: [
                "ish-shell": ISHTerminalBackendFactoryBuilder.make(
                    workspaceURL: { try await workspaceStore.rootURL() }
                )
            ],
            persistenceURL: HarnessJobRegistry.applicationPersistenceURL()
                .deletingLastPathComponent()
                .appendingPathComponent("terminal-sessions.json")
        )
        self.modelClient = modelClient
        nativeAgentPluginCompiler = NativeAgentPluginCompiler(client: modelClient)
        self.nativeAgentPluginStore = nativeAgentPluginStore
        self.pluginInstallCoordinator = pluginInstallCoordinator
        self.modelCatalogDiscoverer = modelCatalogDiscoverer ?? modelClient
        let telemetryDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("HarnessMobile/Telemetry", isDirectory: true)
        let telemetrySink = SessionTelemetryOtelSink(
            configuration: .init(mode: .disabled, outputDirectory: telemetryDirectory)
        )
        self.sessionTelemetrySink = telemetrySink
        let telemetryPersistence = TelemetrySessionPersistence(
            base: trajectoryRepository,
            sink: telemetrySink
        )
        self.trajectoryRepository = telemetryPersistence
        if sessionLogEnabled {
            try? modelClient.deepSeekExtensionRegistry.register(
                field: "dsh_session_log",
                provider: SessionLogDeepSeekExtensionProvider(
                    persistence: telemetryPersistence
                ).makeProvider()
            )
        }
        self.slashCommandRegistry = slashCommandRegistry
        skillRegistry = MobileSkillRegistry(workspaceStore: workspaceStore)
        workspaceInstructionTransitions = WorkspaceInstructionTransitionEngine(
            workspaceStore: workspaceStore
        )
        self.backgroundPreferences = backgroundPreferences
        self.backgroundRunJournal = backgroundRunJournal
        let traceStore = HarnessTraceStore()
        self.traceStore = traceStore
        runtimeHangWatchdog = RuntimeHangWatchdog(telemetryStore: runtimeTelemetryStore)
        runtimeMetricKitSubscriber = RuntimeMetricKitSubscriber(telemetryStore: runtimeTelemetryStore)
        agentServices = CordisAgentServices()
        pluginRuntime = CordisPluginRuntime { draft in
            await traceStore.record(draft)
        }
        let nativeClientRegistry = ISHNativeClientContributionRegistry()
        ishNativeClientRegistry = nativeClientRegistry
        let nativeClientSlotRegistry = ISHNativeClientSlotRegistry()
        ishNativeClientSlotRegistry = nativeClientSlotRegistry
        ishNativeClientCoordinator = ISHNativeClientCordisCoordinator(
            runtime: pluginRuntime,
            registry: nativeClientRegistry,
            slotRegistry: nativeClientSlotRegistry,
            commandRegistry: slashCommandRegistry
        )
        let loadedProviderDirectory = settingsStore.loadProviderDirectory()
        providerDirectory = loadedProviderDirectory.directory
        providerRouteGenerations = Dictionary(
            uniqueKeysWithValues: loadedProviderDirectory.directory.profiles.map { ($0.id, 0) }
        )
        compactionSummaryRoute = settingsStore.loadCompactionSummaryRoute(
            in: loadedProviderDirectory.directory
        )
        timeContextSettings = settingsStore.loadTimeContextSettings()
        sessionTitleSettings = settingsStore.loadSessionTitleSettings(
            in: loadedProviderDirectory.directory
        )
        providerBundles = providerBundleStore.load()
        defaultAgentPresetID = settingsStore.loadDefaultAgentPresetID()
        trustedToolApprovals = settingsStore.loadToolApprovalGrants()
        pendingLegacyConfiguration = loadedProviderDirectory.legacyConfiguration
        let userQuestionProvider = ContinuationUserQuestionProvider()
        fallbackUserQuestionProvider = userQuestionProvider
        fallbackUserQuestionService = UserQuestionService(provider: userQuestionProvider)
        backgroundKeepAliveCoordinator.onStateChange = { [weak self] _ in
            self?.refreshBackgroundSystemProjection()
        }
        localStateServer = LocalStateServer(endpoints: [
            .init(path: "/status", handler: { [localStateSnapshotStore] in localStateSnapshotStore.status() }),
            .init(path: "/sessions", handler: { [localStateSnapshotStore] in localStateSnapshotStore.sessions() }),
            .init(path: "/api/schema", handler: { LocalStateAPISchema.json() }),
            .init(path: "/api/session", handler: { [localStateSnapshotStore] in localStateSnapshotStore.sessions() })
        ])
        localStateServer?.start()
        localStateServer?.setWebhookHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleLocalWebhook(event)
            }
        }
    }

    /// Turn an accepted local webhook delivery into durable, inspectable jobs.
    /// Delivery IDs are claimed before admission; failed admission releases
    /// the claim so the sender can retry without duplicating successful jobs.
    private func handleLocalWebhook(_ event: LocalWebhookEvent) async {
        guard await localWebhookDeduplicator.claim(event.deliveryID) else { return }
        let ownerSession = activeSessionID?.uuidString.lowercased()
        var rules = await localWebhookRuleRegistry.matching(event)
        if rules.isEmpty { rules = [.defaultJob(for: event)] }
        var admitted = false
        for rule in rules {
            var jobID: String?
            for attempt in 1...rule.maximumAttempts {
                do {
                    jobID = try await jobRegistry.start(
                        kind: "webhook",
                        label: rule.jobLabel,
                        ownerSession: ownerSession,
                        outputLimitBytes: 64 * 1_024
                    ) { emit in
                        let output = event.payload.displayText
                        await emit(output)
                        return HarnessJobOutcome(status: .completed, output: output)
                    }
                    break
                } catch {
                    if attempt < rule.maximumAttempts {
                        try? await Task.sleep(for: .milliseconds(50 * attempt))
                    }
                }
            }
            if jobID != nil {
                admitted = true
                if rule.wakeActiveSession, ownerSession != nil {
                    _ = await send(rule.renderedPrompt(for: event))
                }
            }
        }
        if admitted {
            await localWebhookDeduplicator.complete(event.deliveryID)
        } else {
            await localWebhookDeduplicator.requeue(event.deliveryID)
        }
        await refreshVisibleJobs()
    }

    func localWebhookRules() async -> [LocalWebhookRule] {
        await localWebhookRuleRegistry.list()
    }

    func saveLocalWebhookRule(_ rule: LocalWebhookRule) async throws {
        try await localWebhookRuleRegistry.upsert(rule)
    }

    func deleteLocalWebhookRule(id: String) async throws {
        try await localWebhookRuleRegistry.remove(id: id)
    }

    static let localWebhookCredentialOrigin = "https://local.harness-mobile/webhook/github"

    func saveLocalWebhookSecret(_ secret: String) async throws {
        try await saveCredential(secret, forOrigin: Self.localWebhookCredentialOrigin)
        localStateServer?.setWebhookSecret(secret)
    }

    func deleteLocalWebhookSecret() async throws {
        try await deleteCredential(forOrigin: Self.localWebhookCredentialOrigin)
        localStateServer?.setWebhookSecret(nil)
    }

    func localWebhookSecretConfigured() async -> Bool {
        (try? await readCredential(forOrigin: Self.localWebhookCredentialOrigin)) != nil
    }

    private func restoreLocalWebhookSecret() async {
        let secret = try? await readCredential(forOrigin: Self.localWebhookCredentialOrigin)
        localStateServer?.setWebhookSecret(secret)
    }

#if DEBUG
    func resetPersistentStateForUITesting() async throws {
        guard !didResetPersistentStateForUITesting else { return }

        // Keep the saved configuration until its credentials and session are
        // both gone. A failed reset must not look successful.
        try await sessionStore.reset()
        try await agentPresetStore.reset()
        try await trajectoryRepository.resetAll()
        try await credentialStore.deleteAllAPIKeys()
        try await nativeAgentPluginStore.reset()
        settingsStore.clear()
        settingsStore.clearToolApprovalGrants()
        backgroundPreferences.reset()

        providerDirectory = .initial()
        providerRouteGenerations = Dictionary(
            uniqueKeysWithValues: providerDirectory.profiles.map { ($0.id, 0) }
        )
        compactionSummaryRoute = nil
        timeContextSettings = TimeContextSettings()
        sessionTitleSettings = SessionTitleSettings()
        providerBundles = AgentProviderBundle.catalog
        providerBundleInstallStatuses = Dictionary(
            uniqueKeysWithValues: AgentProviderBundleID.allCases.map {
                ($0, .unknown($0))
            }
        )
        providerBundleStore.clear()
        trustedToolApprovals = []
        credentialStatuses = [:]
        pendingLegacyConfiguration = nil
        messages = []
        selectedRunPresentation = nil
        sessions = []
        activeSessionID = nil
        resetTrajectoryProjection()
        workState = ConversationWorkState()
        controlState = ConversationControlState()
        nativeAgentPlugins = []
        agentPresets = AgentPresetRegistry.systemPresets
        defaultAgentPresetID = AgentPresetRegistry.defaultID
        await workStateCoordinator.replace(with: workState)
        didResetPersistentStateForUITesting = true
    }
#endif

    func bootstrap() async {
        guard !isReady else { return }
        await runtimeTelemetryStore.beginBootstrap()
        await runtimeTelemetryStore.configurePerformanceSampling(
            enabled: backgroundPreferences.isPerformanceResourceSamplingEnabled
        )
        runtimeMetricKitSubscriber.start()
        runtimeHangWatchdog.setApplicationActive(appIsActive && !appIsBackgrounded)
        await auditBackgroundRunJournalOnLaunch()
        do {
            agentPresets = try await agentPresetStore.load()
            if !agentPresets.contains(where: {
                $0.id == defaultAgentPresetID && $0.isMountable
            }) {
                defaultAgentPresetID = AgentPresetRegistry.defaultID
                try settingsStore.saveDefaultAgentPresetID(defaultAgentPresetID)
            }
            var state = try await sessionStore.loadState()
            if state.activeSession == nil {
                _ = try await sessionStore.createSession(
                    title: "新会话",
                    controlState: defaultConversationControlState()
                )
                state = try await sessionStore.loadState()
            }
            applySessionState(state)
            await refreshSessionRunProjection()
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: workState)
            await refreshTrajectory()
        } catch {
            presentError(error)
        }

        // Optional plugin state must never prevent the provider directory and
        // its Keychain credential from being restored on the next launch.
        do {
            try await installCoreCordisPluginsIfNeeded()
        } catch {
            await recordStartupIssue(error, source: "core_plugins")
        }
        do {
            try await installConfiguredMCPPlugins()
        } catch {
            await recordStartupIssue(error, source: "mcp_plugins")
        }
        do {
            try await loadNativeAgentPlugins()
        } catch {
            nativeAgentPlugins = []
            await recordStartupIssue(error, source: "native_plugins")
        }
        do {
            try await migrateLegacyProviderConfigurationIfNeeded()
        } catch {
            await recordStartupIssue(error, source: "provider_migration")
        }
        await refreshProviderCredentialStatuses()
        await restoreLocalWebhookSecret()
        await refreshWorkspace()
        await loadHookConfiguration()
        // `latest-image.*` is retained for the local camera_ocr tool, but it
        // is not a pending composer attachment. Restoring it here made every
        // newly-created conversation inherit the last image from a previous
        // conversation and then send it as historical input. Composer images
        // are only admitted through `stageImage(_:)` in the active session.
        hasStagedImage = false
        stagedImageReference = nil
        hasStagedFile = false
        stagedFileReference = nil
        stagedShareAdmission = nil
        await refreshPluginInventory()
        isReady = true
        refreshLocalStateProjection()
        await runtimeTelemetryStore.markBootstrapCompleted()
        await refreshAppIntentRunningSessionProjection()
        if let activeSessionID {
            await deliverPendingJobCompletions(for: activeSessionID)
            // A system-expired run may have been journaled just before iOS
            // terminated the process. Re-arm its exact identity after session
            // state is restored so the next BGProcessing wake-up can resume it.
            await scheduleSystemExpirationResume(for: activeSessionID)
        }
#if os(iOS) && canImport(BackgroundTasks)
        if scheduleBackgroundTasksRegistered {
            await scheduleNextBackgroundTurn()
        }
#endif
    }


#if os(iOS) && canImport(BackgroundTasks)
    /// Register app-wide background handlers from the SwiftUI app lifecycle.
    /// Keeping this out of `bootstrap()` makes data restoration deterministic
    /// in unit tests and avoids touching BGTaskScheduler before launch setup.
    func registerBackgroundTasksIfNeeded() {
        guard !scheduleBackgroundTasksRegistered else { return }
        scheduleBackgroundTasksRegistered = scheduleBackgroundController.register { [weak self] task in
            await self?.handleScheduleBackgroundTask(task)
        }
        guard scheduleBackgroundTasksRegistered, scheduleMutationObserver == nil else { return }
        scheduleMutationObserver = NotificationCenter.default.addObserver(
            forName: .harnessScheduleStoreDidMutate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scheduleNextBackgroundTurn()
            }
        }
    }
#endif

    func recordStartupIssue(_ error: Error, source: String) async {
        let detail = HarnessTraceRedactor.string(
            error.localizedDescription,
            maximumUTF8Bytes: 32 * 1_024
        )
        await traceStore.record(
            HarnessTraceDraft(
                kind: .error,
                name: "startup.\(source)",
                attributes: ["source": .string(source)],
                error: detail
            )
        )
    }

    func saveConfiguration(
        _ configuration: AgentConfiguration,
        apiKey: String
    ) async throws {
        let validated = try configuration.validated()
        let descriptor = ModelProviderCatalog.descriptor(for: validated.providerID)
        let targetID: String
        if let profileID = validated.profileID {
            targetID = profileID
        } else if activeProviderProfile?.providerID == validated.providerID {
            targetID = activeProviderProfile?.id ?? validated.providerID.rawValue
        } else {
            targetID = validated.providerID.rawValue
        }
        let existing = providerDirectory.profile(id: targetID)
        let profile = ProviderProfile(
            id: targetID,
            displayName: existing?.displayName ?? descriptor.displayName,
            providerID: validated.providerID,
            wireProtocol: descriptor.wireProtocol,
            baseURL: validated.baseURL,
            credentialReference: existing?.credentialReference,
            models: mergeModels(
                existing?.models ?? descriptor.builtInModels,
                ensuring: validated.model
            ),
            defaultModel: validated.model,
            reasoningMode: validated.reasoningMode,
            maxSteps: validated.maxSteps,
            maxOutputTokens: validated.maxOutputTokens,
            isCustom: validated.providerID == .customOpenAICompatible
        )
        try await saveProviderProfile(
            profile,
            apiKey: apiKey,
            makeActive: true,
            existingProfileID: existing?.id
        )
    }

    func saveProviderProfile(
        _ profile: ProviderProfile,
        apiKey: String,
        makeActive: Bool,
        existingProfileID: String? = nil
    ) async throws {
        try await saveProviderProfile(
            profile,
            apiKey: apiKey,
            makeActive: makeActive,
            existingProfileID: existingProfileID,
            oauthCredential: nil
        )
    }

    func saveProviderProfile(
        _ profile: ProviderProfile,
        apiKey: String,
        makeActive: Bool,
        existingProfileID: String? = nil,
        oauthCredential: ProviderOAuthCredential?
    ) async throws {
        let validated = try profile.validated()
        let validatedOAuthCredential = try oauthCredential?.validated()
        if makeActive {
            _ = try validated.configuration().validated()
        }

        let existing: ProviderProfile?
        if let existingProfileID {
            guard existingProfileID == validated.id,
                  let stored = providerDirectory.profile(id: existingProfileID) else {
                throw ProviderProfileError.profileIdentityChanged
            }
            guard stored.credentialReference == validated.credentialReference else {
                throw ProviderProfileError.profileIdentityChanged
            }
            existing = stored
        } else {
            guard providerDirectory.profile(id: validated.id) == nil else {
                throw ProviderProfileError.duplicateID(validated.id)
            }
            existing = nil
        }

        let newConfiguration = validated.configuration()
        let newOrigin = try newConfiguration.credentialOrigin()
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldOrigin = try existing?.configuration().credentialOrigin()
        let oldKey: String?
        if let existing, let oldOrigin {
            oldKey = try await credentialStore.readAPIKey(
                for: existing.credentialReference,
                expectedOrigin: oldOrigin
            )
        } else {
            oldKey = nil
        }

        if oldOrigin != nil,
           oldOrigin != newOrigin,
           normalizedKey.isEmpty,
           validatedOAuthCredential == nil {
            throw CredentialStoreError.keyRequiredForOriginChange
        }
        if normalizedKey.isEmpty {
            let hasAPIKey = try await credentialStore.readAPIKey(
                for: validated.credentialReference,
                expectedOrigin: newOrigin
            ) != nil
            let hasOAuthCredential = try await credentialStore.readOAuthCredential(
                for: validated.credentialReference,
                expectedOrigin: newOrigin
            ) != nil
            guard hasAPIKey || hasOAuthCredential || validatedOAuthCredential != nil else {
                throw CredentialStoreError.emptyCredential
            }
        }

        let wroteCredential = !normalizedKey.isEmpty
        if wroteCredential {
            try await credentialStore.saveAPIKey(
                normalizedKey,
                for: validated.credentialReference,
                origin: newOrigin
            )
        }
        let wroteOAuthCredential = validatedOAuthCredential != nil
        if let validatedOAuthCredential {
            try await credentialStore.saveOAuthCredential(
                validatedOAuthCredential,
                for: validated.credentialReference,
                origin: newOrigin
            )
        }

        let previousDirectory = providerDirectory
        let previousCompactionSummaryRoute = compactionSummaryRoute
        let previousSessionTitleSettings = sessionTitleSettings
        var nextDirectory = providerDirectory
        nextDirectory.upsert(validated, makeActive: makeActive)
        let nextCompactionSummaryRoute = previousCompactionSummaryRoute.flatMap { route in
            try? route.validated(in: nextDirectory)
        }
        var nextSessionTitleSettings = previousSessionTitleSettings
        nextSessionTitleSettings.route = previousSessionTitleSettings.route.flatMap { route in
            try? route.validated(in: nextDirectory)
        }
        do {
            try settingsStore.save(nextDirectory)
            try settingsStore.saveCompactionSummaryRoute(
                nextCompactionSummaryRoute,
                in: nextDirectory
            )
            try settingsStore.saveSessionTitleSettings(
                nextSessionTitleSettings,
                in: nextDirectory
            )
        } catch {
            try? settingsStore.save(previousDirectory)
            try? settingsStore.saveCompactionSummaryRoute(
                previousCompactionSummaryRoute,
                in: previousDirectory
            )
            try? settingsStore.saveSessionTitleSettings(
                previousSessionTitleSettings,
                in: previousDirectory
            )
            if wroteCredential {
                if let oldKey, let oldOrigin {
                    try? await credentialStore.saveAPIKey(
                        oldKey,
                        for: validated.credentialReference,
                        origin: oldOrigin
                    )
                } else {
                    try? await credentialStore.deleteAPIKey(for: validated.credentialReference)
                }
            }
            if wroteOAuthCredential {
                if let existing, let oldOrigin,
                   let oldOAuth = try? await credentialStore.readOAuthCredential(
                    for: existing.credentialReference,
                    expectedOrigin: oldOrigin
                   ) {
                    try? await credentialStore.saveOAuthCredential(
                        oldOAuth,
                        for: existing.credentialReference,
                        origin: oldOrigin
                    )
                } else {
                    try? await credentialStore.deleteOAuthCredential(
                        for: validated.credentialReference
                    )
                }
            }
            throw error
        }

        providerDirectory = nextDirectory
        advanceProviderRouteGeneration(for: validated.id)
        compactionSummaryRoute = nextCompactionSummaryRoute
        sessionTitleSettings = nextSessionTitleSettings
        pendingLegacyConfiguration = nil
        await refreshProviderCredentialStatuses()
    }

    func activateProviderProfile(id: String) async throws {
        guard let profile = providerDirectory.profile(id: id) else {
            throw ProviderProfileError.missingProfile(id)
        }
        let configuration = try profile.configuration().validated()
        guard try await apiKey(for: configuration) != nil else {
            throw CredentialStoreError.emptyCredential
        }
        var nextDirectory = providerDirectory
        nextDirectory.activeProfileID = id
        try settingsStore.save(nextDirectory)
        providerDirectory = nextDirectory
        await refreshProviderCredentialStatuses()
    }

    func setCompactionSummaryRoute(_ route: CompactionSummaryRoute?) throws {
        guard !isRunning else {
            throw CompactionSummaryRouteError.profileBusy
        }
        let validated = try route?.validated(in: providerDirectory)
        try settingsStore.saveCompactionSummaryRoute(validated, in: providerDirectory)
        compactionSummaryRoute = validated
    }

    func setTimeContextSettings(_ settings: TimeContextSettings) throws {
        guard !isRunning else {
            throw CompactionSummaryRouteError.profileBusy
        }
        let validated = try settings.validated()
        try settingsStore.saveTimeContextSettings(validated)
        timeContextSettings = validated
    }

    func setSessionTitleSettings(_ settings: SessionTitleSettings) throws {
        guard !isRunning else {
            throw CompactionSummaryRouteError.profileBusy
        }
        let validated = try settings.validated(in: providerDirectory)
        try settingsStore.saveSessionTitleSettings(validated, in: providerDirectory)
        sessionTitleSettings = validated
    }

    func removeProviderProfile(id: String) async throws {
        guard !isRunning else {
            throw ProviderProfileError.profileBusy
        }
        guard let profile = providerDirectory.profile(id: id) else { return }

        let previousDirectory = providerDirectory
        let previousCompactionSummaryRoute = compactionSummaryRoute
        let previousSessionTitleSettings = sessionTitleSettings
        var nextDirectory = providerDirectory
        _ = nextDirectory.remove(id: id)
        if providerDirectory.activeProfileID == id {
            nextDirectory.activeProfileID = nextDirectory.profiles.first(where: { candidate in
                credentialStatuses[candidate.id] == .configured
                    && candidate.descriptor.supportsCurrentInferenceWire
            })?.id ?? nextDirectory.profiles.first?.id
        }

        // Persist the routing change before deleting its secret. A crash or
        // save failure may leave an orphaned Keychain item, but cannot leave a
        // visible profile whose credential was already destroyed.
        let nextCompactionSummaryRoute = previousCompactionSummaryRoute?.profileID == id
            ? nil
            : previousCompactionSummaryRoute
        var nextSessionTitleSettings = previousSessionTitleSettings
        if previousSessionTitleSettings.route?.profileID == id {
            nextSessionTitleSettings.route = nil
        }
        try settingsStore.save(nextDirectory)
        do {
            try settingsStore.saveCompactionSummaryRoute(
                nextCompactionSummaryRoute,
                in: nextDirectory
            )
            try settingsStore.saveSessionTitleSettings(
                nextSessionTitleSettings,
                in: nextDirectory
            )
        } catch {
            try? settingsStore.save(previousDirectory)
            try? settingsStore.saveCompactionSummaryRoute(
                previousCompactionSummaryRoute,
                in: previousDirectory
            )
            try? settingsStore.saveSessionTitleSettings(
                previousSessionTitleSettings,
                in: previousDirectory
            )
            throw error
        }
        do {
            try await credentialStore.deleteAPIKey(for: profile.credentialReference)
            try await credentialStore.deleteOAuthCredential(for: profile.credentialReference)
        } catch {
            do {
                try settingsStore.save(previousDirectory)
                try settingsStore.saveCompactionSummaryRoute(
                    previousCompactionSummaryRoute,
                    in: previousDirectory
                )
                try settingsStore.saveSessionTitleSettings(
                    previousSessionTitleSettings,
                    in: previousDirectory
                )
            } catch {
                throw ProviderProfileError.profileRemovalRollbackFailed
            }
            throw error
        }
        providerDirectory = nextDirectory
        advanceProviderRouteGeneration(for: id)
        await providerCapabilityCache.remove(profileID: id)
        compactionSummaryRoute = nextCompactionSummaryRoute
        sessionTitleSettings = nextSessionTitleSettings
        credentialStatuses[id] = nil
        await refreshProviderCredentialStatuses()
    }

    func refreshProviderCredentialStatuses() async {
        var statuses: [String: ProviderCredentialStatus] = [:]
        for profile in providerDirectory.profiles {
            do {
                let origin = try profile.configuration().credentialOrigin()
                let apiKeyStatus = try await credentialStore.describeAPIKey(
                    for: profile.credentialReference,
                    expectedOrigin: origin
                )
                if apiKeyStatus == .missing {
                    statuses[profile.id] = try await credentialStore.readOAuthCredential(
                        for: profile.credentialReference,
                        expectedOrigin: origin
                    ) == nil ? .missing : .configured
                } else {
                    statuses[profile.id] = apiKeyStatus
                }
            } catch CredentialStoreError.credentialOriginMismatch {
                statuses[profile.id] = .originMismatch
            } catch {
                statuses[profile.id] = .missing
            }
        }
        credentialStatuses = statuses
        if let activeProfile = providerDirectory.activeProfile {
            isConfigured = statuses[activeProfile.id] == .configured
                && activeProfile.descriptor.supportsCurrentInferenceWire
        } else {
            isConfigured = false
        }
    }

    func credentialStatus(for profile: ProviderProfile) -> ProviderCredentialStatus {
        credentialStatuses[profile.id] ?? .unknown
    }

    func inputTriggerSuggestions(
        for draft: String,
        draftRevision: Int
    ) async -> InputTriggerSuggestionSnapshot? {
        if let parsed = SlashCommandParser.parse(draft),
           let descriptor = await slashCommandRegistry.descriptor(
               named: parsed.name,
               scope: activeSessionID?.uuidString
           ),
           let completion = SlashCommandCompletionDetector.detect(
               draft,
               descriptor: descriptor,
               draftRevision: draftRevision
           ) {
            let candidates = SlashCommandCompletionDetector.filter(
                await slashCompletionCandidates(for: completion.kind),
                query: completion.hit.query
            )
            let suggestions = candidates.prefix(30).map { candidate in
                InputTriggerSuggestion(
                    source: candidate.source.rawValue,
                    trigger: .slash,
                    name: candidate.value,
                    description: candidate.detail,
                    systemImage: Self.completionSystemImage(candidate.source),
                    replacementText: candidate.value + " ",
                    kind: .completion(candidate)
                )
            }
            return InputTriggerSuggestionSnapshot(
                draft: draft,
                hit: completion.hit,
                groups: suggestions.isEmpty ? [] : [
                    InputTriggerSuggestionGroup(
                        source: completion.kind.rawValue,
                        order: 0,
                        suggestions: Array(suggestions)
                    )
                ]
            )
        }
        guard let hit = InputTriggerDetector.detect(
            draft,
            draftRevision: draftRevision
        ) else { return nil }

        switch hit.trigger {
        case .at:
            // RC.8 treats `@` as a single reference palette. Keep the child
            // address source, but add local files and durable conversation
            // references so selecting an item is useful even before a model
            // turn starts. References are resolved by the injection provider,
            // not by the UI, and therefore survive retries and session forks.
            guard let sessionID = activeSessionID else {
                return InputTriggerSuggestionSnapshot(draft: draft, hit: hit, groups: [])
            }
            var rawReferences = workspaceFiles.map { file in
                HarnessReferenceCandidate(
                    source: .file,
                    identity: file.path,
                    label: file.path,
                    detail: "\(file.size) bytes",
                    searchableText: file.path,
                    sessionID: nil
                )
            }
            if !hit.quoted {
                rawReferences += sessions.map { session in
                    HarnessReferenceCandidate(
                        source: .session,
                        identity: session.id.uuidString.lowercased(),
                        label: session.title.isEmpty
                            ? session.id.uuidString.lowercased()
                            : session.title,
                        detail: session.id.uuidString.lowercased(),
                        searchableText: "\(session.title) \(session.id.uuidString)",
                        sessionID: session.id
                    )
                }
                let children = await jobRegistry.listSubagents(
                    rootSession: sessionID.uuidString.lowercased(),
                    descendants: true
                )
                rawReferences += children.map { child in
                    HarnessReferenceCandidate(
                        source: .subagent,
                        identity: child.id,
                        label: child.id,
                        detail: "\(child.label) · \(child.status.rawValue)",
                        searchableText: "\(child.id) \(child.label) \(child.status.rawValue)",
                        sessionID: nil
                    )
                }
                let skills = await cachedInputSkillCatalog()
                rawReferences += skills.filter { $0.invocation.userInvocable }.map { skill in
                    HarnessReferenceCandidate(
                        source: .skill,
                        identity: skill.name,
                        label: skill.name,
                        detail: skill.description,
                        searchableText: "\(skill.name) \(skill.description)",
                        sessionID: nil
                    )
                }
                rawReferences += (ishMarketplacePlugins.map { ($0.id, $0.name, $0.description) }
                    + nativeAgentPlugins.map { ($0.id, $0.name, $0.description) }).map { plugin in
                    HarnessReferenceCandidate(
                        source: .plugin,
                        identity: plugin.0,
                        label: plugin.0,
                        detail: plugin.2 ?? plugin.1,
                        searchableText: "\(plugin.0) \(plugin.1) \(plugin.2 ?? "")",
                        sessionID: nil
                    )
                }
            }
            guard !Task.isCancelled else { return nil }
            let matched = HarnessReferenceDirectory.search(
                rawReferences,
                query: hit.query,
                currentSessionID: sessionID
            )
            let groups: [InputTriggerSuggestionGroup] = HarnessReferenceDirectory.grouped(matched).compactMap { group -> InputTriggerSuggestionGroup? in
                let suggestions = group.candidates.prefix(20).compactMap { candidate -> InputTriggerSuggestion? in
                    switch candidate.source {
                    case .file:
                        guard let mention = HarnessReferenceSyntax.formatFileMention(
                            path: candidate.identity,
                            preserveQuote: hit.quoted
                        ) else { return nil }
                        return InputTriggerSuggestion(
                            source: "file", trigger: .at, name: candidate.label,
                            description: candidate.detail, systemImage: "doc.text",
                            replacementText: mention + " ", kind: .file(path: candidate.identity)
                        )
                    case .session:
                        guard let referenceID = candidate.sessionID else { return nil }
                        return InputTriggerSuggestion(
                            source: "history", trigger: .at, name: candidate.label,
                            description: candidate.detail, systemImage: "clock.arrow.circlepath",
                            replacementText: HarnessReferenceSyntax.formatSessionMention(
                                sessionID: referenceID,
                                label: candidate.label
                            ) + " ",
                            kind: .history(sessionID: referenceID)
                        )
                    case .subagent:
                        return InputTriggerSuggestion(
                            source: "subagent", trigger: .at, name: candidate.label,
                            description: candidate.detail,
                            systemImage: "person.crop.circle.badge.checkmark",
                            replacementText: "@\(candidate.identity) ",
                            kind: .subagent(address: candidate.identity)
                        )
                    case .skill:
                        return InputTriggerSuggestion(
                            source: "skill", trigger: .at, name: candidate.label,
                            description: candidate.detail, systemImage: "wand.and.stars",
                            replacementText: "/\(candidate.identity) ",
                            kind: .skill(name: candidate.identity)
                        )
                    case .plugin:
                        return InputTriggerSuggestion(
                            source: "plugin", trigger: .at, name: candidate.label,
                            description: candidate.detail, systemImage: "puzzlepiece.extension",
                            replacementText: "@\(candidate.identity) ",
                            kind: .plugin(id: candidate.identity)
                        )
                    }
                }
                guard !suggestions.isEmpty else { return nil }
                let source = group.source == .session ? "history" : group.source.rawValue
                return InputTriggerSuggestionGroup(
                    source: source,
                    order: group.source.order,
                    suggestions: Array(suggestions)
                )
            }
            return InputTriggerSuggestionSnapshot(
                draft: draft,
                hit: hit,
                groups: groups
            )
        case .slash:
            let commands = await slashCommandRegistry.search(
                hit.query,
                scope: activeSessionID?.uuidString
            )
            guard !Task.isCancelled else { return nil }
            let commandNames = Set(commands.map(\.name))
            let commandSuggestions = commands.map { command in
                InputTriggerSuggestion(
                    source: "command",
                    trigger: .slash,
                    name: command.name,
                    description: command.description,
                    systemImage: Self.commandSystemImage(command.name),
                    replacementText: "/\(command.name)\(command.input == nil ? "" : " ")",
                    kind: .command(command)
                )
            }

            let skills = await cachedInputSkillCatalog()
            guard !Task.isCancelled else { return nil }
            let skillSuggestions = skills
                .filter { skill in
                    skill.invocation.userInvocable
                        && !commandNames.contains(skill.name)
                        && (hit.query.isEmpty || skill.name.hasPrefix(hit.query.lowercased()))
                }
                .map { skill in
                    InputTriggerSuggestion(
                        source: "skill",
                        trigger: .slash,
                        name: skill.name,
                        description: skill.invocation.modelInvocable
                            ? skill.description
                            : "仅用户调用 · \(skill.description)",
                        systemImage: "wand.and.stars",
                        replacementText: "/\(skill.name) ",
                        kind: .skill(name: skill.name)
                    )
                }
                .sorted { $0.name < $1.name }

            let groups = [
                InputTriggerSuggestionGroup(
                    source: "command",
                    order: 0,
                    suggestions: Array(commandSuggestions.prefix(20))
                ),
                InputTriggerSuggestionGroup(
                    source: "skill",
                    order: 2,
                    suggestions: Array(skillSuggestions.prefix(20))
                )
            ]
                .filter { !$0.suggestions.isEmpty }
                .sorted { $0.order < $1.order }
            return InputTriggerSuggestionSnapshot(draft: draft, hit: hit, groups: groups)
        }
    }

    func slashCommandSuggestions(for draft: String) async -> [SlashCommandDescriptor] {
        guard let snapshot = await inputTriggerSuggestions(
            for: draft,
            draftRevision: 0
        ) else { return [] }
        return snapshot.groups.flatMap(\.suggestions).compactMap { suggestion in
            guard case let .command(command) = suggestion.kind else { return nil }
            return command
        }
    }

    private static func commandSystemImage(_ name: String) -> String {
        switch name {
        case "new": "plus.square"
        case "clear": "trash"
        case "plan": "list.bullet.clipboard"
        case "model": "cpu"
        case "compact": "arrow.down.right.and.arrow.up.left"
        case "status": "gauge"
        case "agent": "person.crop.circle.badge.checkmark"
        default: "terminal"
        }
    }

    private static func completionSystemImage(
        _ kind: SlashCommandCompletionKind
    ) -> String {
        switch kind {
        case .model: "cpu"
        case .agent: "person.crop.circle.badge.checkmark"
        case .skill: "wand.and.stars"
        case .file: "doc.text"
        case .session: "clock.arrow.circlepath"
        case .plugin: "puzzlepiece.extension"
        }
    }

    private func slashCompletionCandidates(
        for kind: SlashCommandCompletionKind
    ) async -> [SlashCommandCompletionCandidate] {
        switch kind {
        case .model:
            return providerDirectory.profiles.flatMap { profile in
                profile.models.map { model in
                    SlashCommandCompletionCandidate(
                        source: .model,
                        value: "\(profile.id)/\(model.id)",
                        detail: model.name ?? profile.displayName
                    )
                }
            }
        case .agent:
            return agentPresets.filter(\.isMountable).map { preset in
                SlashCommandCompletionCandidate(
                    source: .agent,
                    value: preset.id,
                    detail: preset.displayName
                )
            }
        case .skill:
            return await cachedInputSkillCatalog().filter {
                $0.invocation.userInvocable
            }.map { skill in
                SlashCommandCompletionCandidate(
                    source: .skill,
                    value: skill.name,
                    detail: skill.description
                )
            }
        case .file:
            return workspaceFiles.map { file in
                SlashCommandCompletionCandidate(
                    source: .file,
                    value: HarnessReferenceSyntax.formatFileMention(path: file.path) ?? "@\(file.path)",
                    detail: "\(file.size) bytes"
                )
            }
        case .session:
            return sessions.compactMap { session in
                guard session.id != activeSessionID else { return nil }
                return SlashCommandCompletionCandidate(
                    source: .session,
                    value: HarnessReferenceSyntax.formatSessionMention(
                        sessionID: session.id,
                        label: session.title.isEmpty
                            ? session.id.uuidString.lowercased()
                            : session.title
                    ),
                    detail: session.id.uuidString.lowercased()
                )
            }
        case .plugin:
            let host = ishMarketplacePlugins.map { plugin in
                SlashCommandCompletionCandidate(
                    source: .plugin,
                    value: plugin.id,
                    detail: plugin.description ?? plugin.name
                )
            }
            let native = nativeAgentPlugins.map { plugin in
                SlashCommandCompletionCandidate(
                    source: .plugin,
                    value: plugin.id,
                    detail: plugin.description ?? plugin.name
                )
            }
            return host + native
        }
    }

    private func cachedInputSkillCatalog() async -> [MobileSkillSummary] {
        if let cache = inputSkillCatalogCache,
           Date().timeIntervalSince(cache.loadedAt) < 2 {
            return cache.skills
        }
        let skills = (try? await skillRegistry.catalog()) ?? []
        inputSkillCatalogCache = (Date(), skills)
        return skills
    }

    func submit(
        _ text: String,
        disposition: QueuedInputDisposition = .queued
    ) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        submissionStatus = "正在解析命令与技能"
        defer {
            isSubmitting = false
            submissionStatus = nil
        }
        if let addressed = AddressedSubagentInputParser.parse(text) {
            submissionStatus = "正在发送给子 Agent"
            return await sendAddressedInput(addressed)
        }
        let preparation = await slashCommandRegistry.prepare(
            text,
            scope: activeSessionID?.uuidString
        )
        switch preparation {
        case .notACommand:
            submissionStatus = isRunning ? "正在加入运行队列" : "正在启动 Agent"
            return await send(text, disposition: disposition)
        case let .invalidSyntax(error):
            presentCommandOutput(
                title: "命令格式错误",
                text: error.message,
                isError: true
            )
            return false
        case let .unknownCommand(command):
            if await skillRegistry.userInvocableDefinition(named: command.name) != nil {
                // `/skill-name` is a user-owned gesture, not a direct command.
                // It remains visible in the conversation while AgentRuntime
                // adds the matching local instruction block at this turn.
                submissionStatus = isRunning ? "正在加入运行队列" : "正在启动 Agent"
                return await send(text, disposition: disposition)
            }
            let suggestions = await slashCommandRegistry.search(
                command.name,
                scope: activeSessionID?.uuidString
            )
            let hint = suggestions.prefix(3).map { "/\($0.name)" }.joined(separator: "、")
            presentCommandOutput(
                title: "未知命令 /\(command.name)",
                text: hint.isEmpty ? "输入 /help 查看本机命令。" : "可能想用：\(hint)",
                isError: true
            )
            return false
        case let .prepared(prepared):
            guard let commandSessionID = activeSessionID else {
                presentCommandOutput(
                    title: "/\(prepared.invocation.descriptor.name)",
                    text: "当前没有可记录命令的会话。",
                    isError: true
                )
                return false
            }
            do {
                try await appendCommandRun(
                    prepared.invocation,
                    sessionID: commandSessionID,
                    imageAttachments: allStagedImageReferences
                )
            } catch {
                presentCommandOutput(
                    title: "/\(prepared.invocation.descriptor.name)",
                    text: "命令未执行：无法写入 command/run。\n\(error.localizedDescription)",
                    isError: true
                )
                return false
            }

            let execution = await slashCommandRegistry.execute(
                prepared,
                imageAttachments: allStagedImageReferences
            )
            return await finishSlashCommandExecution(
                execution,
                sessionID: commandSessionID
            )
        }
    }

    func resolveSlashCommandInteraction(
        _ response: SlashCommandInteractionResponse
    ) {
        guard let pending = pendingSlashCommandInteraction else { return }
        pendingSlashCommandInteraction = nil
        Task { @MainActor in
            guard let execution = await slashCommandRegistry.resumeInteraction(
                commandID: pending.commandID,
                response: response
            ) else {
                presentCommandOutput(
                    title: "/\(pending.commandName)",
                    text: "命令交互已失效，请重新运行命令。",
                    isError: true
                )
                return
            }
            _ = await finishSlashCommandExecution(
                execution,
                sessionID: pending.sessionID
            )
        }
    }

    private func finishSlashCommandExecution(
        _ execution: SlashCommandExecution,
        sessionID: UUID
    ) async -> Bool {
        if let request = execution.result.interaction {
            pendingSlashCommandInteraction = PendingSlashCommandInteraction(
                commandID: execution.commandID,
                commandName: execution.descriptor.name,
                sessionID: sessionID,
                request: request
            )
            return true
        }
        guard execution.result.isSuccess else {
            try? await appendCommandDone(
                execution,
                text: execution.result.text,
                kind: .error,
                sessionID: sessionID
            )
            presentCommandOutput(
                title: "/\(execution.descriptor.name)",
                text: execution.result.text ?? "命令执行失败。",
                isError: true
            )
            return true
        }
        do {
            let actionText = try await applySlashCommandAction(execution.result.action)
            let text = [execution.result.text, actionText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            do {
                try await appendCommandDone(
                    execution,
                    text: text.isEmpty ? nil : text,
                    kind: .success,
                    sessionID: sessionID
                )
            } catch {
                presentCommandOutput(
                    title: "/\(execution.descriptor.name)",
                    text: "命令已经执行，但 command/done 写入失败。\n\(error.localizedDescription)",
                    isError: true
                )
                return true
            }
            // A successful command has consumed the staged attachment. Keep
            // failed commands and pending interactions retryable in the
            // composer instead of silently dropping the user's image.
            if hasStagedImage,
               execution.descriptor.imagePolicy == .accepted {
                stagedImageReference = nil
                hasStagedImage = false
                stagedShareAdmission = stagedShareAdmission.map {
                    WorkspaceShareAdmission(
                        handoffID: $0.handoffID,
                        inlineText: $0.inlineText,
                        imageAttachments: [],
                        fileAttachments: $0.fileAttachments
                    )
                }
            }
            if !text.isEmpty {
                presentCommandOutput(
                    title: "/\(execution.descriptor.name)",
                    text: text,
                    isError: false
                )
            }
        } catch {
            try? await appendCommandDone(
                execution,
                text: error.localizedDescription,
                kind: .error,
                sessionID: sessionID
            )
            presentCommandOutput(
                title: "/\(execution.descriptor.name)",
                text: error.localizedDescription,
                isError: true
            )
        }
        return true
    }

    private func sendAddressedInput(_ input: AddressedSubagentInput) async -> Bool {
        guard let parentSessionID = activeSessionID?.uuidString.lowercased() else {
            presentCommandOutput(
                title: "子 Agent",
                text: "当前没有可用于子 Agent 路由的会话。",
                isError: true
            )
            return false
        }
        do {
            let questionService: UserQuestionService
            if let identity = selectedRunPresentation?.identity,
               let scoped = try? await sessionRunRegistry.questionService(for: identity) {
                questionService = scoped
            } else {
                questionService = fallbackUserQuestionService
            }
            let child = try await jobRegistry.subagent(
                id: input.address,
                requesterSession: parentSessionID
            )
            let request = LocalSubagentRequest.continuation(
                child: child,
                prompt: input.message
            )
            let jobID = try await jobRegistry.startSubagentActivation(id: child.id) { [weak self] emit in
                guard let self else {
                    return HarnessJobOutcome(
                        status: .failed,
                        detail: "mobile Agent owner exited"
                    )
                }
                do {
                    let result = try await self.executeLocalSubagent(
                        request,
                        parentSessionID: parentSessionID,
                        userQuestionService: questionService
                    ) { chunk in
                        await emit(chunk.text)
                    }
                    return HarnessJobOutcome(
                        status: .completed,
                        detail: "child settled",
                        output: result
                    )
                } catch is CancellationError {
                    return HarnessJobOutcome(status: .killed, detail: "child interrupted")
                } catch {
                    return HarnessJobOutcome(
                        status: .failed,
                        detail: error.localizedDescription
                    )
                }
            }
            presentCommandOutput(
                title: child.label,
                text: "已发送给子 Agent。Job：\(jobID)",
                isError: false
            )
            return true
        } catch {
            presentCommandOutput(
                title: "子 Agent",
                text: error.localizedDescription,
                isError: true
            )
            return false
        }
    }

    func removeConfiguration() async {
        cancelRun()
        do {
            try await credentialStore.deleteAllAPIKeys()
            settingsStore.clear()
            providerDirectory = .initial()
            await providerCapabilityCache.removeAll()
            credentialStatuses = [:]
            pendingLegacyConfiguration = nil
            isConfigured = false
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func send(
        _ text: String,
        disposition: QueuedInputDisposition = .queued
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasStagedImage || hasStagedFile else { return false }
        if isRunning {
            if hasStagedImage || hasStagedFile {
                presentError(
                    NSError(
                        domain: "HarnessMobile",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "当前任务仍在运行，请等待完成后再发送附件。"]
                    )
                )
                return false
            }
            guard let identity = selectedRunPresentation?.identity else { return false }
            do {
                let queued = try await sessionRunRegistry.enqueue(
                    text: trimmed,
                    disposition: disposition,
                    for: identity
                )
                publishInboxInserted(
                    queued,
                    source: "user",
                    boundary: disposition == .steer ? .nextStep : .turnStopping,
                    identity: identity
                )
                await persistSelectedRunInbox(identity: identity)
                await persistSession()
            } catch {
                presentError(error)
                return false
            }
            return true
        }

        let message = AgentMessage.user(
            trimmed,
            imageAttachments: allStagedImageReferences,
            fileAttachments: allStagedFileReferences
        )
        // The immutable attachment remains on disk for history/retry; only
        // clear the composer slot so a later message cannot reuse it.
        stagedImageReference = nil
        hasStagedImage = false
        stagedFileReference = nil
        hasStagedFile = false
        stagedShareAdmission = nil
        let shouldRename = messages.isEmpty
        messages.append(message)
        let history = messages
        let runWorkState = workState
        await startRun(
            history: history,
            workState: runWorkState,
            automaticTitle: shouldRename ? String((trimmed.isEmpty ? "附件" : trimmed).prefix(40)) : nil,
            shouldCheckpointBeforeRun: true,
            initialUserMessage: message
        )
        return true
    }

    func retryFromUserMessage(id: UUID) {
        rerunFromUserMessage(id: id, replacementText: nil)
    }

    func editAndRerunUserMessage(id: UUID, text: String) {
        rerunFromUserMessage(id: id, replacementText: text)
    }

    private func rerunFromUserMessage(id: UUID, replacementText: String?) {
        guard !isRunning, !isSubmitting else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preparation = try ConversationRerunPlanner.prepare(
                    messages: self.messages,
                    messageID: id,
                    replacementText: replacementText
                )
                self.messages = preparation.messages
                self.controlState.removeAllQueuedInputs()
                self.hasResumableRun = false
                await self.startRun(
                    history: preparation.messages,
                    workState: self.workState,
                    shouldCheckpointBeforeRun: true,
                    initialUserMessage: preparation.initialUserMessage
                )
            } catch {
                self.presentError(error)
            }
        }
    }

    func updateQueuedInput(id: UUID, text: String) {
        guard let identity = selectedRunPresentation?.identity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sessionRunRegistry.updateQueuedInput(
                    id: id,
                    text: text,
                    for: identity
                )
                await self.persistSelectedRunInbox(identity: identity)
                await self.persistSession()
            } catch {
                self.presentError(error)
            }
        }
    }

    func removeQueuedInput(id: UUID) {
        guard let identity = selectedRunPresentation?.identity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard (try? await self.sessionRunRegistry.removeQueuedInput(
                id: id,
                for: identity
            )) == true else { return }
            await self.persistSelectedRunInbox(identity: identity)
            await self.persistSession()
        }
    }

    func steerQueuedInput(id: UUID) {
        guard let identity = selectedRunPresentation?.identity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sessionRunRegistry.steerQueuedInput(
                    id: id,
                    for: identity
                )
                await self.persistSelectedRunInbox(identity: identity)
                await self.persistSession()
            } catch {
                self.presentError(error)
            }
        }
    }

    func steerAllQueuedInputs() {
        guard let identity = selectedRunPresentation?.identity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard (try? await self.sessionRunRegistry.steerAllQueuedInputs(
                for: identity
            )) == true else { return }
            await self.persistSelectedRunInbox(identity: identity)
            await self.persistSession()
        }
    }

    func setInteractionMode(_ mode: ConversationInteractionMode) {
        guard controlState.interactionMode != mode else { return }
        controlState.interactionMode = mode
        Task {
            await planModeState.setActive(mode == .plan)
            await persistSession()
        }
    }

    /// Selects the mounted Agent preset for the next run. Presets may be
    /// changed while a conversation is idle; the next request records the new
    /// tool and prompt projection in the trajectory.
    @discardableResult
    func selectAgentPreset(id: String) async throws -> AgentPresetDefinition {
        guard !isRunning else { throw AgentPresetError.presetLocked }
        guard let preset = agentPresets.first(where: { $0.id == id }) else {
            throw AgentPresetError.unknownPreset(
                id,
                available: agentPresets.map(\.id)
            )
        }
        guard preset.isMountable else {
            throw AgentPresetError.brokenPreset(
                preset.id,
                reason: preset.broken ?? "未知挂载错误"
            )
        }
        if preset.id == "cordis" {
            try await prepareCreativeMode()
        }
        try controlState.selectAgentPreset(
            id: preset.id,
            defaultPermissionMode: preset.composition.defaultPermissionMode
        )
        await planModeState.setActive(false)
        await persistSession()
        return preset
    }

    private func prepareCreativeMode() async throws {
        guard await startISHPluginHost(reportErrorsGlobally: false) else {
            throw AgentPresetError.brokenPreset(
                "cordis",
                reason: ishPluginMarketplaceFailure?.message
                    ?? "iSH Plugin Host 启动失败；请在诊断日志中查看 Host stderr。"
            )
        }
        let availableTools = Set(pluginToolContributions.map { $0.definition.name })
        guard Self.creativeModeLifecycleTools.isSubset(of: availableTools) else {
            let missing = Self.creativeModeLifecycleTools.subtracting(availableTools).sorted()
            throw AgentPresetError.brokenPreset(
                "cordis",
                reason: "Cordis Host 已运行，但生命周期工具未挂载：\(missing.joined(separator: ", "))。"
            )
        }
    }

    func selectAgentPresetFromUI(id: String) {
        Task { @MainActor in
            do {
                _ = try await selectAgentPreset(id: id)
            } catch {
                presentError(error)
            }
        }
    }

    /// Upstream `dsh-goal-round-driver`: when the agent goes idle and an
    /// active, continuation-enabled goal still has round budget, start the next
    /// goal round instead of waiting for another user message. Continuation is
    /// opt-in (`isContinuationEnabled`) and capped, so this can never loop
    /// without bound.
    func driveNextGoalRound(sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        let started = await workStateCoordinator.startGoalRound()
        guard started else { return }
        guard let goal = await workStateCoordinator.snapshot().goal else { return }
        await send(
            WorkStateToolSupport.goalRoundPrompt(
                objective: goal.title,
                round: goal.usedRounds,
                maximum: goal.effectiveMaximumRounds
            )
        )
    }

    func setPermissionMode(_ mode: ToolPermissionMode) {
        guard !isRunning, controlState.permissionMode != mode else { return }
        controlState.permissionMode = mode
        recordPermissionPreset(mode)
        Task {
            await persistSession()
        }
    }

    /// Records the durable `permission/preset` event the upstream
    /// `permission-presets` package appends whenever the user picks a named
    /// permission preset or the derived `custom` state becomes current. Mobile
    /// uses the same event name with `mode.rawValue` as the table key, so a
    /// log written by either side stays readable.
    private func recordPermissionPreset(_ mode: ToolPermissionMode) {
        guard let sessionID = activeSessionID else { return }
        let session = trajectoryRepository
        let draft = SessionEventDraft(
            type: SessionEventVocabulary.permissionPreset,
            data: .object([
                "preset": .string(mode.rawValue)
            ])
        )
        Task {
            _ = try? await session.append(draft, sessionID: sessionID)
            await MainActor.run { scheduleTrajectoryRefresh(for: sessionID) }
        }
    }

    @discardableResult
    func applyGoalAction(_ action: ConversationGoalAction) async -> Bool {
        do {
            workState = try await workStateCoordinator.applyGoalAction(action)
            await persistSession()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func setSessionModelConfiguration(_ configuration: AgentConfiguration?) async throws {
        let resolved = configuration.map {
            ModelProviderCatalog.applyingKnownModelContract(to: $0)
        }
        let validated = try resolved?.validated()
        if let validated {
            guard try await apiKey(for: validated) != nil else {
                throw CredentialStoreError.emptyCredential
            }
        }
        controlState.modelConfiguration = validated
        await persistSession()
    }

    func cancelRun() {
        guard let presentation = selectedRunPresentation, isRunning else { return }
        let identity = presentation.identity
        let cancelledQuestion = presentation.pendingUserQuestion
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.sessionRunRegistry.cancel(identity)
            if let cancelledQuestion {
                await self.recordQuestionLifecycle(
                    .questionResolved(
                        requestID: cancelledQuestion.id,
                        outcome: "cancelled"
                    ),
                    identity: identity
                )
            }
        }
    }

    /// User cancellation is a normal terminal state, not an error to surface
    /// in the chat. Keep other failures visible with their original detail.
    func presentError(_ error: Error) {
        guard !ISHPluginMarketplaceErrorPolicy.isCancellation(
            error,
            taskIsCancelled: false
        ) else { return }
        let detail = HarnessTraceRedactor.string(
            error.localizedDescription,
            maximumUTF8Bytes: 32 * 1_024
        )
        let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? detail
        errorMessage = HarnessTraceRedactor.string(firstLine, maximumUTF8Bytes: 1_200)
        Task { [traceStore] in
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    name: "app.presented_error",
                    error: detail
                )
            )
        }
    }

    func answerPendingUserQuestion(_ answer: AskUserQuestionAnswer) {
        guard let identity = selectedRunPresentation?.identity,
              let pendingUserQuestion else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sessionRunRegistry.setPendingQuestion(nil, for: identity)
                await self.recordQuestionLifecycle(
                    .questionResolved(
                        requestID: pendingUserQuestion.id,
                        outcome: "answered",
                        answer: answer
                    ),
                    identity: identity
                )
                let provider = try await self.sessionRunRegistry.questionProvider(for: identity)
                try await provider.submit(
                    answer,
                    requestID: pendingUserQuestion.id
                )
            } catch {
                self.presentError(error)
            }
        }
    }

    func cancelPendingUserQuestion() {
        guard let identity = selectedRunPresentation?.identity,
              let pendingUserQuestion else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.sessionRunRegistry.setPendingQuestion(nil, for: identity)
            await self.recordQuestionLifecycle(
                .questionResolved(
                    requestID: pendingUserQuestion.id,
                    outcome: "cancelled"
                ),
                identity: identity
            )
            guard let provider = try? await self.sessionRunRegistry.questionProvider(for: identity) else {
                return
            }
            try? await provider.cancel(requestID: pendingUserQuestion.id)
        }
    }

    func resolveApproval(_ resolution: ToolApprovalResolution) {
        guard let identity = selectedRunPresentation?.identity,
              let request = pendingApproval else { return }

        let approved: Bool
        switch resolution {
        case .deny:
            approved = false
        case .allowOnce:
            approved = true
        case .trustScope:
            do {
                try rememberToolApproval(request)
                approved = true
            } catch {
                presentError(error)
                approved = false
            }
        case .trustDevice:
            do {
                try rememberDeviceToolApproval(for: request)
                approved = true
            } catch {
                presentError(error)
                approved = false
            }
        }
        Task { [sessionRunRegistry] in
            _ = try? await sessionRunRegistry.resolveApproval(
                requestID: request.id,
                approved: approved,
                for: identity
            )
        }
    }

    func resolveApproval(approved: Bool) {
        resolveApproval(approved ? .allowOnce : .deny)
    }

    func revokeToolApproval(id: UUID) {
        guard trustedToolApprovals.contains(where: { $0.id == id }) else { return }
        let remaining = trustedToolApprovals.filter { $0.id != id }
        do {
            try settingsStore.saveToolApprovalGrants(remaining)
            trustedToolApprovals = remaining
        } catch {
            presentError(error)
        }
    }

    func revokeAllToolApprovals() {
        guard !trustedToolApprovals.isEmpty else { return }
        do {
            try settingsStore.saveToolApprovalGrants([])
            trustedToolApprovals = []
        } catch {
            presentError(error)
        }
    }

    func toggleMessageFeedback(
        messageID: UUID,
        rating: MessageFeedbackRating
    ) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant,
              let sessionID = activeSessionID else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await feedbackSidecarStore.record(
                    sessionID: sessionID,
                    messageID: messageID
                )
                let record: MessageFeedbackSidecarRecord
                if current?.rating == rating {
                    record = try await feedbackSidecarStore.clear(
                        sessionID: sessionID,
                        messageID: messageID,
                        expectedRevision: current?.revision
                    )
                } else {
                    record = try await feedbackSidecarStore.setRating(
                        sessionID: sessionID,
                        messageID: messageID,
                        rating: rating,
                        expectedRevision: current?.revision
                    )
                }
                applyFeedbackSidecarRecord(record, messageID: messageID)
                await persistSession()
            } catch {
                presentError(error)
            }
        }
    }

    func updateMessageFeedbackNote(messageID: UUID, note: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant,
              let sessionID = activeSessionID else { return }

        let hasVisibleText = note.contains { !$0.isWhitespace }
        let normalizedNote = hasVisibleText ? note : nil
        if let normalizedNote,
           normalizedNote.utf8.count > MessageFeedback.maximumNoteUTF8Bytes {
            errorMessage = "反馈备注不能超过 4 KiB。"
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await feedbackSidecarStore.record(
                    sessionID: sessionID,
                    messageID: messageID
                )
                let record = try await feedbackSidecarStore.updateNote(
                    sessionID: sessionID,
                    messageID: messageID,
                    note: normalizedNote,
                    expectedRevision: current?.revision
                )
                applyFeedbackSidecarRecord(record, messageID: messageID)
                await persistSession()
            } catch {
                presentError(error)
            }
        }
    }

    private func applyFeedbackSidecarRecord(
        _ record: MessageFeedbackSidecarRecord,
        messageID: UUID
    ) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].feedback = record.rating.map {
            MessageFeedback(
                rating: $0,
                note: record.note,
                version: record.id,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        }
    }

    func resetConversation(preserveTrajectory: Bool = false) async {
        cancelRun()
        selectedRunPresentation = nil
        hasStagedImage = false
        stagedImageReference = nil
        hasStagedFile = false
        stagedFileReference = nil
        stagedShareAdmission = nil
        messages = []
        controlState.unlockAgentPresetForBlankConversation()
        controlState.removeAllQueuedInputs()
        omittedContextMessages = 0
        hasResumableRun = false
        if !preserveTrajectory, let activeSessionID {
            do {
                try await trajectoryRepository.delete(sessionID: activeSessionID)
            } catch {
                presentError(error)
            }
        }
        if !preserveTrajectory {
            resetTrajectoryProjection()
        }
        await persistSession()
    }

    func createConversation(title: String = "新会话") async {
        hasStagedImage = false
        stagedImageReference = nil
        hasStagedFile = false
        stagedFileReference = nil
        stagedShareAdmission = nil
        do {
            let session = try await sessionStore.createSession(
                title: title,
                controlState: defaultConversationControlState()
            )
            apply(session: session)
            await restoreRunPresentation(for: session.id)
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: session.workState)
            await refreshSessionSummaries()
            await refreshTrajectory()
            if ishPluginHostClient != nil {
                await refreshISHPluginHost()
            }
            await deliverPendingJobCompletions(for: session.id)
        } catch {
            presentError(error)
        }
    }

    /// Admits persisted system-entry requests only after the normal app
    /// bootstrap/configuration path is ready. The actual work intentionally
    /// delegates to the same session and run methods used by the chat UI.
    @discardableResult
    func consumeAppIntentInbox() async -> Bool {
        guard isReady, isConfigured else { return false }
        var shouldOpenChat = false
        do {
            while let request = try await appIntentInboxStore.consumeNext() {
                switch request.action {
                case .openSession:
                    guard let sessionID = request.sessionID else { continue }
                    await switchConversation(to: sessionID)
                    shouldOpenChat = activeSessionID == sessionID

                case .retryLatestUserMessage:
                    guard let sessionID = request.sessionID else { continue }
                    await switchConversation(to: sessionID)
                    guard activeSessionID == sessionID,
                          let message = messages.last(where: { $0.role == .user }) else {
                        continue
                    }
                    retryFromUserMessage(id: message.id)
                    shouldOpenChat = true

                case .sendPrompt:
                    guard let prompt = request.prompt else { continue }
                    if let sessionID = request.sessionID {
                        await switchConversation(to: sessionID)
                        guard activeSessionID == sessionID else { continue }
                    } else {
                        let previousSessionID = activeSessionID
                        await createConversation(title: String(prompt.prefix(40)))
                        guard activeSessionID != previousSessionID else { continue }
                    }
                    _ = await send(prompt)
                    shouldOpenChat = true
                }
            }
        } catch {
            presentError(error)
        }
        return shouldOpenChat
    }

    func switchConversation(to id: UUID) async {
        guard id != activeSessionID else { return }
        hasStagedImage = false
        stagedImageReference = nil
        hasStagedFile = false
        stagedFileReference = nil
        stagedShareAdmission = nil
        do {
            let session = try await sessionStore.switchActiveSession(to: id)
            apply(session: session)
            await restoreRunPresentation(for: session.id)
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: session.workState)
            await refreshSessionSummaries()
            await refreshTrajectory()
            if ishPluginHostClient != nil {
                await refreshISHPluginHost()
            }
            await deliverPendingJobCompletions(for: id)
        } catch {
            presentError(error)
        }
    }

    func deleteConversation(id: UUID) async {
        if let identity = await sessionRunRegistry.lookup(sessionID: id)?.identity {
            _ = try? await sessionRunRegistry.cancel(identity)
            _ = try? await sessionRunRegistry.awaitQuiescence(for: identity)
        }
        do {
            _ = try await sessionStore.deleteSession(id: id)
            let trajectoryDeletionError: Error?
            do {
                try await trajectoryRepository.delete(sessionID: id)
                trajectoryDeletionError = nil
            } catch {
                trajectoryDeletionError = error
            }
            var state = try await sessionStore.loadState()
            if state.activeSession == nil {
                _ = try await sessionStore.createSession(
                    title: "新会话",
                    controlState: defaultConversationControlState()
                )
                state = try await sessionStore.loadState()
            }
            applySessionState(state)
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: workState)
            await refreshTrajectory()
            if ishPluginHostClient != nil {
                await refreshISHPluginHost()
            }
            if let trajectoryDeletionError {
                errorMessage = trajectoryDeletionError.localizedDescription
            }
        } catch {
            presentError(error)
        }
    }

    func renameConversation(id: UUID, title: String) async {
        do {
            let renamed = try await sessionStore.renameSession(id: id, title: title)
            do {
                _ = try await trajectoryRepository.append(
                    SessionEventDraft(
                        type: "session/title",
                        data: .object([
                            "title": .string(renamed.title),
                            "messageSeqs": .array([]),
                            "source": .object(["kind": .string("user")])
                        ]),
                        ignorable: true
                    ),
                    sessionID: id
                )
                try await trajectoryRepository.flush(sessionID: id)
            } catch {
                await traceStore.record(
                    HarnessTraceDraft(
                        kind: .error,
                        runID: activeRunID ?? UUID(),
                        name: "session-title/user-event-failed",
                        error: error.localizedDescription
                    )
                )
            }
            await refreshSessionSummaries()
            if activeSessionID == id {
                await refreshTrajectory(for: id)
            }
        } catch {
            presentError(error)
        }
    }

    func searchConversations(query: String) async -> [ConversationSessionSearchResult] {
        do {
            _ = try await sessionQueryReadModel.rebuild(persistence: trajectoryRepository)
            let indexedHits = try await sessionQueryReadModel.searchSessions(query: query)
            let summaries = Dictionary(
                uniqueKeysWithValues: try await sessionStore.listSessions().map { ($0.id, $0) }
            )
            let projected = indexedHits.compactMap { hit -> ConversationSessionSearchResult? in
                guard let summary = summaries[hit.session.id] else { return nil }
                let titleMatched = summary.title.localizedCaseInsensitiveContains(query)
                return ConversationSessionSearchResult(
                    session: summary,
                    matchSnippet: hit.snippet.isEmpty ? nil : hit.snippet,
                    matchedMessageID: nil,
                    titleMatched: titleMatched
                )
            }
            if !projected.isEmpty { return projected }
            return try await sessionStore.searchSessions(query: query)
        } catch {
            presentError(error)
            return []
        }
    }

    func forkConversation(id: UUID) async {
        cancelRun()
        if activeSessionID != nil {
            await persistSession()
        }
        do {
            let session = try await sessionStore.forkSession(id: id)
            apply(session: session)
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: session.workState)
            await refreshSessionSummaries()
            await refreshTrajectory()
            if ishPluginHostClient != nil {
                await refreshISHPluginHost()
            }
        } catch {
            presentError(error)
        }
    }

    func archiveConversation(id: UUID) async {
        let isArchivingActiveSession = id == activeSessionID
        if isArchivingActiveSession {
            cancelRun()
            await persistSession()
        }
        do {
            _ = try await sessionStore.archiveSession(id: id)
            guard isArchivingActiveSession else {
                await refreshSessionSummaries()
                return
            }
            var state = try await sessionStore.loadState()
            if state.activeSession == nil {
                _ = try await sessionStore.createSession(
                    title: "新会话",
                    controlState: defaultConversationControlState()
                )
                state = try await sessionStore.loadState()
            }
            applySessionState(state)
            await projectFeedbackSidecar()
            await workStateCoordinator.replace(with: workState)
            await refreshTrajectory()
            if ishPluginHostClient != nil {
                await refreshISHPluginHost()
            }
        } catch {
            presentError(error)
        }
    }

    func restoreConversation(id: UUID) async {
        do {
            _ = try await sessionStore.restoreSession(id: id)
            await refreshSessionSummaries()
        } catch {
            presentError(error)
        }
    }

    func resumePendingRun() {
        Task { @MainActor [weak self] in
            await self?.resumePendingRunNow()
        }
    }

    private func resumePendingRunNow(useContinuedProcessing: Bool = true) async {
        guard hasResumableRun, !messages.isEmpty, !isRunning else { return }
        await startRun(
            history: messages,
            workState: workState,
            useContinuedProcessing: useContinuedProcessing
        )
    }

    func updateApplicationActivity(isActive: Bool, isBackgrounded: Bool = false) {
        appIsActive = isActive
        appIsBackgrounded = isBackgrounded
        runtimeHangWatchdog.setApplicationActive(isActive && !isBackgrounded)
        Task { [runtimeTelemetryStore] in
            await runtimeTelemetryStore.recordPerformanceSample(
                RuntimeResourceGovernor.currentSignals(isBackgrounded: isBackgrounded)
            )
        }
        Task { [weak self, sessionRunRegistry] in
            let aggregate = await sessionRunRegistry.aggregate()
            await self?.refreshSessionRunProjection()
            for run in aggregate.runs {
                _ = await sessionRunRegistry.setPresentationUpdatesEnabled(
                    isActive,
                    for: run.identity
                )
            }
            if isActive {
                await self?.refreshTrajectory()
            }
        }
        if isActive {
            Task { [weak self] in
                await self?.auditBackgroundRunJournalOnForeground()
            }
        }
        Task { [backgroundResumeCoordinator] in
            await backgroundResumeCoordinator.updateApplicationActivity(isActive: isActive)
        }
        refreshBackgroundAudioKeepAlive()
        refreshBackgroundLocationKeepAlive()
        refreshBackgroundSystemProjection()
#if os(iOS) && canImport(BackgroundTasks)
        if isActive {
            Task { [weak self] in
                await self?.scheduleNextBackgroundTurn()
            }
        }
#endif
        guard isActive else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.backgroundResumeCoordinator.updateApplicationActivity(isActive: true)
            if let activeSessionID = self.activeSessionID {
                await self.scheduleSystemExpirationResume(for: activeSessionID)
            }
            await self.refreshWorkspace(forceMountRefresh: true)
            if let activeSessionID = self.activeSessionID {
                await self.deliverPendingJobCompletions(for: activeSessionID)
            }
        }
    }

    /// Reconcile the audio survival leg against the durable run registry. The
    /// audio engine never infers liveness from the selected UI session, so
    /// switching sessions cannot accidentally stop another live root run.
    func refreshBackgroundAudioKeepAlive() {
        refreshBackgroundKeepAliveCoordinator()
    }

    /// Location survival has its own explicit opt-in and never infers authority
    /// from the foreground one-shot location tool.
    func refreshBackgroundLocationKeepAlive() {
        refreshBackgroundKeepAliveCoordinator()
    }

    private func refreshBackgroundKeepAliveCoordinator() {
        let isBackgrounded = appIsBackgrounded
        Task { @MainActor [weak self] in
            guard let self else { return }
            let liveRootCount = await sessionRunRegistry.aggregate().liveRootCount
            let processInfo = ProcessInfo.processInfo
            backgroundKeepAliveCoordinator.update(
                BackgroundKeepAliveInputs(
                isBackgrounded: isBackgrounded,
                hasLiveRoot: liveRootCount > 0,
                enhancedAudioRequested: backgroundPreferences.isEnhancedBackgroundEnabled,
                locationRequested: backgroundPreferences.isBackgroundLocationKeepAliveEnabled,
                hasFiniteBackgroundLease: legacyBackgroundTaskLease.hasSystemTask,
                hasContinuedProcessing: continuedProcessingController.hasAttachedSystemTask,
                isLowPowerMode: processInfo.isLowPowerModeEnabled,
                isThermallyConstrained: processInfo.thermalState == .serious
                    || processInfo.thermalState == .critical
                )
            )
            self.refreshBackgroundSystemProjection()
        }
    }

    /// Rebuilds the single system-status projection. The projection only
    /// contains counts, capability flags and redacted status labels.
    func refreshBackgroundSystemProjection() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let aggregate = await sessionRunRegistry.aggregate()
            let notification = await completionNotifier.authorizationStatus()
            let location = backgroundKeepAliveCoordinator.locationSnapshot.authorization
            let liveActivitySupported: Bool = {
#if os(iOS) && canImport(ActivityKit)
                HarnessLiveActivityManager.isSystemSupported
#else
                false
#endif
            }()
            let nextProjection = BackgroundSystemProjection.make(
                activeRunCount: aggregate.liveRootCount,
                keepAliveState: backgroundKeepAliveCoordinator.state,
                isBackgrounded: appIsBackgrounded,
                liveActivitySupported: liveActivitySupported,
                liveActivityEnabled: backgroundPreferences.isLiveActivityEnabled,
                notificationAuthorization: Self.backgroundNotificationLabel(notification),
                locationAuthorization: Self.backgroundLocationLabel(location),
                privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled
            )
            guard nextProjection != backgroundSystemProjection else { return }
            backgroundSystemProjection = nextProjection
            refreshWidgetProjection()
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .backgroundTask,
                    name: "background_projection_changed",
                    attributes: [
                        "active_run_count": .number(Double(nextProjection.activeRunCount)),
                        "survival_tier": .string(nextProjection.survivalTier.rawValue),
                        "is_backgrounded": .bool(nextProjection.isBackgrounded),
                        "degraded_reasons": .array(
                            nextProjection.degradedReasons.map { .string(Self.backgroundDegradedLabel($0)) }
                        ),
                        "degraded_details": .array(
                            nextProjection.degradedDetails.map { .string($0) }
                        )
                    ]
                )
            )
        }
    }

    private static func backgroundNotificationLabel(
        _ authorization: BackgroundNotificationAuthorization
    ) -> String {
        switch authorization {
        case .notDetermined: "尚未请求"
        case .denied: "已拒绝"
        case .authorized: "已允许"
        case .unavailable: "不可用"
        }
    }

    private static func backgroundLocationLabel(
        _ authorization: BackgroundLocationAuthorization
    ) -> String {
        switch authorization {
        case .notDetermined: "尚未请求"
        case .whenInUse: "仅使用期间"
        case .always: "始终允许"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .unavailable: "不可用"
        }
    }

    private static func backgroundDegradedLabel(
        _ reason: BackgroundKeepAliveDegradedReason
    ) -> String {
        switch reason {
        case .lowPowerMode: "low_power_mode"
        case .thermalPressure: "thermal_pressure"
        case .audioUnavailable: "audio_unavailable"
        case .locationUnavailable: "location_unavailable"
        }
    }

    func requestBackgroundLocationAuthorization() {
        backgroundKeepAliveCoordinator.requestLocationAuthorizationIfEnabled()
    }

    var backgroundLocationKeepAliveSnapshot: BackgroundLocationKeepAliveSnapshot {
        backgroundKeepAliveCoordinator.locationSnapshot
    }

    func suspendBackgroundAudioForMedia() {
        backgroundKeepAliveCoordinator.suspendAudioForMedia()
    }

    func resumeBackgroundAudioForMedia() {
        backgroundKeepAliveCoordinator.resumeAudioForMedia()
    }

    func importDocument(_ url: URL) async {
        do {
            _ = try await workspaceStore.importFile(from: url)
            await refreshWorkspace()
        } catch {
            presentError(error)
        }
    }

    func workspaceFileData(path: String) async throws -> Data {
        try await workspaceStore.readData(path: path)
    }

    func mountWorkspaceFolder(_ url: URL) async {
        do {
            _ = try await workspaceStore.mountFolder(from: url)
            await refreshWorkspace()
        } catch {
            presentError(error)
        }
    }

    func reauthorizeWorkspaceMount(id: UUID, url: URL) async {
        do {
            _ = try await workspaceStore.reauthorizeMount(id: id, with: url)
            await refreshWorkspace()
        } catch {
            presentError(error)
        }
    }

    func setWorkspaceMountWritable(id: UUID, writable: Bool) async {
        do {
            _ = try await workspaceStore.setMountAccess(
                id: id,
                access: writable ? .readWrite : .readOnly
            )
            await refreshWorkspace()
        } catch {
            presentError(error)
        }
    }

    func removeWorkspaceMount(id: UUID) async {
        do {
            try await workspaceStore.removeMount(id: id)
            await refreshWorkspace()
        } catch {
            presentError(error)
        }
    }

    func stageImage(_ data: Data) async {
        guard !isRunning else {
            presentError(
                NSError(
                    domain: "HarnessMobile",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "当前任务仍在运行，请等待完成后再添加附件。"]
                )
            )
            return
        }
        do {
            stagedImageReference = try await workspaceStore.stageImage(data)
            hasStagedImage = true
        } catch {
            presentError(error)
        }
    }

    func stageFileAttachment(from url: URL) async {
        guard !isRunning else {
            presentError(
                NSError(
                    domain: "HarnessMobile",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "当前任务仍在运行，请等待完成后再添加附件。"]
                )
            )
            return
        }
        do {
            stagedFileReference = try await workspaceStore.stageFileAttachment(from: url)
            hasStagedFile = true
        } catch {
            presentError(error)
        }
    }

    func installShareAdmission(_ admission: WorkspaceShareAdmission) {
        if let existing = stagedShareAdmission {
            var seenImageIDs: Set<UUID> = []
            let images = (existing.imageAttachments + admission.imageAttachments).filter {
                seenImageIDs.insert($0.id).inserted
            }
            var seenFileIDs: Set<UUID> = []
            let files = (existing.fileAttachments + admission.fileAttachments).filter {
                seenFileIDs.insert($0.id).inserted
            }
            stagedShareAdmission = WorkspaceShareAdmission(
                handoffID: admission.handoffID,
                inlineText: nil,
                imageAttachments: images,
                fileAttachments: files
            )
        } else {
            stagedShareAdmission = admission
        }
        hasStagedImage = !allStagedImageReferences.isEmpty
        hasStagedFile = !allStagedFileReferences.isEmpty
        if let inlineText = admission.inlineText, !inlineText.isEmpty {
            let existing = pendingDraft?.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingDraft = [existing, inlineText]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n\n")
        }
    }

    func refreshWorkspace(forceMountRefresh: Bool = false) async {
        do {
            workspaceMounts = try await workspaceStore.activateMounts(
                forceRefresh: forceMountRefresh
            )
            let mounts = try await workspaceStore.activeMountBindings()
            await ISHSandboxCoordinator.shared.setWorkspaceMounts(mounts)
            workspaceFiles = try await workspaceStore.listFiles()
            inputSkillCatalogCache = nil
        } catch {
            presentError(error)
        }
    }

    private func loadHookConfiguration() async {
        let candidates: [(path: String, mode: HookMatcherGroup.MatcherMode)] = [
            (".codex/hooks.json", .codex),
            (".claude/settings.json", .claudeCode),
            (".dsh/hooks.json", .codex)
        ]
        for candidate in candidates {
            guard let text = try? await workspaceStore.readText(path: candidate.path),
                  let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
                continue
            }
            do {
                let groups: [HookPoint: [HookMatcherGroup]]
                switch candidate.mode {
                case .codex:
                    groups = try CodexHookConfigParser.parse(raw: raw).config
                case .claudeCode:
                    groups = try ClaudeCodeHookConfigParser.parse(raw: raw).config
                }
                guard !groups.isEmpty else { continue }
                let workspaceStore = self.workspaceStore
                let executor: HookRunner.Executor = { command, stdinJSON, timeoutSec in
                    let workspaceURL = try await workspaceStore.rootURL()
                    let encoded = Data(stdinJSON.utf8).base64EncodedString()
                    let script = "printf '%s' '\(encoded)' | base64 -d | (\(command))"
                    let result = try await ISHSandboxCoordinator.shared.execute(
                        sessionID: "hook.\(UUID().uuidString.lowercased())",
                        command: script,
                        workspaceURL: workspaceURL,
                        timeout: TimeInterval(timeoutSec ?? 300),
                        maximumOutputBytes: 128 * 1_024,
                        policy: ISHSandboxExecutionPolicy(
                            mode: .dangerFullAccess,
                            workspaceRoot: workspaceURL
                        )
                    )
                    return HookProtocol.parseHookOutput(
                        exitCode: result.exitCode,
                        stdout: result.stdout,
                        stderr: result.stderr
                    )
                }
                loadedHookConfiguration = AgentHookConfiguration(
                    groups: groups,
                    mode: candidate.mode,
                    executor: executor
                )
                return
            } catch {
                continue
            }
        }
        loadedHookConfiguration = nil
    }

    func refreshPluginInventory() async {
        await refreshNativePluginInventory()
        if ishPluginHostClient != nil {
            await refreshISHPluginHost()
        }
    }

    func refreshNativePluginInventory() async {
        pluginSnapshots = await pluginRuntime.snapshots()
        pluginToolContributions = await agentServices.tools.snapshots()
        pluginPromptContributions = await agentServices.systemPrompt.snapshots()
        ishNativeClientPlugins = await ishNativeClientRegistry.plugins()
    }

    @discardableResult
    func startISHPluginHost(reportErrorsGlobally: Bool = true) async -> Bool {
        if let lifecycleTask = ishPluginHostLifecycleTask {
            return await lifecycleTask.value
        }

        if let client = ishPluginHostClient,
           case .running = ishPluginHostState {
            let diagnostics = await client.diagnostics()
            if case .running = diagnostics.state {
                ishPluginHostDiagnostics = diagnostics
                return true
            }
        }

        let lifecycleTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performStartISHPluginHost(
                reportErrorsGlobally: reportErrorsGlobally
            )
        }
        ishPluginHostLifecycleTask = lifecycleTask
        let result = await lifecycleTask.value
        ishPluginHostLifecycleTask = nil
        return result
    }

    private func performStartISHPluginHost(reportErrorsGlobally: Bool) async -> Bool {
        do {
            let client: ISHPluginHostClient
            let expectedProtocolVersion: Int?
            if let existing = ishPluginHostClient {
                client = existing
                expectedProtocolVersion = nil
                ishPluginHostState = .starting
            } else {
                ishPluginHostDiagnostics = nil
                ishPluginHostState = .installing
                let workspaceURL = try await workspaceStore.rootURL()
                let installation = try await ISHPluginHostInstaller.shared.installIfNeeded(
                    workspaceURL: workspaceURL,
                    mirrorURL: URL(string: "https://registry.npmmirror.com")
                )
                expectedProtocolVersion = installation.manifest.protocolVersion
                ishPluginHostState = .starting
                client = ISHPluginHostClient(
                    transport: ISHPersistentPluginHostTransport(workspaceURL: workspaceURL)
                )
                ishPluginHostClient = client
            }

            try await client.start()
            let ping = try await client.ping()
            if let expectedProtocolVersion,
               ping.protocolVersion != expectedProtocolVersion {
                throw ISHPluginHostError.invalidProtocol(
                    "iSH 插件 Host 协议版本不匹配：期望 \(expectedProtocolVersion)，实际 \(ping.protocolVersion)。"
                )
            }
            ishPluginHostPackages = ping.packages
            // Keep the initial handshake cheap. Context projection, settings,
            // dynamic contributions and native-client registration are only
            // needed when a session is active or a marketplace screen asks
            // for them; doing all of them before the first usable ping made
            // every Host cold start pay the full synchronization cost.
            if activeSessionID != nil {
                try await synchronizeISHPluginHost(client: client, ping: ping)
            } else {
                let inventory = try await client.inventory()
                ishPluginHostInventory = inventory.entries
                ishPluginHostPackages = ping.packages
                ishPluginHostDiagnostics = await client.diagnostics()
                ishPluginHostState = .running(
                    hostVersion: ping.hostVersion,
                    processID: processID(from: ishPluginHostDiagnostics)
                )
                await refreshNativePluginInventory()
            }
            await refreshISHMarketplacePlugins(client: client)
            return true
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            await stopISHPluginHost()
            return false
        } catch {
            await failISHPluginHost(error, reportErrorsGlobally: reportErrorsGlobally)
            return false
        }
    }

    private func processID(from diagnostics: ISHPluginHostClient.Diagnostics?) -> Int32? {
        guard let diagnostics else { return nil }
        if case let .running(pid) = diagnostics.state { return pid }
        return nil
    }

    func stopISHPluginHost() async {
        ishPluginHostLifecycleTask?.cancel()
        ishPluginHostLifecycleTask = nil
        ishPluginHostRefreshTask?.cancel()
        ishPluginHostRefreshTask = nil
        let client = ishPluginHostClient
        ishPluginHostClient = nil
        await client?.stop()
        await removeISHPluginBridge()
        ishPluginHostInventory = []
        ishPluginHostPackages = [:]
        ishPluginHostDiagnostics = nil
        ishPluginSettingsSnapshot = nil
        ishMarketplacePlugins = mergedMarketplacePlugins(hostPlugins: [])
        ishPluginHostState = .stopped
        await refreshNativePluginInventory()
    }

    func refreshISHPluginHost() async {
        if let refreshTask = ishPluginHostRefreshTask {
            await refreshTask.value
            return
        }
        let refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshISHPluginHost()
        }
        ishPluginHostRefreshTask = refreshTask
        await refreshTask.value
        ishPluginHostRefreshTask = nil
    }

    private func performRefreshISHPluginHost() async {
        // If a startup is already in progress, wait for its one shared
        // lifecycle task instead of racing a second ping/context sync against
        // the same iSH process.
        if let lifecycleTask = ishPluginHostLifecycleTask {
            _ = await lifecycleTask.value
        }
        guard let client = ishPluginHostClient else { return }
        do {
            let ping = try await client.ping()
            ishPluginHostPackages = ping.packages
            try await synchronizeISHPluginHost(client: client, ping: ping)
            await refreshISHMarketplacePlugins(client: client)
        } catch {
            await failISHPluginHost(error)
        }
    }

    func invokeISHNativeClientInspector(
        pluginID: String,
        inspectorID: String
    ) async throws -> JSONValue {
        guard let client = ishPluginHostClient else {
            throw ISHPluginHostError.invalidState("iSH 插件 Host 尚未运行。")
        }
        guard let plugin = await ishNativeClientRegistry.plugin(id: pluginID),
              let inspector = plugin.contributions.inspectors.first(where: { $0.id == inspectorID }),
              plugin.endpoints.contains(where: { $0.id == inspector.endpoint }) else {
            throw ISHNativeClientError.endpointFailed(
                code: "contribution-not-active",
                message: "原生 Inspector 已停止或被替换。"
            )
        }
        return try await client.invokeNativeClientEndpoint(
            ISHNativeClientEndpointInvocation(
                pluginId: plugin.pluginId,
                activationGeneration: plugin.activationGeneration,
                endpointId: inspector.endpoint
            )
        )
    }

    @discardableResult
    func refreshISHPluginSettings() async -> Bool {
        guard let client = ishPluginHostClient else {
            errorMessage = "iSH 插件 Host 尚未运行。"
            return false
        }
        do {
            _ = try await loadISHPluginSettings(client: client)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func mutateISHPluginSettings(
        namespace: String,
        operations: [ISHPluginSettingsPathOperation],
        expectedRevision: Int
    ) async throws -> ISHPluginSettingsNamespace {
        guard let client = ishPluginHostClient else {
            throw ISHPluginHostError.invalidState("iSH 插件 Host 尚未运行。")
        }
        return try await performISHPluginSettingsWrite(
            client: client,
            namespace: namespace,
            expectedRevision: expectedRevision,
            operationCount: operations.count
        ) {
            try await client.mutateSettings(
                ISHPluginSettingsMutateRequest(
                    ns: namespace,
                    ops: operations,
                    expectedRevision: expectedRevision
                )
            )
        }
    }

    func updateISHPluginSettings(
        namespace: String,
        patch: [String: JSONValue],
        expectedRevision: Int
    ) async throws -> ISHPluginSettingsNamespace {
        guard let client = ishPluginHostClient else {
            throw ISHPluginHostError.invalidState("iSH 插件 Host 尚未运行。")
        }
        return try await performISHPluginSettingsWrite(
            client: client,
            namespace: namespace,
            expectedRevision: expectedRevision,
            operationCount: patch.count
        ) {
            try await client.updateSettings(
                ISHPluginSettingsUpdateRequest(
                    ns: namespace,
                    patch: patch,
                    expectedRevision: expectedRevision
                )
            )
        }
    }

    func replaceISHPluginSettings(
        namespace: String,
        section: [String: JSONValue],
        expectedRevision: Int
    ) async throws -> ISHPluginSettingsNamespace {
        guard let client = ishPluginHostClient else {
            throw ISHPluginHostError.invalidState("iSH 插件 Host 尚未运行。")
        }
        return try await performISHPluginSettingsWrite(
            client: client,
            namespace: namespace,
            expectedRevision: expectedRevision,
            operationCount: section.count
        ) {
            try await client.replaceSettings(
                ISHPluginSettingsReplaceRequest(
                    ns: namespace,
                    section: section,
                    expectedRevision: expectedRevision
                )
            )
        }
    }

    func defineAndRunISHPlugin(
        name: String,
        purpose: String,
        hostCode: String
    ) async -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = hostCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= 128,
              !normalizedPurpose.isEmpty,
              normalizedPurpose.utf8.count <= 2_048,
              !normalizedCode.isEmpty,
              normalizedCode.utf8.count <= 240 * 1_024 else {
            errorMessage = "插件名称、用途或 Host 代码无效。"
            return false
        }
        guard await startISHPluginHost(),
              let client = ishPluginHostClient,
              let sessionID = activeSessionID?.uuidString else {
            return false
        }

        do {
            let receipt = try await client.define(
                ISHPluginHostDefineRequest(
                    sessionId: sessionID,
                    plugin: .new(idPrefix: "mobile"),
                    name: normalizedName,
                    purpose: normalizedPurpose,
                    code: ISHPluginHostDefinitionCode(host: normalizedCode)
                )
            )
            _ = try await activateISHPlugin(
                client: client,
                sessionID: sessionID,
                pluginID: receipt.pluginId,
                packageID: receipt.packageId,
                mode: .run
            )
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func runISHPlugin(
        pluginID: String,
        packageID: String,
        mode: ISHPluginHostRunMode
    ) async {
        guard let client = ishPluginHostClient,
              let sessionID = activeSessionID?.uuidString else {
            errorMessage = "iSH 插件 Host 尚未运行。"
            return
        }
        do {
            _ = try await activateISHPlugin(
                client: client,
                sessionID: sessionID,
                pluginID: pluginID,
                packageID: packageID,
                mode: mode
            )
        } catch {
            presentError(error)
        }
    }

    func stopISHPlugin(pluginID: String) async {
        guard let client = ishPluginHostClient,
              let sessionID = activeSessionID?.uuidString else { return }
        do {
            let response = try await client.stopPlugin(
                ISHPluginHostPluginRequest(sessionId: sessionID, pluginId: pluginID)
            )
            guard response.ok else {
                throw ISHPluginHostError.invalidState(
                    response.message ?? response.reason ?? "iSH 插件未能停止。"
                )
            }
            try await synchronizeISHPluginHost(client: client)
        } catch {
            presentError(error)
        }
    }

    func undefineISHPlugin(pluginID: String) async {
        guard let client = ishPluginHostClient,
              let sessionID = activeSessionID?.uuidString else { return }
        do {
            let response = try await client.undefine(
                ISHPluginHostPluginRequest(sessionId: sessionID, pluginId: pluginID)
            )
            guard response.ok else {
                throw ISHPluginHostError.invalidState(
                    response.message ?? response.reason ?? "iSH 插件未能卸载。"
                )
            }
            try await synchronizeISHPluginHost(client: client)
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    private func activateISHPlugin(
        client: ISHPluginHostClient,
        sessionID: String,
        pluginID: String,
        packageID: String,
        mode: ISHPluginHostRunMode
    ) async throws -> ISHPluginHostRunResponse {
        let response = try await client.run(
            ISHPluginHostRunRequest(
                sessionId: sessionID,
                pluginId: pluginID,
                packageId: packageID,
                mode: mode
            )
        )
        // A failed update still changes latestRun/nextPackageId. Refresh before
        // surfacing the error so the native management UI shows rollback state.
        try await synchronizeISHPluginHost(client: client)
        guard response.ok else {
            throw ISHPluginHostError.invalidState(
                response.message ?? response.reason ?? "iSH 插件未能启动。"
            )
        }
        return response
    }

    private func synchronizeISHPluginHost(
        client: ISHPluginHostClient,
        ping: ISHPluginHostPing? = nil
    ) async throws {
        let sessionID = activeSessionID?.uuidString
        if let sessionID {
            try await synchronizeISHMobileContext(client: client, sessionID: sessionID)
        }
        let inventory = try await client.inventory(sessionId: sessionID)
        _ = try await loadISHPluginSettings(client: client)
        let bridgeInstalled = await pluginRuntime.snapshots().contains {
            $0.id == ISHPluginHostCordisBridge.pluginID
        }
        if let sessionID {
            let contributions = try await client.contributions(sessionId: sessionID)
            let hasContributions = !contributions.tools.isEmpty
                || !contributions.commands.isEmpty
                || !contributions.prompt.sections.isEmpty
                || !contributions.prompt.contexts.isEmpty
                || !contributions.handlers.isEmpty
                || !contributions.services.isEmpty
            if hasContributions {
                let definition = ISHPluginHostCordisBridge.definition(
                    contributions: contributions,
                    sessionID: sessionID,
                    client: client,
                    commandRegistry: slashCommandRegistry,
                    synchronizeMobileContext: { [weak self, client] in
                        guard let self else { return }
                        try await self.synchronizeISHMobileContext(
                            client: client,
                            sessionID: sessionID
                        )
                    },
                    synchronizeContributions: { [weak self, client] in
                        guard let self else { return }
                        try await self.synchronizeISHPluginHost(client: client)
                    }
                )
                if bridgeInstalled {
                    _ = try await pluginRuntime.replace(definition.id, with: definition)
                } else {
                    _ = try await pluginRuntime.install(definition)
                }
            } else if bridgeInstalled {
                _ = try await pluginRuntime.uninstall(ISHPluginHostCordisBridge.pluginID)
            }
        } else if bridgeInstalled {
            _ = try await pluginRuntime.uninstall(ISHPluginHostCordisBridge.pluginID)
        }

        if let sessionID {
            let nativeClient = try await client.nativeClientContributions(sessionId: sessionID)
            ishNativeClientFailures = await ishNativeClientCoordinator.synchronize(
                nativeClient,
                sessionID: sessionID,
                client: client
            )
        } else {
            await ishNativeClientCoordinator.removeAll()
            ishNativeClientFailures = []
        }
        ishNativeClientPlugins = await ishNativeClientRegistry.plugins()

        let diagnostics = await client.diagnostics()
        let processID: Int32?
        switch diagnostics.state {
        case let .running(pid):
            processID = pid
        case .stopped, .starting, .exited:
            processID = nil
        }
        ishPluginHostInventory = inventory.entries
        ishPluginHostPackages = ping?.packages ?? inventory.packages
        ishPluginHostDiagnostics = diagnostics
        ishPluginHostState = .running(
            hostVersion: ping?.hostVersion ?? "1.0.0",
            processID: processID
        )
        await refreshNativePluginInventory()
    }

    private func synchronizeISHMobileContext(
        client: ISHPluginHostClient,
        sessionID: String,
        runID: UUID? = nil
    ) async throws {
        guard let nativeSessionID = UUID(uuidString: sessionID) else {
            throw ISHPluginHostError.invalidState("The active session ID is not a UUID.")
        }
        do {
            // UI snapshots intentionally retain only a bounded tail. The Host
            // projection must start at its own seq 0 and remain stable across
            // restarts, so build it from the complete persisted JSONL stream.
            async let persistedEvents = trajectoryRepository.persistedEvents(
                sessionID: nativeSessionID,
                matching: ISHPluginHostContextProjection.retains
            )
            async let skills = skillRegistry.definitions()
            let (retainedEvents, skillDefinitions) = try await (persistedEvents, skills)
            _ = try await client.synchronizeContext(
                sessionId: sessionID,
                events: ISHPluginHostContextProjection.events(from: retainedEvents),
                skills: skillDefinitions
            )
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            throw error
        } catch {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    sessionID: nativeSessionID,
                    runID: runID ?? activeRunID,
                    pluginID: "ish.plugin-host",
                    name: ISHPluginHostRPCMethod.contextSync.rawValue,
                    error: HarnessTraceRedactor.string(
                        error.localizedDescription,
                        maximumUTF8Bytes: 4_096
                    )
                )
            )
            throw error
        }
    }

    private func loadISHPluginSettings(
        client: ISHPluginHostClient
    ) async throws -> ISHPluginSettingsSnapshot {
        do {
            let snapshot = try await client.settings()
            ishPluginSettingsSnapshot = snapshot
            await recordISHPluginSettingsTrace(
                kind: .settingsRead,
                name: ISHPluginHostRPCMethod.settingsDescribe.rawValue,
                attributes: [
                    "namespaceCount": .number(Double(snapshot.namespaces.count)),
                    "writable": .bool(snapshot.writable)
                ]
            )
            return snapshot
        } catch {
            await recordISHPluginSettingsTrace(
                kind: .settingsRead,
                name: ISHPluginHostRPCMethod.settingsDescribe.rawValue,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func performISHPluginSettingsWrite(
        client: ISHPluginHostClient,
        namespace: String,
        expectedRevision: Int,
        operationCount: Int,
        operation: () async throws -> ISHPluginSettingsNamespace
    ) async throws -> ISHPluginSettingsNamespace {
        do {
            let descriptor = try await operation()
            applyISHPluginSettingsDescriptor(descriptor)
            await recordISHPluginSettingsTrace(
                kind: .settingsWrite,
                namespace: namespace,
                name: "settings/write",
                attributes: [
                    "expectedRevision": .number(Double(expectedRevision)),
                    "revision": .number(Double(descriptor.revision)),
                    "operationCount": .number(Double(operationCount)),
                    "status": .string("committed")
                ]
            )
            return descriptor
        } catch let error as ISHPluginHostError {
            if let conflict = error.settingsConflict {
                await recordISHPluginSettingsTrace(
                    kind: .settingsConflict,
                    namespace: namespace,
                    name: "settings/conflict",
                    attributes: [
                        "expectedRevision": .number(Double(conflict.expectedRevision)),
                        "actualRevision": conflict.actualRevision.map { .number(Double($0)) } ?? .null,
                        "operationCount": .number(Double(operationCount))
                    ],
                    error: error.localizedDescription
                )
                _ = try? await loadISHPluginSettings(client: client)
            } else {
                await recordISHPluginSettingsTrace(
                    kind: .settingsWrite,
                    namespace: namespace,
                    name: "settings/write",
                    attributes: [
                        "expectedRevision": .number(Double(expectedRevision)),
                        "operationCount": .number(Double(operationCount)),
                        "status": .string("rejected")
                    ],
                    error: error.localizedDescription
                )
            }
            throw error
        } catch {
            await recordISHPluginSettingsTrace(
                kind: .settingsWrite,
                namespace: namespace,
                name: "settings/write",
                attributes: [
                    "expectedRevision": .number(Double(expectedRevision)),
                    "operationCount": .number(Double(operationCount)),
                    "status": .string("failed")
                ],
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func applyISHPluginSettingsDescriptor(_ descriptor: ISHPluginSettingsNamespace) {
        let current = ishPluginSettingsSnapshot
            ?? ISHPluginSettingsSnapshot(writable: true, hasDocument: true, namespaces: [])
        var namespaces = current.namespaces
        if let index = namespaces.firstIndex(where: { $0.ns == descriptor.ns }) {
            namespaces[index] = descriptor
        } else {
            namespaces.append(descriptor)
        }
        ishPluginSettingsSnapshot = ISHPluginSettingsSnapshot(
            writable: current.writable,
            hasDocument: current.hasDocument,
            namespaces: namespaces
        )
    }

    private func recordISHPluginSettingsTrace(
        kind: HarnessTraceEventKind,
        namespace: String? = nil,
        name: String,
        attributes: [String: JSONValue] = [:],
        error: String? = nil
    ) async {
        var safeAttributes = attributes
        if let namespace {
            safeAttributes["namespace"] = .string(
                HarnessTraceRedactor.string(namespace, maximumUTF8Bytes: 512)
            )
        }
        await traceStore.record(
            HarnessTraceDraft(
                kind: kind,
                runID: activeRunID,
                pluginID: "ish.host.settings",
                name: name,
                attributes: safeAttributes,
                error: error.map {
                    HarnessTraceRedactor.string($0, maximumUTF8Bytes: 2_048)
                }
            )
        )
        if let identity = selectedRunPresentation?.identity {
            await scheduleHarnessTraceRefresh(for: identity)
        }
    }

    private func refreshISHMarketplacePlugins(client: ISHPluginHostClient) async {
        do {
            ishMarketplacePlugins = mergedMarketplacePlugins(
                hostPlugins: try await client.marketplacePlugins().plugins
            )
            await syncPluginInstallCoordinatorInventory(hostInventoryComplete: true)
        } catch {
            ishMarketplacePlugins = mergedMarketplacePlugins(hostPlugins: [])
        }
    }

    private func removeISHPluginBridge() async {
        let installed = await pluginRuntime.snapshots().contains {
            $0.id == ISHPluginHostCordisBridge.pluginID
        }
        if installed {
            _ = try? await pluginRuntime.uninstall(ISHPluginHostCordisBridge.pluginID)
        }
        await ishNativeClientCoordinator.removeAll()
        ishNativeClientPlugins = []
        ishNativeClientFailures = []
    }

    private func failISHPluginHost(
        _ error: Error,
        reportErrorsGlobally: Bool = true
    ) async {
        let client = ishPluginHostClient
        let diagnostics = await client?.diagnostics()
        await client?.stop()
        ishPluginHostClient = nil
        await removeISHPluginBridge()
        ishPluginHostInventory = []
        ishPluginHostPackages = [:]
        ishPluginHostDiagnostics = diagnostics
        ishPluginSettingsSnapshot = nil
        ishMarketplacePlugins = mergedMarketplacePlugins(hostPlugins: [])
        ishPluginHostState = .failed(error.localizedDescription)
        if reportErrorsGlobally {
            presentError(error)
        } else {
            reportISHPluginMarketplaceError(error)
        }
        await refreshNativePluginInventory()
    }

    @discardableResult
    func refreshISHPluginMarketplace(forceRefresh: Bool = false) async -> Bool {
        let retry = ISHPluginMarketplaceRetry.refreshCatalog(forceRefresh: forceRefresh)
        guard beginISHPluginMarketplaceOperation(.preparingHost, retry: retry) else { return false }
        defer { finishISHPluginMarketplaceOperation() }
        guard await startISHPluginHost(reportErrorsGlobally: false),
              let client = ishPluginHostClient else { return false }

        advanceISHPluginMarketplaceOperation(to: .loadingCatalog)
        do {
            let result: (ISHMarketplaceCatalog, ISHMarketplacePluginList)
            do {
                result = try await loadISHPluginMarketplace(
                    client: client,
                    forceRefresh: forceRefresh
                )
            } catch {
                guard ISHPluginMarketplaceErrorPolicy.shouldRefreshGuestDNSAndRetry(error) else {
                    throw error
                }
                await ISHSandboxCoordinator.shared.refreshGuestDNS()
                result = try await loadISHPluginMarketplace(
                    client: client,
                    forceRefresh: true
                )
            }
            ishPluginMarketplaceCatalog = mergedMarketplaceCatalog(result.0)
            ishMarketplacePlugins = mergedMarketplacePlugins(hostPlugins: result.1.plugins)
            await syncPluginInstallCoordinatorInventory(hostInventoryComplete: true)
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            return false
        }
        return true
    }

    @discardableResult
    func installISHMarketplacePlugin(
        source: ISHMarketplacePluginSource,
        replace: Bool = false,
        compilerGuidance: String? = nil,
        preference: ISHMarketplaceInstallPreference = .hostLoad
    ) async -> Bool {
        let request = PluginInstallRequest(
            source: .marketplace(source),
            scope: .global,
            replace: replace
        )
        do {
            _ = try await pluginInstallCoordinator.install(
                request,
                operation: { @MainActor [weak self] in
                    guard let self else {
                        throw PluginInstallCoordinatorError.operationFailed(
                            "AppModel 已结束。"
                        )
                    }
                    guard let plugin = await self.installISHMarketplacePluginResultUncoordinated(
                        source: source,
                        replace: replace,
                        compilerGuidance: compilerGuidance,
                        preference: preference
                    ) else {
                        throw PluginInstallCoordinatorError.operationFailed(
                            self.ishPluginMarketplaceFailure?.message
                                ?? "插件 Host 未返回已提交记录。"
                        )
                    }
                    return self.pluginInstallResult(for: plugin, scope: .global)
                }
            )
            return true
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            return false
        }
    }

    /// Keeps the page-facing Bool API while exposing the Host's committed
    /// record to conversation tooling that needs the resulting enabled state.
    private func installISHMarketplacePluginResultUncoordinated(
        source: ISHMarketplacePluginSource,
        replace: Bool = false,
        compilerGuidance: String? = nil,
        preference: ISHMarketplaceInstallPreference = .hostLoad
    ) async -> ISHMarketplacePlugin? {
        let retry = ISHPluginMarketplaceRetry.install(
            source: source,
            replace: replace,
            compilerGuidance: compilerGuidance
        )
        guard beginISHPluginMarketplaceOperation(.preparingHost, retry: retry) else { return nil }
        defer { finishISHPluginMarketplaceOperation() }
        beginNativePluginCompilationTrace(source: source)
        guard await startISHPluginHost(reportErrorsGlobally: false),
              let client = ishPluginHostClient else {
            failNativePluginCompilationTrace("iSH 插件 Host 未能启动，尚未下载源码。")
            return nil
        }

        advanceISHPluginMarketplaceOperation(to: .preparingNativePlugin)
        updateNativePluginCompilationStage(
            .sourceAcquisition,
            state: .running,
            detail: "正在手机内下载并准备受限源码快照。"
        )
        do {
            let prepared = try await withTemporaryISHGuestNetwork {
                try await client.prepareNativeMarketplacePlugin(source: source)
            }
            guard Self.isPreparedNativeSourceToken(prepared.preparedToken) else {
                throw ISHPluginHostError.invalidProtocol(
                    "The plugin host returned an invalid prepared native source token."
                )
            }
            updateNativePluginCompilationStage(
                .sourceAcquisition,
                state: .succeeded,
                detail: "源码已下载到手机隔离缓存，未发送 API 密钥。"
            )

            // Desktop parity (D-010): installs default to loading the package
            // into the local host runtime, matching the desktop. The native
            // manifest compile is an explicit opt-in preference only.
            if preference == .nativeCompile, let candidate = prepared.nativeCandidate {
                let sourceBytes = candidate.files.reduce(into: 0) {
                    $0 += $1.content.utf8.count
                }
                updateNativePluginCompilationStage(
                    .sourceAnalysis,
                    state: .succeeded,
                    detail: "已分析 \(candidate.files.count) 个源码文件（\(sourceBytes) 字节）。"
                )
                updateNativePluginCompilationStage(
                    .adaptability,
                    state: .running,
                    detail: "正在判断核心行为能否映射到手机原生工具。"
                )
                advanceISHPluginMarketplaceOperation(to: .compilingNativePlugin)
                do {
                    let plugin = try await compileAndInstallNativeAgentPlugin(
                        candidate,
                        replace: replace,
                        compilerGuidance: compilerGuidance
                    )
                    await discardPreparedNativeMarketplacePlugin(
                        client: client,
                        token: prepared.preparedToken
                    )
                    return plugin
                } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
                    await discardPreparedNativeMarketplacePlugin(
                        client: client,
                        token: prepared.preparedToken
                    )
                    return nil
                } catch {
                    guard let nativeError = error as? NativeAgentPluginError,
                          nativeError.shouldFallbackToISH else {
                        await discardPreparedNativeMarketplacePlugin(
                            client: client,
                            token: prepared.preparedToken
                        )
                        throw error
                    }
                    switch nativeError {
                    case .sourceNotAdaptable:
                        updateNativePluginCompilationStage(
                            .validation,
                            state: .skipped,
                            detail: "适配判断未通过，没有原生清单需要校验。"
                        )
                    case .invalidCompiledPlugin:
                        updateNativePluginCompilationStage(
                            .validation,
                            state: .failed,
                            detail: nativeError.localizedDescription
                        )
                    case .invalidSourceSnapshot, .compilerDidNotReturnManifest,
                         .alreadyInstalled, .notFound, .noExecutionResult:
                        break
                    }
                    updateNativePluginCompilationStage(
                        .nativeInstallation,
                        state: .skipped,
                        detail: "原生方案未注册，保留源码并切换到 iSH。"
                    )
                    updateNativePluginCompilationStage(
                        .ishFallback,
                        state: .running,
                        detail: error.localizedDescription
                    )
                }
            } else {
                updateNativePluginCompilationStage(
                    .sourceAnalysis,
                    state: .succeeded,
                    detail: "Host 已完成源码分析，但没有生成可交给 Agent 的受限快照。"
                )
                updateNativePluginCompilationStage(
                    .adaptability,
                    state: .skipped,
                    detail: "缺少可安全编译的源码入口，直接使用 iSH 兼容路径。"
                )
                updateNativePluginCompilationStage(
                    .modelCompilation,
                    state: .skipped,
                    detail: "未调用模型编译。"
                )
                updateNativePluginCompilationStage(
                    .validation,
                    state: .skipped,
                    detail: "没有原生清单需要校验。"
                )
                updateNativePluginCompilationStage(
                    .nativeInstallation,
                    state: .skipped,
                    detail: "没有注册原生工具。"
                )
                updateNativePluginCompilationStage(
                    .ishFallback,
                    state: .running,
                    detail: "正在手机 iSH 沙箱中安装原插件。"
                )
            }

            advanceISHPluginMarketplaceOperation(
                to: replace ? .updatingPlugin : .installingPlugin
            )
            let plugin = try await commitISHMarketplacePluginInstall(
                client: client,
                source: source,
                replace: replace,
                preparedToken: prepared.preparedToken
            )
            updateNativePluginCompilationStage(
                .ishFallback,
                state: .succeeded,
                detail: "iSH 插件已安装；可在启用后加载 Host 贡献。"
            )
            completeNativePluginCompilationTrace("已通过 iSH 兼容路径安装。")
            return plugin
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            failNativePluginCompilationTrace("操作已取消。")
            return nil
        } catch {
            failNativePluginCompilationTrace(error)
            reportISHPluginMarketplaceError(error)
            return nil
        }
    }

    func commitISHMarketplacePluginInstall(
        client: ISHPluginHostClient,
        source: ISHMarketplacePluginSource,
        replace: Bool,
        preparedToken: String
    ) async throws -> ISHMarketplacePlugin {
        // Treat the install RPC response as the commit point. Inventory
        // refresh and Cordis synchronization are follow-up work; a transient
        // failure there must not make the Agent retry a committed install.
        let response = try await withTemporaryISHGuestNetwork {
            try await client.installMarketplacePlugin(
                ISHMarketplacePluginInstallRequest(
                    source: source,
                    replace: replace,
                    preparedToken: preparedToken
                )
            )
        }
        upsertISHMarketplacePlugin(response.plugin)
        do {
            ishMarketplacePlugins = mergedMarketplacePlugins(
                hostPlugins: try await client.marketplacePlugins().plugins
            )
        } catch {
            reportISHPluginMarketplaceError(error)
        }
        if ishPluginMarketplaceCatalog != nil {
            do {
                ishPluginMarketplaceCatalog = mergedMarketplaceCatalog(
                    try await client.marketCatalog()
                )
            } catch {
                reportISHPluginMarketplaceError(error)
            }
        }
        do {
            try await synchronizeISHPluginHost(client: client)
        } catch {
            reportISHPluginMarketplaceError(error)
        }
        return response.plugin
    }

    func discardPreparedNativeMarketplacePlugin(
        client: ISHPluginHostClient,
        token: String
    ) async {
        do {
            _ = try await client.discardPreparedNativeMarketplacePlugin(token: token)
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return
        } catch {
            reportISHPluginMarketplaceError(error)
        }
    }

    static func isPreparedNativeSourceToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.allSatisfy(\.isHexDigit)
    }

    @discardableResult
    func importISHMarketplacePluginArchive(
        from externalURL: URL,
        replace: Bool = false
    ) async -> Bool {
        let guestPath: String
        do {
            guestPath = try await workspaceStore.stagePluginArchive(from: externalURL)
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            return false
        }
        let installed = await installISHMarketplacePlugin(
            source: ISHMarketplacePluginSource(kind: .localZip, location: guestPath),
            replace: replace
        )
        try? await workspaceStore.removeStagedPluginArchive(guestPath: guestPath)
        return installed
    }

    @discardableResult
    func setISHMarketplacePluginEnabled(id: String, enabled: Bool) async -> Bool {
        let retry = ISHPluginMarketplaceRetry.setEnabled(id: id, enabled: enabled)
        guard beginISHPluginMarketplaceOperation(.preparingHost, retry: retry) else { return false }
        defer { finishISHPluginMarketplaceOperation() }
        if id.hasPrefix(NativeAgentCompiledPlugin.idPrefix) {
            advanceISHPluginMarketplaceOperation(to: enabled ? .enablingPlugin : .disablingPlugin)
            do {
                try await setNativeAgentPluginEnabled(id: id, enabled: enabled)
                _ = try? await pluginInstallCoordinator.setEnabled(
                    pluginID: id,
                    scope: .global,
                    enabled: enabled
                )
                return true
            } catch {
                reportISHPluginMarketplaceError(error)
                return false
            }
        }
        guard await startISHPluginHost(reportErrorsGlobally: false),
              let client = ishPluginHostClient else { return false }

        advanceISHPluginMarketplaceOperation(to: enabled ? .enablingPlugin : .disablingPlugin)
        do {
            let response = try await client.setMarketplacePluginEnabled(
                ISHMarketplacePluginSetEnabledRequest(id: id, enabled: enabled)
            )
            upsertISHMarketplacePlugin(response.plugin)
            do {
                ishMarketplacePlugins = mergedMarketplacePlugins(
                    hostPlugins: try await client.marketplacePlugins().plugins
                )
            } catch {
                reportISHPluginMarketplaceError(error)
            }
            do {
                try await synchronizeISHPluginHost(client: client)
            } catch {
                reportISHPluginMarketplaceError(error)
            }
            _ = try? await pluginInstallCoordinator.setEnabled(
                pluginID: id,
                scope: .global,
                enabled: enabled
            )
            return true
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            await refreshISHMarketplacePlugins(client: client)
            return false
        }
    }

    @discardableResult
    func uninstallISHMarketplacePlugin(id: String) async -> Bool {
        let retry = ISHPluginMarketplaceRetry.uninstall(id: id)
        guard beginISHPluginMarketplaceOperation(.preparingHost, retry: retry) else { return false }
        defer { finishISHPluginMarketplaceOperation() }
        if id.hasPrefix(NativeAgentCompiledPlugin.idPrefix) {
            advanceISHPluginMarketplaceOperation(to: .uninstallingPlugin)
            do {
                try await uninstallNativeAgentPlugin(id: id)
                _ = try? await pluginInstallCoordinator.uninstall(
                    pluginID: id,
                    scope: .global
                )
                return true
            } catch {
                reportISHPluginMarketplaceError(error)
                return false
            }
        }
        guard await startISHPluginHost(reportErrorsGlobally: false),
              let client = ishPluginHostClient else { return false }

        advanceISHPluginMarketplaceOperation(to: .uninstallingPlugin)
        do {
            try await withTemporaryISHGuestNetwork {
                let response = try await client.uninstallMarketplacePlugin(id: id)
                guard response.ok else {
                    throw ISHPluginHostError.invalidState("社区插件未能卸载。")
                }
            }
            ishMarketplacePlugins.removeAll { $0.id == id }
            do {
                ishMarketplacePlugins = mergedMarketplacePlugins(
                    hostPlugins: try await client.marketplacePlugins().plugins
                )
            } catch {
                reportISHPluginMarketplaceError(error)
            }
            if ishPluginMarketplaceCatalog != nil {
                do {
                    ishPluginMarketplaceCatalog = mergedMarketplaceCatalog(
                        try await client.marketCatalog()
                    )
                } catch {
                    reportISHPluginMarketplaceError(error)
                }
            }
            do {
                try await synchronizeISHPluginHost(client: client)
            } catch {
                reportISHPluginMarketplaceError(error)
            }
            _ = try? await pluginInstallCoordinator.uninstall(
                pluginID: id,
                scope: .global
            )
            return true
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            return false
        }
    }

    @discardableResult
    func clearISHPluginMarketplaceCache(includeNpm: Bool = false) async -> Bool {
        let retry = ISHPluginMarketplaceRetry.clearCache(includeNpm: includeNpm)
        guard beginISHPluginMarketplaceOperation(.preparingHost, retry: retry) else { return false }
        defer { finishISHPluginMarketplaceOperation() }
        guard await startISHPluginHost(reportErrorsGlobally: false),
              let client = ishPluginHostClient else { return false }

        advanceISHPluginMarketplaceOperation(to: .clearingCache)
        do {
            _ = try await client.clearMarketplaceCache(includeNpm: includeNpm)
            ishPluginMarketplaceCatalog = nil
            return true
        } catch where ISHPluginMarketplaceErrorPolicy.isCancellation(error) {
            return false
        } catch {
            reportISHPluginMarketplaceError(error)
            return false
        }
    }

    func reportISHPluginMarketplaceError(_ error: Error) {
        guard let message = ISHPluginMarketplaceErrorPolicy.message(for: error) else { return }
        ishPluginMarketplaceFailure = ISHPluginMarketplaceFailure(
            message: message,
            retry: activeISHPluginMarketplaceRetry
        )
    }

    func clearISHPluginMarketplaceFailure() {
        ishPluginMarketplaceFailure = nil
    }

    func retryISHPluginMarketplaceOperation() async {
        guard !isISHPluginMarketplaceWorking,
              let retry = ishPluginMarketplaceFailure?.retry else { return }
        switch retry {
        case let .refreshCatalog(forceRefresh):
            await refreshISHPluginMarketplace(forceRefresh: forceRefresh)
        case let .install(source, replace, compilerGuidance):
            _ = await installISHMarketplacePlugin(
                source: source,
                replace: replace,
                compilerGuidance: compilerGuidance
            )
        case let .setEnabled(id, enabled):
            await setISHMarketplacePluginEnabled(id: id, enabled: enabled)
        case let .uninstall(id):
            await uninstallISHMarketplacePlugin(id: id)
        case let .clearCache(includeNpm):
            await clearISHPluginMarketplaceCache(includeNpm: includeNpm)
        }
    }

    func beginISHPluginMarketplaceOperation(
        _ operation: ISHPluginMarketplaceOperation,
        retry: ISHPluginMarketplaceRetry
    ) -> Bool {
        guard ishPluginMarketplaceOperation == nil else { return false }
        ishPluginMarketplaceFailure = nil
        activeISHPluginMarketplaceRetry = retry
        ishPluginMarketplaceOperation = operation
        return true
    }

    func advanceISHPluginMarketplaceOperation(
        to operation: ISHPluginMarketplaceOperation
    ) {
        guard ishPluginMarketplaceOperation != nil else { return }
        ishPluginMarketplaceOperation = operation
    }

    func finishISHPluginMarketplaceOperation() {
        ishPluginMarketplaceOperation = nil
        activeISHPluginMarketplaceRetry = nil
    }

    func withTemporaryISHGuestNetwork<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let coordinator = ISHSandboxCoordinator.shared
        let lease = await coordinator.beginTemporaryGuestNetworkAccess()
        do {
            let result = try await operation()
            await coordinator.endTemporaryGuestNetworkAccess(lease)
            return result
        } catch {
            await coordinator.endTemporaryGuestNetworkAccess(lease)
            throw error
        }
    }

    private func loadISHPluginMarketplace(
        client: ISHPluginHostClient,
        forceRefresh: Bool
    ) async throws -> (ISHMarketplaceCatalog, ISHMarketplacePluginList) {
        try await withTemporaryISHGuestNetwork {
            await ISHSandboxCoordinator.shared.refreshGuestDNS()
            let catalog = try await client.marketCatalog(forceRefresh: forceRefresh)
            let installed = try await client.marketplacePlugins()
            return (catalog, installed)
        }
    }

    func setPluginEnabled(_ enabled: Bool, id: CordisPluginID) async {
        do {
            _ = try await pluginRuntime.setEnabled(enabled, for: id)
            await refreshPluginInventory()
        } catch {
            presentError(error)
        }
    }

    func restartPlugin(id: CordisPluginID) async {
        do {
            _ = try await pluginRuntime.restart(id)
            await refreshPluginInventory()
        } catch {
            presentError(error)
        }
    }

    func installExperimentalPromptPlugin(id rawID: String, instruction: String) async -> Bool {
        let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              !normalizedInstruction.isEmpty,
              normalizedInstruction.utf8.count <= 16 * 1_024 else {
            errorMessage = "实验插件需要有效名称，Prompt 内容不能超过 16 KiB。"
            return false
        }
        let pluginID = CordisPluginID(rawValue: "memory.\(normalizedID)")
        let definition = CordisPluginDefinition(
            id: pluginID,
            version: "memory-1",
            dependencies: [CordisAgentServiceKeys.systemPrompt.name]
        ) { context in
            try await context.promptSection(
                CordisPromptSection(
                    name: "experimental:\(normalizedID)",
                    order: 100,
                    text: normalizedInstruction
                )
            )
        }
        do {
            _ = try await pluginRuntime.install(definition)
            await refreshPluginInventory()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func uninstallPlugin(id: CordisPluginID) async {
        guard id.rawValue.hasPrefix("memory.") || id.rawValue.hasPrefix("ish.") else {
            errorMessage = "内置插件可以停用或替换，但不能从运行时库存中删除。"
            return
        }
        do {
            _ = try await pluginRuntime.uninstall(id)
            await refreshPluginInventory()
        } catch {
            presentError(error)
        }
    }

    private func installCoreCordisPluginsIfNeeded() async throws {
        let installed = Set(await pluginRuntime.snapshots().map(\.id))
        if !installed.contains("core.agent-services") {
            _ = try await pluginRuntime.install(
                agentServices.pluginDefinition(baseSystemPrompt: MobileHarnessPrompt.text)
            )
        }
        if !installed.contains("core.workspace-fs") {
            _ = try await pluginRuntime.install(
                WorkspaceFileSystemCordisPlugin.definition(store: workspaceStore)
            )
        }
        if !installed.contains(DefaultMemoryCordisPlugin.pluginID) {
            _ = try await pluginRuntime.install(
                DefaultMemoryCordisPlugin.definition(store: memoryStore)
            )
        }
        if !installed.contains("core.fs-observation-policy") {
            _ = try await pluginRuntime.install(
                HarnessFsObservationPolicy().pluginDefinition()
            )
        }
        if !installed.contains("core.local-jobs") {
            _ = try await pluginRuntime.install(
                HarnessJobsCordisPlugin.definition(registry: jobRegistry)
            )
        }
        if !installed.contains("core.mobile-runtime-guidance") {
            _ = try await pluginRuntime.install(runtimeGuidancePluginDefinition())
        }
        if !installed.contains(RepeatToolReminder.pluginID) {
            _ = try await pluginRuntime.install(
                RepeatToolReminder.pluginDefinition()
            )
        }
        if !installed.contains(TimeoutPolicy.pluginID) {
            _ = try await pluginRuntime.install(
                TimeoutPolicy.pluginDefinition()
            )
        }
    }

    /// Settings/admin code owns the server list; agent turns only see tools
    /// already discovered from those configurations.
    func replaceMCPConfigurations(_ configurations: [MCPConfiguredServer]) async {
        do {
            try await mcpConfigurationStore.replace(configurations)
            try await installConfiguredMCPPlugins()
            await refreshPluginInventory()
        } catch {
            presentError(error)
        }
    }

    private func installConfiguredMCPPlugins() async throws {
        let configuredServers = (try await mcpConfigurationStore.load())
            .filter(\.isEnabled)
        let definitions = configuredServers.map {
            MCPServerCordisPlugin.definition(configuration: $0, registry: mcpRegistry)
        }
        let desiredIDs = Set(definitions.map(\.id))
        let installed = await pluginRuntime.snapshots()
        for snapshot in installed where snapshot.id.rawValue.hasPrefix("mcp.") && !desiredIDs.contains(snapshot.id) {
            _ = try await pluginRuntime.uninstall(snapshot.id)
        }
        let remaining = Set(await pluginRuntime.snapshots().map(\.id))
        for definition in definitions {
            if remaining.contains(definition.id) {
                _ = try await pluginRuntime.replace(definition.id, with: definition)
            } else {
                _ = try await pluginRuntime.install(definition)
            }
        }
    }

    private func runtimeGuidancePluginDefinition() -> CordisPluginDefinition {
        CordisPluginDefinition(
            id: "core.mobile-runtime-guidance",
            version: "1",
            dependencies: [CordisAgentServiceKeys.systemPrompt.name]
        ) { [weak self] context in
            try await context.promptSection(
                CordisPromptSection(
                    name: "harness:work-state-guidance",
                    order: -50,
                    text: "Maintain the on-device goal, plan, and todo state with the work_state tools for multi-step tasks. Keep one plan step active at a time and update status as work progresses."
                )
            )
            try await context.promptContext(
                CordisPromptContextContribution(
                    name: "harness:runtime-context",
                    order: 0,
                    text: { [weak self] _ in
                        guard let self else { return "" }
                        return await self.currentCordisRuntimeContext()
                    }
                )
            )
            try await context.promptContext(
                CordisPromptContextContribution(
                    name: "skill-catalog",
                    order: 10,
                    text: { [weak self] _ in
                        guard let self else { return "" }
                        return await self.skillRegistry.modelCatalogPrompt()
                    }
                )
            )
        }
    }

    private func activateMobileToolsPlugin(
        sessionID: String,
        userQuestionService: UserQuestionService
    ) async throws {
        let subagentRunner: LocalSubagentRunner = { [weak self] request, emit in
            guard let self else {
                throw LocalToolError.pluginDenied("手机子 Agent 宿主已退出。")
            }
            return try await self.executeLocalSubagent(
                request,
                parentSessionID: sessionID,
                userQuestionService: userQuestionService,
                onOutput: emit
            )
        }
        let definition = ProductionToolCatalog.pluginDefinition(
            workspaceStore: workspaceStore,
            workStateCoordinator: workStateCoordinator,
            sessionID: sessionID,
            userQuestionService: userQuestionService,
            planModeState: planModeState,
            pluginMarketplaceExecutor: { [weak self] request in
                guard let self else {
                    throw LocalToolError.pluginDenied("本机插件管理器已退出。")
                }
                return try await self.executePluginMarketplaceTool(request)
            },
            skillRegistry: skillRegistry,
            diagnosticsProvider: { [weak self] query in
                guard let self else {
                    return .object([
                        "available": .bool(false),
                        "message": .string("The mobile diagnostics owner has exited.")
                    ])
                }
                return await self.agentDiagnosticSnapshot(query)
            },
            scheduleStore: scheduleStore,
            subagentRunner: subagentRunner,
            workflowLifecycleSink: { [trajectoryRepository] event in
                guard let sessionUUID = UUID(uuidString: sessionID),
                      let draft = event.sessionEvent else { return }
                do {
                    _ = try await trajectoryRepository.append(
                        draft,
                        sessionID: sessionUUID
                    )
                    try await trajectoryRepository.flush(sessionID: sessionUUID)
                } catch {
                    // Workflow recording is observational. A failed append
                    // leaves a legal prefix and must not abort local children.
                }
            },
            trajectoryRepository: trajectoryRepository
        )
        let installed = await pluginRuntime.snapshots().contains { $0.id == definition.id }
        if installed {
            _ = try await pluginRuntime.replace(definition.id, with: definition)
        } else {
            _ = try await pluginRuntime.install(definition)
        }
        await refreshPluginInventory()
    }

    /// Deliver an RC.8 child report to the exact durable direct parent. A
    /// running parent receives a queued follow-up (never mid-turn steering);
    /// an idle active parent is woken immediately for `.wakeup`. Inactive
    /// parents retain the report in their local session and can consume it on
    /// their next activation, matching the phone's single-process boundary.
    private func deliverSubagentMessage(
        childAddress: String,
        parentSession: String,
        output: String,
        sourceKind: String,
        delivery: LocalSubagentReportDelivery
    ) async throws -> String {
        guard let parentID = UUID(uuidString: parentSession),
              UUID(uuidString: childAddress) != nil else {
            throw LocalToolError.invalidArguments
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalToolError.invalidArguments }
        let messageID = UUID()
        let framed = sourceKind == "subagent-report"
            ? "后台子 Agent \(childAddress) 报告：\n\(trimmed)"
            : "后台子 Agent \(childAddress) 已结束：\n\(trimmed)"

        if activeSessionID == parentID,
           let identity = selectedRunPresentation?.identity,
           isRunning {
            let queued = try await sessionRunRegistry.enqueue(
                text: framed,
                disposition: .queued,
                for: identity
            )
            publishInboxInserted(
                queued,
                source: sourceKind,
                boundary: .turnStopping,
                identity: identity
            )
            await persistSelectedRunInbox(identity: identity)
            await persistSession()
            return messageID.uuidString.lowercased()
        }

        let source = JSONValue.object([
            "kind": .string(sourceKind),
            "senderSessionId": .string(childAddress.lowercased()),
            "delivery": .string(delivery.rawValue),
            "messageId": .string(messageID.uuidString.lowercased())
        ])
        var parent = try await sessionStore.session(id: parentID)
        let message = AgentMessage(
            id: messageID,
            role: .user,
            content: framed,
            source: source
        )
        parent = try await sessionStore.checkpointSession(
            id: parentID,
            checkpoint: ConversationCheckpoint(
                messages: parent.messages + [message],
                workState: parent.workState,
                controlState: parent.controlState
            )
        )

        guard activeSessionID == parentID else {
            return messageID.uuidString.lowercased()
        }
        messages = parent.messages
        workState = parent.workState
        controlState = parent.controlState
        guard delivery == .wakeup, !isRunning else {
            return messageID.uuidString.lowercased()
        }
        await startRun(
            history: parent.messages,
            workState: parent.workState,
            shouldCheckpointBeforeRun: true,
            initialUserMessage: message
        )
        return messageID.uuidString.lowercased()
    }

    private func deliverPendingJobCompletions(for ownerSessionID: UUID) async {
        let owner = ownerSessionID.uuidString.lowercased()
        await JobToolSuite.deliverPendingCompletions(
            registry: jobRegistry,
            ownerSession: owner
        ) { [weak self] notice, delivery in
            guard notice.kind != "subagent" else { return }
            guard let self else {
                throw LocalToolError.pluginFailed("主 Agent 尚未恢复，后台任务结果稍后重试。")
            }
            try await self.deliverJobCompletionNotice(notice, delivery: delivery)
        }
    }

    private func deliverJobCompletionNotice(
        _ notice: HarnessJobCompletionNotice,
        delivery: LocalSubagentReportDelivery
    ) async throws {
        guard let parentID = UUID(uuidString: notice.ownerSession) else {
            throw LocalToolError.invalidArguments
        }
        let messageID = UUID()
        let content = "后台任务完成：\n\(notice.text)"
        let message = AgentMessage(
            id: messageID,
            role: .user,
            content: content,
            source: .object([
                "kind": .string("job-completion"),
                "jobId": .string(notice.id),
                "jobKind": .string(notice.kind),
                "delivery": .string(delivery.rawValue),
                "messageId": .string(messageID.uuidString.lowercased())
            ])
        )
        if activeSessionID == parentID,
           let identity = selectedRunPresentation?.identity,
           isRunning {
            let queued = try await sessionRunRegistry.enqueue(
                text: content,
                disposition: .queued,
                for: identity
            )
            publishInboxInserted(
                queued,
                source: "job-completion",
                boundary: .turnStopping,
                identity: identity
            )
            await persistSelectedRunInbox(identity: identity)
            await persistSession()
            return
        }
        var parent = try await sessionStore.session(id: parentID)
        let saved = try await sessionStore.checkpointSession(
            id: parentID,
            checkpoint: ConversationCheckpoint(
                messages: parent.messages + [message],
                workState: parent.workState,
                controlState: parent.controlState
            )
        )
        parent = saved
        guard activeSessionID == parentID else { return }
        messages = parent.messages
        workState = parent.workState
        controlState = parent.controlState
        guard delivery == .wakeup, !isRunning else { return }
        await startRun(
            history: parent.messages,
            workState: parent.workState,
            shouldCheckpointBeforeRun: true,
            initialUserMessage: message
        )
    }

    /// Run one bounded child Agent entirely on-device. The child deliberately
    /// uses a plain local registry instead of the parent Cordis runtime so it
    /// cannot recursively spawn children or mutate the parent's plugin graph.
    private func executeLocalSubagent(
        _ request: LocalSubagentRequest,
        parentSessionID: String,
        userQuestionService: UserQuestionService,
        onOutput: @escaping LocalSubagentOutputEmitter
    ) async throws -> String {
        guard let childID = UUID(uuidString: request.childAddress) else {
            throw LocalToolError.invalidArguments
        }
        let activationID = UUID()
        let childSessionID = childID.uuidString.lowercased()
        func stopHook(_ status: String) async {
            await runSubagentHookIgnoringFailure(
                point: .subagentStop,
                payload: .object([
                    "agentId": .string(childSessionID),
                    "runId": .string(activationID.uuidString.lowercased()),
                    "parentSession": .string(parentSessionID.lowercased()),
                    "childSession": .string(childSessionID),
                    "status": .string(status)
                ])
            )
        }
        try await runSubagentHook(
            point: .subagentStart,
            payload: .object([
                "agentId": .string(childSessionID),
                "runId": .string(activationID.uuidString.lowercased()),
                "parentSession": .string(parentSessionID.lowercased()),
                "childSession": .string(childSessionID),
                "label": .string(request.label),
                "model": request.model.map(JSONValue.string) ?? .null,
                "providerBundle": request.providerBundleID.map { .string($0.rawValue) } ?? .null,
                "continuation": .bool(request.isContinuation)
            ])
        )
        await traceStore.register(runID: activationID, sessionID: childID)
        var structuredOutputEventRecorded = false

        func recordStructuredOutput(
            status: String,
            output: String? = nil,
            errorCode: String? = nil
        ) async {
            guard request.outputSchema != nil else { return }
            let outputType: JSONValue
            if let output,
               let data = output.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                switch value {
                case .object: outputType = .string("object")
                case .array: outputType = .string("array")
                case .string: outputType = .string("string")
                case .number: outputType = .string("number")
                case .bool: outputType = .string("boolean")
                case .null: outputType = .string("null")
                }
            } else {
                outputType = .null
            }
            var data: [String: JSONValue] = [
                "status": .string(status),
                "schemaPresent": .bool(true),
                "outputType": outputType,
                "childSession": .string(childSessionID),
                "runId": .string(activationID.uuidString.lowercased())
            ]
            if let errorCode { data["errorCode"] = .string(errorCode) }
            _ = try? await trajectoryRepository.append(
                SessionEventDraft(
                    type: SessionEventVocabulary.subagentOutput,
                    data: .object(data)
                ),
                sessionID: childID
            )
            structuredOutputEventRecorded = true
        }

        func recordProviderBundleFailure(_ error: Error) async {
            guard let localError = error as? LocalToolError,
                  case let .providerBundleFailed(facts) = localError else { return }
            let state = facts.errorCategory == "cancelled" ? "cancelled" : "failed"
            _ = try? await trajectoryRepository.append(
                SessionEventDraft(
                    type: SessionEventVocabulary.subagentLifecycle,
                    data: .object([
                        "state": .string(state),
                        "runId": .string(activationID.uuidString.lowercased()),
                        "parentSession": .string(parentSessionID.lowercased()),
                        "childSession": .string(childSessionID),
                        "error": .string(facts.userMessage),
                        "failureFacts": facts.jsonValue
                    ])
                ),
                sessionID: childID
            )
            try? await trajectoryRepository.flush(sessionID: childID)
        }

        if let bundleID = request.providerBundleID {
            guard let bundle = providerBundle(bundleID), bundle.enabled else {
                await stopHook("failed")
                throw LocalToolError.pluginDenied("Profile Bundle " + bundleID.rawValue + " 尚未启用，请先在设置中安装。")
            }
            do {
                if let capabilityFailure = bundle.capabilityFailureMessage(
                    for: request.providerBundleRequestFeatures
                ) {
                    throw LocalToolError.pluginDenied(capabilityFailure)
                }
                let result = try await executeLocalProviderBundle(
                    bundle,
                    request: request,
                    onOutput: onOutput
                )
                do {
                    try LocalSubagentStructuredOutput.validate(
                        text: result,
                        schema: request.outputSchema
                    )
                    await recordStructuredOutput(status: "validated", output: result)
                } catch {
                    await recordStructuredOutput(
                        status: "invalid",
                        output: result,
                        errorCode: "structured_output_invalid"
                    )
                    throw error
                }
                return result
            } catch {
                if !structuredOutputEventRecorded {
                    await recordStructuredOutput(
                        status: "failed",
                        errorCode: "activation_failed"
                    )
                }
                await recordProviderBundleFailure(error)
                await stopHook(error is CancellationError ? "cancelled" : "failed")
                throw error
            }
        }
        if let acpProviderID = request.acpProviderID {
            guard request.providerBundleID == nil else {
                await stopHook("failed")
                throw LocalToolError.invalidArguments
            }
            guard let descriptor = await ACPSubagentProviderCatalog.shared.descriptor(id: acpProviderID) else {
                await stopHook("failed")
                throw LocalToolError.pluginDenied("ACP provider (acpProviderID) 尚未注册。")
            }
            do {
                let workspaceURL = try await workspaceStore.rootURL()
                let client = ACPSubagentProviderFactory.makeClient(
                    descriptor: descriptor,
                    workspaceURL: workspaceURL
                )
                let result = try await client.runAndWait(prompt: request.prompt)
                await onOutput(
                    AgentToolOutputChunk(channel: .progress, text: result)
                )
                await stopHook("completed")
                return result
            } catch is CancellationError {
                await stopHook("cancelled")
                throw CancellationError()
            } catch {
                await stopHook("failed")
                throw error
            }
        }
        var configuration = effectiveConfiguration
        if let model = request.model {
            if let profileID = configuration.profileID,
               let profile = providerDirectory.profile(id: profileID) {
                configuration = profile.configuration(
                    model: model,
                    reasoningMode: configuration.reasoningMode
                )
            } else {
                configuration.model = model
                configuration.inputModalities = nil
            }
        }
        if let reasoningEffort = request.reasoningEffort {
            configuration.reasoningMode = reasoningEffort
        }
        do {
            configuration = try configuration.validated()
        } catch {
            await stopHook("failed")
            throw error
        }
        guard let apiKey = try await apiKey(for: configuration) else {
            await stopHook("failed")
            throw CredentialStoreError.emptyCredential
        }

        let childSubagentRunner: LocalSubagentRunner = { [weak self] nestedRequest, nestedEmit in
            guard let self else {
                throw LocalToolError.pluginDenied("手机子 Agent 宿主已退出。")
            }
            return try await self.executeLocalSubagent(
                nestedRequest,
                parentSessionID: childSessionID,
                userQuestionService: userQuestionService,
                onOutput: nestedEmit
            )
        }
        let childComposition = LocalSubagentPolicy(
            contextMode: .fresh,
            persona: request.persona,
            toolFilter: request.toolFilter,
            outputSchema: nil,
            reportDelivery: request.reportDelivery,
            maximumDepth: request.maximumDepth
        )
        let childTools = ProductionToolCatalog.makeTools(
            workspaceStore: workspaceStore,
            workStateCoordinator: WorkStateCoordinator(),
            sessionID: childSessionID,
            userQuestionService: userQuestionService,
            planModeState: PlanModeStateStore(),
            pluginMarketplaceExecutor: nil,
            skillRegistry: skillRegistry,
            diagnosticsProvider: { [weak self] query in
                guard let self else {
                    return .object([
                        "available": .bool(false),
                        "scope": .string(query.scope.rawValue)
                    ])
                }
                return await self.agentDiagnosticSnapshot(query)
            },
            jobRegistry: jobRegistry,
            scheduleStore: scheduleStore,
            subagentRunner: childSubagentRunner,
            subagentPolicy: childComposition,
            terminalProvider: terminalProvider,
            trajectoryRepository: trajectoryRepository
        )

        let childReportTool = SubagentToolSuite.makeReportTool(
            childAddress: childSessionID,
            parentSession: parentSessionID,
            delivery: { [weak self] childAddress, parentSession, output, delivery in
                guard let self else {
                    throw LocalToolError.pluginDenied("父 Agent 宿主已退出，报告未送达。")
                }
                return try await self.deliverSubagentMessage(
                    childAddress: childAddress,
                    parentSession: parentSession,
                    output: output,
                    sourceKind: "subagent-report",
                    delivery: delivery
                )
            }
        )
        let childToolsWithReport = try request.scopedTools(
            from: childTools + [childReportTool]
        )

        let existingSession: ConversationSession
        do {
            existingSession = try await sessionStore.session(id: childID)
        } catch SessionStoreError.sessionNotFound {
            existingSession = try await sessionStore.createSession(
                id: childID,
                title: request.label,
                makeActive: false
            )
        }
        let userMessage = AgentMessage.user(request.prompt)
        let collector = DurableSubagentMessageCollector(
            messages: existingSession.messages + [userMessage]
        )
        let preparation = try await trajectoryRepository.prepare(sessionID: childID)
        let persistedChildHistory = SessionTrajectoryConversationProjection.reconcile(
            sessionMessages: existingSession.messages,
            events: preparation.snapshot.events
        )
        let childHistory: [AgentMessage]
        if request.contextMode == .forkCompletedParent, !request.isContinuation,
           let parentID = UUID(uuidString: parentSessionID) {
            let parentPreparation = try await trajectoryRepository.prepare(sessionID: parentID)
            let parentPrefix = SessionTrajectoryConversationProjection
                .messagesThroughLastCompletedTurn(from: parentPreparation.snapshot.events)
            childHistory = request.seedHistory(from: parentPrefix)
        } else {
            childHistory = persistedChildHistory
        }
        let alreadyDescribed = preparation.snapshot.events.contains {
            $0.type == SessionEventVocabulary.subagentDescriptor
        }
        if !alreadyDescribed {
            let descriptor = JSONValue.object([
                "version": .number(2),
                "mode": .string("continuable"),
                "provider": .string("mobile-local"),
                "label": .string(request.label),
                "parentSession": .string(parentSessionID.lowercased()),
                "agentProvider": .string(configuration.providerID.rawValue),
                "agentModel": .string(configuration.model),
                "delegationDepth": .number(Double(request.delegationDepth)),
                "maximumDepth": .number(Double(request.maximumDepth)),
                "reportDelivery": .string(request.reportDelivery.rawValue),
                "persona": request.persona.map(JSONValue.string) ?? .null,
                "toolFilter": request.toolFilter.map(Self.subagentToolFilterJSON) ?? .null
            ])
            _ = try await trajectoryRepository.append(
                SessionEventDraft(type: SessionEventVocabulary.subagentDescriptor, data: descriptor),
                sessionID: childID
            )
        }
        _ = try await trajectoryRepository.append(
            SessionEventDraft(
                type: SessionEventVocabulary.subagentLifecycle,
                data: .object([
                    "state": .string("running"),
                    "runId": .string(activationID.uuidString.lowercased()),
                    "parentSession": .string(parentSessionID.lowercased()),
                    "childSession": .string(childSessionID)
                ])
            ),
            sessionID: childID
        )
        let runtime = AgentRuntime(
            agentID: childID,
            runID: activationID,
            client: modelClient,
            registry: LocalToolRegistry(tools: childToolsWithReport),
            systemPrompt: """
            You are a local DeepSeek Harness child Agent running on the user's iPhone.
            Complete the standalone task below and return a concise, useful final answer.
            \(request.contextMode == .forkCompletedParent && !request.isContinuation
                ? "You received only the parent's balanced completed-turn prefix; do not assume unfinished tool calls exist."
                : "You do not see the parent conversation beyond this child session.")
            You may delegate to descendant subagents when useful. Every
            descendant activation is local and must stay within the durable
            maximum depth \(request.maximumDepth); do not attempt to bypass
            that limit.
            All tools execute on this phone: shell commands use embedded iSH, files use the
            shared workspace, and network access is limited to the configured model provider
            or explicit native web tools. Never claim server-side execution.
            \(request.persona.map { "Child persona:\n\($0)" } ?? "")
            \(request.outputSchema.map { "Your final answer must be valid JSON matching this schema:\n\($0.displayText)" } ?? "")
            Child address: \(childSessionID)
            """,
            approvalHandler: { [weak self] request in
                guard let self else { return false }
                return await self.requestNestedApproval(request)
            },
            eventHandler: { event in
                await collector.consume(event)
                switch event {
                case let .textDelta(delta):
                    await onOutput(
                        AgentToolOutputChunk(channel: .progress, text: delta)
                    )
                case let .reasoningDelta(delta):
                    await onOutput(
                        AgentToolOutputChunk(channel: .system, text: "[子 Agent 推理] \(String(delta.prefix(2_000)))\n")
                    )
                case let .toolStarted(call, summary):
                    await onOutput(
                        AgentToolOutputChunk(channel: .progress, text: "子 Agent 调用 \(call.name)：\(summary)\n")
                    )
                case let .toolOutput(_, chunk):
                    await onOutput(chunk)
                case let .toolFinished(call, _, isError):
                    await onOutput(
                        AgentToolOutputChunk(
                            channel: isError ? .stderr : .progress,
                            text: "子 Agent \(call.name)：\(isError ? "失败" : "完成")\n"
                        )
                    )
                case .stepStarted, .contextInjected, .toolEventChanged, .usage:
                    break
                case .messagesCommitted:
                    let messages = await collector.snapshot()
                    _ = try? await self.sessionStore.checkpointSession(
                        id: childID,
                        checkpoint: ConversationCheckpoint(messages: messages)
                    )
                }
            },
            providerRequestRouteProvider: { [weak self] configuration in
                guard let self else { throw ProviderProfileError.missingProfile("runtime") }
                return try await self.providerRequestRoute(for: configuration)
            },
            hookConfigurationProvider: { [weak self] in
                await self?.loadedHookConfiguration
            },
            toolResultOutputPolicy: ToolResultOutputPolicy(
                fileSystem: WorkspaceFileSystemProvider(store: workspaceStore)
            ),
            permissionMode: .dangerFullAccess,
            traceHandler: { [weak self] draft in
                var ownedDraft = draft
                ownedDraft.sessionID = ownedDraft.sessionID ?? childID
                await self?.traceStore.record(ownedDraft)
            },
            sessionEventHandler: { [trajectoryRepository] draft in
                try await trajectoryRepository.append(draft, sessionID: childID)
            },
            sessionEventSnapshotProvider: { [trajectoryRepository, childID] in
                try await trajectoryRepository.allEvents(sessionID: childID)
            },
            checkpointHandler: { [trajectoryRepository] in
                try await trajectoryRepository.flush(sessionID: childID)
            }
        )
        await onOutput(
            AgentToolOutputChunk(
                channel: .system,
                text: "已启动本机子 Agent \(childSessionID)（父地址 \(parentSessionID)，activation \(activationID.uuidString.lowercased())）。\n"
            )
        )
        do {
            try await runtime.run(
                history: childHistory,
                configuration: configuration,
                apiKey: apiKey,
                initialUserMessage: userMessage,
                requestHeaderReason: preparation.requestHeaderReason,
                contextWindow: contextWindow(for: configuration),
                startingTurn: preparation.nextTurn
            )
            let committedMessages = await collector.snapshot()
            _ = try await sessionStore.checkpointSession(
                id: childID,
                checkpoint: ConversationCheckpoint(messages: committedMessages)
            )
            guard let result = await collector.result(), !result.isEmpty else {
                throw LocalToolError.pluginFailed("子 Agent 未返回最终结果。")
            }
            do {
                try LocalSubagentStructuredOutput.validate(
                    text: result,
                    schema: request.outputSchema
                )
                await recordStructuredOutput(status: "validated", output: result)
            } catch {
                await recordStructuredOutput(
                    status: "invalid",
                    output: result,
                    errorCode: "structured_output_invalid"
                )
                throw error
            }
            // RC.8 sends an unconditional settlement notice in addition to
            // any explicit `report` calls. This keeps failures, cancellation,
            // and token exhaustion visible to the parent as well.
            _ = try? await deliverSubagentMessage(
                childAddress: childSessionID,
                parentSession: parentSessionID,
                output: result,
                sourceKind: "subagent-settled",
                delivery: request.reportDelivery
            )
            _ = try? await trajectoryRepository.append(
                SessionEventDraft(
                    type: SessionEventVocabulary.subagentLifecycle,
                    data: .object([
                        "state": .string("completed"),
                        "runId": .string(activationID.uuidString.lowercased()),
                        "parentSession": .string(parentSessionID.lowercased()),
                        "childSession": .string(childSessionID)
                    ])
                ),
                sessionID: childID
            )
            try? await trajectoryRepository.flush(sessionID: childID)
            await stopHook("completed")
            return result
        } catch {
            if request.outputSchema != nil && !structuredOutputEventRecorded {
                await recordStructuredOutput(
                    status: "failed",
                    errorCode: error is CancellationError ? "cancelled" : "activation_failed"
                )
            }
            _ = try? await deliverSubagentMessage(
                childAddress: childSessionID,
                parentSession: parentSessionID,
                output: "子 Agent 未能完成任务：\(error.localizedDescription)",
                sourceKind: "subagent-settled",
                delivery: request.reportDelivery
            )
            _ = try? await trajectoryRepository.append(
                SessionEventDraft(
                    type: SessionEventVocabulary.subagentLifecycle,
                    data: .object([
                        "state": .string(error is CancellationError ? "cancelled" : "failed"),
                        "runId": .string(activationID.uuidString.lowercased()),
                        "parentSession": .string(parentSessionID.lowercased()),
                        "childSession": .string(childSessionID),
                        "error": .string(error.localizedDescription)
                    ])
                ),
                sessionID: childID
            )
            try? await trajectoryRepository.flush(sessionID: childID)
            await stopHook(error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }

    private func runSubagentHook(
        point: HookPoint,
        payload: JSONValue
    ) async throws {
        guard let configuration = loadedHookConfiguration,
              let groups = configuration.groups[point],
              !groups.isEmpty else { return }
        let result = await HookRunner.run(
            point: point,
            toolName: nil,
            payload: payload,
            groups: groups,
            mode: configuration.mode,
            executor: configuration.executor
        )
        guard !result.blocked else {
            throw LocalToolError.pluginDenied(
                result.blockReason ?? "Subagent hook blocked"
            )
        }
    }

    private func runSubagentHookIgnoringFailure(
        point: HookPoint,
        payload: JSONValue
    ) async {
        do {
            try await runSubagentHook(point: point, payload: payload)
        } catch {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    sessionID: nil,
                    runID: UUID(),
                    name: "hook/\(point.rawValue)",
                    error: error.localizedDescription
                )
            )
        }
    }

    private static func subagentToolFilterJSON(_ filter: LocalSubagentToolFilter) -> JSONValue {
        .object([
            "allow": filter.allow.map { .array($0.map(JSONValue.string)) } ?? .null,
            "deny": filter.deny.map { .array($0.map(JSONValue.string)) } ?? .null
        ])
    }

    /// Execute an installed RC.8 coding-agent CLI inside the phone's iSH
    /// guest. The prompt is transported as base64 data to prevent shell
    /// interpolation; only the fixed catalog executable and arguments are
    /// allowed. Credentials remain owned by that local CLI installation.
    private func executeLocalProviderBundle(
        _ bundle: AgentProviderBundle,
        request: LocalSubagentRequest,
        onOutput: @escaping LocalSubagentOutputEmitter
    ) async throws -> String {
        do {
            try bundle.installPayload.validate()
        } catch {
            throw LocalToolError.providerBundleFailed(
                Self.providerBundleFailureFacts(
                    bundle: bundle,
                    request: request,
                    stage: "preflight",
                    category: "invalid-manifest",
                    detail: error.localizedDescription,
                    retryable: false
                )
            )
        }
        let workspaceURL = try await workspaceStore.rootURL()
        let mounts = try await workspaceStore.activeMountBindings()
        await ISHSandboxCoordinator.shared.setWorkspaceMounts(mounts)
        guard let promptData = request.prompt.data(using: .utf8) else {
            throw LocalToolError.invalidArguments
        }
        let encodedPrompt = promptData.base64EncodedString()
        let executable = Self.shellQuote(bundle.resolvedExecutablePath)
        let arguments = bundle.nonInteractiveArguments.map(Self.shellQuote).joined(separator: " ")
        let command = [
            "set -eu",
            "BUNDLE_EXECUTABLE=" + executable,
            "if [ ! -x \"$BUNDLE_EXECUTABLE\" ]; then",
            "  printf '%s\\n' 'Profile Bundle executable is not installed at its declared path' >&2",
            "  exit 127",
            "fi",
            "PROMPT=\"$(printf '%s' '" + encodedPrompt + "' | base64 -d)\"",
            "\"$BUNDLE_EXECUTABLE\" " + arguments + " \"$PROMPT\""
        ].joined(separator: "\n")
        let result: ISHCommandResult
        do {
            result = try await ISHSandboxCoordinator.shared.execute(
                sessionID: request.childAddress + ".bundle",
                command: command,
                workspaceURL: workspaceURL,
                timeout: 600,
                maximumOutputBytes: 112 * 1_024,
                policy: ISHSandboxExecutionPolicy(mode: .dangerFullAccess, workspaceRoot: workspaceURL),
                onOutput: { chunk in
                    // stderr is diagnostic-only for a degraded CLI adapter;
                    // never stream it into the parent Agent conversation.
                    guard chunk.channel == .stdout else { return }
                    await onOutput(AgentToolOutputChunk(
                        channel: .progress,
                        text: HarnessTraceRedactor.string(chunk.text, maximumUTF8Bytes: 8 * 1_024)
                    ))
                }
            )
        } catch {
            let category = Self.providerBundleFailureCategory(for: error)
            throw LocalToolError.providerBundleFailed(
                Self.providerBundleFailureFacts(
                    bundle: bundle,
                    request: request,
                    stage: Self.providerBundleFailureStage(for: error),
                    category: category,
                    detail: error.localizedDescription,
                    retryable: Self.providerBundleFailureIsRetryable(for: error)
                )
            )
        }
        guard result.exitCode == 0 else {
            throw LocalToolError.providerBundleFailed(
                Self.providerBundleFailureFacts(
                    bundle: bundle,
                    request: request,
                    stage: "process",
                    category: result.exitCode == 127 ? "not-installed" : "nonzero-exit",
                    exitCode: result.exitCode,
                    detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                    retryable: result.exitCode != 127
                )
            )
        }
        guard let parsed = AgentProviderBundleCompletionParser.parse(result.stdout) else {
            throw LocalToolError.providerBundleFailed(
                Self.providerBundleFailureFacts(
                    bundle: bundle,
                    request: request,
                    stage: "completion",
                    category: "empty-output",
                    exitCode: result.exitCode,
                    detail: result.stderr.isEmpty ? result.stdout : result.stderr,
                    retryable: false
                )
            )
        }
        return parsed.text
    }

    private static func providerBundleFailureFacts(
        bundle: AgentProviderBundle,
        request: LocalSubagentRequest,
        stage: String,
        category: String,
        exitCode: Int? = nil,
        detail: String? = nil,
        retryable: Bool
    ) -> AgentProviderBundleFailureFacts {
        AgentProviderBundleFailureFacts(
            provider: bundle.id.rawValue,
            stage: stage,
            exitCode: exitCode,
            outputAuthority: bundle.outputAuthority,
            errorCategory: category,
            executablePath: bundle.resolvedExecutablePath,
            detail: detail,
            retryable: retryable,
            instanceID: bundle.id.rawValue + ":" + request.childAddress
        )
    }

    private static func providerBundleFailureStage(for error: Error) -> String {
        guard let sandboxError = error as? ISHSandboxError else {
            return error is CancellationError ? "process" : "launch"
        }
        switch sandboxError {
        case .invalidCommand, .policyUnavailable:
            return "preflight"
        case .unavailable, .bootFailed, .workspaceMountFailed, .processCreationFailed, .execFailed:
            return "launch"
        case .timedOut, .cancelled, .sessionBusy, .capacityReached:
            return "process"
        }
    }

    private static func providerBundleFailureCategory(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let sandboxError = error as? ISHSandboxError else {
            return "execution-failed"
        }
        switch sandboxError {
        case .unavailable: return "sandbox-unavailable"
        case .bootFailed, .workspaceMountFailed, .processCreationFailed, .execFailed:
            return "sandbox-launch-failed"
        case .timedOut: return "timeout"
        case .cancelled: return "cancelled"
        case .sessionBusy, .capacityReached: return "resource-unavailable"
        case .invalidCommand: return "invalid-command"
        case .policyUnavailable: return "sandbox-policy"
        }
    }

    private static func providerBundleFailureIsRetryable(for error: Error) -> Bool {
        guard let sandboxError = error as? ISHSandboxError else { return false }
        switch sandboxError {
        case .timedOut, .sessionBusy, .capacityReached:
            return true
        case .unavailable, .bootFailed, .workspaceMountFailed, .processCreationFailed,
             .execFailed, .cancelled, .invalidCommand, .policyUnavailable:
            return false
        }
    }

    private static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Runs marketplace actions requested by the Agent through the same
    /// AppModel-owned lifecycle used by the marketplace screens. Keeping this
    /// adapter here means a conversation can install a plugin without creating
    /// a second downloader or a second Cordis runtime.
    private enum RunOutcome {
        case succeeded
        case failed
        case cancelled
        case interrupted

        var terminalOutcome: MobileAgentTerminalOutcome {
            switch self {
            case .succeeded: .succeeded
            case .failed: .failed
            case .cancelled: .cancelled
            case .interrupted: .interrupted
            }
        }
    }

    private enum ContinuedRunExecutionError: Error {
        case failed
    }

    private func performRun(
        registration: SessionRunRegistration,
        history: [AgentMessage],
        workState: ConversationWorkState,
        configuration: AgentConfiguration,
        executionSnapshot: RunExecutionSnapshot,
        continuedContext: ContinuedProcessingContext,
        initialUserMessage: AgentMessage?
    ) async -> RunOutcome {
        let identity = registration.identity
        let runID = identity.runID
        let state = registration.state
        let outcome: RunOutcome
        let sessionID = identity.sessionID
        do {
            await planModeState.setActive(executionSnapshot.interactionMode == .plan)
            guard let apiKey = try await self.apiKey(for: configuration) else {
                throw CredentialStoreError.emptyCredential
            }
            let workspaceURL = try await workspaceStore.rootURL()
            let trajectoryPreparation = try await trajectoryRepository.prepare(
                sessionID: sessionID
            )
            applyTrajectorySnapshot(
                trajectoryPreparation.snapshot,
                sessionID: sessionID,
                replacing: trajectorySessionID != sessionID
            )
            await prepareHarnessTrace(for: identity)

            // The append-only trajectory is the durable source of truth at a
            // crash boundary. SessionStore may lag the last committed tool
            // result (or contain a partial UI snapshot), so reconcile it
            // before compaction and before the next provider request.
            let durableHistory: [AgentMessage]
            if initialUserMessage != nil {
                // A new user message may intentionally start an edited/retry
                // branch. Replaying the old trajectory suffix here would
                // resurrect the abandoned assistant/tool branch; the runtime
                // records the new user boundary below.
                durableHistory = history
            } else {
                durableHistory = SessionTrajectoryConversationProjection.reconcile(
                    sessionMessages: history,
                    events: trajectoryPreparation.snapshot.events
                )
            }
            let projection = try ConversationCompactor.project(
                messages: durableHistory,
                workState: workState,
                maximumUTF8Bytes: executionSnapshot.contextLimitUTF8Bytes
            )
            omittedContextMessages = projection.omittedMessageCount
            let stateSummary = projection.stateSummary
            _ = await state.setPromptStateSummary(stateSummary, for: identity)
            if executionSnapshot.agentPreset?.id == "cordis" {
                // The creative preset needs the official Cordis lifecycle
                // tools mounted before the first model request. The Host is
                // still lazy and remains entirely inside this iSH guest.
                try await prepareCreativeMode()
            }
            try await activateMobileToolsPlugin(
                sessionID: sessionID.uuidString,
                userQuestionService: state.userQuestionService
            )
            let initialSystemPrompt = await Self.systemPrompt(
                stateSummary: stateSummary,
                interactionMode: executionSnapshot.interactionMode,
                permissionMode: executionSnapshot.permissionMode
            )
            let traceStore = self.traceStore
            let trajectoryRepository = self.trajectoryRepository
            let runtime = AgentRuntime(
                agentID: sessionID,
                runID: runID,
                client: modelClient,
                registry: LocalToolRegistry(tools: []),
                plugins: pluginRuntime,
                systemPrompt: initialSystemPrompt,
                approvalHandler: { [weak self] request in
                    guard let self else { return false }
                    return await self.requestApproval(
                        request,
                        identity: identity
                    )
                },
                eventHandler: { [weak self] event in
                    await self?.handle(
                        event,
                        identity: identity,
                        state: state,
                        continuedContext: continuedContext
                    )
                },
                queuedInputProvider: { boundary in
                    await state.nextQueuedInput(
                        at: boundary,
                        for: identity
                    )
                },
                queuedInputCommitter: { [weak self] messageID in
                    let claimed = await state.claimQueuedInput(
                        id: messageID,
                        for: identity
                    )
                    if claimed {
                        await self?.persistRunInbox(state: state, identity: identity)
                    }
                    return claimed
                },
                workspaceBoundary: workspaceURL.standardizedFileURL.path,
                systemPromptProvider: { [weak self] in
                    guard let self else { return initialSystemPrompt }
                    return await self.runSystemPrompt(
                        stateSummary: stateSummary,
                        interactionMode: executionSnapshot.interactionMode,
                        permissionMode: executionSnapshot.permissionMode
                    )
                },
                apiKeyProvider: { [weak self] configuration in
                    guard let self else { throw CredentialStoreError.emptyCredential }
                    guard let key = try await self.apiKey(for: configuration) else {
                        throw CredentialStoreError.emptyCredential
                    }
                    return key
                },
                providerRequestRouteProvider: { [weak self] configuration in
                    guard let self else { throw ProviderProfileError.missingProfile("runtime") }
                    return try await self.providerRequestRoute(for: configuration)
                },
                compactionConfigurationProvider: { [weak self] _ in
                    guard let self else { return nil }
                    return try await self.compactionSummaryConfiguration()
                },
                contextWindowProvider: { [weak self] configuration in
                    guard let self else { return nil }
                    return await self.contextWindow(for: configuration)
                },
                surfaceReplacementRangeProvider: { [trajectoryRepository, sessionID] count in
                    try await trajectoryRepository.replacementRangeForSurfacePrefix(
                        count: count,
                        sessionID: sessionID
                    )
                },
                userMessageInjectionProvider: { [weak self] message in
                    guard let self else { return [] }
                    return await self.skillInstructionInjections(
                        for: message,
                        sessionID: sessionID
                    )
                },
                preStepInstructionProvider: { [weak self] visibleMessages in
                    guard let self else { return [] }
                    guard let transition = await self.workspaceInstructionTransitions.prepareTransition(
                        sessionID: sessionID,
                        visibleMessages: visibleMessages,
                        durableMessages: durableHistory
                    ) else { return [] }
                    return [
                        AgentRuntimeInstructionInjection(
                            content: transition.content,
                            source: transition.source ?? .object([
                                "kind": .string(WorkspaceInstructionMessageSource.kind),
                                "form": .string("instructions"),
                                "changes": .array([])
                            ])
                        )
                    ]
                },
                timeContextInjectionProvider: { [weak self] visibleMessages, turn, step, now in
                    guard let self else { return nil }
                    let settings = await self.timeContextSettings
                    return try TimeContextOverlay.injection(
                        settings: settings,
                        messages: visibleMessages,
                        turn: turn,
                        step: step,
                        now: now
                    )
                },
                hookConfigurationProvider: { [weak self] in
                    await self?.loadedHookConfiguration
                },
                imageAttachmentProvider: { [workspaceStore] refs in
                    var payloads: [ModelImagePayload] = []
                    payloads.reserveCapacity(refs.count)
                    for ref in refs {
                        payloads.append(
                            ModelImagePayload(
                                id: ref.id,
                                mimeType: ref.mimeType,
                                data: try await workspaceStore.readAttachmentForModelRequest(ref)
                            )
                        )
                    }
                    return payloads
                },
                toolResultOutputPolicy: ToolResultOutputPolicy(
                    fileSystem: WorkspaceFileSystemProvider(store: workspaceStore)
                ),
                permissionMode: executionSnapshot.permissionMode,
                agentPreset: executionSnapshot.agentPreset,
                traceHandler: { [weak self, traceStore] draft in
                    // A run ID is not a sufficient ownership key when parent
                    // and child Agents execute concurrently. Stamp the
                    // durable session identity at the AppModel boundary so
                    // diagnostics and trajectory inspectors can reject
                    // cross-session rows instead of reading the global tail.
                    var ownedDraft = draft
                    ownedDraft.sessionID = ownedDraft.sessionID ?? sessionID
                    await traceStore.record(ownedDraft)
                    await self?.scheduleHarnessTraceRefresh(for: identity)
                },
            sessionEventHandler: { [weak self, trajectoryRepository] draft in
                let event = try await trajectoryRepository.append(
                    draft,
                    sessionID: sessionID
                )
                await self?.scheduleTrajectoryRefresh(for: sessionID)
                return event
            },
            sessionEventSnapshotProvider: { [trajectoryRepository, sessionID] in
                try await trajectoryRepository.allEvents(sessionID: sessionID)
            },
            checkpointHandler: { [trajectoryRepository] in
                try await trajectoryRepository.flush(sessionID: sessionID)
            },
            cancellationReasonProvider: {
                await state.terminalOutcomeProposal(for: identity) == .interrupted
                    ? .systemExpiration
                    : .user
            }
            )
            try await runtime.run(
                history: projection.messages,
                configuration: configuration,
                apiKey: apiKey,
                initialUserMessage: initialUserMessage,
                requestHeaderReason: trajectoryPreparation.requestHeaderReason,
                contextWindow: executionSnapshot.contextWindowTokens,
                startingTurn: trajectoryPreparation.nextTurn
            )
            outcome = .succeeded
        } catch is CancellationError {
            // Cancellation is a normal user action.
            outcome = await state.terminalOutcomeProposal(for: identity) == .interrupted
                ? .interrupted
                : .cancelled
        } catch {
            if selectedRunPresentation?.identity == identity {
                presentError(error)
            }
            outcome = .failed
        }
        switch outcome {
        case .succeeded:
            _ = await state.updateBackground(
                status: .completed(success: true),
                submission: nil,
                event: "completed",
                for: identity
            )
        case .failed:
            _ = await state.updateBackground(
                status: .completed(success: false),
                submission: nil,
                event: "failed",
                for: identity
            )
        case .cancelled:
            _ = await state.updateBackground(
                status: .interrupted,
                submission: nil,
                event: "cancelled",
                for: identity
            )
        case .interrupted:
            _ = await state.updateBackground(
                status: .interrupted,
                submission: nil,
                event: "system_expiration",
                for: identity
            )
        }
        return outcome
    }

    func regenerateConversationTitle(id: UUID) async {
        do {
            let session = try await sessionStore.session(id: id)
            let fallback = session.controlState.modelConfiguration
                ?? providerDirectory.activeProfile?.configuration()
                ?? AgentConfiguration()
            try await refreshConversationTitleIfNeeded(
                id: id,
                force: true,
                fallbackConfiguration: fallback
            )
        } catch {
            presentError(error)
        }
    }

    private func refreshConversationTitleIfNeeded(
        id sessionID: UUID,
        force: Bool,
        fallbackConfiguration: AgentConfiguration
    ) async throws {
        let session = try await sessionStore.session(id: sessionID)
        if !force {
            guard sessionTitleSettings.automaticMode != .disabled else { return }
            if session.titleSource == .user { return }
            if session.titleSource == nil {
                let legacyFallback = session.messages.first(where: {
                    $0.role == .user && !$0.isHiddenContextMessage
                }).map { String($0.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
                guard session.title == "新会话" || session.title == legacyFallback else { return }
            }
            if sessionTitleSettings.automaticMode == .firstPrompt,
               case .provider? = session.titleSource {
                return
            }
        }
        let mode: SessionTitleAutomaticMode = force ? .allPrompts : sessionTitleSettings.automaticMode
        let selected = try SessionTitleGenerator.selectedMessages(
            from: session.messages,
            mode: mode
        )
        let titleProviderID = SessionTitleGenerator.providerID(for: mode)
        let configuration = try sessionTitleSettings.configuration(
            inheriting: fallbackConfiguration,
            in: providerDirectory
        )
        guard let key = try await apiKey(for: configuration) else {
            throw CredentialStoreError.emptyCredential
        }
        let trajectoryEvents = try await trajectoryRepository.allEvents(sessionID: sessionID)
        let selectedMessageIDs = Set(selected.map { $0.id.uuidString.lowercased() })
        let messageSeqs = trajectoryEvents.compactMap { event -> UInt64? in
            guard event.type == SessionEventVocabulary.userMessage,
                  event.data.objectValue?["source"]?.objectValue?["kind"] == .string("user"),
                  let messageID = event.data.objectValue?["id"]?.stringValue?.lowercased(),
                  selectedMessageIDs.contains(messageID) else {
                return nil
            }
            return event.seq
        }
        _ = try await trajectoryRepository.append(
            SessionEventDraft(
                type: "session/title-llm-request",
                data: .object([
                    "titleProvider": .string(titleProviderID),
                    "messageSeqs": .array(messageSeqs.map { .number(Double($0)) }),
                    "route": .object([
                        "provider": .string(configuration.providerID.rawValue),
                        "model": .string(configuration.model)
                    ]),
                    "messages": .array(selected.map { message in
                        .object([
                            "id": .string(message.id.uuidString),
                            "text": .string(message.content)
                        ])
                    }),
                    "maxTokens": .number(Double(configuration.maxOutputTokens))
                ]),
                ignorable: true
            ),
            sessionID: sessionID
        )
        let title = try await SessionTitleGenerator.generate(
            client: modelClient,
            configuration: configuration,
            apiKey: key,
            messages: selected
        )
        _ = try await sessionStore.renameSession(
            id: sessionID,
            title: title,
            source: .provider(
                id: titleProviderID,
                provider: configuration.providerID.rawValue,
                model: configuration.model
            )
        )
        if !messageSeqs.isEmpty {
            _ = try await trajectoryRepository.append(
                SessionEventDraft(
                    type: "session/title",
                    data: .object([
                        "title": .string(title),
                        "messageSeqs": .array(messageSeqs.map { .number(Double($0)) }),
                        "source": .object([
                            "kind": .string("provider"),
                            "provider": .string(titleProviderID),
                            "model": .object([
                                "provider": .string(configuration.providerID.rawValue),
                                "model": .string(configuration.model)
                            ])
                        ])
                    ]),
                    ignorable: true
                ),
                sessionID: sessionID
            )
        }
        try await trajectoryRepository.flush(sessionID: sessionID)
        await refreshSessionSummaries()
        if activeSessionID == sessionID {
            await refreshTrajectory(for: sessionID)
        }
    }

    private func requestApproval(
        _ request: ToolApprovalRequest,
        identity: RunIdentity
    ) async -> Bool {
        if trustedToolApprovals.contains(where: { $0.allows(request) }) {
            return true
        }
        return (try? await sessionRunRegistry.requestApproval(request, for: identity)) ?? false
    }

    /// Child and compiled-plugin Agents share the parent's approval surface.
    /// Grants are still matched against the child request's exact model/tool/
    /// risk/resource scope, while cancelling the parent resolves every nested
    /// waiter fail-closed.
    func requestNestedApproval(_ request: ToolApprovalRequest) async -> Bool {
        guard let identity = selectedRunPresentation?.identity else { return false }
        return await requestApproval(request, identity: identity)
    }

    private func rememberToolApproval(_ request: ToolApprovalRequest) throws {
        guard !trustedToolApprovals.contains(where: { $0.allows(request) }) else {
            return
        }
        var updated = trustedToolApprovals
        updated.insert(ToolApprovalGrant(scope: request.scope), at: 0)
        try settingsStore.saveToolApprovalGrants(updated)
        trustedToolApprovals = updated
    }

    private func rememberDeviceToolApproval(for request: ToolApprovalRequest) throws {
        let scope = try ToolApprovalScope(
            toolName: ToolApprovalScope.allLocalToolsMarker,
            risk: .sideEffect,
            modelDestination: request.scope.modelDestination,
            resources: [ToolApprovalScope.allLocalToolsResource]
        )
        guard !trustedToolApprovals.contains(where: { $0.scope == scope }) else {
            return
        }
        var updated = trustedToolApprovals
        updated.insert(ToolApprovalGrant(scope: scope), at: 0)
        try settingsStore.saveToolApprovalGrants(updated)
        trustedToolApprovals = updated
    }

    private func publishInboxInserted(
        _ message: QueuedAgentInput,
        source: String,
        boundary: QueuedInputBoundary,
        identity: RunIdentity
    ) {
        Task {
            await pluginRuntime.emit(
                CordisAgentLoopEvents.agentInboxInserted,
                input: CordisAgentInboxInsertedContext(
                    agentID: identity.sessionID,
                    runID: identity.runID,
                    message: message,
                    source: source,
                    boundary: boundary
                ),
                target: .agent(identity.sessionID)
            )
        }
    }

    private func persistRunInbox(
        state: SessionRunState,
        identity: RunIdentity
    ) async {
        guard activeSessionID == identity.sessionID,
              selectedRunPresentation?.identity == identity else { return }
        let snapshot = await state.snapshot()
        guard snapshot.identity == identity else { return }
        controlState.replaceQueuedInputs(snapshot.queuedInputs)
    }

    private func persistSelectedRunInbox(identity: RunIdentity) async {
        guard activeSessionID == identity.sessionID,
              selectedRunPresentation?.identity == identity,
              let presentation = await sessionRunRegistry.presentation(for: identity) else {
            return
        }
        controlState.replaceQueuedInputs(presentation.queuedInputs)
    }

    private func projectRunPresentation(_ snapshot: SessionRunPresentation) async {
        if case .terminal = snapshot.phase {
            sessionRunSnapshots.removeValue(forKey: snapshot.identity.sessionID)
            refreshWidgetProjection()
            await refreshAppIntentRunningSessionProjection()
            guard activeSessionID == snapshot.identity.sessionID else { return }
            selectedRunPresentation = snapshot
            return
        }
        if let current = sessionRunSnapshots[snapshot.identity.sessionID],
           current.identity == snapshot.identity,
           current.presentation.revision >= snapshot.revision {
            return
        }
        if let current = selectedRunPresentation,
           current.identity == snapshot.identity,
           current.revision >= snapshot.revision {
            return
        }

        let registered = await sessionRunRegistry.snapshot(for: snapshot.identity)
        guard let registered else {
            return
        }
        sessionRunSnapshots[snapshot.identity.sessionID] = registered
        refreshWidgetProjection()
        await refreshAppIntentRunningSessionProjection()
        guard activeSessionID == snapshot.identity.sessionID else { return }
        selectedRunPresentation = snapshot
        controlState.replaceQueuedInputs(snapshot.queuedInputs)
        refreshBackgroundSystemProjection()
    }

    private func currentSystemPrompt(stateSummary: String?) async -> String {
        await commitPendingPlanExitIfNeeded()
        return await runSystemPrompt(
            stateSummary: stateSummary,
            interactionMode: controlState.interactionMode,
            permissionMode: controlState.permissionMode
        )
    }

    private func runSystemPrompt(
        stateSummary: String?,
        interactionMode: ConversationInteractionMode,
        permissionMode: ToolPermissionMode
    ) async -> String {
        let prompt = await Self.systemPrompt(
            stateSummary: stateSummary,
            interactionMode: interactionMode,
            permissionMode: permissionMode
        )
        let skills = await skillRegistry.modelCatalogPrompt()
        return [prompt, skills].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Mirrors the desktop `dsh-tool-skill` user gesture. Only a first-line
    /// `/skill-name` backed by a currently user-invocable workspace Skill adds
    /// instruction context; all other conversation text remains ordinary user
    /// content and cannot manufacture a privileged injection.
    private func skillInstructionInjections(
        for message: AgentMessage,
        sessionID: UUID? = nil
    ) async -> [AgentRuntimeInstructionInjection] {
        guard message.role == .user else { return [] }
        var result: [AgentRuntimeInstructionInjection] = []
        if let name = Self.userInvokedSkillName(in: message.content),
           let skill = await skillRegistry.userInvocableDefinition(named: name) {
            result.append(
                AgentRuntimeInstructionInjection(
                    content: MobileSkillRegistry.renderContent(skill),
                    source: .object([
                        "kind": .string("skill-invocation"),
                        "name": .string(skill.summary.name),
                        "form": .string("instructions")
                    ])
                )
            )
        }
        result.append(contentsOf: await referenceInjections(
            for: message.content,
            sessionID: sessionID ?? activeSessionID
        ))
        return result
    }

    /// Resolve official `dsh-session:` mentions at the request boundary.
    /// File mentions deliberately do not inject file contents: like desktop
    /// Harness, they remain paths that the Agent must inspect with file tools.
    private func referenceInjections(
        for text: String,
        sessionID: UUID? = nil
    ) async -> [AgentRuntimeInstructionInjection] {
        do {
            let parsed = try HarnessReferenceSyntax.parseSessionReferences(in: text)
            let references = try HarnessReferenceSyntax.normalizeSessionReferences(
                parsed.references,
                currentSessionID: sessionID
            )
            guard !references.isEmpty else { return [] }

            var prepared: [HarnessPreparedSessionReference] = []
            prepared.reserveCapacity(references.count)
            for reference in references {
                let session = try await sessionStore.session(id: reference.sessionID)
                prepared.append(
                    try HarnessSessionReferenceSnapshotBuilder.prepare(
                        session: session,
                        label: reference.label.isEmpty ? session.title : reference.label
                    )
                )
            }
            return [
                AgentRuntimeInstructionInjection(
                    content: HarnessSessionReferenceSnapshotBuilder.prompt(for: prepared),
                    source: HarnessSessionReferenceSnapshotBuilder.source(for: prepared),
                    normalizedUserContent: parsed.renderedText
                )
            ]
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private static func userInvokedSkillName(in text: String) -> String? {
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              firstLine.first == "/" else {
            return nil
        }
        let rawName = firstLine.dropFirst().prefix { !$0.isWhitespace }
        let name = String(rawName)
        return MobileSkillRegistry.isValidName(name) ? name : nil
    }

    private func currentCordisRuntimeContext() async -> String {
        await commitPendingPlanExitIfNeeded()
        let stateSummary: String?
        if let identity = selectedRunPresentation?.identity {
            stateSummary = try? await sessionRunRegistry.promptStateSummary(for: identity)
        } else {
            stateSummary = nil
        }
        return Self.runtimePromptContext(
            stateSummary: stateSummary,
            interactionMode: controlState.interactionMode,
            permissionMode: controlState.permissionMode
        )
    }

    private func commitPendingPlanExitIfNeeded() async {
        if await planModeState.commitPendingExit(),
           controlState.interactionMode == .plan {
            controlState.interactionMode = .agent
            await persistSession()
        }
    }

    private func applySlashCommandAction(
        _ action: SlashCommandAction?
    ) async throws -> String? {
        guard let action else { return nil }
        switch action {
        case let .help(query):
            return await slashCommandRegistry.helpText(
                query: query,
                scope: activeSessionID?.uuidString
            )
        case let .newSession(title):
            await createConversation(title: title ?? "新会话")
            return "已创建新会话。"
        case .clear:
            // Keep the log-only command lifecycle and audit trajectory while
            // clearing the model-visible conversation state.
            await resetConversation(preserveTrajectory: true)
            return "当前会话已清空，工作区文件保留。"
        case let .goal(message):
            let goalText = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let goalText, !goalText.isEmpty {
                workState = await workStateCoordinator.setGoal(
                    title: goalText,
                    status: .active
                )
                await persistSession()
            }
            if hasStagedImage {
                let prompt = goalText.map {
                    "请结合附图完善当前目标：\($0)"
                } ?? "请结合附图确定当前会话目标，并说明目标与依据。"
                guard await send(prompt, disposition: .queued) else {
                    throw AppCommandError.invalidState("附图目标请求未能加入 Agent 队列。")
                }
            }
            return goalText == nil && !hasStagedImage ? "当前目标：\(workState.goal?.title ?? "未设置")" : nil
        case let .goalCommand(operation, message):
            let action: ConversationGoalAction
            switch operation {
            case .edit:
                guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppCommandError.invalidState("编辑目标需要提供新的目标内容。")
                }
                action = .edit(title: message)
            case .pause:
                action = .pause
            case .resume:
                action = .resume
            case .complete:
                action = .complete
            case .block:
                action = .block
            case .clear:
                action = .clear
            }
            workState = try await workStateCoordinator.applyGoalAction(action)
            await persistSession()
            switch operation {
            case .edit: return "已编辑当前目标。"
            case .pause: return "当前目标已暂停。"
            case .resume: return "当前目标已恢复。"
            case .complete: return "当前目标已完成。"
            case .block: return "当前目标已标记为阻塞。"
            case .clear: return "当前目标已清空。"
            }
        case let .feedback(messageID, operation):
            guard let sessionID = activeSessionID else {
                throw AppCommandError.invalidState("当前没有可记录反馈的会话。")
            }
            let targetID = messageID
                ?? messages.reversed().first(where: { $0.role == .assistant })?.id
            guard let targetID,
                  let target = messages.first(where: { $0.id == targetID }),
                  target.role == .assistant else {
                throw AppCommandError.invalidState("当前会话没有可反馈的助手消息。")
            }
            let current = try await feedbackSidecarStore.record(
                sessionID: sessionID,
                messageID: targetID
            )
            switch operation {
            case .show:
                guard let current, let rating = current.rating else {
                    return "该消息暂无反馈。"
                }
                let label = rating == .positive ? "点赞" : "点踩"
                let note = current.note.map { "\n备注：\($0)" } ?? ""
                return "该消息反馈：\(label)（revision \(current.revision)）\(note)"
            case let .setRating(rating):
                let record = try await feedbackSidecarStore.setRating(
                    sessionID: sessionID,
                    messageID: targetID,
                    rating: rating,
                    expectedRevision: current?.revision
                )
                applyFeedbackSidecarRecord(record, messageID: targetID)
                await persistSession()
                return rating == .positive ? "已点赞该助手消息。" : "已点踩该助手消息。"
            case let .note(note):
                let record = try await feedbackSidecarStore.updateNote(
                    sessionID: sessionID,
                    messageID: targetID,
                    note: note.isEmpty ? nil : note,
                    expectedRevision: current?.revision
                )
                applyFeedbackSidecarRecord(record, messageID: targetID)
                await persistSession()
                return note.isEmpty ? "已清除反馈备注。" : "已保存反馈备注。"
            case .clear:
                let record = try await feedbackSidecarStore.clear(
                    sessionID: sessionID,
                    messageID: targetID,
                    expectedRevision: current?.revision
                )
                applyFeedbackSidecarRecord(record, messageID: targetID)
                await persistSession()
                return "已清除该消息的反馈。"
            }
        case let .plan(mode, message):
            setInteractionMode(mode == .on ? .plan : .agent)
            if let message, !message.isEmpty {
                _ = await send(message, disposition: .steer)
            } else if mode == .on, hasStagedImage {
                guard await send("请结合附图制定当前任务计划。", disposition: .steer) else {
                    throw AppCommandError.invalidState("附图计划请求未能加入 Agent 队列。")
                }
            }
            return nil
        case let .agent(preset):
            guard let preset else {
                isSessionAgentPresetPickerRequested = true
                return nil
            }
            let normalized = preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let aliases: [String: String] = [
                "default": AgentPresetRegistry.defaultID,
                "harness": AgentPresetRegistry.defaultID,
                "mobile": AgentPresetRegistry.defaultID,
                "create": "cordis",
                "creative": "cordis",
                "创造": "cordis",
                "创造模式": "cordis"
            ]
            let id = aliases[normalized] ?? normalized
            guard agentPresets.contains(where: { $0.id == id }) else {
                throw AppCommandError.unsupportedAgentPreset(preset)
            }
            let selected = try await selectAgentPreset(id: id)
            let modeName = selected.id == "cordis" ? "Cordis 创造模式" : "Agent"
            return "已选择 \(selected.displayName)（\(selected.id)）；下一轮将使用本机 \(modeName)。"
        case let .model(selection):
            guard let selection else {
                isSessionModelPickerRequested = true
                return nil
            }
            let selectedReasoning = selection.reasoning.flatMap(ReasoningMode.init(rawValue:))
            let selectedProfile: ProviderProfile?
            if let provider = selection.provider {
                guard let profile = providerProfile(named: provider) else {
                    throw AppCommandError.unknownProvider(provider)
                }
                selectedProfile = profile
            } else {
                selectedProfile = providerDirectory.profile(matching: effectiveConfiguration)
            }
            var draft = effectiveConfiguration
            if let selectedProfile {
                draft = selectedProfile.configuration(
                    model: selection.model,
                    reasoningMode: selectedReasoning
                )
            } else {
                draft.model = selection.model
                if let selectedReasoning {
                    draft.reasoningMode = selectedReasoning
                }
            }
            try await setSessionModelConfiguration(draft)
            try await recordModelSelection(draft, reasoning: selectedReasoning)
            let profile = providerDirectory.profile(matching: draft)
            let providerName = profile?.displayName
                ?? ModelProviderCatalog.descriptor(for: draft.providerID).displayName
            return "本会话模型：\(providerName) / \(draft.model)"
        case .compact:
            let compactLimit = 128 * 1_024
            let projection = try ConversationCompactor.project(
                messages: messages,
                workState: workState,
                maximumUTF8Bytes: compactLimit
            )
            controlState.contextLimitUTF8Bytes = compactLimit
            omittedContextMessages = projection.omittedMessageCount
            await persistSession()
            if projection.omittedMessageCount == 0 {
                return "当前上下文低于本机压缩阈值；已为后续请求启用 128 KiB 上限。"
            }
            return "后续请求将省略较早的 \(projection.omittedMessageCount) 条消息，并保留完整的最近工具事务。"
        case .status:
            return statusCommandText()
        }
    }

    private func presentCommandOutput(
        title: String,
        text: String,
        isError: Bool
    ) {
        directCommandOutput = DirectCommandOutput(
            title: title,
            text: text,
            isError: isError
        )
    }

    private func appendCommandRun(
        _ invocation: SlashCommandInvocation,
        sessionID: UUID,
        imageAttachments: [AgentImageAttachmentRef] = []
    ) async throws {
        _ = try await trajectoryRepository.append(
            .commandRun(
                commandID: invocation.commandID,
                name: invocation.parsed.name,
                args: invocation.recordInput ? invocation.parsed.rawInput : nil,
                imageAttachments: imageAttachments
            ),
            sessionID: sessionID
        )
        scheduleTrajectoryRefresh(for: sessionID)
    }

    /// Appends upstream v0.1.2's durable `model/selection` event so the
    /// trajectory explains which route later requests used. Only the route is
    /// recorded; credentials and request bodies stay out of the log.
    private func recordModelSelection(
        _ configuration: AgentConfiguration,
        reasoning: ReasoningMode?
    ) async throws {
        guard let sessionID = activeSessionID else { return }
        _ = try await trajectoryRepository.append(
            SessionEventDraft(
                type: SessionEventVocabulary.modelSelection,
                data: .object([
                    "provider": .string(configuration.providerID.rawValue),
                    "model": .string(configuration.model),
                    "reasoningEffort": reasoning.map { JSONValue.string($0.rawValue) } ?? .null
                ])
            ),
            sessionID: sessionID
        )
        scheduleTrajectoryRefresh(for: sessionID)
    }

    private func appendCommandDone(
        _ execution: SlashCommandExecution,
        text: String?,
        kind: SlashCommandResult.Kind,
        sessionID: UUID
    ) async throws {
        _ = try await trajectoryRepository.append(
            .commandDone(
                commandID: execution.commandID,
                kind: kind.rawValue,
                text: text,
                sourceEventSequence: kind == .success
                    ? execution.result.sourceEventSequence
                    : nil
            ),
            sessionID: sessionID
        )
        scheduleTrajectoryRefresh(for: sessionID)
    }

    private func statusCommandText() -> String {
        let profile = providerDirectory.profile(matching: effectiveConfiguration)
        let providerName = profile?.displayName
            ?? ModelProviderCatalog.descriptor(for: effectiveConfiguration.providerID).displayName
        let mode = interactionMode == .plan ? "Plan" : "Agent"
        let running = isRunning ? "运行中（步骤 \(currentStep)）" : "空闲"
        let queued = queuedInputs.isEmpty ? "无" : "\(queuedInputs.count) 条"
        let compact = controlState.contextLimitUTF8Bytes.map { "\($0 / 1_024) KiB" }
            ?? "自动 384 KiB"
        return """
        状态：\(running)
        模式：\(mode)
        权限：\(permissionMode.title)
        模型：\(providerName) / \(effectiveConfiguration.model)
        队列：\(queued)
        消息：\(messages.count) 条
        上下文：\(compact)
        """
    }

    private func providerProfile(named value: String) -> ProviderProfile? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = providerDirectory.profile(id: normalized) {
            return exact
        }
        if let displayMatch = providerDirectory.profiles.first(where: {
            $0.displayName.lowercased() == normalized
        }) {
            return displayMatch
        }
        let aliases: [String: ModelProviderID] = [
            "deepseek": .deepSeekOfficial,
            "deepseek-official": .deepSeekOfficial,
            "openai": .openAI,
            "openrouter": .openRouter,
            "anthropic": .anthropic,
            "claude": .anthropic,
            "custom": .customOpenAICompatible,
            "openai-compatible": .customOpenAICompatible
        ]
        guard let providerID = aliases[normalized] ?? ModelProviderID(rawValue: normalized) else {
            return nil
        }
        return providerDirectory.profiles.first { $0.providerID == providerID }
    }

    private func handle(
        _ event: AgentRuntimeEvent,
        identity: RunIdentity,
        state: SessionRunState,
        continuedContext: ContinuedProcessingContext
    ) async {
        guard await state.apply(event, for: identity) else { return }
        let runID = identity.runID
        let sessionID = identity.sessionID
        let snapshot = await state.snapshot()
        switch event {
        case let .stepStarted(step):
            if let status = try? ContinuedProcessingStatus(
                title: "Harness 正在执行",
                subtitle: "第 \(step) 步 · 持续执行",
                completedUnitCount: Int64(clamping: max(0, step - 1)),
                totalUnitCount: max(1, Int64(clamping: step))
            ) {
                await continuedContext.report(status)
#if os(iOS)
                await HarnessLiveActivityManager.shared.update(
                    runID: runID,
                    sessionID: sessionID,
                    sessionTitle: sessions.first(where: { $0.id == sessionID })?.title
                        ?? "Harness 任务",
                    phase: .working,
                    status: status,
                    privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled,
                    isEnabled: backgroundPreferences.isLiveActivityEnabled
                )
#endif
            }
        case .contextInjected, .textDelta, .reasoningDelta:
            break
        case let .messagesCommitted(committedMessages):
            if activeSessionID == sessionID {
                messages.append(contentsOf: committedMessages)
                workState = await workStateCoordinator.snapshot()
                await persistRunInbox(state: state, identity: identity)
                await persistSession()
            }
            if committedMessages.contains(where: { $0.role == .tool }) {
                await refreshWorkspace()
            }
        case .toolEventChanged, .toolOutput:
            break
        case let .toolStarted(call, summary):
#if os(iOS)
            if let status = try? ContinuedProcessingStatus(
                title: "Harness 正在执行",
                subtitle: "正在使用本机工具",
                completedUnitCount: Int64(clamping: max(0, snapshot.currentStep - 1)),
                totalUnitCount: max(1, Int64(clamping: snapshot.currentStep))
            ) {
                await HarnessLiveActivityManager.shared.update(
                    runID: runID,
                    sessionID: sessionID,
                    sessionTitle: sessions.first(where: { $0.id == sessionID })?.title
                        ?? "Harness 任务",
                    phase: .usingTool,
                    status: status,
                    toolName: call.name,
                    toolSummary: summary,
                    privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled,
                    isEnabled: backgroundPreferences.isLiveActivityEnabled
                )
            }
#endif
        case let .toolFinished(call, _, isError):
            if !isError,
               ["read", "write", "edit", "workspace_read_text", "workspace_write_text"]
                .contains(call.name),
               let path = Self.fileTouchPath(from: call.arguments) {
                let mutation: WorkspaceInstructionMutation = ["read", "workspace_read_text"]
                    .contains(call.name)
                    ? .observed
                    : .replaced
                await workspaceInstructionTransitions.noteTouchedPath(
                    sessionID: sessionID,
                    path: path,
                    mutation: mutation
                )
            }
#if os(iOS)
            if let status = try? ContinuedProcessingStatus(
                title: "Harness 正在执行",
                subtitle: "继续模型步骤",
                completedUnitCount: Int64(clamping: max(0, snapshot.currentStep - 1)),
                totalUnitCount: max(1, Int64(clamping: snapshot.currentStep))
            ) {
                await HarnessLiveActivityManager.shared.update(
                    runID: runID,
                    sessionID: sessionID,
                    sessionTitle: sessions.first(where: { $0.id == sessionID })?.title
                        ?? "Harness 任务",
                    phase: .working,
                    status: status,
                    privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled,
                    isEnabled: backgroundPreferences.isLiveActivityEnabled
                )
            }
#endif
        case .usage:
            break
        }
    }

    private static func fileTouchPath(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (object["file_path"] as? String) ?? (object["path"] as? String),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return path
    }


    private func persistSession() async {
        do {
            workState = await workStateCoordinator.snapshot()
            let session = try await sessionStore.checkpointActiveSession(
                ConversationCheckpoint(
                    messages: messages,
                    workState: workState,
                    controlState: controlState
                )
            )
            activeSessionID = session.id
            await refreshSessionSummaries()
        } catch {
            presentError(error)
        }
    }

    func refreshTrajectory() async {
        guard let activeSessionID else {
            resetTrajectoryProjection()
            return
        }
        await refreshTrajectory(for: activeSessionID)
        if let identity = selectedRunPresentation?.identity,
           identity.sessionID == activeSessionID {
            await refreshHarnessTrace(for: identity)
        }
    }

    var diagnosticHostStateDescription: String {
        switch ishPluginHostState {
        case .stopped:
            return "已停止"
        case .installing:
            return "正在安装"
        case .starting:
            return "正在启动"
        case let .running(hostVersion, processID):
            return "运行中 · v\(hostVersion) · pid \(processID.map(String.init) ?? "-")"
        case let .failed(message):
            return "失败 · \(message)"
        }
    }

    func refreshDiagnostics() async {
        await refreshTrajectory()
        if ishPluginHostClient != nil {
            await refreshISHPluginHost()
        }
    }

    func diagnosticReportData() async throws -> Data {
        let allTraceEvents: [HarnessTraceEvent]
        if let activeSessionID {
            allTraceEvents = await traceStore.events(sessionID: activeSessionID)
        } else {
            allTraceEvents = []
        }
        let processInfo = ProcessInfo.processInfo
        let device = UIDevice.current
        let configuration = effectiveConfiguration
        let metadata: [String: String] = [
            "generated_at": ISO8601DateFormatter().string(from: .now),
            "app_version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "app_build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "device_model": device.model,
            "device_name": device.name,
            "system": "\(device.systemName) \(device.systemVersion)",
            "thermal_state": Self.thermalStateDescription(processInfo.thermalState),
            "low_power_mode": String(processInfo.isLowPowerModeEnabled),
            "time_zone": TimeZone.current.identifier,
            "session_id": activeSessionID?.uuidString ?? "none",
            "session_title": activeSessionTitle,
            "provider": configuration.providerID.rawValue,
            "endpoint": configuration.baseURL,
            "model": configuration.model,
            "reasoning_mode": configuration.reasoningMode.rawValue,
            "agent_preset": activeAgentPreset.map { "\($0.id) / \($0.displayName)" }
                ?? controlState.agentPresetID,
            "interaction_mode": interactionMode.rawValue,
            "permission_mode": permissionMode.rawValue,
            "is_running": String(isRunning),
            "current_step": String(currentStep),
            "background_state": Self.backgroundStateDescription(backgroundRuntimeStatus),
            "background_last_event": lastBackgroundEvent,
            "continued_processing_submission": Self.continuedProcessingSubmissionDescription(
                continuedProcessingSubmission
            ),
            "message_count": String(messages.count),
            "active_tool_event_count": String(activeToolEvents.count),
            "trajectory_event_count": String(trajectoryEventCount),
            "harness_trace_event_count": String(allTraceEvents.count),
            "plugin_host": diagnosticHostStateDescription,
            "plugin_host_transport": ishPluginHostDiagnostics
                .map { Self.pluginHostTransportDescription($0.state) } ?? "none",
            "plugin_host_pending_requests": String(
                ishPluginHostDiagnostics?.pendingRequestCount ?? 0
            ),
            "plugin_host_outbound_queued_bytes": String(
                ishPluginHostDiagnostics?.outboundQueuedBytes ?? 0
            ),
            "plugin_host_write_in_flight": String(
                ishPluginHostDiagnostics?.outboundWriteInFlight ?? false
            ),
            "plugin_host_rejected_writes": String(
                ishPluginHostDiagnostics?.rejectedWriteCount ?? 0
            ),
            "plugin_host_last_transport_failure": ishPluginHostDiagnostics?.lastTransportFailure
                ?? "none",
            "plugin_marketplace_failure": ishPluginMarketplaceFailure?.message ?? "none",
            "last_presented_error": errorMessage ?? "none"
        ]
        let persistedSessionEvents: [SessionEvent]
        if let activeSessionID {
            persistedSessionEvents = try await trajectoryRepository.allEvents(
                sessionID: activeSessionID
            )
        } else {
            persistedSessionEvents = []
        }
        let runtimeTelemetryRecords = await runtimeTelemetryStore.snapshot()
        return try HarnessDiagnosticReportBuilder.build(
            HarnessDiagnosticReportInput(
                metadata: metadata,
                pluginHostStderr: ishPluginHostDiagnostics?.stderrTail ?? "",
                pluginSnapshots: pluginSnapshots,
                pluginHostInventory: ishPluginHostInventory,
                pluginPackageVersions: ishPluginHostPackages,
                toolContributionNames: pluginToolContributions.map {
                    "\($0.pluginID.rawValue):\($0.definition.name) [\($0.risk)]"
                },
                nativeClientFailures: ishNativeClientFailures.map {
                    "\($0.pluginID): \($0.message)"
                },
                runtimeTelemetryRecords: runtimeTelemetryRecords,
                traceEvents: allTraceEvents,
                sessionEvents: persistedSessionEvents
            )
        )
    }

    func diagnosticReportExport() async throws -> (data: Data, workspacePath: String?) {
        let data = try await diagnosticReportData()
        guard let activeSessionID else { return (data, nil) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "Harness-Diagnostics-\(formatter.string(from: .now)).log"
        let export = try await workspaceStore.writeDiagnosticExport(
            data,
            forSessionID: activeSessionID.uuidString,
            filename: filename
        )
        return (data, export.workspacePath)
    }

    func configureRuntimePerformanceSampling() async {
        await runtimeTelemetryStore.configurePerformanceSampling(
            enabled: backgroundPreferences.isPerformanceResourceSamplingEnabled
        )
        await runtimeTelemetryStore.recordPerformanceSample(
            RuntimeResourceGovernor.currentSignals(isBackgrounded: appIsBackgrounded)
        )
    }

    func agentDiagnosticSnapshot(
        _ query: AgentDiagnosticsQuery
    ) async -> JSONValue {
        let traceEvents: [HarnessTraceEvent]
        if let activeSessionID {
            traceEvents = await traceStore.events(sessionID: activeSessionID)
        } else {
            traceEvents = []
        }
        let pluginRuntimeSnapshots = await pluginRuntime.snapshots()
        let liveHostDiagnostics = if let client = ishPluginHostClient {
            await client.diagnostics()
        } else {
            ishPluginHostDiagnostics
        }
        let retainedSessionEvents = trajectoryEvents.filter { event in
            event.type != SessionEventVocabulary.assistantChunk
                || event.assistantChunkData?.usage != nil
        }
        let durableSessionEvents: [SessionEvent] = if let activeSessionID {
            (try? await trajectoryRepository.allEvents(sessionID: activeSessionID)) ?? trajectoryEvents
        } else {
            []
        }
        _ = await refreshRuntimeInvariantRegistry(
            traceEvents: traceEvents,
            sessionEvents: durableSessionEvents
        )
        let invariantSnapshot = await runtimeInvariantRegistry.snapshot()
        let errorTraceEvents = traceEvents.filter { event in
            event.error != nil
                || event.kind == .error
                || event.kind == .checkpointFailed
                || event.kind == .pluginCleanupFailed
        }
        let pluginErrors = pluginRuntimeSnapshots.compactMap { snapshot -> JSONValue? in
            guard let error = snapshot.error else { return nil }
            return .object([
                "source": .string("cordis_plugin"),
                "plugin": .string(snapshot.id.rawValue),
                "message": .string(error)
            ])
        }
        let nativeClientErrors = ishNativeClientFailures.map { failure in
            JSONValue.object([
                "source": .string("native_client_sync"),
                "plugin": .string(failure.pluginID),
                "message": .string(failure.message)
            ])
        }
        var recentErrors = pluginErrors + nativeClientErrors
        if let errorMessage, !errorMessage.isEmpty {
            recentErrors.append(.object([
                "source": .string("app"),
                "message": .string(errorMessage)
            ]))
        }
        if let failure = ishPluginMarketplaceFailure?.message, !failure.isEmpty {
            recentErrors.append(.object([
                "source": .string("plugin_marketplace"),
                "message": .string(failure)
            ]))
        }
        recentErrors.append(contentsOf: errorTraceEvents.suffix(query.limit).map {
            Self.redactedDiagnosticJSON($0)
        })
        recentErrors = Array(recentErrors.suffix(query.limit))

        var result: [String: JSONValue] = [
            "available": .bool(true),
            "generatedAt": .string(ISO8601DateFormatter().string(from: .now)),
            "scope": .string(query.scope.rawValue),
            "redaction": .string(
                "Credential-shaped strings and credential-keyed fields are removed before this result reaches the Agent."
            ),
            "summary": .object([
                "isRunning": .bool(isRunning),
                "currentStep": .number(Double(currentStep)),
                "sessionId": .string(activeSessionID?.uuidString ?? "none"),
                "background": .string(Self.backgroundStateDescription(backgroundRuntimeStatus)),
                "pluginHost": .string(diagnosticHostStateDescription),
                "pluginCount": .number(Double(pluginRuntimeSnapshots.count)),
                "pluginHostInventoryCount": .number(Double(ishPluginHostInventory.count)),
                "nativePluginCount": .number(Double(nativeAgentPlugins.count)),
                "traceEventCount": .number(Double(traceEvents.count)),
                "sessionEventCount": .number(Double(trajectoryEventCount)),
                "inMemorySessionEventCount": .number(Double(trajectoryEvents.count)),
                "recentErrorCount": .number(Double(recentErrors.count)),
                "runtimeInvariantViolationCount": .number(Double(invariantSnapshot.count))
            ])
        ]

        result["runtimeInvariants"] = .object([
            "healthy": .bool(invariantSnapshot.isEmpty),
            "checked": .array(RuntimeInvariantKind.allCases.map { .string($0.rawValue) }),
            "violations": .array(invariantSnapshot.map { Self.redactedDiagnosticJSON($0) })
        ])

        if query.scope == .errors || query.scope == .full {
            result["errors"] = .array(recentErrors.map {
                HarnessTraceRedactor.json($0, maximumDepth: 20)
            })
        }
        if query.scope == .pluginHost || query.scope == .errors || query.scope == .full {
            let stderr = liveHostDiagnostics?.stderrTail ?? ""
            result["pluginHost"] = .object([
                "state": .string(diagnosticHostStateDescription),
                "transport": .string(
                    liveHostDiagnostics.map {
                        Self.pluginHostTransportDescription($0.state)
                    } ?? "none"
                ),
                "pendingRequests": .number(Double(liveHostDiagnostics?.pendingRequestCount ?? 0)),
                "outboundQueuedBytes": .number(
                    Double(liveHostDiagnostics?.outboundQueuedBytes ?? 0)
                ),
                "outboundWriteInFlight": .bool(
                    liveHostDiagnostics?.outboundWriteInFlight ?? false
                ),
                "rejectedWrites": .number(Double(liveHostDiagnostics?.rejectedWriteCount ?? 0)),
                "lastTransportFailure": .string(
                    liveHostDiagnostics?.lastTransportFailure ?? "none"
                ),
                "stderrTail": .string(
                    HarnessTraceRedactor.string(
                        String(stderr.suffix(16 * 1_024)),
                        maximumUTF8Bytes: 16 * 1_024
                    )
                ),
                "inventory": Self.redactedDiagnosticJSON(
                    Array(ishPluginHostInventory.suffix(query.limit))
                ),
                "packageVersions": Self.redactedDiagnosticJSON(ishPluginHostPackages),
                "nativeClientSynchronizationFailures": .array(
                    nativeClientErrors.suffix(query.limit).map {
                        HarnessTraceRedactor.json($0, maximumDepth: 12)
                    }
                )
            ])
        }
        if query.scope == .compilation || query.scope == .errors || query.scope == .full {
            result["nativeCompilation"] = nativePluginCompilationTrace.map {
                Self.nativeCompilationDiagnosticJSON($0, limit: query.limit)
            } ?? .null
        }
        if query.scope == .trace || query.scope == .full {
            result["harnessTrace"] = .array(traceEvents.suffix(query.limit).map {
                Self.redactedDiagnosticJSON($0)
            })
        }
        if query.scope == .session || query.scope == .full {
            result["sessionEvents"] = .array(retainedSessionEvents.suffix(query.limit).map {
                Self.redactedDiagnosticJSON($0)
            })
            result["streamingSessionEventsOmitted"] = .number(
                Double(max(0, trajectoryEventCount - retainedSessionEvents.count))
            )
        }
        return Self.boundedDiagnosticSnapshot(
            HarnessTraceRedactor.json(.object(result), maximumDepth: 24)
        )
    }

    private func refreshRuntimeInvariantRegistry(
        traceEvents: [HarnessTraceEvent],
        sessionEvents: [SessionEvent]
    ) async -> [RuntimeInvariantViolationRecord] {
        var records = (await sessionRunRegistry.invariantViolations()).map(\.runtimeRecord)
        let aggregate = await sessionRunRegistry.aggregate()
        let registeredOwners = aggregate.runs.reduce(into: [SessionRunBackgroundLeaseToken: RunIdentity]()) {
            result, snapshot in
            for token in snapshot.backgroundLeaseTokens {
                result[token] = snapshot.identity
            }
        }
        for (token, owner) in legacyBackgroundTaskLease.ownershipSnapshot {
            guard let registeredOwner = registeredOwners[token], registeredOwner == owner else {
                records.append(RuntimeInvariantViolationRecord(
                    module: "legacy_background_task_lease",
                    kind: .leaseOwnerExists,
                    sessionID: owner.sessionID,
                    runID: owner.runID,
                    code: "orphan_owner"
                ))
                continue
            }
        }
        for (token, owner) in registeredOwners where legacyBackgroundTaskLease.ownershipSnapshot[token] == nil {
            records.append(RuntimeInvariantViolationRecord(
                module: "session_run_registry",
                kind: .leaseOwnerExists,
                sessionID: owner.sessionID,
                runID: owner.runID,
                code: "missing_background_owner"
            ))
        }

        if let event = traceEvents.last(where: { $0.name == "model-visible-invariant" }) {
            records.append(RuntimeInvariantViolationRecord(
                module: "agent_runtime",
                kind: .modelVisibleRecorded,
                sessionID: event.sessionID ?? activeSessionID,
                runID: event.runID,
                code: "audit_rejected_request"
            ))
        }

        let orderedEvents = sessionEvents.sorted { $0.seq < $1.seq }
        for (index, event) in orderedEvents.enumerated() {
            let expected = UInt64(index)
            guard event.seq == expected else {
                records.append(RuntimeInvariantViolationRecord(
                    module: "session_event_trajectory",
                    kind: .contiguousSequence,
                    sessionID: activeSessionID,
                    runID: nil,
                    code: "expected_\(expected)_found_\(event.seq)"
                ))
                break
            }
        }
        await runtimeInvariantRegistry.replace(records)
        return records
    }

    /// The model/tool bridge has a hard response-size limit. Trace rows can
    /// each contain prompts, tool arguments, and plugin stderr, so limiting
    /// only the row count is insufficient. Always return a valid, compact
    /// diagnostic object instead of allowing an oversized tool result to fail.
    private static func boundedDiagnosticSnapshot(
        _ value: JSONValue,
        maximumUTF8Bytes: Int = 96 * 1_024
    ) -> JSONValue {
        let redacted = HarnessTraceRedactor.json(value, maximumDepth: 20)
        if jsonByteCount(redacted) <= maximumUTF8Bytes {
            return redacted
        }

        let compact = compactDiagnosticJSON(redacted)
        if jsonByteCount(compact) <= maximumUTF8Bytes {
            return compact
        }

        let summary = redacted.objectValue?["summary"] ?? .null
        return .object([
            "available": .bool(true),
            "truncated": .bool(true),
            "summary": summary,
            "message": .string("诊断结果过大，已保留摘要；请缩小 limit 后按 errors、plugin_host、trace 分段读取。")
        ])
    }

    private static func compactDiagnosticJSON(
        _ value: JSONValue,
        depth: Int = 0
    ) -> JSONValue {
        guard depth < 10 else { return .string("<depth-limit>") }
        switch value {
        case let .string(text):
            return .string(HarnessTraceRedactor.string(text, maximumUTF8Bytes: 1_024))
        case let .array(values):
            let retained = Array(values.suffix(8)).map {
                compactDiagnosticJSON($0, depth: depth + 1)
            }
            guard values.count > retained.count else { return .array(retained) }
            return .array([
                .string("<\(values.count - retained.count) older items omitted>"),
            ] + retained)
        case let .object(object):
            let keys = object.keys.sorted()
            var compact: [String: JSONValue] = [:]
            for key in keys.prefix(32) {
                if let child = object[key] {
                    compact[key] = compactDiagnosticJSON(child, depth: depth + 1)
                }
            }
            if object.count > compact.count {
                compact["<truncated>"] = .number(Double(object.count - compact.count))
            }
            return .object(compact)
        case .number, .bool, .null:
            return value
        }
    }

    private static func jsonByteCount(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
    }

    private static func redactedDiagnosticJSON<T: Encodable>(_ value: T) -> JSONValue {
        do {
            let data = try JSONEncoder().encode(value)
            let json = try JSONDecoder().decode(JSONValue.self, from: data)
            return HarnessTraceRedactor.json(json, maximumDepth: 20)
        } catch {
            return .object([
                "encodingError": .string(
                    HarnessTraceRedactor.string(
                        error.localizedDescription,
                        maximumUTF8Bytes: 1_024
                    )
                )
            ])
        }
    }

    private static func nativeCompilationDiagnosticJSON(
        _ trace: NativePluginCompilationTrace,
        limit: Int
    ) -> JSONValue {
        .object([
            "id": .string(trace.id.uuidString),
            "source": .string(trace.source),
            "startedAt": .string(trace.startedAt.formatted(.iso8601)),
            "finishedAt": trace.finishedAt.map {
                .string($0.formatted(.iso8601))
            } ?? .null,
            "outcome": trace.outcome.map(JSONValue.string) ?? .null,
            "diagnostic": trace.diagnostic.map { diagnostic in
                .object([
                    "code": .string(diagnostic.code),
                    "stage": .string(diagnostic.stage),
                    "message": .string(diagnostic.message),
                    "retryable": .bool(diagnostic.retryable),
                    "prepared_token": diagnostic.preparedToken.map(JSONValue.string) ?? .null,
                    "suggested_action": .string(diagnostic.suggestedAction)
                ])
            } ?? .null,
            "steps": .array(trace.steps.map { step in
                .object([
                    "stage": .string(step.stage.rawValue),
                    "state": .string(step.state.rawValue),
                    "detail": .string(step.detail),
                    "updatedAt": .string(step.updatedAt.formatted(.iso8601))
                ])
            }),
            "logs": .array(trace.logs.suffix(limit).map { entry in
                .object([
                    "timestamp": .string(entry.timestamp.formatted(.iso8601)),
                    "stage": .string(entry.stage.rawValue),
                    "state": .string(entry.state.rawValue),
                    "message": .string(entry.message)
                ])
            })
        ])
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func backgroundStateDescription(_ state: BackgroundRuntimeStatus) -> String {
        switch state {
        case .idle:
            "idle"
        case let .running(status):
            "running: \(status.subtitle) [\(status.completedUnitCount)/\(status.totalUnitCount)]"
        case let .completed(success):
            success ? "completed" : "failed"
        case .interrupted:
            "interrupted"
        }
    }

    private static func continuedProcessingSubmissionDescription(
        _ submission: ContinuedProcessingSubmission?
    ) -> String {
        guard let submission else { return "not_requested" }
        return switch submission {
        case .submitted:
            "submitted"
        case .unavailable:
            "unavailable"
        case .registrationRejected:
            "registration_rejected"
        case let .failed(message):
            "failed: \(message)"
        }
    }

    private static func pluginHostTransportDescription(
        _ state: ISHPluginHostClient.State
    ) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case let .running(pid): "running(pid=\(pid))"
        case let .exited(code, errorCode): "exited(code=\(code), error=\(errorCode))"
        }
    }

    private func refreshTrajectory(for sessionID: UUID) async {
        let isNewSession = trajectorySessionID != sessionID
        let cursor = isNewSession ? nil : trajectoryCursor
        do {
            let snapshot = try await trajectoryRepository.snapshot(
                sessionID: sessionID,
                after: cursor
            )
            guard activeSessionID == sessionID else { return }
            applyTrajectorySnapshot(
                snapshot,
                sessionID: sessionID,
                replacing: isNewSession
            )
            if isNewSession {
                // The snapshot is intentionally bounded by the live store's
                // retention window. Fold the lossless stream once so the
                // outline remains stable while older pages are loaded.
                let allEvents = try await trajectoryRepository.allEvents(sessionID: sessionID)
                guard activeSessionID == sessionID else { return }
                trajectoryOutline = SessionTurnOutline.fold(allEvents)
            } else if !snapshot.events.isEmpty {
                for event in snapshot.events {
                    SessionTurnOutline.apply(event, to: &trajectoryOutline)
                }
            }
        } catch {
            guard activeSessionID == sessionID else { return }
            presentError(error)
        }
    }

    func loadOlderTrajectory() async {
        guard !isLoadingOlderTrajectory,
              let sessionID = activeSessionID,
              trajectorySessionID == sessionID else { return }
        let boundary = trajectoryLoadedFromSequence ?? UInt64(trajectoryEventCount)
        guard boundary > 0 else { return }

        isLoadingOlderTrajectory = true
        defer { isLoadingOlderTrajectory = false }
        do {
            let page = try await trajectoryRepository.page(
                sessionID: sessionID,
                before: boundary,
                limit: Self.trajectoryHistoryPageSize,
                matching: { $0.type != SessionEventVocabulary.assistantChunk }
            )
            guard activeSessionID == sessionID else { return }
            if let first = page.first {
                let existing = Set(trajectoryVisibleEvents.map(\.seq))
                trajectoryVisibleEvents = Array(
                    (page.filter { !existing.contains($0.seq) } + trajectoryVisibleEvents)
                        .suffix(Self.maximumPagedVisibleTrajectoryEvents)
                )
                trajectoryLoadedFromSequence = first.seq
            } else {
                trajectoryLoadedFromSequence = 0
            }
        } catch {
            guard activeSessionID == sessionID else { return }
            presentError(error)
        }
    }

    private func scheduleTrajectoryRefresh(for sessionID: UUID) {
        guard activeSessionID == sessionID, trajectoryRefreshTask == nil else { return }
        trajectoryRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.trajectoryRefreshTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await self.refreshTrajectory(for: sessionID)
        }
    }

    private func prepareHarnessTrace(for identity: RunIdentity) async {
        await traceStore.register(runID: identity.runID, sessionID: identity.sessionID)
        let existing = await traceStore.events()
        let startSequence = existing.last?.sequence ?? 0
        _ = try? await sessionRunRegistry.prepareTrace(
            startSequence: startSequence,
            for: identity
        )
        if selectedRunPresentation?.identity == identity {
            harnessTraceEvents = []
            harnessTraceSummary = nil
        }
    }

    private func refreshHarnessTrace(for identity: RunIdentity) async {
        guard let presentation = await sessionRunRegistry.presentation(for: identity),
              let key = presentation.traceKey,
              key.sessionID == identity.sessionID,
              key.runID == identity.runID else { return }
        let newEvents = await traceStore.events(
            after: key.cursor,
            sessionID: identity.sessionID,
            runID: identity.runID
        )
        guard !newEvents.isEmpty else { return }
        let cursor = newEvents.last?.sequence ?? key.cursor
        guard (try? await sessionRunRegistry.advanceTrace(to: cursor, for: identity)) == true,
              selectedRunPresentation?.identity == identity else { return }
        let knownSequences = Set(harnessTraceEvents.map(\.sequence))
        let events = newEvents.filter {
            $0.sequence > key.startSequence && !knownSequences.contains($0.sequence)
        }
        guard !events.isEmpty else { return }
        harnessTraceEvents.append(contentsOf: events)
        let summary = HarnessTraceStore.summarize(
            harnessTraceEvents.filter { $0.runID == identity.runID }
        )
        if harnessTraceSummary != summary {
            harnessTraceSummary = summary
        }
    }

    private func scheduleHarnessTraceRefresh(for identity: RunIdentity) async {
        _ = try? await sessionRunRegistry.startTraceRefresh(for: identity) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await self?.refreshHarnessTrace(for: identity)
            _ = try? await self?.sessionRunRegistry.clearTraceRefresh(for: identity)
        }
    }

    private func applyTrajectorySnapshot(
        _ snapshot: SessionTrajectorySnapshot,
        sessionID: UUID,
        replacing: Bool
    ) {
        trajectoryEventCount = Int(clamping: snapshot.cursor.nextSequence)
        if replacing || snapshot.fromSequence == 0 {
            trajectoryEvents = Array(
                snapshot.events.suffix(Self.maximumInMemoryTrajectoryEvents)
            )
            trajectoryVisibleEvents = Array(
                Self.trajectoryVisibleEvents(from: snapshot.events)
                    .suffix(Self.maximumInMemoryVisibleTrajectoryEvents)
            )
            trajectoryLoadedFromSequence = trajectoryVisibleEvents.first?.seq
                ?? snapshot.cursor.nextSequence
        } else if !snapshot.events.isEmpty {
            trajectoryEvents = Array(
                (trajectoryEvents + snapshot.events)
                    .suffix(Self.maximumInMemoryTrajectoryEvents)
            )
            trajectoryVisibleEvents = Array(
                (trajectoryVisibleEvents + Self.trajectoryVisibleEvents(from: snapshot.events))
                    .suffix(Self.maximumInMemoryVisibleTrajectoryEvents)
            )
        }
        if trajectoryMetrics != snapshot.metrics {
            trajectoryMetrics = snapshot.metrics
        }
        trajectoryRecoveredTornTail = snapshot.recoveredTornTail
        trajectorySessionID = sessionID
        trajectoryCursor = snapshot.cursor
    }

    private func resetTrajectoryProjection() {
        trajectoryRefreshTask?.cancel()
        trajectoryRefreshTask = nil
        trajectorySessionID = nil
        trajectoryCursor = nil
        trajectoryLoadedFromSequence = nil
        trajectoryEvents = []
        trajectoryEventCount = 0
        trajectoryMetrics = nil
        trajectoryRecoveredTornTail = false
        trajectoryOutline = .empty
        harnessTraceEvents = []
        harnessTraceSummary = nil
        trajectoryVisibleEvents = []
    }

    private var activeSessionTitle: String {
        sessions.first(where: { $0.id == activeSessionID })?.title ?? "Harness 任务"
    }

    private func beginQuestionMonitoring(
        identity: RunIdentity,
        state: SessionRunState
    ) async {
        let provider = state.userQuestionProvider
        _ = await state.startQuestionMonitor(for: identity) { [weak self, state] in
            var previousID: UUID?
            while !Task.isCancelled {
                let pending = await provider.pending()
                guard await state.setPendingQuestion(pending, for: identity) else { return }
                if let pending, pending.id != previousID {
                    await self?.recordQuestionLifecycle(
                        .questionRequested(
                            requestID: pending.id,
                            questions: pending.request.questions
                        ),
                        identity: identity
                    )
                }
                previousID = pending?.id
                do {
                    try await Task.sleep(for: .milliseconds(75))
                } catch {
                    return
                }
            }
        }
    }

    private func recordQuestionLifecycle(
        _ draft: SessionEventDraft,
        identity: RunIdentity
    ) async {
        do {
            _ = try await trajectoryRepository.append(draft, sessionID: identity.sessionID)
            scheduleTrajectoryRefresh(for: identity.sessionID)
        } catch {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    sessionID: identity.sessionID,
                    runID: identity.runID,
                    name: draft.type,
                    error: error.localizedDescription
                )
            )
        }
    }

    private func startRun(
        history: [AgentMessage],
        workState: ConversationWorkState,
        automaticTitle: String? = nil,
        shouldCheckpointBeforeRun: Bool = false,
        initialUserMessage: AgentMessage? = nil,
        useContinuedProcessing: Bool = true
    ) async {
        guard let sessionID = activeSessionID else { return }
        hasResumableRun = false
        let identity = await sessionRunRegistry.allocateIdentity(sessionID: sessionID)
        let questionContext = SessionRunQuestionContext()
        let runConfiguration = effectiveConfiguration
        let runExecutionSnapshot = RunExecutionSnapshot(
            controlState: controlState,
            agentPreset: activeAgentPreset?.runtimeProjection,
            contextWindowTokens: contextWindow(for: runConfiguration)
        )

        let finiteLeaseToken = acquireFiniteBackgroundLease(for: identity)
        finiteBackgroundLeaseTokens[identity] = finiteLeaseToken

        let registration: SessionRunRegistration
        do {
            registration = try await sessionRunRegistry.register(
                identity: identity,
                maximumLiveRoots: Self.maximumConcurrentRootRuns
            ) { [weak self] in
                SessionRunPreparedConfiguration(
                    trajectorySessionID: sessionID,
                    backgroundLeaseTokens: [finiteLeaseToken],
                    initialMessages: history,
                    initialQueuedInputs: runExecutionSnapshot.controlState.queuedInputs,
                    questionContext: questionContext,
                    presentationHandler: { [weak self] snapshot in
                        await self?.projectRunPresentation(snapshot)
                    },
                    cancellationHandler: { [weak self] in
                        await self?.cancelContinuedProcessing(identity: identity)
                    },
                    terminalCleanupHandler: { [weak self] identity, outcome, leaseTokens in
                        await self?.performTerminalCleanup(
                            identity: identity,
                            outcome: outcome,
                            backgroundLeaseTokens: leaseTokens
                        )
                    },
                    rollbackHandler: { [weak self] in
                        await self?.releaseFiniteBackgroundLease(
                            token: finiteLeaseToken,
                            for: identity
                        )
                    }
                )
            }
        } catch {
            releaseFiniteBackgroundLease(token: finiteLeaseToken, for: identity)
            presentError(error)
            return
        }

        guard await registration.handle.beginRunning(for: identity),
              await registration.state.markRunning(for: identity) else {
            _ = try? await sessionRunRegistry.finish(.failed, for: identity)
            return
        }
        _ = await sessionRunRegistry.setPresentationUpdatesEnabled(
            appIsActive,
            for: identity
        )
        await refreshSessionRunProjection()
        do {
            try await backgroundRunJournal.upsert(
                BackgroundRunJournalEntry(
                    identity: identity,
                    phase: .running,
                    finiteBackgroundLeaseActive: true,
                    audioKeepAliveActive: appIsBackgrounded,
                    locationKeepAliveActive: appIsBackgrounded
                )
            )
        } catch {
            await recordStartupIssue(error, source: "background_run_journal")
        }
        // A run can start while the scene is already backgrounded (for example
        // from a continued/scheduled handoff). Reconcile after publication so
        // the audio leg does not depend on another scene-phase transition.
        refreshBackgroundAudioKeepAlive()
        refreshBackgroundLocationKeepAlive()
        await beginQuestionMonitoring(identity: identity, state: registration.state)
        do {
            let started = try await sessionRunRegistry.startOwnedTask(for: identity) { [weak self] in
                await self?.executeRegisteredRun(
                    registration: registration,
                    history: history,
                    workState: workState,
                    configuration: runConfiguration,
                    executionSnapshot: runExecutionSnapshot,
                    automaticTitle: automaticTitle,
                    shouldCheckpointBeforeRun: shouldCheckpointBeforeRun,
                    initialUserMessage: initialUserMessage,
                    useContinuedProcessing: useContinuedProcessing
                )
            }
            guard started else {
                _ = try? await sessionRunRegistry.finish(.failed, for: identity)
                return
            }
        } catch {
            _ = try? await sessionRunRegistry.finish(.failed, for: identity)
            presentError(error)
        }
    }

    private func executeRegisteredRun(
        registration: SessionRunRegistration,
        history: [AgentMessage],
        workState: ConversationWorkState,
        configuration: AgentConfiguration,
        executionSnapshot: RunExecutionSnapshot,
        automaticTitle: String?,
        shouldCheckpointBeforeRun: Bool,
        initialUserMessage: AgentMessage?,
        useContinuedProcessing: Bool
    ) async {
        let identity = registration.identity
        let runID = identity.runID
        let state = registration.state

        if let automaticTitle {
            _ = try? await sessionStore.renameSession(
                id: identity.sessionID,
                title: automaticTitle,
                source: .fallback
            )
        }
        if shouldCheckpointBeforeRun,
           activeSessionID == identity.sessionID,
           selectedRunPresentation?.identity == identity {
            await persistSession()
        }
        guard await sessionRunRegistry.snapshot(for: identity) != nil else { return }

        guard let initialStatus = try? ContinuedProcessingStatus(
            title: "Harness 正在执行",
            subtitle: "准备模型与本机工具",
            completedUnitCount: 0,
            totalUnitCount: 1
        ) else {
            if selectedRunPresentation?.identity == identity {
                errorMessage = "无法创建后台任务进度。"
            }
            _ = try? await sessionRunRegistry.finish(.failed, for: identity)
            return
        }
        _ = await state.updateBackground(
            status: .running(initialStatus),
            submission: nil,
            event: backgroundPreferences.isEnhancedBackgroundEnabled
                ? "requesting_continued_processing"
                : "foreground_only",
            for: identity
        )
#if os(iOS)
        await HarnessLiveActivityManager.shared.start(
            runID: runID,
            sessionID: identity.sessionID,
            sessionTitle: sessions.first(where: { $0.id == identity.sessionID })?.title
                ?? "Harness 任务",
            status: initialStatus,
            privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled,
            isEnabled: backgroundPreferences.isLiveActivityEnabled
        )
#endif
        let runOperation: @MainActor (ContinuedProcessingContext) async -> RunOutcome = { context in
            let outcome = await self.performRun(
                registration: registration,
                history: history,
                workState: workState,
                configuration: configuration,
                executionSnapshot: executionSnapshot,
                continuedContext: context,
                initialUserMessage: initialUserMessage
            )
            _ = await state.proposeTerminalOutcome(outcome.terminalOutcome, for: identity)
            return outcome
        }

        guard useContinuedProcessing,
              backgroundPreferences.isEnhancedBackgroundEnabled else {
            let context = ContinuedProcessingContext(runID: runID) { _ in }
            _ = await runOperation(context)
            await settleRegisteredRun(
                identity: identity,
                state: state,
                titleConfiguration: configuration
            )
            return
        }
        do {
            let handle = try await continuedProcessingController.startUserInitiated(
                identity: identity,
                runID: runID,
                initialStatus: initialStatus,
                cancellationHandler: { [weak self] reason in
                    await self?.handleContinuedProcessingCancellation(
                        identity: identity,
                        state: state,
                        reason: reason
                    )
                },
                systemExpirationHandler: { [weak self] in
                    await self?.continueAfterContinuedProcessingExpiration(
                        identity: identity,
                        state: state
                    ) ?? false
                },
                systemTaskAttachedHandler: { [weak self] in
                    self?.releaseFiniteBackgroundLeaseForHandoff(identity: identity)
                },
                systemTaskDetachedHandler: { [weak self] in
                    self?.refreshBackgroundAudioKeepAlive()
                    self?.refreshBackgroundLocationKeepAlive()
                },
                operation: { context in
                    switch await runOperation(context) {
                    case .succeeded:
                        return
                    case .failed:
                        throw ContinuedRunExecutionError.failed
                    case .cancelled, .interrupted:
                        throw CancellationError()
                    }
                }
            )
            _ = await state.updateBackground(
                status: .running(initialStatus),
                submission: handle.submission,
                event: Self.continuedProcessingSubmissionDescription(handle.submission),
                for: identity
            )
            try? await backgroundRunJournal.upsert(
                BackgroundRunJournalEntry(
                    identity: identity,
                    phase: .running,
                    continuedProcessingRequestIdentifier: handle.requestIdentifier,
                    finiteBackgroundLeaseActive: true,
                    continuedProcessingActive: true,
                    audioKeepAliveActive: appIsBackgrounded,
                    locationKeepAliveActive: appIsBackgrounded,
                    liveActivityActive: backgroundPreferences.isLiveActivityEnabled
                )
            )
            let completion = await handle.completion.wait()
            switch completion {
            case let .operationFinished(cancellationReason):
                if let cancellationReason {
                    await handleContinuedProcessingCancellation(
                        identity: identity,
                        state: state,
                        reason: cancellationReason
                    )
                }
            case let .cancelledBeforeStart(reason):
                await handleContinuedProcessingCancellation(
                    identity: identity,
                    state: state,
                    reason: reason
                )
                if reason != .systemExpiration {
                    _ = await state.proposeTerminalOutcome(.cancelled, for: identity)
                }
            }
            await settleRegisteredRun(
                identity: identity,
                state: state,
                titleConfiguration: configuration
            )
        } catch {
            guard await sessionRunRegistry.snapshot(for: identity) != nil else { return }
            if selectedRunPresentation?.identity == identity {
                presentError(error)
            }
            _ = await state.proposeTerminalOutcome(.failed, for: identity)
            await settleRegisteredRun(
                identity: identity,
                state: state,
                titleConfiguration: configuration
            )
        }
    }

    private func settleRegisteredRun(
        identity: RunIdentity,
        state: SessionRunState,
        titleConfiguration: AgentConfiguration
    ) async {
        let proposed = await state.terminalOutcomeProposal(for: identity) ?? .failed
        let settled = (try? await sessionRunRegistry.finish(proposed, for: identity)) ?? proposed
        guard settled == .succeeded else { return }
        do {
            try await refreshConversationTitleIfNeeded(
                id: identity.sessionID,
                force: false,
                fallbackConfiguration: titleConfiguration
            )
        } catch {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    sessionID: identity.sessionID,
                    runID: identity.runID,
                    name: "session-title/generation-failed",
                    error: error.localizedDescription
                )
            )
        }
    }

    private func cancelContinuedProcessing(identity: RunIdentity) async {
        await continuedProcessingController.cancel(
            runID: identity.runID,
            identity: identity
        )
    }

    private func handleContinuedProcessingCancellation(
        identity: RunIdentity,
        state: SessionRunState,
        reason: ContinuedProcessingCancellationReason
    ) async {
        guard reason == .systemExpiration else { return }
        guard await state.proposeTerminalOutcome(.interrupted, for: identity) else { return }
        await runtimeTelemetryStore.recordBackgroundTimeout(
            identity: identity,
            source: .continuedProcessing
        )
        await backgroundResumeCoordinator.markSystemExpiration(identity)
        // A foreground transition is not guaranteed after iOS expires a
        // continued-processing task. Ask the already-registered processing
        // task for one best-effort local recovery opportunity; the scheduler
        // still decides whether and when this request runs.
#if os(iOS) && canImport(BackgroundTasks)
        requestBackgroundRecovery()
#endif
        let presentation = await state.snapshot()
        _ = await state.updateBackground(
            status: .interrupted,
            submission: presentation.continuedProcessingSubmission,
            event: "system_expiration",
            for: identity
        )
#if os(iOS)
        await traceStore.record(
            HarnessTraceDraft(
                kind: .backgroundTask,
                sessionID: identity.sessionID,
                runID: identity.runID,
                name: "system_expiration",
                attributes: [
                    "reason": .string("system_expiration"),
                    "submission": .string(
                        Self.continuedProcessingSubmissionDescription(
                            presentation.continuedProcessingSubmission
                        )
                    )
                ]
            )
        )
        await refreshHarnessTrace(for: identity)
#endif
    }

    /// Continued Processing is foreground-submitted and cannot be endlessly
    /// resubmitted from the background. If an actual audio/location background
    /// mode is healthy, transition the same run onto that mode plus a fresh
    /// finite UIKit lease instead of cancelling the Agent worker.
    private func continueAfterContinuedProcessingExpiration(
        identity: RunIdentity,
        state: SessionRunState
    ) async -> Bool {
        guard appIsBackgrounded,
              backgroundKeepAliveCoordinator.hasHealthyExtendedLease,
              let snapshot = await sessionRunRegistry.snapshot(for: identity),
              case let .running(status) = snapshot.presentation.backgroundRuntimeStatus,
              await ensureFiniteBackgroundLease(for: identity) else {
            return false
        }

        await runtimeTelemetryStore.recordBackgroundTimeout(
            identity: identity,
            source: .continuedProcessing
        )
        _ = await state.updateBackground(
            status: .running(status),
            submission: snapshot.presentation.continuedProcessingSubmission,
            event: "continued_processing_expired_extended_lease",
            for: identity
        )

        let layers = backgroundKeepAliveCoordinator.state.layers
        try? await backgroundRunJournal.upsert(
            BackgroundRunJournalEntry(
                identity: identity,
                phase: .running,
                continuedProcessingRequestIdentifier: nil,
                finiteBackgroundLeaseActive: legacyBackgroundTaskLease.hasSystemTask,
                continuedProcessingActive: false,
                audioKeepAliveActive: layers.contains(.extendedAudio),
                locationKeepAliveActive: layers.contains(.extendedLocation),
                liveActivityActive: backgroundPreferences.isLiveActivityEnabled
            )
        )
        await traceStore.record(
            HarnessTraceDraft(
                kind: .backgroundTask,
                sessionID: identity.sessionID,
                runID: identity.runID,
                name: "continued_processing/continued_with_extended_lease",
                attributes: [
                    "audio": .bool(layers.contains(.extendedAudio)),
                    "location": .bool(layers.contains(.extendedLocation)),
                    "finite_lease": .bool(legacyBackgroundTaskLease.hasSystemTask)
                ]
            )
        )
        return true
    }

    /// The registry's terminal owner invokes this exactly once after runtime
    /// exit and before removing the entry. Keep the ordering durable first,
    /// then release OS-facing resources, then publish optional completion UI.
    private func performTerminalCleanup(
        identity: RunIdentity,
        outcome: MobileAgentTerminalOutcome,
        backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken>
    ) async {
        do {
            try await trajectoryRepository.flush(sessionID: identity.sessionID)
        } catch {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .error,
                    sessionID: identity.sessionID,
                    runID: identity.runID,
                    name: "run/terminal-trajectory-flush-failed",
                    error: error.localizedDescription
                )
            )
        }

        do {
            let session = try await sessionStore.session(id: identity.sessionID)
            let committedMessages = await sessionRunRegistry.messages(for: identity)
                ?? session.messages
            var checkpointControlState = session.controlState
            if let presentation = await sessionRunRegistry.presentation(for: identity) {
                checkpointControlState.replaceQueuedInputs(presentation.queuedInputs)
            }
            let checkpoint = ConversationCheckpoint(
                messages: committedMessages,
                workState: session.workState,
                controlState: checkpointControlState
            )
            _ = try await sessionStore.checkpointSession(
                id: identity.sessionID,
                checkpoint: checkpoint
            )
            if activeSessionID == identity.sessionID {
                messages = committedMessages
                workState = session.workState
                controlState = checkpointControlState
                await refreshSessionSummaries()
            }
        } catch {
            presentError(error)
        }

        if let client = ishPluginHostClient {
            try? await synchronizeISHMobileContext(
                client: client,
                sessionID: identity.sessionID.uuidString,
                runID: identity.runID
            )
        }

        continuedProcessingController.finish(
            runID: identity.runID,
            identity: identity,
            success: outcome == .succeeded
        )
        continuedProcessingController.releaseCompletion(runID: identity.runID, identity: identity)
        if outcome == .succeeded {
            await driveNextGoalRound(sessionID: identity.sessionID)
        }
        do {
            let phase: BackgroundRunJournalPhase = switch outcome {
            case .succeeded: .succeeded
            case .cancelled: .cancelled
            case .failed: .failed
            case .interrupted: .interrupted
            case .disposed: .disposed
            }
            let lastDurableSequence: UInt64?
            if let snapshot = try? await trajectoryRepository.snapshot(
                sessionID: identity.sessionID
            ) {
                lastDurableSequence = snapshot.cursor.nextSequence == 0
                    ? 0
                    : snapshot.cursor.nextSequence - 1
            } else {
                lastDurableSequence = nil
            }
            try await backgroundRunJournal.markTerminal(
                identity: identity,
                phase: phase,
                lastDurableSequence: lastDurableSequence
            )
        } catch {
            await recordStartupIssue(error, source: "background_run_journal_terminal")
        }
#if os(iOS)
        let liveActivityPhase: HarnessLiveActivityPhase = switch outcome {
        case .succeeded: .completed
        case .failed: .failed
        case .cancelled, .interrupted, .disposed: .interrupted
        }
        await HarnessLiveActivityManager.shared.finish(
            runID: identity.runID,
            phase: liveActivityPhase,
            privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled
        )
#endif

        for token in backgroundLeaseTokens {
            releaseFiniteBackgroundLease(token: token, for: identity)
        }
        // Terminal ownership removed this run from the registry before invoking
        // cleanup. Re-evaluate against the remaining live roots so the last run
        // releases its audio keep-alive leg, while another session keeps it.
        refreshBackgroundAudioKeepAlive()
        refreshBackgroundLocationKeepAlive()
        if !backgroundLeaseTokens.isEmpty {
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .backgroundTask,
                    sessionID: identity.sessionID,
                    runID: identity.runID,
                    name: "run/terminal-background-leases-released",
                    attributes: [
                        "count": .number(Double(backgroundLeaseTokens.count))
                    ]
                )
            )
        }

        switch outcome {
        case .succeeded:
            await deliverCompletionNotification(
                runID: identity.runID,
                sessionID: identity.sessionID,
                succeeded: true
            )
        case .failed:
            await deliverCompletionNotification(
                runID: identity.runID,
                sessionID: identity.sessionID,
                succeeded: false
            )
        case .cancelled, .interrupted, .disposed:
            break
        }

        if activeSessionID == identity.sessionID,
           selectedRunPresentation?.identity == identity {
            hasResumableRun = Self.canResume(messages)
            await refreshTrajectory(for: identity.sessionID)
            await refreshHarnessTrace(for: identity)
        }
        if outcome == .interrupted {
            await scheduleSystemExpirationResume(for: identity.sessionID)
        }
    }

    private func auditBackgroundRunJournalOnLaunch() async {
        do {
            let audit = try await backgroundRunJournal.auditOnLaunch()
            for identity in audit.interruptedIdentities {
                await backgroundResumeCoordinator.markSystemExpiration(identity)
            }
            guard audit.didCleanOrphans else { return }
            for identifier in audit.clearedRequestIdentifiers {
                continuedProcessingController.cancelOrphanRequest(identifier: identifier)
            }
#if os(iOS)
            let activeRunIDs = Set((await sessionRunRegistry.aggregate()).runs.map { $0.identity.runID })
            await HarnessLiveActivityManager.shared.cleanupStaleActivities(activeRunIDs: activeRunIDs)
#endif
            refreshBackgroundAudioKeepAlive()
            refreshBackgroundLocationKeepAlive()
        } catch {
            await recordStartupIssue(error, source: "background_run_journal_launch_audit")
        }
    }

    private func auditBackgroundRunJournalOnForeground() async {
        do {
            let audit = try await backgroundRunJournal.auditOnForeground()
            for identity in audit.interruptedIdentities {
                await backgroundResumeCoordinator.markSystemExpiration(identity)
            }
            guard audit.didCleanOrphans else { return }
            for identifier in audit.clearedRequestIdentifiers {
                continuedProcessingController.cancelOrphanRequest(identifier: identifier)
            }
#if os(iOS)
            let activeRunIDs = Set((await sessionRunRegistry.aggregate()).runs.map { $0.identity.runID })
            await HarnessLiveActivityManager.shared.cleanupStaleActivities(activeRunIDs: activeRunIDs)
#endif
            refreshBackgroundAudioKeepAlive()
            refreshBackgroundLocationKeepAlive()
        } catch {
            await recordStartupIssue(error, source: "background_run_journal_foreground_audit")
        }
    }

    private func releaseFiniteBackgroundLeaseForHandoff(identity: RunIdentity) {
        guard let token = finiteBackgroundLeaseTokens[identity] else { return }
        finiteBackgroundLeaseTokens.removeValue(forKey: identity)
        legacyBackgroundTaskLease.release(token)
        Task { [sessionRunRegistry] in
            try? await sessionRunRegistry.removeBackgroundLease(token, from: identity)
        }
    }

    private func acquireFiniteBackgroundLease(
        for identity: RunIdentity
    ) -> SessionRunBackgroundLeaseToken {
        legacyBackgroundTaskLease.acquire(identity: identity) { [weak self] expiredIdentity in
            guard let self else { return false }
            let layers = self.backgroundKeepAliveCoordinator.state.layers
            let shouldContinue = self.appIsBackgrounded
                && self.backgroundKeepAliveCoordinator.hasHealthyExtendedLease
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runtimeTelemetryStore.recordBackgroundTimeout(
                    identity: expiredIdentity,
                    source: .finiteBackgroundLease
                )
                if shouldContinue {
                    await self.traceStore.record(
                        HarnessTraceDraft(
                            kind: .backgroundTask,
                            sessionID: expiredIdentity.sessionID,
                            runID: expiredIdentity.runID,
                            name: "finite_background_lease/rearmed",
                            attributes: [
                                "audio": .bool(layers.contains(.extendedAudio)),
                                "location": .bool(layers.contains(.extendedLocation))
                            ]
                        )
                    )
                    self.refreshBackgroundAudioKeepAlive()
                    self.refreshBackgroundLocationKeepAlive()
                } else {
                    _ = try? await self.sessionRunRegistry.interrupt(expiredIdentity)
                }
            }
            return shouldContinue
        }
    }

    private func ensureFiniteBackgroundLease(for identity: RunIdentity) async -> Bool {
        if finiteBackgroundLeaseTokens[identity] != nil {
            return true
        }
        guard await sessionRunRegistry.snapshot(for: identity) != nil else { return false }

        let token = acquireFiniteBackgroundLease(for: identity)
        finiteBackgroundLeaseTokens[identity] = token
        do {
            try await sessionRunRegistry.addBackgroundLease(token, to: identity)
            refreshBackgroundAudioKeepAlive()
            refreshBackgroundLocationKeepAlive()
            return true
        } catch {
            releaseFiniteBackgroundLease(token: token, for: identity)
            return false
        }
    }

    private func releaseFiniteBackgroundLease(
        token: SessionRunBackgroundLeaseToken,
        for identity: RunIdentity
    ) {
        if finiteBackgroundLeaseTokens[identity] == token {
            finiteBackgroundLeaseTokens.removeValue(forKey: identity)
        }
        legacyBackgroundTaskLease.release(token)
    }

    private func scheduleSystemExpirationResume(for sessionID: UUID) async {
        guard let identity = await backgroundResumeCoordinator.pendingIdentity(
            sessionID: sessionID
        ) else { return }
        _ = await backgroundResumeCoordinator.startMonitor(
            for: identity,
            readiness: { [weak self] in
                guard let self else { return false }
                guard await self.sessionRunRegistry.lookup(
                    sessionID: identity.sessionID
                ) == nil else {
                    return false
                }
                return await MainActor.run {
                    self.activeSessionID == identity.sessionID
                        && !self.isRunning
                        && self.hasResumableRun
                }
            },
            resume: { [weak self] in
                await self?.resumePendingRunNow()
            }
        )
    }

#if os(iOS) && canImport(BackgroundTasks)
    private func requestBackgroundRecovery() {
        guard scheduleBackgroundTasksRegistered else { return }
        do {
            // Recovery is a local wake-up opportunity. Requiring network here
            // can prevent iOS from launching the bounded handler at all while
            // connectivity is temporarily unavailable; the Agent's normal
            // provider retry path handles the network once it is back.
            try scheduleBackgroundController.submit(
                earliestBeginDate: Date(timeIntervalSinceNow: 1),
                requiresNetworkConnectivity: false
            )
            scheduleBackgroundEvent = "recovery_submitted"
        } catch {
            scheduleBackgroundEvent = "recovery_submit_failed"
            Task { [traceStore] in
                await traceStore.record(
                    HarnessTraceDraft(
                        kind: .backgroundTask,
                        name: "background_recovery_submit_failed",
                        error: error.localizedDescription
                    )
                )
            }
        }
    }
#endif

    private func deliverCompletionNotification(
        runID: UUID,
        sessionID: UUID,
        succeeded: Bool
    ) async {
        guard backgroundPreferences.areTaskNotificationsEnabled else { return }
        let taskTitle = sessions.first(where: { $0.id == sessionID })?.title
        try? await completionNotifier.deliverCompletion(
            runID: runID,
            succeeded: succeeded,
            taskTitle: taskTitle,
            privacyModeEnabled: backgroundPreferences.isPrivacyModeEnabled
        )
    }

#if os(iOS) && canImport(BackgroundTasks)
    private func registerScheduleBackgroundTasks() {
        registerBackgroundTasksIfNeeded()
    }

    /// Keep one system request pointed at the earliest pending schedule. A
    /// BGProcessingTask is a wake-up opportunity, not a wall-clock guarantee;
    /// claimDue remains the source of truth when iOS actually launches us.
    private func scheduleNextBackgroundTurn() async {
        guard scheduleBackgroundTasksRegistered else { return }
        guard isReady || !sessions.isEmpty else { return }
        guard let runAt = await scheduleStore.nextPendingRunAt() else {
            scheduleBackgroundController.cancel()
            return
        }
        let now = Date().timeIntervalSince1970
        let earliest = Date(timeIntervalSince1970: max(now + 1, Double(runAt) / 1_000))
        do {
            try scheduleBackgroundController.submit(earliestBeginDate: earliest)
            scheduleBackgroundEvent = "schedule_submitted"
        } catch {
            scheduleBackgroundEvent = "schedule_submit_failed"
            await traceStore.record(
                HarnessTraceDraft(
                    kind: .backgroundTask,
                    name: "schedule_submit_failed",
                    attributes: [
                        "earliest_run_at": .number(Double(runAt))
                    ],
                    error: error.localizedDescription
                )
            )
        }
    }

    private func handleScheduleBackgroundTask(_ task: BGProcessingTask) async {
        let claimOwner = "bg-\(UUID().uuidString.lowercased())"
        var didExpire = false
        task.expirationHandler = {
            Task { @MainActor in
                didExpire = true
                // Expiration must only release this task's schedule claim.
                // The claimed record is requeued below after the bounded run
                // quiesces; if iOS terminates us first, cold launch reclaim
                // handles the lease without touching another foreground run.
            }
        }

        var succeeded = true
        if await resumeInterruptedRunInBackgroundIfPossible() {
            if let identity = selectedRunPresentation?.identity {
                try? await sessionRunRegistry.awaitQuiescence(for: identity)
            }
            succeeded = !didExpire
        }

        let due = succeeded
            ? await scheduleStore.claimDue(now: nil, limit: 1, owner: claimOwner)
            : []
        for schedule in due {
            guard !Task.isCancelled else {
                try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "task cancelled")
                succeeded = false
                break
            }
            guard !didExpire else {
                try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "system expiration")
                succeeded = false
                break
            }
            guard let sessionID = UUID(uuidString: schedule.ownerSession) else {
                try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "invalid owner session")
                succeeded = false
                continue
            }
            do {
                let session = try await sessionStore.session(id: sessionID)
                guard !isRunning else {
                    try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "session already running")
                    succeeded = false
                    break
                }
                apply(session: session)
                await projectFeedbackSidecar()
                await workStateCoordinator.replace(with: workState)
                await refreshTrajectory()

                let message = AgentMessage(
                    role: .user,
                    content: schedule.prompt,
                    source: .object([
                        "kind": .string("user"),
                        "scheduleId": .string(schedule.id),
                        "scheduled": .bool(true)
                    ])
                )
                messages.append(message)
                await startRun(
                    history: messages,
                    workState: workState,
                    shouldCheckpointBeforeRun: true,
                    initialUserMessage: message,
                    useContinuedProcessing: false
                )
                if let identity = selectedRunPresentation?.identity {
                    try? await sessionRunRegistry.awaitQuiescence(for: identity)
                }
                if didExpire {
                    try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "system expiration")
                    succeeded = false
                } else if !isRunning && backgroundRuntimeStatus != .completed(success: false) {
                    try? await scheduleStore.acknowledge(id: schedule.id, owner: claimOwner)
                } else {
                    try? await scheduleStore.requeue(id: schedule.id, owner: claimOwner, reason: "run did not complete")
                    succeeded = false
                }
            } catch {
                try? await scheduleStore.requeue(
                    id: schedule.id,
                    owner: claimOwner,
                    reason: error.localizedDescription
                )
                succeeded = false
                presentError(error)
            }
        }

        await scheduleNextBackgroundTurn()
        task.setTaskCompleted(success: succeeded)
    }

    /// Continue one system-expired run inside the bounded BGProcessingTask
    /// window. The run identity is claimed before starting so a foreground
    /// monitor cannot launch a duplicate worker.
    private func resumeInterruptedRunInBackgroundIfPossible() async -> Bool {
        guard !isRunning,
              let activeSessionID,
              hasResumableRun,
              let identity = await backgroundResumeCoordinator.pendingIdentity(
                  sessionID: activeSessionID
              ),
              await backgroundResumeCoordinator.consumePending(identity) else {
            return false
        }
        // BGProcessingTask already is the bounded background execution window.
        // Do not submit another user-initiated continued-processing request
        // while resuming the checkpointed run.
        await resumePendingRunNow(useContinuedProcessing: false)
        return true
    }
#endif

    private func applySessionState(_ state: SessionStoreState) {
        sessions = state.sessions
            .map(\.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
        if let active = state.activeSession {
            apply(session: active)
        } else {
            activeSessionID = nil
            resetTrajectoryProjection()
            messages = []
            workState = ConversationWorkState()
            controlState = ConversationControlState()
            hasResumableRun = false
        }
        refreshLocalStateProjection()
    }

    private func apply(session: ConversationSession) {
        let didChangeSession = activeSessionID != session.id
        activeSessionID = session.id
        if didChangeSession {
            resetTrajectoryProjection()
        }
        messages = session.messages
        workState = session.workState
        controlState = session.controlState
        selectedRunPresentation = nil
        omittedContextMessages = 0
        hasResumableRun = Self.canResume(session.messages)
    }

    private func restoreRunPresentation(for sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        await refreshSessionRunProjection()
        selectedRunPresentation = sessionRunSnapshots[sessionID]?.presentation
        if let presentation = selectedRunPresentation {
            controlState.replaceQueuedInputs(presentation.queuedInputs)
        }
    }

    /// Rebuilds the transient session-list run projection from the registry.
    /// SessionStore remains the source for durable metadata; this map is only
    /// for live root phase, queue, and presentation status.
    private func refreshSessionRunProjection() async {
        let aggregate = await sessionRunRegistry.aggregate()
        sessionRunSnapshots = Dictionary(
            uniqueKeysWithValues: aggregate.runs.map { ($0.identity.sessionID, $0) }
        )
        refreshLocalStateProjection()
        refreshWidgetProjection()
        await refreshAppIntentRunningSessionProjection()
    }

    private func refreshAppIntentRunningSessionProjection() async {
        do {
            try await appIntentInboxStore.updateRunningSessions(Set(sessionRunSnapshots.keys))
        } catch {
            await recordStartupIssue(error, source: "app_intent_running_projection")
        }
    }

    private func projectFeedbackSidecar() async {
        guard let activeSessionID else { return }
        do {
            messages = try await feedbackSidecarStore.project(
                sessionID: activeSessionID,
                messages: messages
            )
        } catch {
            // Feedback is auxiliary state; a corrupt sidecar must not block a
            // conversation. Keep the embedded compatibility projection.
            await recordStartupIssue(error, source: "feedback_sidecar")
        }
    }

    private func refreshSessionSummaries() async {
        do {
            await refreshSessionRunProjection()
            _ = try await sessionQueryReadModel.rebuild(persistence: trajectoryRepository)
            sessions = try await sessionStore.listSessions()
                .sorted { $0.updatedAt > $1.updatedAt }
            refreshLocalStateProjection()
        } catch {
            presentError(error)
        }
    }

    private func refreshLocalStateProjection() {
        let status: [String: Any] = [
            "status": "ok",
            "source": "harness-mobile",
            "ready": isReady,
            "activeSessionID": activeSessionID?.uuidString.lowercased() as Any,
            "running": isRunning,
            "sessionCount": sessions.count
        ]
        let sessionRows = sessions.map { session in
            [
                "id": session.id.uuidString.lowercased(),
                "title": session.title,
                "messageCount": session.messageCount,
                "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt),
                "archived": session.isArchived,
                "queuedInputCount": session.queuedInputCount,
                "resumable": session.isResumable
            ] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(status),
              JSONSerialization.isValidJSONObject(["sessions": sessionRows]),
              let statusData = try? JSONSerialization.data(withJSONObject: status),
              let sessionsData = try? JSONSerialization.data(withJSONObject: ["sessions": sessionRows]),
              let statusBody = String(data: statusData, encoding: .utf8),
              let sessionsBody = String(data: sessionsData, encoding: .utf8) else { return }
        localStateSnapshotStore.update(statusBody: statusBody, sessionsBody: sessionsBody)
    }

    private func migrateLegacyProviderConfigurationIfNeeded() async throws {
        guard let legacyConfiguration = pendingLegacyConfiguration else { return }
        if let profile = providerDirectory.activeProfile {
            let origin = try legacyConfiguration.credentialOrigin()
            _ = try await credentialStore.migrateLegacyAPIKey(
                from: origin,
                to: profile.credentialReference
            )
        }
        try settingsStore.save(providerDirectory)
        pendingLegacyConfiguration = nil
    }

    /// Internal credential lookup seam used by the separately compiled provider
    /// discovery coordinator. It returns a value transiently and must never be
    /// persisted, traced, or projected into observable UI state.
    func apiKey(for configuration: AgentConfiguration) async throws -> String? {
        let origin = try configuration.credentialOrigin()
        if let reference = configuration.credentialReference
            ?? providerDirectory.profile(matching: configuration)?.credentialReference {
            if let apiKey = try await credentialStore.readAPIKey(
                for: reference,
                expectedOrigin: origin
            ) {
                return apiKey
            }
            // OAuth grants use the same request seam: adapters receive only
            // the current access token, never refresh metadata. A grant with
            // explicit RFC 6749 refresh metadata is refreshed before expiry,
            // serialized per profile by the shared coordinator.
            guard let oauth = try await credentialStore.readOAuthCredential(
                for: reference,
                expectedOrigin: origin
            ) else { return nil }
            guard oauth.isExpired(),
                  oauth.refreshToken != nil,
                  oauth.tokenEndpoint != nil,
                  oauth.clientID?.isEmpty == false else {
                return oauth.accessToken
            }
            let profileID = providerDirectory.profile(matching: configuration)?.id
                ?? configuration.profileID
                ?? reference.rawValue
            return try await oauthRefreshCoordinator.credential(
                profileID: profileID,
                credentialStore: credentialStore,
                reference: reference,
                expectedOrigin: origin,
                refresh: { [oauthRefreshClient] credential in
                    try await oauthRefreshClient.refresh(credential)
                }
            )?.accessToken
        }
        return try await credentialStore.readAPIKey(for: origin)
    }

    func readCredential(forOrigin origin: String) async throws -> String? {
        try await credentialStore.readAPIKey(for: origin)
    }

    func saveCredential(_ key: String, forOrigin origin: String) async throws {
        try await credentialStore.saveAPIKey(key, for: origin)
    }

    func saveOAuthCredential(
        _ credential: ProviderOAuthCredential,
        for configuration: AgentConfiguration
    ) async throws {
        let reference = configuration.credentialReference
            ?? providerDirectory.profile(matching: configuration)?.credentialReference
        guard let reference else {
            throw CredentialStoreError.emptyCredential
        }
        try await credentialStore.saveOAuthCredential(
            credential,
            for: reference,
            origin: configuration.credentialOrigin()
        )
    }

    func deleteCredential(forOrigin origin: String) async throws {
        try await credentialStore.deleteAPIKey(for: origin)
    }

    /// Resolves the current profile identity only while a request is being
    /// assembled. The returned value is immutable and contains no credential.
    func providerRequestRoute(
        for configuration: AgentConfiguration
    ) throws -> ProviderRequestRoute {
        let profileID = providerDirectory.profile(matching: configuration)?.id
            ?? configuration.profileID
        let generation = profileID.flatMap { providerRouteGenerations[$0] } ?? 0
        return try ProviderRequestRoute(
            configuration: configuration,
            profileID: profileID,
            generation: generation
        )
    }

    private func advanceProviderRouteGeneration(for profileID: String) {
        providerRouteGenerations[profileID, default: 0] &+= 1
    }

    func contextWindow(for configuration: AgentConfiguration) -> Int? {
        let configuredModels = providerDirectory.profile(matching: configuration)?.models
            ?? ModelProviderCatalog.descriptor(for: configuration.providerID).builtInModels
        return configuredModels
            .first(where: { $0.id == configuration.model })?
            .contextWindow
    }

    private func compactionSummaryConfiguration() throws -> AgentConfiguration? {
        try compactionSummaryRoute?.configuration(in: providerDirectory)
    }

    private func mergeModels(
        _ models: [ProviderModel],
        ensuring modelID: String
    ) -> [ProviderModel] {
        guard !modelID.isEmpty, !models.contains(where: { $0.id == modelID }) else {
            return models
        }
        return models + [ProviderModel(id: modelID)]
    }

    private static func canResume(_ messages: [AgentMessage]) -> Bool {
        guard let last = messages.last else { return false }
        return last.role == .user || last.role == .tool || last.isIncomplete
    }

    private static func trajectoryVisibleEvents(from events: [SessionEvent]) -> [SessionEvent] {
        events.filter { $0.type != SessionEventVocabulary.assistantChunk }
    }

    private static let maximumInMemoryTrajectoryEvents = 2_048
    private static let maximumInMemoryVisibleTrajectoryEvents = 1_024
    private static let maximumPagedVisibleTrajectoryEvents = 2_048
    private static let trajectoryHistoryPageSize = 256

    private static func systemPrompt(
        stateSummary: String?,
        interactionMode: ConversationInteractionMode,
        permissionMode: ToolPermissionMode
    ) async -> String {
        let context = runtimePromptContext(
            stateSummary: stateSummary,
            interactionMode: interactionMode,
            permissionMode: permissionMode
        )
        var sections = [MobileHarnessPrompt.text]
        if !context.isEmpty { sections.append(context) }
        return sections.joined(separator: "\n\n")
    }

    private static func runtimePromptContext(
        stateSummary: String?,
        interactionMode: ConversationInteractionMode,
        permissionMode: ToolPermissionMode
    ) -> String {
        let modeGuidance: String
        switch interactionMode {
        case .agent:
            modeGuidance = ""
        case .plan:
            modeGuidance = """

            You are in plan mode. Explore and reason before proposing a complete implementation plan. Do not make changes or perform destructive actions while plan mode remains active. Present the plan for explicit user review before implementation.
            """
        }
        let permissionGuidance: String
        switch permissionMode {
        case .readOnly:
            permissionGuidance = "\nThe current tool permission mode is read-only. Do not request shell, file-write, notification, or other side-effect tools."
        case .workspaceWrite:
            permissionGuidance = "\nThe current tool permission mode allows workspace changes; this personal build does not add a repeated Harness approval prompt."
        case .dangerFullAccess:
            permissionGuidance = "\nThe current tool permission mode allows all registered on-device tools without an additional app approval prompt. iOS system permissions and Cordis checkpoint guards still apply."
        }
        let base = (modeGuidance + permissionGuidance)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stateSummary, !stateSummary.isEmpty else { return base }
        let state = "Current local work state:\n" + stateSummary
        guard !base.isEmpty else { return state }
        return base + "\n\n" + state
    }
}

private enum AppCommandError: LocalizedError {
    case unknownProvider(String)
    case unsupportedAgentPreset(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case let .unknownProvider(provider):
            return "未知模型服务商：\(provider)。"
        case let .unsupportedAgentPreset(preset):
            return "当前移动版没有名为 \(preset) 的 Agent 预设。"
        case let .invalidState(message):
            return message
        }
    }
}

private actor DurableSubagentMessageCollector {
    private var messages: [AgentMessage]
    private var finalText: String?

    init(messages: [AgentMessage]) {
        self.messages = messages
    }

    func consume(_ event: AgentRuntimeEvent) {
        guard case let .messagesCommitted(committed) = event else { return }
        messages.append(contentsOf: committed)
        for message in committed where !message.content.isEmpty {
            if message.role == .assistant || finalText == nil {
                finalText = message.content
            }
        }
    }

    func snapshot() -> [AgentMessage] { messages }
    func result() -> String? { finalText }
}
