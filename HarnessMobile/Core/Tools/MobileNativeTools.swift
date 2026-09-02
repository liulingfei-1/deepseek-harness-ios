import Foundation

#if os(iOS)
import CoreLocation
import CoreMotion
import EventKit
import LocalAuthentication
import UIKit
import UserNotifications
#endif

// MARK: - Provider contracts

struct DeviceLocationReading: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double
    let verticalAccuracy: Double?
    let timestamp: Date
    let isReducedAccuracy: Bool
    let isSimulatedBySoftware: Bool
}

protocol DeviceLocationProviding: Sendable {
    func currentLocation(timeout: Duration) async throws -> DeviceLocationReading
}

struct DeviceMotionActivityReading: Sendable, Equatable {
    enum Confidence: String, Sendable, Equatable {
        case low
        case medium
        case high
    }

    let startedAt: Date
    let confidence: Confidence
    let activities: [String]
}

protocol DeviceMotionActivityProviding: Sendable {
    func recentActivity(
        lookbackMinutes: Int,
        timeout: Duration
    ) async throws -> DeviceMotionActivityReading
}

struct LocalNotificationScheduleRequest: Sendable, Equatable {
    let identifier: String
    let title: String
    let body: String
    let delaySeconds: Int
}

protocol LocalNotificationScheduling: Sendable {
    func schedule(
        _ request: LocalNotificationScheduleRequest,
        timeout: Duration
    ) async throws
}

protocol DeviceOwnerAuthenticating: Sendable {
    func authenticateDeviceOwner(
        reason: String,
        timeout: Duration
    ) async throws
}

// MARK: - Tool catalog fragment

enum MobileNativeToolKit {
    private static let coreApprovedNames: Set<String> = [
        "calendar_events",
        "clipboard_read",
        "clipboard_write",
        "contacts_search",
        "device_capabilities",
        "device_status",
        "location_current",
        "motion_activity",
        "notification_schedule",
        "reminders_list",
        "secure_authenticate"
    ]
    static let approvedNames = coreApprovedNames.union(IOSCapabilityToolKit.approvedNames)

#if os(iOS)
    static func makeSystemTools(workspaceStore: WorkspaceStore) -> [any LocalAgentTool] {
        let coreTools: [any LocalAgentTool] = [
            CalendarEventsTool(),
            ClipboardReadTool(),
            ClipboardWriteTool(),
            ContactsSearchTool(provider: SystemDeviceContactSearcher()),
            DeviceCapabilitiesTool(),
            DeviceStatusTool(),
            LocationCurrentTool(provider: SystemDeviceLocationProvider()),
            MotionActivityTool(provider: SystemDeviceMotionActivityProvider()),
            NotificationScheduleTool(provider: SystemLocalNotificationScheduler()),
            RemindersListTool(),
            SecureAuthenticateTool(provider: SystemDeviceOwnerAuthenticator())
        ]
        return coreTools + IOSCapabilityToolKit.makeSystemTools(workspaceStore: workspaceStore)
    }
#endif
}

// MARK: - Tools

struct LocationCurrentTool: LocalAgentTool {
    private let provider: any DeviceLocationProviding

