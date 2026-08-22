import Foundation

/// A single, machine-readable description of a capability that the phone
/// can expose to the agent.  This deliberately includes capabilities which
/// are entitlement-gated or system-mediated: reporting them as unavailable is
/// more useful than making the model guess why an otherwise valid call fails.
struct DeviceCapabilityRecord: Sendable, Equatable {
    let id: String
    let title: String
    let status: String
    let tools: [String]
    let requiresSystemInteraction: Bool
    let entitlement: String?
    let notes: String
}

struct DeviceCapabilityInventory: Sendable, Equatable {
    let records: [DeviceCapabilityRecord]

    func filtered(to capabilityID: String?) -> [DeviceCapabilityRecord] {
        guard let capabilityID else { return records }
        return records.filter { $0.id == capabilityID }
    }
}

protocol DeviceCapabilityInventoryProviding: Sendable {
    func inventory() async -> DeviceCapabilityInventory
}

/// The catalog is intentionally data-only.  Adding a new native offload or a
/// new Apple entitlement therefore has one obvious place to document its
/// user-visible boundary, even when the implementation is supplied by an
/// upstream OpenMinis bridge.
enum DeviceCapabilityCatalog {
    static let records: [DeviceCapabilityRecord] = [
        permission(
            "camera", "相机", tools: ["camera_ocr", "apple-vision"],
            interaction: true, notes: "首次使用由 iOS 显示相机授权；相机画面不会静默后台采集。"
        ),
        permission(
            "microphone", "麦克风", tools: ["apple-speech"],
            interaction: true, notes: "录音只在主动语音操作期间进行。"
        ),
        permission(
            "speech", "语音识别", tools: ["apple-speech"],
            interaction: true, notes: "识别结果会作为工具结果发送给模型。"
        ),
        permission(
            "location", "定位", tools: ["location_current", "apple-location", "apple-maps"],
            interaction: true, notes: "当前实现只请求使用期间定位；不用于保活或假定位。"
        ),
        permission(
            "motion", "运动与健身", tools: ["motion_activity"],
            interaction: true, notes: "读取有界时间窗口的活动估计。"
        ),
        permission(
            "notifications", "通知", tools: ["notification_schedule", "apple-notification"],
            interaction: true, notes: "本地通知由手机调度，不依赖推送服务器。"
        ),
        permission(
            "bluetooth", "蓝牙 LE", tools: ["apple-bluetooth"],
            interaction: true, notes: "可扫描、连接和读写已发现的 BLE 特征。"
        ),
        permission(
            "contacts", "联系人", tools: ["contacts_search"],
            interaction: true, notes: "当前工具只读有限的姓名、电话和邮箱。"
        ),
        permission(
            "photos", "照片图库", tools: ["camera_ocr", "apple-photos", "apple-vision"],
            interaction: true, notes: "选择器和有限图库访问仍由 iOS 控制。"
        ),
        permission(
            "calendar", "日历", tools: ["apple-calendar"],
            interaction: true, notes: "iOS 17.4+ 可能区分完整访问和仅写入。"
        ),
        permission(
            "reminders", "提醒事项", tools: ["apple-reminders"],
            interaction: true, notes: "提醒事项授权由 EventKit 管理。"
        ),
        permission(
            "mediaLibrary", "媒体资料库", tools: ["apple-media"],
            interaction: true, notes: "访问本机音乐资料库，不代表可以读取第三方服务的私有数据。"
        ),
        permission(
            "healthKit", "HealthKit", tools: ["apple-healthkit"],
            interaction: true, entitlement: "com.apple.developer.healthkit",
            notes: "需要签名 entitlement，并且每种健康数据类型分别授权。"
        ),
        permission(
            "homeKit", "HomeKit", tools: ["apple-homekit"],
            interaction: true, entitlement: "com.apple.developer.homekit",
            notes: "需要 HomeKit entitlement 和家庭访问授权。"
        ),
        permission(
            "nfc", "NFC", tools: ["apple-nfc"],
            interaction: true, entitlement: "com.apple.developer.nfc.readersession.formats",
            notes: "每次扫描都会开启可见的 NFC 系统会话，不能永久静默授权。"
        ),
        staticRecord(
            "clipboard", "剪贴板", status: "session_only", tools: ["apple-clipboard"],
            interaction: true, notes: "读取其他 App 写入的内容可能触发 iOS 粘贴隐私提示。"
        ),
        staticRecord(
            "biometric_auth", "设备所有者验证", status: "available", tools: ["secure_authenticate"],
            interaction: true, notes: "Face ID/Touch ID/密码界面由系统控制；生物特征不会返回给模型。"
        ),
        staticRecord(
            "device_status", "设备状态", status: "available", tools: ["ios_native:apple-device", "device_time"],
            interaction: false, notes: "电量、存储、热状态和时间等不需要隐私授权。"
        ),
        staticRecord(
            "vision", "Vision 本机视觉", status: "available", tools: ["camera_ocr", "ios_native:apple-vision"],
            interaction: false, notes: "OCR、条码、分类和图像分析在手机本机执行。"
        ),
        staticRecord(
            "natural_language", "NaturalLanguage 本机文本分析", status: "available", tools: ["ios_native:apple-nlp"],
            interaction: false, notes: "分词、语言识别、情感和实体分析不上传到模型服务。"
        ),
        staticRecord(
            "text_to_speech", "系统朗读", status: "available", tools: ["ios_native:apple-speak"],
            interaction: false, notes: "通过本机 AVSpeechSynthesizer 输出，不需要麦克风权限。"
        ),
        staticRecord(
            "maps", "地图和地理编码", status: "available", tools: ["ios_native:apple-maps"],
            interaction: false, notes: "地图查询仍受 MapKit 网络和定位状态影响。"
        ),
        staticRecord(
            "system_deep_links", "系统设置和 App Deep Link", status: "available", tools: ["ios_native:apple-open"],
            interaction: true, notes: "可打开电话、短信、邮件、网页、设置和已注册的 App scheme；iOS 决定目标 App 是否存在。"
        ),
        staticRecord(
            "file_picker", "文件和照片选择器", status: "available", tools: ["read", "camera_ocr"],
            interaction: true, notes: "文件/照片选择器的安全范围由用户在系统界面授予。"
        ),
        staticRecord(
            "local_network", "本地网络", status: "system_managed", tools: ["web_fetch", "shell_execute"],
            interaction: true, notes: "首次访问局域网设备可能出现 Local Network 系统提示；不能由 App 静默批准。"
        ),
        staticRecord(
            "app_intents", "Siri、快捷指令和 Spotlight", status: "available", tools: ["AppIntents"],
            interaction: true, notes: "由用户从快捷指令或系统入口触发，不提供任意后台命令通道。"
        ),
        staticRecord(
            "live_activity", "实时活动", status: "available", tools: ["continued_processing"],
            interaction: true, notes: "ActivityKit 只显示任务状态；iOS 仍决定后台执行时机。"
        ),
        staticRecord(
            "background_location", "后台定位", status: "constrained", tools: [],
            interaction: true, notes: "当前不启用 Always Location，也不把定位当作保活手段。"
        ),
        staticRecord(
            "background_bluetooth", "后台蓝牙", status: "constrained", tools: [],
            interaction: true, notes: "只有真实 BLE 业务才应申请后台模式；本应用不用于常驻保活。"
        ),
        staticRecord(
            "critical_alerts", "关键通知", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.usernotifications.critical-alerts",
            notes: "需要 Apple 审核授予的 entitlement，普通开发签名不能打开。"
        ),
        staticRecord(
            "nearby_interaction", "Nearby Interaction / UWB", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.nearby-interaction",
            notes: "需要配件协议和 entitlement；没有配件时不能作为通用测距工具。"
        ),
        staticRecord(
            "wifi_info", "Wi-Fi 网络信息", status: "entitlement_or_system_managed", tools: [],
            interaction: true, entitlement: "com.apple.developer.networking.wifi-info",
            notes: "SSID/BSSID 访问受 entitlement、定位和系统隐私策略共同限制。"
        ),
        staticRecord(
            "network_extension", "VPN/网络扩展", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.networking.networkextension",
            notes: "需要 Network Extension 特殊 entitlement 和系统配置流程。"
        ),
        staticRecord(
            "family_controls", "屏幕使用时间控制", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.family-controls",
            notes: "需要 Family Controls entitlement 与用户授权，当前没有具体业务因此不启用。"
        ),
        staticRecord(
            "sensor_kit", "研究传感器", status: "entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.sensorkit",
            notes: "仅面向获批研究项目，不是普通 App 可取得的通用权限。"
        ),
        staticRecord(
            "screen_capture", "屏幕录制", status: "user_initiated_only", tools: [],
            interaction: true, notes: "ReplayKit 必须由用户在前台系统界面启动，不能静默录屏。"
        ),
        staticRecord(
            "weatherkit", "WeatherKit", status: "service_entitlement_required", tools: [],
            interaction: true, entitlement: "com.apple.developer.weatherkit",
            notes: "需要 WeatherKit 服务配置；它不是可任意读取的系统隐私权限。"
        ),
        staticRecord(
            "alarmkit", "AlarmKit", status: "os_and_user_authorization_required", tools: [],
            interaction: true, notes: "iOS 26+ 的闹钟授权和系统确认流程不能被工具静默绕过。"
        ),
        staticRecord(
            "tracking", "跨 App 跟踪", status: "intentionally_disabled", tools: [],
            interaction: true, notes: "Harness 不包含广告或跨 App 跟踪功能，因此不会请求 ATT。"
        ),
    ]

