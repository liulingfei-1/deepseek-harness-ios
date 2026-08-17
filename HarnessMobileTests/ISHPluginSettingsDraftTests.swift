import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHPluginSettingsDraftTests: XCTestCase {
    func testFormBuildsStableRootAndNestedPresentation() throws {
        let form = try ISHPluginSettingsForm(namespace: namespace())

        XCTAssertEqual(form.rootFields.map(\.label), ["count", "enabled", "mode"])
        XCTAssertEqual(form.groups.map(\.name), ["nested"])
        XCTAssertEqual(form.groups.first?.fields.map(\.label), ["label"])
        XCTAssertEqual(
            form.visibleLeafFields.map(\.path),
            [["count"], ["enabled"], ["mode"], ["nested", "label"]]
        )
    }

    func testDraftTreatsPresenceAsOverrideAndStagesReset() throws {
        let descriptor = namespace(
            user: .object(["nested": .object(["label": .string("custom")])]),
            value: .object([
                "count": .number(2),
                "enabled": .bool(true),
                "mode": .string("safe"),
                "nested": .object(["label": .string("custom")])
            ]),
            base: .object(["count": .number(2)])
        )
        let form = try ISHPluginSettingsForm(namespace: descriptor)
        var draft = try ISHPluginSettingsDraft(namespace: descriptor, form: form)

        XCTAssertFalse(draft.isOverridden(at: ["count"]))
        draft.set(.number(2), at: ["count"])
        XCTAssertTrue(draft.isOverridden(at: ["count"]))

        draft.reset(["nested", "label"])
        let label = try XCTUnwrap(
            form.visibleLeafFields.first { $0.path == ["nested", "label"] }
        )
        XCTAssertEqual(draft.effectiveValue(for: label), .string("phone"))
        XCTAssertEqual(
            draft.operations,
            [
                .set(path: ["count"], value: .number(2)),
                .unset(path: ["nested", "label"])
            ]
        )
    }

    func testDraftRebasesOnlyStagedIntentOntoFreshRevision() throws {
        let original = namespace(
            user: .object(["count": .number(4)]),
            value: .object([
                "count": .number(4),
                "enabled": .bool(true),
                "mode": .string("safe"),
                "nested": .object(["label": .string("phone")])
            ]),
            revision: 1
        )
        let form = try ISHPluginSettingsForm(namespace: original)
        var draft = try ISHPluginSettingsDraft(namespace: original, form: form)
        draft.set(.number(5), at: ["count"])
        draft.set(.bool(false), at: ["enabled"])

        let refreshed = namespace(
            user: .object([
                "count": .number(6),
                "mode": .string("fast")
            ]),
            value: .object([
                "count": .number(6),
                "enabled": .bool(true),
                "mode": .string("fast"),
                "nested": .object(["label": .string("phone")])
            ]),
            revision: 2
        )
        let rebased = try draft.rebased(onto: refreshed, form: form)
        let mode = try XCTUnwrap(form.visibleLeafFields.first { $0.path == ["mode"] })

        XCTAssertEqual(rebased.expectedRevision, 2)
        XCTAssertEqual(rebased.effectiveValue(for: mode), .string("fast"))
        XCTAssertEqual(
            rebased.operations,
            [
                .set(path: ["count"], value: .number(5)),
                .set(path: ["enabled"], value: .bool(false))
            ]
        )
    }

    func testDraftValidationRejectsOutOfStepNumber() throws {
        let descriptor = namespace()
        let form = try ISHPluginSettingsForm(namespace: descriptor)
        var draft = try ISHPluginSettingsDraft(namespace: descriptor, form: form)

        draft.set(.number(2.5), at: ["count"])

        XCTAssertEqual(draft.validationIssues(in: form), ["count 必须按步长 1 取值。"])
    }

    private func namespace(
        user: JSONValue? = .object([:]),
        value: JSONValue = .object([
            "count": .number(2),
            "enabled": .bool(true),
            "mode": .string("safe"),
            "nested": .object(["label": .string("phone")])
        ]),
        base: JSONValue? = nil,
        revision: Int = 0
    ) -> ISHPluginSettingsNamespace {
        ISHPluginSettingsNamespace(
            ns: "plugin-demo",
            schema: schema,
            value: value,
            base: base,
            user: user,
            revision: revision,
            applies: .live,
            secrets: [],
            editable: true,
            unsupportedReason: nil
        )
    }

    private var schema: JSONValue {
        .object([
            "uid": .number(8),
            "refs": .object([
                "1": .object([
                    "type": .string("boolean"),
                    "meta": .object(["default": .bool(true)])
                ]),
                "2": .object([
                    "type": .string("number"),
                    "meta": .object([
                        "min": .number(0),
                        "max": .number(10),
                        "step": .number(1),
                        "default": .number(2)
                    ])
                ]),
                "3": .object([
                    "type": .string("string"),
                    "meta": .object(["default": .string("phone")])
                ]),
                "4": .object([
                    "type": .string("object"),
                    "meta": .object(["default": .object([:])]),
                    "dict": .object(["label": .number(3)])
                ]),
                "5": .object([
                    "type": .string("const"),
                    "meta": .object(["description": .string("Fast")]),
                    "value": .string("fast")
                ]),
                "6": .object([
                    "type": .string("const"),
                    "meta": .object(["description": .string("Safe")]),
                    "value": .string("safe")
                ]),
                "7": .object([
                    "type": .string("union"),
                    "meta": .object(["default": .string("safe")]),
                    "list": .array([.number(5), .number(6)])
                ]),
                "8": .object([
                    "type": .string("object"),
                    "meta": .object(["default": .object([:])]),
                    "dict": .object([
                        "enabled": .number(1),
                        "count": .number(2),
                        "nested": .number(4),
                        "mode": .number(7)
                    ])
                ])
            ])
        ])
    }
}
