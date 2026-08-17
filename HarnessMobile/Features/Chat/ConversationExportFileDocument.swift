import SwiftUI
import UniformTypeIdentifiers

struct ConversationExportFileDocument: FileDocument {
    static var markdownContentType: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }

    static var logContentType: UTType {
        UTType(filenameExtension: "log") ?? .plainText
    }

    static var readableContentTypes: [UTType] {
        [.json, markdownContentType, logContentType, .plainText]
    }

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
