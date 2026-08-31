import XCTest

@MainActor
final class HarnessMobileOnboardingUITests: XCTestCase {
    func testResetAlwaysReturnsToOnboarding() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }

        launchResetAndAssertOnboarding(app)
        launchResetAndAssertOnboarding(app)
    }

    func testOnboardingKeepsAdvancedInferenceInSettings() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }

        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["配置 Harness"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["provider-picker"].isHittable)
        for _ in 0..<6 {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(app.staticTexts["安全边界"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["推理"].exists)
    }

    private func launchResetAndAssertOnboarding(_ app: XCUIApplication) {
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["配置 Harness"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.secureTextFields["api-key-field"].exists)
        XCTAssertFalse(app.textFields["provider-display-name-field"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let saveButton = app.buttons["save-configuration"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(saveButton.isHittable)
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)
    }
}

@MainActor
final class HarnessMobileConversationModeUITests: XCTestCase {
    func testConversationSwitchesBetweenChatAndTrajectory() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        openConversation(in: app)

        app.buttons["会话选项"].tap()
        let trajectoryMode = app.buttons["轨迹"]
        XCTAssertTrue(trajectoryMode.waitForExistence(timeout: 5))
        trajectoryMode.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harness-trace-strip"]
                .waitForExistence(timeout: 10)
        )

        app.buttons["会话选项"].tap()
        let chatMode = app.buttons["对话"]
        XCTAssertTrue(chatMode.waitForExistence(timeout: 5))
        chatMode.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].waitForExistence(timeout: 5))
    }
}

@MainActor
final class HarnessMobileConcurrentRunsUITests: XCTestCase {
    func testCreatingAndSwitchingSessionsKeepsBothRootRunsVisible() {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-concurrent-session-runs-for-ui-testing",
        ]
        app.launch()

        let firstSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "新会话")
        ).firstMatch
        let secondSession = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "并发会话 B")
        ).firstMatch
        XCTAssertTrue(firstSession.waitForExistence(timeout: 15))
        XCTAssertTrue(secondSession.exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "运行中")).count,
            2
        )

        secondSession.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Deep diving..."].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(firstSession.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "运行中")).count,
            2
        )
    }
}

@MainActor
final class HarnessMobileWorkspaceHierarchyUITests: XCTestCase {
    func testWorkspaceRootExposesFilesMountsAndSessionStateFromHome() {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["工具"].waitForExistence(timeout: 15))
        app.buttons["工具"].tap()
        XCTAssertTrue(app.navigationBars["工具"].waitForExistence(timeout: 5))
        let open = app.buttons["tool-route-workspace"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.navigationBars["工作区"].waitForExistence(timeout: 5))
    }
}

