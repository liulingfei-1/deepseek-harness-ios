import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ContinuedProcessingStateMachineTests: XCTestCase {
    func testIdentifiersNormalizeWildcardAndCreateUniqueRequestSuffixes() throws {
        let identifiers = try ContinuedProcessingIdentifiers(
            prefix: "com.example.HarnessMobile.continued-processing.*"
        )
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(identifiers.prefix, "com.example.HarnessMobile.continued-processing")
        XCTAssertEqual(identifiers.permittedIdentifier, "com.example.HarnessMobile.continued-processing.*")
        XCTAssertEqual(
            identifiers.requestIdentifier(for: first),
            identifiers.prefix + "." + first.uuidString.lowercased()
        )
        XCTAssertNotEqual(
            identifiers.requestIdentifier(for: first),
            identifiers.requestIdentifier(for: second)
        )
    }

    func testAttachPublishesRealCurrentStatus() throws {
        let fixture = try makeFixture()
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))

        let effects = machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier)

        XCTAssertEqual(
            effects,
            [.updateSystemTask(fixture.descriptor.status), .startWorker]
        )
        XCTAssertEqual(machine.currentRun?.isSystemTaskAttached, true)
    }

    func testReportUpdatesAttachedSystemTaskAndIsIgnoredAfterFinish() throws {
        let fixture = try makeFixture()
        let updated = try ContinuedProcessingStatus(
            title: "Indexing workspace",
            subtitle: "18 of 20 files",
            completedUnitCount: 18,
            totalUnitCount: 20
        )
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))
        _ = machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier)

        XCTAssertEqual(
            machine.report(runID: fixture.descriptor.id, status: updated),
            [.updateSystemTask(updated)]
        )
        XCTAssertEqual(
            machine.finish(runID: fixture.descriptor.id, success: true),
            [.completeSystemTask(success: true)]
        )
        XCTAssertEqual(machine.report(runID: fixture.descriptor.id, status: fixture.descriptor.status), [])
    }

    func testFinishAttachedTaskIsIdempotent() throws {
        let fixture = try makeFixture()
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))
        _ = machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier)

        XCTAssertEqual(
            machine.finish(runID: fixture.descriptor.id, success: true),
            [.completeSystemTask(success: true)]
        )
        XCTAssertEqual(machine.finish(runID: fixture.descriptor.id, success: true), [])
        XCTAssertEqual(machine.cancel(runID: fixture.descriptor.id, reason: .user), [])
        XCTAssertEqual(machine.currentRun?.isSystemTaskCompleted, true)
    }

    func testCancelInvokesCallbackAndCompletesAttachedTaskExactlyOnce() throws {
        let fixture = try makeFixture()
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))
        _ = machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier)

        XCTAssertEqual(
            machine.cancel(runID: fixture.descriptor.id, reason: .systemExpiration),
            [
                .invokeCancellation(.systemExpiration),
                .completeSystemTask(success: false)
            ]
        )
        XCTAssertEqual(machine.cancel(runID: fixture.descriptor.id, reason: .systemExpiration), [])
        XCTAssertEqual(machine.finish(runID: fixture.descriptor.id, success: false), [])
        XCTAssertEqual(machine.currentRun?.isCancellationCallbackDelivered, true)
    }

    func testTerminalRunBeforeAttachmentCancelsPendingRequest() throws {
        let fixture = try makeFixture()
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))

        XCTAssertEqual(
            machine.finish(runID: fixture.descriptor.id, success: true),
            [.cancelPendingRequest(identifier: fixture.descriptor.requestIdentifier)]
        )

        XCTAssertEqual(
            machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier),
            [.completeSystemTask(success: true)]
        )
    }

    func testCancelBeforeAttachmentCancelsPendingRequestAndLateTaskFails() throws {
        let fixture = try makeFixture()
        var machine = ContinuedProcessingStateMachine()
        XCTAssertTrue(machine.begin(fixture.descriptor))

        XCTAssertEqual(
            machine.cancel(runID: fixture.descriptor.id, reason: .user),
            [
                .invokeCancellation(.user),
                .cancelPendingRequest(identifier: fixture.descriptor.requestIdentifier)
            ]
        )
        XCTAssertEqual(
            machine.attachSystemTask(identifier: fixture.descriptor.requestIdentifier),
            [.completeSystemTask(success: false)]
        )
    }

    func testRejectsConcurrentRunAndIgnoresMismatchedTask() throws {
        let fixture = try makeFixture()
        let second = try makeFixture()
        var machine = ContinuedProcessingStateMachine()

        XCTAssertTrue(machine.begin(fixture.descriptor))
        XCTAssertFalse(machine.begin(second.descriptor))
        XCTAssertFalse(machine.canAttachSystemTask(identifier: second.descriptor.requestIdentifier))
        XCTAssertEqual(machine.attachSystemTask(identifier: second.descriptor.requestIdentifier), [])
        XCTAssertEqual(machine.currentRun?.descriptor.id, fixture.descriptor.id)
    }

    func testStatusRejectsInvalidProgress() {
        XCTAssertThrowsError(
            try ContinuedProcessingStatus(
                title: "Invalid",
                subtitle: "Progress",
                completedUnitCount: 2,
                totalUnitCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ContinuedProcessingValidationError, .invalidProgress)
        }
    }

    private func makeFixture() throws -> (descriptor: ContinuedProcessingRunDescriptor, prefix: String) {
        let prefix = "com.example.HarnessMobile.continued-processing"
        let id = UUID()
        let status = try ContinuedProcessingStatus(
            title: "Processing workspace",
            subtitle: "0 of 20 files",
            completedUnitCount: 0,
            totalUnitCount: 20
        )
        return (
            ContinuedProcessingRunDescriptor(
                id: id,
                requestIdentifier: prefix + "." + id.uuidString.lowercased(),
                status: status
            ),
            prefix
        )
    }
}
