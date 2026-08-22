import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkspaceInstructionTransitionTests: XCTestCase {
    func testBaselineAndNestedChangesAreAppendOnlyTypedMessages() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "AGENTS.md", "root rule")
        try write(root, "packages/app/AGENTS.md", "nested rule")
        let engine = WorkspaceInstructionTransitionEngine(
            workspaceStore: WorkspaceStore(root: root)
        )
        let sessionID = UUID()

        let baselineValue = await engine.prepareTransition(sessionID: sessionID, visibleMessages: [])
        let baseline = try XCTUnwrap(baselineValue)
        XCTAssertEqual(baseline.role, .user)
        XCTAssertTrue(baseline.content.contains("Instructions from: AGENTS.md"))
        XCTAssertEqual(baseline.workspaceInstructionSource?.baseline, true)
        XCTAssertEqual(baseline.workspaceInstructionSource?.changes.map(\.action), [.set])

        let unchanged = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline]
        )
        XCTAssertNil(unchanged)

        let nestedValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline],
            touchedPaths: ["packages/app/Sources/main.swift"]
        )
        let nested = try XCTUnwrap(nestedValue)
        XCTAssertTrue(nested.content.contains("Additional instructions from: packages/app/AGENTS.md"))
        XCTAssertEqual(nested.workspaceInstructionSource?.changes.map(\.action), [.set])
        XCTAssertEqual(nested.workspaceInstructionSource?.changes.first?.path, "packages/app/AGENTS.md")
    }

    func testReplaceRemoveAndReappearanceRemainDistinctTransitions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "AGENTS.md", "first rule")
        let engine = WorkspaceInstructionTransitionEngine(
            workspaceStore: WorkspaceStore(root: root)
        )
        let sessionID = UUID()
        let baselineValue = await engine.prepareTransition(sessionID: sessionID, visibleMessages: [])
        let baseline = try XCTUnwrap(baselineValue)

        try write(root, "AGENTS.md", "second rule is longer")
        let replacementValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline],
            touchedPaths: ["AGENTS.md"]
        )
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertEqual(replacement.workspaceInstructionSource?.changes.map(\.action), [.replace])
        XCTAssertTrue(replacement.content.contains("Updated instructions from: AGENTS.md"))

        try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
        let removalValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline, replacement],
            touchedPaths: ["AGENTS.md"]
        )
        let removal = try XCTUnwrap(removalValue)
        XCTAssertEqual(removal.workspaceInstructionSource?.changes.map(\.action), [.remove])
        XCTAssertTrue(removal.content.contains("Instructions removed: AGENTS.md"))

        try write(root, "AGENTS.md", "third rule")
        let reappearanceValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline, replacement, removal],
            touchedPaths: ["AGENTS.md"]
        )
        let reappearance = try XCTUnwrap(reappearanceValue)
        XCTAssertEqual(reappearance.workspaceInstructionSource?.changes.map(\.action), [.set])
    }

    func testCompactionShadowRearmsCompleteCurrentBaselineFromDurableHistory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "AGENTS.md", "root rule")
        try write(root, "packages/app/AGENTS.md", "nested rule")
        let engine = WorkspaceInstructionTransitionEngine(
            workspaceStore: WorkspaceStore(root: root)
        )
        let sessionID = UUID()
        let baselineValue = await engine.prepareTransition(sessionID: sessionID, visibleMessages: [])
        let baseline = try XCTUnwrap(baselineValue)
        let nestedValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline],
            touchedPaths: ["packages/app/main.swift"]
        )
        let nested = try XCTUnwrap(nestedValue)
        let checkpoint = AgentMessage(
            role: .user,
            content: "<compacted-summary>state</compacted-summary>",
            source: .object(["kind": .string("plugin"), "plugin": .string("dsh-compaction-basic")])
        )

        XCTAssertTrue(
            WorkspaceInstructionCompactionProjection.requiresBaselineRearm(
                beforeCompaction: [baseline, nested],
                visibleAfterCompaction: [checkpoint],
                baselineIdentity: WorkspaceInstructionTransitionEngine.defaultBaselineIdentity
            )
        )
        let rearmedValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [checkpoint],
            durableMessages: [baseline, nested, checkpoint]
        )
        let rearmed = try XCTUnwrap(rearmedValue)
        XCTAssertEqual(rearmed.workspaceInstructionSource?.baseline, true)
        XCTAssertTrue(rearmed.content.contains("Instructions from: AGENTS.md"))
        XCTAssertTrue(rearmed.content.contains("Instructions from: packages/app/AGENTS.md"))
        XCTAssertFalse(rearmed.content.contains("Additional instructions from:"))
    }

    func testSameDirectoryTrimmedDuplicateIsRemovedWhenPrecedenceChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "AGENTS.md", "agents rule")
        try write(root, "CLAUDE.md", "claude rule")
        let engine = WorkspaceInstructionTransitionEngine(
            workspaceStore: WorkspaceStore(root: root)
        )
        let sessionID = UUID()
        let baselineValue = await engine.prepareTransition(sessionID: sessionID, visibleMessages: [])
        let baseline = try XCTUnwrap(baselineValue)
        XCTAssertEqual(baseline.workspaceInstructionSource?.changes.count, 2)

        try write(root, "CLAUDE.md", "  agents rule\n")
        let updateValue = await engine.prepareTransition(
            sessionID: sessionID,
            visibleMessages: [baseline],
            touchedPaths: ["CLAUDE.md"]
        )
        let update = try XCTUnwrap(updateValue)
        XCTAssertEqual(update.workspaceInstructionSource?.changes.map(\.action), [.remove])
        XCTAssertEqual(update.workspaceInstructionSource?.changes.first?.path, "CLAUDE.md")
    }

    func testRequestPrefixStabilityFixture() throws {
        let fixture = try loadPrefixFixture()
        XCTAssertEqual(fixture.source.tag, "dsh-v0.1.1-rc.2")
        XCTAssertEqual(fixture.source.commit, "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e")

        let baselineMessage = AgentMessage.workspaceInstruction(
            fixture.instruction.content,
            source: WorkspaceInstructionMessageSource(
                baseline: true,
                baselineIdentity: "fixture-v1",
                changes: [
                    WorkspaceInstructionChange(
                        action: .set,
                        scope: ".\u{0}AGENTS.md",
                        path: "AGENTS.md",
                        digest: "fixture"
                    )
                ]
            )
        )
        let base = request(
            messages: [.user(fixture.userMessage)],
            toolDescription: fixture.toolDescription
        )
        let identical = request(
            messages: [.user(fixture.userMessage)],
            toolDescription: fixture.toolDescription
        )
        let appended = request(
            messages: [.user(fixture.userMessage), baselineMessage],
            toolDescription: fixture.toolDescription
        )
        let toolChanged = request(
            messages: [.user(fixture.userMessage)],
            toolDescription: fixture.changedToolDescription
        )

        let baseSnapshot = ModelRequestPrefixSnapshot.capture(base)
        XCTAssertEqual(
            ModelRequestPrefixSnapshot.capture(identical).difference(from: baseSnapshot),
            .identical
        )
        XCTAssertEqual(
            ModelRequestPrefixSnapshot.capture(appended).difference(from: baseSnapshot),
            .messagesAppended(count: 1, workspaceInstructions: true)
        )
        XCTAssertEqual(
            ModelRequestPrefixSnapshot.capture(toolChanged).difference(from: baseSnapshot),
            .toolSchemaChanged
        )
    }

    private func request(messages: [AgentMessage], toolDescription: String) -> ModelRequest {
        ModelRequest(
            configuration: AgentConfiguration(),
            apiKey: "test-key",
            systemPrompt: "stable system prompt",
            messages: messages,
            tools: [
                ModelToolDefinition(
                    name: "read",
                    description: toolDescription,
                    parameters: .object(["type": .string("object")])
                )
            ]
        )
    }

    private func loadPrefixFixture() throws -> PrefixFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            PrefixFixture.self,
            from: Data(
                contentsOf: repositoryRoot
                    .appendingPathComponent("CompatibilityFixtures/deepseek/request-prefix-stability-v1.json")
            )
        )
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessWorkspaceInstructions-\(UUID().uuidString)")
    }
}

private struct PrefixFixture: Decodable {
    let source: Source
    let userMessage: String
    let toolDescription: String
    let changedToolDescription: String
    let instruction: Instruction

    struct Source: Decodable {
        let tag: String
        let commit: String
    }

    struct Instruction: Decodable {
        let content: String
    }
}