    static var ids: Set<String> { Set(records.map(\.id)) }

    private static func permission(
        _ id: String,
        _ title: String,
        tools: [String],
        interaction: Bool,
        entitlement: String? = nil,
        notes: String
    ) -> DeviceCapabilityRecord {
        DeviceCapabilityRecord(
            id: id,
            title: title,
            status: "unknown",
            tools: tools,
            requiresSystemInteraction: interaction,
            entitlement: entitlement,
            notes: notes
        )
    }

    private static func staticRecord(
        _ id: String,
        _ title: String,
        status: String,
        tools: [String],
        interaction: Bool,
        entitlement: String? = nil,
        notes: String
    ) -> DeviceCapabilityRecord {
        DeviceCapabilityRecord(
            id: id,
            title: title,
            status: status,
            tools: tools,
            requiresSystemInteraction: interaction,
            entitlement: entitlement,
            notes: notes
        )
    }
}

enum DeviceCapabilityInventoryBuilder {
    static func build(
        permissionSnapshots: [DevicePermissionSnapshot]
    ) -> DeviceCapabilityInventory {
        let statuses = Dictionary(
            uniqueKeysWithValues: permissionSnapshots.map {
                ($0.capability.rawValue, $0.status.rawValue)
            }
        )
        let records = DeviceCapabilityCatalog.records.map { record in
            guard let status = statuses[record.id] else { return record }
            return DeviceCapabilityRecord(
                id: record.id,
                title: record.title,
                status: status,
                tools: record.tools,
                requiresSystemInteraction: record.requiresSystemInteraction,
                entitlement: record.entitlement,
                notes: record.notes
            )
        }
        return DeviceCapabilityInventory(records: records)
    }
}

