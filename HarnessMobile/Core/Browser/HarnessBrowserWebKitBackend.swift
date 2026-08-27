#if canImport(WebKit) && os(iOS)
import Foundation
import UIKit
import WebKit

/// The WebKit boundary is deliberately narrow: a non-persistent web view per
/// tab, fixed DOM text extraction, and a bounded snapshot. No cookies,
/// arbitrary JavaScript, request headers, downloads, or shared data store are
/// exposed to the model.
@MainActor
final class HarnessBrowserWebKitBackend: NSObject, HarnessBrowserBackend, WKNavigationDelegate, @unchecked Sendable {
    static let shared = HarnessBrowserWebKitBackend()

    private var webViews: [UUID: WKWebView] = [:]
    private var navigationWaiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    func discard(sessionID _: String, tabID: UUID) async {
        webViews.removeValue(forKey: tabID)
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
            do {
                try await load(url, in: webView)
                return result(for: request, webView: webView)
            } catch {
                webViews.removeValue(forKey: request.tabID)
                throw HarnessBrowserServiceError.backendFailure
            }

        case .navigate:
            guard let url = request.url, let webView = webViews[request.tabID] else {
                throw HarnessBrowserServiceError.tabNotFound
            }
            do {
                try await load(url, in: webView)
                return result(for: request, webView: webView)
            } catch {
                throw HarnessBrowserServiceError.backendFailure
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
                evictedTabID: nil
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
                evictedTabID: nil
            )

        case .close:
            guard webViews.removeValue(forKey: request.tabID) != nil else {
                throw HarnessBrowserServiceError.tabNotFound
            }
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
            evictedTabID: nil
        )
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

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            webViews = webViews.filter { $0.value !== webView }
            finish(webView, error: HarnessBrowserServiceError.backendFailure)
        }
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
