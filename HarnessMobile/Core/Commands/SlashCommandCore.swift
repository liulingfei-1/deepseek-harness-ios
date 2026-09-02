import Foundation

// MARK: - Composer trigger pipeline

/// Native projection of the upstream `ui-input-trigger` token detector.
/// Offsets are Character offsets so SwiftUI can replace the exact token
/// without confusing a Chinese or emoji grapheme with its UTF-8 byte count.
enum InputTriggerCharacter: String, Codable, Sendable, Equatable {
    case slash = "/"
    case at = "@"
}

enum InputTriggerPosition: String, Codable, Sendable, Equatable {
    case leading
    case inline
}

enum InputTriggerGuardTier: String, Codable, Sendable, Equatable {
    case plain
    case claimed
    case frozen
}

struct InputTriggerSpan: Codable, Sendable, Equatable {
    let start: Int
    let end: Int
    let draftRevision: Int
}

struct InputTriggerHit: Codable, Sendable, Equatable {
    let trigger: InputTriggerCharacter
    let query: String
    let position: InputTriggerPosition
    let span: InputTriggerSpan
    let quoted: Bool

    init(
        trigger: InputTriggerCharacter,
        query: String,
        position: InputTriggerPosition,
        span: InputTriggerSpan,
        quoted: Bool = false
    ) {
        self.trigger = trigger
        self.query = query
        self.position = position
        self.span = span
        self.quoted = quoted
    }

    private enum CodingKeys: String, CodingKey {
        case trigger
        case query
        case position
        case span
        case quoted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decode(InputTriggerCharacter.self, forKey: .trigger)
        query = try container.decode(String.self, forKey: .query)
        position = try container.decode(InputTriggerPosition.self, forKey: .position)
        span = try container.decode(InputTriggerSpan.self, forKey: .span)
        quoted = try container.decodeIfPresent(Bool.self, forKey: .quoted) ?? false
    }
}

enum InputTriggerSuggestionKind: Sendable, Equatable {
    case command(SlashCommandDescriptor)
    case completion(SlashCommandCompletionCandidate)
    case skill(name: String)
    case subagent(address: String)
    case file(path: String)
    case history(sessionID: UUID)
    case plugin(id: String)
}

struct InputTriggerSuggestion: Sendable, Equatable, Identifiable {
    let source: String
    let trigger: InputTriggerCharacter
    let name: String
    let description: String?
    let systemImage: String?
    let replacementText: String
    let kind: InputTriggerSuggestionKind

    var id: String { "\(trigger.rawValue):\(source):\(name)" }
}

struct InputTriggerSuggestionGroup: Sendable, Equatable, Identifiable {
    let source: String
    let order: Int
    let suggestions: [InputTriggerSuggestion]

    var id: String { source }
}

struct InputTriggerSuggestionSnapshot: Sendable, Equatable {
    let draft: String
    let hit: InputTriggerHit
    let groups: [InputTriggerSuggestionGroup]
}

// MARK: - Command argument completion

/// Data domain requested by a command input descriptor. Providers stay in the
/// App layer; the command core only detects and ranks an argument token.
enum SlashCommandCompletionKind: String, Codable, CaseIterable, Sendable, Equatable {
    case model
    case agent
    case skill
    case file
    case session
    case plugin
}

struct SlashCommandCompletionCandidate: Codable, Sendable, Equatable, Identifiable {
    let source: SlashCommandCompletionKind
    let value: String
    let detail: String?

    var id: String { "\(source.rawValue):\(value)" }
}

struct SlashCommandCompletionMatch: Sendable, Equatable {
    let command: String
    let kind: SlashCommandCompletionKind
    let hit: InputTriggerHit
}

/// Detects the active argument token of a known leading slash command. This
/// deliberately does not parse quoting: file quoting belongs to the shared
/// `@file` grammar and completion candidates provide their final insertion.
enum SlashCommandCompletionDetector {
    static func detect(
        _ draft: String,
        descriptor: SlashCommandDescriptor,
        draftRevision: Int = 0
    ) -> SlashCommandCompletionMatch? {
        guard let kind = descriptor.input?.completion,
              let parsed = SlashCommandParser.parse(draft),
              parsed.name == descriptor.name,
              !parsed.rawInput.isEmpty else { return nil }
        let characters = Array(draft)
        guard let separator = characters.firstIndex(where: { $0.isWhitespace }),
              !characters[(separator + 1)...].contains(where: { $0.isNewline }) else {
            return nil
        }
        let tokenStart = (characters.lastIndex(where: { $0.isWhitespace }) ?? separator) + 1
        guard tokenStart <= characters.count else { return nil }
        let query = String(characters[tokenStart...])
        return SlashCommandCompletionMatch(
            command: parsed.name,
            kind: kind,
            hit: InputTriggerHit(
                trigger: .slash,
                query: query,
                position: .leading,
                span: InputTriggerSpan(
                    start: tokenStart,
                    end: characters.count,
                    draftRevision: draftRevision
                )
            )
        )
    }

    static func filter(
        _ candidates: [SlashCommandCompletionCandidate],
        query: String
    ) -> [SlashCommandCompletionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.source.rawValue)\u{0}\(candidate.value.lowercased())"
            guard seen.insert(key).inserted else { return false }
            guard !needle.isEmpty else { return true }
            return candidate.value.lowercased().contains(needle)
                || (candidate.detail?.lowercased().contains(needle) ?? false)
        }.sorted {
            let leftPrefix = $0.value.lowercased().hasPrefix(needle)
            let rightPrefix = $1.value.lowercased().hasPrefix(needle)
            if leftPrefix != rightPrefix { return leftPrefix }
            return $0.value.localizedStandardCompare($1.value) == .orderedAscending
        }
    }
}

/// Matches the pinned Harness word-boundary and URL carve-out behavior.
enum InputTriggerDetector {
    static func detect(
        _ draft: String,
        caretOffset: Int? = nil,
        guardTier: InputTriggerGuardTier = .plain,
        draftRevision: Int = 0
    ) -> InputTriggerHit? {
        guard guardTier != .frozen else { return nil }
        let characters = Array(draft)
        let caret = caretOffset ?? characters.count
        guard caret > 0, caret <= characters.count else { return nil }

        // Official file-reference completion keeps an open `@"path with
        // spaces` token active until its closing quote is inserted. Search
        // this form before the ordinary whitespace-delimited token scan.
        if let quoted = quotedFileToken(
               characters,
               caret: caret,
               draftRevision: draftRevision
           ) {
            return quoted
        }

        for index in stride(from: caret - 1, through: 0, by: -1) {
            let character = characters[index]
            if isWhitespace(character) { return nil }

            let trigger: InputTriggerCharacter
            switch character {
            case "/": trigger = .slash
            case "@": trigger = .at
            default: continue
            }
            if guardTier == .claimed, trigger == .slash { continue }
            guard boundaryIsValid(characters, index: index, trigger: trigger) else {
                continue
            }

            let query = String(characters[(index + 1)..<caret])
            let firstNonWhitespace = characters.firstIndex(where: { !isWhitespace($0) })
            return InputTriggerHit(
                trigger: trigger,
                query: query,
                position: firstNonWhitespace == index ? .leading : .inline,
                span: InputTriggerSpan(
                    start: index,
                    end: caret,
                    draftRevision: draftRevision
                )
            )
        }
        return nil
    }

