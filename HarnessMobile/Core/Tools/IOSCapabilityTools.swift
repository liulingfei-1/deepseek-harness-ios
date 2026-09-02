import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

#if os(iOS)
import AVFoundation
@preconcurrency import CoreBluetooth
import CoreLocation
import HealthKit
import MapKit
import MediaPlayer
import Photos
import Speech
import UIKit
import Vision
#endif

// Typed Swift replacements for the useful parts of the former OpenMinis
// apple-* command surface. Each tool owns a narrow schema and calls the public
// iOS framework directly; none of these paths enters iSH or a string command
// dispatcher.
enum IOSCapabilityToolKit {
    static let approvedNames: Set<String> = [
        "bluetooth_scan",
        "health_query",
        "maps_route",
        "maps_search",
        "media_library_search",
        "media_playback",
        "natural_language_analyze",
        "photo_library_list",
        "speech_synthesize",
        "speech_transcribe",
        "system_open",
        "vision_analyze"
    ]

#if os(iOS)
    static func makeSystemTools(workspaceStore: WorkspaceStore) -> [any LocalAgentTool] {
        [
            BluetoothScanTool(),
            HealthQueryTool(),
            MapsRouteTool(),
            MapsSearchTool(),
            MediaLibrarySearchTool(),
            MediaPlaybackTool(),
            NaturalLanguageAnalyzeTool(),
            PhotoLibraryListTool(),
            SpeechSynthesizeTool(),
            SpeechTranscribeTool(),
            SystemOpenTool(),
            VisionAnalyzeTool(store: workspaceStore)
        ]
    }
#endif
}

// MARK: - NaturalLanguage

struct NaturalLanguageAnalyzeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "natural_language_analyze",
        description: "Analyze bounded text entirely on-device with Apple NaturalLanguage: language, tokens, part-of-speech tags, named entities, and sentiment.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string"), "maxLength": .number(16_384)]),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array(["analyze", "language", "tokenize", "pos", "entities", "sentiment"].map(JSONValue.string))
                ]),
                "token_unit": .object([
                    "type": .string("string"),
                    "enum": .array(["word", "sentence", "paragraph"].map(JSONValue.string))
                ])
            ]),
            "required": .array([.string("text")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        _ = try parsed(arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let mode = arguments["mode"]?.stringValue ?? "analyze"
        return "使用本机 NaturalLanguage 执行 \(mode) 分析"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if canImport(NaturalLanguage)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return Self.analyze(text: input.text, mode: input.mode, tokenUnit: input.tokenUnit)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
#else
        throw MobileNativeToolError.hardwareUnavailable("NaturalLanguage")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (text: String, mode: String, tokenUnit: String) {
        try arguments.requireOnlyKeys(["text", "mode", "token_unit"])
        let text = try IOSCapabilityArguments.text(arguments, key: "text", maximumBytes: 32 * 1_024)
        let mode = try IOSCapabilityArguments.choice(
            arguments, key: "mode", default: "analyze",
            allowed: ["analyze", "language", "tokenize", "pos", "entities", "sentiment"]
        )
        let tokenUnit = try IOSCapabilityArguments.choice(
            arguments, key: "token_unit", default: "word",
            allowed: ["word", "sentence", "paragraph"]
        )
        return (text, mode, tokenUnit)
    }

#if canImport(NaturalLanguage)
    private static func analyze(text: String, mode: String, tokenUnit: String) -> String {
        var result: [String: JSONValue] = ["mode": .string(mode)]
        if mode == "analyze" || mode == "language" {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
                .sorted { $0.value > $1.value }
                .map { language, confidence in
                    JSONValue.object([
                        "language": .string(language.rawValue),
                        "confidence": .number(confidence)
                    ])
                }
            result["language"] = .object([
                "dominant": .string(recognizer.dominantLanguage?.rawValue ?? "unknown"),
                "hypotheses": .array(hypotheses)
            ])
        }
        if mode == "analyze" || mode == "tokenize" {
            let unit: NLTokenUnit = switch tokenUnit {
            case "sentence": .sentence
            case "paragraph": .paragraph
            default: .word
            }
            let tokenizer = NLTokenizer(unit: unit)
            tokenizer.string = text
            var tokens: [JSONValue] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if tokens.count < 512 {
                    tokens.append(.string(String(text[range])))
                }
                return tokens.count < 512
            }
            result["tokens"] = .object([
                "unit": .string(tokenUnit),
                "count": .number(Double(tokens.count)),
                "values": .array(tokens)
            ])
        }
        if mode == "analyze" || mode == "pos" {
            result["partOfSpeech"] = .array(taggedValues(
                text: text,
                scheme: .lexicalClass,
                options: [.omitWhitespace, .omitPunctuation],
                acceptedTags: nil
            ))
        }
        if mode == "analyze" || mode == "entities" {
            let accepted: Set<NLTag> = [.personalName, .placeName, .organizationName]
            result["entities"] = .array(taggedValues(
                text: text,
                scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames],
                acceptedTags: accepted
            ))
        }
        if mode == "analyze" || mode == "sentiment" {
            let tagger = NLTagger(tagSchemes: [.sentimentScore])
            tagger.string = text
            let score = tagger.tag(
                at: text.startIndex,
                unit: .paragraph,
                scheme: .sentimentScore
            ).0.flatMap { Double($0.rawValue) } ?? 0
            let label = score < -0.1 ? "negative" : (score > 0.1 ? "positive" : "neutral")
            result["sentiment"] = .object([
                "score": .number(score),
                "label": .string(label)
            ])
        }
        return JSONValue.object(result).displayText
    }

    private static func taggedValues(
        text: String,
        scheme: NLTagScheme,
        options: NLTagger.Options,
        acceptedTags: Set<NLTag>?
    ) -> [JSONValue] {
        let tagger = NLTagger(tagSchemes: [scheme])
        tagger.string = text
        var values: [JSONValue] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: scheme,
            options: options
        ) { tag, range in
            guard values.count < 512 else { return false }
            guard let tag, acceptedTags?.contains(tag) != false else { return true }
            values.append(.object([
                "text": .string(String(text[range])),
                "tag": .string(tag.rawValue)
            ]))
            return true
        }
        return values
    }
