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
            LabeledContent("活动任务", value: "\(projection.activeRunCount) 个")
            LabeledContent("保活层级", value: tierLabel)
            LabeledContent("通知权限", value: projection.notificationAuthorization)
            LabeledContent("定位权限", value: projection.locationAuthorization)
            LabeledContent(
                "实时活动权限",
                value: projection.liveActivitySupported
                    ? (projection.liveActivityEnabled ? "已启用" : "已关闭")
                    : "不可用"
            )
            if !projection.degradedReasons.isEmpty {
                LabeledContent("当前降级", value: degradedLabel)
                    .foregroundStyle(.orange)
            }
            if !projection.degradedDetails.isEmpty {
                LabeledContent("故障证据", value: projection.degradedDetails.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("当前系统投影")
        } footer: {
            Text("这里显示所有并行任务的汇总状态。不会显示提示词、工具参数、工具输出或模型正文；降级只表示对应系统能力当前不可用。")
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
        } header: {
            Text("锁屏与灵动岛")
        } footer: {
            if isSystemSupported {
                Text("显示当前会话、步骤、工具和真实进度。它只投影任务状态，不会让 App 获得永久后台执行能力；关闭后会立即移除当前实时活动。")
            } else {
                Text("当前设备环境不支持 ActivityKit 实时活动。")
            }
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
        } header: {
            Text("后台执行")
        } footer: {
            if isSystemSupported {
                Text("使用 iOS 26 Continued Processing。任务由用户在前台发起，系统允许时可在离开 App 后继续；iOS 仍可因资源、温度或用户操作而终止任务。")
            } else {
                Text("当前系统不支持 Continued Processing。iOS 18–25 下，任务只能使用系统通常提供的短暂后台时间，不能保证持续运行。")
            }
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
        } header: {
            Text("可选定位保活")
        } footer: {
            Text("仅在开启此开关、已允许 Always 定位、后台停留约 15 秒且仍有任务运行时使用约 3 公里精度的位置服务。不会保存、显示或上传坐标；普通一次定位工具不会触发此授权。")
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
        } footer: {
            if let errorDescription {
                Text("通知授权失败：\(errorDescription)")
            } else if authorization == .denied {
                Text("通知偏好已保存，但系统权限被拒绝；在系统设置中允许通知后才能收到任务完成提醒。")
            } else {
                Text("仅在任务结束时发送本地通知。开启开关时才请求系统通知权限。")
            }
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
        } footer: {
            Text("开启后，锁屏、灵动岛状态和完成通知只显示通用任务状态，不显示会话标题、工具名称或回复内容。")
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
        } header: {
            Text("状态")
        } footer: {
            Text("Continued Processing 和实时活动都由 iOS 管理。实时活动只显示真实任务状态；两者都不是无限后台或常驻进程保证。")
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
            LabeledContent("当前任务", value: "空闲")
        case let .running(progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("当前任务")
                    Spacer()
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
            LabeledContent("最近任务", value: success ? "已完成" : "未完成")
        case .interrupted:
            LabeledContent("最近任务", value: "已被系统中断")
        }
    }
}

private struct BackgroundSafetyBoundarySection: View {
    var body: some View {
        Section("执行边界") {
            Label("不会播放静音音频保活", systemImage: "speaker.slash")
            Label("不会申请 Always Location 或伪造位置活动", systemImage: "location.slash")
            Label("不会使用蓝牙或 VoIP 冒充后台业务", systemImage: "checkmark.shield")
        }
    }
}