@MainActor
final class HarnessMobileAccessibilityUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testHomeAtAccessibilityXXXLInDarkLandscape() {
        let app = launchAccessibilityApp()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
        assertSystemToolbarTarget(app.buttons["设置"], named: "首页设置")
        assertSystemToolbarTarget(app.buttons["筛选与排序"], named: "首页筛选与排序")
        assertSystemToolbarTarget(app.buttons["工具"], named: "首页工具")
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新会话")).firstMatch
        assertCriticalTarget(project, named: "首页项目入口")
        attachAccessibilityEvidence(for: app, surface: "home")
    }

    func testTerminalAtAccessibilityXXXLInDarkLandscape() {
        let app = launchAccessibilityApp()
        addTeardownBlock { app.terminate() }

        openTerminal(in: app)
        XCTAssertTrue(app.navigationBars["iSH"].waitForExistence(timeout: 15))

        let field = app.descendants(matching: .any)["ish-command-field"]
        assertCriticalTarget(field, named: "终端命令输入")
        XCTAssertTrue(
            app.descendants(matching: .any)["ish-ready-status"]
                .waitForExistence(timeout: 120)
        )
        field.tap()
        field.typeText("pwd")
        assertCriticalTarget(app.buttons["ish-run-command"], named: "终端执行命令")
        attachAccessibilityEvidence(for: app, surface: "terminal")
    }

    func testChatAtAccessibilityXXXLInDarkLandscape() {
        let app = launchAccessibilityApp()
        addTeardownBlock { app.terminate() }

        openConversation(in: app)
        assertSystemToolbarTarget(app.buttons["会话选项"], named: "聊天会话选项")
        assertCriticalTarget(app.buttons["添加内容"], named: "聊天添加内容")
        assertCriticalTarget(app.buttons["命令"], named: "聊天命令")

        let field = app.descendants(matching: .any)["chat-input"]
        assertCriticalTarget(field, named: "聊天输入")
        field.tap()
        field.typeText("accessibility audit")
        assertCriticalTarget(app.buttons["chat-send-button"], named: "聊天发送")
        attachAccessibilityEvidence(for: app, surface: "chat")
    }

    func testSettingsAtAccessibilityXXXLInDarkLandscape() {
        let app = launchAccessibilityApp()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        let modelProviders = app.buttons["settings-model-providers"]
        scrollUntilHittable(modelProviders, in: app)
        assertCriticalTarget(modelProviders, named: "设置模型与服务商")

        let phonePermissions = app.buttons["settings-phone-permissions"]
        scrollUntilHittable(phonePermissions, in: app)
        assertCriticalTarget(phonePermissions, named: "设置手机权限")
        attachAccessibilityEvidence(for: app, surface: "settings")
    }

    private func launchAccessibilityApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-force-dark-mode-for-ui-testing",
        ]
        app.launch()
        return app
    }

    private func assertCriticalTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "\(name) 不存在",
            file: file,
            line: line
        )
        XCTAssertTrue(element.isHittable, "\(name) 不可点击", file: file, line: line)
        XCTAssertFalse(element.label.isEmpty, "\(name) 没有可访问性名称", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            44,
            "\(name) 宽度小于 44pt：\(element.frame.width)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            44,
            "\(name) 高度小于 44pt：\(element.frame.height)",
            file: file,
            line: line
        )
    }

    private func assertSystemToolbarTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "\(name) 不存在",
            file: file,
            line: line
        )
        XCTAssertTrue(element.isHittable, "\(name) 不可点击", file: file, line: line)
        XCTAssertFalse(element.label.isEmpty, "\(name) 没有可访问性名称", file: file, line: line)
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let scroller = app.collectionViews.firstMatch
        for _ in 0..<6 where !element.isHittable {
            scroller.swipeUp(velocity: .slow)
        }
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication) {
        let scroller = app.collectionViews.firstMatch
        for _ in 0..<6 where !element.exists {
            scroller.swipeUp(velocity: .slow)
        }
    }

    private func attachAccessibilityEvidence(for app: XCUIApplication, surface: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "UI-004-\(surface)-AccessibilityXXXL-dark-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "UI-004-\(surface)-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

@MainActor
final class HarnessMobileProgressiveDisclosureUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHomePrioritizesProjectsAndMovesSecondaryToolsToToolsRoute() {
        let app = launchConfiguredApp()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["项目"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新会话")).firstMatch.exists)
        XCTAssertFalse(app.buttons["home-continue-task"].exists)
        XCTAssertFalse(app.buttons["home-background-status"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace-hierarchy-root"].exists)

        app.buttons["工具"].tap()
        XCTAssertTrue(app.navigationBars["工具"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tool-route-terminal"].exists)
        XCTAssertTrue(app.buttons["tool-route-workspace"].exists)
        XCTAssertTrue(app.buttons["tool-route-settings"].exists)
    }

    func testSettingsGroupsBackgroundStorageAndPrivacyWithoutHidingRoutes() {
        let app = launchConfiguredApp()
        addTeardownBlock { app.terminate() }

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["settings-model-providers"].exists)
        XCTAssertTrue(app.buttons["settings-background-tasks"].exists)
        XCTAssertTrue(app.buttons["settings-phone-permissions"].exists)
        let workspace = app.descendants(matching: .any)["settings-workspace"]
        scrollUntilExists(workspace, in: app)
        XCTAssertTrue(workspace.exists)
        let diagnostics = app.descendants(matching: .any)["settings-diagnostics"]
        scrollUntilExists(diagnostics, in: app)
        XCTAssertTrue(diagnostics.exists)

        scrollToTop(in: app)
        scrollUntilHittable(app.buttons["settings-background-tasks"], in: app)
        app.buttons["settings-background-tasks"].tap()
        XCTAssertTrue(app.navigationBars["后台任务"].waitForExistence(timeout: 10))
        let projectionHeader = app.staticTexts["当前系统投影"]
        scrollUntilExists(projectionHeader, in: app)
        XCTAssertTrue(projectionHeader.exists)
        let activeRuns = app.staticTexts["活动任务"]
        scrollUntilExists(activeRuns, in: app)
        XCTAssertTrue(activeRuns.exists)
    }

    func testProviderManagementMovesRequestBehaviorToFocusedSubpage() {
        let app = launchConfiguredApp()
        addTeardownBlock { app.terminate() }

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        app.buttons["settings-model-providers"].tap()
        XCTAssertTrue(app.navigationBars["模型与服务商"].waitForExistence(timeout: 10))

        let behavior = app.buttons["provider-behavior-settings"]
        XCTAssertTrue(behavior.waitForExistence(timeout: 5))
        behavior.tap()

        XCTAssertTrue(app.navigationBars["模型行为"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["上下文压缩"].exists)
        XCTAssertTrue(app.staticTexts["时间上下文"].exists)
        XCTAssertTrue(app.staticTexts["会话标题"].exists)
    }

    private func launchConfiguredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()
        return app
    }
}

@MainActor
final class HarnessMobileLongConversationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLongConversationStartsAtBoundedLatestWindowAndCanPageBackward() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-long-conversation-for-ui-testing",
        ]
        app.launch()

        openConversation(in: app)

        XCTAssertTrue(text(containing: "perf-message-999", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(text(containing: "perf-message-0", in: app).exists)

        let loadEarlierTools = app.buttons["显示前面的 20 个工具调用"]
        XCTAssertTrue(loadEarlierTools.waitForExistence(timeout: 5))
        XCTAssertEqual(loadEarlierTools.value as? String, "尚有 96 个较早工具调用")
        for _ in 0..<3 where !loadEarlierTools.isHittable {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(loadEarlierTools.isHittable)
        loadEarlierTools.tap()
        let pagedToolValue = NSPredicate(format: "value == %@", "尚有 76 个较早工具调用")
        let pagedToolExpectation = XCTNSPredicateExpectation(
            predicate: pagedToolValue,
            object: loadEarlierTools
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pagedToolExpectation], timeout: 5), .completed)

        let loadEarlier = app.descendants(matching: .any)["load-earlier-messages"]
        // Avoid querying an off-screen lazy element after every gesture: on
        // Xcode 27 each miss retries for about three seconds. Twelve fast
        // gestures cover the fixed 80-row initial window, then query once.
        for _ in 0..<12 {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(loadEarlier.waitForExistence(timeout: 5))
        XCTAssertTrue(loadEarlier.isHittable)
        XCTAssertEqual(loadEarlier.value as? String, "尚有 920 条较早消息")
        loadEarlier.tap()

        let pagedValue = NSPredicate(format: "value == %@", "尚有 840 条较早消息")
        let pagedExpectation = XCTNSPredicateExpectation(predicate: pagedValue, object: loadEarlier)
        XCTAssertEqual(XCTWaiter.wait(for: [pagedExpectation], timeout: 10), .completed)
    }

    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }
}

@MainActor
final class HarnessMobileTrajectoryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTrajectoryLedgersSearchCollapseAndInspect() {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-trajectory-for-ui-testing",
        ]
        app.launch()

        openConversation(in: app)
        app.buttons["会话选项"].tap()
        XCTAssertTrue(app.buttons["轨迹"].waitForExistence(timeout: 5))
        app.buttons["轨迹"].tap()

        XCTAssertTrue(app.staticTexts["Duration"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Turns"].exists)
        XCTAssertTrue(app.staticTexts["Calls"].exists)
        XCTAssertTrue(app.staticTexts["TTFT"].exists)
        XCTAssertTrue(app.staticTexts["Output"].exists)
        XCTAssertTrue(app.staticTexts["Cache"].exists)

        let ledger = app.segmentedControls.firstMatch
        XCTAssertTrue(ledger.waitForExistence(timeout: 5))
        ledger.buttons["Calls"].tap()
        let toolEvent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "TOOL CALL")
        ).firstMatch
        XCTAssertTrue(toolEvent.waitForExistence(timeout: 5))
        toolEvent.tap()
        XCTAssertTrue(app.staticTexts["Tool call"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()

        let resultEvent = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "TOOL RESULT")
        ).firstMatch
        XCTAssertTrue(resultEvent.waitForExistence(timeout: 5))
        resultEvent.tap()
        XCTAssertTrue(app.staticTexts["Tool result"].waitForExistence(timeout: 5))

        app.navigationBars.buttons["完成"].tap()
        ledger.buttons["Turns"].tap()
        let turnHeader = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Turn 1")
        ).firstMatch
        XCTAssertTrue(turnHeader.waitForExistence(timeout: 5))
        turnHeader.tap()
        XCTAssertTrue(app.staticTexts["Request header"].waitForExistence(timeout: 5))
        turnHeader.tap()
        XCTAssertTrue(app.staticTexts["Request header"].exists)

        let search = app.searchFields["搜索类型、内容、工具或 Call ID"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("workspace_read_text")
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "workspace_read_text")
        ).firstMatch.waitForExistence(timeout: 5))
    }
}

