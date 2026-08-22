import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionTitleSettingsTests: XCTestCase {
    func testSettingsPersistIndependentRouteAndBuildBoundedConfiguration() throws {
        let suiteName = "com.llf.harnessmobile.session-title.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = ProviderProfileDirectory.initial()
        let profile = try XCTUnwrap(directory.activeProfile)
        let settings = SessionTitleSettings(
            automaticMode: .allPrompts,
            route: CompactionSummaryRoute(
                profileID: profile.id,
                model: profile.defaultModel
            )
        )
        let store = SettingsStore(defaults: defaults)

        try store.saveSessionTitleSettings(settings, in: directory)
        XCTAssertEqual(store.loadSessionTitleSettings(in: directory), settings)
        let configuration = try settings.configuration(
            inheriting: AgentConfiguration(),
            in: directory
        )
        XCTAssertEqual(configuration.profileID, profile.id)
        XCTAssertEqual(configuration.model, profile.defaultModel)
        XCTAssertEqual(configuration.maxOutputTokens, 128)
        XCTAssertEqual(configuration.reasoningMode, .off)
    }

    func testGeneratorSelectsOnlyDirectUserMessagesAndNormalizesOneLine() async throws {
        let hidden = AgentMessage(
            role: .user,
            content: "hidden",
            source: .object([
                "kind": .string("plugin"),
                "plugin": .string("test")
            ])
        )
        let messages: [AgentMessage] = [
            .user("first question"),
            hidden,
            .assistant("answer"),
            .user("second question")
        ]
        XCTAssertEqual(
            try SessionTitleGenerator.selectedMessages(from: messages, mode: .firstPrompt)
                .map(\.content),
            ["first question"]
        )
        let selected = try SessionTitleGenerator.selectedMessages(from: messages, mode: .allPrompts)
        XCTAssertEqual(selected.map(\.content), ["first question", "second question"])

        var configuration = AgentConfiguration()
        configuration.maxOutputTokens = 128
        configuration.reasoningMode = .off
        let title = try await SessionTitleGenerator.generate(
            client: SessionTitleScriptClient(events: [
                .text("  \"移动端 Harness 调试\"  \nignored"),
                .finish(.stop)
            ]),
            configuration: configuration,
            apiKey: "test-only",
            messages: selected
        )
        XCTAssertEqual(title, "移动端 Harness 调试")
    }

    func testSessionStorePinsManualTitleAndRecordsProviderProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessTitleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let session = try await store.createSession()
        XCTAssertEqual(session.titleSource, .fallback)

        let generated = try await store.renameSession(
            id: session.id,
            title: "Generated",
            source: .provider(id: "title-provider", provider: "deepseek", model: "title-model")
        )
        XCTAssertEqual(
            generated.titleSource,
            .provider(id: "title-provider", provider: "deepseek", model: "title-model")
        )
        let pinned = try await store.renameSession(id: session.id, title: "Pinned")
        XCTAssertEqual(pinned.titleSource, .user)
    }
}

private struct SessionTitleScriptClient: LLMStreamingClient {
    let events: [LLMStreamEvent]

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