    private static func quotedFileToken(
        _ characters: [Character],
        caret: Int,
        draftRevision: Int
    ) -> InputTriggerHit? {
        guard caret >= 2 else { return nil }
        for index in stride(from: caret - 2, through: 0, by: -1) {
            guard characters[index] == "@",
                  characters[index + 1] == "\"",
                  boundaryIsValid(characters, index: index, trigger: .at) else {
                continue
            }
            let queryStart = index + 2
            guard !characters[queryStart..<caret].contains("\"") else { return nil }
            let firstNonWhitespace = characters.firstIndex(where: { !isWhitespace($0) })
            return InputTriggerHit(
                trigger: .at,
                query: String(characters[queryStart..<caret]),
                position: firstNonWhitespace == index ? .leading : .inline,
                span: InputTriggerSpan(
                    start: index,
                    end: caret,
                    draftRevision: draftRevision
                ),
                quoted: true
            )
        }
        return nil
    }

    static func replacing(
        _ draft: String,
        span: InputTriggerSpan,
        with replacement: String,
        currentRevision: Int
    ) -> String? {
        guard span.draftRevision == currentRevision else { return nil }
        let characters = Array(draft)
        guard span.start >= 0,
              span.end >= span.start,
              span.end <= characters.count else { return nil }
        return String(characters[..<span.start])
            + replacement
            + String(characters[span.end...])
    }

    private static func boundaryIsValid(
        _ draft: [Character],
        index: Int,
        trigger: InputTriggerCharacter
    ) -> Bool {
        guard index > 0 else { return true }
        let previous = draft[index - 1]
        if isWhitespace(previous) { return true }
        if isWordCharacter(previous) { return false }
        if trigger == .slash {
            if previous == "/" { return false }
            if previous == ":", index >= 2, !isWhitespace(draft[index - 2]) {
                return false
            }
        }
        return true
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        if character == "_" { return true }
        return character.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .decimalNumber,
                 .letterNumber, .otherNumber:
                true
            default:
                false
            }
        }
    }
}

/// Model-free addressed input accepted by the native composer. The UUID is a
/// durable child address, not a display label, which keeps routing stable when
/// labels change or two children share the same label.
struct AddressedSubagentInput: Sendable, Equatable {
    let address: String
    let message: String
}

enum AddressedSubagentInputParser {
    static let maximumMessageUTF8Bytes = 48 * 1_024

    static func parse(_ input: String) -> AddressedSubagentInput? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "@" else { return nil }
        let body = trimmed.dropFirst()
        guard let boundary = body.firstIndex(where: \Character.isWhitespace) else {
            return nil
        }
        let rawAddress = String(body[..<boundary])
        guard let uuid = UUID(uuidString: rawAddress) else { return nil }
        let message = body[boundary...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              message.utf8.count <= maximumMessageUTF8Bytes else {
            return nil
        }
        return AddressedSubagentInput(
            address: uuid.uuidString.lowercased(),
            message: message
        )
    }
}

// MARK: - Parser

/// The result of parsing a line before command-directory lookup.
///
/// Harness keeps the separator whitespace in `rawInput` so each command owns
/// its argument grammar.  This is intentionally a value type: a command
/// adapter can pass it across an actor boundary without retaining the draft
/// text buffer.
struct ParsedSlashCommand: Codable, Sendable, Equatable {
    /// Lowercase ASCII command name without the leading slash.
    let name: String
    /// Exact bytes after the command name, including separator whitespace.
    let rawInput: String

    var trimmedInput: String {
        rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SlashCommandParseError: String, Codable, Sendable, Equatable, Error {
    case lineTooLong
    case missingName
    case invalidNameStart
    case invalidNameCharacter
    case invalidNameBoundary

    var message: String {
        switch self {
        case .lineTooLong:
            return "The slash command is too long (maximum 64 KiB)."
        case .missingName:
            return "A slash command needs a name, for example /help."
        case .invalidNameStart:
            return "Command names must start with a lowercase ASCII letter."
        case .invalidNameCharacter:
            return "Command names may contain only lowercase letters, digits, '_' and '-'."
        case .invalidNameBoundary:
            return "Separate the command name from its arguments with whitespace."
        }
    }
}

enum SlashCommandParseOutcome: Sendable, Equatable {
    case notACommand
    case invalid(SlashCommandParseError)
    case parsed(ParsedSlashCommand)
}

/// Parser matching the fixed `@deepseek-ai/dsh-commands` grammar.
///
/// Parsing is byte-oriented on purpose.  The upstream contract requires the
/// slash at byte zero and an ASCII command name; using `Character` here would
/// accidentally accept Unicode letters or normalize the separator.
enum SlashCommandParser {
    static let maximumLineBytes = 64 * 1_024
    static let maximumNameBytes = 64

    static func parse(_ line: String) -> ParsedSlashCommand? {
        guard case let .parsed(command) = parseDetailed(line) else { return nil }
        return command
    }

    static func parseDetailed(_ line: String) -> SlashCommandParseOutcome {
        let byteCount = line.utf8.count
        guard byteCount <= maximumLineBytes else {
            // Check the cheap count before materializing the UTF-8 buffer so a
            // pasted megabyte-scale draft cannot cause an equally large
            // temporary allocation in the command path.
            return line.utf8.first == 0x2F ? .invalid(.lineTooLong) : .notACommand
        }
        let bytes = Array(line.utf8)
        guard !bytes.isEmpty, bytes[0] == 0x2F else { return .notACommand }
        guard bytes.count > 1 else { return .invalid(.missingName) }

        let first = bytes[1]
        guard isLowercaseLetter(first) else { return .invalid(.invalidNameStart) }

        var nameEnd = 2
        while nameEnd < bytes.count, isNameByte(bytes[nameEnd]) {
            nameEnd += 1
            if nameEnd - 1 >= maximumNameBytes {
                return .invalid(.invalidNameCharacter)
            }
        }

        guard nameEnd == bytes.count || isSeparator(bytes[nameEnd]) else {
            return .invalid(.invalidNameBoundary)
        }

        // The command name is ASCII, so the byte offset is also a String
        // index offset.  This avoids lossy substring conversion for rawInput.
        let nameEndIndex = line.index(line.startIndex, offsetBy: nameEnd)
        let nameStartIndex = line.index(after: line.startIndex)
        let name = String(line[nameStartIndex..<nameEndIndex])
        let rawInput = String(line[nameEndIndex...])
        return .parsed(ParsedSlashCommand(name: name, rawInput: rawInput))
    }

    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumNameBytes,
              isLowercaseLetter(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy(isNameByte)
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLowercaseLetter(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}

/// Compatibility spelling used by the pinned Harness command package.
func parseCommand(_ line: String) -> ParsedSlashCommand? {
    SlashCommandParser.parse(line)
}

// MARK: - Command contract

struct SlashCommandInputDescriptor: Codable, Sendable, Equatable {
    let hint: String
    let completion: SlashCommandCompletionKind?

    init(
        hint: String,
        completion: SlashCommandCompletionKind? = nil
    ) throws {
        guard !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlashCommandRegistryError.invalidInputHint
        }
        self.hint = hint
        self.completion = completion
    }
}

/// Explicit command-level image admission. A command that does not opt in
/// must reject a staged image instead of silently dropping it.
enum SlashCommandImagePolicy: String, Codable, Sendable, Equatable {
    case rejected
    case accepted
}

struct SlashCommandDescriptor: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let description: String
    let input: SlashCommandInputDescriptor?
    let imagePolicy: SlashCommandImagePolicy

    var id: String { name }

    init(
        name: String,
        description: String,
        input: SlashCommandInputDescriptor? = nil,
        imagePolicy: SlashCommandImagePolicy = .rejected
    ) throws {
        guard SlashCommandParser.isValidName(name) else {
            throw SlashCommandRegistryError.invalidName(name)
        }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlashCommandRegistryError.emptyDescription(name)
        }
        self.name = name
        self.description = description
        self.input = input
        self.imagePolicy = imagePolicy
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case input
        case imagePolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            description: container.decode(String.self, forKey: .description),
            input: container.decodeIfPresent(SlashCommandInputDescriptor.self, forKey: .input),
            imagePolicy: container.decodeIfPresent(SlashCommandImagePolicy.self, forKey: .imagePolicy) ?? .rejected
        )
    }
}

