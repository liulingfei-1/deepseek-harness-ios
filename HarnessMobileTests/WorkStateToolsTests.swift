import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkStateToolsTests: XCTestCase {
    func testGoalPlanAndTodosUpdateOneLocalCoordinator() async throws {
        let coordinator = WorkStateCoordinator()
        let goal = WorkStateSetGoalTool(coordinator: coordinator)
        let plan = WorkStateReplacePlanTool(coordinator: coordinator)
        let todos = WorkStateReplaceTodosTool(coordinator: coordinator)

        _ = try await goal.execute(arguments: [
            "title": .string("整理资料"),
            "status": .string("active")
        ])
        _ = try await plan.execute(arguments: [
            "steps": .array([
                .object(["title": .string("读取"), "status": .string("completed")]),
                .object(["title": .string("总结"), "status": .string("active")])
            ])
        ])
        _ = try await todos.execute(arguments: [
            "items": .array([
                .object(["title": .string("核对来源"), "status": .string("pending")])
            ])
        ])

        let state = await coordinator.snapshot()
        XCTAssertEqual(state.goal?.title, "整理资料")
        XCTAssertEqual(state.goal?.status, .active)
        XCTAssertEqual(state.plan.map(\.status), [.completed, .active])
        XCTAssertEqual(state.todos.map(\.title), ["核对来源"])
    }

    /// Upstream exposes `get_goal` for the same reason: a model resuming a
    /// long task reads durable work state instead of guessing from history.
    func testWorkStateGetReturnsCurrentGoalPlanAndTodos() async throws {
        let coordinator = WorkStateCoordinator()
        let get = WorkStateGetTool(coordinator: coordinator)
        let setGoal = WorkStateSetGoalTool(coordinator: coordinator)

        // `goal` is optional, so an empty state encodes without the key.
        let empty = try JSONDecoder().decode(
            ConversationWorkState.self,
            from: Data(try await get.execute(arguments: [:]).utf8)
        )
        XCTAssertNil(empty.goal)

        _ = try await setGoal.execute(arguments: [
            "title": .string("整理资料"),
            "status": .string("active")
        ])
        let populated = try JSONDecoder().decode(
            ConversationWorkState.self,
            from: Data(try await get.execute(arguments: [:]).utf8)
        )
        XCTAssertEqual(populated.goal?.title, "整理资料")
        XCTAssertEqual(populated.goal?.status, .active)
        XCTAssertEqual(get.definition.name, "work_state_get")
        XCTAssertFalse(get.risk.requiresApproval)
    }

    func testWorkStateToolsRejectUnknownKeysAndInvalidStatus() async {
        let coordinator = WorkStateCoordinator()
        let goal = WorkStateSetGoalTool(coordinator: coordinator)

        do {
            _ = try await goal.execute(arguments: [
                "title": .string("目标"),
                "status": .string("invented"),
                "remote": .bool(true)
            ])
            XCTFail("Invalid work-state input should be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }

        let state = await coordinator.snapshot()
        XCTAssertNil(state.goal)
    }

    func testTodoStatusErrorNamesFieldAndAllowedValues() async {
        let tool = WorkStateReplaceTodosTool(coordinator: WorkStateCoordinator())

        do {
            _ = try await tool.execute(arguments: [
                "items": .array([
                    .object([
                        "title": .string("测试"),
                        "status": .string("in_progress")
                    ])
                ])
            ])
            XCTFail("Invalid status should be rejected")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("status"))
            XCTAssertTrue(message.contains("in_progress"))
            XCTAssertTrue(message.contains("pending"))
            XCTAssertTrue(message.contains("active"))
            XCTAssertFalse(message.contains("不是有效的 JSON 对象"))
        }
    }

    func testGoalLifecyclePreservesIdentityAcrossEditAndStatusTransitions() async throws {
        let original = ConversationGoal(title: "完成手机端移植", status: .active)
        let coordinator = WorkStateCoordinator(
            state: ConversationWorkState(goal: original)
        )

        var state = try await coordinator.applyGoalAction(
            .edit(title: "  完成手机端 Harness 移植  ")
        )
        XCTAssertEqual(state.goal?.id, original.id)
        XCTAssertEqual(state.goal?.title, "完成手机端 Harness 移植")

        state = try await coordinator.applyGoalAction(.pause)
        XCTAssertEqual(state.goal?.status, .paused)
        state = try await coordinator.applyGoalAction(.resume)
        XCTAssertEqual(state.goal?.status, .active)
        state = try await coordinator.applyGoalAction(.block)
        XCTAssertEqual(state.goal?.status, .blocked)
        state = try await coordinator.applyGoalAction(.resume)
        XCTAssertEqual(state.goal?.status, .active)
        state = try await coordinator.applyGoalAction(.complete)
        XCTAssertEqual(state.goal?.status, .completed)
        XCTAssertEqual(state.goal?.id, original.id)

        state = try await coordinator.applyGoalAction(.clear)
        XCTAssertNil(state.goal)
    }

    func testGoalLifecycleRejectsInvalidTransitionsWithoutChangingState() async throws {
        let original = ConversationGoal(title: "保持状态", status: .active)
        let coordinator = WorkStateCoordinator(
            state: ConversationWorkState(goal: original)
        )

        do {
            _ = try await coordinator.applyGoalAction(.resume)
            XCTFail("An already active goal cannot be resumed")
        } catch let error as ConversationGoalLifecycleError {
            XCTAssertEqual(
                error,
                .invalidTransition(from: .active, to: .active)
            )
        }

        do {
            _ = try await coordinator.applyGoalAction(.edit(title: "   "))
            XCTFail("An empty goal objective must be rejected")
        } catch let error as ConversationGoalLifecycleError {
            XCTAssertEqual(error, .emptyTitle)
        }

        let state = await coordinator.snapshot()
        XCTAssertEqual(state.goal, original)
    }

    func testModelGoalUpdatesRetainIdentityUntilACompletedGoalIsReplaced() async throws {
        let coordinator = WorkStateCoordinator()
        let tool = WorkStateSetGoalTool(coordinator: coordinator)

        _ = try await tool.execute(arguments: [
            "title": .string("第一版目标"),
            "status": .string("active")
        ])
        let first = (await coordinator.snapshot()).goal

        _ = try await tool.execute(arguments: [
            "title": .string("修订后的目标"),
            "status": .string("paused")
        ])
        let revised = (await coordinator.snapshot()).goal
        XCTAssertEqual(revised?.id, first?.id)

        _ = try await tool.execute(arguments: [
            "title": .string("修订后的目标"),
            "status": .string("completed")
        ])
        _ = try await tool.execute(arguments: [
            "title": .string("下一项目标"),
            "status": .string("active")
        ])
        let replacement = (await coordinator.snapshot()).goal
        XCTAssertNotEqual(replacement?.id, first?.id)
    }
}
