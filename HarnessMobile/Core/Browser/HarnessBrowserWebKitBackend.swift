#if canImport(WebKit) && os(iOS)
import Foundation
import UIKit
import WebKit

/// The WebKit boundary is deliberately narrow: a non-persistent web view per
/// tab, fixed DOM text extraction, and a bounded snapshot. No cookies,
/// arbitrary JavaScript, request headers, or shared data store are exposed to
/// the model. Downloads are limited to the request's local workspace folder.
@MainActor
final class HarnessBrowserWebKitBackend: NSObject, HarnessBrowserBackend, WKNavigationDelegate, WKDownloadDelegate, @unchecked Sendable {
    static let shared = HarnessBrowserWebKitBackend()
    private static let maximumDownloadBytes = WorkspaceStore.maximumFileAttachmentBytes

    private struct DownloadContext {
        let tabID: UUID
        let directory: WorkspaceBrowserDownloadDirectory
        let fileName: String
        let destination: URL
    }

    private var webViews: [UUID: WKWebView] = [:]
    private var navigationWaiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var downloadDirectories: [UUID: WorkspaceBrowserDownloadDirectory] = [:]
    private var downloadTabIDs: [ObjectIdentifier: UUID] = [:]
    private var liveDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var downloadContexts: [ObjectIdentifier: DownloadContext] = [:]
    private var downloadEvents: [UUID: [HarnessBrowserDownloadedFile]] = [:]

    func discard(sessionID _: String, tabID: UUID) async {
        webViews.removeValue(forKey: tabID)
        cancelDownloads(for: tabID)
        downloadDirectories.removeValue(forKey: tabID)
        downloadEvents.removeValue(forKey: tabID)
    }

    func perform(_ request: HarnessBrowserRequest) async throws -> HarnessBrowserResult {
        switch request.action {
        case .open:
            guard let url = request.url else { throw HarnessBrowserServiceError.invalidAction }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webViews[request.tabID] = webView
            guard let directory = request.downloadDirectory else {
                webViews.removeValue(forKey: request.tabID)
                throw HarnessBrowserServiceError.downloadStorageUnavailable
            }
            downloadDirectories[request.tabID] = directory
            do {
                try await load(url, in: webView)
                return result(for: request, webView: webView)
            } catch {
                webViews.removeValue(forKey: request.tabID)
                downloadDirectories.removeValue(forKey: request.tabID)
                throw error
            }

        case .navigate:
            guard let url = request.url, let webView = webViews[request.tabID] else {
                throw HarnessBrowserServiceError.tabNotFound
            }
            guard let directory = request.downloadDirectory else {
                throw HarnessBrowserServiceError.downloadStorageUnavailable
            }
            downloadDirectories[request.tabID] = directory
            do {
                try await load(url, in: webView)
                return result(for: request, webView: webView)
            } catch {
                throw error
            }

        case .readText:
            guard let webView = webViews[request.tabID] else {
                throw HarnessBrowserServiceError.tabNotFound
            }
            let value = try await webView.evaluateJavaScript(
                "document.body ? document.body.innerText : \"\""
            )
            return HarnessBrowserResult(
                tabID: request.tabID,
                action: request.action,
                pageURL: webView.url,
                title: webView.title,
                text: value as? String ?? "",
                screenshotBase64: nil,
                tabIDs: [],
                evictedTabID: nil,
                downloads: drainDownloadEvents(for: request.tabID)
            )

        case .screenshot:
            guard let webView = webViews[request.tabID] else {
                throw HarnessBrowserServiceError.tabNotFound
            }
            let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            guard let data = image.pngData() else {
                throw HarnessBrowserServiceError.backendFailure
            }
            return HarnessBrowserResult(
                tabID: request.tabID,
                action: request.action,
                pageURL: webView.url,
                title: webView.title,
                text: nil,
                screenshotBase64: data.base64EncodedString(),
                tabIDs: [],
                evictedTabID: nil,
                downloads: drainDownloadEvents(for: request.tabID)
            )

        case .close:
            guard webViews.removeValue(forKey: request.tabID) != nil else {
                throw HarnessBrowserServiceError.tabNotFound
            }
            cancelDownloads(for: request.tabID)
            downloadDirectories.removeValue(forKey: request.tabID)
            downloadEvents.removeValue(forKey: request.tabID)
            return HarnessBrowserResult(
                tabID: request.tabID,
                action: request.action,
                pageURL: nil,
                title: nil,
                text: nil,
                screenshotBase64: nil,
                tabIDs: [],
                evictedTabID: nil
            )

        case .listTabs:
            return HarnessBrowserResult(
                tabID: nil,
                action: request.action,
                pageURL: nil,
                title: nil,
                text: nil,
                screenshotBase64: nil,
                tabIDs: Array(webViews.keys),
                evictedTabID: nil
            )
        }
    }

    private func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationWaiters[ObjectIdentifier(webView)] = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    private func result(for request: HarnessBrowserRequest, webView: WKWebView) -> HarnessBrowserResult {
        HarnessBrowserResult(
            tabID: request.tabID,
            action: request.action,
            pageURL: webView.url ?? request.url,
            title: webView.title,
            text: nil,
            screenshotBase64: nil,
            tabIDs: [],
            evictedTabID: nil,
            downloads: drainDownloadEvents(for: request.tabID)
        )
    }

    private func drainDownloadEvents(for tabID: UUID) -> [HarnessBrowserDownloadedFile] {
        defer { downloadEvents.removeValue(forKey: tabID) }
        return downloadEvents[tabID] ?? []
    }

