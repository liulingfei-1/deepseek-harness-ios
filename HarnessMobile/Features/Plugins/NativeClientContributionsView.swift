import SwiftUI

struct NativeClientContributionsView: View {
    @Environment(AppModel.self) private var model
    let pluginID: String

    var body: some View {
        Group {
            if let plugin {
                List {
                    Section {
                        LabeledContent("Scope", value: plugin.scope.rawValue)
                        LabeledContent(
                            "Activation",
                            value: plugin.activationGeneration.formatted()
                        )
                        LabeledContent("Digest", value: String(plugin.sourceDigest.prefix(12)))
                            .font(.body.monospaced())
                        HarnessStatusPill(
                            title: "第 \(plugin.activationGeneration.formatted()) 代",
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: .accentColor
                        )
                    } header: {
                        Label("Native Client", systemImage: "puzzlepiece.extension")
                    }

                    ForEach(plugin.contributions.inspectors) { inspector in
                        NativeClientInspectorSection(
                            plugin: plugin,
                            inspector: inspector
                        )
                    }

                    if !plugin.contributions.settings.isEmpty {
                        Section {
                            ForEach(plugin.contributions.settings) { contribution in
                                NavigationLink {
                                    PluginSettingsNamespaceView(
                                        namespaceID: contribution.namespace
                                    )
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(contribution.title)
                                            Text(contribution.namespace)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        HarnessIconTile(systemImage: "slider.horizontal.3", tint: .accentColor, size: 28)
                                    }
                                }
                                .accessibilityIdentifier(
                                    "native-client-settings-link-\(plugin.pluginId)-\(contribution.id)"
                                )
                            }
                        } header: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                    }

                    if !plugin.contributions.commands.isEmpty {
                        Section {
                            ForEach(plugin.contributions.commands) { command in
                                HStack(alignment: .top, spacing: 10) {
                                    HarnessIconTile(systemImage: "terminal", tint: .accentColor, size: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("/\(command.name)")
                                            .font(.body.monospaced().weight(.semibold))
                                        Text(command.description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let inputHint = command.inputHint {
                                            Text(inputHint)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.tertiary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(
                                    "native-client-command-\(plugin.pluginId)-\(command.name)"
                                )
                            }
                        } header: {
                            Label("Commands", systemImage: "terminal")
                        }
                    }
                }
                .harnessCompactListChrome()
                .accessibilityIdentifier("native-client-plugin-\(plugin.pluginId)")
            } else {
                ContentUnavailableView(
                    "原生扩展未运行",
                    systemImage: "puzzlepiece.extension",
                    description: Text("插件可能已停止、被替换，或其声明未通过校验。")
                )
            }
        }
        .navigationTitle(plugin?.packageName ?? pluginID)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var plugin: ISHNativeClientPlugin? {
        model.ishNativeClientPlugins.first { $0.pluginId == pluginID }
    }
}

private struct NativeClientInspectorSection: View {
    @Environment(AppModel.self) private var model
    let plugin: ISHNativeClientPlugin
    let inspector: ISHNativeClientInspectorContribution
    @State private var state = NativeClientInspectorLoadState.idle

    var body: some View {
        Section {
            inspectorContent
        } header: {
            HStack(spacing: 8) {
                Text(inspector.title)
                Spacer(minLength: 8)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("刷新 \(inspector.title)")
                .accessibilityIdentifier(
                    "native-client-inspector-refresh-\(plugin.pluginId)-\(inspector.id)"
                )
            }
        } footer: {
            if let description = inspector.description {
                Text(description)
            }
        }
        .accessibilityIdentifier(
            "native-client-inspector-\(plugin.pluginId)-\(inspector.id)"
        )
        .task(id: LoadIdentity(
            generation: plugin.activationGeneration,
            inspectorID: inspector.id
        )) {
            await load()
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 10) {
                HarnessIconTile(systemImage: "arrow.triangle.2.circlepath", tint: .accentColor, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在读取")
                        .foregroundStyle(.secondary)
                    Text("从本机插件贡献读取最新值")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        case let .loaded(value):
            NativeClientValueView(value: value, renderer: inspector.renderer)
        case let .failed(message):
            HStack(alignment: .top, spacing: 10) {
                HarnessIconTile(systemImage: "exclamationmark.triangle.fill", tint: .orange, size: 28)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let value = try await model.invokeISHNativeClientInspector(
                pluginID: plugin.pluginId,
                inspectorID: inspector.id
            )
            guard !Task.isCancelled else { return }
            state = .loaded(value)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private struct LoadIdentity: Hashable {
        let generation: UInt64
        let inspectorID: String
    }
}

private enum NativeClientInspectorLoadState: Equatable {
    case idle
    case loading
    case loaded(JSONValue)
    case failed(String)
}

private struct NativeClientValueView: View {
    let value: JSONValue
    let renderer: ISHNativeClientRenderer

    var body: some View {
        switch renderer {
        case .keyValue:
            if let object = value.objectValue, !object.isEmpty {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: bounded(object[key]?.displayText ?? "null"))
                        .textSelection(.enabled)
                }
            } else {
                Text(bounded(value.displayText))
                    .textSelection(.enabled)
            }
        case .markdown:
            Text(markdownText)
                .textSelection(.enabled)
        }
    }

    private var markdownText: AttributedString {
        let text = bounded(value.stringValue ?? value.displayText)
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private func bounded(_ value: String) -> String {
        String(decoding: value.utf8.prefix(16 * 1_024), as: UTF8.self)
    }
}