#endif
}

// MARK: - Speech and system open

struct SpeechSynthesizeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "speech_synthesize",
        description: "Speak bounded text through the iPhone speaker with AVSpeechSynthesizer, list installed voices, or stop current speech.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array(["speak", "voices", "stop"].map(JSONValue.string))]),
                "text": .object(["type": .string("string"), "maxLength": .number(8_192)]),
                "language": .object(["type": .string("string"), "maxLength": .number(64)]),
                "rate": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
                "pitch": .object(["type": .string("number"), "minimum": .number(0.5), "maximum": .number(2)]),
                "volume": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
            ]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "执行本机系统朗读：\(arguments["action"]?.stringValue ?? "speak")" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["audio:speech-synthesizer"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return await SystemSpeechSynthesizer.shared.perform(
            action: input.action,
            text: input.text,
            language: input.language,
            rate: input.rate,
            pitch: input.pitch,
            volume: input.volume
        )
#else
        throw MobileNativeToolError.hardwareUnavailable("系统朗读")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (action: String, text: String?, language: String?, rate: Double, pitch: Double, volume: Double) {
        try arguments.requireOnlyKeys(["action", "text", "language", "rate", "pitch", "volume"])
        let action = try IOSCapabilityArguments.choice(arguments, key: "action", allowed: ["speak", "voices", "stop"])
        let text = try IOSCapabilityArguments.optionalText(arguments, key: "text", maximumBytes: 16 * 1_024)
        if action == "speak", text == nil { throw LocalToolError.missingArgument("text") }
        let language = try IOSCapabilityArguments.optionalText(arguments, key: "language", maximumBytes: 64)
        let rate = try IOSCapabilityArguments.number(arguments, key: "rate", default: 0.5, range: 0...1)
        let pitch = try IOSCapabilityArguments.number(arguments, key: "pitch", default: 1, range: 0.5...2)
        let volume = try IOSCapabilityArguments.number(arguments, key: "volume", default: 1, range: 0...1)
        return (action, text, language, rate, pitch, volume)
    }
}

struct SpeechTranscribeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "speech_transcribe",
        description: "Transcribe a short foreground microphone recording with Apple's Speech framework. Recording stops at final recognition or the bounded duration.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "language": .object(["type": .string("string"), "maxLength": .number(64)]),
                "duration_seconds": .object(["type": .string("integer"), "minimum": .number(2), "maximum": .number(60)]),
                "on_device_only": .object(["type": .string("boolean")])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "使用麦克风进行一次有界语音识别；文字结果会发送给模型" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["audio:microphone", "speech:recognizer"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await LiveSpeechRecognitionBridge.perform(
            language: input.language,
            duration: .seconds(input.duration),
            onDeviceOnly: input.onDeviceOnly
        )
#else
        throw MobileNativeToolError.hardwareUnavailable("语音识别")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (language: String, duration: Int, onDeviceOnly: Bool) {
        try arguments.requireOnlyKeys(["language", "duration_seconds", "on_device_only"])
        let language = try IOSCapabilityArguments.optionalText(arguments, key: "language", maximumBytes: 64) ?? Locale.current.identifier
        let duration = try IOSCapabilityArguments.integer(arguments, key: "duration_seconds", default: 15, range: 2...60)
        let onDeviceOnly = try IOSCapabilityArguments.boolean(arguments, key: "on_device_only", default: false)
        return (language, duration, onDeviceOnly)
    }
}

