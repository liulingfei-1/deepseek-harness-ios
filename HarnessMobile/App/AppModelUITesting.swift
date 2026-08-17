#if DEBUG
import Foundation

@MainActor
extension AppModel {
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