    let definition = ModelToolDefinition(
        name: "location_current",
        description: "Request one real, current Core Location reading on this iPhone. No continuous or background tracking is started.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(provider: any DeviceLocationProviding) {
        self.provider = provider
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "获取一次当前定位；坐标结果会发送给模型"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        try Task.checkCancellation()
        let reading = try await provider.currentLocation(timeout: .seconds(15))
        try Task.checkCancellation()
        guard reading.latitude.isFinite,
              (-90...90).contains(reading.latitude),
              reading.longitude.isFinite,
              (-180...180).contains(reading.longitude),
              reading.horizontalAccuracy.isFinite,
              reading.horizontalAccuracy >= 0,
              reading.altitude?.isFinite != false,
              reading.verticalAccuracy?.isFinite != false else {
            throw MobileNativeToolError.invalidSystemResult("定位")
        }

        var object: [String: JSONValue] = [
            "latitude": .number(reading.latitude),
            "longitude": .number(reading.longitude),
            "horizontalAccuracyMeters": .number(reading.horizontalAccuracy),
            "timestamp": .string(Self.iso8601(reading.timestamp)),
            "reducedAccuracy": .bool(reading.isReducedAccuracy),
            "simulatedBySoftware": .bool(reading.isSimulatedBySoftware)
        ]
        if let altitude = reading.altitude {
            object["altitudeMeters"] = .number(altitude)
        }
        if let verticalAccuracy = reading.verticalAccuracy {
            object["verticalAccuracyMeters"] = .number(verticalAccuracy)
        }
        return JSONValue.object(object).displayText
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct MotionActivityTool: LocalAgentTool {
    private let provider: any DeviceMotionActivityProviding

    let definition = ModelToolDefinition(
        name: "motion_activity",
        description: "Read the most recent on-device Core Motion activity estimate within a bounded past interval.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "lookback_minutes": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(1_440),
                    "description": .string("Past interval to query. Defaults to 60 minutes.")
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(provider: any DeviceMotionActivityProviding) {
        self.provider = provider
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["lookback_minutes"])
        _ = try arguments.boundedInteger(
            "lookback_minutes",
            default: 60,
            range: 1...1_440
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let minutes = (try? arguments.boundedInteger(
            "lookback_minutes",
            default: 60,
            range: 1...1_440
        )) ?? 60
        return "读取最近 \(minutes) 分钟的本机运动活动；结果会发送给模型"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let lookback = try arguments.boundedInteger(
            "lookback_minutes",
            default: 60,
            range: 1...1_440
        )
        try Task.checkCancellation()
        let reading = try await provider.recentActivity(
            lookbackMinutes: lookback,
            timeout: .seconds(15)
        )
        try Task.checkCancellation()
        let allowedActivities: Set<String> = [
            "unknown", "stationary", "walking", "running", "automotive", "cycling"
        ]
        guard !reading.activities.isEmpty,
              reading.activities.allSatisfy(allowedActivities.contains) else {
            throw MobileNativeToolError.invalidSystemResult("运动活动")
        }

        return JSONValue.object([
            "startedAt": .string(ISO8601DateFormatter().string(from: reading.startedAt)),
            "confidence": .string(reading.confidence.rawValue),
            "activities": .array(reading.activities.map(JSONValue.string)),
            "lookbackMinutes": .number(Double(lookback))
        ]).displayText
    }
}

struct NotificationScheduleTool: LocalAgentTool {
    private let provider: any LocalNotificationScheduling

    let definition = ModelToolDefinition(
        name: "notification_schedule",
        description: "Schedule one local iPhone notification. It does not contact a push server and does not start background execution.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "maxLength": .number(128)
                ]),
                "body": .object([
                    "type": .string("string"),
                    "maxLength": .number(1_024)
                ]),
                "delay_seconds": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(604_800)
                ])
            ]),
            "required": .array([
                .string("title"),
                .string("body"),
                .string("delay_seconds")
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    init(provider: any LocalNotificationScheduling) {
        self.provider = provider
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["title", "body", "delay_seconds"])
        _ = try arguments.notificationTitle("title", maximumUTF8Bytes: 128)
        _ = try arguments.notificationBody("body", maximumUTF8Bytes: 1_024)
        _ = try arguments.boundedInteger(
            "delay_seconds",
            range: 1...604_800
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let seconds = (try? arguments.boundedInteger(
            "delay_seconds",
            range: 1...604_800
        )) ?? 0
        let titleBytes = arguments["title"]?.stringValue?.utf8.count ?? 0
        return "安排一条本地通知（\(seconds) 秒后，标题 \(titleBytes) 字节）"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let title = try arguments.notificationTitle("title", maximumUTF8Bytes: 128)
        let body = try arguments.notificationBody("body", maximumUTF8Bytes: 1_024)
        let delay = try arguments.boundedInteger(
            "delay_seconds",
            range: 1...604_800
        )
        let identifier = "harness-mobile-local-\(UUID().uuidString.lowercased())"
        let request = LocalNotificationScheduleRequest(
            identifier: identifier,
            title: title,
            body: body,
            delaySeconds: delay
        )

        try Task.checkCancellation()
        try await provider.schedule(request, timeout: .seconds(30))
        do {
            try Task.checkCancellation()
        } catch {
            // System providers remove the request if cancellation races with add.
            throw error
        }

        return JSONValue.object([
            "status": .string("scheduled"),
            "identifier": .string(identifier),
            "delaySeconds": .number(Double(delay))
        ]).displayText
    }
}

struct SecureAuthenticateTool: LocalAgentTool {
    private let provider: any DeviceOwnerAuthenticating

    let definition = ModelToolDefinition(
        name: "secure_authenticate",
        description: "Ask iOS Local Authentication to verify the current device owner. No biometric data is exposed to the agent.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    init(provider: any DeviceOwnerAuthenticating) {
        self.provider = provider
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "使用 Face ID、Touch ID 或设备密码验证当前设备所有者"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        try Task.checkCancellation()
        try await provider.authenticateDeviceOwner(
            reason: "验证你本人后继续执行当前本机 Agent 操作",
            timeout: .seconds(60)
        )
        try Task.checkCancellation()
        return JSONValue.object([
            "authenticated": .bool(true),
            "biometricDataShared": .bool(false)
        ]).displayText
    }
}

struct ClipboardReadTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "clipboard_read",
        description: "Read the current plain-text iPhone clipboard contents.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys([]) }
    func summary(arguments: [String: JSONValue]) -> String { "读取本机剪贴板文本" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["clipboard:read"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        #if os(iOS)
        let value = await MainActor.run { UIPasteboard.general.string }
        let text = Self.bounded(value ?? "", maximumBytes: 32 * 1_024)
        return JSONValue.object([
            "hasText": .bool(!text.isEmpty),
            "text": .string(text),
            "characterCount": .number(Double(text.count)),
            "byteCount": .number(Double(text.utf8.count))
        ]).displayText
        #else
        throw MobileNativeToolError.hardwareUnavailable("剪贴板")
        #endif
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let bytes = String(character).utf8.count
            guard result.utf8.count + bytes <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }
}

struct ClipboardWriteTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "clipboard_write",
        description: "Write bounded plain text to the current iPhone clipboard.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object([
                    "type": .string("string"),
                    "maxLength": .number(32 * 1_024)
                ])
            ]),
            "required": .array([.string("text")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["text"])
        _ = try arguments.requiredString("text", maximumUTF8Bytes: 32 * 1_024, allowEmpty: true)
    }
    func summary(arguments: [String: JSONValue]) -> String {
        let bytes = arguments["text"]?.stringValue?.utf8.count ?? 0
        return "写入 \(bytes) 字节到本机剪贴板"
    }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["clipboard:write"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let text = try arguments.requiredString("text", maximumUTF8Bytes: 32 * 1_024, allowEmpty: true)
        #if os(iOS)
        await MainActor.run { UIPasteboard.general.string = text }
        return JSONValue.object([
            "written": .bool(true),
            "characterCount": .number(Double(text.count)),
            "byteCount": .number(Double(text.utf8.count))
        ]).displayText
        #else
        throw MobileNativeToolError.hardwareUnavailable("剪贴板")
        #endif
    }
}