/// Session-local model route selected by `/model`.
struct SlashModelSelection: Codable, Sendable, Equatable {
    let provider: String?
    let model: String
    let reasoning: String?

    init(provider: String? = nil, model: String, reasoning: String? = nil) throws {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty, !normalizedModel.contains(where: { $0.isWhitespace }) else {
            throw SlashCommandArgumentError.invalidModel
        }
        if let provider {
            let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedProvider.isEmpty, !normalizedProvider.contains(where: { $0.isWhitespace }) else {
                throw SlashCommandArgumentError.invalidModel
            }
            self.provider = normalizedProvider
        } else {
            self.provider = nil
        }
        self.model = normalizedModel
        self.reasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SlashPlanMode: String, Codable, Sendable, Equatable {
    case on
    case off
}

/// Mutations exposed by `/goal`. Validation and persistence remain in the
/// shared WorkStateCoordinator used by native controls and Agent tools.
enum SlashGoalCommandOperation: String, Codable, Sendable, Equatable {
    case edit
    case pause
    case resume
    case complete
    case block
    case clear
}

enum SlashFeedbackOperation: Codable, Sendable, Equatable {
    case show
    case setRating(MessageFeedbackRating)
    case note(String)
    case clear

    private enum CodingKeys: String, CodingKey { case kind, rating, note }
    private enum Kind: String, Codable { case show, setRating, note, clear }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .show: self = .show
        case .setRating:
            self = .setRating(try container.decode(MessageFeedbackRating.self, forKey: .rating))
        case .note:
            self = .note(try container.decode(String.self, forKey: .note))
        case .clear: self = .clear
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .show:
            try container.encode(Kind.show, forKey: .kind)
        case let .setRating(rating):
            try container.encode(Kind.setRating, forKey: .kind)
            try container.encode(rating, forKey: .rating)
        case let .note(note):
            try container.encode(Kind.note, forKey: .kind)
            try container.encode(note, forKey: .note)
        case .clear:
            try container.encode(Kind.clear, forKey: .kind)
        }
    }
}

/// A typed intent returned by the built-in command definitions.  The command
/// layer never mutates session state itself; the owning app/domain consumes the
/// action after the direct command result is rendered.
enum SlashCommandAction: Codable, Sendable, Equatable {
    case help(query: String?)
    case newSession(title: String?)
    case clear
    case goal(message: String?)
    case goalCommand(operation: SlashGoalCommandOperation, message: String?)
    case feedback(messageID: UUID?, operation: SlashFeedbackOperation)
    case plan(mode: SlashPlanMode, message: String?)
    case agent(preset: String?)
    case model(selection: SlashModelSelection?)
    case compact
    case status

    private enum CodingKeys: String, CodingKey {
        case kind
        case query
        case title
        case mode
        case message
        case operation
        case messageID
        case feedbackOperation
        case preset
        case selection
    }

    private enum Kind: String, Codable {
        case help
        case newSession
        case clear
        case goal
        case plan
        case agent
        case model
        case compact
        case status
        case goalCommand
        case feedback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .help:
            self = .help(query: try container.decodeIfPresent(String.self, forKey: .query))
        case .newSession:
            self = .newSession(title: try container.decodeIfPresent(String.self, forKey: .title))
        case .clear:
            self = .clear
        case .goal:
            self = .goal(message: try container.decodeIfPresent(String.self, forKey: .message))
        case .goalCommand:
            self = .goalCommand(
                operation: try container.decode(SlashGoalCommandOperation.self, forKey: .operation),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .feedback:
            self = .feedback(
                messageID: try container.decodeIfPresent(UUID.self, forKey: .messageID),
                operation: try container.decode(SlashFeedbackOperation.self, forKey: .feedbackOperation)
            )
        case .plan:
            self = .plan(
                mode: try container.decode(SlashPlanMode.self, forKey: .mode),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .agent:
            self = .agent(preset: try container.decodeIfPresent(String.self, forKey: .preset))
        case .model:
            self = .model(selection: try container.decodeIfPresent(SlashModelSelection.self, forKey: .selection))
        case .compact:
            self = .compact
        case .status:
            self = .status
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .help(query):
            try container.encode(Kind.help, forKey: .kind)
            try container.encodeIfPresent(query, forKey: .query)
        case let .newSession(title):
            try container.encode(Kind.newSession, forKey: .kind)
            try container.encodeIfPresent(title, forKey: .title)
        case .clear:
            try container.encode(Kind.clear, forKey: .kind)
        case let .goal(message):
            try container.encode(Kind.goal, forKey: .kind)
            try container.encodeIfPresent(message, forKey: .message)
        case let .goalCommand(operation, message):
            try container.encode(Kind.goalCommand, forKey: .kind)
            try container.encode(operation, forKey: .operation)
            try container.encodeIfPresent(message, forKey: .message)
        case let .feedback(messageID, operation):
            try container.encode(Kind.feedback, forKey: .kind)
            try container.encodeIfPresent(messageID, forKey: .messageID)
            try container.encode(operation, forKey: .feedbackOperation)
        case let .plan(mode, message):
            try container.encode(Kind.plan, forKey: .kind)
            try container.encode(mode, forKey: .mode)
            try container.encodeIfPresent(message, forKey: .message)
        case let .agent(preset):
            try container.encode(Kind.agent, forKey: .kind)
            try container.encodeIfPresent(preset, forKey: .preset)
        case let .model(selection):
            try container.encode(Kind.model, forKey: .kind)
            try container.encodeIfPresent(selection, forKey: .selection)
        case .compact:
            try container.encode(Kind.compact, forKey: .kind)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        }
    }
}

enum SlashCommandErrorCode: String, Codable, Sendable, Equatable {
    case invalidArguments
    case unknownCommand
    case invalidSyntax
    case handlerFailed
    case cancelled
    case rejected
}

/// Shared copy for an acknowledgement gate, migrated from the pinned
/// `ui-commands` popup contract.
struct SlashCommandConfirmation: Codable, Sendable, Equatable {
    let title: String
    let description: String
    let acknowledgeLabel: String
    let cancelLabel: String
    let confirmLabel: String
}

struct SlashCommandSelectOption: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let detail: String?
    let active: Bool
    let confirmation: SlashCommandConfirmation?