struct SystemOpenTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "system_open",
        description: "Ask iOS to open a URL, Universal Link, registered app deep link, or the Harness app settings page.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "target": .object(["type": .string("string"), "maxLength": .number(2_048)])
            ]),
            "required": .array([.string("target")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws { _ = try target(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "让 iOS 打开指定系统目标或 Deep Link" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let value = try target(arguments)
        return ["system-open:\(URL(string: value)?.scheme?.lowercased() ?? "settings")"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let value = try target(arguments)
#if os(iOS)
        let resolved = value.lowercased() == "settings" ? UIApplication.openSettingsURLString : value
        guard let url = URL(string: resolved) else { throw LocalToolError.invalidArguments }
        let opened = await SystemOpenCapabilityBridge.open(url)
        guard opened else { throw MobileNativeToolError.operationFailed("打开系统目标") }
        return JSONValue.object(["opened": .bool(true), "scheme": .string(url.scheme ?? "")]).displayText
#else
        throw MobileNativeToolError.hardwareUnavailable("系统 Deep Link")
#endif
    }

    private func target(_ arguments: [String: JSONValue]) throws -> String {
        try arguments.requireOnlyKeys(["target"])
        let value = try IOSCapabilityArguments.text(arguments, key: "target", maximumBytes: 2_048)
        guard value.lowercased() == "settings" || URL(string: value)?.scheme != nil else {
            throw LocalToolError.invalidArguments
        }
        return value
    }
}

// MARK: - Maps

struct MapsSearchTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "maps_search",
        description: "Search places and points of interest with MapKit, optionally around a coordinate and radius.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "maxLength": .number(512)]),
                "latitude": .object(["type": .string("number"), "minimum": .number(-90), "maximum": .number(90)]),
                "longitude": .object(["type": .string("number"), "minimum": .number(-180), "maximum": .number(180)]),
                "radius_meters": .object(["type": .string("number"), "minimum": .number(100), "maximum": .number(100_000)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "使用 MapKit 搜索“\(arguments["query"]?.stringValue ?? "地点")”" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await MapKitCapabilityBridge.search(
            query: input.query,
            latitude: input.latitude,
            longitude: input.longitude,
            radius: input.radius,
            limit: input.limit
        )
#else
        throw MobileNativeToolError.hardwareUnavailable("MapKit")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (query: String, latitude: Double?, longitude: Double?, radius: Double, limit: Int) {
        try arguments.requireOnlyKeys(["query", "latitude", "longitude", "radius_meters", "limit"])
        let query = try IOSCapabilityArguments.text(arguments, key: "query", maximumBytes: 512)
        let latitude = try IOSCapabilityArguments.optionalNumber(arguments, key: "latitude", range: -90...90)
        let longitude = try IOSCapabilityArguments.optionalNumber(arguments, key: "longitude", range: -180...180)
        guard (latitude == nil) == (longitude == nil) else { throw LocalToolError.invalidArguments }
        let radius = try IOSCapabilityArguments.number(arguments, key: "radius_meters", default: 1_000, range: 100...100_000)
        let limit = try IOSCapabilityArguments.integer(arguments, key: "limit", default: 10, range: 1...20)
        return (query, latitude, longitude, radius, limit)
    }
}

struct MapsRouteTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "maps_route",
        description: "Resolve two addresses or lat,lon coordinates and calculate a driving, walking, or transit route with MapKit.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "from": .object(["type": .string("string"), "maxLength": .number(512)]),
                "to": .object(["type": .string("string"), "maxLength": .number(512)]),
                "mode": .object(["type": .string("string"), "enum": .array(["driving", "walking", "transit"].map(JSONValue.string))])
            ]),
            "required": .array([.string("from"), .string("to")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "使用 MapKit 计算路线和预计时间" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await MapKitCapabilityBridge.route(from: input.from, to: input.to, mode: input.mode)
#else
        throw MobileNativeToolError.hardwareUnavailable("MapKit")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (from: String, to: String, mode: String) {
        try arguments.requireOnlyKeys(["from", "to", "mode"])
        return (
            try IOSCapabilityArguments.text(arguments, key: "from", maximumBytes: 512),
            try IOSCapabilityArguments.text(arguments, key: "to", maximumBytes: 512),
            try IOSCapabilityArguments.choice(arguments, key: "mode", default: "driving", allowed: ["driving", "walking", "transit"])
        )
    }
}

// MARK: - Photos, media, health and Bluetooth

struct PhotoLibraryListTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "photo_library_list",
        description: "List bounded metadata for recent photos or videos visible to Harness Mobile in the iPhone photo library.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "media_type": .object(["type": .string("string"), "enum": .array(["all", "photo", "video"].map(JSONValue.string))]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
                "favorite_only": .object(["type": .string("boolean")])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "读取照片图库中有限数量的媒体元数据" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { try validate(arguments: arguments); return ["photos:read"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await PhotoLibraryCapabilityBridge.list(mediaType: input.mediaType, limit: input.limit, favoriteOnly: input.favoriteOnly)
#else
        throw MobileNativeToolError.hardwareUnavailable("照片图库")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (mediaType: String, limit: Int, favoriteOnly: Bool) {
        try arguments.requireOnlyKeys(["media_type", "limit", "favorite_only"])
        return (
            try IOSCapabilityArguments.choice(arguments, key: "media_type", default: "all", allowed: ["all", "photo", "video"]),
            try IOSCapabilityArguments.integer(arguments, key: "limit", default: 20, range: 1...100),
            try IOSCapabilityArguments.boolean(arguments, key: "favorite_only", default: false)
        )
    }
}

struct MediaLibrarySearchTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "media_library_search",
        description: "Search the user's on-device Apple media library for songs, albums, artists, or playlists.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "maxLength": .number(256)]),
                "kind": .object(["type": .string("string"), "enum": .array(["song", "album", "artist", "playlist"].map(JSONValue.string))]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50)])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "搜索本机媒体资料库" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { try validate(arguments: arguments); return ["media-library:read"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await MediaLibraryCapabilityBridge.search(query: input.query, kind: input.kind, limit: input.limit)
#else
        throw MobileNativeToolError.hardwareUnavailable("媒体资料库")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (query: String, kind: String, limit: Int) {
        try arguments.requireOnlyKeys(["query", "kind", "limit"])
        return (
            try IOSCapabilityArguments.text(arguments, key: "query", maximumBytes: 256),
            try IOSCapabilityArguments.choice(arguments, key: "kind", default: "song", allowed: ["song", "album", "artist", "playlist"]),
            try IOSCapabilityArguments.integer(arguments, key: "limit", default: 20, range: 1...50)
        )
    }
}

struct MediaPlaybackTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "media_playback",
        description: "Read now-playing metadata or control the iPhone system music player: play, pause, toggle, next, previous, or set volume.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array(["now_playing", "play", "pause", "toggle", "next", "previous", "volume"].map(JSONValue.string))]),
                "volume": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
            ]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "控制本机媒体播放：\(arguments["action"]?.stringValue ?? "now_playing")" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { try validate(arguments: arguments); return ["media:system-player"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return await MediaLibraryCapabilityBridge.playback(action: input.action, volume: input.volume)
#else
        throw MobileNativeToolError.hardwareUnavailable("媒体播放")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (action: String, volume: Double?) {
        try arguments.requireOnlyKeys(["action", "volume"])
        let action = try IOSCapabilityArguments.choice(arguments, key: "action", allowed: ["now_playing", "play", "pause", "toggle", "next", "previous", "volume"])
        let volume = try IOSCapabilityArguments.optionalNumber(arguments, key: "volume", range: 0...1)
        if action == "volume", volume == nil { throw LocalToolError.missingArgument("volume") }
        return (action, volume)
    }
}

struct HealthQueryTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "health_query",
        description: "Read bounded HealthKit samples for steps, heart rate, resting heart rate, HRV, weight, sleep, or workouts. Every type remains separately controlled by Health authorization.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "metric": .object(["type": .string("string"), "enum": .array(["steps", "heart_rate", "resting_heart_rate", "hrv", "weight", "sleep", "workouts"].map(JSONValue.string))]),
                "start_date": .object(["type": .string("string"), "description": .string("ISO-8601 date; defaults to 24 hours ago")]),
                "end_date": .object(["type": .string("string"), "description": .string("ISO-8601 date; defaults to now")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
            ]),
            "required": .array([.string("metric")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "读取已授权的 HealthKit \(arguments["metric"]?.stringValue ?? "健康")数据；结果会发送给模型" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let input = try parsed(arguments)
        return ["healthkit:read:\(input.metric)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await HealthKitCapabilityBridge.query(metric: input.metric, start: input.start, end: input.end, limit: input.limit)
#else
        throw MobileNativeToolError.hardwareUnavailable("HealthKit")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (metric: String, start: Date, end: Date, limit: Int) {
        try arguments.requireOnlyKeys(["metric", "start_date", "end_date", "limit"])
        let metric = try IOSCapabilityArguments.choice(arguments, key: "metric", allowed: ["steps", "heart_rate", "resting_heart_rate", "hrv", "weight", "sleep", "workouts"])
        let end = try IOSCapabilityArguments.optionalDate(arguments, key: "end_date") ?? Date()
        let start = try IOSCapabilityArguments.optionalDate(arguments, key: "start_date") ?? end.addingTimeInterval(-86_400)
        guard start < end, end.timeIntervalSince(start) <= 366 * 86_400 else { throw LocalToolError.invalidArguments }
        let limit = try IOSCapabilityArguments.integer(arguments, key: "limit", default: 50, range: 1...100)
        return (metric, start, end, limit)
    }
}

struct BluetoothScanTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "bluetooth_scan",
        description: "Perform one bounded foreground CoreBluetooth LE scan and return discovered peripheral metadata. It does not connect or enable background scanning.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "duration_seconds": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)]),
                "service_uuids": .object(["type": .string("array"), "items": .object(["type": .string("string"), "maxLength": .number(64)]), "maxItems": .number(16)])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { _ = try parsed(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "执行一次有界 BLE 前台扫描" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { try validate(arguments: arguments); return ["bluetooth:central"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let input = try parsed(arguments)
#if os(iOS)
        return try await BluetoothScanBridge.perform(duration: .seconds(input.duration), serviceUUIDs: input.serviceUUIDs)
#else
        throw MobileNativeToolError.hardwareUnavailable("蓝牙 LE")
#endif
    }

    private func parsed(_ arguments: [String: JSONValue]) throws -> (duration: Int, serviceUUIDs: [String]) {
        try arguments.requireOnlyKeys(["duration_seconds", "service_uuids"])
        let duration = try IOSCapabilityArguments.integer(arguments, key: "duration_seconds", default: 5, range: 1...20)
        let values = try IOSCapabilityArguments.stringArray(arguments, key: "service_uuids", maximumCount: 16, maximumItemBytes: 64)
        return (duration, values)
    }
}

struct VisionAnalyzeTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "vision_analyze",
        description: "Analyze the latest image explicitly selected by the user with Apple Vision: OCR, barcodes, image classification, or face rectangles. Image bytes stay on-device.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object(["type": .string("string"), "enum": .array(["ocr", "barcodes", "classify", "faces"].map(JSONValue.string))])
            ]),
            "required": .array([.string("mode")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["mode"])
        _ = try IOSCapabilityArguments.choice(arguments, key: "mode", allowed: ["ocr", "barcodes", "classify", "faces"])
    }
    func summary(arguments: [String: JSONValue]) -> String { "在本机使用 Vision 分析最近图片" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let mode = arguments["mode"]?.stringValue ?? "ocr"
        let data = try await store.latestImageData()
#if os(iOS)
        let task = Task.detached(priority: .userInitiated) {
            try VisionCapabilityAnalyzer.analyze(data: data, mode: mode)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
#else
        throw MobileNativeToolError.hardwareUnavailable("Vision")
#endif
    }
}

// MARK: - Shared parsing

private enum IOSCapabilityArguments {
    static func text(_ arguments: [String: JSONValue], key: String, maximumBytes: Int) throws -> String {
        guard let value = try optionalText(arguments, key: key, maximumBytes: maximumBytes) else {
            throw LocalToolError.missingArgument(key)
        }
        return value
    }

    static func optionalText(_ arguments: [String: JSONValue], key: String, maximumBytes: Int) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard case let .string(value) = raw else { throw LocalToolError.invalidArguments }
        let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw LocalToolError.invalidArguments
        }
        return normalized
    }

    static func choice(_ arguments: [String: JSONValue], key: String, default defaultValue: String? = nil, allowed: Set<String>) throws -> String {
        guard let raw = arguments[key] else {
            if let defaultValue { return defaultValue }
            throw LocalToolError.missingArgument(key)
        }
        guard case let .string(value) = raw, allowed.contains(value) else { throw LocalToolError.invalidArguments }
        return value
    }

    static func number(_ arguments: [String: JSONValue], key: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
        try optionalNumber(arguments, key: key, range: range) ?? defaultValue
    }

    static func optionalNumber(_ arguments: [String: JSONValue], key: String, range: ClosedRange<Double>) throws -> Double? {
        guard let raw = arguments[key] else { return nil }
        guard case let .number(value) = raw, value.isFinite, range.contains(value) else { throw LocalToolError.invalidArguments }
        return value
    }

    static func integer(_ arguments: [String: JSONValue], key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = arguments[key] else { return defaultValue }
        guard case let .number(value) = raw,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(range.lowerBound),
              value <= Double(range.upperBound) else { throw LocalToolError.invalidArguments }
        return Int(value)
    }

    static func boolean(_ arguments: [String: JSONValue], key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = arguments[key] else { return defaultValue }
        guard case let .bool(value) = raw else { throw LocalToolError.invalidArguments }
        return value
    }

    static func optionalDate(_ arguments: [String: JSONValue], key: String) throws -> Date? {
        guard let raw = arguments[key] else { return nil }
        guard case let .string(value) = raw, let date = ISO8601DateFormatter().date(from: value) else {
            throw LocalToolError.invalidArguments
        }
        return date
    }

    static func stringArray(_ arguments: [String: JSONValue], key: String, maximumCount: Int, maximumItemBytes: Int) throws -> [String] {
        guard let raw = arguments[key] else { return [] }
        guard case let .array(values) = raw, values.count <= maximumCount else { throw LocalToolError.invalidArguments }
        return try values.map { value in
            guard case let .string(text) = value,
                  !text.isEmpty,
                  text.utf8.count <= maximumItemBytes,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw LocalToolError.invalidArguments
            }
            return text
        }
    }
}

#if os(iOS)
// MARK: - iOS bridges

@MainActor
private final class SystemSpeechSynthesizer {
    static let shared = SystemSpeechSynthesizer()
    private let synthesizer = AVSpeechSynthesizer()

    func perform(action: String, text: String?, language: String?, rate: Double, pitch: Double, volume: Double) -> String {
        if action == "stop" {
            let stopped = synthesizer.stopSpeaking(at: .immediate)
            return JSONValue.object(["stopped": .bool(stopped)]).displayText
        }
        if action == "voices" {
            let prefix = language?.lowercased()
            let voices = AVSpeechSynthesisVoice.speechVoices()
                .filter { prefix == nil || $0.language.lowercased().hasPrefix(prefix!) }
                .prefix(200)
                .map { voice in
                    JSONValue.object([
                        "identifier": .string(voice.identifier),
                        "name": .string(voice.name),
                        "language": .string(voice.language),
                        "quality": .string(voice.quality == .enhanced ? "enhanced" : "default")
                    ])
                }
            return JSONValue.object(["count": .number(Double(voices.count)), "voices": .array(Array(voices))]).displayText
        }
        let utterance = AVSpeechUtterance(string: text ?? "")
        let resolvedLanguage = language ?? (text?.range(of: "\\p{Han}", options: .regularExpression) == nil ? "en-US" : "zh-CN")
        utterance.voice = AVSpeechSynthesisVoice(language: resolvedLanguage)
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + Float(rate) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = Float(volume)
        synthesizer.speak(utterance)
        return JSONValue.object(["queued": .bool(true), "language": .string(resolvedLanguage), "characters": .number(Double(text?.count ?? 0))]).displayText
    }
}

@MainActor
private enum SystemOpenCapabilityBridge {
    static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) {
                continuation.resume(returning: $0)
            }
        }
    }
}