struct DeviceStatusTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "device_status",
        description: "Return current iPhone system, battery, thermal, memory, and process status.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys([]) }
    func summary(arguments: [String: JSONValue]) -> String { "读取本机设备运行状态" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        #if os(iOS)
        return await MainActor.run {
            let device = UIDevice.current
            let process = ProcessInfo.processInfo
            let batteryWasEnabled = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
            let state: String
            switch device.batteryState {
            case .unplugged: state = "unplugged"
            case .charging: state = "charging"
            case .full: state = "full"
            default: state = "unknown"
            }
            device.isBatteryMonitoringEnabled = batteryWasEnabled

            var battery: [String: JSONValue] = ["state": .string(state)]
            if level >= 0, level.isFinite {
                battery["level"] = .number(Double(level))
                battery["levelPercent"] = .number(Double((level * 100).rounded()))
            }
            return JSONValue.object([
                "systemName": .string(device.systemName),
                "systemVersion": .string(device.systemVersion),
                "model": .string(device.model),
                "localizedModel": .string(device.localizedModel),
                "battery": .object(battery),
                "lowPowerMode": .bool(process.isLowPowerModeEnabled),
                "thermalState": .string(Self.thermalName(process.thermalState)),
                "physicalMemoryBytes": .number(Double(process.physicalMemory)),
                "processUptimeSeconds": .number(process.systemUptime)
            ]).displayText
        }
        #else
        throw MobileNativeToolError.hardwareUnavailable("设备状态")
        #endif
    }

    #if os(iOS)
    @MainActor private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    #endif
}

