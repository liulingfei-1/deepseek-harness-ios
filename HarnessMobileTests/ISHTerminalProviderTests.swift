import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHTerminalProviderTests: XCTestCase {
    func testProviderCoversOpenReadSendSignalListAndCloseWithOwnerIsolation() async throws {
        let backend = TestTerminalBackend()
        let provider = makeProvider(backend: backend)

        let opened = try await provider.open(
            ownerSession: " agent-a ",
            type: "ish-shell",
            name: "build",
            cwd: "/workspace"
        )
        XCTAssertEqual(opened.snapshot.ownerSession, "agent-a")
        XCTAssertEqual(opened.snapshot.status, .running)

        let listed = await provider.list(ownerSession: "agent-a")
        XCTAssertEqual(listed.map(\.sessionID), [opened.snapshot.sessionID])

        let sent = try await provider.send(
            ownerSession: " agent-a ",
            sessionID: opened.snapshot.sessionID,
            text: "echo hello",
            submit: true
        )
        XCTAssertEqual(sent.sessionStatus, .running)
        let writes = await backend.writes()
        XCTAssertEqual(writes, ["echo hello\n"])

        let read = try await provider.read(
            ownerSession: "agent-a",
            sessionID: opened.snapshot.sessionID,
            offset: 0,
            count: 200
        )
        XCTAssertEqual(read.text, "hello")
        XCTAssertEqual(read.totalLines, 1)

        let signal = try await provider.signal(
            ownerSession: "agent-a",
            sessionID: opened.snapshot.sessionID,
            signal: .interrupt
        )
        XCTAssertTrue(signal.delivered)
        let signals = await backend.signals()
        XCTAssertEqual(signals, [.interrupt])

        do {
            _ = try await provider.read(
                ownerSession: "agent-b",
                sessionID: opened.snapshot.sessionID,
                offset: 0,
                count: 1
            )
            XCTFail("a foreign owner must not read the session")
        } catch let error as ISHTerminalProviderError {
            XCTAssertEqual(error, .foreignSession(opened.snapshot.sessionID))
        }

        let closeResult = try await provider.close(
            ownerSession: "agent-a",
            sessionID: opened.snapshot.sessionID
        )
        XCTAssertEqual(closeResult, .closed)
        let remainingSessions = await provider.list(ownerSession: "agent-a")
        XCTAssertTrue(remainingSessions.isEmpty)
        let backendClosed = await backend.closed()
        XCTAssertTrue(backendClosed)
    }

    func testToolContractsRejectInvalidArgumentsAndExposeAllSixNames() async throws {
        let provider = makeProvider(backend: TestTerminalBackend())
        let tools = ISHTerminalToolSuite.makeTools(provider: provider, ownerSession: "agent")
        XCTAssertEqual(Set(tools.map { $0.definition.name }), ISHTerminalToolSuite.names)

        let open = try XCTUnwrap(tools.first { $0.definition.name == "terminal_open" })
        do {
            _ = try await open.execute(arguments: ["type": .string("remote-shell")])
            XCTFail("unsupported terminal type must be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }

        let read = try XCTUnwrap(tools.first { $0.definition.name == "terminal_read" })
        do {
            _ = try await read.execute(arguments: [
                "session_id": .string("terminal-1"),
                "count": .number(2_001)
            ])
            XCTFail("terminal_read must enforce its bounded count")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }

        let signal = try XCTUnwrap(tools.first { $0.definition.name == "terminal_signal" })
        do {
            _ = try await signal.execute(arguments: [
                "session_id": .string("terminal-1"),
                "signal": .string("SIGUSR1")
            ])
            XCTFail("unknown signals must be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }
    }

    func testPersistenceMarksRunningSessionInterruptedAndBlocksLiveOperations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ISHTerminalProvider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistenceURL = directory.appendingPathComponent("terminals.json")
        let firstBackend = TestTerminalBackend()
        let first = makeProvider(backend: firstBackend, persistenceURL: persistenceURL)
        let opened = try await first.open(
            ownerSession: "agent",
            type: "ish-shell",
            name: nil,
            cwd: nil
        )

        let restored = makeProvider(backend: TestTerminalBackend(), persistenceURL: persistenceURL)
        let restoredSessions = await restored.list(ownerSession: "agent")
        guard let snapshot = restoredSessions.first else {
            XCTFail("the persisted terminal session should be restored")
            return
        }
        XCTAssertEqual(snapshot.sessionID, opened.snapshot.sessionID)
        XCTAssertEqual(snapshot.status, .interrupted(reason: "app restart interrupted the on-device terminal process"))

        do {
            _ = try await restored.send(
                ownerSession: "agent",
                sessionID: snapshot.sessionID,
                text: "echo stale",
                submit: true
            )
            XCTFail("interrupted sessions cannot resume")
        } catch let error as ISHTerminalProviderError {
            XCTAssertEqual(error, .interruptedSession(snapshot.sessionID))
        }

        let closeResult = try await restored.close(
            ownerSession: "agent",
            sessionID: snapshot.sessionID
        )
        XCTAssertEqual(closeResult, .closed)
        let remainingSessions = await restored.list(ownerSession: "agent")
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testProviderEnforcesOwnerCapacity() async throws {
        let provider = makeProvider(backend: TestTerminalBackend(), maximumSessionsPerOwner: 1)
        _ = try await provider.open(ownerSession: "agent", type: "ish-shell", name: nil, cwd: nil)
        do {
            _ = try await provider.open(ownerSession: "agent", type: "ish-shell", name: nil, cwd: nil)
            XCTFail("capacity must be enforced")
        } catch let error as ISHTerminalProviderError {
            XCTAssertEqual(error, .capacityReached(limit: 1))
        }
    }

    private func makeProvider(
        backend: TestTerminalBackend,
        maximumSessionsPerOwner: Int = 8,
        persistenceURL: URL? = nil
    ) -> ISHTerminalSessionProvider {
        ISHTerminalSessionProvider(
            factories: ["ish-shell": { request in
                ISHTerminalOpenedSession(backend: backend, pid: 42, motd: "test terminal \(request.sessionID)")
            }],
            maximumSessionsPerOwner: maximumSessionsPerOwner,
            persistenceURL: persistenceURL
        )
    }
}

private actor TestTerminalBackend: ISHTerminalBackendSession {
    private var written: [String] = []
    private var sentSignals: [ISHTerminalSignal] = []
    private var isClosed = false

    func send(text: String, submit: Bool) async throws -> ISHTerminalSendResult {
        written.append(text + (submit ? "\n" : ""))
        return ISHTerminalSendResult(
            viewport: "hello",
            waitReason: .inferredIdle,
            sessionStatus: .running,
            truncated: false
        )
    }

    func read(offset: Int, count: Int) async throws -> ISHTerminalReadResult {
        guard offset >= 0, count >= 1, count <= 2_000 else {
            throw ISHTerminalProviderError.backendContractUnavailable("invalid test read")
        }
        return ISHTerminalReadResult(
            text: offset == 0 ? "hello" : "",
            totalLines: 1,
            lineBegin: offset,
            lineEnd: min(offset + count, 1),
            truncated: false
        )
    }

    func signal(_ signal: ISHTerminalSignal) async throws -> ISHTerminalSignalResult {
        sentSignals.append(signal)
        return ISHTerminalSignalResult(delivered: true, targetProcessGroup: 42)
    }

    func close() async throws -> Bool {
        isClosed = true
        return true
    }

    func writes() -> [String] { written }
    func signals() -> [ISHTerminalSignal] { sentSignals }
    func closed() -> Bool { isClosed }
}
