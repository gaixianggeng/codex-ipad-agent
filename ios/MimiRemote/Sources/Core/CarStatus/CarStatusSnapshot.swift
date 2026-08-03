import Foundation

/// App 与 Widget Extension 之间唯一允许共享的数据协议。
///
/// 类型名携带版本号，避免未来字段调整后让系统仍持有的旧 timeline 无法解码。
struct CarStatusSnapshotV1: Codable, Equatable {
    static let schemaVersion = 1
    static let staleInterval: TimeInterval = 15 * 60
    static let defaultStaleInterval = staleInterval

    let schemaVersion: Int
    let profileID: String
    let sessionID: String
    let projectDisplayName: String
    let sessionTitle: String
    let displayStatus: CarStatusDisplayStatus
    /// 远端任务最后一次活动时间，只用于向用户解释“多久前更新”。
    let activityDate: Date
    /// 本机最后一次观察并发布这份状态的时间，只用于判断快照是否过期。
    let publishedAt: Date

    init(
        profileID: String,
        sessionID: String,
        projectDisplayName: String,
        sessionTitle: String,
        displayStatus: CarStatusDisplayStatus,
        activityDate: Date,
        publishedAt: Date
    ) {
        self.schemaVersion = Self.schemaVersion
        self.profileID = Self.sanitizedIdentifier(profileID)
        self.sessionID = Self.sanitizedIdentifier(sessionID)
        self.projectDisplayName = Self.sanitized(projectDisplayName, fallback: "Mimi", limit: 64)
        self.sessionTitle = Self.sanitized(sessionTitle, fallback: "Mimi", limit: 120)
        self.displayStatus = displayStatus
        self.activityDate = activityDate
        self.publishedAt = publishedAt
    }

    var expirationDate: Date {
        publishedAt.addingTimeInterval(Self.staleInterval)
    }

    func effectiveStatus(at date: Date) -> CarStatusDisplayStatus {
        date >= expirationDate ? .stale : displayStatus
    }

    func effectiveDisplayStatus(
        at date: Date,
        staleAfter interval: TimeInterval = staleInterval
    ) -> CarStatusDisplayStatus {
        date >= publishedAt.addingTimeInterval(interval) ? .stale : displayStatus
    }

    /// `publishedAt` 只在内容真实变化时推进，避免列表重复赋值造成无意义的 timeline reload。
    func hasSamePayload(as other: Self) -> Bool {
        profileID == other.profileID
            && sessionID == other.sessionID
            && projectDisplayName == other.projectDisplayName
            && sessionTitle == other.sessionTitle
            && displayStatus == other.displayStatus
            && activityDate == other.activityDate
    }

    /// 只接受当前协议版本；损坏或未来版本由 Widget 降级为空态，不猜测字段语义。
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> Self? {
        try? decoder.decode(Self.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported car status snapshot schema"
            )
        }
        let profileID = try values.decode(String.self, forKey: .profileID)
        let sessionID = try values.decode(String.self, forKey: .sessionID)
        guard !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionID,
                in: values,
                debugDescription: "Car status snapshot identifiers must not be empty"
            )
        }
        self.init(
            profileID: profileID,
            sessionID: sessionID,
            projectDisplayName: try values.decode(String.self, forKey: .projectDisplayName),
            sessionTitle: try values.decode(String.self, forKey: .sessionTitle),
            displayStatus: try values.decode(CarStatusDisplayStatus.self, forKey: .displayStatus),
            activityDate: try values.decode(Date.self, forKey: .activityDate),
            publishedAt: try values.decode(Date.self, forKey: .publishedAt)
        )
    }

    private static func sanitized(_ value: String, fallback: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = normalized.isEmpty ? fallback : normalized
        return String(source.prefix(limit))
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(256)
        )
    }
}

struct CarStatusSnapshotStore {
    static let appGroupID = "group.com.gaixianggeng.mimi"
    static let snapshotKey = "carStatus.snapshot.v1"

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)) -> CarStatusSnapshotV1? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return CarStatusSnapshotV1.decode(from: data)
    }
}

enum CarStatusDisplayStatus: String, Codable, CaseIterable, Equatable {
    case running
    case needsAttention
    case completed
    case failed
    case offline
    case stale
}
