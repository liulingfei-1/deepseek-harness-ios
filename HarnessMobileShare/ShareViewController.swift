import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "正在安全接收共享内容…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task { @MainActor in
            await receiveShare()
        }
    }

    private func receiveShare() async {
        do {
            let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let drafts = await ShareItemCollector.collect(from: extensionItems)
            _ = try await ShareHandoffStore().enqueue(drafts)
            statusLabel.text = "已保存。打开 Harness 后会进入当前输入框。"
            extensionContext?.completeRequest(returningItems: [])
        } catch {
            statusLabel.text = error.localizedDescription
            extensionContext?.cancelRequest(withError: error)
        }
    }
}

@MainActor
private enum ShareItemCollector {
    static func collect(from extensionItems: [NSExtensionItem]) async -> [ShareHandoffDraft] {
        var drafts: [ShareHandoffDraft] = []
        for extensionItem in extensionItems {
            for provider in extensionItem.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let data = await loadData(provider, typeIdentifier: UTType.url.identifier),
                   let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: value),
                   !url.isFileURL {
                    drafts.append(.url(url.absoluteString))
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let data = await loadData(provider, typeIdentifier: UTType.plainText.identifier),
                   let value = String(data: data, encoding: .utf8),
                   !value.isEmpty {
                    drafts.append(.text(value))
                    continue
                }
                if let identifier = preferredIdentifier(
                    in: provider,
                    conformingTo: [.jpeg, .png, .gif, .heic, .heif, .image]
                ), let data = await loadData(provider, typeIdentifier: identifier),
                   let type = UTType(identifier) {
                    let mimeType = type.preferredMIMEType ?? imageMimeType(for: type)
                    let suffix = type.preferredFilenameExtension ?? "jpg"
                    drafts.append(
                        .attachment(
                            kind: .image,
                            data: data,
                            displayName: "shared-image.\(suffix)",
                            mimeType: mimeType
                        )
                    )
                    continue
                }
                if let identifier = preferredIdentifier(
                    in: provider,
                    conformingTo: [.pdf, .mp3, .wav, .mpeg4Audio, .mpeg4Movie, .quickTimeMovie, .audio, .movie]
                ), let data = await loadFileData(provider, typeIdentifier: identifier),
                   let type = UTType(identifier),
                   let mimeType = supportedFileMimeType(for: type) {
                    let suffix = type.preferredFilenameExtension ?? fallbackExtension(for: mimeType)
                    drafts.append(
                        .attachment(
                            kind: .file,
                            data: data,
                            displayName: provider.suggestedName.map { "\($0).\(suffix)" }
                                ?? "shared-file.\(suffix)",
                            mimeType: mimeType
                        )
                    )
                }
            }
        }
        return drafts
    }

    private static func preferredIdentifier(
        in provider: NSItemProvider,
        conformingTo candidates: [UTType]
    ) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if candidates.contains(where: { type.conforms(to: $0) }) {
                return identifier
            }
        }
        return nil
    }

    private static func loadData(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func loadFileData(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: try? Data(contentsOf: url, options: [.mappedIfSafe]))
            }
        }
    }

    private static func imageMimeType(for type: UTType) -> String {
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "image/heic" }
        return "image/jpeg"
    }

    private static func supportedFileMimeType(for type: UTType) -> String? {
        if type.conforms(to: .pdf) { return "application/pdf" }
        if type.conforms(to: .mp3) { return "audio/mpeg" }
        if type.conforms(to: .wav) { return "audio/wav" }
        if type.conforms(to: .mpeg4Audio) { return "audio/mp4" }
        if type.conforms(to: .quickTimeMovie) { return "video/quicktime" }
        if type.conforms(to: .mpeg4Movie) { return "video/mp4" }
        return nil
    }

    private static func fallbackExtension(for mimeType: String) -> String {
        switch mimeType {
        case "application/pdf": "pdf"
        case "audio/mpeg": "mp3"
        case "audio/wav": "wav"
        case "audio/mp4": "m4a"
        case "video/quicktime": "mov"
        default: "mp4"
        }
    }
}
