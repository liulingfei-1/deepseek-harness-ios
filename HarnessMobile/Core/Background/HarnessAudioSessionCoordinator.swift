import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

enum HarnessAudioSessionCategory: String, Equatable, Sendable {
    case record
    case playback
}

enum HarnessAudioSessionMode: String, Equatable, Sendable {
    case `default`
    case measurement
    case spokenAudio
}

struct HarnessAudioSessionOptions: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let duckOthers = Self(rawValue: 1 << 0)
    static let mixWithOthers = Self(rawValue: 1 << 1)
}

struct HarnessAudioSessionState: Equatable, Sendable {
    var category: HarnessAudioSessionCategory
    var mode: HarnessAudioSessionMode
    var options: HarnessAudioSessionOptions
    var isActive: Bool
}

protocol HarnessAudioSessionPlatform: AnyObject {
    var state: HarnessAudioSessionState { get }
    func setCategory(
        _ category: HarnessAudioSessionCategory,
        mode: HarnessAudioSessionMode,
        options: HarnessAudioSessionOptions
    ) throws
    func setActive(_ active: Bool) throws
}

enum HarnessAudioSessionEvent: Equatable, Sendable {
    case began(HarnessAudioSessionCoordinator.Intent)
    case ended(HarnessAudioSessionCoordinator.Intent)
    case interruptionBegan
    case interruptionEnded
    case routeChanged
    case mediaServicesReset
    case restored
    case applyFailed
}

#if os(iOS)
private final class AVAudioSessionPlatform: HarnessAudioSessionPlatform {
    private let session = AVAudioSession.sharedInstance()
    private var active = false

    var state: HarnessAudioSessionState {
        let mode: HarnessAudioSessionMode
        switch session.mode {
        case .measurement: mode = .measurement
        case .spokenAudio: mode = .spokenAudio
        default: mode = .default
        }
        return HarnessAudioSessionState(
            category: session.category == .record ? .record : .playback,
            mode: mode,
            options: Self.options(from: session.categoryOptions),
            isActive: active
        )
    }

    func setCategory(
        _ category: HarnessAudioSessionCategory,
        mode: HarnessAudioSessionMode,
        options: HarnessAudioSessionOptions
    ) throws {
        let avCategory: AVAudioSession.Category = category == .record ? .record : .playback
        let avMode: AVAudioSession.Mode
        switch mode {
        case .measurement: avMode = .measurement
        case .spokenAudio: avMode = .spokenAudio
        case .default: avMode = .default
        }
        try session.setCategory(avCategory, mode: avMode, options: Self.avOptions(from: options))
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
        self.active = active
    }

    private static func options(from options: AVAudioSession.CategoryOptions) -> HarnessAudioSessionOptions {
        var result: HarnessAudioSessionOptions = []
        if options.contains(.duckOthers) { result.insert(.duckOthers) }
        if options.contains(.mixWithOthers) { result.insert(.mixWithOthers) }
        return result
    }

    private static func avOptions(from options: HarnessAudioSessionOptions) -> AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        if options.contains(.duckOthers) { result.insert(.duckOthers) }
        if options.contains(.mixWithOthers) { result.insert(.mixWithOthers) }
        return result
    }
}
#endif

private final class NoopAudioSessionPlatform: HarnessAudioSessionPlatform {
    var state = HarnessAudioSessionState(category: .playback, mode: .default, options: [], isActive: false)

    func setCategory(
        _ category: HarnessAudioSessionCategory,
        mode: HarnessAudioSessionMode,
        options: HarnessAudioSessionOptions
    ) throws {
        state.category = category
        state.mode = mode
        state.options = options
    }

    func setActive(_ active: Bool) throws {
        state.isActive = active
    }
}

@MainActor
final class HarnessAudioSessionCoordinator {
    static let shared = HarnessAudioSessionCoordinator()

    enum Intent: Int, CaseIterable, Sendable {
        case backgroundKeepAlive = 0
        case replyTTS = 1
        case mediaAttachment = 2
        case capture = 3
    }

