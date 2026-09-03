import Foundation

/// Mirrors upstream `dsh-session-turn-outline`: a pure fold of `turn/start`
/// boundaries, first human prompts, and final assistant responses into a
/// whole-log outline that stays available even when a client has only paged
/// in a window of events.
///
/// `turn/start` — not the prompt — anchors each entry because its seq is the
/// load-through target for a jump back to that turn. Previews mirror the
/// trajectory card budgets (one prompt line, up to three response lines) so a
/// turn shows the same words before and after its events load. The response
/// commits at `turn/end` from a draft of the newest text-bearing assistant
/// message.
struct SessionTurnOutlineEntry: Codable, Sendable, Equatable, Identifiable {
    let turn: Int
    let seq: UInt64
    /// Bounded first-human-prompt preview; empty until an eligible prompt lands.
    var prompt: String
    /// Bounded final-response preview; empty until the turn ends with text.
    var response: String

    var id: Int { turn }
}

struct SessionTurnOutlineState: Codable, Sendable, Equatable {
    /// Started turns in ascending turn order.
    var turns: [SessionTurnOutlineEntry]
    /// Newest text-bearing assistant preview of the open turn.
    var draft: String

    static let empty = SessionTurnOutlineState(turns: [], draft: "")
}

enum SessionTurnOutline {
    /// Prompt budget: one rail-card line.
    static let promptPreviewLimit = 50
    /// Response budget: three rail-card lines.
    static let responsePreviewLimit = 120

    /// Folds a whole durable log into the outline state.
    static func fold(_ events: [SessionEvent]) -> SessionTurnOutlineState {
        var state = SessionTurnOutlineState.empty
        for event in events {
            apply(event, to: &state)
        }
        return state
    }

    static func apply(_ event: SessionEvent, to state: inout SessionTurnOutlineState) {
        switch event.type {
        case SessionEventVocabulary.turnStart:
            guard let turn = event.turnStartData?.turn else { return }
            // A boundary that does not advance the turn number keeps the
            // outline sorted; a retried turn's previews land on the standing
            // entry.
            if let last = state.turns.last, turn <= last.turn { return }
            state.turns.append(
                SessionTurnOutlineEntry(turn: turn, seq: event.seq, prompt: "", response: "")
            )
            state.draft = ""

        case SessionEventVocabulary.userMessage:
            // Only the newest turn can still be waiting for its opening human
            // prompt; later human messages in the same turn (steering) keep
            // the first preview. Tool-sourced messages never fill it.
            guard event.data.objectValue?["source"]?.objectValue?["kind"]?.stringValue == "user" else {
                return
            }
            guard !state.turns.isEmpty, state.turns[state.turns.count - 1].prompt.isEmpty else {
                return
            }
            let prompt = preview(
                from: event.data.objectValue?["content"],
                limit: promptPreviewLimit
            )
            guard !prompt.isEmpty else { return }
            state.turns[state.turns.count - 1].prompt = prompt

        case SessionEventVocabulary.assistantMessage:
            // Newest text-bearing message wins; the buffer commits at turn/end.
            let content = event.data.objectValue?["message"]?.objectValue?["content"]
            let draft = preview(from: content, limit: responsePreviewLimit)
            guard !draft.isEmpty, draft != state.draft else { return }
            state.draft = draft

        case SessionEventVocabulary.turnEnd:
            guard !state.draft.isEmpty, !state.turns.isEmpty else { return }
            let last = state.turns.count - 1
            guard state.turns[last].response != state.draft else {
                state.draft = ""
                return
            }
            state.turns[last].response = state.draft
            state.draft = ""

        default:
            break
        }
    }

    /// Space-joins text blocks, collapses whitespace, and caps at `limit` with
    /// a trailing ellipsis when clipped. Per-block bounds keep a single
    /// multi-megabyte block from being concatenated whole for a preview this
    /// short.
    static func preview(from content: JSONValue?, limit: Int) -> String {
        guard case let .array(blocks)? = content else { return "" }
        var text = ""
        var clipped = false
        for block in blocks {
            guard block.objectValue?["type"]?.stringValue == "text",
                  let chunk = block.objectValue?["text"]?.stringValue else {
                continue
            }
            if text.count >= limit * 2 {
                clipped = true
                break
            }
            if chunk.count > limit * 2 {
                text += text.isEmpty ? String(chunk.prefix(limit * 2)) : " " + String(chunk.prefix(limit * 2))
                clipped = true
                break
            }
            text += text.isEmpty ? chunk : " " + chunk
        }
        let normalized = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if normalized.count > limit - 1 {
            return String(normalized.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return clipped ? normalized + "…" : normalized
    }
}
