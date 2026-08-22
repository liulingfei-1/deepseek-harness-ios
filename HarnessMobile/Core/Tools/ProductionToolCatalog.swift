import Foundation

enum ProductionToolCatalog {
    private static let baseApprovedNames: Set<String> = [
        "ask_user_question",
        "camera_ocr",
        "code_execute",
        "diagnostics_read",
        "device_time",
        "exit_plan_mode",
        "glob",
        "grep",
        "ios_native",
        "job_kill",
        "job_list",
        "job_output",
        "lsp",
        "schedule_create",
        "schedule_list",
        "schedule_delete",
        "plugin_marketplace",
        "read",
        "read_image",
        "ralph",
        "run_code",
        "session_event_get",
        "session_event_types",
        "session_search",
        "session_trace",
        "send_message",
        "shell_execute",
        "skill",
        "str_replace_editor",
        "subagent",
        "subagent_fork",
        "subagent_control",
        "subagent_list",
        "terminal_open",
        "terminal_read",
        "terminal_send",
        "terminal_signal",
        "terminal_list",
        "terminal_close",
        "web_fetch",
        "web_search",
        "workflow",
        "workspace_search",
        "workspace_diff",
        "deliverable_write",
        "mcp_connect",
        "mcp_list_tools",
        "mcp_call",
        "mcp_disconnect",
        "work_state_replace_plan",
        "work_state_replace_todos",
        "work_state_set_goal",
        "write",
        "edit",
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
        skillRegistry: MobileSkillRegistry? = nil,
        diagnosticsProvider: @escaping AgentDiagnosticsProvider = { query in
            .object([
                "available": .bool(false),
                "scope": .string(query.scope.rawValue)
            ])
        },
        fileSystemEnvironment: FileSystemToolEnvironment? = nil,
        jobRegistry: any HarnessJobManaging = HarnessJobRegistry(),
        scheduleStore: any HarnessScheduleManaging = HarnessScheduleStore(),
        subagentRunner: LocalSubagentRunner? = nil,
        subagentPolicy: LocalSubagentPolicy = LocalSubagentPolicy(),
        workflowLifecycleSink: @escaping LocalWorkflowLifecycleSink = { _ in },
        terminalProvider: (any ISHTerminalProviding)? = nil,
        trajectoryRepository: SessionTrajectoryRepository = SessionTrajectoryRepository(),
        mcpRegistry: MCPClientRegistry? = nil
    ) -> [any LocalAgentTool] {
        let resolvedSkillRegistry = skillRegistry ?? MobileSkillRegistry(workspaceStore: workspaceStore)
        let resolvedFileSystemEnvironment = fileSystemEnvironment ?? .guarded(
            fileSystem: WorkspaceFileSystemProvider(store: workspaceStore),
            sessionID: sessionID,
            policy: HarnessFsObservationPolicy()
        )
        let codeModeResolver = CodeModeToolResolver()
        let resolvedMCPRegistry = mcpRegistry ?? MCPClientRegistry(
            workspaceURLProvider: { try await workspaceStore.rootURL() }
        )
        var tools: [any LocalAgentTool] = [
                AskUserQuestionTool(service: userQuestionService),
                AgentDiagnosticsTool(provider: diagnosticsProvider),
                DeviceTimeTool(),
                ExitPlanModeTool(
                    questionService: userQuestionService,
                    planState: planModeState
                ),
                ISHShellExecuteTool(
                    store: workspaceStore,
                    sessionID: sessionID,
                    jobRegistry: jobRegistry
                ),
                ISHCodeExecuteTool(
                    store: workspaceStore,
                    sessionID: sessionID
                ),
                ISHRunCodeTool(
                    store: workspaceStore,
                    sessionID: sessionID,
                    resolver: codeModeResolver
                ),
                IOSNativeOffloadTool(
                    store: workspaceStore,
                    sessionID: sessionID
                ),
                OnDeviceLSPTool(
                    store: workspaceStore,
                    sessionID: sessionID
                ),
                PluginMarketplaceTool(executor: pluginMarketplaceExecutor),
                SkillLoadTool(registry: resolvedSkillRegistry),
                WebFetchTool(),
                WebSearchTool(),
                StrReplaceEditorTool(environment: resolvedFileSystemEnvironment),
                WorkStateSetGoalTool(coordinator: workStateCoordinator),
                WorkStateReplacePlanTool(coordinator: workStateCoordinator),
                WorkStateReplaceTodosTool(coordinator: workStateCoordinator),
                WorkspaceListTool(store: workspaceStore),
                WorkspaceReadTextTool(environment: resolvedFileSystemEnvironment),
                WorkspaceWriteTextTool(environment: resolvedFileSystemEnvironment),
                CameraOCRTool(store: workspaceStore)
        ]
        tools.append(contentsOf: SessionTrajectoryToolSuite.makeTools(
            repository: trajectoryRepository,
            sessionID: sessionID
        ))
        tools.append(contentsOf: FileSystemToolSuite.makeTools(
            environment: resolvedFileSystemEnvironment,
            imageStore: workspaceStore
        ))
        tools.append(contentsOf: DeliverableToolSuite.makeTools(
            environment: resolvedFileSystemEnvironment
        ))
        tools.append(contentsOf: JobToolSuite.makeTools(
            registry: jobRegistry,
            ownerSession: sessionID
        ))
        tools.append(contentsOf: ScheduleToolSuite.makeTools(
            store: scheduleStore,
            ownerSession: sessionID
        ))
        tools.append(contentsOf: ISHTerminalToolSuite.makeTools(
            provider: terminalProvider ?? ISHTerminalSessionProvider(),
            ownerSession: sessionID
        ))
        tools.append(contentsOf: SubagentToolSuite.makeTools(
            runner: subagentRunner,
            registry: jobRegistry,
            ownerSession: sessionID,
            policy: subagentPolicy
        ))
        tools.append(contentsOf: WorkflowToolSuite.makeTools(
            store: workspaceStore,
            runner: subagentRunner,
            registry: jobRegistry,
            ownerSession: sessionID,
            maximumDepth: subagentPolicy.maximumDepth,
            lifecycleSink: workflowLifecycleSink
        ))
        tools.append(contentsOf: RalphToolSuite.makeTools(
            runner: subagentRunner,
            registry: jobRegistry,
            ownerSession: sessionID,
            maximumDepth: subagentPolicy.maximumDepth
        ))
        tools.append(contentsOf: MCPToolSuite.makeTools(
            workspaceStore: workspaceStore,
            registry: resolvedMCPRegistry
        ))
#if os(iOS)
        tools.append(contentsOf: MobileNativeToolKit.makeSystemTools())
#endif
        let resolvedTools = tools
        codeModeResolver.install { name in
            resolvedTools.first { $0.definition.name == name }
        }
        codeModeResolver.installDefinitions {
            resolvedTools.map(\.definition).sorted { $0.name < $1.name }
        }
        return tools
    }

