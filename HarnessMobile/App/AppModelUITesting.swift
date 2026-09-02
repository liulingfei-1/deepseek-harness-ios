#if DEBUG
import Foundation

@MainActor
extension AppModel {
    func presentMarkdownTableForUITesting() {
        // This isolated renderer fixture does not contact a model provider.
        // Bypass onboarding so it remains deterministic even when the
        // simulator Keychain is unavailable to the test runner.
        isConfigured = true
        messages = [
            AgentMessage.assistant("""
            ## 工具能力对照

            | 能力 | 桌面端 | 手机端 | 状态 | 解释 |
            | :--- | :----: | :----: | ----: | :--- |
            | **文件工具** | 支持 | 支持 | 100% | 工作目录内直接读写 |
            | Web 搜索 | 支持 | 支持 | 95% | 手机直连并发查询，不经过服务器执行 |
            """)
        ]
    }

    func presentLongConversationForUITesting() {
        messages = (0..<1_000).map { index in
            let payload = "长对话性能夹具"
            if index.isMultiple(of: 2) {
                return AgentMessage.user("perf-message-\(index) \(payload)")
            }
            let toolCalls = index == 999
                ? (0..<100).map { toolIndex in
                    AgentToolCall(
                        id: "perf-call-\(toolIndex)",
                        name: "perf_tool_\(toolIndex)",
                        arguments: "{\"index\":\(toolIndex)}"
                    )
                }
                : []
            return AgentMessage.assistant(
                "perf-message-\(index) \(payload)",
                toolCalls: toolCalls
            )
        }
        var presentation = uiTestingRunPresentation()
        presentation.streamingText = String(repeating: "流式尾部 ", count: 160)
            + "perf-stream-tail"
        presentation.streamingPresentationRevision &+= 1
        selectedRunPresentation = presentation
    }

    func presentChatErrorForUITesting() {
        isConfigured = true
        messages = [
            AgentMessage.user("继续完成当前任务"),
            AgentMessage.assistant("当前进度已经保留在这个会话里。")
        ]
        errorMessage = "切换应用后连接中断，请重试上一条消息。"
    }

    func presentReasoningForUITesting() {
        isConfigured = true
        messages = [
            AgentMessage.user("检查当前实现"),
            AgentMessage.assistant(
                "检查完成，没有修改模型原始推理内容。",
                reasoning: "先核对入口，再检查状态与可见操作。"
            )
        ]
    }

    func presentConcurrentSessionRunsForUITesting() async {
        guard let firstSessionID = activeSessionID else { return }
        let firstIdentity = await sessionRunRegistry.allocateIdentity(sessionID: firstSessionID)
        let first = try? await sessionRunRegistry.register(identity: firstIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: firstSessionID)
        }
        guard let first else { return }
        _ = await first.handle.beginRunning(for: firstIdentity)
        _ = await first.state.markRunning(for: firstIdentity)
        _ = try? await first.state.enqueue(
            text: "continue with queued input",
            disposition: .queued,
            for: firstIdentity
        )

