import Foundation

enum ISHPluginSettingsSchemaError: LocalizedError, Sendable, Equatable {
    case missingSchema
    case malformedEnvelope
    case missingReference(String)
    case recursiveReference(String)
    case unsupportedType(String)
    case invalidConstantUnion

    var errorDescription: String? {
        switch self {
        case .missingSchema:
            return "这个配置分节没有可读取的 schema。"
        case .malformedEnvelope:
            return "配置 schema 的序列化结构无效。"
        case let .missingReference(reference):
            return "配置 schema 缺少引用 \(reference)。"
        case let .recursiveReference(reference):
            return "配置 schema 包含当前不支持的递归引用 \(reference)。"
        case let .unsupportedType(type):
            return "当前不支持 \(type) 类型的动态配置。"
        case .invalidConstantUnion:
            return "选项 schema 必须完全由常量组成。"
        }
    }
}

struct ISHPluginSettingsForm: Sendable, Equatable {
    let fields: [ISHPluginSettingsField]
    let rootFields: [ISHPluginSettingsLeaf]
    let groups: [ISHPluginSettingsGroup]
    let visibleLeafFields: [ISHPluginSettingsField]

    init(namespace: ISHPluginSettingsNamespace) throws {
        guard let schema = namespace.schema else {
            throw ISHPluginSettingsSchemaError.missingSchema
        }
        self = try ISHPluginSettingsSchemaParser.parse(schema)
    }

    fileprivate init(fields: [ISHPluginSettingsField]) {
        var rootFields: [ISHPluginSettingsLeaf] = []
        var groups: [ISHPluginSettingsGroup] = []

        for field in fields where !field.hidden {
            switch field.kind {
            case let .object(children):
                let leaves = Self.leaves(
                    in: children,
                    relativeTo: field.path,
                    ancestorDisabled: field.disabled
                )
                guard !leaves.isEmpty else { continue }
                groups.append(
                    ISHPluginSettingsGroup(
                        path: field.path,
                        name: field.name,
                        description: field.description,
                        comment: field.comment,
                        fields: leaves
                    )
                )
            default:
                rootFields.append(
                    ISHPluginSettingsLeaf(
                        field: field,
                        label: field.name,
                        disabled: field.disabled
                    )
                )
            }
        }

        self.fields = fields
        self.rootFields = rootFields
        self.groups = groups
        visibleLeafFields = rootFields.map(\.field)
            + groups.flatMap { $0.fields.map(\.field) }
    }

    private static func leaves(
        in fields: [ISHPluginSettingsField],
        relativeTo groupPath: [String],
        ancestorDisabled: Bool
    ) -> [ISHPluginSettingsLeaf] {
        var output: [ISHPluginSettingsLeaf] = []
        for field in fields where !field.hidden {
            let disabled = ancestorDisabled || field.disabled
            switch field.kind {
            case let .object(children):
                output.append(
                    contentsOf: leaves(
                        in: children,
                        relativeTo: groupPath,
                        ancestorDisabled: disabled
                    )
                )
            default:
                let relativePath = field.path.dropFirst(groupPath.count)
                output.append(
                    ISHPluginSettingsLeaf(
                        field: field,
                        label: relativePath.joined(separator: " / "),
                        disabled: disabled
                    )
                )
            }
        }
        return output
    }
}

struct ISHPluginSettingsLeaf: Sendable, Equatable, Identifiable {
    var id: [String] { field.path }

    let field: ISHPluginSettingsField
    let label: String
    let disabled: Bool
}

struct ISHPluginSettingsGroup: Sendable, Equatable, Identifiable {
    var id: [String] { path }

    let path: [String]
    let name: String
    let description: String?
    let comment: String?
    let fields: [ISHPluginSettingsLeaf]
}

struct ISHPluginSettingsOption: Sendable, Equatable, Identifiable {
    let id: String
    let value: JSONValue
    let label: String
}

struct ISHPluginSettingsField: Sendable, Equatable, Identifiable {
    indirect enum Kind: Sendable, Equatable {
        case boolean
        case number(minimum: Double?, maximum: Double?, step: Double?)
        case string
        case selection([ISHPluginSettingsOption])
        case object([ISHPluginSettingsField])
    }

    var id: [String] { path }

    let path: [String]
    let name: String
    let description: String?
    let comment: String?
    let defaultValue: JSONValue?
    let required: Bool
    let disabled: Bool
    let hidden: Bool
    let kind: Kind
}

enum ISHPluginSettingsValue {
    static func value(at path: [String], in root: JSONValue?) -> JSONValue? {
        guard var cursor = root else { return nil }
        for segment in path {
            guard case let .object(object) = cursor,
                  let child = object[segment] else {
                return nil
            }
            cursor = child
        }
        return cursor
    }

    static func contains(path: [String], in root: JSONValue?) -> Bool {
        guard !path.isEmpty else { return root != nil }
        return value(at: path, in: root) != nil
    }
}

extension ISHPluginSettingsNamespace {
    func resolvedValue(at path: [String]) -> JSONValue? {
        ISHPluginSettingsValue.value(at: path, in: value)
    }