    static func makeRegistry(
        workspaceStore: WorkspaceStore,
        workStateCoordinator: WorkStateCoordinator = WorkStateCoordinator(),
        sessionID: String = "default",
        userQuestionService: UserQuestionService = UserQuestionService(),
        planModeState: PlanModeStateStore = PlanModeStateStore(),
        pluginMarketplaceExecutor: PluginMarketplaceToolExecutor? = nil,
        skillRegistry: MobileSkillRegistry? = nil,
        diagnosticsProvider: @escaping AgentDiagnosticsProvider = { query in
            .object([
                "available": .bool(false),
                "scope": .string(query.scope.rawValue)
            ])
        },
        scheduleStore: any HarnessScheduleManaging = HarnessScheduleStore(),
        subagentRunner: LocalSubagentRunner? = nil,
        subagentPolicy: LocalSubagentPolicy = LocalSubagentPolicy(),
        workflowLifecycleSink: @escaping LocalWorkflowLifecycleSink = { _ in },
        trajectoryRepository: SessionTrajectoryRepository = SessionTrajectoryRepository(),
        mcpRegistry: MCPClientRegistry? = nil
    ) -> LocalToolRegistry {
        let tools = makeTools(
            workspaceStore: workspaceStore,
            workStateCoordinator: workStateCoordinator,
            sessionID: sessionID,
            userQuestionService: userQuestionService,
            planModeState: planModeState,
            pluginMarketplaceExecutor: pluginMarketplaceExecutor,
            skillRegistry: skillRegistry,
            diagnosticsProvider: diagnosticsProvider,
            scheduleStore: scheduleStore,
            subagentRunner: subagentRunner,
            subagentPolicy: subagentPolicy,
            workflowLifecycleSink: workflowLifecycleSink,
            trajectoryRepository: trajectoryRepository,
            mcpRegistry: mcpRegistry
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
        skillRegistry: MobileSkillRegistry? = nil,
        diagnosticsProvider: @escaping AgentDiagnosticsProvider = { query in
            .object([
                "available": .bool(false),
                "scope": .string(query.scope.rawValue)
            ])
        },
        scheduleStore: any HarnessScheduleManaging = HarnessScheduleStore(),
        subagentRunner: LocalSubagentRunner? = nil,
        subagentPolicy: LocalSubagentPolicy = LocalSubagentPolicy(),
        workflowLifecycleSink: @escaping LocalWorkflowLifecycleSink = { _ in },
        terminalProvider: (any ISHTerminalProviding)? = nil,
        trajectoryRepository: SessionTrajectoryRepository = SessionTrajectoryRepository(),
        mcpRegistry: MCPClientRegistry? = nil
    ) -> CordisPluginDefinition {
        return CordisPluginDefinition(
            id: "core.mobile-tools",
            version: "1",
            dependencies: [
                CordisAgentServiceKeys.fileSystem.name,
                CordisAgentServiceKeys.jobs.name,
                CordisAgentServiceKeys.systemPrompt.name,
                CordisAgentServiceKeys.tools.name
            ]
        ) { context in
            let fileSystem = try await context.service(CordisAgentServiceKeys.fileSystem)
            let jobs = try await context.service(CordisAgentServiceKeys.jobs)
            let environment = FileSystemToolEnvironment(
                fileSystem: fileSystem,
                actor: CordisFsActor(sessionID: sessionID),
                writeIntent: { input in
                    try await context.waterfall(
                        CordisFileSystemEvents.writeIntent,
                        input: input,
                        default: { nil }
                    )
                },
                editVersion: { input in
                    try await context.waterfall(
                        CordisFileSystemEvents.editIntent,
                        input: input,
                        default: { nil }
                    )
                },
                observe: { input in
                    try await context.serial(CordisFileSystemEvents.observed, input: input)
                }
            )
            let tools = makeTools(
                workspaceStore: workspaceStore,
                workStateCoordinator: workStateCoordinator,
                sessionID: sessionID,
                userQuestionService: userQuestionService,
                planModeState: planModeState,
                pluginMarketplaceExecutor: pluginMarketplaceExecutor,
                skillRegistry: skillRegistry,
                diagnosticsProvider: diagnosticsProvider,
                fileSystemEnvironment: environment,
                jobRegistry: jobs,
                scheduleStore: scheduleStore,
                subagentRunner: subagentRunner,
                subagentPolicy: subagentPolicy,
                workflowLifecycleSink: workflowLifecycleSink,
                terminalProvider: terminalProvider,
                trajectoryRepository: trajectoryRepository,
                mcpRegistry: mcpRegistry
            )
            precondition(
                Set(tools.map { $0.definition.name }) == approvedNames,
                "Production tool catalog changed without updating its audited allowlist."
            )
            for tool in tools {
                try await context.registerTool(tool)
            }
            for section in FileSystemToolSuite.promptSections {
                try await context.promptSection(
                    CordisPromptSection(
                        name: section.name,
                        order: section.order,
                        text: section.text
                    )
                )
            }
            for section in DeliverableToolSuite.promptSections {
                try await context.promptSection(
                    CordisPromptSection(
                        name: section.name,
                        order: section.order,
                        text: section.text
                    )
                )
            }
            try await context.promptSection(JobToolSuite.promptSection)
            try await context.promptSection(ScheduleToolSuite.promptSection)
            try await context.promptSection(SubagentToolSuite.promptSection)
            try await context.promptSection(WorkflowToolSuite.promptSection)
            try await context.promptSection(RalphToolSuite.promptSection)
            try await context.promptSection(MCPToolSuite.promptSection)
            try await context.promptSection(
                CordisPromptSection(
                    name: "tool:lsp",
                    order: 112,
                    text: "Use search/read for ordinary navigation. Use lsp when textual matches are ambiguous or before a change requires precise definitions, implementations, or references. Positions are one-based line and character (UTF-16) at the cursor; an off-symbol position may return no results. findReferences always includes the declaration."
                )
            )
        }
    }
}