    private func appendDownloadEvent(_ event: HarnessBrowserDownloadedFile, for tabID: UUID) {
        var events = downloadEvents[tabID] ?? []
        if let index = events.firstIndex(where: { $0.workspacePath == event.workspacePath }) {
            events[index] = event
        } else {
            events.append(event)
        }
        downloadEvents[tabID] = Array(events.suffix(8))
    }

    private func cancelDownloads(for tabID: UUID) {
        let keys = downloadTabIDs.compactMap { key, mappedTabID in
            mappedTabID == tabID ? key : nil
        }
        for key in keys {
            let context = downloadContexts.removeValue(forKey: key)
            try? context.map { try FileManager.default.removeItem(at: $0.destination) }
            downloadTabIDs.removeValue(forKey: key)
            if let download = liveDownloads.removeValue(forKey: key) {
                cancel(download)
            }
        }
    }

    private func cancel(_ download: WKDownload) {
        Task { _ = await download.cancel() }
    }

    private func finish(_ webView: WKWebView, error: Error?) {
        guard let waiter = navigationWaiters.removeValue(forKey: ObjectIdentifier(webView)) else {
            return
        }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        Task { @MainActor in finish(webView, error: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        Task { @MainActor in finish(webView, error: error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        Task { @MainActor in finish(webView, error: error) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        return (.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse,
           response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(
        _ webView: WKWebView,
        navigationAction _: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        attach(download, from: webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse _: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        attach(download, from: webView)
    }

    private func attach(_ download: WKDownload, from webView: WKWebView) {
        guard let tabID = webViews.first(where: { $0.value === webView })?.key else {
            cancel(download)
            return
        }
        download.delegate = self
        let key = ObjectIdentifier(download)
        downloadTabIDs[key] = tabID
        liveDownloads[key] = download
        finish(webView, error: nil)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let key = ObjectIdentifier(download)
        guard response.expectedContentLength <= 0 || response.expectedContentLength <= Int64(Self.maximumDownloadBytes),
              let tabID = downloadTabIDs[key],
              let directory = downloadDirectories[tabID] else {
            downloadTabIDs.removeValue(forKey: key)
            liveDownloads.removeValue(forKey: key)
            _ = await download.cancel()
            return nil
        }
        let fileName = uniqueDownloadFileName(suggestedFilename, in: directory.url)
        let destination = directory.url.appendingPathComponent(fileName, isDirectory: false)
        downloadContexts[key] = DownloadContext(
            tabID: tabID,
            directory: directory,
            fileName: fileName,
            destination: destination
        )
        appendDownloadEvent(
            HarnessBrowserDownloadedFile(
                fileName: fileName,
                workspacePath: directory.workspacePath + "/" + fileName,
                state: .started,
                byteCount: nil
            ),
            for: tabID
        )
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        downloadTabIDs.removeValue(forKey: key)
        liveDownloads.removeValue(forKey: key)
        guard let context = downloadContexts.removeValue(forKey: key) else { return }
        let byteCount = (try? context.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard byteCount >= 0, byteCount <= Self.maximumDownloadBytes else {
            try? FileManager.default.removeItem(at: context.destination)
            appendDownloadEvent(
                HarnessBrowserDownloadedFile(
                    fileName: context.fileName,
                    workspacePath: context.directory.workspacePath + "/" + context.fileName,
                    state: .failed,
                    byteCount: nil
                ),
                for: context.tabID
            )
            return
        }
        appendDownloadEvent(
            HarnessBrowserDownloadedFile(
                fileName: context.fileName,
                workspacePath: context.directory.workspacePath + "/" + context.fileName,
                state: .completed,
                byteCount: byteCount
            ),
            for: context.tabID
        )
    }

    func download(_ download: WKDownload, didFailWithError _: Error, resumeData _: Data?) {
        let key = ObjectIdentifier(download)
        downloadTabIDs.removeValue(forKey: key)
        liveDownloads.removeValue(forKey: key)
        guard let context = downloadContexts.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: context.destination)
        appendDownloadEvent(
            HarnessBrowserDownloadedFile(
                fileName: context.fileName,
                workspacePath: context.directory.workspacePath + "/" + context.fileName,
                state: .failed,
                byteCount: nil
            ),
            for: context.tabID
        )
    }

    private func uniqueDownloadFileName(_ suggestedFilename: String, in directory: URL) -> String {
        let cleaned = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original = String((cleaned.isEmpty ? "download" : cleaned).prefix(120))
        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var ordinal = 0
        while true {
            let candidate: String
            if ordinal == 0 {
                candidate = original
            } else if ext.isEmpty {
                candidate = "\(base)-\(ordinal)"
            } else {
                candidate = "\(base)-\(ordinal).\(ext)"
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            ordinal += 1
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let tabID = webViews.first(where: { $0.value === webView })?.key
        webViews = webViews.filter { $0.value !== webView }
        if let tabID {
            cancelDownloads(for: tabID)
            downloadDirectories.removeValue(forKey: tabID)
            downloadEvents.removeValue(forKey: tabID)
        }
        finish(webView, error: HarnessBrowserServiceError.webContentTerminated)
    }
}

struct HarnessBrowserPlatformBackend: HarnessBrowserBackend {
    func perform(_ request: HarnessBrowserRequest) async throws -> HarnessBrowserResult {
        try await HarnessBrowserWebKitBackend.shared.perform(request)
    }
}
#else
typealias HarnessBrowserPlatformBackend = UnavailableHarnessBrowserBackend
#endif
