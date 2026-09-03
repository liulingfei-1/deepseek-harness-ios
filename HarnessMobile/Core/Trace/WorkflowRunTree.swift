import Foundation

/// Mirrors the desktop `ui-workflow-run` conversation-node shape as a data
/// model: each top-level workflow run becomes one foldable group whose member
/// agents are listed in sequence order with their outcome and timing. Built
/// purely from the durable session events (`tool-workflow/*`), so any surface
/// (chat, trajectory) can render the same tree without touching the event
/// log. Runs without a `run-start` marker are not invented.
struct WorkflowRunTree: Sendable, Equatable {
    static let runStartType = "tool-workflow/run-start"
    static let agentStartType = "tool-workflow/agent-start"
    static let agentEndType = "tool-workflow/agent-end"
    static let runEndType = "tool-workflow/run-end"

    struct Member: Sendable, Equatable {
        let sequence: Int
        let label: String
        let phase: String?
        let childID: String
        let parentID: String?
        let depth: Int
        var outcome: String?
        var durationMilliseconds: Int64?
        var error: String?

        var isSucceeded: Bool { outcome == "success" }
        var isFailed: Bool { outcome == "error" || error != nil }
    }

    struct Run: Sendable, Equatable {
        let runID: String
        let name: String
        let startedAtMilliseconds: Int64
        var stopReason: String?
        var members: [Member] = []

        var memberCount: Int { members.count }
        var completedCount: Int { members.filter { $0.outcome != nil }.count }
        var failedCount: Int { members.filter(\.isFailed).count }
    }

    private(set) var runs: [Run]

    var runCount: Int { runs.count }
    var memberCount: Int { runs.reduce(0) { $0 + $1.members.count } }
    var failedMemberCount: Int { runs.reduce(0) { $0 + $1.failedCount } }

    init(runs: [Run] = []) {
        self.runs = runs
    }

    /// Builds the tree from the durable event window. Unknown payloads are
    /// skipped rather than throwing, so a partially understood log still
    /// yields every well-formed run.
    static func build(from events: [SessionEvent]) -> WorkflowRunTree {
        var runs: [String: Run] = [:]
        var order: [String] = []

        for event in events {
            let data = event.data.objectValue ?? [:]
            switch event.type {
            case runStartType:
                guard let runID = data["runId"]?.stringValue ?? data["run_id"]?.stringValue else {
                    continue
                }
                if runs[runID] == nil {
                    order.append(runID)
                }
                runs[runID] = Run(
                    runID: runID,
                    name: data["name"]?.stringValue ?? "工作流",
                    startedAtMilliseconds: event.time
                )

            case agentStartType:
                guard let runID = runIdentifier(data),
                      var run = runs[runID] else { continue }
                run.members.append(
                    Member(
                        sequence: integerValue(data["sequence"]) ?? run.members.count,
                        label: data["label"]?.stringValue
                            ?? data["childId"]?.stringValue ?? "成员",
                        phase: data["phase"]?.stringValue,
                        childID: data["childId"]?.stringValue ?? data["childID"]?.stringValue ?? "",
                        parentID: data["parentId"]?.stringValue ?? data["parentID"]?.stringValue,
                        depth: integerValue(data["depth"]) ?? 0
                    )
                )
                runs[runID] = run

            case agentEndType:
                guard let runID = runIdentifier(data),
                      var run = runs[runID],
                      let sequence = integerValue(data["sequence"]) else { continue }
                if let index = run.members.firstIndex(where: { $0.sequence == sequence }) {
                    run.members[index].outcome = data["outcome"]?.stringValue
                    run.members[index].durationMilliseconds = integerValue(data["durationMilliseconds"])
                        .map(Int64.init) ?? integerValue(data["duration_ms"]).map(Int64.init)
                    run.members[index].error = data["error"]?.stringValue
                    runs[runID] = run
                }

            case runEndType:
                guard let runID = runIdentifier(data),
                      var run = runs[runID] else { continue }
                run.stopReason = data["stopReason"]?.stringValue ?? data["stop_reason"]?.stringValue
                runs[runID] = run

            default:
                break
            }
        }

        return WorkflowRunTree(runs: order.compactMap { runs[$0] })
    }

    private static func runIdentifier(_ data: [String: JSONValue]) -> String? {
        data["runId"]?.stringValue ?? data["run_id"]?.stringValue
    }

    private static func integerValue(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value else { return nil }
        return Int(number)
    }
}
