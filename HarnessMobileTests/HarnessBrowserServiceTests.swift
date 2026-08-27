import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessBrowserServiceTests: XCTestCase {
    func testRejectsUnsafeURLsAndInvalidActions() async throws {
        let service = HarnessBrowserService(backend: RecordingBrowserBackend())
        await XCTAssertThrowsErrorAsync {
            try await service.execute(
                sessionID: "session-a",
                action: .open,
                url: URL(string: "javascript:alert(1)")
            )
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .invalidURL)
        }
        await XCTAssertThrowsErrorAsync {
            try await service.execute(
                sessionID: "session-a",
                action: .open,
                url: URL(string: "https://user:secret@example.com")
            )
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .invalidURL)
        }
        await XCTAssertThrowsErrorAsync {
            try await service.execute(
                sessionID: "session-a",
                action: .open,
                tabID: UUID(),
                url: URL(string: "https://example.com")
            )
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .invalidAction)
        }
    }

    func testSessionsAreIsolatedAndTabsAreBounded() async throws {
        let service = HarnessBrowserService(backend: RecordingBrowserBackend())
        let start = Date(timeIntervalSince1970: 10)
        let aTab = try await service.execute(
            sessionID: "A", action: .open, url: URL(string: "https://a.example")!, now: start
        ).tabID!
        _ = try await service.execute(
            sessionID: "B", action: .open, url: URL(string: "https://b.example")!, now: start.addingTimeInterval(1)
        )
        await XCTAssertThrowsErrorAsync {
            try await service.execute(sessionID: "B", action: .readText, tabID: aTab, now: start.addingTimeInterval(2))
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .tabNotFound)
        }

        var opened: [UUID] = [aTab]
        for offset in 1...3 {
            let result = try await service.execute(
                sessionID: "A",
                action: .open,
                url: URL(string: "https://a\(offset).example")!,
                now: start.addingTimeInterval(Double(offset))
            )
            if let id = result.tabID { opened.append(id) }
        }
        let aDescriptors = try await service.descriptors(sessionID: "A")
        let bDescriptors = try await service.descriptors(sessionID: "B")
        XCTAssertEqual(aDescriptors.count, 3)
        XCTAssertEqual(bDescriptors.count, 1)
        XCTAssertEqual(opened.count, 4)
    }

    func testGlobalCapEvictsLeastRecentlyUsedTab() async throws {
        let backend = RecordingBrowserBackend()
        let service = HarnessBrowserService(backend: backend)
        let start = Date(timeIntervalSince1970: 100)
        for index in 0..<3 {
            _ = try await service.execute(
                sessionID: "A", action: .open,
                url: URL(string: "https://a\(index).example")!,
                now: start.addingTimeInterval(Double(index))
            )
        }
        for index in 0..<3 {
            _ = try await service.execute(
                sessionID: "B", action: .open,
                url: URL(string: "https://b\(index).example")!,
                now: start.addingTimeInterval(Double(index + 3))
            )
        }
        let result = try await service.execute(
            sessionID: "C", action: .open,
            url: URL(string: "https://c.example")!,
            now: start.addingTimeInterval(10)
        )
        XCTAssertNotNil(result.evictedTabID)
        let aCount = try await service.descriptors(sessionID: "A").count
        let bCount = try await service.descriptors(sessionID: "B").count
        let cCount = try await service.descriptors(sessionID: "C").count
        XCTAssertEqual(aCount, 2)
        XCTAssertEqual(bCount, 3)
        XCTAssertEqual(cCount, 1)
        let discardedCount = await backend.discardedCount
        XCTAssertEqual(discardedCount, 1)
    }

    func testOutputLimitsAndCloseAreFailClosed() async throws {
        let backend = RecordingBrowserBackend()
        let service = HarnessBrowserService(backend: backend)
        let tabID = try await service.execute(
            sessionID: "session-a", action: .open, url: URL(string: "https://example.com")!
        ).tabID!
        await backend.setText(String(repeating: "x", count: HarnessBrowserResult.maximumTextUTF8Bytes + 1))
        await XCTAssertThrowsErrorAsync {
            try await service.execute(sessionID: "session-a", action: .readText, tabID: tabID)
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .resultTooLarge)
        }
        _ = try await service.execute(sessionID: "session-a", action: .close, tabID: tabID)
        let remaining = try await service.descriptors(sessionID: "session-a")
        XCTAssertEqual(remaining.count, 0)
        await XCTAssertThrowsErrorAsync {
            try await service.execute(sessionID: "session-a", action: .readText, tabID: tabID)
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .tabNotFound)
        }
    }

    func testWebContentTerminationClosesTheTabAndReturnsTypedOutcome() async throws {
        let backend = RecordingBrowserBackend()
        let service = HarnessBrowserService(backend: backend)
        let tabID = try await service.execute(
            sessionID: "session-a", action: .open, url: URL(string: "https://example.com")!
        ).tabID!
        await backend.terminateNextAction()

        await XCTAssertThrowsErrorAsync {
            try await service.execute(sessionID: "session-a", action: .readText, tabID: tabID)
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .webContentTerminated)
        }
        let descriptors = try await service.descriptors(sessionID: "session-a")
        XCTAssertEqual(descriptors.count, 0)
        await XCTAssertThrowsErrorAsync {
            try await service.execute(sessionID: "session-a", action: .readText, tabID: tabID)
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .tabNotFound)
        }
    }

    func testResultsCarryBoundedModelVisibleProvenance() async throws {
        let backend = RecordingBrowserBackend()
        let service = HarnessBrowserService(backend: backend)
        let result = try await service.execute(
            sessionID: "session-a", action: .open, url: URL(string: "https://example.com")!
        )
        XCTAssertEqual(result.provenance?.source, "on_device_browser")
        XCTAssertEqual(result.provenance?.kind, "navigation")
        XCTAssertEqual(result.provenance?.pageURL, result.pageURL)
        XCTAssertEqual(result.provenance?.byteCount, 0)

        let text = try await service.execute(
            sessionID: "session-a", action: .readText, tabID: result.tabID!
        )
        XCTAssertEqual(text.provenance?.kind, "dom_text")
        XCTAssertEqual(text.provenance?.byteCount, text.text?.utf8.count)
    }

    func testModelVisibleURLsStripQueryAndFragmentCanaries() async throws {
        let canary = "browser-secret-canary-7f3b"
        let backend = RecordingBrowserBackend()
        let service = HarnessBrowserService(backend: backend)
        let result = try await service.execute(
            sessionID: "session-a",
            action: .open,
            url: URL(string: "https://example.com/path?token=\(canary)#\(canary)")!
        )
        XCTAssertEqual(result.pageURL?.absoluteString, "https://example.com/path")
        XCTAssertEqual(result.provenance?.pageURL?.absoluteString, "https://example.com/path")
        let json = try String(decoding: JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains(canary))

        let descriptors = try await service.descriptors(sessionID: "session-a")
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.pageURL?.absoluteString, "https://example.com/path")
    }

    func testDownloadsAreRestrictedToBoundSessionWorkspaceDirectory() async throws {
        let directory = WorkspaceBrowserDownloadDirectory(
            url: FileManager.default.temporaryDirectory,
            workspacePath: "Downloads/session-test"
        )
        let backend = RecordingBrowserBackend()
        await backend.setDownloads([
            HarnessBrowserDownloadedFile(
                fileName: "report.pdf",
                workspacePath: "Downloads/session-test/report.pdf",
                state: .completed,
                byteCount: 512
            )
        ])
        let service = HarnessBrowserService(
            backend: backend,
            downloadDirectoryProvider: { _ in directory }
        )
        let result = try await service.execute(
            sessionID: "session-a", action: .open, url: URL(string: "https://example.com/download")!
        )
        XCTAssertEqual(result.downloads.count, 1)
        XCTAssertEqual(result.downloads.first?.workspacePath, "Downloads/session-test/report.pdf")

        await backend.setDownloads([
            HarnessBrowserDownloadedFile(
                fileName: "outside.pdf",
                workspacePath: "Downloads/session-other/outside.pdf",
                state: .completed,
                byteCount: 512
            )
        ])
        await XCTAssertThrowsErrorAsync {
            try await service.execute(
                sessionID: "session-a", action: .readText, tabID: result.tabID!
            )
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .backendFailure)
        }

        await backend.setDownloads([
            HarnessBrowserDownloadedFile(
                fileName: "nested.pdf",
                workspacePath: "Downloads/session-test/subdirectory/nested.pdf",
                state: .completed,
                byteCount: 512
            )
        ])
        await XCTAssertThrowsErrorAsync {
            try await service.execute(
                sessionID: "session-a", action: .readText, tabID: result.tabID!
            )
        } verify: { error in
            XCTAssertEqual(error as? HarnessBrowserServiceError, .backendFailure)
        }
    }

    func testToolSchemaDoesNotAcceptCookiesHeadersOrJavaScript() throws {
        let tool = HarnessBrowserTool(sessionID: "session-a")
        XCTAssertEqual(tool.definition.name, "browser_use")
        let properties = tool.definition.parameters.objectValue?["properties"]?.objectValue ?? [:]
        XCTAssertNil(properties["cookies"])
        XCTAssertNil(properties["headers"])
        XCTAssertNil(properties["javascript"])
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("open"),
            "url": .string("https://example.com"),
            "javascript": .string("document.cookie")
        ])) { error in
            XCTAssertEqual(String(describing: error), String(describing: LocalToolError.invalidArguments))
        }
    }
}

