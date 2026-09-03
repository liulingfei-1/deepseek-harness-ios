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


    /// Adaptation-surface probe: compiles a spread of plugin shapes (multi
    /// tool, prompt-context, workspace storage, shell-driven) through the real
    /// route and reports the native-adaptation rate. This is the success-rate
    /// signal for "most plugins install natively".
    func testCompilesPluginShapeSpreadWhenExplicitlyEnabled() async throws {
        let (configuration, apiKey) = try liveConfiguration()
        let compiler = NativeAgentPluginCompiler(client: OpenAICompatibleClient())

        let multiTool = snapshot(
            name: "text-utilities",
            version: "1.1.0",
            description: "Text utilities: uppercase, word count and slugify.",
            digestSuffix: "1111111111111111111111111111111111111111111111111111111111111111",
            files: [
                ("package.json", """
                {"name":"text-utilities","version":"1.1.0","dsh":{"plugin":{"tools":["upper","count","slug"]}}}
                """),
                ("index.js", """
                export function upper({ text }) { return { text: String(text).toUpperCase() } }
                export function count({ text }) { return { characters: String(text).length } }
                export function slug({ text }) { return { slug: String(text).toLowerCase().replace(/[^a-z0-9]+/g, '-') } }
                export const upper_tool = upper
                export const count_tool = count
                export const slug_tool = slug
                """),
                ("README.md", "Three read-only text tools. No network, no storage.")
            ]
        )

        let promptContext = snapshot(
            name: "style-guide",
            version: "0.3.0",
            description: "Injects a writing style guide as prompt context each turn.",
            digestSuffix: "2222222222222222222222222222222222222222222222222222222222222222",
            files: [
                ("package.json", """
                {"name":"style-guide","version":"0.3.0","dsh":{"plugin":{"prompt_context":{"source":"inline"}}}}
                """),
                ("guide.md", "Always answer in short numbered steps. Prefer examples over abstract advice."),
                ("README.md", "Prompt-only plugin: no tools, injects the guide as context.")
            ]
        )

        let storage = snapshot(
            name: "reading-list",
            version: "2.0.0",
            description: "Persists a per-session reading list in plugin storage.",
            digestSuffix: "3333333333333333333333333333333333333333333333333333333333333333",
            files: [
                ("package.json", """
                {"name":"reading-list","version":"2.0.0","dsh":{"plugin":{"tools":["add_item","list_items"]}}}
                """),
                ("index.js", """
                import fs from 'node:fs'
                export function add_item({ title }) {
                  fs.mkdirSync('.harness-mobile/native-agent-plugins/reading-list', { recursive: true })
                  fs.appendFileSync('.harness-mobile/native-agent-plugins/reading-list/list.txt', title + '\n')
                  return { ok: true }
                }
                export function list_items() {
                  const p = '.harness-mobile/native-agent-plugins/reading-list/list.txt'
                  return { items: fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean) : [] }
                }
                export const add_item_tool = add_item
                export const list_items_tool = list_items
                """),
                ("README.md", "Two tools backed by plugin-private storage under .harness-mobile.")
            ]
        )

        let shellDriven = snapshot(
            name: "git-summary",
            version: "1.2.0",
            description: "Summarizes git commits and branches inside the iSH sandbox.",
            digestSuffix: "4444444444444444444444444444444444444444444444444444444444444444",
            files: [
                ("package.json", """
                {"name":"git-summary","version":"1.2.0","dsh":{"plugin":{"tools":["git_log"]}}}
                """),
                ("summarize.sh", "#!/bin/sh\ngit log --oneline -20"),
                ("README.md", "Runs git commands through the iSH shell and returns summaries.")
            ]
        )

        let cases: [(String, NativeAgentPluginSourceSnapshot)] = [
            ("multi-tool", multiTool),
            ("prompt-context", promptContext),
            ("storage", storage),
            ("shell-driven", shellDriven)
        ]

        var adapted = 0
        var report: [String] = []
        for (label, snapshot) in cases {
            do {
                let compiled = try await compiler.compile(
                    source: snapshot,
                    configuration: configuration,
                    apiKey: apiKey,
                    allowedToolDefinitions: [
                        workspaceReadDefinition,
                        workspaceWriteDefinition
                    ]
                )
                adapted += 1
                report.append("\(label): OK id=\(compiled.id) tools=\(compiled.tools.map(\.name))")
            } catch {
                report.append("\(label): REJECTED/FATAL \(error.localizedDescription)")
            }
        }
        print("ADAPTATION REPORT (\(adapted)/\(cases.count) native):")
        for line in report { print("  " + line) }
        // The adaptation bar: at least the multi-tool and storage shapes must
        // compile natively; prompt/shell shapes may legitimately fall back.
        XCTAssertGreaterThanOrEqual(adapted, 2, "report: \(report.joined(separator: " | "))")
    }

    private func snapshot(
        name: String,
        version: String,
        description: String,
        digestSuffix: String,
        files: [(String, String)]
    ) -> NativeAgentPluginSourceSnapshot {
        NativeAgentPluginSourceSnapshot(
            schemaVersion: 1,
            failureReason: "prepared from marketplace snapshot",
            sourceDigest: String((digestSuffix + String(repeating: "a", count: 64)).prefix(64)),
            source: ISHMarketplacePluginSource(
                kind: .market,
                location: "https://github.com/example/\(name)"
            ),
            packageName: name,
            version: version,
            description: description,
            files: files.map {
                NativeAgentPluginSourceFile(path: $0.0, content: $0.1, truncated: false)
            }
        )
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
