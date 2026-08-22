import Foundation

/// Optional model route used only for compaction summaries. A missing value
/// means the compactor inherits the active conversation route, matching the
/// upstream `dsh-compaction-basic` empty provider/model pair.
struct CompactionSummaryRoute: Codable, Sendable, Hashable {
    let profileID: String
    let model: String

    init(profileID: String, model: String) {
        self.profileID = profileID
        self.model = model
    }

    func validated(in directory: ProviderProfileDirectory) throws -> CompactionSummaryRoute {
        guard let profile = directory.profile(id: profileID) else {
            throw CompactionSummaryRouteError.missingProfile(profileID)
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty, normalizedModel.utf8.count <= 256 else {
            throw CompactionSummaryRouteError.invalidModel
        }
        guard profile.models.contains(where: { $0.id == normalizedModel }) else {
            throw CompactionSummaryRouteError.modelUnavailable(
                profileID: profileID,
                model: normalizedModel
            )
        }
        return CompactionSummaryRoute(profileID: profileID, model: normalizedModel)
    }

    func configuration(in directory: ProviderProfileDirectory) throws -> AgentConfiguration {
        let route = try validated(in: directory)
        guard let profile = directory.profile(id: route.profileID) else {
            throw CompactionSummaryRouteError.missingProfile(route.profileID)
        }
        return try profile.configuration(model: route.model).validated()
    }
}

enum CompactionSummaryRouteError: LocalizedError, Sendable, Equatable {
    case missingProfile(String)
    case invalidModel
    case modelUnavailable(profileID: String, model: String)
    case profileBusy

    var errorDescription: String? {
        switch self {
        case let .missingProfile(profileID):
            return "压缩摘要使用的 Provider Profile“\(profileID)”已不存在。"
        case .invalidModel:
            return "压缩摘要模型 ID 不能为空，且不能超过 256 字节。"
        case let .modelUnavailable(profileID, model):
            return "Provider Profile“\(profileID)”中没有压缩摘要模型“\(model)”。"
        case .profileBusy:
            return "当前任务仍在运行，停止任务后才能切换压缩摘要模型。"
        }
    }
}