    func baseValue(at path: [String]) -> JSONValue? {
        ISHPluginSettingsValue.value(at: path, in: base)
    }

    func userValue(at path: [String]) -> JSONValue? {
        ISHPluginSettingsValue.value(at: path, in: user)
    }

    func isUserOverridden(at path: [String]) -> Bool {
        ISHPluginSettingsValue.contains(path: path, in: user)
    }
}

private enum ISHPluginSettingsSchemaParser {
    static func parse(_ schema: JSONValue) throws -> ISHPluginSettingsForm {
        guard case let .object(envelope) = schema,
              let uid = envelope["uid"]?.schemaReference,
              case let .object(refs)? = envelope["refs"] else {
            throw ISHPluginSettingsSchemaError.malformedEnvelope
        }

        var parser = Parser(refs: refs)
        let root = try parser.node(reference: uid, path: [])
        guard case let .object(fields) = root.kind else {
            throw ISHPluginSettingsSchemaError.unsupportedType("root")
        }
        return ISHPluginSettingsForm(fields: fields)
    }

    private struct Parser {
        let refs: [String: JSONValue]
        var activeReferences: Set<String> = []

        mutating func node(reference: String, path: [String]) throws -> ISHPluginSettingsField {
            guard activeReferences.insert(reference).inserted else {
                throw ISHPluginSettingsSchemaError.recursiveReference(reference)
            }
            defer { activeReferences.remove(reference) }

            guard case let .object(node)? = refs[reference],
                  let type = node["type"]?.stringValue else {
                throw ISHPluginSettingsSchemaError.missingReference(reference)
            }
            let meta = node["meta"]?.objectValue ?? [:]
            let fieldName = path.last ?? "root"
            let common = CommonField(
                path: path,
                name: fieldName,
                description: localizedText(meta["description"]),
                comment: meta["comment"]?.stringValue,
                defaultValue: meta["default"],
                required: meta["required"]?.boolValue ?? false,
                disabled: meta["disabled"]?.boolValue ?? false,
                hidden: (meta["hidden"]?.boolValue ?? false) || meta["role"]?.stringValue == "secret"
            )

            let kind: ISHPluginSettingsField.Kind
            switch type {
            case "boolean":
                kind = .boolean
            case "number":
                kind = .number(
                    minimum: meta["min"]?.numberValue,
                    maximum: meta["max"]?.numberValue,
                    step: meta["step"]?.numberValue
                )
            case "string":
                kind = .string
            case "object":
                guard case let .object(dict)? = node["dict"] else {
                    throw ISHPluginSettingsSchemaError.malformedEnvelope
                }
                var fields: [ISHPluginSettingsField] = []
                fields.reserveCapacity(dict.count)
                for key in dict.keys.sorted() {
                    guard let childReference = dict[key]?.schemaReference else {
                        throw ISHPluginSettingsSchemaError.malformedEnvelope
                    }
                    fields.append(try self.node(reference: childReference, path: path + [key]))
                }
                kind = .object(fields)
            case "union":
                guard case let .array(list)? = node["list"], !list.isEmpty else {
                    throw ISHPluginSettingsSchemaError.invalidConstantUnion
                }
                var options: [ISHPluginSettingsOption] = []
                options.reserveCapacity(list.count)
                for member in list {
                    guard let memberReference = member.schemaReference,
                          case let .object(constant)? = refs[memberReference],
                          constant["type"]?.stringValue == "const",
                          let value = constant["value"] else {
                        throw ISHPluginSettingsSchemaError.invalidConstantUnion
                    }
                    let constantMeta = constant["meta"]?.objectValue ?? [:]
                    options.append(
                        ISHPluginSettingsOption(
                            id: memberReference,
                            value: value,
                            label: localizedText(constantMeta["description"]) ?? value.displayText
                        )
                    )
                }
                kind = .selection(options)
            case "array", "dict", "tuple", "intersect", "transform", "lazy":
                throw ISHPluginSettingsSchemaError.unsupportedType(type)
            default:
                throw ISHPluginSettingsSchemaError.unsupportedType(type)
            }

            return ISHPluginSettingsField(
                path: common.path,
                name: common.name,
                description: common.description,
                comment: common.comment,
                defaultValue: common.defaultValue,
                required: common.required,
                disabled: common.disabled,
                hidden: common.hidden,
                kind: kind
            )
        }

        private func localizedText(_ value: JSONValue?) -> String? {
            switch value {
            case let .string(text):
                return text
            case let .object(messages):
                for key in ["zh-CN", "zh-Hans", "zh", "", "en"] {
                    if let text = messages[key]?.stringValue, !text.isEmpty { return text }
                }
                return messages.values.compactMap(\.stringValue).first
            default:
                return nil
            }
        }
    }

    private struct CommonField {
        let path: [String]
        let name: String
        let description: String?
        let comment: String?
        let defaultValue: JSONValue?
        let required: Bool
        let disabled: Bool
        let hidden: Bool
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var schemaReference: String? {
        switch self {
        case let .number(value)
            where value.isFinite && value.rounded(.towardZero) == value:
            return String(Int(value))
        case let .string(value):
            return value
        default:
            return nil
        }
    }
}
