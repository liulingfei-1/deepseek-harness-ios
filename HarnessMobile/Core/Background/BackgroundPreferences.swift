import Foundation
import Observation

struct BackgroundPreferences: Codable, Equatable, Sendable {
    var isEnhancedBackgroundEnabled: Bool
    var isBackgroundLocationKeepAliveEnabled: Bool
    var isLiveActivityEnabled: Bool
    var areTaskNotificationsEnabled: Bool
    var isPrivacyModeEnabled: Bool

    static let defaults = BackgroundPreferences(
        isEnhancedBackgroundEnabled: false,
        isBackgroundLocationKeepAliveEnabled: false,
        isLiveActivityEnabled: true,
        areTaskNotificationsEnabled: false,
        isPrivacyModeEnabled: true
    )

    init(
        isEnhancedBackgroundEnabled: Bool,
        isBackgroundLocationKeepAliveEnabled: Bool = false,
        isLiveActivityEnabled: Bool = true,
        areTaskNotificationsEnabled: Bool,
        isPrivacyModeEnabled: Bool
    ) {
        self.isEnhancedBackgroundEnabled = isEnhancedBackgroundEnabled
        self.isBackgroundLocationKeepAliveEnabled = isBackgroundLocationKeepAliveEnabled
        self.isLiveActivityEnabled = isLiveActivityEnabled
        self.areTaskNotificationsEnabled = areTaskNotificationsEnabled
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case isEnhancedBackgroundEnabled
        case isBackgroundLocationKeepAliveEnabled
        case isLiveActivityEnabled
        case areTaskNotificationsEnabled
        case isPrivacyModeEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnhancedBackgroundEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isEnhancedBackgroundEnabled
        ) ?? Self.defaults.isEnhancedBackgroundEnabled
        isBackgroundLocationKeepAliveEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isBackgroundLocationKeepAliveEnabled
        ) ?? Self.defaults.isBackgroundLocationKeepAliveEnabled
        isLiveActivityEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isLiveActivityEnabled
        ) ?? Self.defaults.isLiveActivityEnabled
        areTaskNotificationsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .areTaskNotificationsEnabled
        ) ?? Self.defaults.areTaskNotificationsEnabled
        isPrivacyModeEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isPrivacyModeEnabled
        ) ?? Self.defaults.isPrivacyModeEnabled
    }
}

enum BackgroundRuntimeStatus: Equatable, Sendable {
    case idle
    case running(ContinuedProcessingStatus)
    case completed(success: Bool)
    case interrupted
}

@MainActor
struct BackgroundPreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "background.preferences.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> BackgroundPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(BackgroundPreferences.self, from: data) else {
            return .defaults
        }
        return preferences
    }

    func save(_ preferences: BackgroundPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
final class BackgroundPreferencesModel {
    var isEnhancedBackgroundEnabled: Bool {
        didSet {
            guard isEnhancedBackgroundEnabled != oldValue else { return }
            persist()
        }
    }

    var isBackgroundLocationKeepAliveEnabled: Bool {
        didSet {
            guard isBackgroundLocationKeepAliveEnabled != oldValue else { return }
            persist()
        }
    }

    var areTaskNotificationsEnabled: Bool {
        didSet {
            guard areTaskNotificationsEnabled != oldValue else { return }
            persist()
        }
    }

    var isLiveActivityEnabled: Bool {
        didSet {
            guard isLiveActivityEnabled != oldValue else { return }
            persist()
        }
    }

    var isPrivacyModeEnabled: Bool {
        didSet {
            guard isPrivacyModeEnabled != oldValue else { return }
            persist()
        }
    }

    private(set) var persistenceErrorDescription: String?

    @ObservationIgnored private let store: BackgroundPreferencesStore

    init(store: BackgroundPreferencesStore = BackgroundPreferencesStore()) {
        self.store = store
        let preferences = store.load()
        isEnhancedBackgroundEnabled = preferences.isEnhancedBackgroundEnabled
        isBackgroundLocationKeepAliveEnabled = preferences.isBackgroundLocationKeepAliveEnabled
        isLiveActivityEnabled = preferences.isLiveActivityEnabled
        areTaskNotificationsEnabled = preferences.areTaskNotificationsEnabled
        isPrivacyModeEnabled = preferences.isPrivacyModeEnabled
    }

    var value: BackgroundPreferences {
        BackgroundPreferences(
            isEnhancedBackgroundEnabled: isEnhancedBackgroundEnabled,
            isBackgroundLocationKeepAliveEnabled: isBackgroundLocationKeepAliveEnabled,
            isLiveActivityEnabled: isLiveActivityEnabled,
            areTaskNotificationsEnabled: areTaskNotificationsEnabled,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )
    }

    func reload() {
        let preferences = store.load()
        isEnhancedBackgroundEnabled = preferences.isEnhancedBackgroundEnabled
        isBackgroundLocationKeepAliveEnabled = preferences.isBackgroundLocationKeepAliveEnabled
        isLiveActivityEnabled = preferences.isLiveActivityEnabled
        areTaskNotificationsEnabled = preferences.areTaskNotificationsEnabled
        isPrivacyModeEnabled = preferences.isPrivacyModeEnabled
        persistenceErrorDescription = nil
    }

    func reset() {
        store.clear()
        isEnhancedBackgroundEnabled = BackgroundPreferences.defaults.isEnhancedBackgroundEnabled
        isBackgroundLocationKeepAliveEnabled = BackgroundPreferences.defaults.isBackgroundLocationKeepAliveEnabled
        isLiveActivityEnabled = BackgroundPreferences.defaults.isLiveActivityEnabled
        areTaskNotificationsEnabled = BackgroundPreferences.defaults.areTaskNotificationsEnabled
        isPrivacyModeEnabled = BackgroundPreferences.defaults.isPrivacyModeEnabled
        persistenceErrorDescription = nil
    }

    private func persist() {
        do {
            try store.save(value)
            persistenceErrorDescription = nil
        } catch {
            persistenceErrorDescription = error.localizedDescription
        }
    }
}