@MainActor
private final class LiveSpeechRecognitionBridge {
    private var continuation: CheckedContinuation<String, Error>?
    private let engine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timeoutTask: Task<Void, Never>?
    private var latestText = ""
    private var finished = false

    static func perform(language: String, duration: Duration, onDeviceOnly: Bool) async throws -> String {
        let bridge = LiveSpeechRecognitionBridge()
        return try await bridge.start(language: language, duration: duration, onDeviceOnly: onDeviceOnly)
    }

    private func start(language: String, duration: Duration, onDeviceOnly: Bool) async throws -> String {
        try await Self.ensureAuthorization()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw MobileNativeToolError.hardwareUnavailable("语音识别语言 \(language)")
        }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            throw MobileNativeToolError.hardwareUnavailable("离线语音识别")
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = onDeviceOnly
                self.request = request

                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                    request.append(buffer)
                }
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    finish(.failure(MobileNativeToolError.operationFailed("麦克风录音")))
                    return
                }
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal ?? false
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let text { self.latestText = text }
                        if isFinal {
                            self.finishText()
                        } else if error != nil {
                            self.finish(self.latestText.isEmpty
                                ? .failure(MobileNativeToolError.operationFailed("语音识别"))
                                : .success(self.resultJSON()))
                        }
                    }
                }
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.finishText()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finishText() {
        finish(latestText.isEmpty
            ? .failure(MobileNativeToolError.noData("可识别语音"))
            : .success(resultJSON()))
    }

    private func resultJSON() -> String {
        JSONValue.object(["text": .string(latestText), "final": .bool(true)]).displayText
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        recognitionTask?.cancel()
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private static func ensureAuthorization() async throws {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            if speech == .restricted { throw MobileNativeToolError.restricted("语音识别") }
            throw MobileNativeToolError.permissionDenied("语音识别")
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else { throw MobileNativeToolError.permissionDenied("麦克风") }
    }
}

