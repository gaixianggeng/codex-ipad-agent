import Foundation

/// 一台已保存 Mac 的本地连接档案。
///
/// `id` 是客户端数据隔离命名空间；`installationID` 是 agentd 返回的稳定安装身份；
/// `endpoint` 只是可变路由，不能作为跨 Mac 数据主键。
struct ConnectionProfile: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var endpoint: String
    var lastSuccessfulAt: Date?
    var installationID: String?
    var revision: UInt64

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case endpoint
        case lastSuccessfulAt
        case installationID
        case revision
    }

    init(
        id: String,
        displayName: String,
        endpoint: String,
        lastSuccessfulAt: Date?,
        installationID: String? = nil,
        revision: UInt64 = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.lastSuccessfulAt = lastSuccessfulAt
        self.installationID = installationID
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        lastSuccessfulAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulAt)
        installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    }
}

struct ConnectionProfileSettingsItem: Identifiable, Equatable {
    let profile: ConnectionProfile
    let isCurrent: Bool

    var id: String { profile.id }
    var canSwitch: Bool { !isCurrent }
    var canDelete: Bool { !isCurrent }
}

struct ConnectionProfileSettingsModel: Equatable {
    let current: ConnectionProfileSettingsItem?
    let others: [ConnectionProfileSettingsItem]
    let savedCount: Int

    init(profiles: [ConnectionProfile], activeProfileID: String?) {
        let items = profiles
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastSuccessfulAt ?? .distantPast
                let rhsDate = rhs.lastSuccessfulAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map { ConnectionProfileSettingsItem(profile: $0, isCurrent: $0.id == activeProfileID) }
        current = items.first(where: \.isCurrent)
        others = items.filter { !$0.isCurrent }
        // 设置概览展示所有已保存设备；当前仍只有一个激活连接。
        savedCount = items.count
    }
}

/// 在自己的另一台设备上复用 Mac 连接时使用的短期导入链接。
///
/// 格式沿用 Mac 端已经提供的 `mimiremote://` 协议；区别仅在于已保存档案
/// 持有长期访问码，因此使用 `connect` 路由并通过 `expires_at` 限制 App 的导入窗口。
struct ConnectionTransferLink: Equatable {
    static let validityInterval: TimeInterval = 10 * 60

    let url: URL
    let expiresAt: Date

    init(
        endpoint: String,
        token: String,
        issuedAt: Date = Date(),
        validityInterval: TimeInterval = Self.validityInterval
    ) throws {
        let normalizedEndpoint = try EndpointTransportPolicy.validatedEndpoint(endpoint)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw ConnectionProfileError.missingToken
        }

        let expiresAt = issuedAt.addingTimeInterval(validityInterval)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents()
        components.scheme = "mimiremote"
        components.host = "connect"
        // 与 agentd 的 url.Values.Encode 输出保持相同字段和稳定顺序，方便跨端排查。
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: normalizedEndpoint),
            URLQueryItem(name: "expires_at", value: formatter.string(from: expiresAt)),
            URLQueryItem(name: "issued_at", value: formatter.string(from: issuedAt)),
            URLQueryItem(name: "token", value: normalizedToken)
        ]
        guard let url = components.url else {
            throw PairingLinkError.unsupportedURL
        }

        self.url = url
        self.expiresAt = expiresAt
    }
}

/// 删除连接凭据前展示的纯值确认模型。
/// 这里只保存目标和文案，不持有删除闭包，确保第一次点击按钮只会进入确认态。
struct ConnectionCredentialRemovalConfirmation: Identifiable, Equatable {
    enum Target: Equatable {
        case current(profileID: String?)
        case savedProfile(profileID: String)
    }

    let target: Target
    let displayName: String?

    static func forgettingCurrent(_ profile: ConnectionProfile?) -> Self {
        Self(
            target: .current(profileID: profile?.id),
            displayName: profile?.displayName
        )
    }

    static func deletingSavedProfile(_ profile: ConnectionProfile) -> Self {
        Self(
            target: .savedProfile(profileID: profile.id),
            displayName: profile.displayName
        )
    }

