import Foundation

enum BackgroundKeepAliveLayer: Hashable, Sendable {
    case foreground
    case finiteBackgroundTask
    case continuedProcessing
    case extendedAudio
    case extendedLocation
    case degraded(BackgroundKeepAliveDegradedReason)
}

enum BackgroundKeepAliveDegradedReason: Hashable, Sendable {
    case lowPowerMode
    case thermalPressure
    case audioUnavailable
    case locationUnavailable
}

struct BackgroundKeepAliveInputs: Equatable, Sendable {
    var isBackgrounded: Bool
    var hasLiveRoot: Bool
    var enhancedAudioRequested: Bool
    var locationRequested: Bool
    var hasFiniteBackgroundLease: Bool
    var hasContinuedProcessing: Bool
    var isLowPowerMode: Bool
    var isThermallyConstrained: Bool

    static let idle = BackgroundKeepAliveInputs(
        isBackgrounded: false,
        hasLiveRoot: false,
        enhancedAudioRequested: false,
        locationRequested: false,
        hasFiniteBackgroundLease: false,
        hasContinuedProcessing: false,
        isLowPowerMode: false,
        isThermallyConstrained: false
    )
}

struct BackgroundKeepAliveState: Equatable, Sendable {
    var inputs: BackgroundKeepAliveInputs
    var layers: Set<BackgroundKeepAliveLayer>
    var generation: UInt64
    var degradedDetails: [String]

    init(
        inputs: BackgroundKeepAliveInputs,
        layers: Set<BackgroundKeepAliveLayer>,
        generation: UInt64,
        degradedDetails: [String] = []
    ) {
        self.inputs = inputs
        self.layers = layers
        self.generation = generation
        self.degradedDetails = degradedDetails
    }

    static let idle = BackgroundKeepAliveState(
        inputs: .idle,
        layers: [.foreground],
        generation: 0,
        degradedDetails: []
    )
}

enum BackgroundSurvivalTier: String, Codable, Equatable, Sendable {
    case foreground
    case finiteBackgroundTask
    case continuedProcessing
    case extendedAudio
    case extendedLocation
    case degraded
}

/// One privacy-safe source of truth for the home screen, settings and system
/// surfaces. It contains counts and capability state only; no prompt, tool
/// arguments, output or model text is allowed here.
struct BackgroundSystemProjection: Equatable, Sendable {
    var activeRunCount: Int
    var survivalTier: BackgroundSurvivalTier
    var layers: Set<BackgroundKeepAliveLayer>
    var degradedReasons: Set<BackgroundKeepAliveDegradedReason>
    var degradedDetails: [String]
    var isBackgrounded: Bool
    var liveActivitySupported: Bool
    var liveActivityEnabled: Bool
    var notificationAuthorization: String
    var locationAuthorization: String
    var privacyModeEnabled: Bool

    static let empty = BackgroundSystemProjection(
        activeRunCount: 0,
        survivalTier: .foreground,
        layers: [.foreground],
        degradedReasons: [],
        degradedDetails: [],
        isBackgrounded: false,
        liveActivitySupported: false,
        liveActivityEnabled: false,
        notificationAuthorization: "尚未请求",
        locationAuthorization: "尚未请求",
        privacyModeEnabled: true
    )

    static func make(
        activeRunCount: Int,
        keepAliveState: BackgroundKeepAliveState,
        isBackgrounded: Bool,
        liveActivitySupported: Bool,
        liveActivityEnabled: Bool,
        notificationAuthorization: String,
        locationAuthorization: String,
        privacyModeEnabled: Bool
    ) -> BackgroundSystemProjection {
        let layers = keepAliveState.layers
        let degradedReasons = Set(layers.compactMap { layer -> BackgroundKeepAliveDegradedReason? in
            guard case let .degraded(reason) = layer else { return nil }
            return reason
        })
        let tier: BackgroundSurvivalTier
        if layers.contains(.continuedProcessing) {
            tier = .continuedProcessing
        } else if layers.contains(.extendedAudio) {
            tier = .extendedAudio
        } else if layers.contains(.extendedLocation) {
            tier = .extendedLocation
        } else if layers.contains(.finiteBackgroundTask) {
            tier = .finiteBackgroundTask
        } else if !degradedReasons.isEmpty {
            tier = .degraded
        } else {
            tier = .foreground
        }
        return BackgroundSystemProjection(
            activeRunCount: max(0, activeRunCount),
            survivalTier: tier,
            layers: layers,
            degradedReasons: degradedReasons,
            degradedDetails: keepAliveState.degradedDetails,
            isBackgrounded: isBackgrounded,
            liveActivitySupported: liveActivitySupported,
            liveActivityEnabled: liveActivityEnabled,
            notificationAuthorization: notificationAuthorization,
            locationAuthorization: locationAuthorization,
            privacyModeEnabled: privacyModeEnabled
        )
    }
}
