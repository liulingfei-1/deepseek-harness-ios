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
            XCTAssertEqual(request.limit, 8)
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
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("list"),
            "compiler_guidance": .string("not valid for list")
        ]))
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
            XCTAssertEqual(request.limit, 12)
            return "ok"
        }

        let result = try await tool.execute(arguments: [
            "action": .string("catalog"),
            "query": .string("memory"),
            "offset": .number(40),
            "limit": .number(12)
        ])

        XCTAssertEqual(result, "ok")
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("catalog"),
            "limit": .number(13)
        ]))
    }

    func testPreparedSourceLifecycleActionsRequireTheirTokensAndPayloads() throws {
        let tool = PluginMarketplaceTool()

        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("read_source"),
            "prepared_token": .string("token")
        ]))
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("install_native"),
            "prepared_token": .string("token")
        ]))
        XCTAssertThrowsError(try tool.validate(arguments: [
            "action": .string("install_ish")
        ]))
    }

    func testPreparedSourceLifecycleActionsAcceptExpectedPayloads() throws {
        let tool = PluginMarketplaceTool()
        XCTAssertNoThrow(try tool.validate(arguments: [
            "action": .string("read_source"),
            "prepared_token": .string("token"),
            "source_path": .string("src/index.js")
        ]))
        XCTAssertNoThrow(try tool.validate(arguments: [
            "action": .string("install_native"),
            "prepared_token": .string("token"),
            "native_manifest": .object([
                "adaptable": .bool(false),
                "name": .string("example"),
                "prompt_sections": .array([]),
                "tools": .array([]),
                "compatibility_notes": .array([])
            ])
        ]))
        XCTAssertNoThrow(try tool.validate(arguments: [
            "action": .string("install_ish"),
            "prepared_token": .string("token")
        ]))
    }
}
