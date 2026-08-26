import XCTest
@testable import HarnessMobileCore

final class ShareHandoffTests: XCTestCase {
    func testConsecutiveSharesRemainFIFOAndDoNotOverwrite() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await store.enqueue([.text("A")], now: Date(timeIntervalSince1970: 100))
        let second = try await store.enqueue([.text("B")], now: Date(timeIntervalSince1970: 101))

        let claimAValue = try await store.claimNext(now: Date(timeIntervalSince1970: 102))
        let claimA = try XCTUnwrap(claimAValue)
        XCTAssertEqual(claimA.envelope.id, first)
        XCTAssertEqual(claimA.envelope.items.first?.inlineValue, "A")
        try await store.complete(first, now: Date(timeIntervalSince1970: 102))

        let claimBValue = try await store.claimNext(now: Date(timeIntervalSince1970: 102))
        let claimB = try XCTUnwrap(claimBValue)
        XCTAssertEqual(claimB.envelope.id, second)
        XCTAssertEqual(claimB.envelope.items.first?.inlineValue, "B")
        try await store.complete(second, now: Date(timeIntervalSince1970: 102))
        let noClaim = try await store.claimNext(now: Date(timeIntervalSince1970: 102))
        XCTAssertNil(noClaim)
    }

    func testProcessingClaimSurvivesAForceCloseAndDuplicateAckIsIdempotent() async throws {
        let (writer, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await writer.enqueue([.text("force-close")], now: Date(timeIntervalSince1970: 200))
        let initialClaim = try await writer.claimNext(now: Date(timeIntervalSince1970: 201))
        _ = try XCTUnwrap(initialClaim)

        // A new actor models a new process after the original one was killed.
        let relaunched = ShareHandoffStore(root: root)
        let recoveredValue = try await relaunched.claimNext(now: Date(timeIntervalSince1970: 201))
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.envelope.id, id)
        try await relaunched.complete(id, now: Date(timeIntervalSince1970: 201))
        try await relaunched.complete(id, now: Date(timeIntervalSince1970: 202))
        let noClaim = try await relaunched.claimNext(now: Date(timeIntervalSince1970: 202))
        XCTAssertNil(noClaim)
    }

    func testExpiredShareIsRemovedBeforeClaim() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let createdAt = Date(timeIntervalSince1970: 1_000)
        _ = try await store.enqueue([.text("old")], now: createdAt)
        let noClaim = try await store.claimNext(
            now: createdAt.addingTimeInterval(ShareHandoffStore.handoffTTL + 1)
        )
        XCTAssertNil(noClaim)
    }

    func testItemCountItemBytesTotalBytesAndQueueLimitsAreFailClosed() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await store.enqueue(
                Array(repeating: ShareHandoffDraft.text("x"), count: ShareHandoffStore.maximumItems + 1)
            )
            XCTFail("expected item-count rejection")
        } catch {
            XCTAssertEqual(error as? ShareHandoffError, .tooManyItems(ShareHandoffStore.maximumItems))
        }

        let oversized = Data(repeating: 0x41, count: ShareHandoffStore.maximumItemBytes + 1)
        do {
            _ = try await store.enqueue([
                .attachment(
                    kind: .file,
                    data: oversized,
                    displayName: "oversized.pdf",
                    mimeType: "application/pdf"
                )
            ])
            XCTFail("expected item-size rejection")
        } catch {
            XCTAssertEqual(error as? ShareHandoffError, .itemTooLarge(ShareHandoffStore.maximumItemBytes))
        }

        let totalPart = Data(repeating: 0x41, count: ShareHandoffStore.maximumTotalBytes / 2 + 1)
        do {
            _ = try await store.enqueue([
                .attachment(kind: .file, data: totalPart, displayName: "a.pdf", mimeType: "application/pdf"),
                .attachment(kind: .file, data: totalPart, displayName: "b.pdf", mimeType: "application/pdf")
            ])
            XCTFail("expected total-size rejection")
        } catch {
            XCTAssertEqual(error as? ShareHandoffError, .totalTooLarge(ShareHandoffStore.maximumTotalBytes))
        }

        for index in 0..<ShareHandoffStore.maximumQueuedEnvelopes {
            _ = try await store.enqueue([.text("queue-\(index)")])
        }
        do {
            _ = try await store.enqueue([.text("queue-full")])
            XCTFail("expected queue-full rejection")
        } catch {
            XCTAssertEqual(error as? ShareHandoffError, .queueFull)
        }
    }

    func testWorkspaceAdmissionIsIdempotentAndRollsBackInvalidBatch() async throws {
        let (handoffStore, handoffRoot) = makeStore()
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-share-workspace-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: handoffRoot)
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        let pdf = Data("%PDF-1.7\nshare".utf8)
        _ = try await handoffStore.enqueue([
            .text("read this"),
            .attachment(kind: .file, data: pdf, displayName: "brief.pdf", mimeType: "application/pdf")
        ])
        let claimValue = try await handoffStore.claimNext()
        let claim = try XCTUnwrap(claimValue)
        let workspace = WorkspaceStore(root: workspaceRoot)
        let first = try await workspace.admitShareHandoff(claim, now: Date(timeIntervalSince1970: 500))
        let second = try await workspace.admitShareHandoff(claim, now: Date(timeIntervalSince1970: 501))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.inlineText, "read this")
        let file = try XCTUnwrap(first.fileAttachments.first)
        XCTAssertTrue(file.path.hasSuffix(".pdf"))
        XCTAssertFalse(file.path.contains("item.id"))
        XCTAssertFalse(file.path.contains("admitted.filenameExtension"))
        let admittedData = try await workspace.readFileAttachment(
            file,
            now: Date(timeIntervalSince1970: 501)
        )
        XCTAssertEqual(admittedData, pdf)

        let invalidStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-share-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: invalidStoreRoot) }
        let invalidStore = ShareHandoffStore(root: invalidStoreRoot)
        let invalidID = try await invalidStore.enqueue([
            .attachment(
                kind: .file,
                data: Data("not a pdf".utf8),
                displayName: "bad.pdf",
                mimeType: "application/pdf"
            )
        ])
        let invalidClaimValue = try await invalidStore.claimNext()
        let invalidClaim = try XCTUnwrap(invalidClaimValue)
        do {
            _ = try await workspace.admitShareHandoff(invalidClaim)
            XCTFail("expected invalid attachment rejection")
        } catch {
            // The transaction directory assertion below is the important
            // atomicity check; the concrete admission error is implementation
            // detail shared with normal file-picker validation.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspaceRoot
                    .appendingPathComponent("Attachments/ShareHandoffs/\(invalidID.uuidString.lowercased())")
                    .path
            )
        )
    }

    private func makeStore() -> (ShareHandoffStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-share-\(UUID().uuidString)", isDirectory: true)
        return (ShareHandoffStore(root: root), root)
    }
}
