import SwiftUI
import UIKit

struct PhonePermissionsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var snapshots = DevicePermissionCapability.allCases.map {
        DevicePermissionSnapshot(capability: $0, status: .notDetermined)
    }
    @State private var isRefreshing = false

    private let center: DevicePermissionCenter

    init(center: DevicePermissionCenter = .system) {
        self.center = center
    }

    var body: some View {
        Form {
            permissionSection("隐私访问", capabilities: [
                .camera, .microphone, .speech, .location, .motion,
                .contacts, .photos, .calendar, .reminders, .mediaLibrary,
            ])
            permissionSection("系统连接", capabilities: [
                .notifications, .bluetooth, .localNetwork,
            ])
            permissionSection("额外能力", capabilities: [
                .healthKit, .homeKit, .nfc,
            ])

            Section {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("打开 iOS 设置", systemImage: "gear")
                }
            } footer: {
                Text("此页面只读取当前状态。权限只会在你主动使用对应功能或批准相关工具调用时由 iOS 请求。")
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("手机权限")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .accessibilityLabel("刷新权限状态")
                .help("刷新权限状态")
            }
        }
    }

    @ViewBuilder
    private func permissionSection(
        _ title: String,
        capabilities: [DevicePermissionCapability]
    ) -> some View {
        Section {
            ForEach(capabilities) { capability in
                DevicePermissionRow(
                    capability: capability,
                    status: status(for: capability)
                )
            }
        } header: {
            Label(title, systemImage: sectionIcon(for: title))
        }
    }

    private func sectionIcon(for title: String) -> String {
        switch title {
        case "隐私访问": return "hand.raised"
        case "系统连接": return "point.3.connected.trianglepath.dotted"
        default: return "sparkles"
        }
    }

    private func status(for capability: DevicePermissionCapability) -> DevicePermissionStatus {
        snapshots.first(where: { $0.capability == capability })?.status ?? .unavailable
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshots = await center.refresh()
        isRefreshing = false
    }
}

private struct DevicePermissionRow: View {
    let capability: DevicePermissionCapability
    let status: DevicePermissionStatus
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(capability.purpose(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 44)
                .padding(.top, HarnessTheme.Spacing.xSmall)
        } label: {
            HStack(spacing: 12) {
                HarnessIconTile(systemImage: capability.systemImage, tint: capability.tint)
                Text(capability.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HarnessStatusPill(
                    title: status.title,
                    systemImage: status.systemImage,
                    tint: status.tint
                )
            }
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityIdentifier("phone-permission-\(capability.rawValue)")
    }
}

private extension DevicePermissionCapability {
    var title: String {
        switch self {
        case .camera: "相机"
        case .microphone: "麦克风"
        case .speech: "语音识别"
        case .location: "定位"
        case .motion: "运动与健身"
        case .notifications: "通知"
        case .bluetooth: "蓝牙"
        case .localNetwork: "本地网络"
        case .contacts: "联系人"
        case .photos: "照片"
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .mediaLibrary: "媒体资料库"
        case .healthKit: "HealthKit"
        case .homeKit: "HomeKit"
        case .nfc: "NFC"
        }
    }

    func purpose(for status: DevicePermissionStatus) -> String {
        switch self {
        case .camera: "用于拍照和本机 OCR。"
        case .microphone: "用于手机上的语音输入。"
        case .speech: "用于把语音转换为文字。"
        case .location: "定位工具只获取一次当前位置。"
        case .motion: "读取有限时间范围内的活动估计。"
        case .notifications: "用于本地提醒和任务完成通知。"
        case .bluetooth: "用于批准后的 BLE 设备操作。"
        case .localNetwork: "iOS 没有只读状态查询；实际局域网操作才会触发系统流程。"
        case .contacts: "联系人搜索只返回有限的姓名、电话和邮箱。"
        case .photos: "区分照片读写、有限访问和仅添加权限。"
        case .calendar: "支持只写或完全访问，按工具实际请求。"
        case .reminders: "支持只写或完全访问，按工具实际请求。"
        case .mediaLibrary: "用于访问本机音乐资料库。"
        case .healthKit:
            switch status {
            case .notIntegrated:
                "当前签名未包含 HealthKit capability；请使用启用该 entitlement 的设备构建。"
            case .unavailable:
                "此设备不支持 HealthKit。"
            default:
                "已接入 typed Swift HealthKit 查询；具体数据类型仍由健康 App 管理授权。"
            }
        case .homeKit: "当前未配置 HomeKit capability。"
        case .nfc: "没有永久授权；每次扫描使用系统会话。"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .speech: "waveform"
        case .location: "location"
        case .motion: "figure.walk.motion"
        case .notifications: "bell"
        case .bluetooth: "bluetooth"
        case .localNetwork: "network"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .mediaLibrary: "music.note.list"
        case .healthKit: "heart"
        case .homeKit: "house"
        case .nfc: "wave.3.right"
        }
    }

    var tint: Color {
        switch self {
        case .camera, .photos: .blue
        case .microphone, .speech, .mediaLibrary: .purple
        case .location, .motion: .green
        case .notifications, .calendar, .reminders: .orange
        case .bluetooth: .cyan
        case .localNetwork: .gray
        case .contacts: .indigo
        case .healthKit: .red
        case .homeKit: .teal
        case .nfc: .secondary
        }
    }
}

private extension DevicePermissionStatus {
    var title: String {
        switch self {
        case .notDetermined: "尚未请求"
        case .authorized: "已允许"
        case .limited: "有限访问"
        case .writeOnly: "仅添加/写入"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        case .unavailable: "不可用"
        case .notIntegrated: "未接入"
        case .systemManaged: "系统管理"
        case .sessionOnly: "会话授权"
        }
    }

    var systemImage: String {
        switch self {
        case .authorized: "checkmark.circle.fill"
        case .limited, .sessionOnly: "circle.lefthalf.filled"
        case .writeOnly: "arrow.up.circle"
        case .notDetermined: "questionmark.circle"
        case .denied: "xmark.circle.fill"
        case .restricted: "lock.circle"
        case .unavailable: "minus.circle"
        case .notIntegrated: "wrench.and.screwdriver"
        case .systemManaged: "gearshape.circle"
        }
    }

    var tint: Color {
        switch self {
        case .authorized: .green
        case .limited, .sessionOnly, .writeOnly, .systemManaged: .orange
        case .denied, .restricted: .red
        case .notDetermined, .unavailable, .notIntegrated: .secondary
        }
    }
}
