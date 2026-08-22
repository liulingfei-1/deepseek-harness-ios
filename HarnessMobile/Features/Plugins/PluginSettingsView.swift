import SwiftUI

struct PluginSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var isRefreshing = false

    var body: some View {
        List {
            if let snapshot = model.ishPluginSettingsSnapshot {
                Section("Settings Provider") {
                    LabeledContent("命名空间", value: "\(snapshot.namespaces.count)")
                    LabeledContent("写入", value: snapshot.writable ? "可用" : "只读")
                    LabeledContent("配置文件", value: snapshot.hasDocument ? "已挂载" : "未挂载")
                }

                if filteredNamespaces.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "没有插件设置" : "没有匹配的设置",
                        systemImage: "slider.horizontal.3",
                        description: Text(
                            query.isEmpty
                                ? "启用注册 Settings namespace 的 Host 插件后会显示在这里。"
                                : "尝试搜索其他 namespace。"
                        )
                    )
                } else {
                    Section("命名空间") {
                        ForEach(filteredNamespaces) { namespace in
                            NavigationLink {
                                PluginSettingsNamespaceView(namespaceID: namespace.ns)
                            } label: {
                                PluginSettingsNamespaceRow(namespace: namespace)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Settings Host 未就绪", systemImage: "terminal")
                } description: {
                    Text("启动本机 iSH Cordis Host 后可读取插件设置。")
                } actions: {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("启动 Host", systemImage: "play.fill")
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .accessibilityIdentifier("ish-plugin-settings-list")
        .navigationTitle("插件设置")
        .searchable(text: $query, prompt: "搜索 namespace")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .accessibilityLabel("刷新插件设置")
                .accessibilityIdentifier("ish-plugin-settings-refresh")
                .help("刷新插件设置")
            }
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private var filteredNamespaces: [ISHPluginSettingsNamespace] {
        let namespaces = (model.ishPluginSettingsSnapshot?.namespaces ?? [])
            .sorted { $0.ns.localizedStandardCompare($1.ns) == .orderedAscending }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return namespaces }
        return namespaces.filter { namespace in
            namespace.ns.lowercased().contains(normalized)
                || namespace.applies.displayName.lowercased().contains(normalized)
                || (namespace.unsupportedReason ?? "").lowercased().contains(normalized)
        }
    }

    private var hostIsRunning: Bool {
        if case .running = model.ishPluginHostState { return true }
        return false
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if hostIsRunning {
            _ = await model.refreshISHPluginSettings()
        } else {
            _ = await model.startISHPluginHost()
        }
    }
}

private struct PluginSettingsNamespaceRow: View {
    let namespace: ISHPluginSettingsNamespace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: namespace.editable ? "slider.horizontal.3" : "lock.fill")
                .foregroundStyle(namespace.editable ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(namespace.ns)
                    .font(.body.monospaced())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(namespace.applies.displayName, systemImage: namespace.applies.systemImage)
                    Text("rev \(namespace.revision)")
                        .monospacedDigit()
                    if !namespace.secrets.isEmpty {
                        Label(
                            "\(namespace.secrets.count)",
                            systemImage: "key.fill"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if namespace.user?.objectValue?.isEmpty == false {
                Text("已覆盖")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ish-plugin-settings-namespace-\(namespace.ns)")
    }
}

struct PluginSettingsNamespaceView: View {
    @Environment(AppModel.self) private var model

    let namespaceID: String

    @State private var form: ISHPluginSettingsForm?
    @State private var draft: ISHPluginSettingsDraft?
    @State private var notice: EditorNotice?
    @State private var hasConflict = false
    @State private var isSaving = false

    var body: some View {
        Group {
            if let namespace {
                Form {
                    namespaceStatusSection(namespace)

                    if hasConflict {
                        conflictSection(namespace)
                    }

                    if let notice {
                        Section {
                            Label(notice.message, systemImage: notice.systemImage)
                                .foregroundStyle(notice.tint)
                        }
                    }

                    if namespace.editable, providerIsWritable {
                        if let form, let draftBinding = Binding($draft) {
                            PluginSettingsFormSections(
                                form: form,
                                draft: draftBinding,
                                isDisabled: isSaving
                            )
                        } else {
                            Section {
                                ProgressView("读取 schema")
                            }
                        }
                    } else {
                        readOnlySection(namespace)
                    }

                    if !namespace.secrets.isEmpty {
                        PluginSettingsSecretsSection(secrets: namespace.secrets)
                    }
                }
                .accessibilityIdentifier("ish-plugin-settings-editor")
            } else {
                ContentUnavailableView(
                    "设置已释放",
                    systemImage: "slider.horizontal.3",
                    description: Text("对应插件可能已停用、卸载或重启。")
                )
            }
        }
        .navigationTitle(namespaceID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if namespace?.editable == true, providerIsWritable, draft != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        discardDraft()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(isSaving || draft?.isDirty != true)
                    .accessibilityLabel("放弃设置草稿")
                    .accessibilityIdentifier("ish-plugin-settings-discard")
                    .help("放弃设置草稿")

                    Button {
                        saveDraft()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("保存插件设置")
                    .accessibilityIdentifier("ish-plugin-settings-save")
                    .help("保存插件设置")
                }
            }
        }
        .task {
            if namespace == nil {
                _ = await model.refreshISHPluginSettings()
            }
            seedFromCurrentNamespace(force: false)
        }
        .onChange(of: namespace?.revision) {
            synchronizeExternalRevision()
        }
    }

    private var namespace: ISHPluginSettingsNamespace? {
        model.ishPluginSettingsSnapshot?.namespaces.first { $0.ns == namespaceID }
    }

    private var providerIsWritable: Bool {
        model.ishPluginSettingsSnapshot?.writable == true
    }

    private var canSave: Bool {
        guard !isSaving,
              !hasConflict,
              let form,
              let draft,
              draft.isDirty,
              draft.operations.count <= 256 else { return false }
        return draft.validationIssues(in: form).isEmpty
    }

    @ViewBuilder
    private func namespaceStatusSection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section("状态") {
            LabeledContent("Namespace", value: namespace.ns)
            LabeledContent("Revision", value: "\(namespace.revision)")
            LabeledContent("生效", value: namespace.applies.displayName)
            LabeledContent("编辑", value: namespace.editable && providerIsWritable ? "可用" : "只读")
            if let draft {
                LabeledContent("草稿覆盖", value: "\(draft.overriddenFieldCount)")
            }
        }
    }

    @ViewBuilder
    private func conflictSection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section {
            Label("设置已在其他位置更新到 revision \(namespace.revision)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Button {
                rebaseDraft()
            } label: {
                Label("在新版本上重放草稿", systemImage: "arrow.triangle.branch")
            }
            Button(role: .destructive) {
                discardDraft()
            } label: {
                Label("放弃草稿并重新载入", systemImage: "trash")
            }
        } header: {
            Text("Revision 冲突")
        }
    }

    @ViewBuilder
    private func readOnlySection(_ namespace: ISHPluginSettingsNamespace) -> some View {
        Section {
            Label(
                namespace.unsupportedReason ?? "此 namespace 当前不能从原生表单写入。",
                systemImage: "lock.fill"
            )
                .foregroundStyle(.secondary)
            if namespace.value != .null {
                Text(namespace.value.displayText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("只读配置")
        }
    }

    @MainActor
    private func seedFromCurrentNamespace(force: Bool) {
        guard let namespace else { return }
        if !force, draft != nil { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            form = parsed
            draft = try ISHPluginSettingsDraft(namespace: namespace, form: parsed)
            hasConflict = false
            notice = nil
        } catch {
            form = nil
            draft = nil
            notice = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func synchronizeExternalRevision() {
        guard let namespace else { return }
        guard let draft else {
            seedFromCurrentNamespace(force: true)
            return
        }
        guard namespace.revision != draft.expectedRevision else { return }
        if draft.isDirty {
            hasConflict = true
            notice = .warning("当前草稿仍保留，保存前需要处理 revision 冲突。")
        } else {
            seedFromCurrentNamespace(force: true)
        }
    }

    @MainActor
    private func discardDraft() {
        seedFromCurrentNamespace(force: true)
    }

    @MainActor
    private func rebaseDraft() {
        guard let namespace, let draft else { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            self.form = parsed
            self.draft = try draft.rebased(onto: namespace, form: parsed)
            hasConflict = false
            notice = .success("草稿已重放到 revision \(namespace.revision)。")
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    private func saveDraft() {
        guard canSave, let draft else { return }
        let operations = draft.operations
        isSaving = true
        notice = nil

        Task { @MainActor in
            defer { isSaving = false }
            do {
                let updated = try await model.mutateISHPluginSettings(
                    namespace: draft.namespace,
                    operations: operations,
                    expectedRevision: draft.expectedRevision
                )
                let updatedForm = try ISHPluginSettingsForm(namespace: updated)
                self.form = updatedForm
                self.draft = try ISHPluginSettingsDraft(namespace: updated, form: updatedForm)
                hasConflict = false
                notice = .success(
                    updated.applies == .live
                        ? "设置已生效。"
                        : "设置已保存，将在插件重启后生效。"
                )
            } catch let error as ISHPluginHostError {
                if error.settingsConflict != nil {
                    hasConflict = true
                    notice = .warning("保存被 revision fence 拒绝，草稿未丢失。")
                } else {
                    notice = .error(error.localizedDescription)
                }
            } catch {
                notice = .error(error.localizedDescription)
            }

        }
    }
}

struct NativeAgentPluginSettingsView: View {
    @Environment(AppModel.self) private var model

    let pluginID: String

    @State private var form: ISHPluginSettingsForm?
    @State private var draft: ISHPluginSettingsDraft?
    @State private var notice: EditorNotice?
    @State private var isSaving = false

    var body: some View {
        Group {
            if let plugin, plugin.settings != nil {
                Form {
                    Section("运行方式") {
                        LabeledContent("插件", value: plugin.name)
                        LabeledContent("生效", value: "立即替换运行时贡献")
                        LabeledContent("存储", value: "App 本地插件注册表")
                    }

                    if let notice {
                        Section {
                            Label(notice.message, systemImage: notice.systemImage)
                                .foregroundStyle(notice.tint)
                        }
                    }

                    if let form, let draftBinding = Binding($draft) {
                        PluginSettingsFormSections(
                            form: form,
                            draft: draftBinding,
                            isDisabled: isSaving
                        )
                    } else {
                        Section {
                            ProgressView("读取原生设置 schema")
                        }
                    }

                    if let defaults = plugin.settings?.defaults {
                        Section("默认值") {
                            Button {
                                save(values: defaults, successMessage: "已恢复插件默认设置。")
                            } label: {
                                Label("恢复全部默认值", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(isSaving || plugin.settings?.values == defaults)
                        }
                    }
                }
                .accessibilityIdentifier("native-agent-settings-editor")
            } else {
                ContentUnavailableView(
                    "没有可编辑设置",
                    systemImage: "slider.horizontal.3",
                    description: Text("插件可能已卸载，或源码没有声明可迁移的设置 schema。")
                )
            }
        }
        .navigationTitle(plugin?.name ?? "原生插件设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if draft != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        seed(force: true)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(isSaving || draft?.isDirty != true)
                    .accessibilityLabel("放弃设置草稿")
                    .help("放弃设置草稿")

                    Button {
                        saveDraft()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("保存原生插件设置")
                    .help("保存原生插件设置")
                }
            }
        }
        .task {
            seed(force: false)
        }
    }

    private var plugin: NativeAgentCompiledPlugin? {
        model.nativeAgentPlugins.first { $0.id == pluginID }
    }

    private var namespace: ISHPluginSettingsNamespace? {
        guard let settings = plugin?.settings else { return nil }
        return ISHPluginSettingsNamespace(
            ns: pluginID,
            schema: settings.schema,
            value: settings.values,
            base: settings.defaults,
            user: settings.values,
            revision: 1,
            applies: .live,
            secrets: [],
            editable: true,
            unsupportedReason: nil
        )
    }

    private var canSave: Bool {
        guard !isSaving,
              let form,
              let draft,
              draft.isDirty,
              draft.operations.count <= 256 else { return false }
        return draft.validationIssues(in: form).isEmpty
    }

    @MainActor
    private func seed(force: Bool) {
        guard let namespace else { return }
        if !force, draft != nil { return }
        do {
            let parsed = try ISHPluginSettingsForm(namespace: namespace)
            form = parsed
            draft = try ISHPluginSettingsDraft(namespace: namespace, form: parsed)
            notice = nil
        } catch {
            form = nil
            draft = nil
            notice = .error(error.localizedDescription)
        }
    }

    private func saveDraft() {
        guard canSave,
              let settings = plugin?.settings,
              let draft else { return }
        let values = ISHPluginSettingsValue.merging(
            base: settings.defaults,
            overrides: draft.user
        )
        save(values: values, successMessage: "原生插件设置已生效。")
    }

    private func save(values: JSONValue, successMessage: String) {
        guard !isSaving else { return }
        isSaving = true
        notice = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await model.updateNativeAgentPluginSettings(id: pluginID, values: values)
                seed(force: true)
                notice = .success(successMessage)
            } catch {
                notice = .error(error.localizedDescription)
            }
        }
    }
}

private struct PluginSettingsFormSections: View {
    let form: ISHPluginSettingsForm
    @Binding var draft: ISHPluginSettingsDraft
    let isDisabled: Bool

    var body: some View {
        if !form.rootFields.isEmpty {
            Section("配置") {
                ForEach(form.rootFields) { leaf in
                    PluginSettingsFieldEditor(
                        leaf: leaf,
                        draft: $draft,
                        isDisabled: isDisabled
                    )
                }
            }
        }

        ForEach(form.groups) { group in
            Section {
                ForEach(group.fields) { leaf in
                    PluginSettingsFieldEditor(
                        leaf: leaf,
                        draft: $draft,
                        isDisabled: isDisabled
                    )
                }
            } header: {
                Text(group.name)
            } footer: {
                if let help = group.description ?? group.comment {
                    Text(help)
                }
            }
        }

        let issues = draft.validationIssues(in: form)
        if !issues.isEmpty || draft.operations.count > 256 {
            Section("校验") {
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if draft.operations.count > 256 {
                    Label("一次最多写入 256 个字段。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct PluginSettingsFieldEditor: View {
    let leaf: ISHPluginSettingsLeaf
    @Binding var draft: ISHPluginSettingsDraft
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(leaf.label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if draft.isOverridden(at: leaf.field.path) {
                    Text("覆盖")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 4))
                    Button {
                        var updated = draft
                        updated.reset(leaf.field.path)
                        draft = updated
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled || leaf.disabled)
                    .accessibilityLabel("重置 \(leaf.label)")
                    .help("重置为继承值")
                } else {
                    Text("继承")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            fieldControl
                .disabled(isDisabled || leaf.disabled)

            if let help = leaf.field.description ?? leaf.field.comment {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("ish-plugin-setting-\(leaf.field.path.joined(separator: "."))")
    }

    @ViewBuilder
    private var fieldControl: some View {
        switch leaf.field.kind {
        case .boolean:
            Toggle("值", isOn: booleanBinding)
                .labelsHidden()
                .accessibilityLabel(leaf.label)
        case let .number(minimum, maximum, step):
            numberControl(minimum: minimum, maximum: maximum, step: step)
        case .string:
            TextField("值", text: stringBinding, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case let .selection(options):
            if options.count <= 3 {
                Picker("值", selection: selectionBinding(options)) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("值", selection: selectionBinding(options)) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }
        case .object:
            EmptyView()
        }
    }

    @ViewBuilder
    private func numberControl(
        minimum: Double?,
        maximum: Double?,
        step: Double?
    ) -> some View {
        let effectiveStep = step.flatMap { $0 > 0 ? $0 : nil } ?? 1
        if let minimum, let maximum, minimum <= maximum {
            Stepper(value: numberBinding, in: minimum...maximum, step: effectiveStep) {
                numberTextField
            }
        } else {
            Stepper(value: numberBinding, step: effectiveStep) {
                numberTextField
            }
        }
    }

    private var numberTextField: some View {
        TextField(
            "值",
            value: numberBinding,
            format: .number.precision(.fractionLength(0...6))
        )
        .keyboardType(.numbersAndPunctuation)
        .multilineTextAlignment(.trailing)
    }

    private var booleanBinding: Binding<Bool> {
        Binding(
            get: {
                guard case let .bool(value)? = draft.effectiveValue(for: leaf.field) else {
                    return false
                }
                return value
            },
            set: { update(.bool($0)) }
        )
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: {
                guard case let .number(value)? = draft.effectiveValue(for: leaf.field) else {
                    return 0
                }
                return value
            },
            set: { update(.number($0)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                guard case let .string(value)? = draft.effectiveValue(for: leaf.field) else {
                    return ""
                }
                return value
            },
            set: { update(.string($0)) }
        )
    }

    private func selectionBinding(_ options: [ISHPluginSettingsOption]) -> Binding<String> {
        Binding(
            get: {
                let value = draft.effectiveValue(for: leaf.field)
                return options.first(where: { $0.value == value })?.id ?? options.first?.id ?? ""
            },
            set: { selectedID in
                guard let value = options.first(where: { $0.id == selectedID })?.value else { return }
                update(value)
            }
        )
    }

    private func update(_ value: JSONValue) {
        var updated = draft
        updated.set(value, at: leaf.field.path)
        draft = updated
    }
}

private struct PluginSettingsSecretsSection: View {
    let secrets: [ISHPluginSettingsSecret]

    var body: some View {
        Section("受保护字段") {
            ForEach(secrets, id: \.self) { secret in
                LabeledContent(secret.path.joined(separator: " / ")) {
                    Label(
                        secret.set ? "已配置" : "未配置",
                        systemImage: secret.set ? "checkmark.shield.fill" : "shield"
                    )
                    .foregroundStyle(secret.set ? Color.green : Color.secondary)
                }
            }
        }
    }
}

private struct EditorNotice: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String

    static func success(_ message: String) -> Self { Self(kind: .success, message: message) }
    static func warning(_ message: String) -> Self { Self(kind: .warning, message: message) }
    static func error(_ message: String) -> Self { Self(kind: .error, message: message) }

    var systemImage: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private extension ISHPluginSettingsApplies {
    var displayName: String {
        switch self {
        case .live: "立即生效"
        case .restart: "重启后生效"
        }
    }

    var systemImage: String {
        switch self {
        case .live: "bolt.fill"
        case .restart: "arrow.clockwise"
        }
    }
}