@MainActor
private enum MapKitCapabilityBridge {
    static func search(query: String, latitude: Double?, longitude: Double?, radius: Double, limit: Int) async throws -> String {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let latitude, let longitude {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        let origin = latitude.flatMap { lat in longitude.map { CLLocation(latitude: lat, longitude: $0) } }
        let items = response.mapItems.prefix(limit).map { item in
            let coordinate = item.placemark.coordinate
            var object: [String: JSONValue] = [
                "name": .string(item.name ?? ""),
                "latitude": .number(coordinate.latitude),
                "longitude": .number(coordinate.longitude),
                "address": .string(item.placemark.title ?? ""),
                "phone": .string(item.phoneNumber ?? ""),
                "url": .string(item.url?.absoluteString ?? "")
            ]
            if let origin {
                object["distanceMeters"] = .number(origin.distance(from: item.placemark.location ?? origin).rounded())
            }
            return JSONValue.object(object)
        }
        return JSONValue.object(["query": .string(query), "count": .number(Double(items.count)), "places": .array(Array(items))]).displayText
    }

    static func route(from: String, to: String, mode: String) async throws -> String {
        let source = try await mapItem(from)
        let destination = try await mapItem(to)
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = switch mode {
        case "walking": .walking
        case "transit": .transit
        default: .automobile
        }
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw MobileNativeToolError.noData("可用路线") }
        let steps = route.steps.prefix(100).map { step in
            JSONValue.object([
                "instruction": .string(step.instructions),
                "notice": .string(step.notice ?? ""),
                "distanceMeters": .number(step.distance.rounded())
            ])
        }
        return JSONValue.object([
            "mode": .string(mode),
            "distanceMeters": .number(route.distance.rounded()),
            "expectedTravelSeconds": .number(route.expectedTravelTime.rounded()),
            "name": .string(route.name),
            "steps": .array(Array(steps))
        ]).displayText
    }