@MainActor
final class HarnessMobileChatChromeUITests: XCTestCase {
    func testErrorStaysInlineAndCanBeDismissed() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-chat-error-for-ui-testing",
        ]
        app.launch()

        openConversation(in: app)

        let banner = app.descendants(matching: .any)["chat-error-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertEqual(app.alerts.count, 0)

        let dismiss = app.buttons["关闭错误提示"]
        XCTAssertTrue(dismiss.isHittable)
        dismiss.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
    }
}

@MainActor
final class HarnessMobileMarkdownUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWideMarkdownTableRemainsAccessibleAtLargeDynamicType() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-markdown-table-for-ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        openConversation(in: app)

        let table = app.scrollViews["表格，3 行，5 列"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertEqual(table.label, "表格，3 行，5 列")
        XCTAssertTrue(app.staticTexts["工具能力对照"].exists)
        table.swipeLeft(velocity: .slow)
        XCTAssertTrue(app.staticTexts["解释"].exists)
    }

    func testOneMillionCharacterMarkdownRendersFirstSegmentAndCopiesCompleteSource() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-large-markdown-for-ui-testing",
        ]
        app.launch()

        let started = Date()
        openConversation(in: app)
        let heading = app.staticTexts["large-markdown-end"]
        XCTAssertTrue(heading.waitForExistence(timeout: 15))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)

        XCTAssertTrue(app.links["OpenAI"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["quoted line one"].exists)
        XCTAssertTrue(app.staticTexts["let localOnly = true"].exists)
        XCTAssertTrue(app.scrollViews["表格，2 行，2 列"].exists)

        let copy = app.buttons["复制回答"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.isHittable)
        copy.tap()
    }
}

