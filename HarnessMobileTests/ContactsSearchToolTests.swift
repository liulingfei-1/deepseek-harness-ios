import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ContactsSearchToolTests: XCTestCase {
    func testValidationRejectsEmptyOversizedAndMalformedArguments() throws {
        let tool = ContactsSearchTool(provider: ContactSearchProviderFake(records: []))
        let invalid: [[String: JSONValue]] = [
            [:],
            ["query": .string("   ")],
            ["query": .string(String(repeating: "a", count: 129))],
            ["query": .string("Alice\nAdmin")],
            ["query": .number(1)],
            ["query": .string("Alice"), "limit": .number(0)],
            ["query": .string("Alice"), "limit": .number(21)],
            ["query": .string("Alice"), "limit": .number(1.5)],
            ["query": .string("Alice"), "limit": .string("10")],
            ["query": .string("Alice"), "write": .bool(true)],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try tool.validate(arguments: arguments))
        }
        XCTAssertNoThrow(try tool.validate(arguments: ["query": .string("Alice")]))
        XCTAssertNoThrow(try tool.validate(arguments: [
            "query": .string("Alice"),
            "limit": .number(20),
        ]))
    }

    func testExecutionNormalizesQueryAndUsesDefaultLimit() async throws {
        let provider = ContactSearchProviderFake(records: [
            DeviceContactRecord(
                name: "Alice Chen",
                phoneNumbers: ["+86 138 0000 0000"],
                emailAddresses: ["alice@example.com"]
            )
        ])
        let tool = ContactsSearchTool(provider: provider)

        let result = try decodeObject(try await tool.execute(arguments: [
            "query": .string("  Alice  ")
        ]))
        let request = await provider.lastRequest

        XCTAssertEqual(request?.query, "Alice")
        XCTAssertEqual(request?.limit, ContactsSearchTool.defaultLimit)
        XCTAssertEqual(result["query"], .string("Alice"))
        XCTAssertEqual(result["count"], .number(1))
    }

    func testOutputEnforcesRecordAndFieldBoundaries() async throws {
        let longName = String(repeating: "名", count: 200)
        let records = (0..<25).map { index in
            DeviceContactRecord(
                name: "\(longName)\(index)",
                phoneNumbers: [
                    String(repeating: "1", count: 200), "2", "3", "4", "5",
                ],
                emailAddresses: [
                    String(repeating: "a", count: 400),
                    "b@example.com", "c@example.com", "d@example.com",
                ]
            )
        }
        let provider = ContactSearchProviderFake(records: records)
        let tool = ContactsSearchTool(provider: provider)

        let result = try decodeObject(try await tool.execute(arguments: [
            "query": .string("名"),
            "limit": .number(2),
        ]))
        guard case let .array(contacts) = result["contacts"] else {
            return XCTFail("contacts must be an array")
        }

        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(result["count"], .number(2))
        for contact in contacts {
            guard case let .object(object) = contact,
                  let name = object["name"]?.stringValue,
                  case let .array(phones) = object["phoneNumbers"],
                  case let .array(emails) = object["emailAddresses"] else {
                return XCTFail("contact result has an invalid shape")
            }
            XCTAssertLessThanOrEqual(name.utf8.count, 256)
            XCTAssertLessThanOrEqual(phones.count, 3)
            XCTAssertLessThanOrEqual(emails.count, 3)
            XCTAssertTrue(phones.allSatisfy { ($0.stringValue?.utf8.count ?? .max) <= 128 })
            XCTAssertTrue(emails.allSatisfy { ($0.stringValue?.utf8.count ?? .max) <= 320 })
        }
    }

    func testSensitiveReadRiskAndPermanentApprovalScope() throws {
        let tool = ContactsSearchTool(provider: ContactSearchProviderFake(records: []))
        let arguments = ["query": JSONValue.string("Alice")]

        XCTAssertEqual(tool.risk, .sensitiveRead)
        XCTAssertEqual(try tool.approvalResources(arguments: arguments), ["contacts:read"])
    }

    func testTypedPermissionDenialPropagates() async {
        let tool = ContactsSearchTool(
            provider: ContactSearchProviderFake(error: .permissionDenied("联系人"))
        )

        do {
            _ = try await tool.execute(arguments: ["query": .string("Alice")])
            XCTFail("Expected permission denial")
        } catch let error as MobileNativeToolError {
            XCTAssertEqual(error, .permissionDenied("联系人"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func decodeObject(_ text: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ContactToolTestFailure.notJSONObject
        }
        return object
    }
}

private enum ContactToolTestFailure: Error {
    case notJSONObject
}

private actor ContactSearchProviderFake: DeviceContactSearching {
    private let records: [DeviceContactRecord]
    private let error: MobileNativeToolError?
    private(set) var lastRequest: (query: String, limit: Int)?

    init(records: [DeviceContactRecord] = [], error: MobileNativeToolError? = nil) {
        self.records = records
        self.error = error
    }

    func search(query: String, limit: Int) throws -> [DeviceContactRecord] {
        lastRequest = (query, limit)
        if let error { throw error }
        return records
    }
}