    private static func mapItem(_ value: String) async throws -> MKMapItem {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2,
           let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            return MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: latitude, longitude: longitude)))
        }
        let placemarks = try await CLGeocoder().geocodeAddressString(value)
        guard let placemark = placemarks.first, let location = placemark.location else {
            throw MobileNativeToolError.noData("地理编码结果")
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }
}

@MainActor
private enum PhotoLibraryCapabilityBridge {
    static func list(mediaType: String, limit: Int, favoriteOnly: Bool) async throws -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            if status == .restricted { throw MobileNativeToolError.restricted("照片图库") }
            throw MobileNativeToolError.permissionDenied("照片图库")
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if favoriteOnly { options.predicate = NSPredicate(format: "favorite == YES") }
        let fetch: PHFetchResult<PHAsset>
        if mediaType == "photo" {
            fetch = PHAsset.fetchAssets(with: .image, options: options)
        } else if mediaType == "video" {
            fetch = PHAsset.fetchAssets(with: .video, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: options)
        }
        var assets: [JSONValue] = []
        fetch.enumerateObjects { asset, _, stop in
            guard assets.count < limit else { stop.pointee = true; return }
            assets.append(.object([
                "identifier": .string(asset.localIdentifier),
                "mediaType": .string(asset.mediaType == .video ? "video" : "photo"),
                "width": .number(Double(asset.pixelWidth)),
                "height": .number(Double(asset.pixelHeight)),
                "durationSeconds": .number(asset.duration),
                "favorite": .bool(asset.isFavorite),
                "creationDate": .string(asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
                "latitude": asset.location.map { .number($0.coordinate.latitude) } ?? .null,
                "longitude": asset.location.map { .number($0.coordinate.longitude) } ?? .null
            ]))
        }
        return JSONValue.object(["access": .string(status == .limited ? "limited" : "authorized"), "count": .number(Double(assets.count)), "assets": .array(assets)]).displayText
    }
}

