import Foundation

enum ConversationExportFormat: String, Sendable, Equatable, CaseIterable {
    case json
    case markdown

    var filenameExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        }
    }
}

struct ConversationExportInput: Sendable, Equatable {
    let sessionID: UUID
    let title: String
    let providerID: String
    let model: String
    let exportedAt: Date
    let messages: [AgentMessage]

    init(
        sessionID: UUID,
        title: String,
        providerID: String,
        model: String,
        exportedAt: Date = .now,
        messages: [AgentMessage]
    ) {
        self.sessionID = sessionID
        self.title = title
        self.providerID = providerID
        self.model = model
        self.exportedAt = exportedAt
        self.messages = messages
    }
}

enum ConversationExportBuilder {
    private static let maximumTextUTF8Bytes = 512 * 1_024
    private static let maximumToolResultUTF8Bytes = 64 * 1_024

    static func makeData(
        input: ConversationExportInput,
        format: ConversationExportFormat
    ) throws -> Data {
        switch format {
        case .json:
            try makeJSON(input)
        case .markdown:
            Data(makeMarkdown(input).utf8)
        }
    }

    private static func makeJSON(_ input: ConversationExportInput) throws -> Data {
        let document = ExportDocument(
            schemaVersion: 1,
            redacted: true,
            sessionID: input.sessionID,
            title: redact(input.title),
            providerID: input.providerID,
            model: input.model,
            exportedAt: input.exportedAt,
            messages: input.messages.map(exportMessage)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private static func makeMarkdown(_ input: ConversationExportInput) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# \(redact(input.title))",
            "",
            "- Session: `\(input.sessionID.uuidString.lowercased())`",
            "- Provider: `\(input.providerID)`",
            "- Model: `\(input.model)`",
            "- Exported: \(formatter.string(from: input.exportedAt))",
            "- Privacy: sensitive token patterns are redacted; raw tool arguments are omitted",
        ]

        for message in input.messages {
            lines.append("")
            lines.append("## \(roleTitle(message.role))")
            lines.append("")
            lines.append(formatter.string(from: message.createdAt))

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                lines.append("")
                lines.append("<details><summary>Reasoning</summary>")
                lines.append("")
                lines.append(redact(bounded(reasoning, maximumUTF8Bytes: maximumTextUTF8Bytes)))
                lines.append("")
                lines.append("</details>")
            }

            if !message.content.isEmpty {
                lines.append("")
                lines.append(redact(bounded(message.content, maximumUTF8Bytes: maximumTextUTF8Bytes)))
            }

            if !message.toolEvents.isEmpty {
                lines.append("")
                lines.append("### Tools")
                appendMarkdownTools(message.toolEvents, depth: 0, lines: &lines)
            } else if !message.toolCalls.isEmpty {
                lines.append("")
                lines.append("### Tools")
                for call in message.toolCalls {
                    lines.append("- `\(call.name)`: arguments omitted from redacted export")
                }
            }

            if let feedback = message.feedback {
                lines.append("")
                lines.append("Feedback: \(feedback.rating == .positive ? "positive" : "negative")")
                if let note = feedback.note {
                    lines.append("Note: \(redact(note))")
                }
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendMarkdownTools(
        _ events: [AgentToolEvent],
        depth: Int,
        lines: inout [String]
    ) {
        for event in events {
            let indentation = String(repeating: "  ", count: depth)
            let summary = event.summary.isEmpty ? event.name : redact(event.summary)
            lines.append("\(indentation)- `\(event.name)` [\(event.status.rawValue)]: \(summary)")
            if let result = event.result, !result.isEmpty {
                lines.append(
                    "\(indentation)  Result: \(redact(bounded(result, maximumUTF8Bytes: maximumToolResultUTF8Bytes)))"
                )
            }
            if let error = event.errorMessage, !error.isEmpty {
                lines.append("\(indentation)  Error: \(redact(error))")
            }
            appendMarkdownTools(event.children, depth: depth + 1, lines: &lines)
        }
    }

    private static func exportMessage(_ message: AgentMessage) -> ExportMessage {
        ExportMessage(
            id: message.id,
            role: message.role.rawValue,
            content: redact(bounded(message.content, maximumUTF8Bytes: maximumTextUTF8Bytes)),
            reasoning: message.reasoning.map {
                redact(bounded($0, maximumUTF8Bytes: maximumTextUTF8Bytes))
            },
            toolCalls: message.toolCalls.map {
                ExportToolCall(id: $0.id, name: $0.name, argumentsOmitted: true)
            },
            toolEvents: message.toolEvents.map(exportToolEvent),
            feedback: message.feedback.map {
                ExportFeedback(
                    rating: $0.rating.rawValue,
                    note: $0.note.map(redact),
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            },
            createdAt: message.createdAt
        )
    }

    private static func exportToolEvent(_ event: AgentToolEvent) -> ExportToolEvent {
        ExportToolEvent(
            name: event.name,
            summary: redact(event.summary),
            status: event.status.rawValue,
            result: event.result.map {
                redact(bounded($0, maximumUTF8Bytes: maximumToolResultUTF8Bytes))
            },
            errorMessage: event.errorMessage.map(redact),
            createdAt: event.createdAt,
            startedAt: event.startedAt,
            finishedAt: event.finishedAt,
            children: event.children.map(exportToolEvent)
        )
    }

    private static func redact(_ text: String) -> String {
        var value = text
        let replacements = [
            (#"(?i)\bsk-[a-z0-9_-]{8,}\b"#, "[REDACTED]"),
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]"),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: replacement
            )
        }
        return value
    }

    private static func bounded(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result + "\n[truncated in export]"
    }

    private static func roleTitle(_ role: AgentRole) -> String {
        switch role {
        case .user: "User"
        case .assistant: "Harness"
        case .tool: "Tool"
        }
    }
}

private struct ExportDocument: Encodable {
    let schemaVersion: Int
    let redacted: Bool
    let sessionID: UUID
    let title: String
    let providerID: String
    let model: String
    let exportedAt: Date
    let messages: [ExportMessage]
}

private struct ExportMessage: Encodable {
    let id: UUID
    let role: String
    let content: String
    let reasoning: String?
    let toolCalls: [ExportToolCall]
    let toolEvents: [ExportToolEvent]
    let feedback: ExportFeedback?
    let createdAt: Date
}

private struct ExportToolCall: Encodable {
    let id: String
    let name: String
    let argumentsOmitted: Bool
}

private struct ExportToolEvent: Encodable {
    let name: String
    let summary: String
    let status: String
    let result: String?
    let errorMessage: String?
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let children: [ExportToolEvent]
}

private struct ExportFeedback: Encodable {
    let rating: String
    let note: String?
    let createdAt: Date
    let updatedAt: Date
}
