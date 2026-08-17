@preconcurrency import ImageIO
@preconcurrency import UIKit
@preconcurrency import Vision
import Foundation

struct CameraOCRTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "camera_ocr",
        description: "Recognize text locally from the latest image explicitly selected or captured by the user. Image bytes never leave the iPhone; only returned text may be sent to the model.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "本地识别最近图片，并把识别文字发送给模型"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let source = try await store.latestImageData()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try ImageDownsampler.downsample(source, maximumPixelSize: 2_048)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: data, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            return text.isEmpty ? "(未识别到文字)" : text
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum ImageDownsampler {
    static func downsample(_ data: Data, maximumPixelSize: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw OCRToolError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
            throw OCRToolError.invalidImage
        }
        return encoded
    }
}

enum OCRToolError: LocalizedError, Sendable {
    case invalidImage

    var errorDescription: String? {
        "无法读取所选图片。"
    }
}