@MainActor
private enum MediaLibraryCapabilityBridge {
    static func search(query: String, kind: String, limit: Int) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            if status == .restricted { throw MobileNativeToolError.restricted("媒体资料库") }
            throw MobileNativeToolError.permissionDenied("媒体资料库")
        }
        let mediaQuery: MPMediaQuery = switch kind {
        case "album": .albums()
        case "artist": .artists()
        case "playlist": .playlists()
        default: .songs()
        }
        let property: String = switch kind {
        case "album": MPMediaItemPropertyAlbumTitle
        case "artist": MPMediaItemPropertyArtist
        case "playlist": MPMediaPlaylistPropertyName
        default: MPMediaItemPropertyTitle
        }
        mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: property, comparisonType: .contains))
        if kind == "playlist" {
            let playlists = (mediaQuery.collections ?? []).compactMap { $0 as? MPMediaPlaylist }.prefix(limit).map { playlist in
                JSONValue.object([
                    "persistentID": .string(String(playlist.persistentID)),
                    "title": .string(playlist.name ?? ""),
                    "itemCount": .number(Double(playlist.items.count))
                ])
            }
            return JSONValue.object(["query": .string(query), "kind": .string(kind), "count": .number(Double(playlists.count)), "items": .array(Array(playlists))]).displayText
        }
        let items = (mediaQuery.items ?? []).prefix(limit).map { item in
            JSONValue.object([
                "persistentID": .string(String(item.persistentID)),
                "title": .string(item.title ?? ""),
                "artist": .string(item.artist ?? ""),
                "album": .string(item.albumTitle ?? ""),
                "durationSeconds": .number(item.playbackDuration)
            ])
        }
        return JSONValue.object(["query": .string(query), "kind": .string(kind), "count": .number(Double(items.count)), "items": .array(Array(items))]).displayText
    }

    static func playback(action: String, volume: Double?) -> String {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch action {
        case "play": player.play()
        case "pause": player.pause()
        case "toggle": player.playbackState == .playing ? player.pause() : player.play()
        case "next": player.skipToNextItem()
        case "previous": player.skipToPreviousItem()
        case "volume":
            if let volume,
               let slider = MPVolumeView(frame: .zero).subviews.compactMap({ $0 as? UISlider }).first {
                slider.value = Float(volume)
                slider.sendActions(for: .valueChanged)
            }
        default: break
        }
        let item = player.nowPlayingItem
        return JSONValue.object([
            "action": .string(action),
            "playbackState": .string(playbackState(player.playbackState)),
            "title": .string(item?.title ?? ""),
            "artist": .string(item?.artist ?? ""),
            "album": .string(item?.albumTitle ?? ""),
            "playbackTimeSeconds": .number(player.currentPlaybackTime)
        ]).displayText
    }

    private static func playbackState(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        case .seekingForward: "seeking_forward"
        case .seekingBackward: "seeking_backward"
        @unknown default: "unknown"
        }
    }
}

private enum HealthKitCapabilityBridge {
    static func query(metric: String, start: Date, end: Date, limit: Int) async throws -> String {
        guard HKHealthStore.isHealthDataAvailable() else { throw MobileNativeToolError.hardwareUnavailable("HealthKit") }
        let store = HKHealthStore()
        let objectType = try type(for: metric)
        try await store.requestAuthorization(toShare: [], read: [objectType])
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        if metric == "steps", let quantityType = objectType as? HKQuantityType {
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                    if error != nil { continuation.resume(throwing: MobileNativeToolError.operationFailed("HealthKit 步数查询")); return }
                    let value = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    continuation.resume(returning: JSONValue.object([
                        "metric": .string(metric), "value": .number(value), "unit": .string("count"),
                        "startDate": .string(ISO8601DateFormatter().string(from: start)),
                        "endDate": .string(ISO8601DateFormatter().string(from: end))
                    ]).displayText)
                }
                store.execute(query)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: objectType, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if error != nil { continuation.resume(throwing: MobileNativeToolError.operationFailed("HealthKit 查询")); return }
                let values = (samples ?? []).map { sampleJSON($0, metric: metric) }
                continuation.resume(returning: JSONValue.object([
                    "metric": .string(metric), "count": .number(Double(values.count)), "samples": .array(values)
                ]).displayText)
            }
            store.execute(query)
        }
    }

    private static func type(for metric: String) throws -> HKSampleType {
        let value: HKSampleType? = switch metric {
        case "steps": HKObjectType.quantityType(forIdentifier: .stepCount)
        case "heart_rate": HKObjectType.quantityType(forIdentifier: .heartRate)
        case "resting_heart_rate": HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case "hrv": HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case "weight": HKObjectType.quantityType(forIdentifier: .bodyMass)
        case "sleep": HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case "workouts": HKObjectType.workoutType()
        default: nil
        }
        guard let value else { throw LocalToolError.invalidArguments }
        return value
    }

    private static func sampleJSON(_ sample: HKSample, metric: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "startDate": .string(ISO8601DateFormatter().string(from: sample.startDate)),
            "endDate": .string(ISO8601DateFormatter().string(from: sample.endDate)),
            "source": .string(sample.sourceRevision.source.name)
        ]
        if let quantity = sample as? HKQuantitySample {
            let (unit, name): (HKUnit, String) = switch metric {
            case "heart_rate", "resting_heart_rate": (HKUnit.count().unitDivided(by: .minute()), "count/min")
            case "hrv": (.secondUnit(with: .milli), "ms")
            case "weight": (.gramUnit(with: .kilo), "kg")
            default: (.count(), "count")
            }
            object["value"] = .number(quantity.quantity.doubleValue(for: unit))
            object["unit"] = .string(name)
        } else if let category = sample as? HKCategorySample {
            object["value"] = .number(Double(category.value))
            object["durationSeconds"] = .number(category.endDate.timeIntervalSince(category.startDate))
        } else if let workout = sample as? HKWorkout {
            object["activityType"] = .number(Double(workout.workoutActivityType.rawValue))
            object["durationSeconds"] = .number(workout.duration)
            if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
               let energy = workout.statistics(for: energyType)?.sumQuantity() {
                object["energyKilocalories"] = .number(energy.doubleValue(for: .kilocalorie()))
            }
            if let distance = workout.totalDistance {
                object["distanceMeters"] = .number(distance.doubleValue(for: .meter()))
            }
        }
        return .object(object)
    }
}