@MainActor
final class HarnessMobilePlanReviewUITests: XCTestCase {
    func testPlanReviewPresentsAllDesktopActions() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-plan-review-for-ui-testing",
        ]
        app.launch()

        openConversation(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["plan-review-sheet"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.buttons["plan-review-chat"].isHittable)
        XCTAssertTrue(app.buttons["plan-review-refuse"].isHittable)
        XCTAssertTrue(app.buttons["plan-review-approve"].isHittable)
    }
}

@MainActor
final class HarnessMobileISHTerminalUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLocalTerminalExecutesStreamsAndStopsCommands() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        openTerminal(in: app)

        let readyStatus = app.descendants(matching: .any)["ish-ready-status"]
        XCTAssertTrue(readyStatus.waitForExistence(timeout: 120))

        let networkToggle = app.switches["ish-network-toggle"]
        XCTAssertTrue(networkToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(networkToggle.isHittable)
        setSwitch(networkToggle, enabled: true)
        setSwitch(networkToggle, enabled: false)

        run(command: "uname -m", in: app)
        let architectureOutput = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'arm64' OR label CONTAINS[c] 'aarch64'")
        ).firstMatch
        XCTAssertTrue(architectureOutput.waitForExistence(timeout: 30))

        run(command: "printf 'stdout-ok\\n'; printf 'stderr-ok\\n' >&2", in: app)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "stdout-ok")
        ).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "stderr-ok")
        ).firstMatch.waitForExistence(timeout: 30))

        let commandField = app.descendants(matching: .any)["ish-command-field"]
        commandField.tap()
        commandField.typeText("sleep 30")
        app.buttons["ish-run-command"].tap()
        let stopButton = app.buttons["ish-stop-command"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()
        XCTAssertTrue(app.staticTexts["已停止"].waitForExistence(timeout: 15))
    }

    func testLiveMarketplaceEndpointsOnPhysicalDevice() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_RUN_LIVE_ISH_NETWORK_TEST"] == "1",
            "Set HARNESS_RUN_LIVE_ISH_NETWORK_TEST=1 for an explicit physical-device probe."
        )

        let app = XCUIApplication()
        addTeardownBlock {
            if app.state == .runningForeground {
                let networkToggle = app.switches["ish-network-toggle"]
                if networkToggle.exists, networkToggle.value as? String == "1" {
                    networkToggle.tap()
                }
            }
            app.terminate()
        }
        app.launchArguments = ["-disable-animations-for-ui-testing"]
        app.launch()

        openTerminal(in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["ish-ready-status"]
                .waitForExistence(timeout: 120)
        )
        let networkToggle = app.switches["ish-network-toggle"]
        XCTAssertTrue(networkToggle.waitForExistence(timeout: 5))
        setSwitch(networkToggle, enabled: true)

        run(
            command: Self.fetchProbeCommand(
                label: "RAW",
                url: "https://raw.githubusercontent.com/awesome-dsh-plugin/awesome-dsh-plugin/main/README.zh.md"
            ),
            in: app
        )
        XCTAssertTrue(
            output(containingAnyOf: ["RAW_STATUS=", "RAW_ERROR="], in: app)
                .waitForExistence(timeout: 45)
        )

        run(
            command: Self.fetchProbeCommand(
                label: "JSD",
                url: "https://cdn.jsdelivr.net/gh/awesome-dsh-plugin/awesome-dsh-plugin@main/README.zh.md"
            ),
            in: app
        )
        XCTAssertTrue(
            output(containingAnyOf: ["JSD_STATUS=200"], in: app)
                .waitForExistence(timeout: 45)
        )
        setSwitch(networkToggle, enabled: false)
    }

    private func run(command: String, in app: XCUIApplication) {
        let commandField = app.descendants(matching: .any)["ish-command-field"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        commandField.tap()
        commandField.typeText(command)

        let runButton = app.buttons["ish-run-command"]
        XCTAssertTrue(runButton.isEnabled)
        runButton.tap()
    }

    private func setSwitch(_ toggle: XCUIElement, enabled: Bool) {
        let expectedValue = enabled ? "1" : "0"
        guard toggle.value as? String != expectedValue else { return }

        toggle.tap()

        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: toggle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Expected switch value to become \(expectedValue), got \(String(describing: toggle.value))"
        )
    }

    private static func fetchProbeCommand(label: String, url: String) -> String {
        "node -e \"fetch('\\(url)').then(r=>{console.log('\\(label)_STATUS='+r.status);process.exit(r.ok?0:1)}).catch(e=>{console.error('\\(label)_ERROR='+e.message);console.error('\\(label)_CAUSE='+(e.cause?.code||e.cause?.message||''));process.exit(1)})\""
    }

    private func output(containingAnyOf fragments: [String], in app: XCUIApplication) -> XCUIElement {
        let clauses = fragments.map { _ in "label CONTAINS %@" }.joined(separator: " OR ")
        return app.staticTexts.matching(
            NSPredicate(format: clauses, argumentArray: fragments)
        ).firstMatch
    }
}

