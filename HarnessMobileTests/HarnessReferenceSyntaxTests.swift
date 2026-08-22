import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessReferenceSyntaxTests: XCTestCase {
    func testReferenceDirectoryClassifiesSearchesDeduplicatesAndFiltersCurrentSession() {
        let current = UUID()
        let other = UUID()
        let candidates = [
            HarnessReferenceCandidate(
                source: .session,
                identity: current.uuidString,
                label: "Current",
                detail: nil,
                searchableText: current.uuidString,
                sessionID: current
            ),
            HarnessReferenceCandidate(
                source: .file,
                identity: "Docs/Plan.md",
                label: "Docs/Plan.md",
                detail: "file",
                searchableText: "Docs Plan",
                sessionID: nil
            ),
            HarnessReferenceCandidate(
                source: .session,
                identity: other.uuidString,
                label: "Plan review",
                detail: nil,
                searchableText: other.uuidString,
                sessionID: other
            ),
            HarnessReferenceCandidate(
                source: .plugin,
                identity: "plan-helper",
                label: "plan-helper",
                detail: "plugin",
                searchableText: "plan helper",
                sessionID: nil
            ),
            HarnessReferenceCandidate(
                source: .plugin,
                identity: "plan-helper",
                label: "duplicate",
                detail: nil,
                searchableText: "plan",
                sessionID: nil
            )
        ]
        let matched = HarnessReferenceDirectory.search(
            candidates,
            query: "plan",
            currentSessionID: current
        )
        XCTAssertEqual(matched.map(\.source), [.file, .session, .plugin])
        XCTAssertEqual(matched.filter { $0.source == .plugin }.count, 1)
        XCTAssertFalse(matched.contains { $0.sessionID == current })
        XCTAssertEqual(
            HarnessReferenceDirectory.grouped(matched).map(\.source),
            [.file, .session, .plugin]
        )
        XCTAssertEqual(
            HarnessReferenceDirectory.availableSources(candidates, currentSessionID: current),
            [.file, .session, .plugin]
        )
    }

    func testReferenceDirectoryFiltersByOneOrSeveralSourceCategories() {
        let candidates = [
            HarnessReferenceCandidate(
                source: .file,
                identity: "README.md",
                label: "README.md",
                detail: nil,
                searchableText: "README",
                sessionID: nil
            ),
            HarnessReferenceCandidate(
                source: .session,
                identity: "session-1",
                label: "Release review",
                detail: nil,
                searchableText: "release review",
                sessionID: nil
            ),
            HarnessReferenceCandidate(
                source: .skill,
                identity: "review",
                label: "review",
                detail: "Review changes",
                searchableText: "review changes",
                sessionID: nil
            ),
            HarnessReferenceCandidate(
                source: .subagent,
                identity: "child-1",
                label: "child-1",
                detail: "running",
                searchableText: "child-1 running",
                sessionID: nil
            )
        ]

        let skills = HarnessReferenceDirectory.search(
            candidates,
            query: "review",
            currentSessionID: nil,
            sourceFilter: .only(.skill)
        )
        XCTAssertEqual(skills.map(\.source), [.skill])
        XCTAssertEqual(skills.first?.identity, "review")

        let fileAndSession = HarnessReferenceDirectory.grouped(
            candidates,
            sourceFilter: .included([.file, .session])
        )
        XCTAssertEqual(fileAndSession.map(\.source), [.file, .session])
        XCTAssertEqual(fileAndSession.flatMap(\.candidates).count, 2)

        XCTAssertTrue(
            HarnessReferenceDirectory.search(
                candidates,
                query: "review",
                currentSessionID: nil,
                sourceFilter: .included([.file, .subagent])
            ).isEmpty
        )

        let qualified = HarnessReferenceDirectory.search(
            candidates,
            query: "skill:review",
            currentSessionID: nil
        )
        XCTAssertEqual(qualified.map(\.source), [.skill])
        XCTAssertEqual(qualified.first?.label, "review")

        let ordinaryColonText = HarnessReferenceDirectory.search(
            candidates,
            query: "release:review",
            currentSessionID: nil
        )
        XCTAssertTrue(ordinaryColonText.isEmpty)
    }

    func testReferenceSourceMetadataIsStableAndLocalized() {
        XCTAssertEqual(HarnessReferenceSource.allCases.map(\.title), [
            "文件", "历史会话", "子 Agent", "Skill", "插件"
        ])
        XCTAssertEqual(HarnessReferenceSource.file.systemImage, "doc.text")
        XCTAssertEqual(HarnessReferenceSource.session.systemImage, "clock.arrow.circlepath")
        XCTAssertEqual(HarnessReferenceSource.subagent.systemImage, "person.crop.circle.badge.checkmark")
        XCTAssertEqual(HarnessReferenceSource.skill.systemImage, "wand.and.stars")
        XCTAssertEqual(HarnessReferenceSource.plugin.systemImage, "puzzlepiece.extension")
    }

    func testFileMentionUsesOfficialQuotedGrammarWithoutInjectingContent() {
        XCTAssertEqual(
            HarnessReferenceSyntax.formatFileMention(path: "Docs/report.md"),
            "@Docs/report.md"
        )
        XCTAssertEqual(
            HarnessReferenceSyntax.formatFileMention(path: "Docs/deep report.md"),
            "@\"Docs/deep report.md\""
        )
        XCTAssertEqual(
            HarnessReferenceSyntax.formatFileMention(path: "Docs", isDirectory: true),
            "@Docs/"
        )
        XCTAssertEqual(
            HarnessReferenceSyntax.formatFileMention(
                path: "Deep Reports",
                isDirectory: true
            ),
            "@\"Deep Reports/"
        )
        XCTAssertNil(HarnessReferenceSyntax.formatFileMention(path: "bad\"name.md"))
        XCTAssertNil(HarnessReferenceSyntax.formatFileMention(path: "bad\nname.md"))
    }

    func testSessionMentionRoundTripsCanonicalURIAndReadableLabel() throws {
        let id = UUID(uuidString: "4D16E270-86A5-49D5-9127-88C04010722B")!
        let mention = HarnessReferenceSyntax.formatSessionMention(
            sessionID: id,
            label: "历史]记录"
        )
        let parsed = try HarnessReferenceSyntax.parseSessionReferences(
            in: "参考 \(mention) 继续"
        )

        XCTAssertEqual(parsed.renderedText, "参考 @历史]记录 继续")
        XCTAssertEqual(
            parsed.references,
            [HarnessSessionReference(sessionID: id, label: "历史]记录")]
        )
        XCTAssertEqual(
            try HarnessReferenceSyntax.decodeSessionURI(
                HarnessReferenceSyntax.encodeSessionURI(id)
            ),
            id
        )
        XCTAssertThrowsError(
            try HarnessReferenceSyntax.decodeSessionURI(
                HarnessReferenceSyntax.encodeSessionURI(id) + "="
            )
        )
    }

    func testLegacySessionMentionMigratesAndNormalizationRejectsUnsafeSets() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let parsed = try HarnessReferenceSyntax.parseSessionReferences(
            in: "@session:\(first.uuidString)"
        )
        XCTAssertEqual(parsed.references.first?.sessionID, first)

        XCTAssertEqual(
            try HarnessReferenceSyntax.normalizeSessionReferences(
                [
                    HarnessSessionReference(sessionID: first, label: "one"),
                    HarnessSessionReference(sessionID: first, label: "duplicate"),
                    HarnessSessionReference(sessionID: second, label: "two")
                ],
                currentSessionID: nil
            ).map(\.sessionID),
            [first, second]
        )
        XCTAssertThrowsError(
            try HarnessReferenceSyntax.normalizeSessionReferences(
                [HarnessSessionReference(sessionID: first, label: "self")],
                currentSessionID: first
            )
        ) { error in
            XCTAssertEqual(error as? HarnessReferenceError, .selfReference(first))
        }
        XCTAssertThrowsError(
            try HarnessReferenceSyntax.normalizeSessionReferences(
                [first, second, third, fourth].map {
                    HarnessSessionReference(sessionID: $0, label: $0.uuidString)
                },
                currentSessionID: nil
            )
        ) { error in
            XCTAssertEqual(error as? HarnessReferenceError, .tooManySessions(maximum: 3))
        }
    }

    func testSnapshotExcludesToolsReasoningAndInjectedContextButKeepsCheckpoint() throws {
        let id = UUID()
        let checkpoint = AgentMessage(
            role: .user,
            content: "checkpoint <summary>",
            source: .object([
                "kind": .string("plugin"),
                "plugin": .string("dsh-compaction-basic")
            ])
        )
        let session = makeSession(
            id: id,
            messages: [
                AgentMessage.user("direct <script>"),
                AgentMessage(
                    role: .user,
                    content: "injected-secret",
                    source: .object(["kind": .string("session-reference")])
                ),
                AgentMessage.assistant("visible answer", reasoning: "hidden-reasoning"),
                .tool(callID: "call-1", name: "shell", content: "tool-secret"),
                checkpoint
            ]
        )

        let prepared = try HarnessSessionReferenceSnapshotBuilder.prepare(
            session: session,
            label: "source"
        )
        let encoded = HarnessSessionReferenceSnapshotBuilder.tagSafeJSONString(prepared.data)

        XCTAssertTrue(encoded.contains("direct \\u003cscript>"))
        XCTAssertTrue(encoded.contains("checkpoint \\u003csummary>"))
        XCTAssertTrue(encoded.contains("visible answer"))
        XCTAssertFalse(encoded.contains("injected-secret"))
        XCTAssertFalse(encoded.contains("hidden-reasoning"))
        XCTAssertFalse(encoded.contains("tool-secret"))
        XCTAssertFalse(encoded.contains("<script"))
        XCTAssertTrue(prepared.stats.compacted)
        XCTAssertEqual(prepared.stats.originalMessages, 3)

        let prompt = HarnessSessionReferenceSnapshotBuilder.prompt(for: [prepared])
        XCTAssertTrue(prompt.contains("<referenced-sessions>"))
        XCTAssertTrue(prompt.contains("untrusted, read-only snapshot"))
    }

    func testSnapshotRetentionStaysWithinExactUTF8Budget() throws {
        let session = makeSession(
            id: UUID(),
            messages: (0..<8).flatMap { index in
                [
                    AgentMessage.user("user-\(index)-" + String(repeating: "中", count: 400)),
                    AgentMessage.assistant("assistant-\(index)-" + String(repeating: "文", count: 400))
                ]
            }
        )
        let maximumBytes = 1_024
        let prepared = try HarnessSessionReferenceSnapshotBuilder.prepare(
            session: session,
            label: "bounded",
            maximumBytes: maximumBytes
        )
        let encoded = HarnessSessionReferenceSnapshotBuilder.tagSafeJSONString(prepared.data)

        XCTAssertLessThanOrEqual(encoded.utf8.count, maximumBytes)
        XCTAssertTrue(prepared.stats.truncated)
        XCTAssertGreaterThan(prepared.stats.omittedMessages + prepared.stats.omittedBytes, 0)
    }

    private func makeSession(id: UUID, messages: [AgentMessage]) -> ConversationSession {
        ConversationSession(
            id: id,
            title: "Reference source",
            messages: messages,
            workState: ConversationWorkState(),
            controlState: ConversationControlState(),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            revision: 1
        )
    }
}