@MainActor
private final class BluetoothScanBridge: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var duration: Duration = .seconds(5)
    private var services: [CBUUID]?
    private var values: [UUID: JSONValue] = [:]
    private var finished = false

    static func perform(duration: Duration, serviceUUIDs: [String]) async throws -> String {
        let bridge = BluetoothScanBridge()
        return try await bridge.start(duration: duration, serviceUUIDs: serviceUUIDs)
    }

    private func start(duration: Duration, serviceUUIDs: [String]) async throws -> String {
        self.duration = duration
        services = serviceUUIDs.isEmpty ? nil : serviceUUIDs.map(CBUUID.init(string:))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                manager = CBCentralManager(delegate: self, queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: duration)
                finish(.success(resultJSON()))
            }
        case .unauthorized: finish(.failure(MobileNativeToolError.permissionDenied("蓝牙")))
        case .unsupported: finish(.failure(MobileNativeToolError.hardwareUnavailable("蓝牙 LE")))
        case .poweredOff: finish(.failure(MobileNativeToolError.hardwareUnavailable("已关闭的蓝牙")))
        case .resetting, .unknown: break
        @unknown default: finish(.failure(MobileNativeToolError.hardwareUnavailable("蓝牙 LE")))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        values[peripheral.identifier] = .object([
            "identifier": .string(peripheral.identifier.uuidString),
            "name": .string(peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")),
            "rssi": .number(RSSI.doubleValue),
            "connectable": .bool((advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false),
            "serviceUUIDs": .array(serviceUUIDs.map(JSONValue.string))
        ])
    }

    private func resultJSON() -> String {
        let peripherals = values.sorted { lhs, rhs in lhs.key.uuidString < rhs.key.uuidString }.map(\.value)
        return JSONValue.object(["count": .number(Double(peripherals.count)), "peripherals": .array(peripherals)]).displayText
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        manager?.stopScan()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

private enum VisionCapabilityAnalyzer {
    static func analyze(data: Data, mode: String) throws -> String {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(data: data)
        switch mode {
        case "barcodes":
            let request = VNDetectBarcodesRequest()
            try handler.perform([request])
            let values = (request.results ?? []).prefix(100).map { observation in
                JSONValue.object([
                    "payload": .string(observation.payloadStringValue ?? ""),
                    "symbology": .string(observation.symbology.rawValue),
                    "confidence": .number(Double(observation.confidence))
                ])
            }
            return JSONValue.object(["mode": .string(mode), "count": .number(Double(values.count)), "barcodes": .array(Array(values))]).displayText
        case "classify":
            let request = VNClassifyImageRequest()
            try handler.perform([request])
            let values = (request.results ?? []).prefix(20).map { observation in
                JSONValue.object(["identifier": .string(observation.identifier), "confidence": .number(Double(observation.confidence))])
            }
            return JSONValue.object(["mode": .string(mode), "classifications": .array(Array(values))]).displayText
        case "faces":
            let request = VNDetectFaceRectanglesRequest()
            try handler.perform([request])
            let values = (request.results ?? []).prefix(100).map { observation in
                let box = observation.boundingBox
                return JSONValue.object([
                    "confidence": .number(Double(observation.confidence)),
                    "x": .number(box.origin.x), "y": .number(box.origin.y),
                    "width": .number(box.width), "height": .number(box.height)
                ])
            }
            return JSONValue.object(["mode": .string(mode), "count": .number(Double(values.count)), "faces": .array(Array(values))]).displayText
        default:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.prefix(500)
            return JSONValue.object(["mode": .string("ocr"), "text": .string(lines.joined(separator: "\n")), "lineCount": .number(Double(lines.count))]).displayText
        }
    }
}
#endif