    init(
        id: String,
        label: String,
        detail: String? = nil,
        active: Bool = false,
        confirmation: SlashCommandConfirmation? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.active = active
        self.confirmation = confirmation
    }
}

enum SlashCommandInteractionRequest: Codable, Sendable, Equatable {
    case popupSelect(title: String, options: [SlashCommandSelectOption])
    case confirmation(SlashCommandConfirmation)
}

enum SlashCommandInteractionResponse: Codable, Sendable, Equatable {
    case selected(optionID: String)
    case confirmed
    case denied
    case cancelled
}

/// Direct, model-free command output.  `action` is intentionally separate
/// from `text`: command output never enters model history, while an action can
/// be applied by the session owner after the UI acknowledges it.
struct SlashCommandResult: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case success
        case error
        case interaction
    }

    let kind: Kind
    let text: String?
    let action: SlashCommandAction?
    let sourceEventSequence: Int?
    let errorCode: SlashCommandErrorCode?
    let interaction: SlashCommandInteractionRequest?

    static func success(
        text: String? = nil,
        action: SlashCommandAction? = nil,
        sourceEventSequence: Int? = nil
    ) -> SlashCommandResult {
        SlashCommandResult(
            kind: .success,
            text: text,
            action: action,
            sourceEventSequence: sourceEventSequence,
            errorCode: nil,
            interaction: nil
        )
    }

    static func failure(
        _ code: SlashCommandErrorCode,
        text: String
    ) -> SlashCommandResult {
        SlashCommandResult(
            kind: .error,
            text: text,
            action: nil,
            sourceEventSequence: nil,
            errorCode: code,
            interaction: nil
        )
    }

    static func interaction(_ request: SlashCommandInteractionRequest) -> SlashCommandResult {
        SlashCommandResult(
            kind: .interaction,
            text: nil,
            action: nil,
            sourceEventSequence: nil,
            errorCode: nil,
            interaction: request
        )
    }

    var isSuccess: Bool { kind == .success }
    var isTerminal: Bool { kind != .interaction }
}

struct SlashCommandInvocation: Sendable {
    let commandID: String
    let scope: String?
    let parsed: ParsedSlashCommand
    let descriptor: SlashCommandDescriptor
    /// Mirrors Harness' `recordInput` policy for a future durable command log.
    let recordInput: Bool
    /// Images staged for this invocation.  Keeping the references on the
    /// immutable invocation lets interaction resumes and native handlers see
    /// the same attachments without re-reading composer state.
    let imageAttachments: [AgentImageAttachmentRef]
    /// A typed answer supplied when the UI resumes the same command call.
    let interactionResponse: SlashCommandInteractionResponse?
}

typealias SlashCommandHandler = @Sendable (SlashCommandInvocation) async throws -> SlashCommandResult

struct SlashCommandDefinition: Sendable {
    let descriptor: SlashCommandDescriptor
    let recordInput: Bool
    let handler: SlashCommandHandler

    init(
        name: String,
        description: String,
        input: SlashCommandInputDescriptor? = nil,
        imagePolicy: SlashCommandImagePolicy = .rejected,
        recordInput: Bool = true,
        handler: @escaping SlashCommandHandler
    ) throws {
        self.descriptor = try SlashCommandDescriptor(
            name: name,
            description: description,
            input: input,
            imagePolicy: imagePolicy
        )
        self.recordInput = recordInput
        self.handler = handler
    }
}

struct SlashCommandRegistration: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let scope: String?
    let origin: SlashCommandOrigin
}

/// One merged command directory. Scoped registrations shadow globals first;
/// within a layer Host owns the canonical row, then audited nativeClient
/// contributions, then app-native contributions. Removing a winner reveals
/// the next live row instead of leaving stale metadata behind.
enum SlashCommandOrigin: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case host
    case nativeClient
    case native

    fileprivate var priority: Int {
        switch self {
        case .host: 0
        case .nativeClient: 1
        case .native: 2
        }
    }
}

struct SlashCommandExecution: Codable, Sendable, Equatable {
    let commandID: String
    let scope: String?
    let parsed: ParsedSlashCommand
    let descriptor: SlashCommandDescriptor
    let recordInput: Bool
    let result: SlashCommandResult
}

/// A resolved command whose pairing identity has been minted but whose handler
/// has not started. UI adapters use this boundary to durably append
/// `command/run` before invoking plugin-owned command code.
struct PreparedSlashCommand: Sendable {
    let invocation: SlashCommandInvocation
    fileprivate let definition: SlashCommandDefinition
}

enum SlashCommandPreparationResult: Sendable {
    case notACommand
    case invalidSyntax(SlashCommandParseError)
    case unknownCommand(ParsedSlashCommand)
    case prepared(PreparedSlashCommand)
}

enum SlashCommandDispatchResult: Sendable, Equatable {
    case notACommand
    case invalidSyntax(SlashCommandParseError)
    case unknownCommand(ParsedSlashCommand)
    case executed(SlashCommandExecution)

    /// Stable direct text for an adapter that only needs to show admission
    /// failures.  A successful execution's text remains in `result.text`.
    var userMessage: String? {
        switch self {
        case .notACommand:
            return nil
        case let .invalidSyntax(error):
            return error.message
        case let .unknownCommand(command):
            return "Unknown command /\(command.name). Use /help to list commands."
        case let .executed(execution):
            return execution.result.text
        }
    }

