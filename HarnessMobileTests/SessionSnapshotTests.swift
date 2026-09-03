import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the snapshot host contract: normalization hides volatile fields,
/// credentials never enter fixtures, replay detects structural drift, and
/// refresh mode rewrites the fixture. Uses a temporary fixture file so the
/// compatibility fixtures in the repo stay untouched.
final class SessionSnapshotTests: XCTestCase {
    private func makeEvent(_ type: String, seq: UInt64, data: [String: JSONValue]) -> SessionEvent {
        try! SessionEvent(type: type, seq: seq, time: 1_700_000_000_000 + Int64(seq), data: .object(data))
    }

    private func scenarioEvents() -> [SessionEvent] {
        [
            makeEvent("turnStart", seq: 1, data: ["turn": .number(1)]),
            makeEvent("toolCall", seq: 2, data: [
                "name": .string("schedule.create"),
                "arguments": .object(["label": .string("早班提醒"), "runAt": .string("2026-09-04T06:00:00+08:00")])
            ]),
            makeEvent("toolResult", seq: 3, data: [
                "content": .string("已创建 id sk-demo1234567890"),
                "runId": .string(UUID().uuidString)
            ]),
            makeEvent("turnEnd", seq: 4, data: ["reason": .string("completed")])
        ]
    }

    func testNormalizationHidesVolatileFieldsAndCredentials() throws {
        let normalized = SessionSnapshot.normalizedEvent(scenarioEvents()[2])
        let object = try XCTUnwrap(normalized.objectValue)
        let data = try XCTUnwrap(object["data"]?.objectValue)
        let content = try XCTUnwrap(data["content"]?.stringValue)
        XCTAssertTrue(content.contains("[credential-shaped text removed]"))
        let runID = try XCTUnwrap(data["runId"]?.stringValue)
        XCTAssertEqual(runID, "<uuid>")
    }

    func testReplayPassesForIdenticalShapeAndFailsOnDrift() throws {
        let events = scenarioEvents()
        let fixture = try SessionSnapshot.fixtureData(scenario: "schedule-flow", events: events)
        // Same shape (different seq/time/uuid) replays clean.
        XCTAssertNil(try SessionSnapshot.replay(fixture: fixture, against: scenarioEvents()))

        // Structural drift: a new event breaks replay with a precise message.
        var drifted = scenarioEvents()
        drifted.append(makeEvent("toolCall", seq: 9, data: ["name": .string("extra")]))
        let mismatch = try SessionSnapshot.replay(fixture: fixture, against: drifted)
        XCTAssertEqual(mismatch, "event count mismatch: recorded 4, fresh 5")
    }

    func testContentChangeIsReportedWithIndex() throws {
        let events = scenarioEvents()
        let fixture = try SessionSnapshot.fixtureData(scenario: "schedule-flow", events: events)
        var changed = scenarioEvents()
        changed[1] = makeEvent("toolCall", seq: 2, data: [
            "name": .string("schedule.list"),
            "arguments": .object(["label": .string("早班提醒")])
        ])
        let mismatch = try SessionSnapshot.replay(fixture: fixture, against: changed)
        let expected = try XCTUnwrap(mismatch)
        XCTAssertTrue(expected.hasPrefix("event 1 mismatch"))
    }

    func testLoadOrRefreshWritesMissingFixtureAndReplaysAfterwards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("schedule-flow.json")

        let events = scenarioEvents()
        let first = try SessionSnapshot.loadOrRefreshFixture(fixtureURL: fixtureURL, scenario: "schedule-flow", events: events)
        XCTAssertTrue(first.refreshed, "a missing fixture is written (record path)")

        let second = try SessionSnapshot.loadOrRefreshFixture(fixtureURL: fixtureURL, scenario: "schedule-flow", events: events)
        XCTAssertFalse(second.refreshed)
        XCTAssertNil(try SessionSnapshot.replay(fixture: second.fixture, against: events))
    }
}
