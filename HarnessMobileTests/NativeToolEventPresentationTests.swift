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

    func testWorkflowBuildsDedicatedPhaseAndChildProjection() {
        let arguments = #"{"meta":{"name":"并行研究","description":"汇总资料","phases":[{"title":"搜索","detail":"抓取来源"},{"title":"汇总"}]}}"#
        let output = [
            AgentToolOutputChunk(channel: .progress, text: "Workflow phase: 搜索\n"),
            AgentToolOutputChunk(channel: .progress, text: "Workflow child 1 started: 来源 A\n"),
            AgentToolOutputChunk(channel: .progress, text: "Workflow child 1 completed: 来源 A [duration_ms=1250]\n"),
            AgentToolOutputChunk(channel: .progress, text: "Workflow child 2 started: 来源 B\n")
        ]
        let presentation = NativeToolEventPresentation.derive(
            name: "workflow",
            arguments: arguments,
            result: #"{"runId":"r1","agentsStarted":2,"result":{"ok":true}}"#,
            output: output,
            status: .running
        )

        guard case let .workflow(workflow) = presentation else {
            return XCTFail("Expected a workflow presentation")
        }
        XCTAssertEqual(workflow.name, "并行研究")
        XCTAssertEqual(workflow.phases.count, 2)
        XCTAssertTrue(workflow.phases[0].isCurrent)
        XCTAssertFalse(workflow.phases[1].isCompleted)
        XCTAssertEqual(workflow.members.map(\.sequence), [1, 2])
        XCTAssertEqual(workflow.members[0].status, .completed)
        XCTAssertEqual(workflow.members[0].durationMilliseconds, 1_250)
        XCTAssertEqual(workflow.members[1].status, .running)
        XCTAssertEqual(workflow.resultSummary, #"{"ok":true}"#)
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

    func testWorkspaceSearchBuildsBoundedNativeMatches() {
        let result = #"{"query":"needle","root":"/workspace/Sources","matches":[{"path":"/workspace/Sources/App.swift","line":12,"excerpt":"let needle = true"}],"truncated":false,"files_visited":17}"#
        let presentation = NativeToolEventPresentation.derive(
            name: "workspace_search",
            arguments: #"{"query":"needle","path":"/workspace/Sources"}"#,
            result: result
        )

        guard case let .search(search) = presentation else {
            return XCTFail("Expected a search presentation")
        }
        XCTAssertEqual(search.kind, .workspace)
        XCTAssertEqual(search.query, "needle")
        XCTAssertEqual(search.root, "/workspace/Sources")
        XCTAssertEqual(search.filesVisited, 17)
        XCTAssertEqual(search.matches.first?.line, 12)
        XCTAssertEqual(search.matches.first?.excerpt, "let needle = true")
        XCTAssertFalse(search.truncated)
    }

    func testGlobAndGrepTextContractsBecomeSearchCards() {
        let glob = NativeToolEventPresentation.derive(
            name: "glob",
            arguments: #"{"pattern":"**/*.swift","path":"/workspace"}"#,
            result: "/workspace/A.swift\n/workspace/B.swift\n\n(Showing 2 of 9 paths. Full sorted result stored at: /workspace/.harness-mobile/tool-results/glob.txt (200 bytes). Use read with this path to inspect it.)"
        )
        guard case let .search(globSearch) = glob else {
            return XCTFail("Expected a glob search presentation")
        }
        XCTAssertEqual(globSearch.kind, .glob)
        XCTAssertEqual(globSearch.matches.map(\.path), ["/workspace/A.swift", "/workspace/B.swift"])
        XCTAssertEqual(globSearch.totalCount, 9)
        XCTAssertEqual(globSearch.spillLocator, "/workspace/.harness-mobile/tool-results/glob.txt")
        XCTAssertTrue(globSearch.truncated)

        let grep = NativeToolEventPresentation.derive(
            name: "grep",
            arguments: #"{"pattern":"needle"}"#,
            result: "Found 2 matches\n\n/workspace/A.swift\nLine 2: needle one\n\n/workspace/B.swift\nLine 8: needle two"
        )
        guard case let .search(grepSearch) = grep else {
            return XCTFail("Expected a grep search presentation")
        }
        XCTAssertEqual(grepSearch.kind, .grep)
        XCTAssertEqual(grepSearch.totalCount, 2)
        XCTAssertEqual(grepSearch.matches.map(\.line), [2, 8])
        XCTAssertEqual(grepSearch.matches.map(\.excerpt), ["needle one", "needle two"])
    }

    func testWebSearchBuildsRankedSourcesAndRejectsMalformedRows() {
        let result = #"{"queries":["swift ios"],"sources":[{"query":"swift ios","provider":"duckduckgo","title":"Swift","url":"https://swift.org/","snippet":"Language docs"}],"source_count":1,"truncated":false,"query_count":1,"note":"bounded"}"#
        let presentation = NativeToolEventPresentation.derive(
            name: "web_search",
            arguments: #"{"queries":["swift ios"]}"#,
            result: result
        )
        guard case let .web(web) = presentation else {
            return XCTFail("Expected a web presentation")
        }
        XCTAssertEqual(web.kind, .search)
        XCTAssertEqual(web.queries, ["swift ios"])
        XCTAssertEqual(web.sources.first?.rank, 1)
        XCTAssertEqual(web.sources.first?.url, "https://swift.org/")
        XCTAssertFalse(web.truncated)

        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "web_search",
                arguments: #"{"queries":["x"]}"#,
                result: #"{"queries":["x"],"sources":[{"title":42}],"source_count":1,"truncated":false}"#
            ),
            .generic
        )
    }

    func testWebFetchCapsMultibytePreviewWithoutBreakingUnicode() {
        let content = String(repeating: "你", count: 20_000)
        let value = JSONValue.object([
            "url": .string("https://example.com/final"),
            "statusCode": .number(200),
            "body": .object(["kind": .string("html"), "content": .string(content)]),
            "truncated": .bool(false)
        ]).displayText
        let presentation = NativeToolEventPresentation.derive(
            name: "web_fetch",
            arguments: #"{"url":"https://example.com"}"#,
            result: value
        )
        guard case let .web(web) = presentation else {
            return XCTFail("Expected a web fetch presentation")
        }
        XCTAssertEqual(web.kind, .fetch)
        XCTAssertEqual(web.url, "https://example.com")
        XCTAssertEqual(web.statusCode, 200)
        XCTAssertLessThanOrEqual(web.contentPreview?.utf8.count ?? .max, 32 * 1_024)
        XCTAssertTrue(web.truncated)
        XCTAssertNotNil(web.contentPreview?.data(using: .utf8))
    }

    func testJobOutputExtractsStatusAndBoundsOutput() {
        let result = "first\nsecond\n[status: running, waiting for child]"
        let presentation = NativeToolEventPresentation.derive(
            name: "job_output",
            arguments: #"{"job_id":"job-42"}"#,
            result: result
        )
        guard case let .job(job) = presentation else {
            return XCTFail("Expected a job presentation")
        }
        XCTAssertEqual(job.kind, .output)
        XCTAssertEqual(job.jobID, "job-42")
        XCTAssertEqual(job.status, "running")
        XCTAssertEqual(job.detail, "waiting for child")
        XCTAssertEqual(job.outputPreview, "first\nsecond")
        XCTAssertEqual(job.totalLines, 2)
    }

    func testJobListAndKillBuildCompactCards() {
        let list = NativeToolEventPresentation.derive(
            name: "job_list",
            arguments: "{}",
            result: "job-1 [shell] running - build app\njob-2 [subagent] completed - inspect docs"
        )
        guard case let .job(jobList) = list else {
            return XCTFail("Expected a job list presentation")
        }
        XCTAssertEqual(jobList.kind, .list)
        XCTAssertEqual(jobList.entries.map(\.id), ["job-1", "job-2"])
        XCTAssertEqual(jobList.entries.map(\.status), ["running", "completed"])

        let kill = NativeToolEventPresentation.derive(
            name: "job_kill",
            arguments: #"{"job_id":"job-1"}"#,
            result: "job job-1 had already finished [status: completed]"
        )
        guard case let .job(jobKill) = kill else {
            return XCTFail("Expected a job kill presentation")
        }
        XCTAssertEqual(jobKill.kind, .kill)
        XCTAssertEqual(jobKill.jobID, "job-1")
        XCTAssertEqual(jobKill.status, "completed")
    }

    func testMalformedSearchAndJobResultsFallBackWithoutCrashing() {
        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "workspace_search",
                arguments: #"{"query":"x"}"#,
                result: #"{"query":"x","root":"/workspace","matches":[{"path":"a","line":0,"excerpt":"x"}],"truncated":false,"files_visited":1}"#
            ),
            .generic
        )
        XCTAssertEqual(
            NativeToolEventPresentation.derive(
                name: "job_output",
                arguments: #"{"job_id":"job-1"}"#,
                result: "unframed output"
            ),
            .generic
        )
    }
}
