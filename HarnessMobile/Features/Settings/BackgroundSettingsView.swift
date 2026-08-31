import SwiftUI

struct BackgroundSettingsView: View {
    @Environment(BackgroundPreferencesModel.self) private var preferences
    @State private var notificationAuthorization: BackgroundNotificationAuthorization = .notDetermined
    @State private var notificationErrorDescription: String?

    let runtimeStatus: BackgroundRuntimeStatus
    let locationSnapshot: BackgroundLocationKeepAliveSnapshot
    let systemProjection: BackgroundSystemProjection
    let requestLocationAuthorization: () -> Void

    private let notifier = BackgroundCompletionNotifier()

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            BackgroundExecutionSettingsSection(
                isEnabled: $preferences.isEnhancedBackgroundEnabled,
                isSystemSupported: isContinuedProcessingSupported
            )
            BackgroundLocationKeepAliveSettingsSection(
                isEnabled: $preferences.isBackgroundLocationKeepAliveEnabled,
                snapshot: locationSnapshot,
                requestAuthorization: requestLocationAuthorization
            )
            BackgroundLiveActivitySettingsSection(
                isEnabled: $preferences.isLiveActivityEnabled,
                isSystemSupported: isLiveActivitySupported,
                areActivitiesEnabled: areLiveActivitiesEnabled
            )
            BackgroundNotificationSettingsSection(
                isEnabled: $preferences.areTaskNotificationsEnabled,
                authorization: notificationAuthorization,
                errorDescription: notificationErrorDescription
            )
            BackgroundPrivacySettingsSection(
                isEnabled: $preferences.isPrivacyModeEnabled
            )
            BackgroundRuntimeStatusSection(
                status: runtimeStatus,
                privacyModeEnabled: preferences.isPrivacyModeEnabled,
                isContinuedProcessingSupported: isContinuedProcessingSupported,
                isLiveActivitySupported: isLiveActivitySupported,
                isLiveActivityEnabled: preferences.isLiveActivityEnabled
            )
            BackgroundSystemProjectionSection(projection: systemProjection)
            BackgroundSafetyBoundarySection()

            if let persistenceErrorDescription = preferences.persistenceErrorDescription {
                Section {
                    Text(persistenceErrorDescription)
                        .foregroundStyle(.red)
                } header: {
                    Text("偏好存储")
                } footer: {
                    Text("这项设置没有成功保存到本机。")
                }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("后台任务")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notificationAuthorization = await notifier.authorizationStatus()
        }
        .onChange(of: preferences.areTaskNotificationsEnabled) { _, isEnabled in
            guard isEnabled else { return }
            Task {
                await requestNotificationAuthorization()
            }
        }
        .onChange(of: preferences.isLiveActivityEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            Task {
                await HarnessLiveActivityManager.shared.endAll()
            }
        }
        .onChange(of: preferences.isPrivacyModeEnabled) { _, isEnabled in
            Task {
                await HarnessLiveActivityManager.shared.applyPrivacyMode(isEnabled)
            }
        }
    }

    private var isContinuedProcessingSupported: Bool {
        if #available(iOS 26.0, *) {
            true
        } else {
            false
        }
    }

    private var isLiveActivitySupported: Bool {
        HarnessLiveActivityManager.isSystemSupported
    }

    private var areLiveActivitiesEnabled: Bool {
        HarnessLiveActivityManager.shared.areActivitiesEnabled
    }

    private func requestNotificationAuthorization() async {
        do {
            notificationAuthorization = try await notifier.requestAuthorization()
            notificationErrorDescription = nil
        } catch {
            notificationAuthorization = await notifier.authorizationStatus()
            notificationErrorDescription = error.localizedDescription
        }
    }
}

private struct BackgroundSystemProjectionSection: View {
    let projection: BackgroundSystemProjection

