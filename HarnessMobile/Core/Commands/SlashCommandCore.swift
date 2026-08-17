import Foundation

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

    init(hint: String) throws {
        guard !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlashCommandRegistryError.invalidInputHint
        }
        self.hint = hint
    }
}

struct SlashCommandDescriptor: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let description: String
    let input: SlashCommandInputDescriptor?

    var id: String { name }

    init(
        name: String,
        description: String,
        input: SlashCommandInputDescriptor? = nil
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

/// A typed intent returned by the built-in command definitions.  The command
/// layer never mutates session state itself; the owning app/domain consumes the
/// action after the direct command result is rendered.
enum SlashCommandAction: Codable, Sendable, Equatable {
    case help(query: String?)
    case newSession(title: String?)
    case clear
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
        case preset
        case selection
    }

    private enum Kind: String, Codable {
        case help
        case newSession
        case clear
        case plan
        case agent
        case model
        case compact
        case status
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
}

/// Direct, model-free command output.  `action` is intentionally separate
/// from `text`: command output never enters model history, while an action can
/// be applied by the session owner after the UI acknowledges it.
struct SlashCommandResult: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case success
        case error
    }

    let kind: Kind
    let text: String?
    let action: SlashCommandAction?
    let sourceEventSequence: Int?
    let errorCode: SlashCommandErrorCode?

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
            errorCode: nil
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
            errorCode: code
        )
    }

    var isSuccess: Bool { kind == .success }
}

struct SlashCommandInvocation: Sendable {
    let commandID: String
    let scope: String?
    let parsed: ParsedSlashCommand
    let descriptor: SlashCommandDescriptor
    /// Mirrors Harness' `recordInput` policy for a future durable command log.
    let recordInput: Bool
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
        recordInput: Bool = true,
        handler: @escaping SlashCommandHandler
    ) throws {
        self.descriptor = try SlashCommandDescriptor(
            name: name,
            description: description,
            input: input
        )
        self.recordInput = recordInput
        self.handler = handler
    }
}

struct SlashCommandRegistration: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let scope: String?
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
        case .invalidModel:
            return "Model names and providers must be non-empty and contain no whitespace."
        case .invalidReasoningMode:
            return "Reasoning must be one of providerDefault, off, high, or max."
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

    private var global: [String: Entry]
    private var scoped: [String: [String: Entry]]
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
                    scope: nil
                )
                global[definition.descriptor.name] = Entry(
                    registration: registration,
                    definition: definition
                )
            }
        }
    }

    /// Register one global or scope-specific definition.
    @discardableResult
    func register(
        _ definition: SlashCommandDefinition,
        scope: String? = nil
    ) throws -> SlashCommandRegistration {
        let normalizedScope = try Self.normalizeScope(scope)
        if normalizedScope == nil {
            guard global[definition.descriptor.name] == nil else {
                throw SlashCommandRegistryError.duplicate(definition.descriptor.name, scope: nil)
            }
        } else {
            var layer = scoped[normalizedScope!] ?? [:]
            guard layer[definition.descriptor.name] == nil else {
                throw SlashCommandRegistryError.duplicate(definition.descriptor.name, scope: normalizedScope)
            }
            let registration = mintRegistration(name: definition.descriptor.name, scope: normalizedScope)
            layer[definition.descriptor.name] = Entry(registration: registration, definition: definition)
            scoped[normalizedScope!] = layer
            return registration
        }
        let registration = mintRegistration(name: definition.descriptor.name, scope: nil)
        global[definition.descriptor.name] = Entry(registration: registration, definition: definition)
        return registration
    }

    /// Remove a registration.  Built-ins can be removed by token as well,
    /// which lets tests and future plugin composition disable a feature cleanly.
    @discardableResult
    func unregister(_ registration: SlashCommandRegistration) -> Bool {
        if let entry = global[registration.name], entry.registration.id == registration.id {
            global.removeValue(forKey: registration.name)
            return true
        }
        guard let scope = registration.scope,
              var layer = scoped[scope],
              let entry = layer[registration.name],
              entry.registration.id == registration.id else { return false }
        layer.removeValue(forKey: registration.name)
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
                recordInput: entry.definition.recordInput
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
    func execute(_ prepared: PreparedSlashCommand) async -> SlashCommandExecution {
        let invocation = prepared.invocation
        var result = SlashCommandResult.failure(.handlerFailed, text: "Command failed.")
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
        if let scope, let scopedEntry = scoped[scope]?[name] {
            return scopedEntry
        }
        return global[name]
    }

    private func effectiveEntries(scope: String?) -> [String: Entry] {
        var result = global
        if let scope, let layer = scoped[scope] {
            for (name, entry) in layer { result[name] = entry }
        }
        return result
    }

    private func mintRegistration(name: String, scope: String?) -> SlashCommandRegistration {
        sequence += 1
        return SlashCommandRegistration(
            id: "registration-\(instanceToken)-\(sequence)",
            name: name,
            scope: scope
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
        make(name: "help", description: "Show available slash commands", hint: "[query]") { invocation in
            let query = try bounded(invocation.parsed.trimmedInput, command: "help", maximumBytes: 256)
            return .success(action: .help(query: query.isEmpty ? nil : query))
        },
        make(name: "new", description: "Start a new conversation", hint: "[title]") { invocation in
            let title = try bounded(invocation.parsed.trimmedInput, command: "new", maximumBytes: 4 * 1_024)
            return .success(action: .newSession(title: title.isEmpty ? nil : title))
        },
        make(name: "clear", description: "Clear the current conversation") { invocation in
            try requireNoArguments(invocation, usage: "/clear (no arguments)")
            return .success(action: .clear)
        },
        make(name: "plan", description: "Enter or leave plan mode", hint: "[off|on|message]") { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "plan", maximumBytes: 8 * 1_024)
            if input.caseInsensitiveCompare("off") == .orderedSame {
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
        make(name: "agent", description: "Choose an agent preset", hint: "[preset]") { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "agent", maximumBytes: 256)
            guard input.isEmpty || !input.contains(where: { $0.isWhitespace }) else {
                throw SlashCommandArgumentError.invalidAgentName
            }
            return .success(action: .agent(preset: input.isEmpty ? nil : input))
        },
        make(name: "model", description: "Choose a provider and model", hint: "[provider/]model [--reasoning <mode>]") { invocation in
            let input = try bounded(invocation.parsed.trimmedInput, command: "model", maximumBytes: 512)
            return .success(action: .model(selection: try parseModelSelection(input)))
        },
        make(name: "compact", description: "Compact older conversation history") { invocation in
            try requireNoArguments(invocation, usage: "/compact (no arguments)")
            return .success(action: .compact)
        },
        make(name: "status", description: "Show the current session status") { invocation in
            try requireNoArguments(invocation, usage: "/status (no arguments)")
            return .success(action: .status)
        }
    ]

    private static func make(
        name: String,
        description: String,
        hint: String? = nil,
        handler: @escaping SlashCommandHandler
    ) -> SlashCommandDefinition {
        do {
            let input = try hint.map(SlashCommandInputDescriptor.init(hint:))
            return try SlashCommandDefinition(
                name: name,
                description: description,
                input: input,
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
            let accepted = ["providerdefault", "off", "high", "max"]
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
