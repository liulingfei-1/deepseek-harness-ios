import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class DeviceCapabilitiesToolTests: XCTestCase {
    func testCatalogContainsPermissionAndEntitlementBoundaries() {
        XCTAssertTrue(DeviceCapabilityCatalog.ids.contains("camera"))
        XCTAssertTrue(DeviceCapabilityCatalog.ids.contains("local_network"))
        XCTAssertTrue(DeviceCapabilityCatalog.ids.contains("healthKit"))
        XCTAssertTrue(DeviceCapabilityCatalog.ids.contains("screen_capture"))
        XCTAssertEqual(
            DeviceCapabilityCatalog.records.first(where: { $0.id == "healthKit" })?.entitlement,
            "com.apple.developer.healthkit"
        )
    }

    func testInventoryUsesLivePermissionStatusesAndSupportsFiltering() async throws {
        let provider = InventoryProviderFake(
            snapshots: [
                DevicePermissionSnapshot(capability: .camera, status: .authorized),
                DevicePermissionSnapshot(capability: .photos, status: .limited),
            ]
        )
        let tool = DeviceCapabilitiesTool(provider: provider)

        let output = try decodeObject(try await tool.execute(arguments: [
            "capability": .string("camera")
        ]))
        guard case let .array(values) = output["capabilities"] else {
            return XCTFail("expected capability array")
        }
        XCTAssertEqual(values.count, 1)
        guard case let .object(camera) = values[0] else {
            return XCTFail("expected camera object")
        }
        XCTAssertEqual(camera["status"], .string("authorized"))
        XCTAssertEqual(output["executedOn"], .string("iPhone"))
        let readCount = await provider.readCount
        XCTAssertEqual(readCount, 1)
    }

    func testValidationIsStrictAndCanHideUnavailableEntries() async throws {
        let tool = DeviceCapabilitiesTool(provider: InventoryProviderFake(snapshots: []))
        XCTAssertThrowsError(try tool.validate(arguments: ["capability": .string("unknown")]))
        XCTAssertThrowsError(try tool.validate(arguments: ["include_unavailable": .string("yes")]))
        XCTAssertThrowsError(try tool.validate(arguments: ["extra": .bool(true)]))
        XCTAssertNoThrow(try tool.validate(arguments: [:]))

        let output = try decodeObject(try await tool.execute(arguments: [
            "include_unavailable": .bool(false)
        ]))
        guard case let .array(values) = output["capabilities"] else {
            return XCTFail("expected capability array")
        }
        XCTAssertFalse(values.contains { value in
            guard case let .object(object) = value,
                  case let .string(status) = object["status"] else { return false }
            return status == "entitlement_required"
        })
    }

    func testSystemManagedLocalNetworkDoesNotAppearUnintegrated() {
        let inventory = DeviceCapabilityInventoryBuilder.build(permissionSnapshots: [
            DevicePermissionSnapshot(capability: .localNetwork, status: .systemManaged)
        ])

        XCTAssertEqual(
            inventory.records.first(where: { $0.id == "local_network" })?.status,
            "system_managed"
        )
    }

    private func decodeObject(_ text: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TestFailure.notJSONObject
        }
        return object
    }
}

private enum TestFailure: Error {
    case notJSONObject
}

private actor InventoryProviderFake: DeviceCapabilityInventoryProviding {
    private let snapshots: [DevicePermissionSnapshot]
    private(set) var readCount = 0

    init(snapshots: [DevicePermissionSnapshot]) {
        self.snapshots = snapshots
    }

    func inventory() async -> DeviceCapabilityInventory {
        readCount += 1
        return DeviceCapabilityInventoryBuilder.build(permissionSnapshots: snapshots)
    }
}
