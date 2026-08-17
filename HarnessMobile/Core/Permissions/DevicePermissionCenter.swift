import Foundation

#if os(iOS)
import AVFoundation
import Contacts
import CoreBluetooth
import CoreLocation
import CoreMotion
import CoreNFC
import EventKit
import HealthKit
import MediaPlayer
import Photos
import Speech
import UserNotifications
#endif

enum DevicePermissionCapability: String, CaseIterable, Identifiable, Sendable {
    case camera
    case microphone
    case speech
    case location
    case motion
    case notifications
    case bluetooth
    case localNetwork = "local_network"
    case contacts
    case photos
    case calendar
    case reminders
    case mediaLibrary
    case healthKit
    case homeKit
    case nfc

    var id: String { rawValue }
}

enum DevicePermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case limited
    case writeOnly
    case denied
    case restricted
    case unavailable
    case notIntegrated
    case sessionOnly
}

struct DevicePermissionSnapshot: Identifiable, Sendable, Equatable {
    let capability: DevicePermissionCapability
    let status: DevicePermissionStatus

    var id: DevicePermissionCapability { capability }
}

protocol DevicePermissionStatusProviding: Sendable {
    func authorizationStatuses() async -> [DevicePermissionSnapshot]
}

struct DevicePermissionCenter: Sendable {
    private let provider: any DevicePermissionStatusProviding

    init(provider: any DevicePermissionStatusProviding) {
        self.provider = provider
    }

    func refresh() async -> [DevicePermissionSnapshot] {
        let reported = await provider.authorizationStatuses()
        let statuses = reported.reduce(into: [DevicePermissionCapability: DevicePermissionStatus]()) {
            $0[$1.capability] = $1.status
        }
        return DevicePermissionCapability.allCases.map { capability in
            DevicePermissionSnapshot(
                capability: capability,
                status: statuses[capability] ?? .unavailable
            )
        }
    }
}

#if os(iOS)
extension DevicePermissionCenter {
    static let system = DevicePermissionCenter(
        provider: SystemDevicePermissionStatusProvider()
    )
}

struct SystemDevicePermissionStatusProvider: DevicePermissionStatusProviding {
    func authorizationStatuses() async -> [DevicePermissionSnapshot] {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()

        return [
            snapshot(.camera, cameraStatus),
            snapshot(.microphone, microphoneStatus),
            snapshot(.speech, speechStatus),
            snapshot(.location, locationStatus),
            snapshot(.motion, motionStatus),
            snapshot(.notifications, notificationStatus(notificationSettings.authorizationStatus)),
            snapshot(.bluetooth, bluetoothStatus),
            // iOS has no non-invasive global local-network status API. A
            // discovery probe is an actual operation and may prompt.
            snapshot(.localNetwork, .notIntegrated),
            snapshot(.contacts, contactsStatus),
            snapshot(.photos, photosStatus),
            snapshot(.calendar, eventStatus(for: .event)),
            snapshot(.reminders, eventStatus(for: .reminder)),
            snapshot(.mediaLibrary, mediaLibraryStatus),
            snapshot(.healthKit, healthKitStatus),
            snapshot(.homeKit, .notIntegrated),
            snapshot(.nfc, NFCNDEFReaderSession.readingAvailable ? .sessionOnly : .unavailable),
        ]
    }

    private func snapshot(
        _ capability: DevicePermissionCapability,
        _ status: DevicePermissionStatus
    ) -> DevicePermissionSnapshot {
        DevicePermissionSnapshot(capability: capability, status: status)
    }

    private var cameraStatus: DevicePermissionStatus {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var microphoneStatus: DevicePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var speechStatus: DevicePermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var locationStatus: DevicePermissionStatus {
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var motionStatus: DevicePermissionStatus {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    private func notificationStatus(
        _ status: UNAuthorizationStatus
    ) -> DevicePermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .limited
        @unknown default: return .unavailable
        }
    }

    private var bluetoothStatus: DevicePermissionStatus {
        switch CBManager.authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var contactsStatus: DevicePermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .unavailable
        }
    }

    private var photosStatus: DevicePermissionStatus {
        let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch readWrite {
        case .authorized: return .authorized
        case .limited: return .limited
        case .restricted: return .restricted
        case .notDetermined:
            switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
            case .authorized: return .writeOnly
            case .limited: return .limited
            case .restricted: return .restricted
            case .denied, .notDetermined: return .notDetermined
            @unknown default: return .unavailable
            }
        case .denied:
            switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
            case .authorized: return .writeOnly
            case .limited: return .limited
            case .restricted: return .restricted
            case .denied, .notDetermined: return .denied
            @unknown default: return .unavailable
            }
        @unknown default: return .unavailable
        }
    }

    private func eventStatus(for entityType: EKEntityType) -> DevicePermissionStatus {
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized, .fullAccess: return .authorized
        case .writeOnly: return .writeOnly
        @unknown default: return .unavailable
        }
    }

    private var mediaLibraryStatus: DevicePermissionStatus {
        switch MPMediaLibrary.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    private var healthKitStatus: DevicePermissionStatus {
        HKHealthStore.isHealthDataAvailable() ? .notIntegrated : .unavailable
    }
}
#endif
