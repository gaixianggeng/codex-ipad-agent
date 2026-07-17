import Foundation
import UserNotifications

// SessionStore 的持久化、队列、提醒和历史预算辅助类型，不构成公开 API。
struct QueuedCommandActionRun: Equatable {
    let path: String
    let id: String
    let confirmed: Bool
}

struct HistoryFirstPageRequestKey: Hashable {
    let sessionID: SessionID
    let limit: Int
    let loadMode: HistoryMessagesPage.LoadMode
}

struct SessionListFirstPageRequestKey: Hashable {
    let connectionGeneration: Int
    let workspaceID: String
    let workspacePath: String
    let limit: Int
}

struct SessionListBudgetKey: Hashable {
    let connectionGeneration: Int
    let cwd: String
}

struct SessionListFirstPageInFlight {
    let task: Task<SessionsPage, Error>
}

struct SessionListFirstPageCacheEntry {
    let page: SessionsPage
    let loadedAt: Date
}

struct HistoryFirstPageInFlight {
    let token: Int
    let task: Task<HistoryMessagesPage, Error>
}

struct HistoryFirstPageCacheEntry {
    let page: HistoryMessagesPage
    let loadedAt: Date
    let token: Int
}

struct HistoryFirstPageResult {
    let page: HistoryMessagesPage
    let token: Int
}

struct HistoryFirstPageFetchFailure: LocalizedError {
    let underlying: Error
    let token: Int

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

struct HistoryPolicyFailure: Equatable {
    let retryAfterNanoseconds: UInt64?
    let retryAfterSeconds: Int?
}

struct SessionListPolicyFailure: Equatable {
    let retryAfterNanoseconds: UInt64
    let retryAfterSeconds: Int
}

enum HistoryFirstPageCachePolicy: Equatable {
    case reuseRecent
    case bypass
}

enum HistoryLoadReason: Equatable {
    case automatic
    case manualFull
    case summaryChoice
}

enum HistoryLoadQuality: Equatable {
    case full
    case summary
}

struct HistoryLoadSignature: Equatable {
    let updatedAt: Date?
    let revision: ModelRevision?
    let lastSeq: EventSequence?

    init(session: AgentSession) {
        self.updatedAt = session.updatedAt
        self.revision = session.revision
        self.lastSeq = session.lastSeq
    }
}

// 会话首屏历史按 session 维度复用，而不是按选中动作复用。
// 用户来回切会话、前台恢复、手动刷新可能同时触发 before=nil 请求；
// 这里保留一轮加载的 task 和 session 快照，用来避免同一个大 session 反复请求。
struct HistoryLoadJob {
    let token: Int
    let sessionSignature: HistoryLoadSignature
    let loadMode: HistoryMessagesPage.LoadMode
    let allowPolicyRetry: Bool
    let task: Task<HistoryFirstPageResult, Error>
    var requiresForegroundReporting: Bool
    var foregroundSuccessStatusMessage: String?
}

struct ProjectSessionListSnapshot: Equatable {
    let projectID: String
    let isExpanded: Bool
    let isShowingAll: Bool
    let visibleSessions: [AgentSession]
    let allSessionCount: Int
    let hiddenCount: Int
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let hasCollapsedPreview: Bool

    var isEmpty: Bool {
        allSessionCount == 0
    }

    var shouldShowActionRow: Bool {
        hiddenCount > 0 || canLoadMore || isShowingAll && hasCollapsedPreview
    }

    var actionTitle: String {
        if isLoadingMore {
            return "加载中..."
        }
        if isShowingAll && visibleSessions.count >= allSessionCount && !canLoadMore {
            return "收起显示"
        }
        return "显示更多"
    }
}

struct SessionListPreferences: Codable, Equatable {
    var pinnedSessionIDs: Set<SessionID> = []
    var archivedSessionIDs: Set<SessionID> = []
    var sessionWorkspaceIDs: Set<String>? = nil
}

struct SessionListPreferenceStore {
    struct Storage: Codable {
        var byEndpoint: [String: SessionListPreferences] = [:]
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionListPreferences") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> SessionListPreferences {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? SessionListPreferences()
    }

