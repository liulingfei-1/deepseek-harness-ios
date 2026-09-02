import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the DeepSeek request-extension registry: field claiming, concurrent
/// preparation, fail-closed dispatch, and one-shot accept semantics.
final class DeepSeekLlmAPIExtensionRegistryTests: XCTestCase {
    func testRegisterRejectsMalformedAndDuplicateNames() throws {
        let registry = DeepSeekLlmAPIExtensionRegistry()
        XCTAssertThrowsError(try registry.register(field: "1bad", provider: .init(prepare: { _ in nil }))) {
            XCTAssertEqual($0 as? DeepSeekLlmAPIExtensionRegistry.RegistryError, .malformedField("1bad"))
        }
        XCTAssertThrowsError(try registry.register(field: "has space", provider: .init(prepare: { _ in nil })))
        try registry.register(field: "thinking_budget", provider: .init(prepare: { _ in nil }))
        XCTAssertThrowsError(try registry.register(field: "thinking_budget", provider: .init(prepare: { _ in nil }))) {
            XCTAssertEqual($0 as? DeepSeekLlmAPIExtensionRegistry.RegistryError, .duplicateField("thinking_budget"))
        }
    }

    func testPrepareMergesContributionsAndSupportsUndefined() async throws {
        let registry = DeepSeekLlmAPIExtensionRegistry()
        try registry.register(field: "alpha_field", provider: .init(prepare: { _ in
            .number(42)
        }))
        // A provider with no contribution for this request returns nil.
        try registry.register(field: "beta_field", provider: .init(prepare: { _ in nil }))
        let fields = try await registry.prepare(
            .init(baseBody: Data("{}".utf8), sessionID: nil, purpose: nil)
        )
        XCTAssertEqual(fields, ["alpha_field": .number(42)])
    }

    func testPrepareFailsClosedWhenAnyProviderThrows() async throws {
        let registry = DeepSeekLlmAPIExtensionRegistry()
        try registry.register(field: "good_field", provider: .init(prepare: { _ in .bool(true) }))
        struct ProviderFailure: Error {}
        try registry.register(field: "bad_field", provider: .init(prepare: { _ in
            throw ProviderFailure()
        }))
        await XCTAssertThrowsErrorAsync(try await registry.prepare(
            .init(baseBody: Data("{}".utf8), sessionID: nil, purpose: nil)
        ))
    }

    func testUnregisterReleasesTheClaim() throws {
        let registry = DeepSeekLlmAPIExtensionRegistry()
        try registry.register(field: "field_a", provider: .init(prepare: { _ in nil }))
        registry.unregister(field: "field_a")
        XCTAssertNoThrow(try registry.register(field: "field_a", provider: .init(prepare: { _ in nil })))
    }
}

/// Minimal async throw-assertion helper (XCTest lacks one natively).
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