#if os(iOS)
struct SystemDeviceCapabilityInventoryProvider: DeviceCapabilityInventoryProviding {
    func inventory() async -> DeviceCapabilityInventory {
        DeviceCapabilityInventoryBuilder.build(
            permissionSnapshots: await DevicePermissionCenter.system.refresh()
        )
    }
}
#else
struct SystemDeviceCapabilityInventoryProvider: DeviceCapabilityInventoryProviding {
    func inventory() async -> DeviceCapabilityInventory {
        DeviceCapabilityInventoryBuilder.build(
            permissionSnapshots: DevicePermissionCapability.allCases.map {
                DevicePermissionSnapshot(capability: $0, status: .unavailable)
            }
        )
    }
}
#endif

struct DeviceCapabilitiesTool: LocalAgentTool {
    private let provider: any DeviceCapabilityInventoryProviding

    let definition = ModelToolDefinition(
        name: "device_capabilities",
        description: "Inspect this iPhone's native tools, current iOS privacy authorization states, and entitlement or system-interaction limits. It only reports state; it never grants a permission or runs a remote command.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "capability": .object([
                    "type": .string("string"),
                    "enum": .array(DeviceCapabilityCatalog.records.map { .string($0.id) }),
                    "description": .string("Optional capability ID to inspect. Omit it to return the complete inventory.")
                ]),
                "include_unavailable": .object([
                    "type": .string("boolean"),
                    "description": .string("Include entitlement-gated and intentionally disabled capabilities. Defaults to true.")
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(provider: any DeviceCapabilityInventoryProviding) {
        self.provider = provider
    }

    #if os(iOS)
    init() {
        self.provider = SystemDeviceCapabilityInventoryProvider()
    }
    #endif

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["capability", "include_unavailable"])
        if let capability = arguments["capability"]?.stringValue {
            guard DeviceCapabilityCatalog.ids.contains(capability),
                  capability.utf8.count <= 80 else {
                throw LocalToolError.invalidArguments
            }
        } else if arguments["capability"] != nil {
            throw LocalToolError.invalidArguments
        }
        if let include = arguments["include_unavailable"] {
            guard case .bool = include else { throw LocalToolError.invalidArguments }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        if let capability = arguments["capability"]?.stringValue {
            return "读取手机能力状态：\(capability)"
        }
        return "读取手机原生能力和 iOS 权限状态"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["device-capabilities"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let inventory = await provider.inventory()
        let capabilityID = arguments["capability"]?.stringValue
        let includeUnavailable: Bool
        if case let .bool(value) = arguments["include_unavailable"] {
            includeUnavailable = value
        } else {
            includeUnavailable = true
        }

        let records = inventory.filtered(to: capabilityID).filter { record in
            includeUnavailable || ![
                "unavailable", "notIntegrated", "entitlement_required",
                "service_entitlement_required", "intentionally_disabled"
            ].contains(record.status)
        }
        let values = records.map { record in
            var value: [String: JSONValue] = [
                "id": .string(record.id),
                "title": .string(record.title),
                "status": .string(record.status),
                "tools": .array(record.tools.map(JSONValue.string)),
                "requiresSystemInteraction": .bool(record.requiresSystemInteraction),
                "notes": .string(record.notes)
            ]
            if let entitlement = record.entitlement {
                value["entitlement"] = .string(entitlement)
            }
            return JSONValue.object(value)
        }
        return JSONValue.object([
            "count": .number(Double(values.count)),
            "capabilities": .array(values),
            "executedOn": .string("iPhone")
        ]).displayText
    }
}
