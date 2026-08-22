import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class RalphToolTests: XCTestCase {
    func testRalphStopsOnCompleteAfterFreshRoundsAndCarriesBoundedHandoff() async throws {
        let registry = HarnessJobRegistry()
        let prompts = LockedStrings()
        let runner: LocalSubagentRunner = { request, _ in
            await prompts.append(request.prompt)
            if await prompts.count == 1 {
                return #"{"status":"continue","summary":"first slice","evidence":["test passed"],"nextSteps":["finish second slice"],"blocker":""}"#
            }
            return #"{"status":"complete","summary":"done","evidence":["all gates pass"],"nextSteps":[],"blocker":""}"#
        }
        let tool = try XCTUnwrap(
            RalphToolSuite.makeTools(
                runner: runner,
                registry: registry,
                ownerSession: "parent",
                deploymentRoundCeiling: 4
            ).first
        )

        let result = try await tool.execute(arguments: [
            "objective": .string("finish the work"),
            "max_rounds": .number(4)
        ])
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        XCTAssertEqual(json.objectValue?["status"], .string("complete"))
        XCTAssertEqual(json.objectValue?["rounds_started"], .number(2))
        let recorded = await prompts.values
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(recorded[0].contains("first round"))
        XCTAssertTrue(recorded[1].contains("first slice"))
    }

    func testRalphReturnsBudgetLimitedWhenWorkerContinues() async throws {
        let runner: LocalSubagentRunner = { _, _ in
            #"{"status":"continue","summary":"still working","evidence":["one gate"],"nextSteps":["another gate"],"blocker":""}"#
        }
        let tool = try XCTUnwrap(
            RalphToolSuite.makeTools(
                runner: runner,
                registry: HarnessJobRegistry(),
                ownerSession: "parent",
                deploymentRoundCeiling: 2
            ).first
        )

        let result = try await tool.execute(arguments: [
            "objective": .string("keep going"),
            "max_rounds": .number(2)
        ])
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        XCTAssertEqual(json.objectValue?["status"], .string("budget-limited"))
        XCTAssertEqual(json.objectValue?["rounds_started"], .number(2))
    }

    func testRalphRejectsMalformedStatusSpecificReport() async throws {
        let runner: LocalSubagentRunner = { _, _ in
            #"{"status":"complete","summary":"done","evidence":[],"nextSteps":[],"blocker":""}"#
        }
        let tool = try XCTUnwrap(
            RalphToolSuite.makeTools(
                runner: runner,
                registry: HarnessJobRegistry(),
                ownerSession: "parent",
                deploymentRoundCeiling: 1
            ).first
        )
        do {
            _ = try await tool.execute(arguments: ["objective": .string("reject")])
            XCTFail("expected malformed report failure")
        } catch let error as LocalToolError {
            guard case .pluginFailed = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
    }
}

private actor LockedStrings {
    private(set) var values: [String] = []

    var count: Int { values.count }

    func append(_ value: String) {
        values.append(value)
    }
}
