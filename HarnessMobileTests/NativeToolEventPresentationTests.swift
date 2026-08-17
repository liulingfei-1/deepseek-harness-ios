import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class NativeToolEventPresentationTests: XCTestCase {
    func testWorkspaceReadBuildsLineNumberedBoundedCard() {
        let presentation = NativeToolEventPresentation.derive(
            name: "workspace_read_text",
            arguments: #"{"path":"Sources/App.swift"}"#,
            result: "let a = 1\nlet b = 2\n"
        )

        guard case let .workspaceRead(read) = presentation else {
            return XCTFail("Expected a workspace read presentation")
        }
        XCTAssertEqual(read.path, "Sources/App.swift")
        XCTAssertEqual(read.languageHint, "swift")
        XCTAssertEqual(read.totalLines, 2)
        XCTAssertEqual(read.lines.map(\.number), [1, 2])
        XCTAssertEqual(read.lines.map(\.text), ["let a = 1", "let b = 2"])
        XCTAssertFalse(read.previewTruncated)
    }

    func testWorkspaceReadFallsBackForMalformedArguments() {
        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "workspace_read_text",
                arguments: #"{"path":42}"#,
                result: "text"
            ),
            .generic
        )
    }

    func testWorkspaceWriteShowsIntendedFullFileContentWithoutInventingOldText() {
        let presentation = NativeToolEventPresentation.derive(
            name: "workspace_write_text",
            arguments: #"{"path":"notes/demo.md","text":"first\nsecond\n"}"#,
            result: #"{"path":"notes/demo.md","status":"written"}"#
        )

        guard case let .workspaceWrite(write) = presentation else {
            return XCTFail("Expected a workspace write presentation")
        }
        XCTAssertEqual(write.path, "notes/demo.md")
        XCTAssertEqual(write.languageHint, "md")
        XCTAssertEqual(write.byteCount, 13)
        XCTAssertEqual(write.totalLines, 2)
        XCTAssertEqual(write.lines.map(\.text), ["first", "second"])
    }

    func testWorkspaceFilesRequiresUniqueWellFormedPaths() {
        let valid = NativeToolEventPresentation.derive(
            name: "workspace_list_files",
            arguments: "{}",
            result: #"[{"modifiedAt":12,"path":"a.swift","size":42},{"path":"Docs/readme.md","size":1000}]"#
        )
        guard case let .workspaceFiles(files) = valid else {
            return XCTFail("Expected a workspace files presentation")
        }
        XCTAssertEqual(files.files.map(\.path), ["a.swift", "Docs/readme.md"])
        XCTAssertEqual(files.files.map(\.size), [42, 1_000])

        let duplicate = NativeToolEventPresentation.derive(
            name: "workspace_list_files",
            arguments: "{}",
            result: #"[{"path":"a.swift","size":1},{"path":"a.swift","size":2}]"#
        )
        XCTAssertEqual(duplicate, .generic)

        let malformed = NativeToolEventPresentation.derive(
            name: "workspace_list_files",
            arguments: "{}",
            result: #"[{"path":"a.swift","size":"large"}]"#
        )
        XCTAssertEqual(malformed, .generic)
    }

    func testTodoPresentationUsesSettledStateAndSummarizesParallelActiveItems() {
        let result = #"""
        {
          "goal": null,
          "plan": [],
          "todos": [
            {"id":"11111111-1111-1111-1111-111111111111","title":"完成项","status":"completed"},
            {"id":"22222222-2222-2222-2222-222222222222","title":"当前项","status":"active"},
            {"id":"33333333-3333-3333-3333-333333333333","title":"并行项","status":"active"}
          ]
        }
        """#
        let presentation = NativeToolEventPresentation.derive(
            name: "work_state_replace_todos",
            arguments: #"{"items":[{"title":"旧值","status":"pending"}]}"#,
            result: result,
            status: .succeeded
        )

        guard case let .workItems(items) = presentation else {
            return XCTFail("Expected a work-items presentation")
        }
        XCTAssertEqual(items.kind, .todos)
        XCTAssertEqual(items.completedCount, 1)
        XCTAssertEqual(items.activeItems.map(\.title), ["当前项", "并行项"])
        XCTAssertEqual(items.items.count, 3)
    }

    func testTodoPresentationRejectsMalformedItems() {
        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "work_state_replace_todos",
                arguments: #"{"items":[{"title":"x","status":"invented"}]}"#,
                result: nil,
                status: .running
            ),
            .generic
        )
    }

    func testPlanUsesTheSameNativeWorkItemProjection() {
        let presentation = NativeToolEventPresentation.derive(
            name: "work_state_replace_plan",
            arguments: #"{"steps":[{"title":"读取","status":"completed"},{"title":"实现","status":"active"}]}"#,
            result: nil,
            status: .running
        )

        guard case let .workItems(items) = presentation else {
            return XCTFail("Expected a work-items presentation")
        }
        XCTAssertEqual(items.kind, .plan)
        XCTAssertEqual(items.completedCount, 1)
        XCTAssertEqual(items.activeItems.first?.title, "实现")
    }

    func testTerminalPrefersStreamedOrderingAndCarriesExitMetadata() {
        let output = [
            AgentToolOutputChunk(channel: .stdout, text: "first"),
            AgentToolOutputChunk(channel: .stderr, text: " warning\nsecond\n")
        ]
        let presentation = NativeToolEventPresentation.derive(
            name: "shell_execute",
            arguments: #"{"command":"printf test","timeout_seconds":30}"#,
            result: #"{"duration_ms":125,"exit_code":2,"pid":41,"stderr":"duplicate stderr","stdout":"duplicate stdout"}"#,
            output: output,
            status: .succeeded
        )

        guard case let .terminal(terminal) = presentation else {
            return XCTFail("Expected a terminal presentation")
        }
        XCTAssertEqual(terminal.firstCommandLine, "printf test")
        XCTAssertEqual(terminal.timeoutSeconds, 30)
        XCTAssertEqual(terminal.exitCode, 2)
        XCTAssertEqual(terminal.processID, 41)
        XCTAssertEqual(terminal.durationMilliseconds, 125)
        XCTAssertTrue(terminal.failedExit)
        XCTAssertEqual(terminal.totalOutputLines, 2)
        XCTAssertEqual(terminal.outputLines[0].segments.map(\.channel), [.stdout, .stderr])
        XCTAssertEqual(terminal.outputLines[0].segments.map(\.text), ["first", " warning"])
        XCTAssertEqual(terminal.outputLines[1].segments.map(\.text), ["second"])
    }

    func testTerminalFallsBackToSettledStreamsWhenNoLiveChunksExist() {
        let presentation = NativeToolEventPresentation.derive(
            name: "shell_execute",
            arguments: #"{"command":"echo hi"}"#,
            result: #"{"duration_ms":5,"exit_code":0,"pid":7,"stderr":"warn\n","stdout":"hi\n"}"#,
            status: .succeeded
        )

        guard case let .terminal(terminal) = presentation else {
            return XCTFail("Expected a terminal presentation")
        }
        XCTAssertEqual(terminal.totalOutputLines, 2)
        XCTAssertEqual(terminal.outputLines[0].segments.first?.channel, .stdout)
        XCTAssertEqual(terminal.outputLines[0].segments.first?.text, "hi")
        XCTAssertEqual(terminal.outputLines[1].segments.first?.channel, .stderr)
        XCTAssertEqual(terminal.outputLines[1].segments.first?.text, "warn")
        XCTAssertFalse(terminal.failedExit)
    }

    func testIOSNativeUsesTerminalCardWithoutAllowingArbitraryCommandNames() {
        let presentation = NativeToolEventPresentation.derive(
            name: "ios_native",
            arguments: #"{"command":"apple-calendar","arguments":["list","--today"],"timeout_seconds":45}"#,
            result: #"{"command":"apple-calendar","duration_ms":18,"exit_code":0,"stderr":"","stdout":"{\"events\":[]}"}"#,
            status: .succeeded
        )

        guard case let .terminal(terminal) = presentation else {
            return XCTFail("Expected an iOS native terminal presentation")
        }
        XCTAssertEqual(terminal.firstCommandLine, "apple-calendar list --today")
        XCTAssertEqual(terminal.timeoutSeconds, 45)
        XCTAssertEqual(terminal.exitCode, 0)
        XCTAssertNil(terminal.processID)
        XCTAssertEqual(terminal.durationMilliseconds, 18)

        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "ios_native",
                arguments: #"{"command":"sh","arguments":["-c","id"]}"#,
                result: nil
            ),
            .generic
        )
    }

    func testLargeReadKeepsBoundedHeadAndTailWithRealLineNumbers() {
        let text = (1...400).map { "line-\($0)" }.joined(separator: "\n")
        let presentation = NativeToolEventPresentation.derive(
            name: "workspace_read_text",
            arguments: #"{"path":"large.txt"}"#,
            result: text
        )

        guard case let .workspaceRead(read) = presentation else {
            return XCTFail("Expected a workspace read presentation")
        }
        XCTAssertEqual(read.totalLines, 400)
        XCTAssertEqual(read.lines.count, 256)
        XCTAssertEqual(read.lines.first?.number, 1)
        XCTAssertEqual(read.lines[127].number, 128)
        XCTAssertEqual(read.lines[128].number, 273)
        XCTAssertEqual(read.lines.last?.number, 400)
        XCTAssertTrue(read.previewTruncated)
    }
}
