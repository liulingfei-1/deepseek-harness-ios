import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WebFetchToolTests: XCTestCase {
    override func tearDown() {
        WebFetchURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testURLPolicyRejectsUnsafeSchemesCredentialsAndOversizedURLs() {
        let limits = WebFetchLimits(
            maximumURLBytes: 32,
            maximumResponseBytes: 1_024,
            maximumBodyCharacters: 1_024,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )

        XCTAssertThrowsError(try WebFetchURLPolicy.validate("file:///etc/passwd", limits: limits)) {
            XCTAssertEqual($0 as? WebFetchError, .unsupportedScheme("file"))
        }
        XCTAssertThrowsError(try WebFetchURLPolicy.validate("https://user:pass@example.com", limits: limits)) {
            XCTAssertEqual($0 as? WebFetchError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(
            try WebFetchURLPolicy.validate(
                "https://example.com/" + String(repeating: "x", count: 64),
                limits: limits
            )
        ) {
            XCTAssertEqual($0 as? WebFetchError, .urlTooLong(32))
        }
    }

    func testOriginNormalizationUsesEffectivePortsAndSameOriginPolicy() throws {
        let first = try XCTUnwrap(URL(string: "https://EXAMPLE.com/path"))
        let same = try XCTUnwrap(URL(string: "https://example.com:443/other"))
        let otherPort = try XCTUnwrap(URL(string: "https://example.com:8443/other"))

        XCTAssertEqual(try WebFetchURLPolicy.normalizedOrigin(for: first), "https://example.com")
        XCTAssertTrue(WebFetchURLPolicy.isSameOrigin(first, same))
        XCTAssertFalse(WebFetchURLPolicy.isSameOrigin(first, otherPort))
        XCTAssertEqual(
            try WebFetchURLPolicy.normalizedOrigin(for: otherPort),
            "https://example.com:8443"
        )
    }

    func testToolScopesApprovalToOneWebOrigin() throws {
        let tool = WebFetchTool()
        let arguments: [String: JSONValue] = [
            "url": .string("https://example.com/docs/page")
        ]

        try tool.validate(arguments: arguments)
        XCTAssertEqual(
            try tool.approvalResources(arguments: arguments),
            ["web:origin:https://example.com"]
        )
        XCTAssertEqual(tool.summary(arguments: arguments), "从手机访问网页：https://example.com")
    }

    func testClientReadsTextWithoutCookiesCredentialsOrRealNetwork() async throws {
        let limits = WebFetchLimits(
            maximumURLBytes: 2_048,
            maximumResponseBytes: 1_024,
            maximumBodyCharacters: 5,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )
        WebFetchURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "web-fetch-tests")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"]
                )
            )
            return (response, Data("abcdef".utf8))
        }

        let client = WebFetchHTTPClient(
            limits: limits,
            protocolClasses: [WebFetchURLProtocolStub.self]
        )
        let result = try await client.fetch("https://example.com/readme")

        XCTAssertEqual(result.url, "https://example.com/readme")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, WebFetchBody(kind: .text, content: "abcde"))
        XCTAssertTrue(result.truncated)
    }

    func testDeclaredOversizedResponseFailsBeforeBufferingBody() async throws {
        let limits = WebFetchLimits(
            maximumURLBytes: 2_048,
            maximumResponseBytes: 4,
            maximumBodyCharacters: 100,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )
        WebFetchURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "text/plain",
                        "Content-Length": "10"
                    ]
                )
            )
            return (response, Data("0123456789".utf8))
        }

        let client = WebFetchHTTPClient(
            limits: limits,
            protocolClasses: [WebFetchURLProtocolStub.self]
        )
        do {
            _ = try await client.fetch("https://example.com/large")
            XCTFail("Expected the declared response size to be rejected")
        } catch let error as WebFetchError {
            XCTAssertEqual(error, .responseTooLarge(4))
        }
    }
}

private final class WebFetchURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
