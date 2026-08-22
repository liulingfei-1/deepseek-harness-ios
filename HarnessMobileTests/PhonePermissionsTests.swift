import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class PhonePermissionsTests: XCTestCase {
    func testRefreshQueriesStatusesWithoutRequestingPermissions() async {
        let provider = PermissionStatusProviderFake(statuses: [
            DevicePermissionSnapshot(capability: .contacts, status: .authorized),
            DevicePermissionSnapshot(capability: .healthKit, status: .systemManaged),
            DevicePermissionSnapshot(capability: .nfc, status: .sessionOnly),
        ])
        let center = DevicePermissionCenter(provider: provider)

        let snapshots = await center.refresh()
        let counts = await provider.counts

        XCTAssertEqual(snapshots.count, DevicePermissionCapability.allCases.count)
        XCTAssertEqual(
            snapshots.first(where: { $0.capability == .contacts })?.status,
            .authorized
        )
        XCTAssertEqual(
            snapshots.first(where: { $0.capability == .nfc })?.status,
            .sessionOnly
        )
        XCTAssertEqual(
            snapshots.first(where: { $0.capability == .healthKit })?.status,
            .systemManaged
        )
        XCTAssertEqual(
            snapshots.first(where: { $0.capability == .camera })?.status,
            .unavailable
        )
        XCTAssertEqual(counts.statusReads, 1)
        XCTAssertEqual(counts.permissionRequests, 0)
    }

    func testCapabilityCatalogContainsEveryRequestedPhonePermission() {
        XCTAssertEqual(
            Set(DevicePermissionCapability.allCases),
            [
                .camera, .microphone, .speech, .location, .motion,
                .notifications, .bluetooth, .localNetwork, .contacts, .photos, .calendar,
                .reminders, .mediaLibrary, .healthKit, .homeKit, .nfc,
            ]
        )
    }
}

private actor PermissionStatusProviderFake: DevicePermissionStatusProviding {
    private let statuses: [DevicePermissionSnapshot]
    private var statusReads = 0
    private var permissionRequests = 0

    init(statuses: [DevicePermissionSnapshot]) {
        self.statuses = statuses
    }

    func authorizationStatuses() -> [DevicePermissionSnapshot] {
        statusReads += 1
        return statuses
    }

    var counts: (statusReads: Int, permissionRequests: Int) {
        (statusReads, permissionRequests)
    }
}
