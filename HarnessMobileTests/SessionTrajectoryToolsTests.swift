import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionTrajectoryToolsTests: XCTestCase {
    func testTraceIsPaginatedAndRedactsCredentialShapedFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        _ = try await repository.append(
            SessionEventDraft(
                type: SessionEventVocabulary.toolResult,
                time: 1,
                data: .object([
                    "apiKey": .string("sk-secret-value-123456"),
                    "message": .string("first")
                ])
            ),
            sessionID: sessionID
        )
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, time: 2, data: .string("second")),
            sessionID: sessionID
        )

        let tool = SessionTraceTool(repository: repository, sessionID: sessionID.uuidString)
        let first = try await tool.execute(arguments: ["limit": .number(1)])
        XCTAssertTrue(first.contains("<redacted>"))
        XCTAssertTrue(first.contains("has_more"))
        let firstValue = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(first.utf8)).objectValue)
        let cursor = try XCTUnwrap(firstValue["next_cursor"]?.stringValue)
        let second = try await tool.execute(arguments: ["cursor": .string(cursor), "limit": .number(1)])
        XCTAssertTrue(second.contains("second"))
        XCTAssertFalse(second.contains("first"))
    }

    func testSearchAndPointLookupShareTheDurableSequence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, time: 1, data: .string("needle here")),
            sessionID: sessionID
        )
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.assistantMessage, time: 2, data: .string("other")),
            sessionID: sessionID
        )

        let search = SessionSearchTool(repository: repository, sessionID: sessionID.uuidString)
        let result = try await search.execute(arguments: ["query": .string("needle")])
        XCTAssertTrue(result.contains("needle here"))
        XCTAssertTrue(result.contains("\"seq\":0"))

        let get = SessionEventGetTool(repository: repository, sessionID: sessionID.uuidString)
        let event = try await get.execute(arguments: ["seq": .number(1)])
        XCTAssertTrue(event.contains("\"found\":true"))
        XCTAssertTrue(event.contains(SessionEventVocabulary.assistantMessage))

        let types = SessionEventTypesTool(repository: repository, sessionID: sessionID.uuidString)
        let counts = try await types.execute(arguments: [:])
        XCTAssertTrue(counts.contains(SessionEventVocabulary.userMessage))
        XCTAssertTrue(counts.contains(SessionEventVocabulary.assistantMessage))
    }

    func testCursorCannotBeReusedAcrossSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let firstID = UUID()
        let secondID = UUID()
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, time: 1, data: .string("first")),
            sessionID: firstID
        )
        let firstTool = SessionTraceTool(repository: repository, sessionID: firstID.uuidString)
        let firstPage = try await firstTool.execute(arguments: ["limit": .number(1)])
        let firstValue = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(firstPage.utf8)).objectValue)
        let cursor = try XCTUnwrap(firstValue["next_cursor"]?.stringValue)

        let secondTool = SessionTraceTool(repository: repository, sessionID: secondID.uuidString)
        do {
            _ = try await secondTool.execute(arguments: ["cursor": .string(cursor)])
            XCTFail("A cursor must be bound to its originating session")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }
    }

    func testTraceTypesFilterPreservesMatchingEventPagination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, time: 1, data: .string("user one")),
            sessionID: sessionID
        )
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.toolResult, time: 2, data: .string("tool one")),
            sessionID: sessionID
        )
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, time: 3, data: .string("user two")),
            sessionID: sessionID
        )

        let tool = SessionTraceTool(repository: repository, sessionID: sessionID.uuidString)
        let first = try await tool.execute(arguments: [
            "types": .array([.string(SessionEventVocabulary.userMessage)]),
            "limit": .number(1)
        ])
        let firstValue = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(first.utf8)).objectValue)
        let firstEvents: [JSONValue]
        guard case let .array(events) = firstValue["events"] else {
            return XCTFail("trace response must contain an events array")
        }
        firstEvents = events
        XCTAssertEqual(firstEvents.count, 1)
        XCTAssertEqual(firstEvents.first?.objectValue?["type"]?.stringValue, SessionEventVocabulary.userMessage)
        let cursor = try XCTUnwrap(firstValue["next_cursor"]?.stringValue)

        let second = try await tool.execute(arguments: [
            "types": .array([.string(SessionEventVocabulary.userMessage)]),
            "cursor": .string(cursor),
            "limit": .number(1)
        ])
        let secondValue = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(second.utf8)).objectValue)
        let secondEvents: [JSONValue]
        guard case let .array(events) = secondValue["events"] else {
            return XCTFail("trace response must contain an events array")
        }
        secondEvents = events
        XCTAssertEqual(secondEvents.count, 1)
        XCTAssertEqual(secondEvents.first?.objectValue?["data"]?.stringValue, "user two")
    }

    func testTrajectoryToolsRejectMalformedArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID().uuidString
        let trace = SessionTraceTool(repository: repository, sessionID: sessionID)
        let search = SessionSearchTool(repository: repository, sessionID: sessionID)
        let get = SessionEventGetTool(repository: repository, sessionID: sessionID)

        do {
            _ = try await trace.execute(arguments: ["limit": .number(0)])
            XCTFail("zero is outside the supported page limit")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }
        do {
            _ = try await search.execute(arguments: ["query": .string("   ")])
            XCTFail("blank search queries must be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }
        do {
            _ = try await get.execute(arguments: ["seq": .number(-1)])
            XCTFail("negative sequence numbers must be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }
    }
}
