import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ToolResultOutputPolicyTests: XCTestCase {
    func testShortResultPassesThroughWithoutWritingAFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let policy = ToolResultOutputPolicy(fileSystem: fileSystem)
        let original = CordisToolExecutionResult(
            text: "short result",
            isError: false,
            value: .object(["ok": .bool(true)])
        )

        let projected = try await policy.project(
            original,
            toolName: "example",
            callID: "call-short"
        )

        XCTAssertEqual(projected, original)
        let directory = try await fileSystem.resolve(
            "/workspace/.harness-mobile/tool-results",
            cwd: "/workspace"
        )
        let directoryInfo = try await fileSystem.stat(directory)
        XCTAssertNil(directoryInfo)
    }

    func testLongSuccessIsBoundedAndCompleteUnicodeContentIsReadable() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let policy = ToolResultOutputPolicy(
            fileSystem: fileSystem,
            configuration: ToolResultOutputConfiguration(
                maximumInlineBytes: 1_024,
                maximumSpillBytes: 64 * 1_024
            )
        )
        let full = String(repeating: "完整结果🙂\n", count: 700)
        let value = JSONValue.object(["kind": .string("canonical")])

        let projected = try await policy.project(
            CordisToolExecutionResult(text: full, isError: false, value: value),
            toolName: "plugin/tool:name",
            callID: "call/with unsafe chars"
        )

        XCTAssertFalse(projected.isError)
        XCTAssertEqual(projected.value, value)
        XCTAssertLessThanOrEqual(projected.text.utf8.count, 1_024)
        XCTAssertTrue(projected.text.contains("Use read with this path"))
        XCTAssertTrue(projected.text.contains("call_id=callwithunsafechars"))
        let locator = try XCTUnwrap(locator(in: projected.text))
        XCTAssertTrue(locator.hasPrefix("/workspace/.harness-mobile/tool-results/"))
        XCTAssertTrue(locator.hasSuffix("-plugintoolname-result.txt"))
        let target = try await fileSystem.resolve(locator, cwd: "/workspace")
        let stored = try await fileSystem.readText(target)
        XCTAssertEqual(stored, full)
    }

    func testLongErrorKeepsErrorAndCanonicalValueWhileSpillingCompleteText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let policy = ToolResultOutputPolicy(
            fileSystem: fileSystem,
            configuration: ToolResultOutputConfiguration(
                maximumInlineBytes: 1_024,
                maximumSpillBytes: 16 * 1_024
            )
        )
        let full = "PROVIDER_ERROR: " + String(repeating: "failure detail ", count: 500)
        let value = JSONValue.object(["code": .string("PROVIDER_ERROR")])

        let projected = try await policy.project(
            CordisToolExecutionResult(text: full, isError: true, value: value),
            toolName: "remote-compatible-local-tool",
            callID: "error-call"
        )

        XCTAssertTrue(projected.isError)
        XCTAssertEqual(projected.value, value)
        XCTAssertLessThanOrEqual(projected.text.utf8.count, 1_024)
        XCTAssertTrue(projected.text.hasPrefix("PROVIDER_ERROR"))
        XCTAssertTrue(projected.text.contains("Full tool error stored at:"))
        let locator = try XCTUnwrap(locator(in: projected.text))
        let target = try await fileSystem.resolve(locator, cwd: "/workspace")
        let stored = try await fileSystem.readText(target)
        XCTAssertEqual(stored, full)
    }

    func testCancellationPropagatesBeforeAnySpillWrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let policy = ToolResultOutputPolicy(
            fileSystem: fileSystem,
            configuration: ToolResultOutputConfiguration(
                maximumInlineBytes: 1_024,
                maximumSpillBytes: 8 * 1_024
            )
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await policy.project(
                CordisToolExecutionResult(
                    text: String(repeating: "cancel me", count: 400),
                    isError: false
                ),
                toolName: "cancel",
                callID: "cancel-call"
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancellation must escape the output policy")
        } catch is CancellationError {
            // Expected: the caller retains canonical interrupted semantics.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let directory = try await fileSystem.resolve(
            "/workspace/.harness-mobile/tool-results",
            cwd: "/workspace"
        )
        let directoryInfo = try await fileSystem.stat(directory)
        XCTAssertNil(directoryInfo)
    }

    func testSpillLimitFailureRetainsOriginalErrorPreview() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let policy = ToolResultOutputPolicy(
            fileSystem: fileSystem,
            configuration: ToolResultOutputConfiguration(
                maximumInlineBytes: 1_024,
                maximumSpillBytes: 2_048
            )
        )
        let full = "ORIGINAL_ERROR: " + String(repeating: "x", count: 4_000)

        do {
            _ = try await policy.project(
                CordisToolExecutionResult(text: full, isError: true),
                toolName: "oversize",
                callID: "oversize-call"
            )
            XCTFail("An unsavable result must not be silently truncated")
        } catch let error as ToolResultOutputPolicyError {
            XCTAssertTrue(error.originalWasError)
            XCTAssertTrue(error.originalPreview.hasPrefix("ORIGINAL_ERROR"))
            XCTAssertTrue(error.localizedDescription.contains("无法保存完整内容"))
        } catch {
            XCTFail("Expected ToolResultOutputPolicyError, got \(error)")
        }
    }

    private func locator(in output: String) -> String? {
        let marker = "stored at: "
        guard let range = output.range(of: marker) else { return nil }
        return output[range.upperBound...]
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolResultOutputPolicyTests-\(UUID().uuidString)", isDirectory: true)
    }
}
