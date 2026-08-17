import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class MobileSkillRegistryTests: XCTestCase {
    func testBundleDiscoveryUsesUpstreamRootPrecedence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSkill(
            root,
            path: "Skills/release-notes/SKILL.md",
            description: "custom",
            body: "custom instructions"
        )
        try writeSkill(
            root,
            path: ".agents/skills/release-notes.md",
            description: "agents",
            body: "agents instructions"
        )
        try writeSkill(
            root,
            path: ".dsh/skills/release-notes/SKILL.md",
            description: "dsh",
            body: "dsh instructions"
        )

        let registry = MobileSkillRegistry(workspaceStore: WorkspaceStore(root: root))
        let catalog = try await registry.catalog()
        XCTAssertEqual(catalog.map(\.name), ["release-notes"])
        XCTAssertEqual(catalog.first?.source, .projectDSH)

        let definition = try await registry.definition(named: "release-notes")
        XCTAssertEqual(definition.summary.description, "dsh")
        XCTAssertEqual(definition.content, "dsh instructions")
        XCTAssertEqual(definition.summary.resourceBase, ".dsh/skills/release-notes")
    }

    func testInvocationPolicyFailsClosedAndUserOnlySkillLoadsOnlyForUser() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSkill(
            root,
            path: "Skills/user-only.md",
            description: "human switch",
            extraFrontmatter: [
                "disable-model-invocation: true",
                "user-invocable: yes"
            ],
            body: "Use the human-only steps."
        )
        try writeSkill(
            root,
            path: "Skills/legacy.md",
            description: "must be ignored",
            extraFrontmatter: ["disableModelInvocation: false"],
            body: "legacy"
        )
        try writeSkill(
            root,
            path: "Skills/invalid-policy.md",
            description: "must be ignored",
            extraFrontmatter: ["user-invocable: sometimes"],
            body: "invalid"
        )

        let registry = MobileSkillRegistry(workspaceStore: WorkspaceStore(root: root))
        let catalog = try await registry.catalog()
        XCTAssertEqual(catalog.map(\.name), ["user-only"])
        XCTAssertEqual(catalog.first?.invocation, MobileSkillInvocationPolicy(
            modelInvocable: false,
            userInvocable: true
        ))
        let modelPrompt = await registry.modelCatalogPrompt()
        let userInvocation = await registry.userInvocableDefinition(named: "user-only")
        XCTAssertFalse(modelPrompt.contains("user-only"))
        XCTAssertEqual(userInvocation?.content, "Use the human-only steps.")

        do {
            _ = try await SkillLoadTool(registry: registry).execute(arguments: ["name": .string("user-only")])
            XCTFail("The model tool must reject a user-only skill.")
        } catch let error as MobileSkillError {
            XCTAssertEqual(error, .modelInvocationDisabled("user-only"))
        }
    }

    func testSkillToolLoadsCurrentBundleContentOnDemand() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Skills/on-demand/SKILL.md"
        try writeSkill(root, path: path, description: "load current content", body: "first revision")

        let registry = MobileSkillRegistry(workspaceStore: WorkspaceStore(root: root))
        let tool = SkillLoadTool(registry: registry)
        let first = try await tool.execute(arguments: ["name": .string("on-demand")])
        XCTAssertTrue(first.contains("first revision"))

        try writeSkill(root, path: path, description: "load current content", body: "second revision")
        let second = try await tool.execute(arguments: ["name": .string("on-demand")])
        XCTAssertTrue(second.contains("second revision"))
        XCTAssertFalse(second.contains("first revision"))
    }

    private func writeSkill(
        _ root: URL,
        path: String,
        description: String,
        extraFrontmatter: [String] = [],
        body: String
    ) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let name = url.deletingPathExtension().lastPathComponent == "SKILL"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        let text = ([
            "---",
            "name: \(name)",
            "description: \(description)"
        ] + extraFrontmatter + ["---", body]).joined(separator: "\n")
        try Data(text.utf8).write(to: url)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessMobileSkills-\(UUID().uuidString)", isDirectory: true)
    }
}
