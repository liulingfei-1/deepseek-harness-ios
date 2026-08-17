import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class UserInteractionToolsTests: XCTestCase {
    func testQuestionServiceRejectsDuplicateIDsAndAcceptsSkippedAnswers() throws {
        let duplicate = AskUserQuestionRequest(
            questions: [
                AskUserQuestionItem(id: "same", question: "One?"),
                AskUserQuestionItem(id: "same", question: "Two?")
            ]
        )
        XCTAssertThrowsError(try UserQuestionService.validate(request: duplicate))

        let request = AskUserQuestionRequest(
            questions: [AskUserQuestionItem(id: "choice", question: "Choose")]
        )
        let skipped = AskUserQuestionAnswerItem(id: "choice")
        XCTAssertTrue(skipped.isSkipped)
        XCTAssertNoThrow(
            try UserQuestionService.validate(
                answer: AskUserQuestionAnswer(answers: [skipped]),
                for: request
            )
        )
        XCTAssertThrowsError(
            try UserQuestionService.validate(
                answer: AskUserQuestionAnswer(
                    answers: [AskUserQuestionAnswerItem(id: "choice", custom: "   ")]
                ),
                for: request
            )
        )
    }

    func testPlanReviewPresentationNarrowsOnlyAnExpressibleSingleDecision() {
        let approve = AskUserQuestionOption(label: "Approve", description: "Ship it")
        let decline = AskUserQuestionOption(label: "Keep planning", description: "Revise it")
        let intent = AskUserQuestionIntent(approve: approve.label)

        func question(
            detail: String?,
            options: [AskUserQuestionOption]?,
            multiSelect: Bool,
            intent: AskUserQuestionIntent?
        ) -> AskUserQuestionItem {
            AskUserQuestionItem(
                id: "plan-review",
                question: "Approve this plan?",
                detail: detail,
                options: options,
                multiSelect: multiSelect,
                intent: intent
            )
        }

        let valid = AskUserQuestionRequest(
            questions: [
                question(
                    detail: "# Plan",
                    options: [approve, decline],
                    multiSelect: false,
                    intent: intent
                )
            ]
        )
        let presentation = PlanReviewPresentation(request: valid)
        XCTAssertEqual(presentation?.id, "plan-review")
        XCTAssertEqual(presentation?.question, "Approve this plan?")
        XCTAssertEqual(presentation?.plan, "# Plan")
        XCTAssertEqual(presentation?.approve, approve)
        XCTAssertEqual(presentation?.decline, decline)

        let approveOnly = AskUserQuestionRequest(
            questions: [
                question(
                    detail: "# Plan",
                    options: [approve],
                    multiSelect: false,
                    intent: intent
                )
            ]
        )
        XCTAssertNil(PlanReviewPresentation(request: approveOnly)?.decline)

        let invalidRequests = [
            AskUserQuestionRequest(questions: valid.questions + valid.questions),
            AskUserQuestionRequest(
                questions: [
                    question(
                        detail: "# Plan",
                        options: [approve, decline],
                        multiSelect: false,
                        intent: nil
                    )
                ]
            ),
            AskUserQuestionRequest(
                questions: [
                    question(
                        detail: nil,
                        options: [approve, decline],
                        multiSelect: false,
                        intent: intent
                    )
                ]
            ),
            AskUserQuestionRequest(
                questions: [
                    question(
                        detail: "# Plan",
                        options: [decline],
                        multiSelect: false,
                        intent: intent
                    )
                ]
            ),
            AskUserQuestionRequest(
                questions: [
                    question(
                        detail: "# Plan",
                        options: [approve, decline, AskUserQuestionOption(label: "Start over")],
                        multiSelect: false,
                        intent: intent
                    )
                ]
            ),
            AskUserQuestionRequest(
                questions: [
                    question(
                        detail: "# Plan",
                        options: [approve, decline],
                        multiSelect: true,
                        intent: intent
                    )
                ]
            )
        ]
        for request in invalidRequests {
            XCTAssertNil(PlanReviewPresentation(request: request))
        }
    }

    func testContinuationProviderRoundTripsStructuredAnswer() async throws {
        let provider = ContinuationUserQuestionProvider()
        let request = AskUserQuestionRequest(
            questions: [
                AskUserQuestionItem(
                    id: "model",
                    question: "Which model?",
                    options: [AskUserQuestionOption(label: "deepseek-chat")]
                )
            ]
        )
        let task = Task { try await provider.ask(request) }
        let pending = try await waitForPending(provider)
        XCTAssertEqual(pending.request, request)

        let expected = AskUserQuestionAnswer(
            answers: [
                AskUserQuestionAnswerItem(id: "model", selected: ["deepseek-chat"])
            ]
        )
        try await provider.submit(expected, requestID: pending.id)
        let returned = try await task.value
        let remaining = await provider.pending()
        XCTAssertEqual(returned, expected)
        XCTAssertNil(remaining)
    }

    func testContinuationProviderRoundTripsSkippedAnswerAndClearsPendingRequest() async throws {
        let provider = ContinuationUserQuestionProvider()
        let service = UserQuestionService(provider: provider)
        let request = AskUserQuestionRequest(
            questions: [
                AskUserQuestionItem(
                    id: "model",
                    question: "Which model?",
                    options: [AskUserQuestionOption(label: "deepseek-chat")]
                ),
                AskUserQuestionItem(id: "detail", question: "Anything else?")
            ]
        )
        let task = Task { try await service.ask(request) }
        let pending = try await waitForPending(provider)
        let expected = AskUserQuestionAnswer(
            answers: [
                AskUserQuestionAnswerItem(id: "model", selected: ["deepseek-chat"]),
                AskUserQuestionAnswerItem(id: "detail")
            ]
        )

        try await provider.submit(expected, requestID: pending.id)

        let returned = try await task.value
        let remaining = await provider.pending()
        XCTAssertEqual(returned, expected)
        XCTAssertNil(remaining)
    }

    func testContinuationProviderCancellationNeverLeaksPendingRequest() async {
        let provider = ContinuationUserQuestionProvider()
        let request = AskUserQuestionRequest(
            questions: [AskUserQuestionItem(id: "cancel", question: "Continue?")]
        )
        let task = Task { try await provider.ask(request) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || error as? UserQuestionError == .cancelled)
        }
        let remaining = await provider.pending()
        XCTAssertNil(remaining)
    }

    func testAskUserQuestionToolReturnsStableWireAnswer() async throws {
        let provider = ContinuationUserQuestionProvider()
        let tool = AskUserQuestionTool(service: UserQuestionService(provider: provider))
        let arguments: [String: JSONValue] = [
            "questions": .array([
                .object([
                    "id": .string("confirm"),
                    "question": .string("Proceed?"),
                    "options": .array([
                        .object(["label": .string("Yes")]),
                        .object(["label": .string("No")])
                    ])
                ])
            ])
        ]

        let task = Task { try await tool.execute(arguments: arguments) }
        let pending = try await waitForPending(provider)
        try await provider.submit(
            AskUserQuestionAnswer(
                answers: [AskUserQuestionAnswerItem(id: "confirm", selected: ["Yes"])]
            ),
            requestID: pending.id
        )
        let output = try await task.value
        XCTAssertEqual(output, #"{"answers":[{"id":"confirm","selected":["Yes"]}]}"#)
    }

    func testAskUserQuestionToolPreservesAnsweredAndSkippedItemsInOneWireBatch() async throws {
        let provider = ContinuationUserQuestionProvider()
        let tool = AskUserQuestionTool(service: UserQuestionService(provider: provider))
        let arguments: [String: JSONValue] = [
            "questions": .array([
                .object([
                    "id": .string("mode"),
                    "question": .string("Choose a mode"),
                    "options": .array([
                        .object(["label": .string("Fast")]),
                        .object(["label": .string("Careful")])
                    ])
                ]),
                .object([
                    "id": .string("detail"),
                    "question": .string("Anything else?")
                ])
            ])
        ]

        let task = Task { try await tool.execute(arguments: arguments) }
        let pending = try await waitForPending(provider)
        try await provider.submit(
            AskUserQuestionAnswer(
                answers: [
                    AskUserQuestionAnswerItem(id: "mode", selected: ["Fast"]),
                    AskUserQuestionAnswerItem(id: "detail")
                ]
            ),
            requestID: pending.id
        )

        let output = try await task.value
        XCTAssertEqual(
            output,
            #"{"answers":[{"id":"mode","selected":["Fast"]},{"id":"detail","selected":[]}]}"#
        )
    }

    func testExitPlanModeRequiresExactApprovalAndCommitsAtBoundary() async throws {
        let provider = ContinuationUserQuestionProvider()
        let state = PlanModeStateStore(active: true)
        let tool = ExitPlanModeTool(
            questionService: UserQuestionService(provider: provider),
            planState: state
        )
        let task = Task {
            try await tool.execute(arguments: ["plan": .string("# Ship\n\n1. Build\n2. Verify")])
        }
        let pending = try await waitForPending(provider)
        try await provider.submit(
            AskUserQuestionAnswer(
                answers: [
                    AskUserQuestionAnswerItem(
                        id: ExitPlanModeTool.reviewID,
                        selected: [ExitPlanModeTool.approveLabel]
                    )
                ]
            ),
            requestID: pending.id
        )

        let output = try await task.value
        let pendingExit = await state.hasPendingExit()
        let committed = await state.commitPendingExit()
        let active = await state.isActive()
        XCTAssertEqual(output, #"{"approved":true}"#)
        XCTAssertTrue(pendingExit)
        XCTAssertTrue(committed)
        XCTAssertFalse(active)
    }

    func testExitPlanModeRejectionWithFeedbackKeepsPlanModeActive() async throws {
        let provider = ContinuationUserQuestionProvider()
        let state = PlanModeStateStore(active: true)
        let tool = ExitPlanModeTool(
            questionService: UserQuestionService(provider: provider),
            planState: state
        )
        let task = Task {
            try await tool.execute(arguments: ["plan": .string("# Revise\n\nCheck details")])
        }
        let pending = try await waitForPending(provider)
        try await provider.submit(
            AskUserQuestionAnswer(
                answers: [
                    AskUserQuestionAnswerItem(
                        id: ExitPlanModeTool.reviewID,
                        selected: [ExitPlanModeTool.keepPlanningLabel],
                        custom: "Add rollback steps"
                    )
                ]
            ),
            requestID: pending.id
        )

        do {
            _ = try await task.value
            XCTFail("Expected plan rejection")
        } catch let error as PlanReviewError {
            XCTAssertEqual(error, .rejected("Add rollback steps"))
        }
        let active = await state.isActive()
        let pendingExit = await state.hasPendingExit()
        XCTAssertTrue(active)
        XCTAssertFalse(pendingExit)
    }

    func testExitPlanModeRefusalKeepsPlanModeActive() async throws {
        let provider = ContinuationUserQuestionProvider()
        let state = PlanModeStateStore(active: true)
        let tool = ExitPlanModeTool(
            questionService: UserQuestionService(provider: provider),
            planState: state
        )
        let task = Task {
            try await tool.execute(arguments: ["plan": .string("# Revise\n\nCheck details")])
        }
        let pending = try await waitForPending(provider)
        try await provider.submit(
            AskUserQuestionAnswer(
                answers: [
                    AskUserQuestionAnswerItem(
                        id: ExitPlanModeTool.reviewID,
                        selected: [ExitPlanModeTool.keepPlanningLabel]
                    )
                ]
            ),
            requestID: pending.id
        )

        do {
            _ = try await task.value
            XCTFail("Expected plan refusal")
        } catch let error as PlanReviewError {
            XCTAssertEqual(error, .rejected(nil))
        }
        let active = await state.isActive()
        let pendingExit = await state.hasPendingExit()
        XCTAssertTrue(active)
        XCTAssertFalse(pendingExit)
    }

    func testExitPlanModeChatAboutItDismissesReviewAndKeepsPlanModeActive() async throws {
        let provider = ContinuationUserQuestionProvider()
        let state = PlanModeStateStore(active: true)
        let tool = ExitPlanModeTool(
            questionService: UserQuestionService(provider: provider),
            planState: state
        )
        let task = Task {
            try await tool.execute(arguments: ["plan": .string("# Discuss\n\nConfirm scope")])
        }
        let pending = try await waitForPending(provider)

        try await provider.cancel(requestID: pending.id)

        do {
            _ = try await task.value
            XCTFail("Expected dismissed plan review")
        } catch let error as PlanReviewError {
            XCTAssertEqual(error, .dismissed)
        }
        let active = await state.isActive()
        let pendingExit = await state.hasPendingExit()
        let remaining = await provider.pending()
        XCTAssertTrue(active)
        XCTAssertFalse(pendingExit)
        XCTAssertNil(remaining)
    }

    private func waitForPending(
        _ provider: ContinuationUserQuestionProvider
    ) async throws -> ContinuationUserQuestionProvider.Pending {
        for _ in 0..<100 {
            if let pending = await provider.pending() {
                return pending
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw XCTSkip("Timed out waiting for pending user question")
    }
}
