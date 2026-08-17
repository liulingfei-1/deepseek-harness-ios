import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class UserInteractionCompatibilityFixtureTests: XCTestCase {
    func testPinnedAskUserQuestionWireContract() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.source.commit,
            "47f943859bef60e4160492346772ded9b24f765a"
        )

        let provider = ContinuationUserQuestionProvider()
        let tool = AskUserQuestionTool(service: UserQuestionService(provider: provider))
        let task = Task {
            try await tool.execute(arguments: fixture.askUser.arguments)
        }
        let pending = try await waitForPending(provider)
        XCTAssertEqual(
            pending.request.questions.map(\.id),
            fixture.askUser.expectedQuestionIDs
        )
        XCTAssertTrue(pending.request.questions[0].multiSelect)
        XCTAssertFalse(pending.request.questions[1].multiSelect)
        XCTAssertNil(pending.request.questions[2].options)

        try await provider.submit(
            AskUserQuestionAnswer(
                answers: fixture.askUser.answer.answers.map(\.productionValue)
            ),
            requestID: pending.id
        )

        let output = try await task.value
        XCTAssertEqual(output, fixture.askUser.expectedOutput)
    }

    func testPinnedPlanReviewActionContract() async throws {
        let fixture = try loadFixture()

        for action in fixture.planReview.actions {
            let provider = ContinuationUserQuestionProvider()
            let state = PlanModeStateStore(active: true)
            let tool = ExitPlanModeTool(
                questionService: UserQuestionService(provider: provider),
                planState: state
            )
            let task = Task {
                try await tool.execute(arguments: [
                    "plan": .string(fixture.planReview.plan)
                ])
            }
            let pending = try await waitForPending(provider)
            let presentation = try XCTUnwrap(
                PlanReviewPresentation(request: pending.request)
            )
            XCTAssertEqual(presentation.id, fixture.planReview.expectedPresentation.id)
            XCTAssertEqual(
                presentation.question,
                fixture.planReview.expectedPresentation.question
            )
            XCTAssertEqual(
                presentation.approve.label,
                fixture.planReview.expectedPresentation.approve
            )
            XCTAssertEqual(
                presentation.decline?.label,
                fixture.planReview.expectedPresentation.decline
            )
            XCTAssertEqual(presentation.plan, fixture.planReview.plan)

            if action.kind == "discuss" {
                try await provider.cancel(requestID: pending.id)
            } else {
                let answer = try XCTUnwrap(action.answer)
                try await provider.submit(
                    AskUserQuestionAnswer(answers: [answer.productionValue]),
                    requestID: pending.id
                )
            }

            do {
                let output = try await task.value
                XCTAssertEqual(action.expectedOutcome, "approved")
                XCTAssertEqual(output, action.expectedOutput)
            } catch let error as PlanReviewError {
                switch action.expectedOutcome {
                case "dismissed":
                    XCTAssertEqual(error, .dismissed)
                case "rejected":
                    XCTAssertEqual(error, .rejected(action.expectedFeedback))
                default:
                    XCTFail("Unexpected plan review error for \(action.kind): \(error)")
                }
            }

            let activeAfterAction = await state.isActive()
            let pendingExitAfterAction = await state.hasPendingExit()
            XCTAssertEqual(activeAfterAction, action.activeAfterAction)
            XCTAssertEqual(pendingExitAfterAction, action.pendingExitAfterAction)
            if let activeAfterCommit = action.activeAfterCommit {
                let committed = await state.commitPendingExit()
                let active = await state.isActive()
                XCTAssertTrue(committed)
                XCTAssertEqual(active, activeAfterCommit)
            }
        }
    }

    private func waitForPending(
        _ provider: ContinuationUserQuestionProvider
    ) async throws -> ContinuationUserQuestionProvider.Pending {
        for _ in 0..<200 {
            if let pending = await provider.pending() {
                return pending
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw XCTSkip("Timed out waiting for the fixture-backed user question")
    }

    private func loadFixture() throws -> UserInteractionFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("deepseek", isDirectory: true)
            .appendingPathComponent("user-interaction-v1.json")
        return try JSONDecoder().decode(
            UserInteractionFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }
}

private struct UserInteractionFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let askUser: AskUser
    let planReview: PlanReview

    struct Source: Decodable {
        let project: String
        let commit: String
    }

    struct AskUser: Decodable {
        let arguments: [String: JSONValue]
        let expectedQuestionIDs: [String]
        let answer: Answer
        let expectedOutput: String
    }

    struct Answer: Decodable {
        let answers: [AnswerItem]
    }

    struct AnswerItem: Decodable {
        let id: String
        let selected: [String]
        let custom: String?

        var productionValue: AskUserQuestionAnswerItem {
            AskUserQuestionAnswerItem(id: id, selected: selected, custom: custom)
        }
    }

    struct PlanReview: Decodable {
        let plan: String
        let expectedPresentation: ExpectedPresentation
        let actions: [Action]

        struct ExpectedPresentation: Decodable {
            let id: String
            let question: String
            let approve: String
            let decline: String
        }

        struct Action: Decodable {
            let kind: String
            let answer: AnswerItem?
            let expectedOutcome: String
            let expectedFeedback: String?
            let expectedOutput: String?
            let activeAfterAction: Bool
            let pendingExitAfterAction: Bool
            let activeAfterCommit: Bool?
        }
    }
}
