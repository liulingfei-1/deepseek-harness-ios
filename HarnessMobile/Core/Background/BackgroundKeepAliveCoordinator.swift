import Foundation

/// Serializes the OS survival legs. It owns no Agent/session state and never
/// decides whether a run is allowed to continue; it only reflects leases and
/// routes lifecycle inputs to the process-level audio/location resources.
@MainActor
final class BackgroundKeepAliveCoordinator {
    private let audio: BackgroundAudioKeepAlive
    private let location: BackgroundLocationKeepAlive
    private var inputs = BackgroundKeepAliveInputs.idle

    private(set) var state = BackgroundKeepAliveState.idle
    var onStateChange: ((BackgroundKeepAliveState) -> Void)?

    init(
        audio: BackgroundAudioKeepAlive = BackgroundAudioKeepAlive(),
        location: BackgroundLocationKeepAlive = BackgroundLocationKeepAlive()
    ) {
        self.audio = audio
        self.location = location
        audio.onStateChange = { [weak self] _ in self?.reconcile() }
        location.onStateChange = { [weak self] _ in self?.reconcile() }
    }

    func update(_ inputs: BackgroundKeepAliveInputs) {
        let changed = self.inputs != inputs
        self.inputs = inputs
        if changed {
            state.generation &+= 1
        }
        audio.update(
            isBackgrounded: inputs.isBackgrounded,
            requested: inputs.enhancedAudioRequested && inputs.hasLiveRoot
        )
        location.update(
            isBackgrounded: inputs.isBackgrounded,
            requested: inputs.locationRequested,
            hasLiveRoot: inputs.hasLiveRoot
        )
        reconcile()
    }

    func suspendAudioForMedia() {
        audio.suspendForMedia()
        reconcile()
    }

    func resumeAudioForMedia() {
        audio.resumeForMedia()
        reconcile()
    }

    var locationSnapshot: BackgroundLocationKeepAliveSnapshot {
        location.snapshot
    }

    /// Only real, currently running long-lived modes qualify. A saved toggle,
    /// pending retry, finite task, or Continued Processing request alone does
    /// not prove that the process can survive after an OS task expires.
    var hasHealthyExtendedLease: Bool {
        state.layers.contains(.extendedAudio)
            || state.layers.contains(.extendedLocation)
    }

    func requestLocationAuthorizationIfEnabled() {
        location.requestAlwaysAuthorizationIfEnabled()
    }

    private func reconcile() {
        var layers = Set<BackgroundKeepAliveLayer>()
        guard inputs.isBackgrounded, inputs.hasLiveRoot else {
            layers.insert(.foreground)
            publish(layers, degradedDetails: [])
            return
        }

        if inputs.hasFiniteBackgroundLease {
            layers.insert(.finiteBackgroundTask)
        }
        if inputs.hasContinuedProcessing {
            layers.insert(.continuedProcessing)
        }
        if audio.snapshot.phase == .running {
            layers.insert(.extendedAudio)
        }
        if location.snapshot.phase == .running {
            layers.insert(.extendedLocation)
        }
        if inputs.isLowPowerMode {
            layers.insert(.degraded(.lowPowerMode))
        }
        if inputs.isThermallyConstrained {
            layers.insert(.degraded(.thermalPressure))
        }
        if audio.snapshot.phase == .degraded {
            layers.insert(.degraded(.audioUnavailable))
        }
        if case .degraded = location.snapshot.phase {
            layers.insert(.degraded(.locationUnavailable))
        }
        var degradedDetails: [String] = []
        if inputs.isLowPowerMode {
            degradedDetails.append("low_power_mode")
        }
        if inputs.isThermallyConstrained {
            degradedDetails.append("thermal_pressure")
        }
        if audio.snapshot.phase == .degraded {
            let detail = audio.snapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
            degradedDetails.append(
                detail.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
                    ?? "audio_unavailable"
            )
        }
        if case let .degraded(authorization) = location.snapshot.phase {
            degradedDetails.append(Self.locationDegradedDetail(authorization))
        }
        publish(layers, degradedDetails: degradedDetails)
    }

    private func publish(_ layers: Set<BackgroundKeepAliveLayer>, degradedDetails: [String]) {
        guard state.layers != layers
                || state.inputs != inputs
                || state.degradedDetails != degradedDetails else { return }
        state.inputs = inputs
        state.layers = layers
        state.degradedDetails = degradedDetails
        onStateChange?(state)
    }

    private static func locationDegradedDetail(
        _ authorization: BackgroundLocationAuthorization
    ) -> String {
        switch authorization {
        case .notDetermined: "location_not_determined"
        case .whenInUse: "location_when_in_use"
        case .always: "location_always_unavailable"
        case .denied: "location_denied"
        case .restricted: "location_restricted"
        case .unavailable: "location_unavailable"
        }
    }
}
