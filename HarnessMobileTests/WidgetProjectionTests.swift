import XCTest
@testable import HarnessMobileCore

final class WidgetProjectionTests: XCTestCase {
    func testProjectionKeepsOnlyLiveRunsAndSortsByStableSessionIdentity() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let projection = HarnessWidgetProjectionStore.make(
            snapshots: [
                HarnessWidgetRunSnapshotInput(
                    sessionID: second,
                    runID: UUID(),
                    phase: .terminal,
                    queuedInputCount: 9
                ),
                HarnessWidgetRunSnapshotInput(
                    sessionID: second,
                    runID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                    phase: .cancelling,
                    queuedInputCount: 2
                ),
                HarnessWidgetRunSnapshotInput(
                    sessionID: first,
                    runID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    phase: .running,
                    queuedInputCount: 1
                ),
                HarnessWidgetRunSnapshotInput(
                    sessionID: UUID(),
                    runID: UUID(),
                    phase: .idle,
                    queuedInputCount: 0
                )
            ],
            privacyModeEnabled: false,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(projection.activeRunCount, 2)
        XCTAssertEqual(projection.sessions.map(\.id), [first, second])
        XCTAssertEqual(projection.sessions.map(\.queuedInputCount), [1, 2])
        XCTAssertEqual(projection.updatedAt, Date(timeIntervalSince1970: 100))
    }

    func testPrivacyProjectionIsRoundTripCodableWithoutPromptOrToolFields() throws {
        let projection = HarnessWidgetProjection(
            activeRunCount: 1,
            privacyModeEnabled: true,
            sessions: []
        )
        let data = try JSONEncoder().encode(projection)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("prompt"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("args"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("output"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("environment"))
        XCTAssertEqual(try JSONDecoder().decode(HarnessWidgetProjection.self, from: data), projection)
    }

    func testDeepLinkRoundTripsExactSessionAndRejectsExtraComponents() throws {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let url = HarnessWidgetProjectionStore.deepLink(for: id)
        XCTAssertEqual(url.absoluteString, "harnessmobile://session/01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(HarnessWidgetProjectionStore.sessionID(from: url), id)
        XCTAssertNil(
            HarnessWidgetProjectionStore.sessionID(
                from: URL(string: "harnessmobile://session/\(id.uuidString)?prompt=secret")!
            )
        )
        XCTAssertNil(
            HarnessWidgetProjectionStore.sessionID(
                from: URL(string: "harnessmobile://session/\(id.uuidString)/extra")!
            )
        )
    }
}
