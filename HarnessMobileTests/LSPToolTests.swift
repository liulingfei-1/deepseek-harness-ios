import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class LSPToolTests: XCTestCase {
    func testProviderSelectionMatchesUpstreamFinalExtensionSemantics() {
        XCTAssertEqual(LSPOnDeviceProviderCatalog.finalExtension("Foo.D.TS"), ".ts")
        XCTAssertEqual(LSPOnDeviceProviderCatalog.finalExtension(".bashrc"), "")
        XCTAssertEqual(LSPOnDeviceProviderCatalog.provider(for: "src/main.py")?.command, "pyright-langserver")
        XCTAssertEqual(LSPOnDeviceProviderCatalog.provider(for: "src/App.TSX")?.languageID, "typescriptreact")
        XCTAssertEqual(LSPOnDeviceProviderCatalog.provider(for: "Sources/App.swift")?.command, "sourcekit-lsp")
        XCTAssertNil(LSPOnDeviceProviderCatalog.provider(for: "README.md"))
    }

    func testToolSchemaUsesFourReadOnlySemanticOperationsAndOneBasedCoordinates() throws {
        let tool = OnDeviceLSPTool(store: WorkspaceStore(), sessionID: "test")
        let properties = try XCTUnwrap(tool.definition.parameters.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(
            properties["operation"]?.objectValue?["enum"],
            .array(LSPToolOperation.allCases.map { .string($0.rawValue) })
        )
        XCTAssertEqual(properties["line"]?.objectValue?["minimum"], .number(1))
        XCTAssertEqual(properties["character"]?.objectValue?["minimum"], .number(1))

        XCTAssertNoThrow(try tool.validate(arguments: [
            "operation": .string("findReferences"),
            "file_path": .string("/workspace/src/a.ts"),
            "line": .number(1),
            "character": .number(1)
        ]))
        XCTAssertThrowsError(try tool.validate(arguments: [
            "operation": .string("symbols"),
            "file_path": .string("src/a.ts"),
            "line": .number(0),
            "character": .number(1)
        ]))
        XCTAssertThrowsError(try tool.validate(arguments: [
            "operation": .string("hover"),
            "file_path": .string("source/../../outside.py"),
            "line": .number(1),
            "character": .number(1)
        ]))
    }

    func testLocationAndLocationLinkNormalizationIsBounded() throws {
        var locations: [JSONValue] = [
            .object([
                "targetUri": .string("file:///workspace/src/definition.ts"),
                "targetSelectionRange": range(line: 4, character: 2)
            ])
        ]
        for index in 0..<104 {
            locations.append(.object([
                "uri": .string("file:///workspace/src/r\(index).ts"),
                "range": range(line: index, character: 0)
            ]))
        }
        let output = try OnDeviceLSPTool.normalizeHostOutput(
            envelope(.array(locations)),
            operation: .findReferences,
            workspaceURI: "file:///workspace"
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        let object = try XCTUnwrap(value.objectValue)
        let normalized = try XCTUnwrap(object["locations"]?.arrayValue)
        XCTAssertLessThanOrEqual(normalized.count, 100)
        guard case let .number(omitted)? = object["omitted"] else {
            return XCTFail("expected bounded omission count")
        }
        XCTAssertEqual(normalized.count + Int(omitted), 105)
        XCTAssertLessThanOrEqual(output.count, OnDeviceLSPTool.maximumResultCharacters)
        XCTAssertEqual(
            normalized.first?.objectValue?["uri"],
            .string("file:///workspace/src/definition.ts")
        )
    }

    func testHoverMarkedStringsNormalizeToStableMarkdown() throws {
        let hover = JSONValue.object([
            "contents": .array([
                .object(["language": .string("swift"), "value": .string("let value: Int")]),
                .string("documentation")
            ]),
            "range": range(line: 1, character: 3)
        ])
        let output = try OnDeviceLSPTool.normalizeHostOutput(
            envelope(hover),
            operation: .hover,
            workspaceURI: "file:///workspace"
        )
        XCTAssertTrue(output.contains("```swift"))
        XCTAssertTrue(output.contains("documentation"))
        XCTAssertTrue(output.contains("\"kind\" : \"hover\""))
    }

    func testMalformedProviderPayloadFailsWithStableError() {
        XCTAssertThrowsError(try OnDeviceLSPTool.normalizeHostOutput(
            envelope(.array([.object(["uri": .string("file:///bad")])])),
            operation: .goToDefinition,
            workspaceURI: "file:///workspace"
        )) { error in
            XCTAssertTrue((error as? LSPToolError)?.localizedDescription.contains("LSP_MALFORMED_RESPONSE") == true)
        }
    }

    private func envelope(_ result: JSONValue) -> String {
        JSONValue.object(["ok": .bool(true), "result": result]).displayText
    }

    private func range(line: Int, character: Int) -> JSONValue {
        .object([
            "start": .object(["line": .number(Double(line)), "character": .number(Double(character))]),
            "end": .object(["line": .number(Double(line)), "character": .number(Double(character + 1))])
        ])
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }
}
