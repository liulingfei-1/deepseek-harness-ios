import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AgentProviderBundleTests: XCTestCase {
    func testCatalogDescribesRC8CodingAgentBundles() {
        XCTAssertEqual(Set(AgentProviderBundle.catalog.map(\.id)), [.codex, .claudeCode])
        XCTAssertTrue(AgentProviderBundle.catalog.allSatisfy(\.supportsNamedInstances))
        XCTAssertEqual(AgentProviderBundle.catalog.first { $0.id == .codex }?.nonInteractiveArguments, ["exec", "--full-auto"])
        XCTAssertTrue(AgentProviderBundle.catalog.allSatisfy { bundle in
            bundle.capabilities == .outOfProcess
        })
        let paths = AgentProviderBundle.catalog.map(\.resolvedExecutablePath)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/") })
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(AgentProviderBundle.catalog.allSatisfy {
            $0.outputAuthority == .mobileCLIStdoutDegraded
        })
    }

    func testOutOfProcessBundleRejectsParentCompositionFeatures() {
        let bundle = try! XCTUnwrap(AgentProviderBundle.catalog.first { $0.id == .codex })
        let request = AgentProviderBundleRequestFeatures(
            usesParentContext: true,
            hasOutputSchema: true,
            hasDepthLimitOverride: true,
            hasToolFilter: true,
            hasPersona: true,
            hasModelOverride: true,
            isContinuation: true
        )

        XCTAssertEqual(
            bundle.unsupportedCapabilities(for: request),
            AgentProviderBundleCapability.allCases
        )
        XCTAssertTrue(
            bundle.capabilityFailureMessage(for: request)?.contains("父会话上下文") == true
        )
    }

    func testDefaultDepthAndFreshPromptAreAcceptedByOutOfProcessBundle() {
        let bundle = try! XCTUnwrap(AgentProviderBundle.catalog.first { $0.id == .claudeCode })
        let request = AgentProviderBundleRequestFeatures(
            usesParentContext: false,
            hasOutputSchema: false,
            hasDepthLimitOverride: false,
            hasToolFilter: false,
            hasPersona: false,
            hasModelOverride: false,
            isContinuation: false
        )

        XCTAssertTrue(bundle.unsupportedCapabilities(for: request).isEmpty)
        XCTAssertNil(bundle.capabilityFailureMessage(for: request))
    }

    func testBundleStorePersistsOnlyEnabledIDsAndLoadsDisabledByDefault() throws {
        let suite = "bundle-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentProviderBundleStore(defaults: defaults)
        XCTAssertTrue(store.load().allSatisfy { !$0.enabled })
        var bundles = store.load()
        bundles[0].enabled = true
        try store.save(bundles)
        XCTAssertTrue(store.load().first { $0.id == .codex }?.enabled == true)
        XCTAssertFalse(store.load().first { $0.id == .claudeCode }?.enabled == true)
    }

    func testInstallPayloadIsFixedAndValidated() throws {
        let bundle = try XCTUnwrap(AgentProviderBundle.catalog.first { $0.id == .codex })
        XCTAssertNoThrow(try bundle.installPayload.validate())
        XCTAssertEqual(
            bundle.installPayload.sourceURL,
            "https://registry.npmjs.org/@openai/codex/-/codex-0.147.0.tgz"
        )
        XCTAssertEqual(
            bundle.installPayload.sha256,
            "d28b4fd4bd9f07ea71083d0cc40c579595cebbd4c10bc8ca98a6d385432e7255"
        )
        XCTAssertEqual(
            bundle.resolvedExecutablePath,
            "/usr/local/lib/harness-mobile/provider-bundles/codex/bin/codex"
        )
        XCTAssertFalse(bundle.resolvedExecutablePath.contains("/usr/bin/env"))
    }

    func testInstallPayloadRejectsPlaceholderChecksum() throws {
        let bundle = try XCTUnwrap(AgentProviderBundle.catalog.first { $0.id == .codex })
        let placeholder = AgentProviderBundleInstallPayload(
            bundleID: bundle.id,
            packageName: bundle.installPayload.packageName,
            version: bundle.installPayload.version,
            executable: bundle.installPayload.executable,
            arguments: bundle.installPayload.arguments,
            sourceURL: bundle.installPayload.sourceURL,
            sha256: String(repeating: "0", count: 64),
            protocolKind: bundle.installPayload.protocolKind
        )
        XCTAssertThrowsError(try placeholder.validate())
    }

    func testCompletionParserUsesFinalAnswerAndSupportsLegacyText() {
        let structured = AgentProviderBundleCompletionParser.parse("{\"type\":\"message\",\"final_answer\":\"done\"}")
        XCTAssertEqual(structured?.text, "done")
        XCTAssertEqual(structured?.structured, true)
        let legacy = AgentProviderBundleCompletionParser.parse("plain answer")
        XCTAssertEqual(legacy?.text, "plain answer")
        XCTAssertEqual(legacy?.structured, false)
    }

    func testFailureFactsAreBoundedAndRedacted() throws {
        let facts = AgentProviderBundleFailureFacts.make(
            bundleID: .codex,
            instanceID: "codex:one",
            phase: "process",
            exitCode: 1,
            errorCode: "provider_exit",
            stdout: "token=secret-value " + String(repeating: "x", count: 2_000),
            stderr: "Authorization: Bearer abc123"
        )
        XCTAssertTrue(facts.credentialRedacted)
        XCTAssertTrue(facts.truncated)
        XCTAssertFalse(facts.serialized.contains("secret-value"))
        XCTAssertFalse(facts.serialized.contains("abc123"))
        XCTAssertFalse(facts.userMessage.contains("abc123"))
        XCTAssertLessThanOrEqual(facts.detail?.utf8.count ?? 0, 512)
        XCTAssertEqual(facts.outputAuthority, .mobileCLIStdoutDegraded)
        XCTAssertEqual(facts.jsonValue.objectValue?["outputAuthority"]?.stringValue, "mobile-cli-stdout-degraded")
    }

    func testNamedInstancesNormalizeAndRemainIndependent() async throws {
        let one = try AgentProviderBundleInstance(bundleID: .codex, name: "  Build-One ")
        let two = try AgentProviderBundleInstance(bundleID: .codex, name: "build-two")
        XCTAssertEqual(one.name, "build-one")
        XCTAssertNotEqual(one.id, two.id)
        let registry = AgentProviderBundleInstanceRegistry()
        try await registry.register(one)
        try await registry.register(two)
        let instances = await registry.snapshot()
        XCTAssertEqual(instances.count, 2)
    }
}
