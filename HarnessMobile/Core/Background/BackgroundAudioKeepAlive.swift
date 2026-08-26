import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
protocol BackgroundAudioKeepAliveEngine: AnyObject {
    var isHealthy: Bool { get }
    func start() throws
    func stop()
}

@MainActor
protocol BackgroundAudioKeepAliveEngineFactory: AnyObject {
    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine
}

enum BackgroundAudioKeepAlivePhase: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case suspended
    case degraded
}

struct BackgroundAudioKeepAliveSnapshot: Equatable, Sendable {
    var isBackgrounded: Bool
    var requested: Bool
    var suspendCount: Int
    var generation: UInt64
    var phase: BackgroundAudioKeepAlivePhase
    var attempt: Int
    var lastError: String?
}

enum BackgroundAudioKeepAliveError: Error, Equatable, Sendable {
    case engineCreationFailed
    case engineStartFailed
    case engineUnhealthy
}

#if os(iOS)
@MainActor
private final class AVAudioEngineKeepAlive: BackgroundAudioKeepAliveEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    var isHealthy: Bool {
        engine.isRunning && player.isPlaying
    }

    func start() throws {
        engine.attach(player)
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw BackgroundAudioKeepAliveError.engineCreationFailed
        }

        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channelData[channel].initialize(repeating: 0, count: Int(frameCount))
            }
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        // The buffer is bit-for-bit silence; the tiny mixer volume keeps an
        // active playback route without producing an audible signal.
        engine.mainMixerNode.outputVolume = 0.001
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        guard isHealthy else {
            stop()
            throw BackgroundAudioKeepAliveError.engineUnhealthy
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.detach(player)
    }
}

@MainActor
private final class AVAudioEngineKeepAliveFactory: BackgroundAudioKeepAliveEngineFactory {
    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine {
        AVAudioEngineKeepAlive()
    }
}
#else
@MainActor
private final class NoopBackgroundAudioKeepAliveFactory: BackgroundAudioKeepAliveEngineFactory {
    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine {
        throw BackgroundAudioKeepAliveError.engineCreationFailed
    }
}
#endif

/// Owns the silent playback engine used by the extended background leg.
///
/// This class deliberately does not decide whether a run should survive. The
/// background coordinator (currently AppModel's lifecycle bridge) supplies
/// `requested`; this object only enforces the background gate, media suspend
/// refcount, generation ordering, bounded retries, and engine health checks.
@MainActor
final class BackgroundAudioKeepAlive {
    private let factory: any BackgroundAudioKeepAliveEngineFactory
    private let stopDebounceNanoseconds: UInt64
    private let retryDelayNanoseconds: UInt64
    private let maxAttempts: Int
    private var engine: (any BackgroundAudioKeepAliveEngine)?
    private var retryTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var intentHeld = false

    private(set) var snapshot: BackgroundAudioKeepAliveSnapshot
    var onStateChange: ((BackgroundAudioKeepAliveSnapshot) -> Void)?

    init(
        factory: (any BackgroundAudioKeepAliveEngineFactory)? = nil,
        stopDebounceNanoseconds: UInt64 = 1_500_000_000,
        retryDelayNanoseconds: UInt64 = 500_000_000,
        maxAttempts: Int = 3,
        observeNotifications: Bool = true
    ) {
#if os(iOS)
        self.factory = factory ?? AVAudioEngineKeepAliveFactory()
#else
        self.factory = factory ?? NoopBackgroundAudioKeepAliveFactory()
#endif
        self.stopDebounceNanoseconds = stopDebounceNanoseconds
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.maxAttempts = max(1, maxAttempts)
        snapshot = BackgroundAudioKeepAliveSnapshot(
            isBackgrounded: false,
            requested: false,
            suspendCount: 0,
            generation: 0,
            phase: .idle,
            attempt: 0,
            lastError: nil
        )
        if observeNotifications {
            registerObservers()
        }
    }

    var isRunning: Bool { snapshot.phase == .running && engine?.isHealthy == true }

    func update(isBackgrounded: Bool, requested: Bool) {
        let changed = snapshot.isBackgrounded != isBackgrounded || snapshot.requested != requested
        snapshot.isBackgrounded = isBackgrounded
        snapshot.requested = requested
        guard changed else {
            reconcile()
            return
        }
        snapshot.generation &+= 1
        snapshot.attempt = 0
        snapshot.lastError = nil
        cancelPendingStop()
        cancelRetry()
        reconcile()
    }

    func suspendForMedia() {
        snapshot.suspendCount += 1
        snapshot.generation &+= 1
        cancelPendingStop()
        cancelRetry()
        reconcile(immediateStop: true)
    }