    /// Convert an admission outcome into the same result shape used by a
    /// resolved handler. `nil` means the line was ordinary model text.
    var directResult: SlashCommandResult? {
        switch self {
        case .notACommand:
            return nil
        case let .invalidSyntax(error):
            return .failure(.invalidSyntax, text: error.message)
        case let .unknownCommand(command):
            return .failure(
                .unknownCommand,
                text: "Unknown command /\(command.name). Use /help to list commands."
            )
        case let .executed(execution):
            return execution.result
        }
    }
}

enum SlashCommandRegistryError: LocalizedError, Sendable, Equatable {
    case invalidName(String)
    case emptyDescription(String)
    case invalidInputHint
    case duplicate(String, scope: String?)
    case invalidScope

    var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            return "Command name \"\(name)\" must match [a-z][a-z0-9_-]*."
        case let .emptyDescription(name):
            return "Command \"\(name)\" description must not be empty."
        case .invalidInputHint:
            return "Command input hint must not be empty."
        case let .duplicate(name, scope):
            if let scope {
                return "Command \"\(name)\" is already registered in scope \"\(scope)\"."
            }
            return "Command \"\(name)\" is already registered globally."
        case .invalidScope:
            return "Command scope must be a non-empty identifier."
        }
    }
}

enum SlashCommandArgumentError: LocalizedError, Sendable, Equatable {
    case tooLong(command: String, maximumBytes: Int)
    case unexpectedArguments(command: String, usage: String? = nil)
    case missingArgument(command: String, usage: String)
    case invalidArguments(command: String, usage: String? = nil)
    case invalidModel
    case invalidReasoningMode
    case invalidAgentName

    var errorDescription: String? {
        switch self {
        case let .tooLong(command, maximumBytes):
            return "/\(command) input exceeds \(maximumBytes) bytes."
        case let .unexpectedArguments(command, usage):
            if let usage {
                return "Usage: \(usage)"
            }
            return "Unexpected arguments for /\(command)."
        case let .missingArgument(command, usage):
            return "Missing argument for /\(command). Usage: \(usage)"
        case let .invalidArguments(command, usage):
            if let usage {
                return "Invalid arguments for /\(command). Usage: \(usage)"
            }
            return "Invalid arguments for /\(command)."
        case .invalidModel:
            return "Model names and providers must be non-empty and contain no whitespace."
        case .invalidReasoningMode:
            return "Reasoning must be one of providerDefault, off, low, high, or max."
        case .invalidAgentName:
            return "Agent preset names must be non-empty and contain no whitespace."
        }
    }
}

// MARK: - Registry