struct CalendarEventsTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "calendar_events",
        description: "List calendar events in a bounded date range from the iPhone EventKit store.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "start_date": .object(["type": .string("string"), "description": .string("ISO-8601 start date")]),
                "end_date": .object(["type": .string("string"), "description": .string("ISO-8601 end date")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
            ]),
            "required": .array([.string("start_date"), .string("end_date")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["start_date", "end_date", "limit"])
        _ = try EventKitToolSupport.date(arguments, key: "start_date")
        _ = try EventKitToolSupport.date(arguments, key: "end_date")
        _ = try arguments.boundedInteger("limit", default: 50, range: 1...100)
    }
    func summary(arguments: [String: JSONValue]) -> String { "读取指定日期范围内的本机日历事件" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["calendar:read"]
    }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let start = try EventKitToolSupport.date(arguments, key: "start_date")
        let end = try EventKitToolSupport.date(arguments, key: "end_date")
        guard start <= end else { throw LocalToolError.invalidArguments }
        let limit = try arguments.boundedInteger("limit", default: 50, range: 1...100)
        #if os(iOS)
        return try await EventKitReadBridge.events(start: start, end: end, limit: limit)
        #else
        throw MobileNativeToolError.hardwareUnavailable("日历")
        #endif
    }
}

struct RemindersListTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "reminders_list",
        description: "List bounded iPhone reminders, optionally filtered by title.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "maxLength": .number(128)]),
                "include_completed": .object(["type": .string("boolean")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["query", "include_completed", "limit"])
        if let query = arguments["query"] {
            guard let text = query.stringValue, text.utf8.count <= 128,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw LocalToolError.invalidArguments
            }
        }
        if let include = arguments["include_completed"] {
            guard case .bool = include else { throw LocalToolError.invalidArguments }
        }
        _ = try arguments.boundedInteger("limit", default: 50, range: 1...100)
    }
    func summary(arguments: [String: JSONValue]) -> String { "读取本机提醒事项" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["reminders:read"]
    }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeCompleted: Bool
        if case let .bool(value) = arguments["include_completed"] {
            includeCompleted = value
        } else {
            includeCompleted = false
        }
        let limit = try arguments.boundedInteger("limit", default: 50, range: 1...100)
        #if os(iOS)
        return try await EventKitReadBridge.reminders(query: query, includeCompleted: includeCompleted, limit: limit)
        #else
        throw MobileNativeToolError.hardwareUnavailable("提醒事项")
        #endif
    }
}

private enum EventKitToolSupport {
    static func date(_ arguments: [String: JSONValue], key: String) throws -> Date {
        let value = try arguments.requiredString(key, maximumUTF8Bytes: 128)
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { throw LocalToolError.invalidArguments }
        return date
    }
}

// MARK: - Typed failures

enum MobileNativeToolError: LocalizedError, Sendable, Equatable {
    case hardwareUnavailable(String)
    case permissionDenied(String)
    case restricted(String)
    case timedOut(String)
    case noData(String)
    case requestInProgress(String)
    case invalidSystemResult(String)
    case authenticationCancelled
    case authenticationFailed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .hardwareUnavailable(capability):
            return "当前设备或模拟器不支持\(capability)。"
        case let .permissionDenied(capability):
            return "\(capability)权限已被拒绝，请在系统设置中允许后重试。"
        case let .restricted(capability):
            return "\(capability)受到系统或家长控制限制。"
        case let .timedOut(capability):
            return "等待\(capability)超时。"
        case let .noData(capability):
            return "没有可用的\(capability)数据。"
        case let .requestInProgress(capability):
            return "已有\(capability)请求正在进行。"
        case let .invalidSystemResult(capability):
            return "系统返回了无效的\(capability)结果。"
        case .authenticationCancelled:
            return "设备所有者验证已取消。"
        case .authenticationFailed:
            return "设备所有者验证失败。"
        case let .operationFailed(capability):
            return "\(capability)操作失败。"
        }
    }
}

