import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SSEEventDecoderTests: XCTestCase {
    func testMultilineDataAndComments() throws {
        var decoder = SSEEventDecoder()

        XCTAssertNil(try decoder.consume(line: ": heartbeat"))
        XCTAssertNil(try decoder.consume(line: "data: first"))
        XCTAssertNil(try decoder.consume(line: "data:second"))
        XCTAssertEqual(try decoder.consume(line: ""), "first\nsecond")
    }

    func testFlushesFinalEventWithoutTrailingBlankLine() throws {
        var decoder = SSEEventDecoder()
        XCTAssertNil(try decoder.consume(line: "data: [DONE]"))
        XCTAssertEqual(try decoder.finish(), "[DONE]")
        XCTAssertNil(try decoder.finish())
    }

    func testIgnoresUnknownFields() throws {
        var decoder = SSEEventDecoder()
        XCTAssertNil(try decoder.consume(line: "event: message"))
        XCTAssertNil(try decoder.consume(line: "id: 42"))
        XCTAssertNil(try decoder.consume(line: ""))
    }

    func testRejectsOversizedEventBeforeBufferingMoreData() throws {
        var decoder = SSEEventDecoder(maximumEventBytes: 8)
        XCTAssertNil(try decoder.consume(line: "data: 1234"))
        XCTAssertThrowsError(try decoder.consume(line: "data: 5678")) { error in
            XCTAssertEqual(error as? SSEEventDecoderError, .eventTooLarge(8))
        }
    }

    func testByteFramingHandlesCRLFAndArbitraryUnicodeSplits() throws {
        var decoder = SSEEventDecoder()
        let wire = Data("data: {\"text\":\"你好\"}\r\n\r\n".utf8)
        var payload: String?
        for byte in wire {
            payload = try decoder.consume(byte: byte) ?? payload
        }
        XCTAssertEqual(payload, "{\"text\":\"你好\"}")
    }

    func testRejectsOversizedLineBeforeConstructingString() throws {
        var decoder = SSEEventDecoder(maximumLineBytes: 4, maximumEventBytes: 16)
        for byte in Data("data".utf8) {
            XCTAssertNil(try decoder.consume(byte: byte))
        }
        XCTAssertThrowsError(try decoder.consume(byte: UInt8(ascii: ":"))) { error in
            XCTAssertEqual(error as? SSEEventDecoderError, .lineTooLarge(4))
        }
    }
}
