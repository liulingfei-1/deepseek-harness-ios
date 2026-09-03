import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the workflow-run tree contract against the durable
/// `tool-workflow/*` session events: one foldable run per `run-start`,
/// members in sequence order with outcome/timing, and resilience to
/// malformed payloads.
final class WorkflowRunTreeTests: XCTestCase {
    private func event(
        _ type: String,
        seq: UInt64,
        data: [String: JSONValue]
    ) -> SessionEvent {
        try! SessionEvent(type: type, seq: seq, time: 1_700_000_000_000, data: .object(data))
    }

    private func runStart(_ runID: String, name: String, seq: UInt64) -> SessionEvent {
        event(WorkflowRunTree.runStartType, seq: seq, data: ["runId": .string(runID), "name": .string(name)])
    }

    private func agentStart(
        _ runID: String,
        sequence: Int,
        label: String,
        childID: String,
        parentID: String?,
        depth: Int,
        seq: UInt64
    ) -> SessionEvent {
        var data: [String: JSONValue] = [
            "runId": .string(runID),
            "sequence": .number(Double(sequence)),
            "label": .string(label),
            "childId": .string(childID),
            "depth": .number(Double(depth))
        ]
        if let parentID { data["parentId"] = .string(parentID) }
        return event(WorkflowRunTree.agentStartType, seq: seq, data: data)
    }

    private func agentEnd(_ runID: String, sequence: Int, outcome: String, seq: UInt64) -> SessionEvent {
        event(WorkflowRunTree.agentEndType, seq: seq, data: [
            "runId": .string(runID),
            "sequence": .number(Double(sequence)),
            "outcome": .string(outcome)
        ])
    }

    func testBuildsFoldableRunsWithMembersAndOutcomes() {
        let events = [
            runStart("r1", name: "项目摘要", seq: 1),
            agentStart("r1", sequence: 0, label: "研究员", childID: "c0", parentID: nil, depth: 0, seq: 2),
            agentStart("r1", sequence: 1, label: "分析员", childID: "c1", parentID: "c0", depth: 1, seq: 3),
            agentEnd("r1", sequence: 1, outcome: "success", seq: 4),
            agentEnd("r1", sequence: 0, outcome: "error", seq: 5),
            event(WorkflowRunTree.runEndType, seq: 6, data: ["runId": .string("r1"), "stopReason": .string("completed")])
        ]
        let tree = WorkflowRunTree.build(from: events)
        XCTAssertEqual(tree.runCount, 1)
        let run = tree.runs[0]
        XCTAssertEqual(run.name, "项目摘要")
        XCTAssertEqual(run.stopReason, "completed")
        XCTAssertEqual(run.memberCount, 2)
        XCTAssertEqual(run.members[0].childID, "c0")
        XCTAssertEqual(run.members[1].parentID, "c0")
        XCTAssertEqual(run.members[1].depth, 1)
        XCTAssertTrue(run.members[1].isSucceeded)
        XCTAssertTrue(run.members[0].isFailed)
        XCTAssertEqual(run.failedCount, 1)
        XCTAssertEqual(tree.failedMemberCount, 1)
    }

    func testTwoRunsKeepOrderAndCounts() {
        let events = [
            runStart("a", name: "A", seq: 1),
            runStart("b", name: "B", seq: 2),
            agentStart("a", sequence: 0, label: "x", childID: "x1", parentID: nil, depth: 0, seq: 3),
            agentStart("b", sequence: 0, label: "y", childID: "y1", parentID: nil, depth: 0, seq: 4)
        ]
        let tree = WorkflowRunTree.build(from: events)
        XCTAssertEqual(tree.runs.map(\.runID), ["a", "b"])
        XCTAssertEqual(tree.memberCount, 2)
    }

    func testMalformedPayloadsAreSkippedNotFatal() {
        let events = [
            runStart("r1", name: "ok", seq: 1),
            event(WorkflowRunTree.agentStartType, seq: 2, data: ["runId": .string("missing-member")]),
            event(WorkflowRunTree.agentEndType, seq: 3, data: ["runId": .string("r1"), "sequence": .number(99)]),
            event(WorkflowRunTree.runEndType, seq: 4, data: [:])
        ]
        let tree = WorkflowRunTree.build(from: events)
        XCTAssertEqual(tree.runCount, 1)
        XCTAssertEqual(tree.runs[0].members.count, 0)
        XCTAssertNil(tree.runs[0].stopReason)
    }
}