// MARK: - Strict argument helpers

private extension Dictionary where Key == String, Value == JSONValue {
    func boundedInteger(
        _ key: String,
        default defaultValue: Int? = nil,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = self[key] else {
            if let defaultValue, range.contains(defaultValue) {
                return defaultValue
            }
            throw LocalToolError.missingArgument(key)
        }
        guard case let .number(value) = raw,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(range.lowerBound),
              value <= Double(range.upperBound) else {
            throw LocalToolError.invalidArguments
        }
        return Int(value)
    }

    func notificationTitle(_ key: String, maximumUTF8Bytes: Int) throws -> String {
        guard let raw = self[key]?.stringValue else {
            throw LocalToolError.missingArgument(key)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LocalToolError.invalidArguments
        }
        return value
    }

    func notificationBody(_ key: String, maximumUTF8Bytes: Int) throws -> String {
        guard let value = self[key]?.stringValue else {
            throw LocalToolError.missingArgument(key)
        }
        guard value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && $0 != "\n"
                      && $0 != "\t"
              }) else {
            throw LocalToolError.invalidArguments
        }
        return value
    }
}

#if os(iOS)
@MainActor
private final class EventKitReadBridge {
    private struct ReminderSnapshot: Sendable {
        let identifier: String
        let title: String
        let completed: Bool
        let list: String
        let dueDate: Date?
    }

