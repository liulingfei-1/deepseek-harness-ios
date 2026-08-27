import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessSyncEnvelopeTests: XCTestCase {
    func testConcurrentDeviceSuffixesRemainOrderedAndUnknownEventFieldsRoundTrip() throws {
        let first = try event(seq: 11, type: "future/plugin-event", data: .object(["new_field": .string("kept")]))
        let second = try event(seq: 12, type: SessionEventVocabulary.userMessage, data: .object(["body": .string("hello")]))
        let envelope = try HarnessSyncEnvelope(
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            baseSequence: 10,
            events: [first, second],
            metadata: ["device": "A"]
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(HarnessSyncEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.events.map(\.seq), [11, 12])
        XCTAssertEqual(decoded.events[0].data.objectValue?["new_field"]?.stringValue, "kept")
    }

    func testSuffixRejectsReorderingGapsAndCredentialFields() throws {
        let one = try event(seq: 2, type: "future/event", data: .object(["ok": .bool(true)]))
        let three = try event(seq: 4, type: "future/event", data: .object(["ok": .bool(true)]))
        XCTAssertThrowsError(try HarnessSyncEnvelope(sessionID: UUID(), baseSequence: 1, events: [three])) { error in
            XCTAssertEqual(error as? HarnessSyncEnvelopeError, .nonContiguousSuffix)
        }
        XCTAssertThrowsError(try HarnessSyncEnvelope(sessionID: UUID(), baseSequence: 1, events: [three, one])) { error in
            XCTAssertEqual(error as? HarnessSyncEnvelopeError, .nonContiguousSuffix)
        }

        let secret = try event(seq: 2, type: "future/event", data: .object(["api_key": .string("secret-canary")]))
        XCTAssertThrowsError(try HarnessSyncEnvelope(sessionID: UUID(), baseSequence: 1, events: [secret])) { error in
            XCTAssertEqual(error as? HarnessSyncEnvelopeError, .secretField)
        }
    }

    func testTombstonesAssetsAndMetadataAreBoundedAndExplicit() throws {
        let event = try event(seq: 1, type: "future/event", data: .object(["ok": .bool(true)]))
        let asset = try HarnessSyncAssetReference(key: "image", relativePath: "attachments/a.png", byteCount: 12, mimeType: "image/png")
        let tombstone = try HarnessSyncTombstone(eventID: 1, deletedAt: 100)
        let envelope = try HarnessSyncEnvelope(
            sessionID: UUID(), baseSequence: 0, events: [event],
            metadata: ["source": "device-a"], assets: [asset], tombstones: [tombstone]
        )
        XCTAssertEqual(envelope.assets, [asset])
        XCTAssertEqual(envelope.tombstones, [tombstone])
        XCTAssertThrowsError(try HarnessSyncAssetReference(key: "x", relativePath: "../escape", byteCount: 1))
        XCTAssertThrowsError(try HarnessSyncTombstone(eventID: 0, deletedAt: 1))
    }

    private func event(seq: UInt64, type: String, data: JSONValue) throws -> SessionEvent {
        try SessionEvent(type: type, seq: seq, time: 1, data: data)
    }
}