/// Upgrade-friendly local command registry.
///
/// This mirrors the upstream global-plus-scoped command view: a scoped
/// registration shadows a global one for that scope, duplicate registrations
/// in one layer fail, and command dispatch never forwards slash text to the
/// model.  The registry is an actor because registration and async handlers
/// may be driven by multiple SwiftUI surfaces at once.
actor SlashCommandRegistry {
    private struct Entry: Sendable {
        let registration: SlashCommandRegistration
        let definition: SlashCommandDefinition
    }

    private struct PendingInteraction: Sendable {
        let prepared: PreparedSlashCommand
        let request: SlashCommandInteractionRequest
    }

    private typealias OriginLayer = [SlashCommandOrigin: Entry]
    private typealias NameLayer = [String: OriginLayer]

    private var global: NameLayer
    private var scoped: [String: NameLayer]
    private var pendingInteractions: [String: PendingInteraction] = [:]
    private var sequence = 0
    private let instanceToken: String

    init(includeBuiltIns: Bool = true, instanceToken: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.global = [:]
        self.scoped = [:]
        self.instanceToken = instanceToken
        if includeBuiltIns {
            for definition in SlashCommandBuiltins.definitions {
                let registration = SlashCommandRegistration(
                    id: "builtin-\(definition.descriptor.name)",
                    name: definition.descriptor.name,
                    scope: nil,
                    origin: .host
                )
                global[definition.descriptor.name] = [
                    .host: Entry(registration: registration, definition: definition)
                ]
            }
        }
    }

    /// Register one global or scope-specific definition.
    @discardableResult
    func register(
        _ definition: SlashCommandDefinition,
        scope: String? = nil,
        origin: SlashCommandOrigin = .native
    ) throws -> SlashCommandRegistration {
        let normalizedScope = try Self.normalizeScope(scope)
        if normalizedScope == nil {
            guard global[definition.descriptor.name]?[origin] == nil else {
                throw SlashCommandRegistryError.duplicate(definition.descriptor.name, scope: nil)
            }
        } else {
            var layer = scoped[normalizedScope!] ?? [:]
            guard layer[definition.descriptor.name]?[origin] == nil else {
                throw SlashCommandRegistryError.duplicate(definition.descriptor.name, scope: normalizedScope)
            }
            let registration = mintRegistration(
                name: definition.descriptor.name,
                scope: normalizedScope,
                origin: origin
            )
            var origins = layer[definition.descriptor.name] ?? [:]
            origins[origin] = Entry(registration: registration, definition: definition)
            layer[definition.descriptor.name] = origins
            scoped[normalizedScope!] = layer
            return registration
        }
        let registration = mintRegistration(
            name: definition.descriptor.name,
            scope: nil,
            origin: origin
        )
        var origins = global[definition.descriptor.name] ?? [:]
        origins[origin] = Entry(registration: registration, definition: definition)
        global[definition.descriptor.name] = origins
        return registration
    }

    /// Remove a registration.  Built-ins can be removed by token as well,
    /// which lets tests and future plugin composition disable a feature cleanly.
    @discardableResult
    func unregister(_ registration: SlashCommandRegistration) -> Bool {
        if let entry = global[registration.name]?[registration.origin],
           entry.registration.id == registration.id {
            global[registration.name]?.removeValue(forKey: registration.origin)
            if global[registration.name]?.isEmpty == true {
                global.removeValue(forKey: registration.name)
            }
            return true
        }
        guard let scope = registration.scope,
              var layer = scoped[scope],
              let entry = layer[registration.name]?[registration.origin],
              entry.registration.id == registration.id else { return false }
        layer[registration.name]?.removeValue(forKey: registration.origin)
        if layer[registration.name]?.isEmpty == true {
            layer.removeValue(forKey: registration.name)
        }
        if layer.isEmpty {
            scoped.removeValue(forKey: scope)
        } else {
            scoped[scope] = layer
        }
        return true
    }

    func descriptor(named name: String, scope: String? = nil) -> SlashCommandDescriptor? {
        effectiveEntry(name: name, scope: scope)?.definition.descriptor
    }

    /// Resolve the full immutable definition for an integration that needs to
    /// inspect `recordInput` or invoke a command from a non-text trigger.
    func definition(named name: String, scope: String? = nil) -> SlashCommandDefinition? {
        effectiveEntry(name: name, scope: scope)?.definition
    }

    func list(scope: String? = nil) -> [SlashCommandDescriptor] {
        effectiveEntries(scope: scope)
            .values
            .map { $0.definition.descriptor }
            .sorted { $0.name < $1.name }
    }

    /// Upstream-style fuzzy discovery.  Exact command resolution remains
    /// strict; fuzzy matching is only for the slash menu.
    func search(_ query: String, scope: String? = nil) -> [SlashCommandDescriptor] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "/" })
            .lowercased()
        let descriptors = list(scope: scope)
        guard !normalized.isEmpty else { return descriptors }
        let ranked = descriptors.enumerated().compactMap { index, descriptor -> RankedCommand? in
            guard let score = Self.fuzzyScore(name: descriptor.name.lowercased(), query: normalized) else {
                return nil
            }
            return RankedCommand(
                descriptor: descriptor,
                index: index,
                prefix: descriptor.name.lowercased().hasPrefix(normalized),
                score: score
            )
        }
        return ranked
            .sorted {
                if $0.prefix != $1.prefix { return $0.prefix }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            .map(\.descriptor)
    }

    /// Render a portable help surface from the current effective directory.
    func helpText(query: String? = nil, scope: String? = nil) -> String {
        let rows = search(query ?? "", scope: scope)
        guard !rows.isEmpty else {
            return query?.isEmpty == false ? "No commands match \"\(query!)\"." : "No slash commands are available."
        }
        return rows.map { descriptor in
            let hint = descriptor.input.map { " \($0.hint)" } ?? ""
            return "/\(descriptor.name)\(hint) — \(descriptor.description)"
        }.joined(separator: "\n")
    }

    /// Parse and resolve one line without entering its handler. Unknown or
    /// malformed lines are represented explicitly and never become model input.
    func prepare(
        _ line: String,
        scope: String? = nil
    ) -> SlashCommandPreparationResult {
        switch SlashCommandParser.parseDetailed(line) {
        case .notACommand:
            return .notACommand
        case let .invalid(error):
            return .invalidSyntax(error)
        case let .parsed(parsed):
            guard let entry = effectiveEntry(name: parsed.name, scope: scope) else {
                return .unknownCommand(parsed)
            }
            sequence += 1
            let commandID = "cmd-\(instanceToken)-\(sequence)"
            let invocation = SlashCommandInvocation(
                commandID: commandID,
                scope: scope,
                parsed: parsed,
                descriptor: entry.definition.descriptor,
                recordInput: entry.definition.recordInput,
                imageAttachments: [],
                interactionResponse: nil
            )
            return .prepared(
                PreparedSlashCommand(
                    invocation: invocation,
                    definition: entry.definition
                )
            )
        }
    }

    /// Execute a previously resolved command. The caller may append durable
    /// lifecycle records around this method without racing a second lookup.
    func execute(
        _ prepared: PreparedSlashCommand,
        imageAttachments: [AgentImageAttachmentRef] = []
    ) async -> SlashCommandExecution {
        let attachments = imageAttachments.isEmpty
            ? prepared.invocation.imageAttachments
            : imageAttachments
        let invocation = SlashCommandInvocation(
            commandID: prepared.invocation.commandID,
            scope: prepared.invocation.scope,
            parsed: prepared.invocation.parsed,
            descriptor: prepared.invocation.descriptor,
            recordInput: prepared.invocation.recordInput,
            imageAttachments: attachments,
            interactionResponse: prepared.invocation.interactionResponse
        )
        var result = SlashCommandResult.failure(.handlerFailed, text: "Command failed.")
        if !attachments.isEmpty, invocation.descriptor.imagePolicy == .rejected {
            result = .failure(
                .invalidArguments,
                text: "/\(invocation.parsed.name) does not accept image attachments"
            )
        } else {
            do {
                try Task.checkCancellation()
                result = try await prepared.definition.handler(invocation)
                try Task.checkCancellation()
            } catch is CancellationError {
                result = .failure(.cancelled, text: "Command cancelled.")
            } catch let error as SlashCommandArgumentError {
                result = .failure(.invalidArguments, text: error.localizedDescription)
            } catch {
                result = .failure(.handlerFailed, text: Self.boundedErrorText(error))
            }
        }
        let execution = SlashCommandExecution(
            commandID: invocation.commandID,
            scope: invocation.scope,
            parsed: invocation.parsed,
            descriptor: invocation.descriptor,
            recordInput: invocation.recordInput,
            result: result
        )
        if let request = result.interaction {
            pendingInteractions[invocation.commandID] = PendingInteraction(
                prepared: PreparedSlashCommand(
                    invocation: invocation,
                    definition: prepared.definition
                ),
                request: request
            )
        } else {
            pendingInteractions.removeValue(forKey: invocation.commandID)
        }
        return execution
    }

    /// Resume the exact handler whose interaction is on screen. Selection and
    /// confirmation re-enter that handler with a typed response; dismissal and
    /// rejection settle locally so an untrusted provider cannot turn a refusal
    /// into another side effect.
    func resumeInteraction(
        commandID: String,
        response: SlashCommandInteractionResponse
    ) async -> SlashCommandExecution? {
        guard let pending = pendingInteractions.removeValue(forKey: commandID) else {
            return nil
        }
        let original = pending.prepared.invocation
        switch response {
        case .cancelled:
            return terminalInteractionExecution(
                pending.prepared,
                result: .failure(.cancelled, text: "Command interaction cancelled.")
            )
        case .denied:
            return terminalInteractionExecution(
                pending.prepared,
                result: .failure(.rejected, text: "Command confirmation denied.")
            )
        case let .selected(optionID):
            guard case let .popupSelect(_, options) = pending.request,
                  options.contains(where: { $0.id == optionID }) else {
                return terminalInteractionExecution(
                    pending.prepared,
                    result: .failure(.invalidArguments, text: "The selected command option is no longer available.")
                )
            }
        case .confirmed:
            guard case .confirmation = pending.request else {
                return terminalInteractionExecution(
                    pending.prepared,
                    result: .failure(.invalidArguments, text: "This command is not awaiting confirmation.")
                )
            }
        }
        let resumed = PreparedSlashCommand(
            invocation: SlashCommandInvocation(
                commandID: original.commandID,
                scope: original.scope,
                parsed: original.parsed,
                descriptor: original.descriptor,
                recordInput: original.recordInput,
                imageAttachments: original.imageAttachments,
                interactionResponse: response
            ),
            definition: pending.prepared.definition
        )
        return await execute(resumed)
    }

    private func terminalInteractionExecution(
        _ prepared: PreparedSlashCommand,
        result: SlashCommandResult
    ) -> SlashCommandExecution {
        let invocation = prepared.invocation
        return SlashCommandExecution(
            commandID: invocation.commandID,
            scope: invocation.scope,
            parsed: invocation.parsed,
            descriptor: invocation.descriptor,
            recordInput: invocation.recordInput,
            result: result
        )
    }

    /// Convenience path for callers that do not own a durable session log.
    func dispatch(_ line: String, scope: String? = nil) async -> SlashCommandDispatchResult {
        switch prepare(line, scope: scope) {
        case .notACommand:
            return .notACommand
        case let .invalidSyntax(error):
            return .invalidSyntax(error)
        case let .unknownCommand(command):
            return .unknownCommand(command)
        case let .prepared(prepared):
            return .executed(await execute(prepared))
        }
    }

    private func effectiveEntry(name: String, scope: String?) -> Entry? {
        if let scope, let origins = scoped[scope]?[name],
           let scopedEntry = Self.winner(in: origins) {
            return scopedEntry
        }
        return global[name].flatMap(Self.winner(in:))
    }

    private func effectiveEntries(scope: String?) -> [String: Entry] {
        var result = global.compactMapValues(Self.winner(in:))
        if let scope, let layer = scoped[scope] {
            for (name, origins) in layer {
                if let entry = Self.winner(in: origins) { result[name] = entry }
            }
        }
        return result
    }

    private static func winner(in origins: OriginLayer) -> Entry? {
        origins.min { left, right in
            left.key.priority < right.key.priority
        }?.value
    }

    private func mintRegistration(
        name: String,
        scope: String?,
        origin: SlashCommandOrigin
    ) -> SlashCommandRegistration {
        sequence += 1
        return SlashCommandRegistration(
            id: "registration-\(instanceToken)-\(sequence)",
            name: name,
            scope: scope,
            origin: origin
        )
    }

    private static func normalizeScope(_ scope: String?) throws -> String? {
        guard let scope else { return nil }
        let normalized = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              !normalized.contains(where: { $0.isWhitespace }) else {
            throw SlashCommandRegistryError.invalidScope
        }
        return normalized
    }

    private static func boundedErrorText(_ error: Error) -> String {
        let bytes = Array(error.localizedDescription.utf8.prefix(4 * 1_024))
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct RankedCommand {
        let descriptor: SlashCommandDescriptor
        let index: Int
        let prefix: Bool
        let score: Int
    }

    private static func fuzzyScore(name: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= name.count else { return nil }
        let characters = Array(name)
        let queryCharacters = Array(query)
        let noMatch = Int.min / 4
        var previous = Array(repeating: noMatch, count: characters.count)
        for index in characters.indices where characters[index] == queryCharacters[0] {
            previous[index] = 1 + boundaryBonus(name: name, index: index) - index
        }
        if queryCharacters.count > 1 {
            for queryIndex in 1..<queryCharacters.count {
                var current = Array(repeating: noMatch, count: characters.count)
                var bestGapped = noMatch
                for index in characters.indices {
                    let gapIndex = index - 2
                    if gapIndex >= 0, previous[gapIndex] != noMatch {
                        bestGapped = max(bestGapped, previous[gapIndex] + gapIndex)
                    }
                    guard characters[index] == queryCharacters[queryIndex] else { continue }
                    let bonus = 1 + boundaryBonus(name: name, index: index)
                    if index > 0, previous[index - 1] != noMatch {
                        current[index] = previous[index - 1] + bonus + 4
                    }
                    if bestGapped != noMatch {
                        current[index] = max(current[index], bestGapped + bonus + 1 - index)
                    }
                }
                previous = current
            }
        }
        let best = previous.max() ?? noMatch
        return best == noMatch ? nil : best
    }

    private static func boundaryBonus(name: String, index: Int) -> Int {
        guard index == 0 || name[name.index(name.startIndex, offsetBy: index - 1)] == "-"
                || name[name.index(name.startIndex, offsetBy: index - 1)] == "_" else { return 0 }
        return 8
    }
}