    func save(_ preferences: SessionListPreferences, endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = preferences
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

enum SessionControlState: String, Codable, Equatable {
    case ipadOwned
    case takenOver
    case observing

    var isControllable: Bool {
        self == .ipadOwned || self == .takenOver
    }
}

struct SessionControlStateStore {
    struct Storage: Codable {
        var byEndpoint: [String: [SessionID: SessionControlState]] = [:]
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionControlStates") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> [SessionID: SessionControlState] {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? [:]
    }

    func save(_ states: [SessionID: SessionControlState], endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = states
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

struct SessionReminder: Codable, Equatable, Identifiable {
    let sessionID: SessionID
    var title: String
    var fireAt: Date
    var createdAt: Date

    var id: SessionID { sessionID }

    func isDue(now: Date = Date()) -> Bool {
        fireAt <= now
    }
}

struct SessionRuntimeNotification: Equatable {
    enum Kind: String {
        case approval
        case completed
        case failed
    }

    let id: String
    let sessionID: SessionID
    let title: String
    let body: String
    let kind: Kind
}

struct SessionReminderStore {
    struct Storage: Codable {
        var byEndpoint: [String: [SessionID: SessionReminder]] = [:]
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionReminders") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> [SessionID: SessionReminder] {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? [:]
    }

    func save(_ reminders: [SessionID: SessionReminder], endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = reminders
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

struct HistorySavingsNotice: Equatable {
    enum Kind: Equatable {
        case loadingFull
        case fullFailed
        case loadingSummary
        case summaryLoaded
        case summaryFailed
    }

    let sessionID: SessionID
    let kind: Kind
    let message: String
}

struct HistorySavingsNoticeStore {
    struct Storage: Codable {
        var dismissedEndpoints: Set<String> = []
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.historySavingsNotice") {
        self.defaults = defaults
        self.key = key
    }

    func loadDismissedEndpoints() -> Set<String> {
        storage().dismissedEndpoints
    }

    func dismiss(endpoint: String) -> Set<String> {
        var storage = storage()
        storage.dismissedEndpoints.insert(normalizedEndpoint(endpoint))
        persist(storage)
        return storage.dismissedEndpoints
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

enum SessionReminderScheduleOutcome: Equatable {
    case scheduled
    case permissionDenied
}

protocol SessionReminderScheduling {
    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome
    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws
    func cancel(sessionID: SessionID)
}

struct UserNotificationSessionReminderScheduler: SessionReminderScheduling {
    let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return .permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = "会话提醒"
        content.body = reminder.title
        content.sound = .default
        content.userInfo = route.userInfo

        let interval = max(reminder.fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: reminder.sessionID),
            content: content,
            trigger: trigger
        )
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: reminder.sessionID)])
        try await add(request)
        return .scheduled
    }

    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = route.userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.runtimeNotificationID(for: notification.id),
            content: content,
            trigger: trigger
        )
        center.removePendingNotificationRequests(withIdentifiers: [Self.runtimeNotificationID(for: notification.id)])
        try await add(request)
    }

    func cancel(sessionID: SessionID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: sessionID)])
    }

    func requestAuthorizationIfNeeded() async throws -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await requestAuthorization()
        @unknown default:
            return false
        }
    }

    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func notificationID(for sessionID: SessionID) -> String {
        "mimi.sessionReminder.\(sessionID)"
    }

    static func runtimeNotificationID(for id: String) -> String {
        "mimi.sessionRuntime.\(id)"
    }
}

struct NoopSessionReminderScheduler: SessionReminderScheduling {
    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome { .scheduled }
    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws {}
    func cancel(sessionID: SessionID) {}
}

enum FilePreviewStoreError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "文件预览内容无效"
        }
    }
}

enum WorktreeCleanupSelectionError: LocalizedError, Equatable {
    case emptySelection
    case containsBlockedPath
    case missingPlan

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "请至少选择一个可清理的 Worktree。"
        case .containsBlockedPath:
            return "清理选择已过期或包含受保护的 Worktree，请重新生成预览。"
        case .missingPlan:
            return "清理预览缺少 plan_id，请重新生成预览。"
        }
    }
}

enum WorkspaceSessionRefreshError: LocalizedError, Equatable {
    case workspaceUnavailable

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            return "工作区已失效，请重新打开"
        }
    }
}

struct SessionListProjection: Equatable {
    enum Source: Equatable {
        case localUser
        case localAssistant
    }

    let preview: String
    let updatedAt: Date
    let baseRemoteUpdatedAt: Date?
    let basePreview: String?
    let source: Source
    let clientMessageID: ClientMessageID?
}

enum RunningTurnDelivery {
    case queued
    case guided
}

enum QueuedTurnIntent: Codable, Equatable {
    case standard
    case plan
    case goal(objective: String, tokenBudget: Int64?)

    var title: String {
        switch self {
        case .standard:
            return "下一轮"
        case .plan:
            return "计划"
        case .goal:
            return "目标"
        }
    }

    var canGuideCurrentTurn: Bool {
        if case .standard = self {
            return true
        }
        return false
    }

    var startsGoal: Bool {
        if case .goal = self {
            return true
        }
        return false
    }
}

enum QueuedTurnDispatchState: String, Codable, Equatable {
    case waiting
    case dispatching
    case needsConfirmation
}

struct QueuedTurnEntry: Codable, Equatable, Identifiable {
    var id: ClientMessageID { clientMessageID }

