import Foundation

#if os(iOS)
import CoreLocation
#endif

enum BackgroundLocationAuthorization: Equatable, Sendable {
    case notDetermined
    case whenInUse
    case always
    case denied
    case restricted
    case unavailable
}

enum BackgroundLocationKeepAlivePhase: Equatable, Sendable {
    case idle
    case waitingForDelay
    case waitingForPermission
    case running
    case degraded(BackgroundLocationAuthorization)
}

struct BackgroundLocationKeepAliveSnapshot: Equatable, Sendable {
    var isBackgrounded: Bool
    var requested: Bool
    var hasLiveRoot: Bool
    var generation: UInt64
    var authorization: BackgroundLocationAuthorization
    var phase: BackgroundLocationKeepAlivePhase
}

@MainActor
protocol BackgroundLocationKeepAlivePlatform: AnyObject {
    var authorization: BackgroundLocationAuthorization { get }
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)? { get set }
    func requestAlwaysAuthorization()
    func startCoarseBackgroundUpdates()
    func stopCoarseBackgroundUpdates()
    func beginBackgroundActivity()
    func endBackgroundActivity()
    func retractOrphanedBackgroundActivity()
}

#if os(iOS)
@MainActor
private final class SystemBackgroundLocationKeepAlivePlatform: NSObject, BackgroundLocationKeepAlivePlatform, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var activitySession: CLBackgroundActivitySession?
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorization: BackgroundLocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startCoarseBackgroundUpdates() {
        guard authorization == .always else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    func stopCoarseBackgroundUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func beginBackgroundActivity() {
        guard activitySession == nil else { return }
        if #available(iOS 17.0, *) {
            activitySession = CLBackgroundActivitySession()
        }
    }

    func endBackgroundActivity() {
        if #available(iOS 17.0, *) {
            activitySession?.invalidate()
        }
        activitySession = nil
    }

    func retractOrphanedBackgroundActivity() {
        guard activitySession == nil else { return }
        if #available(iOS 17.0, *) {
            let probe = CLBackgroundActivitySession()
            probe.invalidate()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChanged?(Self.map(manager.authorizationStatus))
    }

    private static func map(_ status: CLAuthorizationStatus) -> BackgroundLocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
}
#else
@MainActor
private final class NoopBackgroundLocationKeepAlivePlatform: BackgroundLocationKeepAlivePlatform {
    var authorization: BackgroundLocationAuthorization = .unavailable
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)?
    func requestAlwaysAuthorization() {}
    func startCoarseBackgroundUpdates() {}
    func stopCoarseBackgroundUpdates() {}
    func beginBackgroundActivity() {}
    func endBackgroundActivity() {}
    func retractOrphanedBackgroundActivity() {}
}
#endif

/// Process-wide coarse-location survival leg. It never stores or publishes a
/// CLLocation: location data is used only by CoreLocation to keep the opted-in
/// background activity alive.
@MainActor
final class BackgroundLocationKeepAlive {
    private let platform: any BackgroundLocationKeepAlivePlatform
    private let armDelayNanoseconds: UInt64
    private var armTask: Task<Void, Never>?
    private var isRunning = false

    private(set) var snapshot: BackgroundLocationKeepAliveSnapshot
    var onStateChange: ((BackgroundLocationKeepAliveSnapshot) -> Void)?

    init(
        platform: (any BackgroundLocationKeepAlivePlatform)? = nil,
        armDelayNanoseconds: UInt64 = 15_000_000_000
    ) {
#if os(iOS)
        self.platform = platform ?? SystemBackgroundLocationKeepAlivePlatform()
#else
        self.platform = platform ?? NoopBackgroundLocationKeepAlivePlatform()
#endif
        self.armDelayNanoseconds = armDelayNanoseconds
        snapshot = BackgroundLocationKeepAliveSnapshot(
            isBackgrounded: false,
            requested: false,
            hasLiveRoot: false,
            generation: 0,
            authorization: self.platform.authorization,
            phase: .idle
        )
        self.platform.onAuthorizationChanged = { [weak self] authorization in
            self?.handleAuthorizationChange(authorization)
        }
        self.platform.retractOrphanedBackgroundActivity()
    }

    func update(isBackgrounded: Bool, requested: Bool, hasLiveRoot: Bool) {
        let changed = snapshot.isBackgrounded != isBackgrounded
            || snapshot.requested != requested
            || snapshot.hasLiveRoot != hasLiveRoot
        snapshot.isBackgrounded = isBackgrounded
        snapshot.requested = requested
        snapshot.hasLiveRoot = hasLiveRoot
        snapshot.authorization = platform.authorization
        guard changed else {
            reconcile()
            return
        }
        snapshot.generation &+= 1
        cancelArm()
        reconcile()
    }

    /// This is the only call site allowed to request Always authorization. It
    /// requires the user to have enabled the dedicated location survival leg.
    func requestAlwaysAuthorizationIfEnabled() {
        guard snapshot.requested else { return }
        guard snapshot.authorization == .notDetermined || snapshot.authorization == .whenInUse else { return }
        platform.requestAlwaysAuthorization()
    }

    func cleanupOrphansOnForeground() {
        guard !snapshot.isBackgrounded else { return }
        platform.retractOrphanedBackgroundActivity()
    }

    private var shouldArm: Bool {
        snapshot.isBackgrounded && snapshot.requested && snapshot.hasLiveRoot
    }

    private var canRun: Bool {
        shouldArm && snapshot.authorization == .always
    }

    private func reconcile() {
        guard shouldArm else {
            stopNow(phase: .idle)
            return
        }
        guard snapshot.authorization == .always else {
            stopNow(phase: .degraded(snapshot.authorization))
            return
        }
        guard !isRunning else {
            setPhase(.running)
            return
        }
        scheduleArm(for: snapshot.generation)
    }

    private func scheduleArm(for generation: UInt64) {
        guard armTask == nil else { return }
        setPhase(.waitingForDelay)
        armTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.armDelayNanoseconds)
            } catch {
                return
            }
            self.armTask = nil
            guard generation == self.snapshot.generation, self.canRun else { return }
            self.platform.beginBackgroundActivity()
            self.platform.startCoarseBackgroundUpdates()
            self.isRunning = true
            self.setPhase(.running)
        }
    }

    private func stopNow(phase: BackgroundLocationKeepAlivePhase) {
        cancelArm()
        guard isRunning else {
            setPhase(phase)
            return
        }
        platform.stopCoarseBackgroundUpdates()
        platform.endBackgroundActivity()
        isRunning = false
        setPhase(phase)
    }

    private func cancelArm() {
        armTask?.cancel()
        armTask = nil
    }

    private func handleAuthorizationChange(_ authorization: BackgroundLocationAuthorization) {
        snapshot.authorization = authorization
        snapshot.generation &+= 1
        cancelArm()
        reconcile()
    }

    private func setPhase(_ phase: BackgroundLocationKeepAlivePhase) {
        snapshot.phase = phase
        onStateChange?(snapshot)
    }
}