        await createConversation(title: "并发会话 B")
        guard let secondSessionID = activeSessionID else { return }
        let secondIdentity = await sessionRunRegistry.allocateIdentity(sessionID: secondSessionID)
        let second = try? await sessionRunRegistry.register(identity: secondIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: secondSessionID)
        }
        guard let second else { return }
        _ = await second.handle.beginRunning(for: secondIdentity)
        _ = await second.state.markRunning(for: secondIdentity)

        // End on the original session so the UI exercise proves that switching
        // away from the newly created session preserves both root runs.
        await switchConversation(to: firstSessionID)
    }

    func presentTrajectoryForUITesting() async {
        guard let sessionID = activeSessionID else { return }
        let userID = UUID().uuidString
        let assistantID = UUID().uuidString
        let usage = SessionTokenUsage(
            inputTokens: 120,
            outputTokens: 24,
            cacheReadTokens: 80,
            cacheWriteTokens: 0,
            reasoningTokens: 6
        )
        let header: JSONValue = .object([
            "config": .object([
                "provider": .string("deepseek"),
                "model": .string("deepseek-chat"),
                "tools": .array([.string("workspace_read_text")])
            ]),
            "system": .string("UI-008 trajectory fixture")
        ])
        let userMessage: JSONValue = .object([
            "id": .string(userID),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("inspect this trajectory")
            ])]),
            "source": .object(["kind": .string("user")])
        ])
        let assistantMessage: JSONValue = .object([
            "id": .string(assistantID),
            "role": .string("assistant"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("I inspected the local session.")
            ]), .object([
                "type": .string("tool-call"),
                "id": .string("ui008-call"),
                "name": .string("workspace_read_text"),
                "arguments": .string("{\"path\":\"/workspace/README.md\"}")
            ])])
        ])
        let toolMessage: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "role": .string("tool"),
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("README fixture output")
            ])]),
            "source": .object([
                "kind": .string("tool"),
                "callId": .string("ui008-call")
            ])
        ])

        do {
            _ = try await trajectoryRepository.append(
                .requestHeader(header: header, reason: .initial, time: 1_000),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .requestContext(
                    provider: "deepseek",
                    model: "deepseek-chat",
                    contextWindow: 128_000,
                    time: 1_010
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .turnStart(turn: 1, time: 1_020),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .stepStart(turn: 1, step: 1, time: 1_030),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .userMessage(userMessage, time: 1_040),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .assistantMessage(
                    turn: 1,
                    step: 1,
                    message: assistantMessage,
                    usage: usage,
                    time: 1_120
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .toolCall(
                    turn: 1,
                    step: 1,
                    callID: "ui008-call",
                    name: "workspace_read_text",
                    arguments: "{\"path\":\"/workspace/README.md\"}",
                    time: 1_140
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .toolResult(
                    turn: 1,
                    step: 1,
                    message: toolMessage,
                    time: 1_240
                ),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .stepEnd(turn: 1, step: 1, time: 1_250),
                sessionID: sessionID
            )
            _ = try await trajectoryRepository.append(
                .turnEnd(turn: 1, reason: .string("completed"), time: 1_260),
                sessionID: sessionID
            )
            try await trajectoryRepository.flush(sessionID: sessionID)
            await refreshTrajectory()
        } catch {
            presentError(error)
        }
    }

    func presentLargeMarkdownForUITesting(characterCount: Int = 1_000_000) {
        isConfigured = true
        let prefix = """
        # large-markdown-start

        """
        let suffix = """


        # large-markdown-end

        [OpenAI](https://openai.com)

        > quoted line one
        > quoted line two

        | Name | Status |
        | :--- | :----: |
        | Harness | ready |

        ~~~~swift
        let localOnly = true
        ~~~~
        """
        let paragraph = String(repeating: "bounded markdown paragraph word ", count: 120) + "\n\n"
        let tailPadding = String(repeating: "x", count: 12_000) + "\n\n"
        let bodyCount = max(
            0,
            characterCount - prefix.count - tailPadding.count - suffix.count
        )
        let repeatedBody = String(repeating: paragraph, count: bodyCount / paragraph.count)
        let remainder = String(repeating: "x", count: bodyCount - repeatedBody.count)
        let markdown = prefix + repeatedBody + remainder + tailPadding + suffix
        messages = [AgentMessage.assistant(markdown)]
    }

    func presentPluginMarketplaceForUITesting() {
        ishPluginMarketplaceCatalog = ISHMarketplaceCatalog(
            sourceURL: "https://example.invalid/market/README.md",
            fetchedAt: "2026-08-16T00:00:00Z",
            stale: false,
            items: [
                ISHMarketplaceCatalogItem(
                    id: "git-tools",
                    name: "Git Tools",
                    repositoryURL: "https://github.com/example/git-tools",
                    repositoryKey: "example/git-tools",
                    description: "在本机 iSH 中整理提交、分支和变更摘要。",
                    category: "工具与能力",
                    compatibility: .supported,
                    unsupportedReason: nil,
                    installed: false,
                    installedPluginID: nil,
                    installedVersion: nil
                ),
                ISHMarketplaceCatalogItem(
                    id: "memory-notes",
                    name: "Memory Notes",
                    repositoryURL: "https://github.com/example/memory-notes",
                    repositoryKey: "example/memory-notes",
                    description: "为 Agent 提供可插拔的本地 Markdown 记忆索引。",
                    category: "记忆",
                    compatibility: .review,
                    unsupportedReason: "安装时会在手机内校验 Host 服务兼容性。",
                    installed: true,
                    installedPluginID: "memory-notes",
                    installedVersion: "1.2.0"
                ),
                ISHMarketplaceCatalogItem(
                    id: "file-memory-native",
                    name: "File Memory Native",
                    repositoryURL: "https://github.com/example/file-memory",
                    repositoryKey: "example/file-memory",
                    description: "按对话隔离、可动态注入上下文的原生文件记忆插件。",
                    category: "记忆",
                    compatibility: .supported,
                    unsupportedReason: nil,
                    installed: true,
                    installedPluginID: "native-agent.file-memory",
                    installedVersion: "1.0.0-native"
                ),
                ISHMarketplaceCatalogItem(
                    id: "desktop-theme",
                    name: "Desktop Theme",
                    repositoryURL: "https://github.com/example/desktop-theme",
                    repositoryKey: "example/desktop-theme",
                    description: "仅提供桌面 Web Client 主题，手机 Host 不执行。",
                    category: "主题与外观",
                    compatibility: .unsupported,
                    unsupportedReason: "该分类主要注入 DSH 桌面 Web UI，当前手机端不兼容。",
                    installed: false,
                    installedPluginID: nil,
                    installedVersion: nil
                ),
            ]
        )
        ishMarketplacePlugins = [
            ISHMarketplacePlugin(
                id: "memory-notes",
                name: "Memory Notes",
                version: "1.2.0",
                description: "为 Agent 提供可插拔的本地 Markdown 记忆索引。",
                license: "MIT",
                source: ISHMarketplacePluginSource(
                    kind: .market,
                    location: "https://github.com/example/memory-notes"
                ),
                enabled: true,
                state: .enabled,
                installedAt: "2026-08-15T12:00:00Z",
                updatedAt: "2026-08-16T00:00:00Z",
                entryCount: 3,
                lastError: nil
            ),
        ]
        let nativePlugin = NativeAgentCompiledPlugin(
            schemaVersion: NativeAgentCompiledPlugin.schemaVersion,
            id: "native-agent.file-memory",
            name: "File Memory Native",
            version: "1.0.0-native",
            description: "按对话隔离的原生文件记忆插件。",
            source: ISHMarketplacePluginSource(
                kind: .github,
                location: "https://github.com/example/file-memory"
            ),
            sourceDigest: String(repeating: "c", count: 64),
            compiledAt: .now,
            compilerProviderID: "ui-test",
            compilerModel: "ui-test",
            enabled: true,
            promptSections: [],
            promptContexts: [
                NativeAgentPromptContext(
                    name: "memory",
                    order: 120,
                    source: .file,
                    path: "<session-storage>/notes.md",
                    maximumCharacters: 6_000,
                    prefix: "<memory>\n",
                    suffix: "\n</memory>"
                )
            ],
            settings: NativeAgentPluginSettings(
                schema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "maxRecallChars": .object([
                            "type": .string("integer"),
                            "title": .string("最大回忆字符数"),
                            "description": .string("单次注入到上下文的字符上限。"),
                            "minimum": .number(256),
                            "maximum": .number(32_768),
                            "default": .number(6_000)
                        ])
                    ]),
                    "required": .array([.string("maxRecallChars")]),
                    "additionalProperties": .bool(false)
                ]),
                defaults: .object(["maxRecallChars": .number(6_000)]),
                values: .object(["maxRecallChars": .number(6_000)])
            ),
            tools: [],
            toolGuards: [],
            compatibilityNotes: [
                "桌面 Node fs 已替换为 iPhone 工作区文件系统。",
                "每个对话使用独立存储目录。"
            ]
        )
        nativeAgentPlugins = [nativePlugin]
        ishMarketplacePlugins.append(nativePlugin.marketplaceProjection)
        ishPluginMarketplaceFailure = nil
        ishPluginMarketplaceOperation = nil
    }

    func presentPluginSettingsForUITesting() {
        ishPluginHostState = .running(hostVersion: "ui-test", processID: nil)
        ishPluginSettingsSnapshot = ISHPluginSettingsSnapshot(
            writable: true,
            hasDocument: true,
            namespaces: [
                ISHPluginSettingsNamespace(
                    ns: "memory-notes",
                    schema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "autoIndex": .object([
                                "type": .string("boolean"),
                                "title": .string("自动索引"),
                                "description": .string("保存文件后自动更新本地记忆索引。"),
                                "default": .bool(true)
                            ]),
                            "maxItems": .object([
                                "type": .string("integer"),
                                "title": .string("最大记录数"),
                                "description": .string("单个命名空间保留的记录上限。"),
                                "minimum": .number(10),
                                "maximum": .number(500),
                                "default": .number(50)
                            ])
                        ]),
                        "required": .array([.string("autoIndex"), .string("maxItems")]),
                        "additionalProperties": .bool(false)
                    ]),
                    value: .object(["autoIndex": .bool(true), "maxItems": .number(80)]),
                    base: .object(["autoIndex": .bool(true), "maxItems": .number(50)]),
                    user: .object(["maxItems": .number(80)]),
                    revision: 7,
                    applies: .live,
                    secrets: [],
                    editable: true,
                    unsupportedReason: nil
                )
            ]
        )
    }

    func presentPluginCompilationFailureForUITesting() {
        presentPluginMarketplaceForUITesting()

        let timestamp = Date(timeIntervalSince1970: 1_724_587_200)
        var trace = NativePluginCompilationTrace(
            source: "example/unsupported-web-client",
            now: timestamp
        )
        trace.finishedAt = timestamp.addingTimeInterval(12)
        trace.outcome = "失败：检测到未审计的 Web client contribution。"
        trace.diagnostic = NativeAgentCompilationDiagnostic(
            code: "UNSUPPORTED_CLIENT_CONTRIBUTION",
            stage: NativePluginCompilationStage.validation.rawValue,
            message: "该插件请求 Web client slot；手机端不动态加载 Web 或 Swift 代码。",
            retryable: false,
            suggestedAction: "删除 Web client contribution，改用受控 native manifest 后重新编译。"
        )
        trace.steps = trace.steps.map { step in
            var updated = step
            switch step.stage {
            case .sourceAcquisition:
                updated.state = .succeeded
                updated.detail = "源码快照已完成，凭据仍留在 Keychain。"
            case .sourceAnalysis:
                updated.state = .succeeded
                updated.detail = "已识别插件贡献和本机 Host 边界。"
            case .adaptability:
                updated.state = .succeeded
                updated.detail = "核心能力可投影为受控原生清单。"
            case .modelCompilation:
                updated.state = .succeeded
                updated.detail = "Agent 已返回候选原生插件清单。"
            case .validation:
                updated.state = .failed
                updated.detail = "拒绝未审计的 Web client contribution。"
            case .nativeInstallation, .ishFallback:
                updated.state = .skipped
                updated.detail = "校验失败，未继续执行。"
            }
            updated.updatedAt = timestamp
            return updated
        }
        trace.logs = [
            NativePluginCompilationLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                timestamp: timestamp,
                stage: .sourceAcquisition,
                state: .succeeded,
                message: "源码快照已完成，凭据仍留在 Keychain。"
            ),
            NativePluginCompilationLogEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                timestamp: timestamp.addingTimeInterval(12),
                stage: .validation,
                state: .failed,
                message: "拒绝未审计的 Web client contribution。"
            ),
        ]
        nativePluginCompilationTrace = trace
    }

    func presentPlanReviewForUITesting() {
        let request = AskUserQuestionRequest(
            questions: [
                AskUserQuestionItem(
                    id: "plan-review",
                    question: "Approve this plan and leave plan mode?",
                    detail: "# Harness Mobile plan\n\n1. Inspect the local runtime.\n2. Apply the change.\n3. Verify it on iPhone.",
                    header: "Plan review",
                    options: [
                        AskUserQuestionOption(
                            label: "Refuse",
                            description: "Keep Plan mode and revise the plan."
                        ),
                        AskUserQuestionOption(
                            label: "Approve",
                            description: "Approve and leave Plan mode at the next model boundary."
                        ),
                    ],
                    intent: AskUserQuestionIntent(approve: "Approve")
                ),
            ]
        )
        var presentation = uiTestingRunPresentation()
        presentation.pendingUserQuestion = ContinuationUserQuestionProvider.Pending(
            id: request.id,
            request: request
        )
        selectedRunPresentation = presentation
    }

    private func uiTestingRunPresentation() -> SessionRunPresentation {
        if let selectedRunPresentation {
            return selectedRunPresentation
        }
        let identity = RunIdentity(
            sessionID: activeSessionID ?? UUID(),
            runID: UUID(),
            generation: 1
        )
        var presentation = SessionRunPresentation(identity: identity)
        presentation.phase = .running
        presentation.runStartedAt = .now
        return presentation
    }
}
#endif
