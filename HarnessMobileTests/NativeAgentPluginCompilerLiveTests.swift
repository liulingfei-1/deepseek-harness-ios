import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Live end-to-end proof of the native plugin pipeline: a realistic plugin
/// source snapshot is compiled by the real model route into a native manifest
/// (tools + prompt sections), which is exactly what "native install" runs on
/// device. Skips unless a route file/config is provided, so normal CI and
/// local runs are unaffected.
final class NativeAgentPluginCompilerLiveTests: XCTestCase {
    private struct LiveRouteFile: Codable {
        let baseURL: String
        let model: String
        let apiKey: String
    }

    private func liveConfiguration() throws -> (AgentConfiguration, String) {
        // xcodebuild forwards host variables prefixed with TEST_RUNNER_ to the
        // on-device test runner; fall back to a local route file.
        let environment = ProcessInfo.processInfo.environment
        let apiKey = environment["UITEST_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            throw XCTSkip("Export TEST_RUNNER_UITEST_API_KEY for the live compiler test.")
        }
        var configuration = AgentConfiguration()
        if let baseURL = environment["UITEST_BASE_URL"], !baseURL.isEmpty {
            configuration.baseURL = baseURL
        }
        if let model = environment["UITEST_MODEL"], !model.isEmpty {
            configuration.model = model
        }
        configuration.reasoningMode = .off
        configuration.maxOutputTokens = 8_192
        return (configuration, apiKey)
    }

    private func sampleSnapshot() -> NativeAgentPluginSourceSnapshot {
        func file(_ path: String, _ content: String) -> NativeAgentPluginSourceFile {
            NativeAgentPluginSourceFile(path: path, content: content, truncated: false)
        }
        return NativeAgentPluginSourceSnapshot(
            schemaVersion: 1,
            failureReason: "prepared from marketplace snapshot",
            sourceDigest: "a1b2c3d4e5f60718293a4b5c6d7e8f9011121314a1b2c3d4e5f60718293a4b5c",
            source: ISHMarketplacePluginSource(
                kind: .market,
                location: "https://github.com/example/word-count"
            ),
            packageName: "word-count",
            version: "1.0.0",
            description: "Counts words and characters in text the agent provides.",
            files: [
                file("package.json", """
                {
                  "name": "word-count",
                  "version": "1.0.0",
                  "description": "Counts words and characters in text.",
                  "main": "index.js",
                  "dsh": {"plugin": {"tools": ["count_words"]}}
                }
                """),
                file("index.js", """
                export function countWords({ text }) {
                  const words = String(text).trim().split(/\\s+/).filter(Boolean).length
                  const characters = String(text).length
                  return { words, characters }
                }
                export const count_words = countWords
                """),
                file("README.md", """
                # word-count

                Provides one tool `count_words` that takes `{ text: string }` and
                returns `{ words, characters }`. Read-only, no network, no storage.
                """)
            ]
        )
    }

    func testCompilesRealPluginSourceIntoNativeManifestWhenExplicitlyEnabled() async throws {
        let (configuration, apiKey) = try liveConfiguration()

        let compiler = NativeAgentPluginCompiler(client: OpenAICompatibleClient())
        var events: [NativeAgentPluginCompiler.Event] = []
        let compiled = try await compiler.compile(
            source: sampleSnapshot(),
            configuration: configuration,
            apiKey: apiKey,
            allowedToolDefinitions: [
                workspaceReadDefinition,
                workspaceWriteDefinition
            ],
            onEvent: { event in
                await MainActor.run { events.append(event) }
            }
        )

        // The compiled manifest must be a usable native plugin: named, with at
        // least one contributed tool mapping the source's capability.
        XCTAssertFalse(compiled.id.isEmpty)
        XCTAssertFalse(compiled.name.isEmpty)
        XCTAssertFalse(compiled.tools.isEmpty, "compiled plugin must contribute tools")
        XCTAssertTrue(
            events.contains { if case .validationSucceeded = $0 { return true } else { return false } },
            "events: \(events)"
        )
        XCTAssertFalse(
            events.contains { if case .adaptabilityRejected = $0 { return true } else { return false } }
        )

        let toolNames = compiled.tools.map(\.name)
        XCTAssertTrue(toolNames.allSatisfy { !$0.isEmpty })
        // Every tool must carry runnable metadata for the native runtime.
        XCTAssertTrue(compiled.tools.allSatisfy { !$0.instructions.isEmpty })
        struct CompileSummary: Codable {
            let id: String
            let name: String
            let tools: [String]
            let promptSections: Int
        }
        let summary = CompileSummary(
            id: compiled.id,
            name: compiled.name,
            tools: toolNames,
            promptSections: compiled.promptSections.count
        )
        let summaryData = try JSONEncoder().encode(summary)
        print("COMPILED: \(String(decoding: summaryData, as: UTF8.self))")
    }

    private var workspaceReadDefinition: ModelToolDefinition {
        ModelToolDefinition(
            name: "workspace_read_text",
            description: "Read a bounded UTF-8 text file from the private workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path")])
            ])
        )
    }

    private var workspaceWriteDefinition: ModelToolDefinition {
        ModelToolDefinition(
            name: "workspace_write_text",
            description: "Write a bounded UTF-8 text file into the private workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        )
    }
}