    struct Snapshot: Equatable, Sendable {
        var counts: [Intent: Int]
        var highestIntent: Intent?
        var interrupted: Bool
        var lastEvent: HarnessAudioSessionEvent?
    }

    private let platform: HarnessAudioSessionPlatform
    private var counts: [Intent: Int] = [:]
    private var originalState: HarnessAudioSessionState?
    private var interrupted = false
    private(set) var lastEvent: HarnessAudioSessionEvent?
    var onStateChange: ((Snapshot) -> Void)?

    init(
        platform: HarnessAudioSessionPlatform? = nil,
        observeNotifications: Bool = true
    ) {
#if os(iOS)
        self.platform = platform ?? AVAudioSessionPlatform()
#else
        self.platform = platform ?? NoopAudioSessionPlatform()
#endif
        if observeNotifications {
            registerObservers()
        }
    }

    var snapshot: Snapshot {
        Snapshot(counts: counts, highestIntent: highestIntent, interrupted: interrupted, lastEvent: lastEvent)
    }

    func begin(_ intent: Intent) {
        if counts.values.reduce(0, +) == 0 {
            originalState = platform.state
        }
        counts[intent, default: 0] += 1
        record(.began(intent))
        applyCurrentProfile()
    }

    func end(_ intent: Intent) {
        guard let count = counts[intent], count > 0 else { return }
        if count == 1 {
            counts.removeValue(forKey: intent)
        } else {
            counts[intent] = count - 1
        }
        record(.ended(intent))
        if counts.values.reduce(0, +) == 0 {
            restoreOriginalState()
        } else {
            applyCurrentProfile()
        }
    }

    func handleInterruptionBegan() {
        interrupted = true
        record(.interruptionBegan)
        try? platform.setActive(false)
        emitState()
    }

    func handleInterruptionEnded() {
        interrupted = false
        record(.interruptionEnded)
        applyCurrentProfile()
    }

    func handleRouteChange() {
        record(.routeChanged)
        applyCurrentProfile(force: true)
    }

    func handleMediaServicesReset() {
        record(.mediaServicesReset)
        applyCurrentProfile(force: true)
    }

    private var highestIntent: Intent? {
        counts.keys.max { $0.rawValue < $1.rawValue }
    }

    private func profile(for intent: Intent) -> HarnessAudioSessionState {
        switch intent {
        case .capture:
            HarnessAudioSessionState(category: .record, mode: .measurement, options: [], isActive: true)
        case .mediaAttachment:
            HarnessAudioSessionState(category: .playback, mode: .default, options: [.duckOthers], isActive: true)
        case .replyTTS:
            HarnessAudioSessionState(category: .playback, mode: .spokenAudio, options: [.duckOthers], isActive: true)
        case .backgroundKeepAlive:
            HarnessAudioSessionState(category: .playback, mode: .default, options: [.mixWithOthers], isActive: true)
        }
    }

    private func applyCurrentProfile(force: Bool = false) {
        guard let highestIntent else {
            if let originalState {
                apply(originalState, event: .restored, force: force)
            }
            return
        }
        apply(profile(for: highestIntent), event: nil, force: force)
    }

    private func apply(_ desired: HarnessAudioSessionState, event: HarnessAudioSessionEvent?, force: Bool = false) {
        do {
            let current = platform.state
            if force || current.category != desired.category || current.mode != desired.mode || current.options != desired.options {
                try platform.setCategory(desired.category, mode: desired.mode, options: desired.options)
            }
            if current.isActive != desired.isActive || interrupted {
                try platform.setActive(desired.isActive)
            }
            interrupted = false
            if let event { record(event) } else { emitState() }
        } catch {
            record(.applyFailed)
        }
    }

    private func restoreOriginalState() {
        guard let originalState else { emitState(); return }
        apply(originalState, event: .restored)
        self.originalState = nil
    }

    private func record(_ event: HarnessAudioSessionEvent) {
        lastEvent = event
        emitState()
    }

    private func emitState() {
        onStateChange?(snapshot)
    }

    private func registerObservers() {
#if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let raw else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue { self?.handleInterruptionBegan() }
                if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.handleInterruptionEnded() }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
#endif
    }
}
