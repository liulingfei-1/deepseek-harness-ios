import XCTest
@testable import HarnessMobileCore

final class HarnessLLMSessionRegistryTests: XCTestCase {
    func testInterfaceChangesAreDeduplicatedAndIncrementGeneration() {
        let registry = HarnessLLMSessionRegistry.shared
#if DEBUG
        registry.resetForTesting()
#endif
        let session = URLSession(configuration: .ephemeral)
        let recorder = ReasonRecorder()
        registry.register(session) { reason in
            recorder.append(reason)
        }
        defer {
            registry.unregister(session)
#if DEBUG
            registry.resetForTesting()
#endif
        }

        XCTAssertTrue(registry.observe(interfaceSet: ["wifi"], isSatisfied: true))
        let firstGeneration = registry.currentGeneration
        XCTAssertFalse(registry.observe(interfaceSet: ["wifi"], isSatisfied: true))
        XCTAssertEqual(registry.currentGeneration, firstGeneration)
        XCTAssertTrue(registry.observe(interfaceSet: ["cellular"], isSatisfied: true))
        XCTAssertEqual(registry.currentGeneration, firstGeneration + 1)
        XCTAssertEqual(recorder.values, ["interface-change", "interface-change"])
    }
}

private final class ReasonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