private actor RecordingBrowserBackend: HarnessBrowserBackend {
    private var text = "page text"
    private var terminateNext = false
    private var downloads: [HarnessBrowserDownloadedFile] = []
    private(set) var discardedCount = 0

    func discard(sessionID _: String, tabID _: UUID) async {
        discardedCount += 1
    }

    func setText(_ text: String) {
        self.text = text
    }

    func terminateNextAction() {
        terminateNext = true
    }

    func setDownloads(_ downloads: [HarnessBrowserDownloadedFile]) {
        self.downloads = downloads
    }

    func perform(_ request: HarnessBrowserRequest) async throws -> HarnessBrowserResult {
        switch request.action {
        case .open, .navigate:
            return HarnessBrowserResult(
                tabID: request.tabID, action: request.action, pageURL: request.url,
                title: "Example", text: nil, screenshotBase64: nil, tabIDs: [], evictedTabID: nil,
                downloads: downloads
            )
        case .readText:
            if terminateNext {
                terminateNext = false
                throw HarnessBrowserServiceError.webContentTerminated
            }
            return HarnessBrowserResult(
                tabID: request.tabID, action: request.action, pageURL: nil,
                title: "Example", text: text, screenshotBase64: nil, tabIDs: [], evictedTabID: nil,
                downloads: downloads
            )
        case .screenshot:
            return HarnessBrowserResult(
                tabID: request.tabID, action: request.action, pageURL: nil,
                title: "Example", text: nil, screenshotBase64: "c2NyZWVuc2hvdA==", tabIDs: [], evictedTabID: nil
            )
        case .close:
            return HarnessBrowserResult(
                tabID: request.tabID, action: request.action, pageURL: nil,
                title: nil, text: nil, screenshotBase64: nil, tabIDs: [], evictedTabID: nil
            )
        case .listTabs:
            return HarnessBrowserResult(
                tabID: nil, action: request.action, pageURL: nil,
                title: nil, text: nil, screenshotBase64: nil, tabIDs: [], evictedTabID: nil
            )
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        verify: (Error) -> Void
    ) async {
        do {
            try await expression()
            XCTFail("Expected async expression to throw")
        } catch {
            verify(error)
        }
    }
}
