import Foundation

enum ProductionToolCatalog {
    private static let baseApprovedNames: Set<String> = [
        "ask_user_question",
        "camera_ocr",
        "device_time",
        "exit_plan_mode",
        "ios_native",
        "plugin_marketplace",
        "shell_execute",
        "skill",
        "web_fetch",
        "work_state_replace_plan",
        "work_state_replace_todos",
        "work_state_set_goal",
        "workspace_list_files",
        "workspace_read_text",
        "workspace_write_text"
    ]

    static let approvedNames = baseApprovedNames.union(MobileNativeToolKit.approvedNames)

    static func makeTools(
        workspaceStore: WorkspaceStore,
        workStateCoordinator: WorkStateCoordinator = WorkStateCoordinator(),
        sessionID: String = "default",
        userQuestionService: UserQuestionService = UserQuestionService(),
        planModeState: PlanModeStateStore = PlanModeStateStore(),
        pluginMarketplaceExecutor: PluginMarketplaceToolExecutor? = nil,
        skillRegistry: MobileSkillRegistry? = nil
    ) -> [any LocalAgentTool] {
        let resolvedSkillRegistry = skillRegistry ?? MobileSkillRegistry(workspaceStore: workspaceStore)
        var tools: [any LocalAgentTool] = [
                AskUserQuestionTool(service: userQuestionService),
                DeviceTimeTool(),
                ExitPlanModeTool(
                    questionService: userQuestionService,
                    planState: planModeState
                ),
                ISHShellExecuteTool(
                    store: workspaceStore,
                    sessionID: sessionID
                ),
                IOSNativeOffloadTool(
                    store: workspaceStore,
                    sessionID: sessionID
                ),
                PluginMarketplaceTool(executor: pluginMarketplaceExecutor),
                SkillLoadTool(registry: resolvedSkillRegistry),
                WebFetchTool(),
                WorkStateSetGoalTool(coordinator: workStateCoordinator),
                WorkStateReplacePlanTool(coordinator: workStateCoordinator),
                WorkStateReplaceTodosTool(coordinator: workStateCoordinator),
                WorkspaceListTool(store: workspaceStore),
                WorkspaceReadTextTool(store: workspaceStore),
                WorkspaceWriteTextTool(store: workspaceStore),
                CameraOCRTool(store: workspaceStore)
        ]
#if os(iOS)
        tools.append(contentsOf: MobileNativeToolKit.makeSystemTools())
#endif
        return tools
    }

    static func makeRegistry(
        workspaceStore: WorkspaceStore,
        workStateCoordinator: WorkStateCoordinator = WorkStateCoordinator(),
        sessionID: String = "default",
        userQuestionService: UserQuestionService = UserQuestionService(),
        planModeState: PlanModeStateStore = PlanModeStateStore(),
        pluginMarketplaceExecutor: PluginMarketplaceToolExecutor? = nil,
        skillRegistry: MobileSkillRegistry? = nil
    ) -> LocalToolRegistry {
        let tools = makeTools(
            workspaceStore: workspaceStore,
            workStateCoordinator: workStateCoordinator,
            sessionID: sessionID,
            userQuestionService: userQuestionService,
            planModeState: planModeState,
            pluginMarketplaceExecutor: pluginMarketplaceExecutor,
            skillRegistry: skillRegistry
        )
        let registry = LocalToolRegistry(tools: tools)
        precondition(
            Set(registry.definitions.map(\.name)) == approvedNames,
            "Production tool catalog changed without updating its audited allowlist."
        )
        return registry
    }

    static func pluginDefinition(
        workspaceStore: WorkspaceStore,
        workStateCoordinator: WorkStateCoordinator = WorkStateCoordinator(),
        sessionID: String = "default",
        userQuestionService: UserQuestionService = UserQuestionService(),
        planModeState: PlanModeStateStore = PlanModeStateStore(),
        pluginMarketplaceExecutor: PluginMarketplaceToolExecutor? = nil,
        skillRegistry: MobileSkillRegistry? = nil
    ) -> CordisPluginDefinition {
        let tools = makeTools(
            workspaceStore: workspaceStore,
            workStateCoordinator: workStateCoordinator,
            sessionID: sessionID,
            userQuestionService: userQuestionService,
            planModeState: planModeState,
            pluginMarketplaceExecutor: pluginMarketplaceExecutor,
            skillRegistry: skillRegistry
        )
        precondition(
            Set(tools.map { $0.definition.name }) == approvedNames,
            "Production tool catalog changed without updating its audited allowlist."
        )
        return CordisPluginDefinition(
            id: "core.mobile-tools",
            version: "1",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            for tool in tools {
                try await context.registerTool(tool)
            }
        }
    }
}
