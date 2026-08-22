import Foundation

struct ToolResultOutputConfiguration: Sendable, Equatable {
    static let standard = ToolResultOutputConfiguration()

    let maximumInlineBytes: Int
    let maximumSpillBytes: Int

    init(
        maximumInlineBytes: Int = 56 * 1_024,
        maximumSpillBytes: Int = ToolResultSpillStore.defaultMaximumBytes
    ) {
        precondition(maximumInlineBytes >= 1_024)
        precondition(maximumSpillBytes >= maximumInlineBytes)
        self.maximumInlineBytes = maximumInlineBytes
        self.maximumSpillBytes = maximumSpillBytes
    }
}

struct ToolResultOutputPolicyError: LocalizedError, Sendable, Equatable {
    let originalWasError: Bool
    let originalPreview: String
    let spillFailure: String

    var errorDescription: String? {
        let kind = originalWasError ? "工具原始错误" : "工具结果"
        return "\(kind)过长且无法保存完整内容：\(spillFailure) 原始内容开头：\(originalPreview)"
    }
}

/// Universal, model-facing output seam. Callers apply it after tool/plugin
/// finalization and before trajectory persistence or model-message creation.
/// It preserves `isError` and the canonical value while bounding only the
/// presentation text; cancellation always propagates unchanged.
struct ToolResultOutputPolicy: Sendable {
    let spillStore: ToolResultSpillStore
    let configuration: ToolResultOutputConfiguration

    init(
        fileSystem: any HarnessFileSystem,
        configuration: ToolResultOutputConfiguration = .standard
    ) {
        self.configuration = configuration
        spillStore = ToolResultSpillStore(
            fileSystem: fileSystem,
            maximumBytes: configuration.maximumSpillBytes
        )
    }

    func project(
        _ result: CordisToolExecutionResult,
        toolName: String,
        callID: String
    ) async throws -> CordisToolExecutionResult {
        try Task.checkCancellation()
        let byteCount = result.text.utf8.count
        guard byteCount > configuration.maximumInlineBytes else { return result }

        let reference: ToolResultSpillReference
        do {
            reference = try await spillStore.save(
                result.text,
                suggestedName: "\(Self.safeComponent(toolName))-result.txt"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolResultOutputPolicyError(
                originalWasError: result.isError,
                originalPreview: Self.utf8Prefix(result.text, maximumBytes: 1_024),
                spillFailure: String(error.localizedDescription.prefix(2_048))
            )
        }

        let status = result.isError ? "error" : "result"
        let footer = "[Full tool \(status) stored at: \(reference.locator) (\(reference.bytes) bytes). Use read with this path to inspect it. call_id=\(Self.safeComponent(callID))]"
        let separator = "\n\n"
        let available = max(
            0,
            configuration.maximumInlineBytes - separator.utf8.count - footer.utf8.count
        )
        let preview = Self.utf8Prefix(result.text, maximumBytes: available)
        let projected = preview.isEmpty ? footer : preview + separator + footer
        return result.replacingContent(projected)
    }

    private static func safeComponent(_ value: String) -> String {
        let safe = value.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
        let bounded = String(safe.prefix(96))
        return bounded.isEmpty ? "tool" : bounded
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            guard used + value.utf8.count <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
            used += value.utf8.count
        }
        return result
    }
}