    static func events(start: Date, end: Date, limit: Int) async throws -> String {
        let store = EKEventStore()
        try await requestEventsAccess(store)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let values = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                JSONValue.object([
                    "identifier": .string(Self.bounded(event.eventIdentifier ?? "", maximumBytes: 256)),
                    "title": .string(Self.bounded(event.title ?? "", maximumBytes: 512)),
                    "startDate": .string(Self.iso8601(event.startDate)),
                    "endDate": .string(Self.iso8601(event.endDate)),
                    "allDay": .bool(event.isAllDay),
                    "location": .string(Self.bounded(event.location ?? "", maximumBytes: 512)),
                    "calendar": .string(Self.bounded(event.calendar?.title ?? "", maximumBytes: 256))
                ])
            }
        return JSONValue.object([
            "startDate": .string(Self.iso8601(start)),
            "endDate": .string(Self.iso8601(end)),
            "count": .number(Double(values.count)),
            "events": .array(Array(values))
        ]).displayText
    }

    static func reminders(query: String?, includeCompleted: Bool, limit: Int) async throws -> String {
        let store = EKEventStore()
        try await requestRemindersAccess(store)
        let reminders = try await fetchReminders(store)
        let normalizedQuery = query?.lowercased() ?? ""
        let values = reminders
            .filter { includeCompleted || !$0.completed }
            .filter { normalizedQuery.isEmpty || $0.title.lowercased().contains(normalizedQuery) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            .prefix(limit)
            .map { reminder in
                var object: [String: JSONValue] = [
                    "identifier": .string(reminder.identifier),
                    "title": .string(reminder.title),
                    "completed": .bool(reminder.completed),
                    "list": .string(reminder.list)
                ]
                if let date = reminder.dueDate {
                    object["dueDate"] = .string(Self.iso8601(date))
                }
                return JSONValue.object(object)
            }
        return JSONValue.object([
            "query": .string(query ?? ""),
            "includeCompleted": .bool(includeCompleted),
            "count": .number(Double(values.count)),
            "reminders": .array(Array(values))
        ]).displayText
    }

    private static func requestEventsAccess(_ store: EKEventStore) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if granted { continuation.resume() }
                else if EKEventStore.authorizationStatus(for: .event) == .restricted {
                    continuation.resume(throwing: MobileNativeToolError.restricted("日历"))
                } else if error != nil || EKEventStore.authorizationStatus(for: .event) == .denied {
                    continuation.resume(throwing: MobileNativeToolError.permissionDenied("日历"))
                } else {
                    continuation.resume(throwing: MobileNativeToolError.operationFailed("日历授权"))
                }
            }
        }
    }

    private static func requestRemindersAccess(_ store: EKEventStore) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToReminders { granted, error in
                if granted { continuation.resume() }
                else if EKEventStore.authorizationStatus(for: .reminder) == .restricted {
                    continuation.resume(throwing: MobileNativeToolError.restricted("提醒事项"))
                } else if error != nil || EKEventStore.authorizationStatus(for: .reminder) == .denied {
                    continuation.resume(throwing: MobileNativeToolError.permissionDenied("提醒事项"))
                } else {
                    continuation.resume(throwing: MobileNativeToolError.operationFailed("提醒事项授权"))
                }
            }
        }
    }

    private static func fetchReminders(_ store: EKEventStore) async throws -> [ReminderSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = store.predicateForReminders(in: nil)
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map { reminder in
                    ReminderSnapshot(
                        identifier: bounded(reminder.calendarItemIdentifier, maximumBytes: 256),
                        title: bounded(reminder.title ?? "", maximumBytes: 512),
                        completed: reminder.isCompleted,
                        list: bounded(reminder.calendar?.title ?? "", maximumBytes: 256),
                        dueDate: reminder.dueDateComponents?.date
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    private static func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        for character in value {
            let bytes = String(character).utf8.count
            guard result.utf8.count + bytes <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }
}

// MARK: - Real iOS providers

struct SystemDeviceLocationProvider: DeviceLocationProviding {
    func currentLocation(timeout: Duration) async throws -> DeviceLocationReading {
        try await LocationRequestBridge.perform(timeout: timeout)
    }
}

@MainActor
private final class LocationRequestBridge: NSObject, @MainActor CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<DeviceLocationReading, Error>?
    private var manager: CLLocationManager?
    private var timeoutTask: Task<Void, Never>?
    private var didRequestLocation = false
    private var isFinished = false

    static func perform(timeout: Duration) async throws -> DeviceLocationReading {
        let bridge = LocationRequestBridge()
        return try await bridge.request(timeout: timeout)
    }

    private func request(timeout: Duration) async throws -> DeviceLocationReading {
        guard timeout > .zero else {
            throw MobileNativeToolError.timedOut("定位")
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.manager = manager
                startTimeout(timeout, capability: "定位")
                beginAuthorizationOrRequest()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func beginAuthorizationOrRequest() {
        guard !isFinished, let manager else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            finish(.failure(MobileNativeToolError.hardwareUnavailable("定位服务")))
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !didRequestLocation else { return }
            didRequestLocation = true
            manager.requestLocation()
        case .denied:
            finish(.failure(MobileNativeToolError.permissionDenied("定位")))
        case .restricted:
            finish(.failure(MobileNativeToolError.restricted("定位")))
        @unknown default:
            finish(.failure(MobileNativeToolError.operationFailed("定位")))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        beginAuthorizationOrRequest()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0 else {
            finish(.failure(MobileNativeToolError.invalidSystemResult("定位")))
            return
        }
        let verticalAccuracy = location.verticalAccuracy >= 0
            ? location.verticalAccuracy
            : nil
        let reading = DeviceLocationReading(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: verticalAccuracy == nil ? nil : location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: location.timestamp,
            isReducedAccuracy: manager.accuracyAuthorization == .reducedAccuracy,
            isSimulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware ?? false
        )
        finish(.success(reading))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        if code == .denied {
            finish(.failure(MobileNativeToolError.permissionDenied("定位")))
        } else if code == .locationUnknown {
            finish(.failure(MobileNativeToolError.hardwareUnavailable("当前定位")))
        } else {
            finish(.failure(MobileNativeToolError.operationFailed("定位")))
        }
    }

    private func startTimeout(_ timeout: Duration, capability: String) {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(.failure(MobileNativeToolError.timedOut(capability)))
        }
    }

    private func finish(_ result: Result<DeviceLocationReading, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

struct SystemDeviceMotionActivityProvider: DeviceMotionActivityProviding {
    func recentActivity(
        lookbackMinutes: Int,
        timeout: Duration
    ) async throws -> DeviceMotionActivityReading {
        try await MotionActivityRequestBridge.perform(
            lookbackMinutes: lookbackMinutes,
            timeout: timeout
        )
    }
}

@MainActor
private final class MotionActivityRequestBridge {
    private var continuation: CheckedContinuation<DeviceMotionActivityReading, Error>?
    private var manager: CMMotionActivityManager?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    static func perform(
        lookbackMinutes: Int,
        timeout: Duration
    ) async throws -> DeviceMotionActivityReading {
        let bridge = MotionActivityRequestBridge()
        return try await bridge.request(lookbackMinutes: lookbackMinutes, timeout: timeout)
    }

    private func request(
        lookbackMinutes: Int,
        timeout: Duration
    ) async throws -> DeviceMotionActivityReading {
        guard CMMotionActivityManager.isActivityAvailable() else {
            throw MobileNativeToolError.hardwareUnavailable("运动活动识别")
        }
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied:
            throw MobileNativeToolError.permissionDenied("运动与健身")
        case .restricted:
            throw MobileNativeToolError.restricted("运动与健身")
        case .authorized, .notDetermined:
            break
        @unknown default:
            throw MobileNativeToolError.operationFailed("运动活动识别")
        }
        guard timeout > .zero else {
            throw MobileNativeToolError.timedOut("运动活动识别")
        }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CMMotionActivityManager()
                self.manager = manager
                startTimeout(timeout)
                let end = Date()
                let start = end.addingTimeInterval(-Double(lookbackMinutes) * 60)
                manager.queryActivityStarting(
                    from: start,
                    to: end,
                    to: .main
                ) { [weak self] activities, error in
                    let result = Self.makeResult(activities: activities, error: error)
                    Task { @MainActor in
                        self?.finish(result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    nonisolated private static func makeResult(
        activities: [CMMotionActivity]?,
        error: Error?
    ) -> Result<DeviceMotionActivityReading, Error> {
        if error != nil {
            switch CMMotionActivityManager.authorizationStatus() {
            case .denied:
                return .failure(MobileNativeToolError.permissionDenied("运动与健身"))
            case .restricted:
                return .failure(MobileNativeToolError.restricted("运动与健身"))
            default:
                return .failure(MobileNativeToolError.operationFailed("运动活动识别"))
            }
        }
        guard let activity = activities?.max(by: { $0.startDate < $1.startDate }) else {
            return .failure(MobileNativeToolError.noData("运动活动"))
        }
        var labels: [String] = []
        if activity.unknown { labels.append("unknown") }
        if activity.stationary { labels.append("stationary") }
        if activity.walking { labels.append("walking") }
        if activity.running { labels.append("running") }
        if activity.automotive { labels.append("automotive") }
        if activity.cycling { labels.append("cycling") }
        if labels.isEmpty { labels = ["unknown"] }

        let confidence: DeviceMotionActivityReading.Confidence
        switch activity.confidence {
        case .low:
            confidence = .low
        case .medium:
            confidence = .medium
        case .high:
            confidence = .high
        @unknown default:
            confidence = .low
        }
        return .success(DeviceMotionActivityReading(
            startedAt: activity.startDate,
            confidence: confidence,
            activities: labels
        ))
    }

    private func startTimeout(_ timeout: Duration) {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(.failure(MobileNativeToolError.timedOut("运动活动识别")))
        }
    }

    private func finish(_ result: Result<DeviceMotionActivityReading, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        manager = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

struct SystemLocalNotificationScheduler: LocalNotificationScheduling {
    func schedule(
        _ request: LocalNotificationScheduleRequest,
        timeout: Duration
    ) async throws {
        try await NotificationScheduleBridge.perform(request: request, timeout: timeout)
    }
}

@MainActor
private final class NotificationScheduleBridge {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var center: UNUserNotificationCenter?
    private var request: LocalNotificationScheduleRequest?
    private var isFinished = false

    static func perform(
        request: LocalNotificationScheduleRequest,
        timeout: Duration
    ) async throws {
        let bridge = NotificationScheduleBridge()
        try await bridge.schedule(request: request, timeout: timeout)
    }

    private func schedule(
        request: LocalNotificationScheduleRequest,
        timeout: Duration
    ) async throws {
        guard timeout > .zero else {
            throw MobileNativeToolError.timedOut("本地通知")
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.request = request
                let center = UNUserNotificationCenter.current()
                self.center = center
                startTimeout(timeout)
                center.getNotificationSettings { [weak self] settings in
                    let status = settings.authorizationStatus.rawValue
                    Task { @MainActor in
                        self?.handleAuthorizationStatus(status)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func handleAuthorizationStatus(_ rawStatus: Int) {
        guard !isFinished, let center else { return }
        guard let status = UNAuthorizationStatus(rawValue: rawStatus) else {
            finish(.failure(MobileNativeToolError.operationFailed("通知授权")))
            return
        }
        switch status {
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in
                    guard error == nil else {
                        self?.finish(.failure(MobileNativeToolError.operationFailed("通知授权")))
                        return
                    }
                    if granted {
                        self?.addRequest()
                    } else {
                        self?.finish(.failure(MobileNativeToolError.permissionDenied("通知")))
                    }
                }
            }
        case .denied:
            finish(.failure(MobileNativeToolError.permissionDenied("通知")))
        case .authorized, .provisional, .ephemeral:
            addRequest()
        @unknown default:
            finish(.failure(MobileNativeToolError.operationFailed("通知授权")))
        }
    }

    private func addRequest() {
        guard !isFinished, let center, let request else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(request.delaySeconds),
            repeats: false
        )
        let notification = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        center.add(notification) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if self.isFinished {
                    self.center?.removePendingNotificationRequests(
                        withIdentifiers: [request.identifier]
                    )
                } else if error == nil {
                    self.finish(.success(()))
                } else {
                    self.finish(.failure(MobileNativeToolError.operationFailed("本地通知")))
                }
            }
        }
    }

    private func startTimeout(_ timeout: Duration) {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(.failure(MobileNativeToolError.timedOut("本地通知")))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result, let identifier = request?.identifier {
            center?.removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        center = nil
        request = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

struct SystemDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    func authenticateDeviceOwner(
        reason: String,
        timeout: Duration
    ) async throws {
        try await DeviceOwnerAuthenticationBridge.perform(reason: reason, timeout: timeout)
    }
}

@MainActor
private final class DeviceOwnerAuthenticationBridge {
    private var continuation: CheckedContinuation<Void, Error>?
    private var context: LAContext?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    static func perform(reason: String, timeout: Duration) async throws {
        let bridge = DeviceOwnerAuthenticationBridge()
        try await bridge.authenticate(reason: reason, timeout: timeout)
    }

    private func authenticate(reason: String, timeout: Duration) async throws {
        guard timeout > .zero else {
            throw MobileNativeToolError.timedOut("设备所有者验证")
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let context = LAContext()
                context.localizedCancelTitle = "取消"
                self.context = context
                var error: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                    finish(.failure(Self.mapAuthenticationError(error)))
                    return
                }
                startTimeout(timeout)
                context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                ) { [weak self] success, error in
                    let code = (error as? LAError)?.code.rawValue
                    Task { @MainActor in
                        if success {
                            self?.finish(.success(()))
                        } else {
                            self?.finish(.failure(Self.mapAuthenticationCode(code)))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func startTimeout(_ timeout: Duration) {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(.failure(MobileNativeToolError.timedOut("设备所有者验证")))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        context?.invalidate()
        context = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    nonisolated private static func mapAuthenticationError(_ error: NSError?) -> Error {
        mapAuthenticationCode((error as? LAError)?.code.rawValue)
    }

    nonisolated private static func mapAuthenticationCode(_ rawCode: Int?) -> Error {
        guard let rawCode, let code = LAError.Code(rawValue: rawCode) else {
            return MobileNativeToolError.hardwareUnavailable("设备所有者验证")
        }
        switch code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return MobileNativeToolError.authenticationCancelled
        case .authenticationFailed:
            return MobileNativeToolError.authenticationFailed
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet, .notInteractive:
            return MobileNativeToolError.hardwareUnavailable("设备所有者验证")
        case .biometryLockout:
            return MobileNativeToolError.restricted("生物识别")
        default:
            return MobileNativeToolError.operationFailed("设备所有者验证")
        }
    }
}
#endif
