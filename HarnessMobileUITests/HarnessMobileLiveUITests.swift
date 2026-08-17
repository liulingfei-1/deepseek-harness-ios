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

    private func launchResetAndAssertOnboarding(_ app: XCUIApplication) {
        app.launchArguments = [
            "-reset-persistent-state-for-ui-testing",
            "-disable-animations-for-ui-testing",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["配置 Harness"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.secureTextFields["api-key-field"].exists)
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

    let activeConversation = app.staticTexts["新会话"].firstMatch
    if activeConversation.waitForExistence(timeout: 3), activeConversation.isHittable {
        activeConversation.tap()
    } else {
        let newConversation = app.buttons["新建会话"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        newConversation.tap()
    }

    XCTAssertTrue(app.buttons["会话选项"].waitForExistence(timeout: 15))
}

@MainActor
private func openTerminal(in app: XCUIApplication) {
    XCTAssertTrue(app.navigationBars["Harness"].waitForExistence(timeout: 15))
    let terminalButton = app.buttons["iSH 终端"]
    XCTAssertTrue(terminalButton.waitForExistence(timeout: 5))
    terminalButton.tap()
}
