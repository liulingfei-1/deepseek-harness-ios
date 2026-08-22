import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class DeepSeekFilesClientTests: XCTestCase {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }

    func testUploadUsesMultipartAndReusesMemoryCache() async throws {
        let counter = Counter()
        let transport: DeepSeekFilesTransport = { request in
            await counter.increment()
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = try XCTUnwrap(request.httpBody)
            let bodyString = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyString.contains("name=\"purpose\""))
            XCTAssertTrue(bodyString.contains("user_data"))
            XCTAssertTrue(bodyString.contains("expires_after[anchor]"))
            XCTAssertTrue(bodyString.contains("created_at"))
            XCTAssertTrue(bodyString.contains("expires_after[seconds]"))
            XCTAssertTrue(bodyString.contains("\r\n\r\n604800\r\n"))
            XCTAssertTrue(bodyString.contains("image/png"))
            XCTAssertTrue(body.contains(Data([1, 2, 3])))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"id":"file-api-cached"}"#.utf8), response)
        }
        let client = DeepSeekFilesClient(transport: transport)
        let request = makeRequest(apiKey: "key-a")

        let first = await client.prepare(request)
        let second = await client.prepare(request)
        XCTAssertEqual(first.imagePayloads.first?.fileID, "file-api-cached")
        XCTAssertEqual(second.imagePayloads.first?.fileID, "file-api-cached")
        let uploadCount = await counter.read()
        XCTAssertEqual(uploadCount, 1)
    }

    func testDifferentCredentialsDoNotShareFileCache() async throws {
        let counter = Counter()
        let transport: DeepSeekFilesTransport = { request in
            await counter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let id = "file-api-\(await counter.read())"
            return (Data("{\"id\":\"\(id)\"}".utf8), response)
        }
        let client = DeepSeekFilesClient(transport: transport)
        _ = await client.prepare(makeRequest(apiKey: "key-a"))
        _ = await client.prepare(makeRequest(apiKey: "key-b"))
        let uploadCount = await counter.read()
        XCTAssertEqual(uploadCount, 2)
    }

    func testConcurrentRequestsCoalesceOneUpload() async throws {
        let counter = Counter()
        let transport: DeepSeekFilesTransport = { request in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(25))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"id":"file-api-coalesced"}"#.utf8), response)
        }
        let client = DeepSeekFilesClient(transport: transport)
        let request = makeRequest(apiKey: "key-a")

        async let first = client.prepare(request)
        async let second = client.prepare(request)
        let (preparedFirst, preparedSecond) = await (first, second)
        
        XCTAssertEqual(preparedFirst.imagePayloads.first?.fileID, "file-api-coalesced")
        XCTAssertEqual(preparedSecond.imagePayloads.first?.fileID, "file-api-coalesced")
        let uploadCount = await counter.read()
        XCTAssertEqual(uploadCount, 1)
    }

    func testMalformedUploadFallsBackToInlinePayload() async throws {
        let transport: DeepSeekFilesTransport = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"id":"not-a-files-id"}"#.utf8), response)
        }
        let client = DeepSeekFilesClient(transport: transport)
        let prepared = await client.prepare(makeRequest(apiKey: "key-a"))
        XCTAssertNil(prepared.imagePayloads.first?.fileID)
    }

    func testFilesEligibilityUsesResolvedModelModalitiesInsteadOfModelName() async throws {
        let counter = Counter()
        let transport: DeepSeekFilesTransport = { request in
            await counter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"id":"file-api-modalities"}"#.utf8), response)
        }
        let client = DeepSeekFilesClient(transport: transport)

        var declaredImage = AgentConfiguration(model: "private-multimodal-deployment")
        declaredImage.inputModalities = [.text, .image]
        let prepared = await client.prepare(
            makeRequest(apiKey: "key-a", configuration: declaredImage)
        )
        XCTAssertEqual(prepared.imagePayloads.first?.fileID, "file-api-modalities")

        var textOnlyVisionName = AgentConfiguration(model: "contains-vision-name")
        textOnlyVisionName.inputModalities = [.text]
        let notPrepared = await client.prepare(
            makeRequest(apiKey: "key-a", configuration: textOnlyVisionName)
        )
        XCTAssertNil(notPrepared.imagePayloads.first?.fileID)
        let uploadCount = await counter.read()
        XCTAssertEqual(uploadCount, 1)
    }

    func testFileReferenceFailureOnlyRetriesForExplicitFileErrors() {
        let request = makeRequest(apiKey: "key-a", fileID: "file-api-old")
        let expired = ModelClientError.httpFailure(
            .init(status: 404, code: "file_not_found", retryAfterMilliseconds: nil, requestID: nil),
            "The file reference has expired"
        )
        let unauthorized = ModelClientError.httpFailure(
            .init(status: 401, code: "invalid_api_key", retryAfterMilliseconds: nil, requestID: nil),
            "invalid api key"
        )
        XCTAssertTrue(OpenAICompatibleClient.shouldRetryInlineImages(after: expired, request: request))
        XCTAssertFalse(OpenAICompatibleClient.shouldRetryInlineImages(after: unauthorized, request: request))
    }

    private func makeRequest(
        apiKey: String,
        fileID: String? = nil,
        configuration: AgentConfiguration = AgentConfiguration(
            model: "deepseek-v4-flash-vision-exp"
        )
    ) -> ModelRequest {
        let id = UUID()
        return ModelRequest(
            configuration: configuration,
            apiKey: apiKey,
            systemPrompt: "system",
            messages: [AgentMessage.user(
                "image",
                imageAttachments: [AgentImageAttachmentRef(
                    id: id,
                    path: "Attachments/\(id.uuidString).png",
                    mimeType: "image/png",
                    byteCount: 3
                )]
            )],
            tools: [],
            imagePayloads: [ModelImagePayload(
                id: id,
                mimeType: "image/png",
                data: Data([1, 2, 3]),
                fileID: fileID
            )]
        )
    }
}