    func resumeForMedia() {
        guard snapshot.suspendCount > 0 else { return }
        snapshot.suspendCount -= 1
        snapshot.generation &+= 1
        reconcile()
    }

    func handleInterruptionEnded() {
        guard wanted else { return }
        snapshot.generation &+= 1
        cancelRetry()
        stopEngineOnly()
        beginStart(for: snapshot.generation)
    }

    func handleMediaServicesReset() {
        guard wanted else { return }
        snapshot.generation &+= 1
        cancelRetry()
        stopEngineOnly()
        beginStart(for: snapshot.generation)
    }

    private var wanted: Bool {
        snapshot.isBackgrounded && snapshot.requested && snapshot.suspendCount == 0
    }

    private func reconcile(immediateStop: Bool = false) {
        if wanted {
            cancelPendingStop()
            guard !isRunning else {
                setPhase(.running, attempt: 0, error: nil)
                return
            }
            beginStart(for: snapshot.generation)
            return
        }

        guard intentHeld || engine != nil else {
            setPhase(snapshot.suspendCount > 0 ? .suspended : .idle, attempt: 0, error: nil)
            return
        }
        if !immediateStop && !snapshot.isBackgrounded && snapshot.requested && snapshot.suspendCount == 0 {
            scheduleDebouncedStop(for: snapshot.generation)
        } else {
            stopNow(phase: snapshot.suspendCount > 0 ? .suspended : .idle)
        }
    }

    private func beginStart(for generation: UInt64) {
        guard generation == snapshot.generation, wanted, !isRunning else { return }
        cancelPendingStop()
        guard retryTask == nil else { return }
        if !intentHeld {
            HarnessAudioSessionCoordinator.shared.begin(.backgroundKeepAlive)
            intentHeld = true
        }
        snapshot.attempt += 1
        setPhase(.starting, attempt: snapshot.attempt, error: nil)
        do {
            let newEngine = try factory.makeEngine()
            try newEngine.start()
            guard generation == snapshot.generation, wanted, newEngine.isHealthy else {
                newEngine.stop()
                throw BackgroundAudioKeepAliveError.engineUnhealthy
            }
            engine = newEngine
            setPhase(.running, attempt: snapshot.attempt, error: nil)
            snapshot.attempt = 0
            startHealthMonitor(for: generation)
        } catch {
            engine = nil
            scheduleRetry(for: generation, error: error)
        }
    }

    private func scheduleRetry(for generation: UInt64, error: Error) {
        let message = String(describing: error)
        setPhase(.degraded, attempt: snapshot.attempt, error: message)
        guard snapshot.attempt < maxAttempts, wanted else {
            releaseIntent()
            return
        }
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.retryDelayNanoseconds)
            } catch {
                return
            }
            self.retryTask = nil
            guard generation == self.snapshot.generation, self.wanted else { return }
            self.beginStart(for: generation)
        }
    }

    private func startHealthMonitor(for generation: UInt64) {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard generation == self.snapshot.generation, self.wanted else { return }
                guard self.engine?.isHealthy == true else {
                    self.stopEngineOnly()
                    self.beginStart(for: generation)
                    return
                }
            }
        }
    }

    private func scheduleDebouncedStop(for generation: UInt64) {
        guard pendingStopTask == nil else { return }
        pendingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.stopDebounceNanoseconds)
            } catch {
                return
            }
            self.pendingStopTask = nil
            guard generation == self.snapshot.generation else { return }
            self.stopNow(phase: .idle)
        }
    }

    private func stopNow(phase: BackgroundAudioKeepAlivePhase) {
        snapshot.generation &+= 1
        cancelPendingStop()
        cancelRetry()
        stopEngineOnly()
        releaseIntent()
        setPhase(phase, attempt: 0, error: nil)
    }

    private func stopEngineOnly() {
        healthTask?.cancel()
        healthTask = nil
        engine?.stop()
        engine = nil
    }

    private func releaseIntent() {
        guard intentHeld else { return }
        intentHeld = false
        HarnessAudioSessionCoordinator.shared.end(.backgroundKeepAlive)
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func cancelPendingStop() {
        pendingStopTask?.cancel()
        pendingStopTask = nil
    }

    private func setPhase(
        _ phase: BackgroundAudioKeepAlivePhase,
        attempt: Int,
        error: String?
    ) {
        snapshot.phase = phase
        snapshot.attempt = attempt
        snapshot.lastError = error
        onStateChange?(snapshot)
    }

    private func registerObservers() {
#if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor in self?.handleInterruptionEnded() }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
#endif
    }
}
