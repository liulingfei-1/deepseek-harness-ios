import CryptoKit
import Foundation

/// Small transport seam used by tests and by the production URLSession path.
typealias DeepSeekFilesTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

private actor DeepSeekFilesCache {
    struct Entry: Sendable {
        let fileID: String
        let expiresAt: Date
    }

    private var values: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry?, Never>] = [:]

    func value(for key: String, now: Date = .now) -> Entry? {
        guard let entry = values[key] else { return nil }
        guard entry.expiresAt > now else {
            values.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    func insert(_ entry: Entry, for key: String) {
        values[key] = entry
    }

    /// Coalesce concurrent uploads for the same image. Queued turns and a
    /// retry can otherwise upload identical bytes at the same time.
    func valueOrLoad(
        for key: String,
        now: Date,
        loader: @escaping @Sendable () async -> Entry?
    ) async -> Entry? {
        if let cached = value(for: key, now: now) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { await loader() }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if let result {
            values[key] = result
        }
        return result
    }

    func remove(_ key: String) {
        values.removeValue(forKey: key)
    }
}

/// DeepSeek RC.8 Files API adapter for vision requests.
///
/// The cache is memory-only and scoped by endpoint, credential digest, image
/// digest, and MIME type. No API key or image bytes are persisted.
final class DeepSeekFilesClient: @unchecked Sendable {
    static let uploadLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let transport: DeepSeekFilesTransport
    private let cache = DeepSeekFilesCache()

    init(transport: DeepSeekFilesTransport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ModelClientError.invalidResponse
            }
            return (data, httpResponse)
        }
    }

    /// Rewrites eligible image payloads to provider file references. Upload
    /// failures deliberately leave the payload untouched so inline data URL
    /// encoding remains a reliable fallback.
    func prepare(_ request: ModelRequest, now: Date = .now) async -> ModelRequest {
        guard Self.supportsFilesAPI(request.configuration),
              !request.imagePayloads.isEmpty,
              !request.apiKey.isEmpty else {
            return request
        }

        let endpoint: URL
        do {
            endpoint = try request.configuration.apiEndpointURL(appending: "files")
        } catch {
            return request
        }

        var payloads: [ModelImagePayload] = []
        payloads.reserveCapacity(request.imagePayloads.count)
        for payload in request.imagePayloads {
            guard let fileID = await fileID(
                for: payload,
                endpoint: endpoint,
                apiKey: request.apiKey,
                now: now
            ) else {
                payloads.append(payload)
                continue
            }
            payloads.append(
                ModelImagePayload(
                    id: payload.id,
                    mimeType: payload.mimeType,
                    data: payload.data,
                    fileID: fileID
                )
            )
        }

        return ModelRequest(
            configuration: request.configuration,
            apiKey: request.apiKey,
            systemPrompt: request.systemPrompt,
            messages: request.messages,
            tools: request.tools,
            imagePayloads: payloads
        )
    }

    func invalidate(_ payload: ModelImagePayload, request: ModelRequest) async {
        guard let endpoint = try? request.configuration.apiEndpointURL(appending: "files") else {
            return
        }
        await cache.remove(Self.cacheKey(
            endpoint: endpoint,
            apiKey: request.apiKey,
            payload: payload
        ))
    }

    static func supportsFilesAPI(_ configuration: AgentConfiguration) -> Bool {
        guard configuration.providerID == .deepSeekOfficial,
              ModelProviderCatalog.supportsImageInput(configuration),
              let host = try? configuration.chatCompletionsURL().host?.lowercased(),
              host == "api.deepseek.com" else {
            return false
        }
        return true
    }

    private func fileID(
        for payload: ModelImagePayload,
        endpoint: URL,
        apiKey: String,
        now: Date
    ) async -> String? {
        guard Self.supportedMIME(payload.mimeType), !payload.data.isEmpty else {
            return nil
        }
        let key = Self.cacheKey(endpoint: endpoint, apiKey: apiKey, payload: payload)
        let entry = await cache.valueOrLoad(for: key, now: now) { [transport] in
            guard var request = try? Self.makeUploadRequest(
                endpoint: endpoint,
                apiKey: apiKey,
                payload: payload
            ) else {
                return nil
            }
            request.timeoutInterval = 60

            do {
                let (data, response) = try await transport(request)
                guard (200..<300).contains(response.statusCode),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fileID = object["id"] as? String,
                      fileID.hasPrefix("file-api-"),
                      fileID.utf8.count <= 256 else {
                    return nil
                }
                return .init(fileID: fileID, expiresAt: Self.expiry(from: object, now: now))
            } catch {
                return nil
            }
        }
        return entry?.fileID
    }

    private static func makeUploadRequest(
        endpoint: URL,
        apiKey: String,
        payload: ModelImagePayload
    ) throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            body.append(contentsOf: string.utf8)
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n")
        append("user_data\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"expires_after[anchor]\"\r\n\r\n")
        append("created_at\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"expires_after[seconds]\"\r\n\r\n")
        append("\(Int(uploadLifetime))\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"image.\(fileExtension(for: payload.mimeType))\"\r\n")
        append("Content-Type: \(payload.mimeType)\r\n\r\n")
        body.append(payload.data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func expiry(from object: [String: Any], now: Date) -> Date {
        if let seconds = object["expires_at"] as? Double,
           seconds > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = object["expires_at"] as? Int,
           seconds > Int(now.timeIntervalSince1970) {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return now.addingTimeInterval(uploadLifetime)
    }

    private static func cacheKey(
        endpoint: URL,
        apiKey: String,
        payload: ModelImagePayload
    ) -> String {
        let origin = "\(endpoint.scheme ?? "")://\(endpoint.host ?? ""):\(endpoint.port ?? 443)"
        return [
            origin,
            digest(apiKey.data(using: .utf8) ?? Data()),
            digest(payload.data),
            payload.mimeType.lowercased()
        ].joined(separator: "|")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func supportedMIME(_ mimeType: String) -> Bool {
        ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mimeType.lowercased())
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }
}