    let sessionID: SessionID
    let projectID: String?
    var payload: CodexAppServerTurnPayload
    let clientMessageID: ClientMessageID
    var intent: QueuedTurnIntent
    let createdAt: Date
    var dispatchState: QueuedTurnDispatchState
    var expectedTurnID: TurnID?
    // 上一条 turn/start 已获接受、但 started 事件尚未到达时，后续项必须跨重启继续等待；
    // blockedCompletionID 用来识别并忽略触发上一条派发的重复 completed 事件。
    var waitsForAcceptedTurnStart: Bool?
    var blockedCompletionID: TurnID?
    var lastAttemptAt: Date?
    var lastError: String?

    init(
        sessionID: SessionID,
        projectID: String? = nil,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID,
        intent: QueuedTurnIntent,
        createdAt: Date = Date(),
        dispatchState: QueuedTurnDispatchState = .waiting,
        expectedTurnID: TurnID? = nil,
        waitsForAcceptedTurnStart: Bool? = nil,
        blockedCompletionID: TurnID? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.payload = payload
        self.clientMessageID = clientMessageID
        self.intent = intent
        self.createdAt = createdAt
        self.dispatchState = dispatchState
        self.expectedTurnID = expectedTurnID
        self.waitsForAcceptedTurnStart = waitsForAcceptedTurnStart
        self.blockedCompletionID = blockedCompletionID
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    var previewText: String {
        payload.previewText
    }

    var imageCount: Int {
        payload.input.reduce(into: 0) { count, input in
            switch input {
            case .image, .localImage:
                count += 1
            default:
                break
            }
        }
    }
}

struct QueuedTurnProfileSnapshot: Codable, Equatable {
    static let schemaVersion = 1

    var version = Self.schemaVersion
    let profileID: String
    var queuesBySessionID: [SessionID: [QueuedTurnEntry]]
}

enum QueuedTurnStoreError: LocalizedError {
    case invalidProfile
    case unsupportedVersion(Int)
    case storageTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "本地队列不属于当前 Mac 连接档案"
        case .unsupportedVersion(let version):
            return "本地队列版本不支持（v\(version)）"
        case .storageTooLarge(let maximumBytes):
            return "本地队列超过 \(maximumBytes / 1_024 / 1_024) MB，请先删除部分消息或图片"
        }
    }
}

protocol QueuedTurnPersisting {
    func load(profileID: String) throws -> QueuedTurnProfileSnapshot
    func save(_ snapshot: QueuedTurnProfileSnapshot) throws
    func remove(profileID: String) throws
}

struct FileQueuedTurnStore: QueuedTurnPersisting {
    static let maximumEncodedByteCount = 64 * 1_024 * 1_024

    let directoryURL: URL
    let fileManager: FileManager
    let maximumEncodedByteCount: Int

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEncodedByteCount: Int = Self.maximumEncodedByteCount
    ) {
        self.fileManager = fileManager
        self.maximumEncodedByteCount = maximumEncodedByteCount
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = applicationSupport
                .appendingPathComponent("MimiRemote", isDirectory: true)
                .appendingPathComponent("QueuedTurns", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
    }

    func load(profileID: String) throws -> QueuedTurnProfileSnapshot {
        let url = fileURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return QueuedTurnProfileSnapshot(profileID: profileID, queuesBySessionID: [:])
        }
        let snapshot = try JSONDecoder().decode(QueuedTurnProfileSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == QueuedTurnProfileSnapshot.schemaVersion else {
            throw QueuedTurnStoreError.unsupportedVersion(snapshot.version)
        }
        guard snapshot.profileID == profileID else {
            throw QueuedTurnStoreError.invalidProfile
        }
        return snapshot
    }

    func save(_ snapshot: QueuedTurnProfileSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumEncodedByteCount else {
            throw QueuedTurnStoreError.storageTooLarge(maximumBytes: maximumEncodedByteCount)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try? mutableDirectoryURL.setResourceValues(directoryValues)

        let url = fileURL(profileID: snapshot.profileID)
        try data.write(to: url, options: [.atomic])
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableFileURL = url
        try? mutableFileURL.setResourceValues(fileValues)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    func remove(profileID: String) throws {
        let url = fileURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    func fileURL(profileID: String) -> URL {
        directoryURL.appendingPathComponent(Self.stableDigest(profileID) + ".json", isDirectory: false)
    }

    static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct HistoryLoadProgress: Equatable {
    let sessionID: SessionID
    var title: String
    var fraction: Double

    var percentText: String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

struct SessionRestoreSnapshot: Codable, Equatable {
    let endpoint: String
    let session: AgentSession
}

enum SessionNotificationOpenOutcome: Equatable {
    case opened
    case requiresProfileSwitch(displayName: String?)
    case unavailable(message: String)
    case ignored
}

