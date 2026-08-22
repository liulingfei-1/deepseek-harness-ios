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
        messages = (0..<240).map { index in
            let payload = "长对话性能夹具"
            if index.isMultiple(of: 2) {
                return AgentMessage.user("perf-message-\(index) \(payload)")
            }
            return AgentMessage.assistant("perf-message-\(index) \(payload)")
        }
        streamingText = String(repeating: "流式尾部 ", count: 160) + "perf-stream-tail"
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
        pendingUserQuestion = ContinuationUserQuestionProvider.Pending(
            id: request.id,
            request: request
        )
    }
}
#endif