    var id: String {
        switch target {
        case .current(let profileID):
            return "forget-current:\(profileID ?? "legacy")"
        case .savedProfile(let profileID):
            return "delete-profile:\(profileID)"
        }
    }

    var title: String {
        switch target {
        case .current:
            return L10n.text("ui.forgot_your_current_mac")
        case .savedProfile:
            return L10n.format("ui.delete_value_c193903e", displayName ?? L10n.text("ui.this_mac"))
        }
    }

    var message: String {
        switch target {
        case .current:
            let targetName = displayName.map { "“\($0)”" } ?? L10n.text("ui.current_mac")
            return L10n.format("ui.this_will_delete_value_s_access_code_from", targetName)
        case .savedProfile:
            let targetName = displayName ?? L10n.text("ui.this_mac")
            return L10n.format("ui.this_will_delete_value_s_connection_profile_and", targetName)
        }
    }

    var confirmButtonTitle: String {
        switch target {
        case .current:
            return L10n.text("ui.forget_this_mac")
        case .savedProfile:
            return L10n.text("ui.delete_connection_file")
        }
    }
}

enum ConnectionProfileError: LocalizedError, Equatable {
    case notFound
    case missingToken
    case installationIdentityRequired
    case installationIdentityMismatch(profileName: String)
    case duplicateInstallation(profileName: String)
    case preparedContextExpired
    case preparedContextConsumed
    case preparedContextMismatch
    case cannotDeleteCurrent
    case operationInProgress
    case invalidDisplayName
    case displayNameTooLong(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return L10n.text("ui.the_connection_file_cannot_be_found_for_this")
        case .missingToken:
            return L10n.text("ui.the_access_code_for_this_mac_does_not")
        case .installationIdentityRequired:
            return L10n.text("ui.agentd_version_too_old_for_multi_mac")
        case .installationIdentityMismatch(let profileName):
            return L10n.format("ui.mac_installation_identity_mismatch", profileName)
        case .duplicateInstallation(let profileName):
            return L10n.format("ui.mac_already_saved_as_value", profileName)
        case .preparedContextExpired:
            return L10n.text("ui.prepared_connection_expired")
        case .preparedContextConsumed:
            return L10n.text("ui.prepared_connection_consumed")
        case .preparedContextMismatch:
            return L10n.text("ui.prepared_connection_mismatch")
        case .cannotDeleteCurrent:
            return L10n.text("ui.please_switch_to_another_mac_before_deleting_this")
        case .operationInProgress:
            return L10n.text("ui.another_mac_connection_operation_is_still_in_progress")
        case .invalidDisplayName:
            return L10n.text("ui.mac_name_cannot_be_empty")
        case .displayNameTooLong(let maximum):
            return L10n.format("ui.mac_name_can_be_up_to_value_characters", maximum)
        }
    }
}

enum PreparedConnectionProfileTarget: Equatable {
    case currentOrNew(displayName: String?)
    case newProfile(id: String, displayName: String)
    case existingProfile(id: String)
}

/// 已完成目标 Mac 验证、等待事务提交的值对象。
struct PreparedConnectionSettings: Equatable {
    let endpoint: String
    let token: String
    let profileTarget: PreparedConnectionProfileTarget
    let validatedAt: Date
    let installationID: String?
    let hostContext: PreparedHostContext?

    init(
        endpoint: String,
        token: String,
        profileTarget: PreparedConnectionProfileTarget = .currentOrNew(displayName: nil),
        validatedAt: Date = Date(),
        installationID: String? = nil,
        hostContext: PreparedHostContext? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.profileTarget = profileTarget
        self.validatedAt = validatedAt
        self.installationID = installationID
        self.hostContext = hostContext
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint &&
            lhs.token == rhs.token &&
            lhs.profileTarget == rhs.profileTarget &&
            lhs.validatedAt == rhs.validatedAt &&
            lhs.installationID == rhs.installationID &&
            lhs.hostContext === rhs.hostContext
    }
}
