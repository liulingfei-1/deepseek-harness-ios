import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class PluginMarketplaceToolTests: XCTestCase {
    func testInstallRequestAcceptsRepositorySource() async throws {
        let expectation = expectation(description: "executor")
        let tool = PluginMarketplaceTool { request in
            XCTAssertEqual(request.action, .install)
            XCTAssertEqual(request.sourceKind, .github)
            XCTAssertEqual(request.location, "https://github.com/example/plugin")
            XCTAssertTrue(request.replace)
            XCTAssertNil(request.query)
            XCTAssertEqual(request.offset, 0)
            XCTAssertEqual(request.limit, 20)
            expectation.fulfill()
            return "ok"
        }

        let arguments: [String: JSONValue] = [
            "action": .string("install"),
            "source_kind": .string("github"),
            "location": .string("https://github.com/example/plugin"),
            "replace": .bool(true)
        ]
        XCTAssertNoThrow(try tool.validate(arguments: arguments))
        let result = try await tool.execute(arguments: arguments)
        XCTAssertEqual(result, "ok")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testLifecycleActionsRequirePluginID() throws {
        let tool = PluginMarketplaceTool()
        for action in ["enable", "disable", "uninstall"] {
            XCTAssertThrowsError(try tool.validate(arguments: [
                "action": .string(action)
            ]))
        }
    }

    func testUnsupportedLocalZipSourceIsRejected() throws {
        let tool = PluginMarketplaceTool()
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("install"),
            "source_kind": .string("local_zip")
        ]))
    }

    func testCatalogRequestAcceptsBoundedPaginationAndSearch() async throws {
        let tool = PluginMarketplaceTool { request in
            XCTAssertEqual(request.action, .catalog)
            XCTAssertEqual(request.query, "memory")
            XCTAssertEqual(request.offset, 40)
            XCTAssertEqual(request.limit, 25)
            return "ok"
        }

        let result = try await tool.execute(arguments: [
            "action": .string("catalog"),
            "query": .string("memory"),
            "offset": .number(40),
            "limit": .number(25)
        ])

        XCTAssertEqual(result, "ok")
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("catalog"),
            "limit": .number(26)
        ]))
    }
}