// MARK: - Built-in commands

enum SlashCommandBuiltins {
    static let definitions: [SlashCommandDefinition] = [
        make(name: "help", description: "查看可用的斜杠命令", hint: "[query]") { invocation in
            let query = try bounded(invocation.parsed.trimmedInput, command: "help", maximumBytes: 256)
            return .success(action: .help(query: query.isEmpty ? nil : query))
        },
        make(name: "new", description: "新建一个会话", hint: "[title]") { invocation in
            let title = try bounded(invocation.parsed.trimmedInput, command: "new", maximumBytes: 4 * 1_024)
            return .success(action: .newSession(title: title.isEmpty ? nil : title))
        },
        make(name: "clear", description: "清空当前会话消息") { invocation in
            try requireNoArguments(invocation, usage: "/clear (no arguments)")
            return .success(action: .clear)
        },
        make(
            name: "goal",
            description: "设置当前会话目标",
            hint: "[message]",
            imagePolicy: .accepted
        ) { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "goal", maximumBytes: 8 * 1_024)
            if let separator = input.firstIndex(where: { $0.isWhitespace }) {
                let operation = String(input[..<separator]).lowercased()
                let remainder = String(input[input.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let operation = SlashGoalCommandOperation(rawValue: operation) {
                    switch operation {
                    case .edit:
                        guard !remainder.isEmpty else {
                            throw SlashCommandArgumentError.invalidArguments(command: "goal", usage: "/goal edit <title>")
                        }
                    case .clear, .pause, .resume, .complete, .block:
                        guard remainder.isEmpty else {
                            throw SlashCommandArgumentError.invalidArguments(command: "goal", usage: "/goal <pause|resume|complete|block|clear>")
                        }
                    }
                    return .success(
                        action: .goalCommand(
                            operation: operation,
                            message: operation == .edit ? remainder : nil
                        )
                    )
                }
            } else if let operation = SlashGoalCommandOperation(rawValue: input.lowercased()) {
                guard operation != .edit else {
                    throw SlashCommandArgumentError.invalidArguments(command: "goal", usage: "/goal edit <title>")
                }
                return .success(action: .goalCommand(operation: operation, message: nil))
            }
            return .success(action: .goal(message: input.isEmpty ? nil : input))
        },
        make(
            name: "plan",
            description: "进入或退出计划模式",
            hint: "[off|on|message]",
            imagePolicy: .accepted
        ) { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "plan", maximumBytes: 8 * 1_024)
            if input.caseInsensitiveCompare("off") == .orderedSame {
                if !invocation.imageAttachments.isEmpty {
                    return .failure(
                        .invalidArguments,
                        text: "Image attachments cannot accompany /plan off."
                    )
                }
                return .success(text: "Plan mode off.", action: .plan(mode: .off, message: nil))
            }
            if input.caseInsensitiveCompare("on") == .orderedSame || input.caseInsensitiveCompare("enter") == .orderedSame {
                return .success(text: "Plan mode on. Use /plan off to leave.", action: .plan(mode: .on, message: nil))
            }
            return .success(
                text: "Plan mode on. Use /plan off to leave.",
                action: .plan(mode: .on, message: input.isEmpty ? nil : input)
            )
        },
        make(
            name: "feedback",
            description: "评价最近回复或补充备注",
            hint: "[message-id] [like|dislike|note|clear] [text]"
        ) { invocation in
            let input = try bounded(
                invocation.parsed.trimmedInput,
                command: "feedback",
                maximumBytes: MessageFeedback.maximumNoteUTF8Bytes + 256
            )
            var remainder = input
            var messageID: UUID?
            if let first = remainder.split(whereSeparator: { $0.isWhitespace }).first,
               let parsedID = UUID(uuidString: String(first)) {
                messageID = parsedID
                remainder = String(remainder.dropFirst(first.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !remainder.isEmpty else {
                return .success(action: .feedback(messageID: messageID, operation: .show))
            }
            let parts = remainder.split(
                maxSplits: 1,
                whereSeparator: { $0.isWhitespace }
            ).map(String.init)
            let command = parts[0].lowercased()
            let tail = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            switch command {
            case "like", "positive", "up", "赞", "👍":
                guard tail.isEmpty else {
                    throw SlashCommandArgumentError.invalidArguments(
                        command: "feedback",
                        usage: "/feedback [message-id] like"
                    )
                }
                return .success(action: .feedback(messageID: messageID, operation: .setRating(.positive)))
            case "dislike", "negative", "down", "踩", "👎":
                guard tail.isEmpty else {
                    throw SlashCommandArgumentError.invalidArguments(
                        command: "feedback",
                        usage: "/feedback [message-id] dislike"
                    )
                }
                return .success(action: .feedback(messageID: messageID, operation: .setRating(.negative)))
            case "note", "备注":
                guard tail.utf8.count <= MessageFeedback.maximumNoteUTF8Bytes else {
                    throw SlashCommandArgumentError.tooLong(
                        command: "feedback",
                        maximumBytes: MessageFeedback.maximumNoteUTF8Bytes
                    )
                }
                return .success(action: .feedback(messageID: messageID, operation: .note(tail)))
            case "clear", "remove", "清除":
                guard tail.isEmpty else {
                    throw SlashCommandArgumentError.invalidArguments(
                        command: "feedback",
                        usage: "/feedback [message-id] clear"
                    )
                }
                return .success(action: .feedback(messageID: messageID, operation: .clear))
            default:
                throw SlashCommandArgumentError.invalidArguments(
                    command: "feedback",
                    usage: "/feedback [message-id] [like|dislike|note|clear] [text]"
                )
            }
        },
        make(
            name: "agent",
            description: "切换 Agent 预设",
            hint: "[preset]",
            completion: .agent
        ) { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "agent", maximumBytes: 256)
            guard input.isEmpty || !input.contains(where: { $0.isWhitespace }) else {
                throw SlashCommandArgumentError.invalidAgentName
            }
            return .success(action: .agent(preset: input.isEmpty ? nil : input))
        },
        make(
            name: "model",
            description: "选择服务商与模型",
            hint: "[provider/]model [--reasoning <mode>]",
            completion: .model
        ) { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "model", maximumBytes: 512)
            return .success(action: .model(selection: try parseModelSelection(input)))
        },
        make(name: "compact", description: "压缩较早的会话历史") { invocation in
            try requireNoArguments(invocation, usage: "/compact (no arguments)")
            return .success(action: .compact)
        },
        make(name: "status", description: "查看当前会话状态") { invocation in
            try requireNoArguments(invocation, usage: "/status (no arguments)")
            return .success(action: .status)
        }
    ]

    private static func make(
        name: String,
        description: String,
        hint: String? = nil,
        completion: SlashCommandCompletionKind? = nil,
        imagePolicy: SlashCommandImagePolicy = .rejected,
        handler: @escaping SlashCommandHandler
    ) -> SlashCommandDefinition {
        do {
            let input = try hint.map {
                try SlashCommandInputDescriptor(hint: $0, completion: completion)
            }
            return try SlashCommandDefinition(
                name: name,
                description: description,
                input: input,
                imagePolicy: imagePolicy,
                handler: handler
            )
        } catch {
            // These are source-owned constants.  A failure means this pinned
            // command contract was edited inconsistently and should be loud.
            preconditionFailure("invalid built-in command /\(name): \(error)")
        }
    }

    private static func bounded(_ input: String, command: String, maximumBytes: Int) throws -> String {
        guard input.utf8.count <= maximumBytes else {
            throw SlashCommandArgumentError.tooLong(command: command, maximumBytes: maximumBytes)
        }
        return input
    }

    private static func requireNoArguments(_ invocation: SlashCommandInvocation, usage: String) throws {
        guard invocation.parsed.trimmedInput.isEmpty else {
            throw SlashCommandArgumentError.unexpectedArguments(
                command: invocation.parsed.name,
                usage: usage
            )
        }
        _ = usage // Usage is supplied by the caller's stable error wrapper below.
    }

    private static func parseModelSelection(_ input: String) throws -> SlashModelSelection? {
        guard !input.isEmpty else { return nil }
        let tokens = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return nil }
        var modelToken = first
        var reasoning: String?
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--reasoning=") {
                guard reasoning == nil else { throw SlashCommandArgumentError.invalidReasoningMode }
                reasoning = String(token.dropFirst("--reasoning=".count))
            } else if token == "--reasoning" {
                guard reasoning == nil, index + 1 < tokens.count else {
                    throw SlashCommandArgumentError.invalidReasoningMode
                }
                index += 1
                reasoning = tokens[index]
            } else {
                throw SlashCommandArgumentError.unexpectedArguments(command: "model")
            }
            index += 1
        }
        if var reasoning {
            let accepted = ["providerdefault", "off", "low", "high", "max"]
            guard accepted.contains(reasoning.lowercased()) else {
                throw SlashCommandArgumentError.invalidReasoningMode
            }
            if reasoning.lowercased() == "providerdefault" {
                reasoning = "providerDefault"
            }
        }
        let provider: String?
        if let separator = modelToken.firstIndex(of: "/") {
            provider = String(modelToken[..<separator])
            modelToken = String(modelToken[modelToken.index(after: separator)...])
        } else {
            provider = nil
        }
        guard !modelToken.isEmpty, !modelToken.contains("/") else {
            throw SlashCommandArgumentError.invalidModel
        }
        return try SlashModelSelection(provider: provider, model: modelToken, reasoning: reasoning)
    }
}