@MainActor
final class HarnessMobilePluginManagementUITests: XCTestCase {
    func testCompilationFailureTraceExposesStagesLogsAndStructuredDiagnostic() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-plugin-compilation-failure-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["社区插件"].waitForExistence(timeout: 15))
        let trace = app.descendants(matching: .any)["community-plugin-compilation-summary"]
        XCTAssertTrue(trace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["下载源码"].exists)
        let validation = app.staticTexts["Swift 校验"]
        XCTAssertTrue(validation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["拒绝未审计的 Web client contribution。"].exists)

        let logs = app.buttons["community-plugin-compilation-logs-toggle"]
        scrollUntilHittable(logs, in: app)
        XCTAssertTrue(logs.isHittable)
        logs.tap()
        let sourceSnapshotLog = app.staticTexts["源码快照已完成，凭据仍留在 Keychain。"]
        XCTAssertTrue(sourceSnapshotLog.waitForExistence(timeout: 5))
        let diagnosticTitle = app.staticTexts["结构化诊断 · UNSUPPORTED_CLIENT_CONTRIBUTION"]
        scrollUntilExists(diagnosticTitle, in: app)
        XCTAssertTrue(diagnosticTitle.exists)
        XCTAssertTrue(app.staticTexts["该插件请求 Web client slot；手机端不动态加载 Web 或 Swift 代码。"].exists)
        XCTAssertTrue(app.staticTexts["example/unsupported-web-client"].exists)
    }

    func testCommunityMarketplaceUsesCompactSearchableList() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
            "-present-plugin-market-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["社区插件"].waitForExistence(timeout: 15))

        let mode = app.segmentedControls["community-plugin-market-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.buttons["市场"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["community-plugin-market-summary"].exists)
        XCTAssertTrue(app.staticTexts["Git Tools"].exists)
        XCTAssertTrue(app.staticTexts["Memory Notes"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["community-plugin-market-error"].exists)

        let search = app.searchFields["搜索插件、分类或仓库"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("memory")
        XCTAssertTrue(app.staticTexts["Memory Notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Git Tools"].exists)

        mode.buttons["已安装"].tap()
        XCTAssertTrue(mode.buttons["已安装"].isSelected)
        XCTAssertTrue(app.staticTexts["Memory Notes"].waitForExistence(timeout: 5))

        let actions = app.buttons["community-plugin-market-actions"]
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        XCTAssertTrue(app.buttons["刷新目录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["GitHub 仓库"].exists)
        XCTAssertTrue(app.buttons["导入 ZIP"].exists)
        XCTAssertTrue(app.buttons["清理下载缓存"].exists)
    }

    func testLiveMarketplaceCatalogRPCOnDevice() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_RUN_LIVE_ISH_NETWORK_TEST"] == "1",
            "Set HARNESS_RUN_LIVE_ISH_NETWORK_TEST=1 for an explicit on-device catalog probe."
        )

        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
        let toolsButton = app.buttons["工具"]
        XCTAssertTrue(toolsButton.waitForExistence(timeout: 5))
        toolsButton.tap()

        let pluginsButton = app.buttons["tool-route-plugins"]
        XCTAssertTrue(pluginsButton.waitForExistence(timeout: 5))
        pluginsButton.tap()

        let marketplaceButton = app.buttons["community-plugin-market"]
        XCTAssertTrue(marketplaceButton.waitForExistence(timeout: 15))
        marketplaceButton.tap()
        XCTAssertTrue(app.navigationBars["社区插件"].waitForExistence(timeout: 10))

        let status = app.descendants(matching: .any)["community-plugin-market-status"]
        _ = status.waitForExistence(timeout: 3)
        XCTAssertTrue(
            status.waitForNonExistence(timeout: 240),
            "The real market/catalog RPC did not finish."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["community-plugin-market-error"].exists,
            "The real market/catalog RPC surfaced an error."
        )
        XCTAssertTrue(
            app.staticTexts["社区目录"].waitForExistence(timeout: 10),
            "The real market/catalog RPC returned no catalog rows."
        )
    }

    func testHostControlsAndJavaScriptEditorAreReachable() {
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
        }
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-bootstrap-configuration-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
        let toolsButton = app.buttons["工具"]
        XCTAssertTrue(toolsButton.waitForExistence(timeout: 5))
        toolsButton.tap()
        XCTAssertTrue(app.navigationBars["工具"].waitForExistence(timeout: 5))

        let pluginsButton = app.buttons["tool-route-plugins"]
        XCTAssertTrue(pluginsButton.waitForExistence(timeout: 5))
        pluginsButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["ish-plugin-host-status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["plugin-runtime-summary"].exists)
        XCTAssertTrue(app.buttons["ish-plugin-host-start"].isEnabled)
        XCTAssertFalse(app.buttons["ish-plugin-host-refresh"].isEnabled)
        XCTAssertFalse(app.buttons["ish-plugin-host-stop"].isEnabled)

        let addPlugin = app.buttons["add-plugin-menu"]
        XCTAssertTrue(addPlugin.exists)
        addPlugin.tap()
        app.buttons["iSH JavaScript 插件"].tap()

        XCTAssertTrue(app.navigationBars["iSH 插件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["ish-plugin-name"].exists)
        XCTAssertTrue(app.textFields["ish-plugin-purpose"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ish-plugin-host-code"].exists)
    }
}

@MainActor
private func openConversation(in app: XCUIApplication) {
    XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))

    let activeConversation = app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "新会话", "当前")
    ).firstMatch
    if activeConversation.waitForExistence(timeout: 3), activeConversation.isHittable {
        activeConversation.tap()
    } else {
        for _ in 0..<3 where !activeConversation.exists {
            app.swipeUp(velocity: .fast)
        }
        if activeConversation.waitForExistence(timeout: 2), activeConversation.isHittable {
            activeConversation.tap()
        } else {
            let newConversation = app.buttons["新建会话"]
            XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
            newConversation.tap()
        }
    }

    XCTAssertTrue(app.buttons["会话选项"].waitForExistence(timeout: 15))
}

@MainActor
private func openTerminal(in app: XCUIApplication) {
    XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
    let toolsButton = app.buttons["工具"]
    XCTAssertTrue(toolsButton.waitForExistence(timeout: 5))
    toolsButton.tap()
    let terminalButton = app.descendants(matching: .any)["tool-route-terminal"]
    let scroller = app.collectionViews.firstMatch
    for _ in 0..<8 {
        if terminalButton.exists && terminalButton.isHittable {
            break
        }
        if scroller.exists {
            scroller.swipeUp(velocity: .fast)
        } else {
            app.swipeUp(velocity: .fast)
        }
    }
    XCTAssertTrue(terminalButton.waitForExistence(timeout: 5))
    XCTAssertTrue(terminalButton.isHittable)
    terminalButton.tap()
}

@MainActor
private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication) {
    let scroller = app.collectionViews.firstMatch
    for _ in 0..<6 where !element.exists {
        scroller.swipeUp(velocity: .slow)
    }
}

@MainActor
private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
    let scroller = app.collectionViews.firstMatch
    for _ in 0..<6 where !element.isHittable {
        scroller.swipeUp(velocity: .slow)
    }
}

@MainActor
private func scrollPluginMarketUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
    let scroller = app.tables.firstMatch.exists
        ? app.tables.firstMatch
        : app.collectionViews.firstMatch
    for _ in 0..<8 where !element.isHittable {
        scroller.swipeUp(velocity: .slow)
    }
}

@MainActor
private func scrollToTop(in app: XCUIApplication) {
    let scroller = app.collectionViews.firstMatch
    for _ in 0..<8 {
        scroller.swipeDown(velocity: .fast)
    }
}