    var body: some View {
        Section {
            HStack(spacing: HarnessTheme.Spacing.medium) {
                HarnessIconTile(systemImage: "bolt.horizontal.circle", tint: .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("活动任务")
                    Text("\(projection.activeRunCount) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HarnessStatusPill(title: tierLabel, systemImage: tierIcon, tint: tierTint)
            }
            statusRow("通知权限", value: projection.notificationAuthorization, icon: "bell.badge")
            statusRow("定位权限", value: projection.locationAuthorization, icon: "location.fill")
            statusRow(
                "实时活动权限",
                value: projection.liveActivitySupported
                    ? (projection.liveActivityEnabled ? "已启用" : "已关闭")
                    : "不可用",
                icon: "rectangle.topthird.inset.filled"
            )
            if !projection.degradedReasons.isEmpty {
                statusRow("当前降级", value: degradedLabel, icon: "exclamationmark.triangle", tint: .orange)
            }
            if !projection.degradedDetails.isEmpty {
                LabeledContent("故障证据", value: projection.degradedDetails.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            BackgroundDetailsRow(
                title: "投影范围",
                text: "这里显示所有并行任务的汇总状态。不会显示提示词、工具参数、工具输出或模型正文；降级只表示对应系统能力当前不可用。"
            )
        } header: {
            Label("当前系统投影", systemImage: "waveform.path.ecg")
        }
    }

    private var tierLabel: String {
        switch projection.survivalTier {
        case .foreground: "前台"
        case .finiteBackgroundTask: "短时后台"
        case .continuedProcessing: "Continued Processing"
        case .extendedAudio: "音频延展"
        case .extendedLocation: "定位延展"
        case .degraded: "降级"
        }
    }

    private var tierIcon: String {
        switch projection.survivalTier {
        case .foreground: "iphone"
        case .finiteBackgroundTask: "timer"
        case .continuedProcessing: "arrow.clockwise.icloud"
        case .extendedAudio: "speaker.wave.2"
        case .extendedLocation: "location.fill"
        case .degraded: "exclamationmark.triangle"
        }
    }

    private var tierTint: Color {
        switch projection.survivalTier {
        case .foreground: .secondary
        case .finiteBackgroundTask, .continuedProcessing: .blue
        case .extendedAudio, .extendedLocation: .green
        case .degraded: .orange
        }
    }

    private func statusRow(
        _ title: String,
        value: String,
        icon: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: HarnessTheme.Spacing.medium) {
            HarnessIconTile(systemImage: icon, tint: tint, size: 28)
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var degradedLabel: String {
        projection.degradedReasons.map {
            switch $0 {
            case .lowPowerMode: "低电量模式"
            case .thermalPressure: "温度压力"
            case .audioUnavailable: "音频不可用"
            case .locationUnavailable: "定位不可用"
            }
        }.sorted().joined(separator: "、")
    }
}

private struct BackgroundLiveActivitySettingsSection: View {
    @Binding var isEnabled: Bool
    let isSystemSupported: Bool
    let areActivitiesEnabled: Bool

    var body: some View {
        Section {
            if isSystemSupported {
                Toggle("实时活动", isOn: $isEnabled)
                LabeledContent(
                    "系统权限",
                    value: areActivitiesEnabled ? "已允许" : "已在系统设置中关闭"
                )
            } else {
                Toggle("实时活动", isOn: .constant(false))
                    .disabled(true)
            }
            BackgroundDetailsRow(
                title: "实时活动说明",
                text: isSystemSupported
                    ? "显示当前会话、步骤、工具和真实进度。它只投影任务状态，不会让 App 获得永久后台执行能力；关闭后会立即移除当前实时活动。"
                    : "当前设备环境不支持 ActivityKit 实时活动。"
            )
        } header: {
            Label("锁屏与灵动岛", systemImage: "rectangle.topthird.inset.filled")
        }
    }
}

private struct BackgroundExecutionSettingsSection: View {
    @Binding var isEnabled: Bool
    let isSystemSupported: Bool

    var body: some View {
        Section {
            if isSystemSupported {
                Toggle("增强后台处理", isOn: $isEnabled)
            } else {
                Toggle("增强后台处理", isOn: .constant(false))
                    .disabled(true)
            }
            BackgroundDetailsRow(
                title: "工作方式与限制",
                text: isSystemSupported
                    ? "组合使用 iOS 26 Continued Processing 与任务期间的音频/定位延展。系统后台时间配额到期时，只要延展层仍健康，就结束旧 lease、续挂新的有限 lease，并继续同一个任务和上下文；这不是模型服务商额度续期，系统仍可因资源、温度或用户操作终止 App。"
                    : "当前系统不支持 Continued Processing。iOS 18–25 下只使用系统提供的短时后台时间，不承诺持续运行。"
            )
        } header: {
            Label("后台执行", systemImage: "arrow.clockwise.icloud")
        }
    }
}

private struct BackgroundLocationKeepAliveSettingsSection: View {
    @Binding var isEnabled: Bool
    let snapshot: BackgroundLocationKeepAliveSnapshot
    let requestAuthorization: () -> Void

    var body: some View {
        Section {
            Toggle("后台粗略定位保活", isOn: $isEnabled)
            LabeledContent("定位权限", value: authorizationLabel)
            if isEnabled && (snapshot.authorization == .notDetermined || snapshot.authorization == .whenInUse) {
                Button("请求 Always 定位授权", action: requestAuthorization)
            }
            LabeledContent("当前状态", value: phaseLabel)
            BackgroundDetailsRow(
                title: "定位用途与隐私",
                text: "仅在开启此开关、已允许 Always 定位、后台停留约 15 秒且仍有任务运行时使用约 3 公里精度的位置服务。不会保存、显示或上传坐标；普通一次定位工具不会触发此授权。"
            )
        } header: {
            Label("可选定位保活", systemImage: "location.fill")
        }
    }

    private var authorizationLabel: String {
        switch snapshot.authorization {
        case .notDetermined: "尚未请求"
        case .whenInUse: "仅使用期间"
        case .always: "始终允许"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .unavailable: "不可用"
        }
    }

    private var phaseLabel: String {
        switch snapshot.phase {
        case .idle: "未运行"
        case .waitingForDelay: "等待后台延迟"
        case .waitingForPermission: "等待授权"
        case .running: "运行中"
        case .degraded: "不可用"
        }
    }
}

private struct BackgroundNotificationSettingsSection: View {
    @Binding var isEnabled: Bool
    let authorization: BackgroundNotificationAuthorization
    let errorDescription: String?

    var body: some View {
        Section {
            Toggle("任务通知", isOn: $isEnabled)
            LabeledContent("系统权限", value: authorizationLabel)
            if let errorDescription {
                Text("通知授权失败：\(errorDescription)")
                    .foregroundStyle(.red)
            } else if authorization == .denied {
                Text("通知偏好已保存，但系统权限被拒绝；在系统设置中允许通知后才能收到任务完成提醒。")
                    .foregroundStyle(.orange)
            }
            BackgroundDetailsRow(
                title: "通知说明",
                text: "仅在任务结束时发送本地通知。开启开关时才请求系统通知权限。"
            )
        } header: {
            Label("任务通知", systemImage: "bell.badge")
        }
    }

    private var authorizationLabel: String {
        switch authorization {
        case .notDetermined:
            "尚未请求"
        case .denied:
            "已拒绝"
        case .authorized:
            "已允许"
        case .unavailable:
            "不可用"
        }
    }
}

private struct BackgroundPrivacySettingsSection: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Section {
            Toggle("任务状态隐私", isOn: $isEnabled)
            BackgroundDetailsRow(
                title: "隐私显示说明",
                text: "开启后，锁屏、灵动岛状态和完成通知只显示通用任务状态，不显示会话标题、工具名称或回复内容。"
            )
        } header: {
            Label("隐私显示", systemImage: "eye.slash")
        }
    }
}

private struct BackgroundRuntimeStatusSection: View {
    let status: BackgroundRuntimeStatus
    let privacyModeEnabled: Bool
    let isContinuedProcessingSupported: Bool
    let isLiveActivitySupported: Bool
    let isLiveActivityEnabled: Bool

    var body: some View {
        Section {
            LabeledContent(
                "Continued Processing",
                value: isContinuedProcessingSupported ? "iOS 26 可用" : "当前不可用"
            )
            LabeledContent(
                "实时活动",
                value: liveActivityStatus
            )
            runtimeContent
            BackgroundDetailsRow(
                title: "状态说明",
                text: "Continued Processing 和实时活动都由 iOS 管理。实时活动只显示真实任务状态；两者都不是无限后台或常驻进程保证。"
            )
        } header: {
            Label("状态", systemImage: "chart.bar.xaxis")
        }
    }

    private var liveActivityStatus: String {
        guard isLiveActivitySupported else { return "当前不可用" }
        return isLiveActivityEnabled ? "已启用" : "已关闭"
    }

    @ViewBuilder
    private var runtimeContent: some View {
        switch status {
        case .idle:
            HarnessStatusPill(title: "空闲", systemImage: "pause.circle", tint: .secondary)
        case let .running(progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("当前任务")
                    Spacer()
                    HarnessStatusPill(title: "运行中", systemImage: "bolt.fill", tint: .green)
                    Text("\(progress.completedUnitCount)/\(progress.totalUnitCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(
                    value: Double(progress.completedUnitCount),
                    total: Double(progress.totalUnitCount)
                )
                if privacyModeEnabled {
                    Text("任务进行中")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(progress.title)
                        .font(.footnote)
                    Text(progress.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case let .completed(success):
            HarnessStatusPill(
                title: success ? "已完成" : "未完成",
                systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                tint: success ? .green : .red
            )
        case .interrupted:
            HarnessStatusPill(title: "已被系统中断", systemImage: "pause.circle", tint: .orange)
        }
    }
}

private struct BackgroundDetailsRow: View {
    let title: String
    let text: String

    var body: some View {
        DisclosureGroup(title) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, HarnessTheme.Spacing.xSmall)
        }
        .font(.footnote)
    }
}

private struct BackgroundSafetyBoundarySection: View {
    var body: some View {
        Section {
            Label("静音音频只在已开启、仍有任务且 App 位于后台时运行", systemImage: "speaker.wave.2")
            Label("后台定位需单独开启并取得 Always 授权，不保存或上传坐标", systemImage: "location")
            Label("不会使用蓝牙或 VoIP 冒充后台业务", systemImage: "checkmark.shield")
        } header: {
            Label("执行边界", systemImage: "checkmark.shield")
        }
    }
}
