import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class TurnAccumulatorTests: XCTestCase {
    func testReasoningSignatureAccumulatesForReplay() throws {
        var accumulator = TurnAccumulator()
        try accumulator.appendReasoning("plan")
        try accumulator.appendReasoningSignature("sig-")
        try accumulator.appendReasoningSignature("123")
        XCTAssertEqual(accumulator.reasoning, "plan")
        XCTAssertEqual(accumulator.reasoningSignature, "sig-123")
    }

    func testInterleavedToolCallDeltasPreserveIndexOrder() throws {
        var accumulator = TurnAccumulator()
        try accumulator.appendToolCall(
            index: 1,
            id: "call-b",
            type: "function",
            name: "second",
            arguments: "{\"b\":"
        )
        try accumulator.appendToolCall(
            index: 0,
            id: "call-a",
            type: "function",
            name: "first",
            arguments: "{\"a\":"
        )
        try accumulator.appendToolCall(
            index: 1, id: nil, type: nil, name: nil, arguments: "2}"
        )
        try accumulator.appendToolCall(
            index: 0, id: nil, type: nil, name: nil, arguments: "1}"
        )

        let calls = try accumulator.completedToolCalls()
        XCTAssertEqual(calls.map(\.id), ["call-a", "call-b"])
        XCTAssertEqual(calls.map(\.arguments), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testConflictingIdentityIsRejected() throws {
        var accumulator = TurnAccumulator()
        try accumulator.appendToolCall(
            index: 0,
            id: "first-id",
            type: "function",
            name: "tool",
            arguments: ""
        )

        XCTAssertThrowsError(
            try accumulator.appendToolCall(
                index: 0,
                id: "different-id",
                type: nil,
                name: nil,
                arguments: ""
            )
        )
    }
}
