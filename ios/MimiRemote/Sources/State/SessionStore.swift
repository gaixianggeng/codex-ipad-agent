import Foundation
import UserNotifications

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func modelOptions() async throws -> [CodexAppServerModelOption]
    func capabilities(path: String?) async throws -> CapabilityListResponse
    func resolveWorkspace(path: String) async throws -> AgentWorkspace
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse
    func listWorktrees() async throws -> [WorktreeListItem]
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse
    func listDirectories(path: String) async throws -> DirectoryListResponse
    func readFile(path: String) async throws -> FileReadResponse
    func readHistoryMedia(id: String) async throws -> FileReadResponse
    func commandActions(path: String) async throws -> [AgentCommandAction]
    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse
    func gitStatus(path: String) async throws -> GitStatusResponse
    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse
    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse
    func gitCommit(path: String, message: String) async throws -> GitStatusResponse
    func gitPush(path: String, remote: String?) async throws -> GitPushResponse
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse
    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse
    func threadGoal(threadID: String) async throws -> ThreadGoal?
    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal
    func clearThreadGoal(threadID: String) async throws
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession
    func stopSession(id: String) async throws
    func setSessionArchived(id: String, archived: Bool) async throws
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage
    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary?
}

extension SessionStoreAPIClient {
    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        nil
    }
    func modelOptions() async throws -> [CodexAppServerModelOption] {
        []
    }

    func capabilities(path: String?) async throws -> CapabilityListResponse {
        throw AgentAPIError.invalidResponse
    }

    func session(id: String) async throws -> SessionResponse {
        try await session(id: id, afterSeq: nil)
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        throw AgentAPIError.invalidResponse
    }

    func threadGoal(threadID: String) async throws -> ThreadGoal? {
        throw AgentAPIError.invalidResponse
    }

    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal {
        throw AgentAPIError.invalidResponse
    }

    func clearThreadGoal(threadID: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession {
        throw AgentAPIError.invalidResponse
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/workspaces/resolve。
        throw AgentAPIError.invalidResponse
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/create。
        throw AgentAPIError.invalidResponse
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/branches。
        throw AgentAPIError.invalidResponse
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/list。
        throw AgentAPIError.invalidResponse
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/delete。
        throw AgentAPIError.invalidResponse
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/worktrees/prune。
        throw AgentAPIError.invalidResponse
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/directories/list。
        throw AgentAPIError.invalidResponse
    }

    func readFile(path: String) async throws -> FileReadResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/files/read。
        throw AgentAPIError.invalidResponse
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/app-server/history-media/{id}。
        throw AgentAPIError.invalidResponse
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/actions/list。
        throw AgentAPIError.invalidResponse
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/actions/run。
        throw AgentAPIError.invalidResponse
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/status。
        throw AgentAPIError.invalidResponse
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/action。
        throw AgentAPIError.invalidResponse
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/action。
        throw AgentAPIError.invalidResponse
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/commit。
        throw AgentAPIError.invalidResponse
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/push。
        throw AgentAPIError.invalidResponse
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/pull-request。
        throw AgentAPIError.invalidResponse
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/git/pull-request/status。
        throw AgentAPIError.invalidResponse
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/voice/transcribe。
        throw AgentAPIError.invalidResponse
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await sessionsPage(projectID: workspace.rootProjectID ?? workspace.id, cursor: cursor, limit: limit)
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        HistoryMessagesPage(messages: try await messages(sessionID: sessionID, before: before, limit: limit))
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit)
    }

}

actor TerminalStreamStore {
    private let maxBatchSize: Int
    private var eventsBySessionID: [SessionID: [AgentEvent]] = [:]

    init(maxBatchSize: Int = 64) {
        self.maxBatchSize = max(1, maxBatchSize)
    }

    func append(_ event: AgentEvent, sessionID: SessionID) -> Bool {
        eventsBySessionID[sessionID, default: []].append(event)
        return eventsBySessionID[sessionID, default: []].count >= maxBatchSize
    }

    func drain(sessionID: SessionID) -> [AgentEvent] {
        let events = eventsBySessionID[sessionID] ?? []
        eventsBySessionID[sessionID] = []
        return events
    }

    func removeAll(sessionID: SessionID) {
        eventsBySessionID.removeValue(forKey: sessionID)
    }
}

private struct QueuedCommandActionRun: Equatable {
    let path: String
    let id: String
    let confirmed: Bool
}

private struct HistoryFirstPageRequestKey: Hashable {
    let sessionID: SessionID
    let limit: Int
    let loadMode: HistoryMessagesPage.LoadMode
}

private struct SessionListFirstPageRequestKey: Hashable {
    let connectionGeneration: Int
    let workspaceID: String
    let workspacePath: String
    let limit: Int
}

private struct SessionListBudgetKey: Hashable {
    let connectionGeneration: Int
    let cwd: String
}

private struct SessionListFirstPageInFlight {
    let task: Task<SessionsPage, Error>
}

private struct SessionListFirstPageCacheEntry {
    let page: SessionsPage
    let loadedAt: Date
}

private struct HistoryFirstPageInFlight {
    let token: Int
    let task: Task<HistoryMessagesPage, Error>
}

private struct HistoryFirstPageCacheEntry {
    let page: HistoryMessagesPage
    let loadedAt: Date
    let token: Int
}

private struct HistoryFirstPageResult {
    let page: HistoryMessagesPage
    let token: Int
}

private struct HistoryFirstPageFetchFailure: LocalizedError {
    let underlying: Error
    let token: Int

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private struct HistoryPolicyFailure: Equatable {
    let retryAfterNanoseconds: UInt64?
    let retryAfterSeconds: Int?
}

private struct SessionListPolicyFailure: Equatable {
    let retryAfterNanoseconds: UInt64
    let retryAfterSeconds: Int
}

private enum HistoryFirstPageCachePolicy: Equatable {
    case reuseRecent
    case bypass
}

private enum HistoryLoadReason: Equatable {
    case automatic
    case manualFull
    case summaryChoice
}

private enum HistoryLoadQuality: Equatable {
    case full
    case summary
}

private struct HistoryLoadSignature: Equatable {
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
private struct HistoryLoadJob {
    let token: Int
    let sessionSignature: HistoryLoadSignature
    let loadMode: HistoryMessagesPage.LoadMode
    let allowPolicyRetry: Bool
    let task: Task<HistoryFirstPageResult, Error>
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
    private struct Storage: Codable {
        var byEndpoint: [String: SessionListPreferences] = [:]
    }

    private let defaults: UserDefaults
    private let key: String

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

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
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
    private struct Storage: Codable {
        var byEndpoint: [String: [SessionID: SessionControlState]] = [:]
    }

    private let defaults: UserDefaults
    private let key: String

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

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
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
    private struct Storage: Codable {
        var byEndpoint: [String: [SessionID: SessionReminder]] = [:]
    }

    private let defaults: UserDefaults
    private let key: String

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

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
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
    private struct Storage: Codable {
        var dismissedEndpoints: Set<String> = []
    }

    private let defaults: UserDefaults
    private let key: String

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

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

protocol SessionReminderScheduling {
    func schedule(_ reminder: SessionReminder) async throws
    func notify(_ notification: SessionRuntimeNotification) async throws
    func cancel(sessionID: SessionID)
}

struct UserNotificationSessionReminderScheduler: SessionReminderScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func schedule(_ reminder: SessionReminder) async throws {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "会话提醒"
        content.body = reminder.title
        content.sound = .default

        let interval = max(reminder.fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: reminder.sessionID),
            content: content,
            trigger: trigger
        )
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: reminder.sessionID)])
        try await add(request)
    }

    func notify(_ notification: SessionRuntimeNotification) async throws {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

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

    private func requestAuthorizationIfNeeded() async throws -> Bool {
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

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func requestAuthorization() async throws -> Bool {
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

    private func add(_ request: UNNotificationRequest) async throws {
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

    private static func notificationID(for sessionID: SessionID) -> String {
        "mimi.sessionReminder.\(sessionID)"
    }

    private static func runtimeNotificationID(for id: String) -> String {
        "mimi.sessionRuntime.\(id)"
    }
}

struct NoopSessionReminderScheduler: SessionReminderScheduling {
    func schedule(_ reminder: SessionReminder) async throws {}
    func notify(_ notification: SessionRuntimeNotification) async throws {}
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

private struct SessionListProjection: Equatable {
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

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var projects: [AgentProject] = [] {
        didSet {
            rebuildProjectIndex()
        }
    }
    @Published private(set) var recentWorkspaces: [AgentWorkspace] = [] {
        didSet {
            rebuildWorkspaceIndex()
        }
    }
    @Published private(set) var sidebarProjects: [AgentProject] = [] {
        didSet {
            rebuildProjectSessionListSnapshots()
        }
    }
    // 某个工作区的目录被删除、或 Mac 端 scan_roots 改动后掉出 allowlist 时记入这里：
    // 侧栏单独标记该行不可用，避免把“某个 recent 失效”冒泡成整页的全局错误。
    @Published private(set) var unavailableWorkspaceIDs: Set<String> = []
    @Published private(set) var sessions: [AgentSession] = [] {
        didSet {
            rebuildSessionIndexes()
        }
    }
    @Published private(set) var pinnedSessionIDs: Set<SessionID> = []
    @Published private(set) var archivedSessionIDs: Set<SessionID> = []
    @Published private(set) var sessionWorkspaceIDs: Set<String>? = nil
    @Published private(set) var sessionRemindersByID: [SessionID: SessionReminder] = [:]
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published var sessionSearchQuery = "" {
        didSet {
            guard oldValue != sessionSearchQuery else {
                return
            }
            rebuildProjectSessionListSnapshots()
        }
    }
    @Published private(set) var expandedProjectIDs: Set<String> = []
    @Published private(set) var showingAllSessionProjectIDs: Set<String> = []
    @Published var isLoading = false
    @Published var webSocketStatus: WebSocketStatus = .disconnected
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var isRefreshingSelectedSession = false
    @Published private(set) var isUpdatingThreadGoal = false
    @Published private(set) var threadGoalErrorMessage: String?
    @Published private(set) var appServerModelOptions: [CodexAppServerModelOption] = []
    @Published private(set) var isRefreshingAppServerModels = false
    @Published private(set) var capabilityList: CapabilityListResponse?
    @Published private(set) var isRefreshingCapabilities = false
    @Published private(set) var capabilityErrorMessage: String?
    @Published private(set) var isCreatingWorktree = false
    @Published private(set) var worktreeBranchesByPath: [String: WorktreeBranchListResponse] = [:]
    @Published private(set) var worktreeBranchErrorByPath: [String: String] = [:]
    @Published private(set) var isRefreshingWorktreeBranches = false
    @Published private(set) var managedWorktrees: [WorktreeListItem] = []
    @Published private(set) var isRefreshingWorktrees = false
    @Published private(set) var isDeletingWorktree = false
    @Published private(set) var isPruningWorktrees = false
    @Published private(set) var worktreeErrorMessage: String?
    @Published private(set) var gitStatusByPath: [String: GitStatusResponse] = [:]
    @Published private(set) var gitStatusErrorByPath: [String: String] = [:]
    @Published private(set) var isRefreshingGitStatus = false
    @Published private(set) var gitActionErrorByPath: [String: String] = [:]
    @Published private(set) var commandActionsByPath: [String: [AgentCommandAction]] = [:]
    @Published private(set) var commandActionErrorByPath: [String: String] = [:]
    @Published private(set) var commandActionResultByPath: [String: CommandActionRunResponse] = [:]
    @Published private(set) var commandActionHistoryByPath: [String: [CommandActionRunResponse]] = [:]
    @Published private(set) var isRefreshingCommandActions = false
    @Published private(set) var queuedCommandActionIDsByPath: [String: [String]] = [:]
    @Published private(set) var runningCommandActionPath: String?
    @Published private(set) var runningCommandActionID: String?
    @Published private(set) var isRunningGitAction = false
    @Published private(set) var isCommittingGitChanges = false
    @Published private(set) var isPushingGitBranch = false
    @Published private(set) var isCreatingPullRequest = false
    @Published private(set) var pullRequestURLByPath: [String: String] = [:]
    @Published private(set) var pullRequestStatusByPath: [String: GitPullRequestStatusResponse] = [:]
    @Published private(set) var pullRequestStatusErrorByPath: [String: String] = [:]
    @Published private(set) var isRefreshingPullRequestStatus = false
    @Published private var pendingApprovalDecisionIDsBySessionID: [SessionID: Set<String>] = [:]
    @Published private var pendingUserInputResponseIDsBySessionID: [SessionID: Set<String>] = [:]
    private var pendingUserInputRequestsBySessionID: [SessionID: [String: AgentUserInputRequest]] = [:]
    @Published private var foregroundActivityBySessionID: [SessionID: SessionForegroundActivity] = [:]
    @Published private var runtimeActivityBySessionID: [SessionID: RuntimeActivitySnapshot] = [:]
    @Published private var sessionControlStateByID: [SessionID: SessionControlState] = [:]

    private let appStore: AppStore
    private let conversationStore: ConversationStore
    private let logStore: LogStore
    private let contextStore: SessionContextStore
    private let eventReducer: EventReducer
    private let recentWorkspaceStore: RecentWorkspaceStore
    private let sessionListPreferenceStore: SessionListPreferenceStore
    private let sessionControlStateStore: SessionControlStateStore
    private let sessionReminderStore: SessionReminderStore
    private let sessionReminderScheduler: any SessionReminderScheduling
    private let historySavingsNoticeStore: HistorySavingsNoticeStore
    private let terminalStreamStore = TerminalStreamStore()
    private let clientFactory: () throws -> any SessionStoreAPIClient
    private let webSocketFactory: () -> any SessionWebSocketClient
    private let sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)?
    private let webSocketReconnectDelayNanoseconds: (Int) -> UInt64
    private let sessionListNow: () -> Date
    private let sessionListSleep: (UInt64) async -> Void
    private var webSocket: (any SessionWebSocketClient)?
    private var connectedSessionID: String?
    private var webSocketConnectionGeneration = 0
    private var webSocketReconnectTask: Task<Void, Never>?
    private var webSocketReconnectAttemptBySessionID: [SessionID: Int] = [:]
    private var lastSeenEventSeqBySessionID: [SessionID: EventSequence] = [:]
    private var historySnapshotSeqBySessionID: [SessionID: EventSequence] = [:]
    private var runtimeEventFlushTasks: [SessionID: Task<Void, Never>] = [:]
    private var foregroundActivityClearTasks: [SessionID: Task<Void, Never>] = [:]
#if DEBUG
    private var didApplyDebugWorkbenchUISeed = false
#endif
    private var deliveredRuntimeNotificationIDs: Set<String> = []
    private var locallyCompletedSessionIDs: Set<SessionID> = []
    private var locallyCompletedGoalThreadIDs: Set<SessionID> = []
    private var listProjectionBySessionID: [SessionID: SessionListProjection] = [:]
    private var queuedCommandActionRuns: [QueuedCommandActionRun] = []
    private var projectsByID: [String: AgentProject] = [:]
    private var workspacesByID: [String: AgentWorkspace] = [:]
    private var sidebarProjectsByID: [String: AgentProject] = [:]
    private var sessionsByID: [SessionID: AgentSession] = [:]
    private var sessionIndexByID: [SessionID: Int] = [:]
    private var sortedAllSessions: [AgentSession] = []
    private var sortedSessionsByProjectID: [String: [AgentSession]] = [:]
    private var previewSessionsByProjectID: [String: [AgentSession]] = [:]
    private var hiddenSessionCountByProjectID: [String: Int] = [:]
    @Published private var sessionVisibleLimitByProjectID: [String: Int] = [:]
    private var sessionListSnapshotsByProjectID: [String: ProjectSessionListSnapshot] = [:]
    private var frozenAllSessionOrder: [SessionID] = []
    private var frozenSessionOrderByProjectID: [String: [SessionID]] = [:]
    private var sessionPageCursorByProjectID: [String: String] = [:]
    private var sessionHasMoreByProjectID: [String: Bool] = [:]
    private var sessionPageRequestTokenByProjectID: [String: Int] = [:]
    private var sessionPageLoadingTokenByProjectID: [String: Int] = [:]
    private var sessionListFirstPageInFlightByKey: [SessionListFirstPageRequestKey: SessionListFirstPageInFlight] = [:]
    private var sessionListFirstPageCacheByKey: [SessionListFirstPageRequestKey: SessionListFirstPageCacheEntry] = [:]
    private var sessionListCooldownUntilByBudgetKey: [SessionListBudgetKey: Date] = [:]
    private var sessionListReconciliationTasksByProjectID: [String: Task<Void, Never>] = [:]
    private var historyPreviousCursorBySessionID: [SessionID: String] = [:]
    private var historyHasMoreBeforeBySessionID: [SessionID: Bool] = [:]
    private var historyPageRequestTokenBySessionID: [SessionID: Int] = [:]
    private var historyFirstPageInFlightByKey: [HistoryFirstPageRequestKey: HistoryFirstPageInFlight] = [:]
    private var historyFirstPageCacheByKey: [HistoryFirstPageRequestKey: HistoryFirstPageCacheEntry] = [:]
    private var historyLoadJobsBySessionID: [SessionID: HistoryLoadJob] = [:]
    private var historyLoadJobTokenBySessionID: [SessionID: Int] = [:]
    private var historyLoadedSignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    private var historyLoadedQualityBySessionID: [SessionID: HistoryLoadQuality] = [:]
    private var freshEmptyHistorySignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    private var initialHistoryLoadingSessionIDs: Set<SessionID> = []
    @Published private var historyLoadProgressBySessionID: [SessionID: HistoryLoadProgress] = [:]
    @Published private var historySavingsNoticesBySessionID: [SessionID: HistorySavingsNotice] = [:]
    @Published private var dismissedHistorySavingsNoticeEndpoints: Set<String> = []
    private var appServerModelOptionsLastRefresh: Date?
    @Published private var loadingEarlierHistorySessionIDs: Set<SessionID> = []

    private let foregroundOutputIdleClearDelay: UInt64 = 8_000_000_000
    private let runtimeEventFlushDelayNanoseconds: UInt64 = 80_000_000
    private let sessionListConnectedPollingDelayNanoseconds: UInt64 = 60_000_000_000
    private let sessionListDisconnectedPollingDelayNanoseconds: UInt64 = 8_000_000_000
    private let sessionListFirstPageCacheTTL: TimeInterval = 2
    private let sessionListReconciliationDelayNanoseconds: UInt64 = 1_500_000_000
    private let economyHistoryPageLimit = 60
    private let fullHistoryPageLimit = 20
    private let historyFirstPageCacheTTL: TimeInterval = 4
    private let historyPolicyRetryFallbackNanoseconds: UInt64 = 15_000_000_000
    private let historyPolicyRetryMaxNanoseconds: UInt64 = 20_000_000_000
    private static let optimisticSessionSource = "local"
    static let sessionPreviewLimit = 3
    static let sessionExpansionStep = 5
    // 远程/VPS 中转链路下，thread/list 的响应会经过 WebSocket + SSH 隧道。
    // 首屏先拿较小窗口，避免弱网下为了预览历史会话而卡住整个工作台。
    private static let initialSessionPageLimit = 20
    private static let expandedSessionPageLimit = 20
    private static let commandActionHistoryLimit = 10

    init(
        appStore: AppStore,
        conversationStore: ConversationStore,
        logStore: LogStore,
        contextStore: SessionContextStore? = nil,
        recentWorkspaceStore: RecentWorkspaceStore? = nil,
        sessionListPreferenceStore: SessionListPreferenceStore? = nil,
        sessionControlStateStore: SessionControlStateStore? = nil,
        sessionReminderStore: SessionReminderStore? = nil,
        historySavingsNoticeStore: HistorySavingsNoticeStore? = nil,
        sessionReminderScheduler: (any SessionReminderScheduling)? = nil,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil,
        sessionListNow: @escaping () -> Date = Date.init,
        sessionListSleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.appStore = appStore
        self.conversationStore = conversationStore
        self.logStore = logStore
        self.contextStore = contextStore ?? SessionContextStore()
        self.eventReducer = EventReducer()
        if let recentWorkspaceStore {
            self.recentWorkspaceStore = recentWorkspaceStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.RecentWorkspaces.\(UUID().uuidString)") ?? .standard
            self.recentWorkspaceStore = RecentWorkspaceStore(defaults: defaults)
        } else {
            self.recentWorkspaceStore = RecentWorkspaceStore()
        }
        if let sessionListPreferenceStore {
            self.sessionListPreferenceStore = sessionListPreferenceStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionListPreferences.\(UUID().uuidString)") ?? .standard
            self.sessionListPreferenceStore = SessionListPreferenceStore(defaults: defaults)
        } else {
            self.sessionListPreferenceStore = SessionListPreferenceStore()
        }
        if let sessionControlStateStore {
            self.sessionControlStateStore = sessionControlStateStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionControlStates.\(UUID().uuidString)") ?? .standard
            self.sessionControlStateStore = SessionControlStateStore(defaults: defaults)
        } else {
            self.sessionControlStateStore = SessionControlStateStore()
        }
        if let sessionReminderStore {
            self.sessionReminderStore = sessionReminderStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.SessionReminders.\(UUID().uuidString)") ?? .standard
            self.sessionReminderStore = SessionReminderStore(defaults: defaults)
        } else {
            self.sessionReminderStore = SessionReminderStore()
        }
        if let historySavingsNoticeStore {
            self.historySavingsNoticeStore = historySavingsNoticeStore
        } else if clientFactory != nil {
            let defaults = UserDefaults(suiteName: "SessionStore.HistorySavingsNotice.\(UUID().uuidString)") ?? .standard
            self.historySavingsNoticeStore = HistorySavingsNoticeStore(defaults: defaults)
        } else {
            self.historySavingsNoticeStore = HistorySavingsNoticeStore()
        }
        if let sessionReminderScheduler {
            self.sessionReminderScheduler = sessionReminderScheduler
        } else if clientFactory != nil {
            self.sessionReminderScheduler = NoopSessionReminderScheduler()
        } else {
            self.sessionReminderScheduler = UserNotificationSessionReminderScheduler()
        }
        self.clientFactory = clientFactory ?? { try appStore.makeSessionStoreAPIClient() }
        self.webSocketFactory = webSocketFactory ?? { appStore.makeSessionWebSocketClient() }
        if let sessionWebSocketFactory {
            self.sessionWebSocketFactory = sessionWebSocketFactory
        } else if webSocketFactory == nil {
            self.sessionWebSocketFactory = { appStore.makeSessionWebSocketClient(for: $0) }
        } else {
            self.sessionWebSocketFactory = nil
        }
        self.webSocketReconnectDelayNanoseconds = webSocketReconnectDelayNanoseconds ?? Self.defaultWebSocketReconnectDelayNanoseconds
        self.sessionListNow = sessionListNow
        self.sessionListSleep = sessionListSleep
        self.dismissedHistorySavingsNoticeEndpoints = self.historySavingsNoticeStore.loadDismissedEndpoints()
        reloadSessionListPreferences()
        reloadSessionControlStates()
        reloadSessionReminders()
    }

    private static func defaultWebSocketReconnectDelayNanoseconds(attempt: Int) -> UInt64 {
        let boundedAttempt = max(1, min(attempt, 4))
        let seconds = UInt64(1 << (boundedAttempt - 1))
        return seconds * 1_000_000_000
    }

    private static func safePreviewFilename(_ rawName: String) -> String {
        let fallback = "preview"
        let lastComponent = (rawName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastComponent.isEmpty else {
            return fallback
        }
        let blocked = CharacterSet(charactersIn: "/\\:\u{0}")
        let cleaned = lastComponent
            .components(separatedBy: blocked)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    var selectedProject: AgentProject? {
        guard let selectedProjectID else {
            return nil
        }
        return sidebarProjectsByID[selectedProjectID] ?? projectsByID[selectedProjectID]
    }

    var selectedSession: AgentSession? {
        guard let selectedSessionID else {
            return nil
        }
        return sessionsByID[selectedSessionID]
    }

    var selectedThreadGoal: ThreadGoal? {
        guard let session = selectedSession else {
            return nil
        }
        return Self.matchingThreadGoal(for: session, context: contextStore.context(for: session.id))
    }

    var selectedForegroundActivity: SessionForegroundActivity? {
        if isRefreshingSelectedSession {
            return .refreshing
        }
        guard let selectedSessionID else {
            return nil
        }
        guard selectedSession?.isRunning == true else {
            return nil
        }
        return foregroundActivityBySessionID[selectedSessionID]
    }

    var selectedRuntimeActivitySnapshot: RuntimeActivitySnapshot? {
        guard let selectedSessionID else {
            return nil
        }
        guard selectedSession?.isRunning == true else {
            return nil
        }
        return runtimeActivityBySessionID[selectedSessionID]
    }

    func foregroundActivity(for sessionID: SessionID) -> SessionForegroundActivity? {
        guard sessionsByID[sessionID]?.isRunning == true else {
            return nil
        }
        return foregroundActivityBySessionID[sessionID]
    }

    func runtimeActivitySnapshot(for sessionID: SessionID) -> RuntimeActivitySnapshot? {
        guard sessionsByID[sessionID]?.isRunning == true else {
            return nil
        }
        return runtimeActivityBySessionID[sessionID]
    }

    var selectedGitStatusPath: String? {
        if let session = selectedSession, !session.dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.dir
        }
        return selectedProject?.path
    }

    var selectedCommandActionPath: String? {
        selectedGitStatusPath
    }

    var selectedCommandActions: [AgentCommandAction] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return commandActionsByPath[path] ?? []
    }

    var selectedCommandActionErrorMessage: String? {
        guard let path = selectedCommandActionPath else {
            return nil
        }
        return commandActionErrorByPath[path]
    }

    var selectedCommandActionResult: CommandActionRunResponse? {
        guard let path = selectedCommandActionPath else {
            return nil
        }
        return commandActionResultByPath[path]
    }

    var selectedCommandActionHistory: [CommandActionRunResponse] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return commandActionHistoryByPath[path] ?? []
    }

    var selectedQueuedCommandActionIDs: [String] {
        guard let path = selectedCommandActionPath else {
            return []
        }
        return queuedCommandActionIDsByPath[path] ?? []
    }

    var isRunningCommandAction: Bool {
        runningCommandActionID != nil
    }

    var selectedGitStatus: GitStatusResponse? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitStatusByPath[path]
    }

    var selectedGitStatusErrorMessage: String? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitStatusErrorByPath[path]
    }

    var selectedGitActionErrorMessage: String? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitActionErrorByPath[path]
    }

    var selectedPullRequestURL: String? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return pullRequestStatusByPath[path]?.url ?? pullRequestURLByPath[path]
    }

    var selectedPullRequestStatus: GitPullRequestStatusResponse? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return pullRequestStatusByPath[path]
    }

    var selectedPullRequestStatusErrorMessage: String? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return pullRequestStatusErrorByPath[path]
    }

    var connectionBadgeTitle: String? {
        guard let selectedSession else {
            return nil
        }
        guard selectedSession.isRunning else {
            if selectedSession.isAppServerHistory {
                return "历史"
            }
            return selectedSession.status == "closed" ? "已结束" : selectedSession.status
        }
        return webSocketStatus.title
    }

    var filteredSessions: [AgentSession] {
        let base: [AgentSession]
        guard let selectedProjectID else {
            base = sortedAllSessions
            return sessionsMatchingSearch(base)
        }
        base = sortedSessionsByProjectID[selectedProjectID] ?? []
        return sessionsMatchingSearch(base)
    }

    /// 会话库不跟随 selectedProjectID 过滤；根侧栏和会话页始终看到同一份跨工作区轻量索引。
    var sessionLibrarySessions: [AgentSession] {
        sessionsMatchingSearch(Self.sortedSessions(sessions.filter(isListableSession)))
    }

    /// 最近列表严格按活动时间排序，置顶只影响完整会话库，不改变“最近”的时间语义。
    var recentSessions: [AgentSession] {
        Array(Self.sortedSessions(sessions.filter(isListableSession)).prefix(8))
    }

    var filteredSidebarProjects: [AgentProject] {
        guard isSessionSearchActive else {
            return sidebarProjects
        }
        return sidebarProjects.filter { project in
            projectMatchesSearch(project) || !sessionsMatchingSearch(sortedSessionsByProjectID[project.id] ?? []).isEmpty
        }
    }

    var sessionSidebarProjects: [AgentProject] {
        guard let sessionWorkspaceIDs else {
            return sidebarProjects
        }
        return sidebarProjects.filter { sessionWorkspaceIDs.contains($0.id) }
    }

    var filteredSessionSidebarProjects: [AgentProject] {
        let projects = effectiveSessionSidebarProjects
        guard isSessionSearchActive else {
            return projects
        }
        return projects.filter { project in
            projectMatchesSearch(project) || !sessionsMatchingSearch(sortedSessionsByProjectID[project.id] ?? []).isEmpty
        }
    }

    private var effectiveSessionSidebarProjects: [AgentProject] {
        let projects = sessionSidebarProjects
        guard selectedSessionID != nil,
              let selectedProjectID,
              !projects.contains(where: { $0.id == selectedProjectID })
        else {
            return projects
        }

        // 当前正在查看的会话必须在左侧保留上下文；这里只做临时补项，不写回工作区筛选偏好。
        return sidebarProjects.filter { project in
            project.id == selectedProjectID || projects.contains(where: { $0.id == project.id })
        }
    }

    var sessionWorkspaceSelectionCount: Int {
        sessionSidebarProjects.count
    }

    var isSessionSearchActive: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    func isShowingAllSessions(projectID: String) -> Bool {
        sessionVisibleLimit(forProjectID: projectID) > Self.sessionPreviewLimit
    }

    func sessions(forProjectID projectID: String) -> [AgentSession] {
        sortedSessionsByProjectID[projectID] ?? []
    }

    func isSessionPinned(_ sessionID: SessionID) -> Bool {
        pinnedSessionIDs.contains(sessionID)
    }

    func isSessionArchived(_ sessionID: SessionID) -> Bool {
        archivedSessionIDs.contains(sessionID)
    }

    func isWorkspaceShownInSessions(_ projectID: String) -> Bool {
        sessionWorkspaceIDs?.contains(projectID) ?? true
    }

    func toggleWorkspaceInSessions(_ project: AgentProject) {
        let allProjectIDs = Set(sidebarProjects.map(\.id))
        var next = sessionWorkspaceIDs ?? allProjectIDs
        if next.contains(project.id) {
            next.remove(project.id)
            setStatusMessage("已从会话移除 \(project.name)")
        } else {
            next.insert(project.id)
            setStatusMessage("已在会话显示 \(project.name)")
        }
        setSessionWorkspaceIDs(next.intersection(allProjectIDs))
    }

    func resetSessionWorkspaceSelection() {
        setStatusMessage("会话已恢复显示全部工作区")
        setSessionWorkspaceIDs(nil)
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        let sessions = sessions(forProjectID: projectID)
        let limit = min(sessionVisibleLimit(forProjectID: projectID), sessions.count)
        return Array(sessions.prefix(limit))
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        let sessions = sessions(forProjectID: projectID)
        return max(0, sessions.count - min(sessionVisibleLimit(forProjectID: projectID), sessions.count))
    }

    func canLoadMoreSessions(projectID: String) -> Bool {
        sessionHasMoreByProjectID[projectID] == true
    }

    func sessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        sessionListSnapshotsByProjectID[projectID] ?? makeProjectSessionListSnapshot(forProjectID: projectID)
    }

    func controlState(for session: AgentSession) -> SessionControlState {
        if let state = sessionControlStateByID[session.id] {
            return state
        }
        return session.isRunning ? .observing : .takenOver
    }

    func canControlSession(_ session: AgentSession?) -> Bool {
        guard let session else {
            return true
        }
        guard session.isRunning else {
            return true
        }
        return controlState(for: session).isControllable
    }

    var canSendInSelectedSession: Bool {
        canControlSession(selectedSession) && selectedQuotaNotice?.blocksSending != true
    }

    var selectedQuotaNotice: CodexQuotaNotice? {
        CodexQuotaNotice.make(rateLimit: selectedSession?.rateLimit, errorMessage: errorMessage)
    }

    var selectedCodexUsageDisplay: CodexUsageDisplaySummary? {
        CodexUsageDisplaySummary.make(rateLimit: selectedSession?.rateLimit)
    }

    var accountCodexUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestCodexRateLimit)
    }

    private var latestCodexRateLimit: RateLimitSummary? {
        if let rateLimit = selectedSession?.rateLimit {
            return rateLimit
        }
        if let rateLimit = mostRecentSessionRateLimit(preferCodexRuntime: true) {
            return rateLimit
        }
        return mostRecentSessionRateLimit(preferCodexRuntime: false)
    }

    private func mostRecentSessionRateLimit(preferCodexRuntime: Bool) -> RateLimitSummary? {
        sessions
            .filter { session in
                guard session.rateLimit != nil else {
                    return false
                }
                guard preferCodexRuntime else {
                    return true
                }
                return session.runtimeProvider?.lowercased() == "codex"
                    || session.source.lowercased() == "codex"
            }
            .sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            .first?
            .rateLimit
    }

    var isSelectedSessionObserving: Bool {
        guard let session = selectedSession else {
            return false
        }
        return isSessionObserving(session)
    }

    func isSessionObserving(_ session: AgentSession) -> Bool {
        session.isRunning && !canControlSession(session)
    }

    var selectedSessionControlNotice: String? {
        guard isSelectedSessionObserving else {
            return nil
        }
        return "这个会话正在其他客户端运行，iPad 当前仅观察。接管后才会发送新消息或处理审批。"
    }

    func takeOverSession(_ session: AgentSession) {
        setSessionControlState(.takenOver, sessionID: session.id)
        if session.id == selectedSessionID, session.isRunning {
            // 接管前消息区已经由 selectSession/刷新用 thread/read 快照兜底；backlog 走状态级
            // 回放（completed 内容仍会补播），完整回放会把旧 delta 再直播一遍。
            connectWebSocket(session, replayBufferedEvents: false)
        }
        setStatusMessage("已接管到 iPad")
    }

    func takeOverSelectedSession() {
        guard let session = selectedSession else {
            return
        }
        takeOverSession(session)
    }

    func canLoadEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return historyHasMoreBeforeBySessionID[sessionID] == true
    }

    var selectedHistorySavingsNotice: HistorySavingsNotice? {
        guard let selectedSessionID else {
            return nil
        }
        return historySavingsNoticesBySessionID[selectedSessionID]
    }

    func isLoadingEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return loadingEarlierHistorySessionIDs.contains(sessionID)
    }

    func historyLoadProgress(sessionID: SessionID?) -> HistoryLoadProgress? {
        guard let sessionID else {
            return nil
        }
        return historyLoadProgressBySessionID[sessionID]
    }

    func bootstrap(restoring snapshot: SessionRestoreSnapshot? = nil) async {
#if DEBUG
        if appStore.shouldSeedDebugWorkbenchUI {
            applyDebugWorkbenchUISeedIfNeeded()
            return
        }
#endif
        guard appStore.isConfigured else {
            return
        }
        _ = await refreshConnectionRoute(preferPrimary: true)
        // 冷启动有两层“没就绪”：① VPN / Tailscale 隧道还没建好，首个 HTTP 请求就失败；
        // ② agentd 的 HTTP 端口先于 app-server gateway 上游就绪——projects 能立刻拿到，但首个
        // 会话请求 / WebSocket 连接会因为上游还没接受连接而失败。scenePhase 的 .active 回调在
        // 冷启动不会触发（没有 background→active 切换），所以这里必须自己退避重试，直到数据
        // 真正加载完成。否则只要 projects 一到手就收手，首屏会停在“有项目、无会话、点什么都
        // 连不上”的半成品状态，只能靠用户杀进程重开才恢复。
        await refreshUntilLoaded(maxWait: 45, autoAttach: true)
        if let snapshot {
            await restoreSessionIfPossible(snapshot)
        }
    }

    private func restoreSessionIfPossible(_ snapshot: SessionRestoreSnapshot) async {
        guard AgentAPIClient.normalizedEndpoint(snapshot.endpoint) == AgentAPIClient.normalizedEndpoint(appStore.endpoint),
              let workspace = ensureWorkspaceForKnownProjectID(snapshot.session.projectID)
        else { return }

        // 先让 runtime 从真实 thread/list 建立 session→provider 路由；旧会话不在首屏时再使用本地轻量快照。
        do {
            let page = try await sessionListFirstPage(workspace: workspace, limit: Self.initialSessionPageLimit, reuseRecent: true)
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateSessionPageState(projectID: workspace.id, page: page)
        } catch {
            // 恢复快照仍须经过工作区授权校验；单次列表失败不应让用户丢掉上次阅读位置。
        }

        let restored = sessionsByID[snapshot.session.id] ?? session(snapshot.session, in: workspace)
        guard restored.projectID == workspace.id else { return }
        mergeSessionPage([restored])
        await selectSession(restored)
    }

#if DEBUG
    private func applyDebugWorkbenchUISeedIfNeeded() {
        guard !didApplyDebugWorkbenchUISeed else {
            return
        }
        didApplyDebugWorkbenchUISeed = true

        let now = Date()
        let debugRateLimit = RateLimitSummary(
            limitName: "Codex",
            planType: "pro",
            primaryUsedPercent: 62,
            secondaryUsedPercent: 38,
            primaryResetsAt: Int64(now.addingTimeInterval(60 * 82).timeIntervalSince1970),
            secondaryResetsAt: Int64(now.addingTimeInterval(60 * 60 * 24 * 3).timeIntervalSince1970),
            hasCredits: true,
            creditsUnlimited: false,
            creditBalance: "18.40"
        )
        let chatArchive = AgentWorkspace(
            id: "debug-chat-archive",
            name: "chat-archive",
            path: "/Users/demo/code/chat-archive",
            rootProjectID: "debug-chat-archive",
            rootProjectName: "chat-archive",
            rootProjectPath: "/Users/demo/code/chat-archive",
            lastOpenedAt: now.addingTimeInterval(-60 * 8)
        )
        let ipadAgent = AgentWorkspace(
            id: "debug-ipad-agent",
            name: "codex-ipad-agent",
            path: "/Users/demo/code/codex-ipad-agent",
            rootProjectID: "debug-ipad-agent",
            rootProjectName: "codex-ipad-agent",
            rootProjectPath: "/Users/demo/code/codex-ipad-agent",
            lastOpenedAt: now.addingTimeInterval(-60 * 35)
        )
        let selectedSessionID = "debug-session-layout"
        let runningSessionID = "debug-session-running"
        let sessions = [
            AgentSession(
                id: selectedSessionID,
                projectID: chatArchive.id,
                project: chatArchive.name,
                dir: chatArchive.path,
                title: "优化三栏边界和工具按钮",
                status: SessionStatus.completed.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: selectedSessionID,
                createdAt: now.addingTimeInterval(-60 * 40),
                updatedAt: now.addingTimeInterval(-60 * 3),
                preview: "统一左栏、对话区和右侧详情栏的边界，并把操作按钮收成一组。",
                rateLimit: debugRateLimit
            ),
            AgentSession(
                id: runningSessionID,
                projectID: chatArchive.id,
                project: chatArchive.name,
                dir: chatArchive.path,
                title: "整理会话历史摘要",
                status: SessionStatus.running.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: runningSessionID,
                createdAt: now.addingTimeInterval(-60 * 110),
                updatedAt: now.addingTimeInterval(-60 * 1),
                preview: "正在检查最近会话的摘要展示和输入区状态。",
                activeTurnID: "debug-turn-running"
            ),
            AgentSession(
                id: "debug-session-workspace",
                projectID: ipadAgent.id,
                project: ipadAgent.name,
                dir: ipadAgent.path,
                title: "工作区卡片视觉微调",
                status: SessionStatus.closed.rawValue,
                source: "debug",
                runtimeProvider: "codex",
                resumeID: "debug-session-workspace",
                createdAt: now.addingTimeInterval(-60 * 180),
                updatedAt: now.addingTimeInterval(-60 * 28),
                preview: "卡片等高、选中态和加入会话按钮需要更稳定。"
            )
        ]

        isLoading = false
        setErrorMessage(nil)
        setStatusMessage("Debug UI 样例已加载")
        setProjectsIfChanged([chatArchive.project, ipadAgent.project])
        setRecentWorkspacesIfChanged([chatArchive, ipadAgent])
        sessionWorkspaceIDs = nil
        setExpandedProjectIDs([chatArchive.id])
        replaceSessionsIfChanged(with: sessions, projectID: nil)
        setSelectedProjectID(chatArchive.id)
        setSelectedSessionID(selectedSessionID)
        webSocketStatus = .disconnected
        disconnectWebSocket()
        seedDebugConversationMessages(sessionID: selectedSessionID, now: now)
        seedDebugConversationMessages(sessionID: runningSessionID, now: now.addingTimeInterval(-60 * 10))
        rebuildProjectSessionListSnapshots()
    }

    private func seedDebugConversationMessages(sessionID: SessionID, now: Date) {
        let history = [
            CodexHistoryMessage(
                id: "\(sessionID)-user-1",
                role: "user",
                content: "帮我把会话页左侧和右侧的边界重新看一下，按钮不要显得零散。",
                createdAt: now.addingTimeInterval(-60 * 18),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-user-1",
                timelineOrdinal: 1
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-assistant-1",
                role: "assistant",
                content: "我会把维护动作收进统一工具组，并让左右栏使用一致的 sidebar 背景和分割线。左栏空态会放进列表内部，避免和标题或主内容区互相抢位置。",
                createdAt: now.addingTimeInterval(-60 * 16),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-assistant-1",
                timelineOrdinal: 2
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-summary-1",
                role: "system",
                kind: .reasoningSummary,
                content: "已完成布局整理：左栏列表内空态、顶部胶囊工具组、右侧详情栏边界统一。",
                createdAt: now.addingTimeInterval(-60 * 14),
                turnID: "\(sessionID)-turn-1",
                itemID: "\(sessionID)-item-summary-1",
                timelineOrdinal: 3
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-user-2",
                role: "user",
                content: "很好，再确认一下没有选中会话和选中会话时都不要出现奇怪的漂浮 icon。",
                createdAt: now.addingTimeInterval(-60 * 6),
                turnID: "\(sessionID)-turn-2",
                itemID: "\(sessionID)-item-user-2",
                timelineOrdinal: 4
            ),
            CodexHistoryMessage(
                id: "\(sessionID)-assistant-2",
                role: "assistant",
                content: "空态会保留一个明确的主行动按钮；有会话时，刷新和右栏入口保持同一组原生 SF Symbol 控件。这样用户能一眼知道哪里是导航、哪里是当前对话、哪里是辅助信息。",
                createdAt: now.addingTimeInterval(-60 * 4),
                turnID: "\(sessionID)-turn-2",
                itemID: "\(sessionID)-item-assistant-2",
                timelineOrdinal: 5
            )
        ]
        conversationStore.replaceHistorySnapshot(history, sessionID: sessionID)
    }

    private var isDebugWorkbenchUISeedActive: Bool {
        appStore.shouldSeedDebugWorkbenchUI && didApplyDebugWorkbenchUISeed
    }
#endif

    // refreshAll 成功拿到数据、或后端确实为空时都会清空 errorMessage；只要还有 errorMessage，
    // 就说明 projects / sessions / gateway 至少有一环没就绪，需要继续重试让首屏自愈。
    //
    // 冷启动失败基本是后端还没就绪（agentd / 隧道未通，或 app-server 上游还没接受连接），这类失败
    // 都很快返回，所以用较短的固定退避高频轮询：后端一就绪就能在 ~1s 内被探测到并自愈，而不是用
    // 慢退避白等。按总时长封顶而非固定次数，后端晚十几二十秒才起来也能等到，不会提前放弃又卡回
    // “要杀进程”的老问题。
    @discardableResult
    private func refreshConnectionRoute(preferPrimary: Bool) async -> Bool {
        do {
            let selectedEndpoint = try await appStore.prepareReachableRoute(preferPrimary: preferPrimary)
            guard selectedEndpoint != appStore.activeEndpoint else {
                return false
            }
            // 路由切换是连接代次边界：先停止旧订阅，再让所有新 client 读取同一个 active endpoint。
            disconnectWebSocket()
            let changed = try appStore.activateConnectionRoute(selectedEndpoint)
            if changed {
                setStatusMessage("已切换到\(appStore.activeConnectionRouteTitle)")
            }
            return changed
        } catch {
            // 这里不覆盖业务错误；refreshAll 会给出更具体的 projects / gateway 失败原因。
            return false
        }
    }

    private func refreshUntilLoaded(maxWait: TimeInterval, autoAttach: Bool) async {
        let deadline = Date().addingTimeInterval(max(0, maxWait))
        var attempt = 0
        while true {
            await refreshAll(autoAttach: autoAttach)
            if errorMessage == nil {
                return
            }
            if Task.isCancelled || Date() >= deadline {
                return
            }
            // Gateway 已明确给出 retryAfter 时必须尊重该窗口；继续按 0.3/0.9 秒探测只会把一次限流
            // 放大成重试风暴，也不能把业务限流误判成主链路故障并切到备用地址。
            if let workspace = selectedProjectID.flatMap({ workspacesByID[$0] }),
               let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
                attempt += 1
                await sessionListSleep(cooldownDelay)
                if Task.isCancelled { return }
                continue
            }
            if await refreshConnectionRoute(preferPrimary: false) {
                continue
            }
            // 普通隧道/启动失败仍保留原来的快速恢复节奏。
            let backoffNanoseconds: UInt64 = attempt == 0 ? 300_000_000 : 900_000_000
            attempt += 1
            await sessionListSleep(backoffNanoseconds)
            if Task.isCancelled { return }
        }
    }

    func refreshAll(autoAttach: Bool = false) async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("Debug UI 样例不会连接后端")
            return
        }
#endif
        isLoading = true
        defer { isLoading = false }
        let connectionGeneration = appStore.connectionGeneration
        var requestToken: Int?
        var requestProjectID: String?
        var activeWorkspace: AgentWorkspace?
        do {
            let client = try clientFactory()
            let previousProjectID = selectedProjectID
            let previousSessionID = selectedSessionID
            let fetchedProjects = try await client.projects()
            guard connectionGeneration == appStore.connectionGeneration else {
                return
            }
            setProjectsIfChanged(fetchedProjects)
            reloadRecentWorkspaces()
            if let previousProjectID,
               sidebarProjectsByID[previousProjectID] == nil,
               let project = projectsByID[previousProjectID] {
                _ = ensureWorkspace(for: project)
            }
            let validProjectIDs = Self.projectIDs(sidebarProjects)
            setExpandedProjectIDs(expandedProjectIDs.intersection(validProjectIDs))
            setShowingAllSessionProjectIDs(showingAllSessionProjectIDs.intersection(validProjectIDs))
            sessionPageCursorByProjectID = sessionPageCursorByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionHasMoreByProjectID = sessionHasMoreByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionPageRequestTokenByProjectID = sessionPageRequestTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionPageLoadingTokenByProjectID = sessionPageLoadingTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            rebuildProjectSessionListSnapshots()
            let projectID = previousProjectID.flatMap { id in
                sidebarProjectsByID[id] == nil ? nil : id
            } ?? (autoAttach ? sidebarProjects.first?.id : nil)
            setSelectedProjectID(projectID)
            guard let projectID else {
                replaceSessionsIfChanged(with: [], projectID: nil)
                setSelectedSessionID(nil)
                disconnectWebSocket()
                setStatusMessage(sidebarProjects.isEmpty ? "尚未打开工作区" : "已加载 \(sidebarProjects.count) 个最近工作区")
                setErrorMessage(nil)
                return
            }

            requestProjectID = projectID
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            guard let workspace = workspacesByID[projectID] else {
                setSelectedProjectID(nil)
                setSelectedSessionID(nil)
                setStatusMessage("工作区已失效，请重新打开")
                setErrorMessage(nil)
                return
            }
            activeWorkspace = workspace
            // refreshAll 也必须进入首屏列表 single-flight。否则它与前台轮询或手动刷新重叠时，
            // 会向 gateway 发出两个相同 thread/list，后发请求被保护策略拒绝为 -32080。
            // reuseRecent=false 只绕过短缓存，不绕过正在执行的共享请求，仍保持全量刷新的语义。
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: false
            )
            guard connectionGeneration == appStore.connectionGeneration else {
                return
            }
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingLoadedWindow(pageSessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)

            if let previousSessionID, let session = sessionsByID[previousSessionID] {
                // 刷新或重新保存设置不能抢走用户已经点选的历史会话。
                setSelectedProjectID(session.projectID)
                setSelectedSessionID(session.id)
                revealProjectInSidebar(session.projectID)
                await prepareSelectedSessionAfterRefresh(session, autoAttach: autoAttach)
            } else if autoAttach, let runningSession = sessions(forProjectID: projectID).first(where: \.isRunning) {
                // iPad 冷启动/回前台时，如果当前没有明确选中的会话，优先恢复正在运行的会话。
                // 这会触发 direct app-server 的 thread/resume，让残留审批等运行态问题有机会自愈。
                setSelectedProjectID(runningSession.projectID)
                setSelectedSessionID(runningSession.id)
                revealProjectInSidebar(runningSession.projectID)
                await prepareSelectedSessionAfterRefresh(runningSession, autoAttach: true)
            } else {
                setSelectedSessionID(nil)
            }

            setStatusMessage("已加载 \(sidebarProjects.count) 个最近工作区，\(filteredSessions.count) 个会话")
            setErrorMessage(nil)
        } catch {
            if let requestProjectID, let requestToken, !isCurrentSessionPageRequest(projectID: requestProjectID, token: requestToken) {
                return
            }
            if let activeWorkspace {
                // 已经拿到 projects、只是这个工作区的会话加载失败：单独判定该工作区可用性，
                // 避免把“某个 recent 失效”冒泡成整页错误，也避免冷启动退避一直重试一个已删除目录。
                await handleWorkspaceLoadFailure(workspace: activeWorkspace, error: error)
            } else {
                setErrorMessage(error.localizedDescription)
            }
        }
    }

    func selectProject(_ project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("已选择 Debug 工作区 \(project.name)")
            return
        }
#endif
        disconnectWebSocket()
        await refreshSessions(forProjectID: workspace.id)
    }

    /// 只刷新工作区目录，不改变当前会话选择，也不重建 WebSocket。
    /// 工作区页浏览和手动刷新必须与会话运行态隔离，避免用户查看目录时打断长任务。
    func refreshWorkspaceCatalog() async throws {
        let fetchedProjects = try await clientFactory().projects()
        setProjectsIfChanged(fetchedProjects)

        var nextWorkspaces = recentWorkspaces
        let knownIDs = Set(nextWorkspaces.map(\.id))
        for project in fetchedProjects where !knownIDs.contains(project.id) {
            nextWorkspaces.append(AgentWorkspace(project: project))
        }
        nextWorkspaces.sort { lhs, rhs in
            let lhsDate = lhs.lastOpenedAt ?? .distantPast
            let rhsDate = rhs.lastOpenedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        recentWorkspaceStore.save(nextWorkspaces, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(nextWorkspaces)
    }

    @discardableResult
    func openWorkspace(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setErrorMessage("请输入开发环境中的目录路径")
            return false
        }
        do {
            // 走 clientFactory（与会话请求同一个注入点）而不是 appStore.client()，
            // 让 resolve 和后续会话加载共用一条可测试链路。
            let workspace = try await clientFactory().resolveWorkspace(path: trimmed)
            rememberWorkspace(workspace)
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)
            return true
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func openWorkspace(project: AgentProject) async -> Bool {
        await openWorkspace(path: project.path)
    }

    @discardableResult
    func createWorktreeAndOpen(project: AgentProject, name: String? = nil, base: String? = nil, branch: String? = nil) async -> Bool {
        isCreatingWorktree = true
        defer { isCreatingWorktree = false }
        do {
            let response = try await clientFactory().createWorktree(
                path: project.path,
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                base: base?.trimmingCharacters(in: .whitespacesAndNewlines),
                branch: branch?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let workspace = response.workspace
            // Worktree 成功创建后作为一个普通 workspace 接入，后续 thread/list 和 thread/start 复用现有 cwd 安全链路。
            rememberWorkspace(workspace)
            upsertManagedWorktree(WorktreeListItem(workspace: workspace, worktree: response.worktree))
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)
            return true
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func handoffSessionToWorktree(_ session: AgentSession, name: String? = nil, base: String? = nil, branch: String? = nil) async -> Bool {
        guard !session.isRunning else {
            setErrorMessage("运行中的会话不能直接转到 Worktree，请先停止或等待完成。")
            return false
        }
        let rootProjectID = rootProjectID(forProjectID: session.projectID)
        guard let rootWorkspace = ensureWorkspaceForKnownProjectID(rootProjectID) else {
            setErrorMessage("来源会话的根项目已失效，请重新打开工作区。")
            return false
        }

        isCreatingWorktree = true
        defer { isCreatingWorktree = false }
        do {
            // handoff 仍然创建真实 managed Worktree，再用普通 thread/start 启动新线程；
            // 不伪造历史迁移，避免跨 cwd resume 带来不可预测状态。
            let response = try await clientFactory().createWorktree(
                path: rootWorkspace.path,
                name: normalizedOptional(name) ?? defaultHandoffWorktreeName(for: session),
                base: normalizedOptional(base),
                branch: normalizedOptional(branch)
            )
            let workspace = response.workspace
            rememberWorkspace(workspace)
            upsertManagedWorktree(WorktreeListItem(workspace: workspace, worktree: response.worktree))
            clearWorkspaceUnavailable(workspace.id)
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            insertExpandedProjectID(workspace.id)
            setErrorMessage(nil)
            worktreeErrorMessage = nil
            disconnectWebSocket()
            await refreshSessions(forProjectID: workspace.id)

            let sourceThreadID = normalizedOptional(session.resumeID) ?? session.id
            do {
                let forked = try await clientFactory().forkSession(threadID: sourceThreadID, workspace: workspace)
                let responseSession = self.session(forked, in: workspace)
                upsert(responseSession)
                setSelectedProjectID(responseSession.projectID)
                setSelectedSessionID(responseSession.id)
                insertExpandedProjectID(responseSession.projectID)
                await loadHistoryIfNeeded(for: responseSession)
                if responseSession.isRunning {
                    connectWebSocket(responseSession)
                } else {
                    disconnectWebSocket()
                }
                conversationStore.appendSystem("已从来源会话 fork 到这个 Worktree。", sessionID: responseSession.id)
                setStatusMessage("已 fork 到新 Worktree")
                return true
            } catch {
                setStatusMessage("原生 fork 不可用，改用提示式 Worktree 交接：\(error.localizedDescription)")
            }

            var options = CodexAppServerTurnOptions.default
            options.sessionStartSource = "mimi_remote_worktree_handoff"
            options.threadSource = "worktree_handoff"
            let prompt = worktreeHandoffPrompt(
                source: session,
                rootWorkspace: rootWorkspace,
                targetWorkspace: workspace,
                worktree: response.worktree
            )
            let started = await createSession(
                projectID: workspace.id,
                payload: CodexAppServerTurnPayload(prompt: prompt, options: options),
                resume: nil,
                clientMessageID: UUID().uuidString
            )
            if started {
                setStatusMessage("已转到新 Git Worktree")
            }
            return started
        } catch {
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func defaultHandoffWorktreeName(for session: AgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "handoff" : "handoff-\(String(title.prefix(36)))"
    }

    private func worktreeHandoffPrompt(
        source session: AgentSession,
        rootWorkspace: AgentWorkspace,
        targetWorkspace: AgentWorkspace,
        worktree: WorktreeDescriptor
    ) -> String {
        let sourceThreadID = normalizedOptional(session.resumeID) ?? session.id
        let branch = normalizedOptional(worktree.branch) ?? "未命名分支"
        let preview = normalizedOptional(session.preview).map { "\n来源摘要：\($0)" } ?? ""
        return """
        请在这个新的 Worktree 中继续处理来源会话的任务。

        来源会话：
        - 标题：\(session.title)
        - 线程 ID：\(sourceThreadID)
        - 原工作区：\(rootWorkspace.path)\(preview)

        新 Worktree：
        - 路径：\(targetWorkspace.path)
        - Base：\(worktree.base)
        - 分支：\(branch)

        继续要求：
        1. 先检查当前目录的 Git 状态和关键文件。
        2. 不要假设原工作区的未提交改动已经复制到这里；这个 Worktree 是从上面的 Base 创建的隔离 checkout。
        3. 如果需要来源会话更完整的上下文，请先向我确认要补充哪些信息。
        """
    }

    func worktreeBranches(path: String) -> WorktreeBranchListResponse? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return worktreeBranchesByPath[trimmed]
    }

    func worktreeBranchError(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return worktreeBranchErrorByPath[trimmed]
    }

    func refreshWorktreeBranches(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        isRefreshingWorktreeBranches = true
        defer { isRefreshingWorktreeBranches = false }
        do {
            // 分支列表是只读建议值：缓存服务端 canonical path，同时保留调用方原始 key，避免 /var 和 /private/var 这类路径差异影响 UI 命中。
            let response = try await clientFactory().worktreeBranches(path: trimmed)
            worktreeBranchesByPath[trimmed] = response
            worktreeBranchesByPath[response.path] = response
            worktreeBranchErrorByPath.removeValue(forKey: trimmed)
            worktreeBranchErrorByPath.removeValue(forKey: response.path)
        } catch {
            worktreeBranchErrorByPath[trimmed] = error.localizedDescription
        }
    }

    func refreshManagedWorktrees() async {
        isRefreshingWorktrees = true
        defer { isRefreshingWorktrees = false }
        do {
            let worktrees = try await clientFactory().listWorktrees()
            setManagedWorktreesIfChanged(worktrees)
            worktreeErrorMessage = nil
        } catch {
            worktreeErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func pruneMissingManagedWorktrees() async -> Int {
        isPruningWorktrees = true
        defer { isPruningWorktrees = false }
        do {
            let response = try await clientFactory().pruneMissingWorktrees()
            setManagedWorktreesIfChanged(response.worktrees)
            worktreeErrorMessage = nil
            let count = response.prunedPaths.count
            setStatusMessage(count == 0 ? "没有需要清理的 Worktree 登记" : "已清理 \(count) 条丢失的 Worktree 登记")
            return count
        } catch {
            worktreeErrorMessage = error.localizedDescription
            return 0
        }
    }

    func managedWorktrees(rootProjectID: String) -> [WorktreeListItem] {
        let root = rootProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            return []
        }
        return managedWorktrees.filter { $0.worktree.rootProjectID == root }
    }

    func rootProjectID(forProjectID projectID: String) -> String {
        workspacesByID[projectID]?.rootProjectID ?? projectID
    }

    func hasRunningSession(in worktree: WorktreeListItem) -> Bool {
        sessions.contains { session in
            session.projectID == worktree.workspace.id && session.isRunning
        }
    }

    @discardableResult
    func openManagedWorktree(_ item: WorktreeListItem) async -> Bool {
        let workspace = item.workspace
        rememberWorkspace(workspace)
        clearWorkspaceUnavailable(workspace.id)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
        worktreeErrorMessage = nil
        disconnectWebSocket()
        await refreshSessions(forProjectID: workspace.id)
        return true
    }

    @discardableResult
    func deleteManagedWorktree(_ item: WorktreeListItem, force: Bool = false) async -> Bool {
        if hasRunningSession(in: item) {
            worktreeErrorMessage = "该 Worktree 还有运行中的会话，先停止会话后再删除。"
            return false
        }

        let workspace = item.workspace
        isDeletingWorktree = true
        defer { isDeletingWorktree = false }
        do {
            let response = try await clientFactory().deleteWorktree(path: workspace.path, force: force)
            setManagedWorktreesIfChanged(response.worktrees)
            forgetWorkspaceAfterWorktreeDeletion(workspace)
            gitStatusByPath.removeValue(forKey: workspace.path)
            gitStatusErrorByPath.removeValue(forKey: workspace.path)
            gitActionErrorByPath.removeValue(forKey: workspace.path)
            commandActionsByPath.removeValue(forKey: workspace.path)
            commandActionErrorByPath.removeValue(forKey: workspace.path)
            commandActionResultByPath.removeValue(forKey: workspace.path)
            commandActionHistoryByPath.removeValue(forKey: workspace.path)
            queuedCommandActionRuns.removeAll { $0.path == workspace.path }
            queuedCommandActionIDsByPath.removeValue(forKey: workspace.path)
            worktreeBranchesByPath.removeValue(forKey: workspace.path)
            worktreeBranchErrorByPath.removeValue(forKey: workspace.path)
            pullRequestURLByPath.removeValue(forKey: workspace.path)
            pullRequestStatusByPath.removeValue(forKey: workspace.path)
            pullRequestStatusErrorByPath.removeValue(forKey: workspace.path)
            worktreeErrorMessage = nil
            setStatusMessage("已删除 Git Worktree \(workspace.name)")
            return true
        } catch {
            worktreeErrorMessage = error.localizedDescription
            return false
        }
    }

    // 目录浏览只读不改状态，错误交给调用方（打开面板内联展示），不污染全局 errorMessage。
    func listDirectories(path: String) async throws -> DirectoryListResponse {
        try await clientFactory().listDirectories(path: path)
    }

    // 文件预览同样不污染全局错误状态：后端只返回授权边界内的普通文件，客户端落到临时目录后交给 QuickLook。
    func previewFile(path: String) async throws -> URL {
        let response = try await clientFactory().readFile(path: path)
        return try Self.previewURL(from: response)
    }

    // 历史图片走 app-server gateway 的短期缓存 ID，不阻塞会话文字首屏；点按后再落到临时文件预览。
    func previewHistoryMedia(id: String) async throws -> URL {
        let response = try await clientFactory().readHistoryMedia(id: id)
        return try Self.previewURL(from: response)
    }

    private static func previewURL(from response: FileReadResponse) throws -> URL {
        guard let data = Data(base64Encoded: response.contentBase64) else {
            throw FilePreviewStoreError.invalidPayload
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MimiRemotePreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = Self.safePreviewFilename(response.name)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(filename)", isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    func refreshSelectedCommandActions() async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshCommandActions(path: path)
    }

    func refreshCommandActions(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        isRefreshingCommandActions = true
        defer { isRefreshingCommandActions = false }
        do {
            let actions = try await clientFactory().commandActions(path: targetPath)
            // action 是 agentd 配置里的 allowlist，只按工作区 path 缓存，避免跨会话串结果。
            commandActionsByPath[targetPath] = actions
            commandActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            commandActionsByPath[targetPath] = []
            commandActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func runSelectedCommandAction(_ action: AgentCommandAction) async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await runCommandAction(path: path, id: action.id, confirmed: action.requiresConfirmation)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool = false) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !actionID.isEmpty else {
            return
        }

        let run = QueuedCommandActionRun(path: targetPath, id: actionID, confirmed: confirmed)
        if isRunningCommandAction {
            enqueueCommandActionRun(run)
            return
        }

        await drainCommandActionRuns(startingWith: run)
    }

    private func enqueueCommandActionRun(_ run: QueuedCommandActionRun) {
        queuedCommandActionRuns.append(run)
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        ids.append(run.id)
        queuedCommandActionIDsByPath[run.path] = ids
    }

    private func dequeueCommandActionRun() -> QueuedCommandActionRun? {
        guard !queuedCommandActionRuns.isEmpty else {
            return nil
        }
        let run = queuedCommandActionRuns.removeFirst()
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        if let index = ids.firstIndex(of: run.id) {
            ids.remove(at: index)
        }
        if ids.isEmpty {
            queuedCommandActionIDsByPath.removeValue(forKey: run.path)
        } else {
            queuedCommandActionIDsByPath[run.path] = ids
        }
        return run
    }

    private func drainCommandActionRuns(startingWith firstRun: QueuedCommandActionRun) async {
        var nextRun: QueuedCommandActionRun? = firstRun
        while let run = nextRun {
            await performCommandActionRun(run)
            nextRun = dequeueCommandActionRun()
        }
    }

    private func performCommandActionRun(_ run: QueuedCommandActionRun) async {
        runningCommandActionPath = run.path
        runningCommandActionID = run.id
        defer {
            runningCommandActionPath = nil
            runningCommandActionID = nil
        }
        do {
            let response = try await clientFactory().runCommandAction(path: run.path, id: run.id, confirmed: run.confirmed)
            commandActionResultByPath[run.path] = response
            var history = commandActionHistoryByPath[run.path] ?? []
            // 执行历史只做本地短缓存，不写后端，避免命令输出长期留存在配置服务里。
            history.insert(response, at: 0)
            if history.count > Self.commandActionHistoryLimit {
                history.removeLast(history.count - Self.commandActionHistoryLimit)
            }
            commandActionHistoryByPath[run.path] = history
            commandActionErrorByPath.removeValue(forKey: run.path)
        } catch {
            commandActionErrorByPath[run.path] = error.localizedDescription
        }
    }

    func refreshSelectedGitStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshGitStatus(path: path)
    }

    func refreshGitStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        isRefreshingGitStatus = true
        defer { isRefreshingGitStatus = false }
        do {
            let status = try await clientFactory().gitStatus(path: targetPath)
            // Git 状态是只读辅助信息，按路径缓存；用户切换会话后，旧请求只会更新旧路径缓存。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performSelectedGitAction(_ action: GitActionKind, files: [String]) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitAction(path: path, action: action, files: files)
    }

    func performGitAction(path: String, action: GitActionKind, files: [String]) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetFiles = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targetPath.isEmpty, !targetFiles.isEmpty else {
            return
        }

        isRunningGitAction = true
        defer { isRunningGitAction = false }
        do {
            let status = try await clientFactory().gitAction(path: targetPath, action: action, files: targetFiles)
            // 写动作成功后直接采用服务端返回的新状态，避免前端本地推断 Git index。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performSelectedGitPatchAction(_ action: GitActionKind, patch: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitPatchAction(path: path, action: action, patch: patch)
    }

    func performGitPatchAction(path: String, action: GitActionKind, patch: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !targetPatch.isEmpty else {
            return
        }

        isRunningGitAction = true
        defer { isRunningGitAction = false }
        do {
            let status = try await clientFactory().gitPatchAction(path: targetPath, action: action, patch: targetPatch)
            // hunk 操作同样以服务端返回为准，避免本地解析 patch 后再二次推断状态。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func commitSelectedGitChanges(message: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await commitGitChanges(path: path, message: message)
    }

    func commitGitChanges(path: String, message: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return
        }

        isCommittingGitChanges = true
        defer { isCommittingGitChanges = false }
        do {
            let status = try await clientFactory().gitCommit(path: targetPath, message: commitMessage)
            // commit 只提交已暂存内容；成功后用服务端状态清理 staged diff 和文件列表。
            gitStatusByPath[targetPath] = status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func pushSelectedGitBranch(remote: String? = nil) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await pushGitBranch(path: path, remote: remote)
    }

    func pushGitBranch(path: String, remote: String? = nil) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        isPushingGitBranch = true
        defer { isPushingGitBranch = false }
        do {
            let response = try await clientFactory().gitPush(path: targetPath, remote: targetRemote?.isEmpty == true ? nil : targetRemote)
            gitStatusByPath[targetPath] = response.status
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func createSelectedPullRequest(title: String, body: String = "", draft: Bool = true) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await createPullRequest(path: path, title: title, body: body, draft: draft)
    }

    func createPullRequest(path: String, title: String, body: String = "", draft: Bool = true) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let prTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !prTitle.isEmpty else {
            return
        }

        isCreatingPullRequest = true
        defer { isCreatingPullRequest = false }
        do {
            let response = try await clientFactory().gitCreatePullRequest(path: targetPath, title: prTitle, body: body, draft: draft)
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
                pullRequestStatusByPath[targetPath] = GitPullRequestStatusResponse(
                    path: targetPath,
                    branch: response.branch,
                    exists: true,
                    title: prTitle,
                    url: url,
                    isDraft: draft
                )
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshSelectedPullRequestStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshPullRequestStatus(path: path)
    }

    func refreshPullRequestStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        isRefreshingPullRequestStatus = true
        defer { isRefreshingPullRequestStatus = false }
        do {
            let response = try await clientFactory().gitPullRequestStatus(path: targetPath)
            pullRequestStatusByPath[targetPath] = response
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
        } catch {
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func forgetWorkspace(_ project: AgentProject) {
        let next = recentWorkspaceStore.forget(id: project.id, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        clearSessionReminders(forProjectID: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            setSelectedProjectID(nil)
            setSelectedSessionID(nil)
            disconnectWebSocket()
        }
        setStatusMessage("已从当前设备移除 \(project.name)")
    }

    func toggleSessionPinned(_ session: AgentSession) {
        if pinnedSessionIDs.contains(session.id) {
            pinnedSessionIDs.remove(session.id)
            setStatusMessage("已取消置顶 \(session.title)")
        } else {
            archivedSessionIDs.remove(session.id)
            pinnedSessionIDs.insert(session.id)
            setStatusMessage("已置顶 \(session.title)")
        }
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }

    func toggleSessionArchived(_ session: AgentSession) {
        if archivedSessionIDs.contains(session.id) {
            archivedSessionIDs.remove(session.id)
            setStatusMessage("已取消归档 \(session.title)")
        } else {
            archivedSessionIDs.insert(session.id)
            pinnedSessionIDs.remove(session.id)
            setStatusMessage("已归档 \(session.title)")
        }
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }

    @discardableResult
    func toggleSessionArchivedRemote(_ session: AgentSession) async -> Bool {
        let shouldArchive = !archivedSessionIDs.contains(session.id)
        toggleSessionArchived(session)
        do {
            try await clientFactory().setSessionArchived(id: session.id, archived: shouldArchive)
            setStatusMessage(shouldArchive ? "已归档远端会话 \(session.title)" : "已取消远端归档 \(session.title)")
            return true
        } catch {
            setStatusMessage(
                shouldArchive
                    ? "已在本地归档，远端归档失败：\(error.localizedDescription)"
                    : "已在本地取消归档，远端取消失败：\(error.localizedDescription)"
            )
            return false
        }
    }

    func sessionReminder(for sessionID: SessionID) -> SessionReminder? {
        sessionRemindersByID[sessionID]
    }

    func scheduleSessionReminder(_ session: AgentSession, after interval: TimeInterval, now: Date = Date()) async {
        let boundedInterval = max(60, interval)
        let reminder = SessionReminder(
            sessionID: session.id,
            title: session.title,
            fireAt: now.addingTimeInterval(boundedInterval),
            createdAt: now
        )
        sessionRemindersByID[session.id] = reminder
        saveSessionReminders()

        do {
            // 先持久化，再尽力交给系统通知；即使用户未授权通知，侧栏仍能显示提醒状态。
            try await sessionReminderScheduler.schedule(reminder)
            setStatusMessage("已设置提醒 \(session.title)")
        } catch {
            setStatusMessage("已保存提醒，但通知调度失败：\(error.localizedDescription)")
        }
    }

    func clearSessionReminder(_ session: AgentSession) {
        sessionRemindersByID.removeValue(forKey: session.id)
        saveSessionReminders()
        sessionReminderScheduler.cancel(sessionID: session.id)
        setStatusMessage("已清除提醒 \(session.title)")
    }

    func isWorkspaceUnavailable(_ projectID: String) -> Bool {
        unavailableWorkspaceIDs.contains(projectID)
    }

    // 用户在 Mac 上恢复目录或修好配置后，点“重试”重新校验并加载；resolve 通过即自动清除不可用标记。
    func retryWorkspace(_ project: AgentProject) async {
        clearWorkspaceUnavailable(project.id)
        setErrorMessage(nil)
        await refreshSessions(forProjectID: project.id)
    }

    func toggleProjectExpansion(_ project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        if expandedProjectIDs.contains(workspace.id) {
            removeExpandedProjectID(workspace.id)
            removeShowingAllSessionProjectID(workspace.id)
            return
        }

        insertExpandedProjectID(workspace.id)
        if selectedProjectID != workspace.id {
            setSelectedProjectID(workspace.id)
            setSelectedSessionID(nil)
            setErrorMessage(nil)
            disconnectWebSocket()
        }
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("Debug UI 样例已展开 \(project.name)")
            return
        }
#endif
        await refreshSessions(forProjectID: workspace.id)
    }

    func toggleSessionListExpansion(projectID: String) async {
        let currentLimit = sessionVisibleLimit(forProjectID: projectID)
        let loadedCount = sessions(forProjectID: projectID).count
        let isFullyExpanded = currentLimit > Self.sessionPreviewLimit &&
            currentLimit >= loadedCount &&
            !canLoadMoreSessions(projectID: projectID)

        if isFullyExpanded {
            setSessionVisibleLimit(nil, forProjectID: projectID)
            return
        }

        let nextLimit = currentLimit + Self.sessionExpansionStep
        setSessionVisibleLimit(nextLimit, forProjectID: projectID)
        if canLoadMoreSessions(projectID: projectID), nextLimit >= loadedCount {
            await loadMoreSessions(projectID: projectID)
        }
    }

    func loadMoreSessions(projectID: String) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return
        }
        projectID = workspace.id
        guard let cursor = sessionPageCursorByProjectID[projectID],
              canLoadMoreSessions(projectID: projectID),
              sessionPageLoadingTokenByProjectID[projectID] == nil
        else {
            return
        }
        var requestToken: Int?
        do {
            let client = try clientFactory()
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await client.sessionsPage(workspace: workspace, cursor: cursor, limit: Self.expandedSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            mergeSessionPage(sessions(page.sessions, in: workspace))
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
            setErrorMessage(nil)
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshSelectedProjectSessions(showLoading: Bool = true) async {
        guard let selectedProjectID else {
            return
        }
        await refreshSessions(forProjectID: selectedProjectID, showLoading: showLoading)
    }

    /// 为单一全局侧栏加载跨工作区轻量索引。只取 thread/list 首屏，不读取任何消息历史。
    func refreshSessionLibraryIndex() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else { return }
#endif
        // 全局“最近”最终只展示 8 条，但要得到正确的全局 Top 8，必须读取每个已打开工作区的
        // 首屏候选；不能先截断工作区，否则较早打开的工作区即使刚有新会话也永远不会入选。
        let workspaces = recentWorkspaces.filter { workspace in
            // 当前工作区已经由 refreshAll/轮询维护完整首屏时，会话库直接复用本地投影。
            // 再用 limit=8 请求一次会和 limit=20 共用 gateway 预算，却无法命中 exact single-flight。
            !(workspace.id == selectedProjectID && !sessions(forProjectID: workspace.id).isEmpty)
        }
        guard !workspaces.isEmpty else { return }
        let generation = appStore.connectionGeneration

        // 两个一组并发，兼顾首屏速度和本机 app-server 压力；底层继续复用 single-flight/短缓存。
        for start in stride(from: 0, to: workspaces.count, by: 2) {
            guard generation == appStore.connectionGeneration, !Task.isCancelled else { return }
            let first = workspaces[start]
            if start + 1 < workspaces.count {
                let second = workspaces[start + 1]
                async let firstResult = sessionLibraryPage(workspace: first)
                async let secondResult = sessionLibraryPage(workspace: second)
                let results = await [firstResult, secondResult]
                mergeSessionLibraryPages(results, generation: generation)
            } else {
                let result = await sessionLibraryPage(workspace: first)
                mergeSessionLibraryPages([result], generation: generation)
            }
        }
    }

    func pollSelectedProjectSessionsWhileVisible() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: sessionListPollingDelayNanoseconds())
            } catch {
                return
            }
#if DEBUG
            guard !isDebugWorkbenchUISeedActive else {
                continue
            }
#endif
            guard appStore.isConfigured, selectedProjectID != nil else {
                continue
            }
            await refreshSelectedProjectSessions(showLoading: false)
        }
    }

    private func sessionListPollingDelayNanoseconds() -> UInt64 {
        webSocketStatus == .connected
            ? sessionListConnectedPollingDelayNanoseconds
            : sessionListDisconnectedPollingDelayNanoseconds
    }

    func refreshCodexUsage() async {
        do {
            let summary = try await clientFactory().refreshRateLimit(sessionID: selectedSessionID)
            guard let summary, var session = selectedSession else {
                return
            }
            session.rateLimit = summary
            upsert(session)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshCurrentContext() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("Debug UI 样例不会连接后端")
            return
        }
#endif
        guard let session = selectedSession else {
            await refreshAll(autoAttach: false)
            return
        }
        await refreshSelectedSessionContent(session)
    }

    func loadFullHistoryForSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        await refreshSelectedSessionContent(session, successStatusMessage: "已加载完整历史", reason: .manualFull)
    }

    func loadSummaryHistoryForSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        _ = await loadHistory(
            for: session,
            quiet: false,
            loadMode: .economy,
            force: true,
            reason: .summaryChoice,
            successStatusMessage: "已加载缩略历史"
        )
    }

    func dismissSelectedHistorySavingsNotice() {
        if let selectedSessionID {
            historySavingsNoticesBySessionID.removeValue(forKey: selectedSessionID)
        }
    }

    func dismissErrorMessage() {
        setErrorMessage(nil)
    }

    func refreshAppServerModelOptions(force: Bool = false) async {
        if isRefreshingAppServerModels {
            return
        }
        if !force,
           !appServerModelOptions.isEmpty,
           let appServerModelOptionsLastRefresh,
           Date().timeIntervalSince(appServerModelOptionsLastRefresh) < 300 {
            return
        }

        isRefreshingAppServerModels = true
        defer { isRefreshingAppServerModels = false }
        do {
            let client = try clientFactory()
            let options = try await client.modelOptions()
            appServerModelOptionsLastRefresh = Date()
            if !options.isEmpty || force {
                appServerModelOptions = options
            }
            if force {
                setStatusMessage(options.isEmpty ? "未发现 app-server 模型列表，继续使用内置选项" : "已刷新模型列表")
            }
        } catch {
            appServerModelOptionsLastRefresh = Date()
            if force {
                setStatusMessage("模型列表不可用，继续使用内置选项")
            }
        }
    }

    private func payloadResolvingRequiredModel(_ payload: CodexAppServerTurnPayload) async -> CodexAppServerTurnPayload {
        var resolved = payload
        let lockedRuntimeProvider = selectedSessionRuntimeProviderForTurn()
        if let lockedRuntimeProvider {
            let requestedRuntimeProvider = Self.normalizedRuntimeProvider(resolved.options.runtimeProvider)
            if requestedRuntimeProvider != lockedRuntimeProvider {
                // 已有会话的 thread 授权只属于创建它的 runtime。历史 Codex/Claude 会话里如果残留了
                // 另一条渠道的模型选择，必须清掉并回到当前会话 runtime 的默认模型，避免 resume 到错误 gateway。
                resolved.options.runtimeProvider = Self.payloadRuntimeProvider(lockedRuntimeProvider)
                resolved.options.model = nil
                resolved.options.modelProvider = nil
            } else if resolved.options.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                resolved.options.runtimeProvider = Self.payloadRuntimeProvider(lockedRuntimeProvider)
            }
        }
        if let model = resolved.options.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            resolved.options = resolved.options.sanitizedForRuntimePolicy()
            return resolved
        }

        if appServerModelOptions.isEmpty {
            await refreshAppServerModelOptions()
        }
        let allOptions = appServerModelOptions.isEmpty ? CodexAppServerModelOption.builtInFallback : appServerModelOptions
        let targetRuntimeProvider = lockedRuntimeProvider ?? Self.explicitRuntimeProvider(resolved.options.runtimeProvider)
        let options = targetRuntimeProvider.map { runtimeProvider in
            allOptions.filter { Self.normalizedRuntimeProvider($0.runtimeProvider) == runtimeProvider }
        } ?? allOptions
        let candidateOptions: [CodexAppServerModelOption]
        if options.isEmpty, targetRuntimeProvider == "claude" {
            candidateOptions = CodexAppServerModelOption.builtInClaudeFallback
        } else if options.isEmpty, targetRuntimeProvider == "codex" {
            candidateOptions = CodexAppServerModelOption.builtInFallback
        } else {
            candidateOptions = options.isEmpty ? allOptions : options
        }
        guard let selected = candidateOptions.first(where: \.isDefault) ?? candidateOptions.first else {
            resolved.options = resolved.options.sanitizedForRuntimePolicy()
            return resolved
        }

        // app-server 的 turn/start 目前要求顶层 model 必填；模型来源必须优先使用
        // model/list 的账号默认值，只有列表不可用时才使用内置兜底，避免 iPad 硬编码旧模型踩 rollout。
        if resolved.options.runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            resolved.options.runtimeProvider = Self.payloadRuntimeProvider(Self.normalizedRuntimeProvider(selected.runtimeProvider))
        }
        resolved.options.model = selected.model
        resolved.options.modelProvider = selected.provider
        resolved.options = resolved.options.sanitizedForRuntimePolicy()
        return resolved
    }

    private func selectedSessionRuntimeProviderForTurn() -> String? {
        guard let session = selectedSession else {
            return nil
        }
        if session.source == "local", session.runtimeProvider == nil {
            return nil
        }
        return Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source)
    }

    private static func explicitRuntimeProvider(_ rawValue: String?) -> String? {
        guard rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return normalizedRuntimeProvider(rawValue)
    }

    private static func normalizedRuntimeProvider(_ rawValue: String?) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(rawValue)
    }

    private static func payloadRuntimeProvider(_ normalizedRuntimeProvider: String) -> String? {
        normalizedRuntimeProvider == "codex" ? nil : normalizedRuntimeProvider
    }

    func refreshCapabilities() async {
        if isRefreshingCapabilities {
            return
        }
        let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        isRefreshingCapabilities = true
        defer { isRefreshingCapabilities = false }
        do {
            let response = try await clientFactory().capabilities(path: path?.isEmpty == true ? nil : path)
            capabilityList = response
            capabilityErrorMessage = nil
        } catch {
            capabilityErrorMessage = error.localizedDescription
        }
    }

    func loadEarlierHistoryForSelectedSession() async {
        guard let session = selectedSession,
              let cursor = historyPreviousCursorBySessionID[session.id],
              canLoadEarlierHistory(sessionID: session.id),
              !loadingEarlierHistorySessionIDs.contains(session.id)
        else {
            return
        }
        loadingEarlierHistorySessionIDs.insert(session.id)
        setHistoryLoadProgress(sessionID: session.id, title: "加载更早消息", fraction: 0.18)
        defer {
            loadingEarlierHistorySessionIDs.remove(session.id)
            clearHistoryLoadProgress(sessionID: session.id)
        }
        do {
            let client = try clientFactory()
            setHistoryLoadProgress(sessionID: session.id, title: "请求历史分页", fraction: 0.42)
            let page = try await client.messagesPage(
                sessionID: session.id,
                before: cursor,
                limit: historyLoadedQualityBySessionID[session.id] == .summary ? economyHistoryPageLimit : fullHistoryPageLimit,
                loadMode: historyLoadedQualityBySessionID[session.id] == .summary ? .economy : .full
            )
            setHistoryLoadProgress(sessionID: session.id, title: "解析历史消息", fraction: 0.76)
            ingestHistoryContext(page.context, fallbackSessionID: session.id)
            conversationStore.setHistory(
                page.messages,
                sessionID: session.id,
                authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
            )
            setHistoryLoadProgress(sessionID: session.id, title: "更新界面", fraction: 0.94)
            updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: false)
            setErrorMessage(nil)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func returnToSessionList() {
        let wasAlreadyOnList = selectedSessionID == nil
            && errorMessage == nil
            && connectedSessionID == nil
            && webSocket == nil
            && webSocketStatus == .disconnected
            && pendingApprovalDecisionIDsBySessionID.isEmpty
            && pendingUserInputResponseIDsBySessionID.isEmpty
            && pendingUserInputRequestsBySessionID.isEmpty
        guard !wasAlreadyOnList else {
            return
        }
        setSelectedSessionID(nil)
        setErrorMessage(nil)
        disconnectWebSocket()
    }

    func resetConnectionForSettingsChange(clearData: Bool = false) {
        disconnectWebSocket()
        if clearData {
            clearConnectionData()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
    }

    @discardableResult
    func applyConnectionSettings(
        endpoint: String,
        fallbackEndpoint: String,
        token: String
    ) async throws -> Bool {
        let prepared = try await appStore.prepareConnectionSettings(
            endpoint: endpoint,
            fallbackEndpoint: fallbackEndpoint,
            token: token
        )
        return try commitPreparedConnection(prepared)
    }

    @discardableResult
    func applyPairingURL(_ url: URL) async throws -> Bool {
        let prepared = try await appStore.preparePairingURL(url)
        return try commitPreparedConnection(prepared)
    }

    private func commitPreparedConnection(_ prepared: PreparedConnectionSettings) throws -> Bool {
        // 连接切换必须先结束旧 WebSocket，再原子提交新的 active endpoint；后续 REST 与
        // WebSocket 都从同一个 runtime bundle 创建，避免一次会话被拆到两条链路上。
        disconnectWebSocket()
        let didChange = try appStore.commitConnectionSettings(prepared)
        if didChange {
            clearConnectionData()
        }
        setErrorMessage(nil)
        setStatusMessage(nil)
        return didChange
    }

    func selectSession(_ session: AgentSession) async {
        if isNoOpHistorySelection(session) {
            return
        }
        let session = sessionForExplicitSelection(session)
        setSelectedProjectID(session.projectID)
        setSelectedSessionID(session.id)
        revealProjectInSidebar(session.projectID)
        setErrorMessage(nil)
        conversationStore.retainSessionCache(sessionID: session.id)
        logStore.retainSessionCache(sessionID: session.id)
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage("已选择 Debug 会话 \(session.title)")
            return
        }
#endif

        if session.isRunning && canControlSession(session) {
            // 重新点回运行会话时，离开期间的输出先用 thread/read 快照一次性补齐；
            // 随后的 WebSocket 只回放状态级 backlog，避免消息区把旧 delta 逐条直播。
            let didRefreshHistory = await loadHistory(for: session)
            connectWebSocket(session, replayBufferedEvents: !didRefreshHistory)
        } else if session.isRunning {
            // 其他客户端正在运行：只读观察，不建立可发送的事件通道。
            await loadHistoryIfNeeded(for: session)
            disconnectWebSocket()
        } else {
            // 非运行会话有两种可能：真历史，或被瞬时 idle 误读降级的运行会话。
            // 已有缓存时先展示缓存、后台静默补一次最新页；同时仍建立事件订阅——
            // thread/resume 的权威状态能立即纠正误判，之后的 turn 事件也能直接推进来，
            // 不再要求手动刷新。
            let didRefreshHistory: Bool
            if conversationStore.hasLoadedHistory(sessionID: session.id) {
                scheduleQuietHistoryRefresh(for: session)
                didRefreshHistory = true
            } else {
                didRefreshHistory = await loadHistoryIfNeeded(for: session)
            }
            connectWebSocket(session, replayBufferedEvents: !didRefreshHistory, allowNonRunning: true)
        }
    }

    // 新建会话在点击瞬间就急切创建空线程并绑定 runtime；不传 runtimeProvider 时由默认模型
    // 决定（当前是 Codex）。要开 Claude 会话必须在这里显式指定，事后无法把线程迁到另一条通道。
    func startNewSession(runtimeProvider: String? = nil) async {
        guard let selectedProjectID else {
            setErrorMessage("请先选择项目")
            return
        }
        await createSession(projectID: selectedProjectID, prompt: "", resume: nil, runtimeProvider: runtimeProvider)
    }

    func startNewSession(in project: AgentProject, runtimeProvider: String? = nil) async {
        let workspace = ensureWorkspace(for: project)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
        disconnectWebSocket()
        await createSession(projectID: workspace.id, prompt: "", resume: nil, runtimeProvider: runtimeProvider)
    }

    var hasClaudeRuntimeChannel: Bool {
        appServerModelOptions.contains { Self.normalizedRuntimeProvider($0.runtimeProvider) == "claude" }
    }

    @discardableResult
    func sendPrompt(_ text: String) async -> Bool {
        await sendTurn(CodexAppServerTurnPayload(prompt: text))
    }

    @discardableResult
    func startGoalTurn(
        payload: CodexAppServerTurnPayload,
        objective: String,
        tokenBudget: Int64? = nil,
        runningDelivery: RunningTurnDelivery = .queued
    ) async -> Bool {
        let normalizedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedObjective.isEmpty else {
            threadGoalErrorMessage = "目标内容不能为空"
            return false
        }
        if let tokenBudget, tokenBudget <= 0 {
            threadGoalErrorMessage = "Token 预算必须大于 0"
            return false
        }
        threadGoalErrorMessage = nil
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }

        if let session = selectedSession, session.isRunning {
            // 运行中目标要先确认实时通道可用；否则会出现目标已写入但任务没有真正发送的中间态。
            guard readyWebSocket(for: session) != nil else {
                return false
            }
            // 运行中 thread 已经绑定了 WebSocket，先更新 thread 级目标，再把同一份输入作为目标任务发送。
            guard await setThreadGoal(
                threadID: session.id,
                objective: normalizedObjective,
                status: .active,
                tokenBudget: tokenBudget
            ) else {
                return false
            }
            let sent = await sendTurn(payload, runningDelivery: runningDelivery)
            if sent {
                setStatusMessage("目标任务已启动")
            }
            return sent
        }

        let resume = selectedSession
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            setErrorMessage("请先选择项目")
            return false
        }
        let started = await createSession(
            projectID: projectID,
            payload: payload,
            resume: resume,
            clientMessageID: UUID().uuidString,
            initialGoalObjective: normalizedObjective
        )
        if started {
            setStatusMessage("目标任务已启动")
        }
        return started
    }

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?, prompt: String?) async throws -> VoiceTranscriptionResponse {
        try await clientFactory().transcribeVoice(
            filename: filename,
            contentType: contentType,
            audioData: audioData,
            language: language,
            prompt: prompt
        )
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload, runningDelivery: RunningTurnDelivery = .queued) async -> Bool {
        guard !payload.isEmpty else {
            return false
        }
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }
        let payload = runningDelivery == .queued ? await payloadResolvingRequiredModel(payload) : payload
        let prompt = payload.previewText

        if let session = selectedSession, session.isRunning {
            guard canControlSession(session) else {
                setErrorMessage("这个会话正在其他客户端运行。请先接管到 iPad，再继续发送。")
                return false
            }
            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            let clientMessageID = UUID().uuidString
            conversationStore.appendLocalUser(
                prompt,
                sessionID: session.id,
                clientMessageID: clientMessageID,
                sendStatus: .sending,
                turnPayload: payload,
                userDelivery: runningDelivery == .guided ? .guided : .queued
            )
            setSessionListProjection(sessionID: session.id, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            let didAcceptLocally: Bool
            switch runningDelivery {
            case .queued:
                didAcceptLocally = socket.sendTurn(payload, clientMessageID: clientMessageID)
            case .guided:
                guard let activeTurnID = session.activeTurnID else {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                    clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                    clearForegroundActivity(sessionID: session.id)
                    setErrorMessage("引导对话失败：当前会话没有活跃 turn")
                    return false
                }
                didAcceptLocally = socket.sendGuidance(payload, clientMessageID: clientMessageID, expectedTurnID: activeTurnID)
            }
            guard didAcceptLocally else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("发送失败：WebSocket 未连接")
                return false
            }
            // 只有后端通道接受首个 turn 后才解除 fresh-empty 保护；本地发送失败时 thread 仍无 rollout。
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
            return true
        }

        let resume = selectedSession
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            setErrorMessage("请先选择项目")
            return false
        }
        return await createSession(projectID: projectID, payload: payload, resume: resume, clientMessageID: UUID().uuidString)
    }

    func sendCtrlC() {
        guard let session = selectedSession, session.isRunning, canControlSession(session) else {
            return
        }
        guard session.activeTurnID != nil else {
            setStatusMessage("当前没有可中断的活动回合")
            return
        }
        guard let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendCtrlC() {
            setErrorMessage("发送 Ctrl-C 失败：WebSocket 未连接")
        }
    }

    func decideApproval(_ approval: ApprovalSummary, accept: Bool) {
        guard let session = selectedSession, session.isRunning else {
            setErrorMessage("审批失败：WebSocket 未连接")
            return
        }
        guard canControlSession(session) else {
            setErrorMessage("这个会话正在其他客户端运行。请先接管到 iPad，再处理审批。")
            return
        }
        guard let socket = readyWebSocket(for: session) else {
            setErrorMessage("审批失败：WebSocket 未连接")
            return
        }
        guard !isApprovalDecisionPending(approval, sessionID: session.id) else {
            setStatusMessage("审批决定正在发送")
            return
        }
        let decision = accept ? "accept" : "decline"
        markApprovalDecisionPending(approval.id, sessionID: session.id)
        guard socket.sendApprovalDecision(approvalID: approval.id, decision: decision, message: nil) else {
            clearPendingApprovalDecision(sessionID: session.id, approvalID: approval.id)
            setErrorMessage("审批发送失败：WebSocket 未连接")
            return
        }
        setStatusMessage(accept ? "批准决定已发送，等待 Agent 继续执行" : "拒绝决定已发送，等待 Agent 确认")
    }

    func isApprovalDecisionPending(_ approval: ApprovalSummary) -> Bool {
        guard let sessionID = selectedSession?.id else {
            return false
        }
        return isApprovalDecisionPending(approval, sessionID: sessionID)
    }

    func respondToUserInput(_ request: AgentUserInputRequest, answers: [String: [String]]) {
        guard let session = selectedSession, session.isRunning else {
            setErrorMessage("补充信息发送失败：WebSocket 未连接")
            return
        }
        guard canControlSession(session) else {
            setErrorMessage("这个会话正在其他客户端运行。请先接管到 iPad，再提交输入。")
            return
        }
        guard let socket = readyWebSocket(for: session) else {
            setErrorMessage("补充信息发送失败：WebSocket 未连接")
            return
        }
        guard !isUserInputResponsePending(request, sessionID: session.id) else {
            setStatusMessage("补充信息正在发送")
            return
        }
        markUserInputResponsePending(request, sessionID: session.id)
        guard socket.sendUserInputResponse(requestID: request.id, answers: answers) else {
            clearPendingUserInputResponse(sessionID: session.id, requestID: request.id)
            setErrorMessage("补充信息发送失败：WebSocket 未连接")
            return
        }
        acceptUserInputResponseLocally(request, sessionID: session.id)
        setStatusMessage("补充信息已发送，等待 Codex 继续")
    }

    func isUserInputResponsePending(_ request: AgentUserInputRequest) -> Bool {
        guard let sessionID = selectedSession?.id else {
            return false
        }
        return isUserInputResponsePending(request, sessionID: sessionID)
    }

    @discardableResult
    func retryFailedUserMessage(_ message: ConversationMessage) async -> Bool {
        guard message.role == .user, message.sendStatus == .failed else {
            return false
        }
        let prompt = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return false
        }
        if let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }

        if let session = selectedSession,
           session.isRunning,
           let clientMessageID = message.clientMessageID {
            guard canControlSession(session) else {
                setErrorMessage("这个会话正在其他客户端运行。请先接管到 iPad，再继续发送。")
                return false
            }
            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            // 失败消息有 client_message_id 时直接复用原 row 重发，避免 timeline 里出现重复用户气泡。
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sending)
            setSessionListProjection(sessionID: session.id, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            let payload = message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt)
            let resolvedPayload = await payloadResolvingRequiredModel(payload)
            guard socket.sendTurn(resolvedPayload, clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearSessionListProjection(sessionID: session.id, clientMessageID: clientMessageID)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("重试失败：WebSocket 未连接")
                return false
            }
            return true
        }

        // 会话已经结束或失败时，沿用普通发送路径重新创建/恢复后端 thread。
        return await sendTurn(message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt))
    }

    func resumeFromForeground() async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            return
        }
#endif
        guard appStore.isConfigured else {
            return
        }
        _ = await refreshConnectionRoute(preferPrimary: true)
        // 回前台同样可能赶上 gateway 还没恢复；做几秒的高频重试，避免单次失败后又卡到下次切换。
        // 正常情况下首次 refreshAll 就成功（errorMessage 为 nil），立即返回，不会有额外开销。
        await refreshUntilLoaded(maxWait: 10, autoAttach: true)
    }

    func stopSelectedSession() async {
        guard let session = selectedSession else {
            return
        }
        guard canControlSession(session) else {
            setErrorMessage("这个会话正在其他客户端运行。请先接管到 iPad，再停止。")
            return
        }
        do {
            let client = try clientFactory()
            try await client.stopSession(id: session.id)
            updateSession(session.id) { item in
                item.status = "closed"
                item.pendingApproval = nil
                item.activeTurnID = nil
            }
            clearForegroundActivity(sessionID: session.id)
            clearRuntimeActivity(sessionID: session.id)
            conversationStore.appendSystem("会话已停止。", sessionID: session.id)
            disconnectWebSocket()
            setStatusMessage("已停止会话")
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            let goal = try await clientFactory().threadGoal(threadID: sessionID)
            if let goal {
                applyThreadGoal(goal, fallbackSessionID: sessionID)
            } else {
                clearThreadGoal(sessionID: sessionID)
            }
        } catch {
            threadGoalErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setThreadGoal(
        threadID: SessionID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async -> Bool {
        let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedObjective, normalizedObjective.isEmpty {
            threadGoalErrorMessage = "目标内容不能为空"
            return false
        }
        if let tokenBudget, tokenBudget <= 0 {
            threadGoalErrorMessage = "Token 预算必须大于 0"
            return false
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            let goal = try await clientFactory().setThreadGoal(
                threadID: threadID,
                objective: normalizedObjective,
                status: status,
                tokenBudget: tokenBudget
            )
            if let status, status != .complete {
                clearLocalCompletedGoalMark(goal, sessionID: threadID)
            }
            applyThreadGoal(goal, fallbackSessionID: threadID, respectsLocalCompletion: false)
            setStatusMessage("目标已更新")
            return true
        } catch {
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func setSelectedThreadGoal(
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async -> Bool {
        guard let sessionID = selectedSessionID else {
            return false
        }
        return await setThreadGoal(threadID: sessionID, objective: objective, status: status, tokenBudget: tokenBudget)
    }

    func updateSelectedThreadGoalStatus(_ status: ThreadGoalStatus) async {
        guard let sessionID = selectedSessionID else {
            return
        }
        _ = await setThreadGoal(threadID: sessionID, objective: nil, status: status, tokenBudget: nil)
    }

    func clearSelectedThreadGoal() async {
        guard let sessionID = selectedSessionID else {
            return
        }
        isUpdatingThreadGoal = true
        threadGoalErrorMessage = nil
        defer { isUpdatingThreadGoal = false }
        do {
            try await clientFactory().clearThreadGoal(threadID: sessionID)
            clearThreadGoal(sessionID: sessionID)
            setStatusMessage("目标已清除")
        } catch {
            threadGoalErrorMessage = error.localizedDescription
            setErrorMessage(error.localizedDescription)
        }
    }

    @discardableResult
    private func createSession(
        projectID: String,
        prompt: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        runtimeProvider: String? = nil
    ) async -> Bool {
        var payload = CodexAppServerTurnPayload(prompt: prompt)
        if let runtimeProvider, !runtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.options.runtimeProvider = runtimeProvider
        }
        return await createSession(projectID: projectID, payload: payload, resume: resume, clientMessageID: clientMessageID)
    }

    @discardableResult
    private func createSession(
        projectID: String,
        payload: CodexAppServerTurnPayload,
        resume: AgentSession?,
        clientMessageID: ClientMessageID? = nil,
        initialGoalObjective: String? = nil
    ) async -> Bool {
        // 空会话只执行 thread/start，没有 turn/start；提前拉 model/list 既不会影响线程创建，
        // 还会在远程链路上平白增加一次串行往返。只有真正要发送首轮输入时才解析模型。
        let payload = payload.isEmpty ? payload : await payloadResolvingRequiredModel(payload)
        if !payload.isEmpty, let notice = selectedQuotaNotice, notice.blocksSending {
            setErrorMessage(notice.message)
            return false
        }
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage("工作区已失效，请重新打开")
            return false
        }
        projectID = workspace.id
        isLoading = true
        defer { isLoading = false }
        let prompt = payload.previewText
        let optimisticSessionID = optimisticSessionID(
            projectID: projectID,
            resume: resume,
            clientMessageID: clientMessageID,
            prompt: prompt
        ) ?? (resume == nil && payload.isEmpty ? "local:\(projectID):\(UUID().uuidString)" : nil)
        if let optimisticSessionID {
            // 空会话也先发布本地占位，让 UI 立即离开创建弹窗；带首轮输入时继续用
            // client_message_id 合并本地气泡，服务端确认后再迁移到真实 session_id。
            if resume == nil {
                upsert(makeOptimisticSession(
                    id: optimisticSessionID,
                    projectID: projectID,
                    prompt: prompt,
                    runtimeProvider: payload.options.runtimeProvider
                ))
            }
            setSelectedProjectID(projectID)
            setSelectedSessionID(optimisticSessionID)
            insertExpandedProjectID(projectID)
            if let clientMessageID {
                conversationStore.appendLocalUser(prompt, sessionID: optimisticSessionID, clientMessageID: clientMessageID, sendStatus: .sending, turnPayload: payload)
                setSessionListProjection(sessionID: optimisticSessionID, preview: prompt, source: .localUser, clientMessageID: clientMessageID)
                setForegroundActivity(.waitingForAssistant, sessionID: optimisticSessionID)
            }
        }

        do {
            let client = try clientFactory()
            let response = try await client.createSession(CreateSessionRequest(
                projectID: projectID,
                projectPath: workspace.path,
                projectName: workspace.name,
                rootProjectID: workspace.rootProjectID,
                prompt: prompt,
                input: payload.input,
                turnOptions: payload.options,
                initialGoalObjective: initialGoalObjective,
                resumeID: resume?.resumeID ?? "",
                clientMessageID: clientMessageID
            ))
            let responseSession = self.session(response.session, in: workspace)

            if let optimisticSessionID,
               optimisticSessionID != responseSession.id {
                // 新建会话会从 local:<project>:<client_message_id> 切换到后端 session_id，
                // 这里迁移前台活动和本地气泡，保持列表/对话 store 解耦。
                if let clientMessageID {
                    conversationStore.moveLocalEcho(clientMessageID: clientMessageID, from: optimisticSessionID, to: responseSession.id)
                    moveSessionListProjection(from: optimisticSessionID, to: responseSession.id, clientMessageID: clientMessageID)
                    migrateForegroundActivity(from: optimisticSessionID, to: responseSession.id)
                    migrateRuntimeActivity(from: optimisticSessionID, to: responseSession.id)
                }
                if resume == nil {
                    removeSession(optimisticSessionID)
                }
            }
            upsert(responseSession)
            setSessionControlState(resume == nil ? .ipadOwned : .takenOver, sessionID: responseSession.id)
            setSelectedProjectID(responseSession.projectID)
            setSelectedSessionID(responseSession.id)
            insertExpandedProjectID(responseSession.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”；
            // 带首轮 prompt 的新会话也保留 thread/read 快照，用它校准后续事件回放。
            // 新建空交互会话没有历史可补；启动后立刻请求完整历史容易撞上后端 thread/read
            // 初始化窗口并误报“大历史加载失败”，因此只跳过这类空会话的首屏补拉。
            let didLoadInitialHistory: Bool
            if hasLoadedFullHistorySnapshot(sessionID: responseSession.id) {
                // 用户刚从历史列表进入时可复用已有快照，避免同一会话立刻再打一次 full。
                didLoadInitialHistory = true
            } else if resume != nil || !payload.isEmpty {
                didLoadInitialHistory = await loadHistoryIfNeeded(for: responseSession)
            } else {
                // 新建空 thread 在首个 turn 前没有 rollout。把当前空快照标成已加载，前台恢复时
                // 就不会误打 thread/turns/list 并把 no-rollout 错报成“大历史加载失败”；首个 turn
                // 会改变 updatedAt/revision/lastSeq，届时签名自然失效并允许正常补拉。
                markEmptyHistoryLoaded(for: responseSession)
                didLoadInitialHistory = true
            }
            if !prompt.isEmpty {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: responseSession.id, status: .sent)
                    conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: responseSession.id)
                } else {
                    conversationStore.appendLocalUser(
                        prompt,
                        sessionID: responseSession.id,
                        clientMessageID: nil,
                        sendStatus: .sent,
                        turnPayload: payload.retainedAfterAcceptedSend()
                    )
                }
                setForegroundActivity(.waitingForAssistant, sessionID: responseSession.id)
            } else {
                conversationStore.appendSystem("交互式会话已启动。", sessionID: responseSession.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: responseSession.id)
                if firstMessage.role == .assistant {
                    setSessionListProjection(sessionID: responseSession.id, preview: firstMessage.content, source: .localAssistant, clientMessageID: nil)
                    clearForegroundActivity(sessionID: responseSession.id)
                }
            }
            if resume != nil {
                conversationStore.appendSystem("已继续这个历史会话。", sessionID: responseSession.id)
            }
            // 历史已成为 canonical 快照后，WS 只需要补连接状态；否则 buffered content replay
            // 会把同一 turn 的过程卡再次 append 到时间线。历史加载失败时仍保留 replay，避免漏消息。
            let shouldReplayBufferedEvents = resume == nil || !didLoadInitialHistory
            connectWebSocket(responseSession, replayBufferedEvents: shouldReplayBufferedEvents)
            setStatusMessage("会话已启动")
            setErrorMessage(nil)
            return true
        } catch {
            if let optimisticSessionID {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: optimisticSessionID, status: .failed)
                    clearSessionListProjection(sessionID: optimisticSessionID, clientMessageID: clientMessageID)
                }
                updateSession(optimisticSessionID) { item in
                    item.status = "failed"
                }
                clearForegroundActivity(sessionID: optimisticSessionID)
            }
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    private func markEmptyHistoryLoaded(for session: AgentSession) {
        conversationStore.replaceHistorySnapshot([], sessionID: session.id)
        historyLoadedSignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historyLoadedQualityBySessionID[session.id] = .full
        freshEmptyHistorySignatureBySessionID[session.id] = HistoryLoadSignature(session: session)
        historySavingsNoticesBySessionID.removeValue(forKey: session.id)
    }

    @discardableResult
    private func loadHistoryIfNeeded(for session: AgentSession) async -> Bool {
        if canReuseFreshEmptyHistory(for: session) {
            return true
        }
        guard !canReuseLoadedHistory(for: session, loadMode: .full) else {
            return true
        }
        return await loadHistory(for: session)
    }

    private func canReuseFreshEmptyHistory(for session: AgentSession) -> Bool {
        guard let baseline = freshEmptyHistorySignatureBySessionID[session.id] else {
            return false
        }
        // thread/start 与 thread/list 的 updatedAt 来源并不稳定，不能用它判断首个 turn 是否存在。
        // 本地首发会主动清除此标记；远端状态若已出现 turn/seq/revision，也立即恢复正常历史补拉。
        let isStillFresh = baseline.revision == session.revision
            && baseline.lastSeq == session.lastSeq
            && session.activeTurnID == nil
        if !isStillFresh {
            freshEmptyHistorySignatureBySessionID.removeValue(forKey: session.id)
        }
        return isStillFresh
    }

    // quiet 模式用于切回已加载会话时的后台补拉：界面继续展示缓存，不出进度条，
    // 失败也不打扰用户（下一次轮询/手动刷新仍会兜底）。
    @discardableResult
    private func loadHistory(
        for session: AgentSession,
        quiet: Bool = false,
        loadMode: HistoryMessagesPage.LoadMode = .full,
        force: Bool = false,
        reason: HistoryLoadReason = .automatic,
        successStatusMessage: String? = nil,
        allowPolicyRetry: Bool = true
    ) async -> Bool {
        if !force, canReuseLoadedHistory(for: session, loadMode: loadMode) {
            return true
        }

        if let existing = historyLoadJobsBySessionID[session.id] {
            if existing.loadMode == loadMode {
                // 已有同模式加载时直接等待同一个 job，避免切换/刷新制造重复大包请求。
                return await awaitHistoryLoadJob(
                    existing,
                    session: session,
                    quiet: quiet,
                    successStatusMessage: successStatusMessage
                )
            }
            switch reason {
            case .summaryChoice, .manualFull:
                cancelHistoryLoadJob(existing, sessionID: session.id)
            case .automatic:
                return true
            }
        }

        let signature = HistoryLoadSignature(session: session)
        let jobToken = beginHistoryLoadJob(sessionID: session.id)
        let limit = loadMode == .full ? fullHistoryPageLimit : economyHistoryPageLimit
        let hasNewerSessionSnapshot = historyLoadedSignatureBySessionID[session.id].map { $0 != signature } == true
        let cachePolicy: HistoryFirstPageCachePolicy = force || hasNewerSessionSnapshot ? .bypass : .reuseRecent
        let task = Task { [self] in
            try await historyFirstPage(
                sessionID: session.id,
                limit: limit,
                loadMode: loadMode,
                cachePolicy: cachePolicy
            )
        }
        let job = HistoryLoadJob(
            token: jobToken,
            sessionSignature: signature,
            loadMode: loadMode,
            allowPolicyRetry: allowPolicyRetry,
            task: task
        )
        historyLoadJobsBySessionID[session.id] = job
        if !quiet {
            setHistoryLoadNotice(sessionID: session.id, kind: loadMode == .full ? .loadingFull : .loadingSummary)
        }

        if !quiet {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? "准备加载完整历史" : "准备加载缩略历史", fraction: 0.08)
        }
        defer {
            if !quiet {
                clearHistoryLoadProgress(sessionID: session.id)
            }
        }

        if !quiet {
            setHistoryLoadProgress(sessionID: session.id, title: loadMode == .full ? "请求完整历史" : "请求缩略历史", fraction: 0.32)
        }
        return await awaitHistoryLoadJob(job, session: session, quiet: quiet, successStatusMessage: successStatusMessage)
    }

    private func scheduleQuietHistoryRefresh(for session: AgentSession) {
        Task { [weak self] in
            guard let self, self.selectedSessionID == session.id else {
                return
            }
            await self.loadHistory(for: session, quiet: true)
        }
    }

    private func canReuseLoadedHistory(for session: AgentSession, loadMode: HistoryMessagesPage.LoadMode) -> Bool {
        guard conversationStore.hasLoadedHistory(sessionID: session.id),
              let loadedSignature = historyLoadedSignatureBySessionID[session.id],
              loadedSignature == HistoryLoadSignature(session: session),
              let loadedQuality = historyLoadedQualityBySessionID[session.id]
        else {
            return false
        }
        // 缩略历史只能满足 summary 视图；当调用方明确需要 full 时必须重新拉完整历史。
        return loadMode == .economy || loadedQuality == .full
    }

    private func hasLoadedFullHistorySnapshot(sessionID: SessionID) -> Bool {
        conversationStore.hasLoadedHistory(sessionID: sessionID)
            && historyLoadedQualityBySessionID[sessionID] == .full
    }

    private func awaitHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        quiet: Bool,
        successStatusMessage: String?
    ) async -> Bool {
        do {
            let result = try await job.task.value
            return finishHistoryLoadJob(
                job,
                result: result,
                sessionID: session.id,
                quiet: quiet,
                successStatusMessage: successStatusMessage
            )
        } catch {
            return await failHistoryLoadJob(job, session: session, error: error, quiet: quiet)
        }
    }

    private func finishHistoryLoadJob(
        _ job: HistoryLoadJob,
        result: HistoryFirstPageResult,
        sessionID: SessionID,
        quiet: Bool,
        successStatusMessage: String?
    ) -> Bool {
        guard historyLoadJobsBySessionID[sessionID]?.token == job.token else {
            // 当前 job 已被用户选择 summary 或新的刷新取代；旧结果可以完成，但不能覆盖界面。
            return historyLoadedSignatureBySessionID[sessionID] == job.sessionSignature
        }
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        guard isCurrentHistoryPageRequest(sessionID: sessionID, token: result.token) else {
            return false
        }
        if !quiet {
            setHistoryLoadProgress(sessionID: sessionID, title: "解析历史消息", fraction: 0.74)
        }
        applyHistoryFirstPage(result.page, sessionID: sessionID)
        if !quiet {
            setHistoryLoadProgress(sessionID: sessionID, title: "更新界面", fraction: 0.94)
        }
        updateHistoryPageState(sessionID: sessionID, page: result.page, preserveExistingCursorOnEmptyPage: true)
        historyLoadedSignatureBySessionID[sessionID] = job.sessionSignature
        historyLoadedQualityBySessionID[sessionID] = job.loadMode == .full ? .full : .summary
        if job.loadMode == .full {
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
        } else if !quiet {
            setHistoryLoadNotice(sessionID: sessionID, kind: .summaryLoaded)
        }
        if let successStatusMessage {
            setStatusMessage(successStatusMessage)
        }
        return true
    }

    private func failHistoryLoadJob(
        _ job: HistoryLoadJob,
        session: AgentSession,
        error: Error,
        quiet: Bool
    ) async -> Bool {
        let sessionID = session.id
        guard historyLoadJobsBySessionID[sessionID]?.token == job.token else {
            return false
        }
        historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        if error is CancellationError {
            return false
        }
        if let failure = error as? HistoryFirstPageFetchFailure,
           !isCurrentHistoryPageRequest(sessionID: sessionID, token: failure.token) {
            return false
        }
        if let policyFailure = historyPolicyFailure(from: error) {
            switch job.loadMode {
            case .full:
                let message = "完整历史内容较大，正在切换缩略历史。"
                if !quiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                return await loadHistory(
                    for: session,
                    quiet: quiet,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: quiet ? nil : "已自动加载缩略历史"
                )
            case .economy where job.allowPolicyRetry:
                let delay = policyFailure.retryAfterNanoseconds ?? historyPolicyRetryFallbackNanoseconds
                let seconds = policyFailure.retryAfterSeconds ?? Int((delay + 999_999_999) / 1_000_000_000)
                let message = "服务器临时限流，\(seconds) 秒后自动重试缩略历史。"
                if !quiet {
                    setHistoryLoadNotice(sessionID: sessionID, kind: .loadingSummary, message: message)
                    setStatusMessage(message)
                }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return false
                }
                if let selectedSessionID, selectedSessionID != sessionID {
                    return false
                }
                return await loadHistory(
                    for: session,
                    quiet: quiet,
                    loadMode: .economy,
                    force: true,
                    reason: .automatic,
                    successStatusMessage: quiet ? nil : "已加载缩略历史",
                    allowPolicyRetry: false
                )
            default:
                break
            }
        }
        if job.loadMode == .full {
            if !quiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .fullFailed)
                setStatusMessage("完整历史加载失败：\(error.localizedDescription)")
            }
        } else {
            // 终态失败必须离开“正在加载”横幅，否则重连触发的静默刷新会让界面永远停在加载中。
            if !quiet {
                setHistoryLoadNotice(sessionID: sessionID, kind: .summaryFailed)
                setErrorMessage("缩略历史加载失败：\(error.localizedDescription)")
            }
        }
        return false
    }

    // gateway 策略拒绝（-32080）对同样的请求参数是确定性失败：自动重连只会带着相同参数再次被拒，
    // 结果是错误横幅无限刷新。历史预算类拒绝（限流/响应过大/pending 过多）是时间窗资源，恢复后
    // 可以成功，这些仍保留重连与 history 重试路径。
    nonisolated static func isDeterministicGatewayPolicyFailure(_ message: String) -> Bool {
        guard message.contains("-32080") else {
            return false
        }
        let lowerMessage = message.lowercased()
        if lowerMessage.contains("thread/turns/list")
            || lowerMessage.contains("thread/read")
            || lowerMessage.contains("history response")
            || lowerMessage.contains("limit/itemsview")
            || message.contains("相同历史或列表请求仍在执行") {
            return false
        }
        return !(message.contains("历史响应")
            || message.contains("临时限流")
            || message.contains("响应过大")
            || message.contains("内容过大")
            || message.contains("请求过多"))
    }

    private func sessionListPolicyFailure(from error: Error) -> SessionListPolicyFailure? {
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = error {
            appServerError = error
        } else {
            appServerError = nil
        }
        let data = appServerError?.data?.objectValue
        let method = data?["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = error.localizedDescription.lowercased()
        let isStructuredListPolicy = appServerError?.code == -32080
            && method == "thread/list"
            && (reason == "history_budget_limited" || reason == "history_request_in_flight")
        let isLegacyListPolicy = message.contains("-32080")
            && message.contains("thread/list")
            && (message.contains("临时限流") || message.contains("相同历史或列表请求"))
        guard isStructuredListPolicy || isLegacyListPolicy else { return nil }

        let fallbackNanoseconds: UInt64 = reason == "history_request_in_flight"
            ? 1_000_000_000
            : 15_000_000_000
        let requestedNanoseconds: UInt64
        if let retryAfterMs = data?["retryAfterMs"]?.intValue, retryAfterMs > 0 {
            requestedNanoseconds = UInt64(retryAfterMs) * 1_000_000
        } else if let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue, retryAfterSeconds > 0 {
            requestedNanoseconds = UInt64(retryAfterSeconds) * 1_000_000_000
        } else {
            requestedNanoseconds = fallbackNanoseconds
        }
        // 防止异常上游把客户端挂起太久；正常 gateway 窗口目前是 1~15 秒。
        let boundedNanoseconds = min(max(requestedNanoseconds, 1_000_000), 60_000_000_000)
        let seconds = max(1, Int((boundedNanoseconds + 999_999_999) / 1_000_000_000))
        return SessionListPolicyFailure(
            retryAfterNanoseconds: boundedNanoseconds,
            retryAfterSeconds: seconds
        )
    }

    private func historyPolicyFailure(from error: Error) -> HistoryPolicyFailure? {
        let underlying = (error as? HistoryFirstPageFetchFailure)?.underlying ?? error
        let message = underlying.localizedDescription
        let lowerMessage = message.lowercased()
        let appServerError: CodexAppServerError?
        if case CodexAppServerConnectionError.appServer(let error) = underlying {
            appServerError = error
        } else {
            appServerError = nil
        }

        let data = appServerError?.data?.objectValue
        let reason = data?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHistoryReason = reason?.hasPrefix("history_") == true
        let isLegacyHistoryPolicyMessage =
            lowerMessage.contains("-32080")
            && (
                lowerMessage.contains("thread/turns/list")
                || lowerMessage.contains("thread/read")
                || lowerMessage.contains("history response")
                || lowerMessage.contains("limit/itemsview")
                || message.contains("历史响应")
                || message.contains("临时限流")
                || message.contains("响应过大")
                || message.contains("内容过大")
            )
        let isGatewayHistoryPolicy = appServerError?.code == -32080 && (isHistoryReason || isLegacyHistoryPolicyMessage)
        guard isGatewayHistoryPolicy || isLegacyHistoryPolicyMessage else {
            return nil
        }

        let retryAfterMs = data?["retryAfterMs"]?.intValue
        let retryAfterSeconds = data?["retryAfterSeconds"]?.intValue
            ?? Self.retryAfterSeconds(fromHistoryPolicyMessage: message)
        let retryAfterNanoseconds: UInt64?
        if let retryAfterMs, retryAfterMs > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterMs) * 1_000_000)
        } else if let retryAfterSeconds, retryAfterSeconds > 0 {
            retryAfterNanoseconds = boundedHistoryPolicyRetryNanoseconds(UInt64(retryAfterSeconds) * 1_000_000_000)
        } else {
            retryAfterNanoseconds = nil
        }
        return HistoryPolicyFailure(retryAfterNanoseconds: retryAfterNanoseconds, retryAfterSeconds: retryAfterSeconds)
    }

    private func boundedHistoryPolicyRetryNanoseconds(_ nanoseconds: UInt64) -> UInt64 {
        min(max(nanoseconds, 1_000_000), historyPolicyRetryMaxNanoseconds)
    }

    nonisolated private static func retryAfterSeconds(fromHistoryPolicyMessage message: String) -> Int? {
        let patterns = [
            #""retryAfterSeconds"\s*:\s*(\d+)"#,
            #""retry_after_seconds"\s*:\s*(\d+)"#,
            #"请\s*(\d+)\s*秒后重试"#
        ]
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            guard let match = regex.firstMatch(in: message, range: range),
                  let secondsRange = Range(match.range(at: 1), in: message),
                  let seconds = Int(message[secondsRange]) else {
                continue
            }
            return seconds
        }
        return nil
    }

    private func cancelHistoryLoadJob(_ job: HistoryLoadJob, sessionID: SessionID) {
        if historyLoadJobsBySessionID[sessionID]?.token == job.token {
            // best-effort 取消旧 job；即使底层请求已发出，token 校验也会阻止迟到结果覆盖当前视图。
            job.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func setHistoryLoadNotice(sessionID: SessionID, kind: HistorySavingsNotice.Kind, message customMessage: String? = nil) {
        let defaultMessage: String
        switch kind {
        case .loadingFull:
            defaultMessage = "正在加载完整历史，内容较大时可能需要等待。"
        case .fullFailed:
            defaultMessage = "完整历史加载失败，可能是内容过大。"
        case .loadingSummary:
            defaultMessage = "正在加载缩略历史。"
        case .summaryLoaded:
            defaultMessage = "当前显示缩略历史。"
        case .summaryFailed:
            defaultMessage = "缩略历史加载失败，可能是网络不稳或服务器限流。"
        }
        let message = customMessage ?? defaultMessage
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(sessionID: sessionID, kind: kind, message: message)
    }

    private func refreshSelectedSessionContent(
        _ session: AgentSession,
        successStatusMessage: String = "当前会话已刷新",
        reason: HistoryLoadReason = .manualFull
    ) async {
        isRefreshingSelectedSession = true
        defer { isRefreshingSelectedSession = false }

        let didLoad = await loadHistory(
            for: session,
            quiet: false,
            loadMode: .full,
            force: true,
            reason: reason,
            successStatusMessage: successStatusMessage
        )
        if didLoad {
            if !session.isRunning {
                clearForegroundActivity(sessionID: session.id)
                clearRuntimeActivity(sessionID: session.id)
            }
            // 手动刷新当前会话只等待历史页接口；列表/运行态校准放到后台，
            // 避免 thread/list 之类的慢接口把“刷新历史”按钮继续卡住。
            scheduleSessionStateReconciliationAfterHistoryRefresh(session)
            setErrorMessage(nil)
        }
    }

    private func historyFirstPage(
        sessionID: SessionID,
        limit: Int,
        loadMode: HistoryMessagesPage.LoadMode,
        cachePolicy: HistoryFirstPageCachePolicy
    ) async throws -> HistoryFirstPageResult {
        let key = HistoryFirstPageRequestKey(sessionID: sessionID, limit: limit, loadMode: loadMode)
        if cachePolicy == .reuseRecent,
           let cached = historyFirstPageCacheByKey[key],
           Date().timeIntervalSince(cached.loadedAt) < historyFirstPageCacheTTL {
            return HistoryFirstPageResult(page: cached.page, token: cached.token)
        }
        if cachePolicy == .reuseRecent,
           let inFlight = historyFirstPageInFlightByKey[key] {
            do {
                return HistoryFirstPageResult(page: try await inFlight.task.value, token: inFlight.token)
            } catch {
                throw HistoryFirstPageFetchFailure(underlying: error, token: inFlight.token)
            }
        }

        let token = beginHistoryPageRequest(sessionID: sessionID)
        let client = try clientFactory()
        let task = Task {
            try await client.messagesPage(
                sessionID: sessionID,
                before: nil,
                limit: limit,
                loadMode: loadMode
            )
        }
        historyFirstPageInFlightByKey[key] = HistoryFirstPageInFlight(token: token, task: task)
        do {
            let page = try await task.value
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
                historyFirstPageCacheByKey[key] = HistoryFirstPageCacheEntry(page: page, loadedAt: Date(), token: token)
            }
            return HistoryFirstPageResult(page: page, token: token)
        } catch {
            if historyFirstPageInFlightByKey[key]?.token == token {
                historyFirstPageInFlightByKey.removeValue(forKey: key)
            }
            throw HistoryFirstPageFetchFailure(underlying: error, token: token)
        }
    }

    private func applyHistoryFirstPage(_ page: HistoryMessagesPage, sessionID: SessionID) {
        ingestHistoryContext(page.context, fallbackSessionID: sessionID)
        conversationStore.replaceHistorySnapshot(
            page.messages,
            sessionID: sessionID,
            authoritativeCompletedTurnItems: page.authoritativeCompletedTurnItems
        )
        updateHistorySavingsNotice(sessionID: sessionID, page: page)
    }

    private func updateHistorySavingsNotice(sessionID: SessionID, page: HistoryMessagesPage) {
        guard page.loadMode == .economy,
              let notice = page.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notice.isEmpty
        else {
            historySavingsNoticesBySessionID.removeValue(forKey: sessionID)
            return
        }
        historySavingsNoticesBySessionID[sessionID] = HistorySavingsNotice(sessionID: sessionID, kind: .summaryLoaded, message: notice)
    }

    private func scheduleSessionStateReconciliationAfterHistoryRefresh(_ session: AgentSession) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.reconcileSessionStateAfterHistoryRefresh(session)
        }
    }

    private func reconcileSessionStateAfterHistoryRefresh(_ session: AgentSession) async {
        if session.isRunning {
            do {
                let client = try clientFactory()
                let response = try await client.session(id: session.id, afterSeq: logStore.lastSeq(for: session.id))
                let refreshed = self.session(response.session, in: workspaceForSession(session))
                upsert(refreshed)
                if !refreshed.isRunning {
                    clearForegroundActivity(sessionID: session.id)
                    clearRuntimeActivity(sessionID: session.id)
                }
                if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                    // recent_output 只作为诊断日志展示；对话内容以 app-server 结构化 history/event 为准。
                    logStore.append(recentOutput, sessionID: session.id, seq: response.lastSeq)
                }
            } catch {
                // 运行态快照读取失败时，后台静默用列表刷新重新同步 app-server 线程状态。
                await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
            }
        } else {
            await refreshSessionListQuietlyIfStillSelected(projectID: session.projectID)
        }
    }

    private func refreshSessionListQuietlyIfStillSelected(projectID: String) async {
        guard selectedProjectID == projectID else {
            return
        }
        await refreshSessions(
            forProjectID: projectID,
            showLoading: false,
            clearErrorOnSuccess: false,
            updateStatusMessage: false,
            reportErrorOnFailure: false
        )
    }

    private func refreshSessions(
        forProjectID projectID: String,
        showLoading: Bool = true,
        clearErrorOnSuccess: Bool = true,
        updateStatusMessage: Bool = true,
        reportErrorOnFailure: Bool = true
    ) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage("工作区已失效，请重新打开")
            return
        }
        projectID = workspace.id
        if selectedProjectID != projectID {
            setSelectedProjectID(projectID)
        }
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }
        var requestToken: Int?
        do {
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: Self.initialSessionPageLimit,
                reuseRecent: !showLoading
            )
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            guard selectedProjectID == projectID else {
                return
            }
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingLoadedWindow(pageSessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
            if updateStatusMessage {
                setStatusMessage("已加载 \(filteredSessions.count) 个会话")
            }
            // 手动刷新/切换工作区成功时可以清掉旧错误；发送后的后台刷新不能抢掉刚产生的发送失败提示。
            if clearErrorOnSuccess {
                setErrorMessage(nil)
            }
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            if reportErrorOnFailure, selectedProjectID == projectID {
                await handleWorkspaceLoadFailure(workspace: workspace, error: error)
            }
        }
    }

    private func sessionLibraryPage(
        workspace: AgentWorkspace
    ) async -> (workspace: AgentWorkspace, page: SessionsPage?) {
        do {
            let page = try await sessionListFirstPage(
                workspace: workspace,
                limit: 8,
                reuseRecent: true
            )
            return (workspace, page)
        } catch {
            // 某个最近工作区失效不能阻断整个会话库；该项目仍可在工作区页单独重试。
            return (workspace, nil)
        }
    }

    private func mergeSessionLibraryPages(
        _ results: [(workspace: AgentWorkspace, page: SessionsPage?)],
        generation: Int
    ) {
        guard generation == appStore.connectionGeneration else { return }
        for result in results {
            guard let page = result.page else { continue }
            mergeSessionPage(sessions(page.sessions, in: result.workspace))
            updateSessionPageState(projectID: result.workspace.id, page: page)
            clearWorkspaceUnavailable(result.workspace.id)
        }
    }

    private func sessionListFirstPage(
        workspace: AgentWorkspace,
        limit: Int,
        reuseRecent: Bool
    ) async throws -> SessionsPage {
        let key = SessionListFirstPageRequestKey(
            connectionGeneration: appStore.connectionGeneration,
            workspaceID: workspace.id,
            workspacePath: workspace.path,
            limit: limit
        )
        // 手动刷新可以绕过短缓存，但同一时刻仍必须等待已存在的共享请求。
        if let inFlight = sessionListFirstPageInFlightByKey[key] {
            return try await inFlight.task.value
        }
        // 会话库只需要 8 条时，可以复用同工作区正在执行的 20 条请求；反向复用会缩短主列表，不能做。
        if let largerInFlight = sessionListFirstPageInFlightByKey.first(where: { entry in
            entry.key.connectionGeneration == key.connectionGeneration
                && entry.key.workspaceID == key.workspaceID
                && entry.key.workspacePath == key.workspacePath
                && entry.key.limit >= key.limit
        })?.value {
            return try await largerInFlight.task.value
        }
        let now = sessionListNow()
        if reuseRecent,
           let cached = sessionListFirstPageCacheByKey[key],
           now.timeIntervalSince(cached.loadedAt) < sessionListFirstPageCacheTTL {
            return cached.page
        }

        if let cooldownDelay = sessionListCooldownDelayNanoseconds(for: workspace) {
            // 已有页时直接保留旧列表；后台轮询会在窗口恢复后自然校准，不让限流冒泡成整页红错。
            if let stale = cachedSessionListPage(workspace: workspace, minimumLimit: limit) {
                return stale
            }
            // 冷启动没有任何可展示数据时才等待窗口并继续请求，保证首屏最终自动恢复。
            await sessionListSleep(cooldownDelay)
        }

        let client = try clientFactory()
        let task = Task {
            try await client.sessionsPage(workspace: workspace, cursor: nil, limit: limit)
        }
        sessionListFirstPageInFlightByKey[key] = SessionListFirstPageInFlight(task: task)
        do {
            let page = try await task.value
            sessionListFirstPageInFlightByKey.removeValue(forKey: key)
            sessionListFirstPageCacheByKey[key] = SessionListFirstPageCacheEntry(page: page, loadedAt: sessionListNow())
            clearSessionListCooldown(for: workspace)
            return page
        } catch {
            sessionListFirstPageInFlightByKey.removeValue(forKey: key)
            if let policyFailure = sessionListPolicyFailure(from: error) {
                registerSessionListCooldown(policyFailure, for: workspace)
            }
            throw error
        }
    }

    private func cachedSessionListPage(workspace: AgentWorkspace, minimumLimit: Int) -> SessionsPage? {
        sessionListFirstPageCacheByKey
            .filter { entry in
                entry.key.connectionGeneration == appStore.connectionGeneration
                    && entry.key.workspaceID == workspace.id
                    && entry.key.workspacePath == workspace.path
                    && entry.key.limit >= minimumLimit
            }
            .max { $0.value.loadedAt < $1.value.loadedAt }?
            .value.page
    }

    private func sessionListBudgetKey(for workspace: AgentWorkspace) -> SessionListBudgetKey {
        let workspacePath = standardizedSessionListPath(workspace.path)
        let rootPath = workspace.rootProjectPath.map(standardizedSessionListPath)
        let cwd: String
        if let rootPath, workspacePath == rootPath || workspacePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
            cwd = rootPath
        } else {
            cwd = workspacePath
        }
        return SessionListBudgetKey(connectionGeneration: appStore.connectionGeneration, cwd: cwd)
    }

    private func standardizedSessionListPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func sessionListCooldownDelayNanoseconds(for workspace: AgentWorkspace) -> UInt64? {
        let key = sessionListBudgetKey(for: workspace)
        guard let until = sessionListCooldownUntilByBudgetKey[key] else { return nil }
        let remaining = until.timeIntervalSince(sessionListNow())
        guard remaining > 0 else {
            sessionListCooldownUntilByBudgetKey.removeValue(forKey: key)
            return nil
        }
        return UInt64(ceil(remaining * 1_000_000_000))
    }

    private func registerSessionListCooldown(_ failure: SessionListPolicyFailure, for workspace: AgentWorkspace) {
        let key = sessionListBudgetKey(for: workspace)
        let until = sessionListNow().addingTimeInterval(Double(failure.retryAfterNanoseconds) / 1_000_000_000)
        if let current = sessionListCooldownUntilByBudgetKey[key], current >= until {
            return
        }
        sessionListCooldownUntilByBudgetKey[key] = until
    }

    private func clearSessionListCooldown(for workspace: AgentWorkspace) {
        sessionListCooldownUntilByBudgetKey.removeValue(forKey: sessionListBudgetKey(for: workspace))
    }

    private func prepareSelectedSessionAfterRefresh(_ session: AgentSession, autoAttach: Bool) async {
        await loadHistoryIfNeeded(for: session)
        if session.isRunning {
            if autoAttach && canControlSession(session) {
                // 前台恢复会反复走到这里；已加载会话的 loadHistoryIfNeeded 是 no-op，此时若做
                // 完整回放，backlog 里的旧卡会被追加到已合并的时间线后面。状态级回放已经
                // 覆盖 completed 内容，足够补齐离开期间的输出。
                connectWebSocket(session, replayBufferedEvents: false)
            } else if !canControlSession(session) {
                disconnectWebSocket()
            }
        } else if autoAttach {
            // 非运行会话回前台也重新订阅：连接重建后 resume 的权威状态能纠正误判，
            // 期间完成的输出走状态级回放 + 静默补拉，不再依赖手动刷新。
            connectWebSocket(session, replayBufferedEvents: false, allowNonRunning: true)
            scheduleQuietHistoryRefresh(for: session)
        } else if connectedSessionID != nil {
            disconnectWebSocket()
        }
    }

    static func replacingSessions(_ current: [AgentSession], with fresh: [AgentSession], projectID: String?) -> [AgentSession] {
        SessionIndexStore.replacingSessions(current, with: fresh, projectID: projectID)
    }

    private func replaceSessionsIfChanged(with fresh: [AgentSession], projectID: String?) {
        let nextFresh = fresh.map(sessionPreparedForStorage)
        let next = Self.replacingSessions(sessions, with: nextFresh, projectID: projectID)
        ingestSessionContexts(next)
        guard next != sessions else {
            return
        }
        sessions = next
    }

    private func pageSessionsPreservingSelection(_ fresh: [AgentSession], projectID: String) -> [AgentSession] {
        guard let selectedSessionID,
              let selected = sessionsByID[selectedSessionID],
              selected.projectID == projectID,
              !fresh.contains(where: { $0.id == selected.id })
        else {
            return fresh
        }
        // 分页首屏只取最近会话；如果用户当前停在更旧的历史，会话行必须保留，
        // 否则前台刷新会把右侧正在看的上下文从列表索引里踢掉。
        return fresh + [selected]
    }

    private func pageSessionsPreservingLoadedWindow(_ fresh: [AgentSession], projectID: String) -> [AgentSession] {
        var result = pageSessionsPreservingSelection(fresh, projectID: projectID)
        guard isShowingAllSessions(projectID: projectID) else {
            return result
        }

        var knownIDs = Set(result.map(\.id))
        let olderLoadedSessions = sessions(forProjectID: projectID).filter { session in
            guard !knownIDs.contains(session.id) else {
                return false
            }
            knownIDs.insert(session.id)
            return true
        }
        guard !olderLoadedSessions.isEmpty else {
            return result
        }
        // 用户已经展开/翻页看到的旧会话属于本地分页窗口；后台首屏刷新只更新最新状态，
        // 不能把这些旧页踢掉，否则列表会在轮询后从“图二”回跳到“图一”。
        result.append(contentsOf: olderLoadedSessions)
        return result
    }

    private func sessions(_ items: [AgentSession], in workspace: AgentWorkspace) -> [AgentSession] {
        items.map { session($0, in: workspace) }
    }

    private func session(_ item: AgentSession, in workspace: AgentWorkspace?) -> AgentSession {
        guard let workspace else {
            return alignSessionToKnownWorkspace(item)
        }
        return AgentSession(
            id: item.id,
            projectID: workspace.id,
            project: workspace.name,
            dir: item.dir.isEmpty ? workspace.path : item.dir,
            title: item.title,
            status: item.status,
            source: item.source,
            runtimeProvider: item.runtimeProvider,
            resumeID: item.resumeID,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            preview: item.preview,
            activeTurnID: item.activeTurnID,
            lastSeq: item.lastSeq,
            revision: item.revision,
            usage: item.usage,
            rateLimit: item.rateLimit,
            pendingApproval: item.pendingApproval,
            pendingUserInput: item.pendingUserInput,
            goal: item.goal,
            context: item.context
        )
    }

    private func alignSessionToKnownWorkspace(_ item: AgentSession) -> AgentSession {
        if let existing = sessionsByID[item.id],
           let workspace = workspacesByID[existing.projectID] {
            return session(item, in: workspace)
        }
        if let workspace = workspaceForPath(item.dir) {
            return session(item, in: workspace)
        }
        return item
    }

    private func workspaceForSession(_ session: AgentSession) -> AgentWorkspace? {
        workspacesByID[session.projectID] ?? workspaceForPath(session.dir)
    }

    private func workspaceForPath(_ rawPath: String) -> AgentWorkspace? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return recentWorkspaces
            .filter { workspace in
                let workspacePath = workspace.path.trimmingCharacters(in: .whitespacesAndNewlines)
                return path == workspacePath || path.hasPrefix(workspacePath + "/")
            }
            .max { lhs, rhs in
                lhs.path.split(separator: "/").count < rhs.path.split(separator: "/").count
            }
    }

    private func mergeSessionPage(_ pageSessions: [AgentSession]) {
        guard !pageSessions.isEmpty else {
            return
        }
        let pageSessions = pageSessions.map(sessionPreparedForStorage)
        ingestSessionContexts(pageSessions)
        var next = sessions
        var indexByID = sessionIndexByID
        for session in pageSessions {
            if let index = indexByID[session.id], next.indices.contains(index) {
                next[index] = session
            } else {
                indexByID[session.id] = next.count
                next.append(session)
            }
        }
        guard next != sessions else {
            return
        }
        sessions = next
    }

    private func updateSessionPageState(projectID: String, page: SessionsPage) {
        if let cursor = page.nextCursor, page.hasMore {
            sessionPageCursorByProjectID[projectID] = cursor
            sessionHasMoreByProjectID[projectID] = true
        } else {
            sessionPageCursorByProjectID.removeValue(forKey: projectID)
            sessionHasMoreByProjectID[projectID] = false
        }
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    private func updateHistoryPageState(
        sessionID: SessionID,
        page: HistoryMessagesPage,
        preserveExistingCursorOnEmptyPage: Bool
    ) {
        recordHistorySnapshotSeq(page.snapshotSeq, sessionID: sessionID)
        if let cursor = page.previousCursor, page.hasMoreBefore {
            historyPreviousCursorBySessionID[sessionID] = cursor
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else if preserveExistingCursorOnEmptyPage,
                  page.messages.isEmpty,
                  historyPreviousCursorBySessionID[sessionID] != nil {
            // resume/刷新首屏偶发空页时不要丢掉已有 older cursor。用户主动点“加载更早”
            // 的请求仍会传 false，让后端空页可以明确关闭分页入口。
            historyHasMoreBeforeBySessionID[sessionID] = true
        } else {
            historyPreviousCursorBySessionID.removeValue(forKey: sessionID)
            historyHasMoreBeforeBySessionID[sessionID] = false
        }
    }

    private func setSessionListProjection(
        sessionID: SessionID,
        preview rawPreview: String,
        source: SessionListProjection.Source,
        clientMessageID: ClientMessageID?
    ) {
        let preview = rawPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else {
            return
        }

        let existingProjection = listProjectionBySessionID[sessionID]
        let existingSession = sessionsByID[sessionID]
        let projection = SessionListProjection(
            preview: preview,
            updatedAt: Date(),
            baseRemoteUpdatedAt: existingProjection?.baseRemoteUpdatedAt ?? existingSession?.updatedAt,
            basePreview: existingProjection?.basePreview ?? existingSession?.preview,
            source: source,
            clientMessageID: clientMessageID
        )
        listProjectionBySessionID[sessionID] = projection
        updateSession(sessionID) { item in
            item.preview = projection.preview
            item.updatedAt = projection.updatedAt
        }
    }

    private func clearSessionListProjection(sessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard let projection = listProjectionBySessionID[sessionID] else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sessionID)
        updateSession(sessionID) { item in
            item.preview = projection.basePreview
            item.updatedAt = projection.baseRemoteUpdatedAt ?? item.updatedAt
        }
    }

    private func moveSessionListProjection(from sourceSessionID: SessionID, to targetSessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard sourceSessionID != targetSessionID,
              let projection = listProjectionBySessionID[sourceSessionID]
        else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        listProjectionBySessionID.removeValue(forKey: sourceSessionID)
        let existing = sessionsByID[targetSessionID]
        listProjectionBySessionID[targetSessionID] = SessionListProjection(
            preview: projection.preview,
            updatedAt: projection.updatedAt,
            baseRemoteUpdatedAt: existing?.updatedAt,
            basePreview: existing?.preview,
            source: projection.source,
            clientMessageID: projection.clientMessageID
        )
    }

    private func sessionPreparedForStorage(_ incoming: AgentSession) -> AgentSession {
        sessionApplyingListProjection(
            sessionPreservingLocalCompletedGoal(
                sessionPreservingLocalCompletedStatus(
                    sessionPreservingActiveApproval(incoming)
                )
            )
        )
    }

    private func sessionApplyingListProjection(_ incoming: AgentSession) -> AgentSession {
        guard let projection = listProjectionBySessionID[incoming.id] else {
            return incoming
        }
        if shouldClearListProjection(projection, remoteUpdatedAt: incoming.updatedAt) {
            listProjectionBySessionID.removeValue(forKey: incoming.id)
            return incoming
        }
        var projected = incoming
        projected.preview = projection.preview
        projected.updatedAt = projection.updatedAt
        return projected
    }

    private func shouldClearListProjection(_ projection: SessionListProjection, remoteUpdatedAt: Date?) -> Bool {
        guard let remoteUpdatedAt else {
            return false
        }
        guard let baseRemoteUpdatedAt = projection.baseRemoteUpdatedAt else {
            return true
        }
        return remoteUpdatedAt > baseRemoteUpdatedAt
    }

    private func optimisticSessionID(
        projectID: String,
        resume: AgentSession?,
        clientMessageID: ClientMessageID?,
        prompt: String
    ) -> SessionID? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let clientMessageID else {
            return nil
        }
        if let resume {
            return resume.id
        }
        return "local:\(projectID):\(clientMessageID)"
    }

    private func makeOptimisticSession(id: SessionID, projectID: String, prompt: String, runtimeProvider: String?) -> AgentSession {
        let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID]
        let title = Self.promptTitle(prompt)
        return AgentSession(
            id: id,
            projectID: projectID,
            project: project?.name ?? projectID,
            dir: project?.path ?? "",
            title: title,
            status: "running",
            source: Self.optimisticSessionSource,
            runtimeProvider: runtimeProvider,
            resumeID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            preview: prompt
        )
    }

    private static func promptTitle(_ prompt: String) -> String {
        let collapsed = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return "新会话"
        }
        if collapsed.count <= 42 {
            return collapsed
        }
        return String(collapsed.prefix(42)) + "..."
    }

    private func removeSession(_ id: SessionID) {
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        next.remove(at: index)
        sessions = next
        clearRuntimeActivity(sessionID: id)
    }

    private func migrateForegroundActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = foregroundActivityBySessionID[sourceSessionID] else {
            return
        }
        foregroundActivityBySessionID.removeValue(forKey: sourceSessionID)
        foregroundActivityBySessionID[targetSessionID] = activity
        foregroundActivityClearTasks[targetSessionID]?.cancel()
        foregroundActivityClearTasks[targetSessionID] = foregroundActivityClearTasks.removeValue(forKey: sourceSessionID)
    }

    private func migrateRuntimeActivity(from sourceSessionID: SessionID, to targetSessionID: SessionID) {
        guard sourceSessionID != targetSessionID,
              let activity = runtimeActivityBySessionID[sourceSessionID] else {
            return
        }
        runtimeActivityBySessionID.removeValue(forKey: sourceSessionID)
        runtimeActivityBySessionID[targetSessionID] = activity
    }

    // 会话列表请求是按 project 并发的：用户快速切项目、刷新、展开加载更多时，
    // 旧响应可能晚于新响应返回。每次请求递增 token，落库前只接受当前 token。
    private func beginSessionPageRequest(projectID: String) -> Int {
        let token = (sessionPageRequestTokenByProjectID[projectID] ?? 0) + 1
        sessionPageRequestTokenByProjectID[projectID] = token
        sessionPageLoadingTokenByProjectID[projectID] = token
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
        return token
    }

    private func finishSessionPageRequest(projectID: String, token: Int) {
        guard sessionPageLoadingTokenByProjectID[projectID] == token else {
            return
        }
        sessionPageLoadingTokenByProjectID.removeValue(forKey: projectID)
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    private func isCurrentSessionPageRequest(projectID: String, token: Int) -> Bool {
        sessionPageRequestTokenByProjectID[projectID] == token
    }

    private func beginHistoryLoadJob(sessionID: SessionID) -> Int {
        let token = (historyLoadJobTokenBySessionID[sessionID] ?? 0) + 1
        historyLoadJobTokenBySessionID[sessionID] = token
        return token
    }

    // 历史首屏也会并发触发：点选历史、前台恢复、手动刷新都可能同时请求 before=nil。
    // 只接受最新 token，避免旧 rollout 快照晚到后覆盖较新的消息投影和分页 cursor。
    private func beginHistoryPageRequest(sessionID: SessionID) -> Int {
        let token = (historyPageRequestTokenBySessionID[sessionID] ?? 0) + 1
        historyPageRequestTokenBySessionID[sessionID] = token
        return token
    }

    private func isCurrentHistoryPageRequest(sessionID: SessionID, token: Int) -> Bool {
        historyPageRequestTokenBySessionID[sessionID] == token
    }

    private func rebuildProjectIndex() {
        var byID: [String: AgentProject] = [:]
        byID.reserveCapacity(projects.count)
        for project in projects {
            byID[project.id] = project
        }
        projectsByID = byID
    }

    private func rebuildWorkspaceIndex() {
        var byID: [String: AgentWorkspace] = [:]
        byID.reserveCapacity(recentWorkspaces.count)
        for workspace in recentWorkspaces {
            byID[workspace.id] = workspace
        }
        workspacesByID = byID
        setSidebarProjectsIfChanged(recentWorkspaces.map(\.project))
    }

    private func rebuildSessionIndexes() {
        var byID: [SessionID: AgentSession] = [:]
        var indexByID: [SessionID: Int] = [:]
        byID.reserveCapacity(sessions.count)
        indexByID.reserveCapacity(sessions.count)
        for (index, session) in sessions.enumerated() {
            byID[session.id] = session
            indexByID[session.id] = index
        }
        sessionsByID = byID
        sessionIndexByID = indexByID
        pruneSessionScopedState(validSessionIDs: Set(byID.keys))

        // 和 Codex/Litter 的 snapshot 思路一致：Store 在数据变更时生成排序/分组投影，
        // SwiftUI 列表渲染时只读取缓存，避免每个项目行反复 filter + sort。
        let listableSessions = sessions.filter(isListableSession)
        let sorted = sortedSessionsForList(listableSessions)
        if sessions.contains(where: \.isRunning) {
            let previousOrder = frozenAllSessionOrder.isEmpty ? Self.sessionIDs(sortedAllSessions) : frozenAllSessionOrder
            let frozen = Self.applyFrozenOrder(to: sorted, previousOrder: previousOrder)
            sortedAllSessions = frozen
            frozenAllSessionOrder = Self.sessionIDs(frozen)
        } else {
            sortedAllSessions = sorted
            frozenAllSessionOrder = []
        }

        var naturalGrouped: [String: [AgentSession]] = [:]
        naturalGrouped.reserveCapacity(sidebarProjects.count)
        for session in sorted {
            naturalGrouped[session.projectID, default: []].append(session)
        }

        var runningProjectIDs: Set<String> = []
        runningProjectIDs.reserveCapacity(naturalGrouped.count)
        for session in listableSessions where session.isRunning {
            runningProjectIDs.insert(session.projectID)
        }
        var grouped: [String: [AgentSession]] = [:]
        grouped.reserveCapacity(naturalGrouped.count)
        for (projectID, projectSessions) in naturalGrouped {
            guard runningProjectIDs.contains(projectID) else {
                grouped[projectID] = projectSessions
                frozenSessionOrderByProjectID.removeValue(forKey: projectID)
                continue
            }
            let previousOrder = frozenSessionOrderByProjectID[projectID]
                ?? sortedSessionsByProjectID[projectID].map(Self.sessionIDs)
                ?? Self.sessionIDs(projectSessions)
            let frozen = Self.applyFrozenOrder(to: projectSessions, previousOrder: previousOrder)
            grouped[projectID] = frozen
            frozenSessionOrderByProjectID[projectID] = Self.sessionIDs(frozen)
        }
        frozenSessionOrderByProjectID = frozenSessionOrderByProjectID.filter { runningProjectIDs.contains($0.key) }
        sortedSessionsByProjectID = grouped

        var previews: [String: [AgentSession]] = [:]
        var hiddenCounts: [String: Int] = [:]
        previews.reserveCapacity(grouped.count)
        hiddenCounts.reserveCapacity(grouped.count)
        for (projectID, projectSessions) in grouped {
            let hiddenCount = max(0, projectSessions.count - Self.sessionPreviewLimit)
            hiddenCounts[projectID] = hiddenCount
            // 侧栏每次 body 计算都会读取可见会话。像 Litter 的派生模型一样提前保存预览窗口，
            // 避免多个项目行在刷新时重复构造 prefix 数组。
            if hiddenCount == 0 {
                previews[projectID] = projectSessions
            } else {
                previews[projectID] = Array(projectSessions.prefix(Self.sessionPreviewLimit))
            }
        }
        previewSessionsByProjectID = previews
        hiddenSessionCountByProjectID = hiddenCounts
        rebuildProjectSessionListSnapshots()
    }

    private func makeProjectSessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        let baseSessions = sortedSessionsByProjectID[projectID] ?? []
        if isSessionSearchActive {
            let matchingSessions = sessionsMatchingSearch(baseSessions)
            return ProjectSessionListSnapshot(
                projectID: projectID,
                isExpanded: true,
                isShowingAll: true,
                visibleSessions: matchingSessions,
                allSessionCount: matchingSessions.count,
                hiddenCount: 0,
                canLoadMore: false,
                isLoadingMore: false,
                hasCollapsedPreview: false
            )
        }

        let allSessions = baseSessions
        let visibleLimit = sessionVisibleLimit(forProjectID: projectID)
        let visibleSessions = Array(allSessions.prefix(min(visibleLimit, allSessions.count)))
        let isShowingAll = visibleLimit > Self.sessionPreviewLimit

        return ProjectSessionListSnapshot(
            projectID: projectID,
            isExpanded: expandedProjectIDs.contains(projectID),
            isShowingAll: isShowingAll,
            visibleSessions: visibleSessions,
            allSessionCount: allSessions.count,
            hiddenCount: max(0, allSessions.count - visibleSessions.count),
            canLoadMore: canLoadMoreSessions(projectID: projectID),
            isLoadingMore: sessionPageLoadingTokenByProjectID[projectID] != nil,
            hasCollapsedPreview: allSessions.count > Self.sessionPreviewLimit
        )
    }

    private func rebuildProjectSessionListSnapshot(forProjectID projectID: String) {
        let snapshot = makeProjectSessionListSnapshot(forProjectID: projectID)
        sessionListSnapshotsByProjectID[projectID] = snapshot
    }

    private func rebuildProjectSessionListSnapshots() {
        var projectIDs: Set<String> = []
        projectIDs.reserveCapacity(sidebarProjects.count + sortedSessionsByProjectID.count)
        for project in sidebarProjects {
            projectIDs.insert(project.id)
        }
        projectIDs.formUnion(sortedSessionsByProjectID.keys)
        projectIDs.formUnion(expandedProjectIDs)
        projectIDs.formUnion(showingAllSessionProjectIDs)
        projectIDs.formUnion(sessionHasMoreByProjectID.keys)
        projectIDs.formUnion(sessionPageLoadingTokenByProjectID.keys)

        var snapshots: [String: ProjectSessionListSnapshot] = [:]
        snapshots.reserveCapacity(projectIDs.count)
        for projectID in projectIDs {
            snapshots[projectID] = makeProjectSessionListSnapshot(forProjectID: projectID)
        }
        sessionListSnapshotsByProjectID = snapshots
    }

    private var normalizedSessionSearchQuery: String {
        Self.normalizedSearchText(sessionSearchQuery)
    }

    private func sessionsMatchingSearch(_ items: [AgentSession]) -> [AgentSession] {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return items
        }
        // 搜索只作用于已加载会话投影，不改原始 sessions；这样清空搜索后能恢复分页、冻结顺序和选择状态。
        return items.filter { sessionMatchesSearch($0, query: query) }
    }

    private func sessionMatchesSearch(_ session: AgentSession, query: String) -> Bool {
        [
            session.title,
            session.preview,
            session.project,
            session.dir,
            session.displayStatusText,
            session.id,
            session.resumeID
        ].contains { value in
            Self.normalizedSearchText(value ?? "").contains(query)
        }
    }

    private func isListableSession(_ session: AgentSession) -> Bool {
        !archivedSessionIDs.contains(session.id) || session.id == selectedSessionID || session.isRunning
    }

    private func projectMatchesSearch(_ project: AgentProject) -> Bool {
        let query = normalizedSessionSearchQuery
        guard !query.isEmpty else {
            return true
        }
        return [
            project.name,
            project.path,
            project.id
        ].contains { value in
            Self.normalizedSearchText(value).contains(query)
        }
    }

    private static func normalizedSearchText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private func pruneSessionScopedState(validSessionIDs: Set<SessionID>) {
        // 会话分页只保留当前已知列表和被选中保留的 session；旧 session 的 cursor/token/activity
        // 继续留在字典里没有业务价值，长时间浏览大量历史时还会慢慢堆内存。
        historyPreviousCursorBySessionID = historyPreviousCursorBySessionID.filter { validSessionIDs.contains($0.key) }
        historyHasMoreBeforeBySessionID = historyHasMoreBeforeBySessionID.filter { validSessionIDs.contains($0.key) }
        historySnapshotSeqBySessionID = historySnapshotSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        historyPageRequestTokenBySessionID = historyPageRequestTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadProgressBySessionID = historyLoadProgressBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleHistoryLoadJobIDs = historyLoadJobsBySessionID.keys.filter { !validSessionIDs.contains($0) }
        for sessionID in staleHistoryLoadJobIDs {
            historyLoadJobsBySessionID[sessionID]?.task.cancel()
            historyLoadJobsBySessionID.removeValue(forKey: sessionID)
        }
        historyLoadJobTokenBySessionID = historyLoadJobTokenBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedSignatureBySessionID = historyLoadedSignatureBySessionID.filter { validSessionIDs.contains($0.key) }
        historyLoadedQualityBySessionID = historyLoadedQualityBySessionID.filter { validSessionIDs.contains($0.key) }
        let staleHistoryFirstPageKeys = historyFirstPageInFlightByKey.keys.filter { !validSessionIDs.contains($0.sessionID) }
        for key in staleHistoryFirstPageKeys {
            historyFirstPageInFlightByKey[key]?.task.cancel()
            historyFirstPageInFlightByKey.removeValue(forKey: key)
        }
        historyFirstPageCacheByKey = historyFirstPageCacheByKey.filter { validSessionIDs.contains($0.key.sessionID) }
        historySavingsNoticesBySessionID = historySavingsNoticesBySessionID.filter { validSessionIDs.contains($0.key) }
        initialHistoryLoadingSessionIDs.formIntersection(validSessionIDs)

        let loadingEarlierSessionIDs = loadingEarlierHistorySessionIDs.intersection(validSessionIDs)
        if loadingEarlierSessionIDs != loadingEarlierHistorySessionIDs {
            loadingEarlierHistorySessionIDs = loadingEarlierSessionIDs
        }

        let staleActivitySessionIDs = Set(foregroundActivityBySessionID.keys).subtracting(validSessionIDs)
        for sessionID in staleActivitySessionIDs {
            foregroundActivityClearTasks[sessionID]?.cancel()
            foregroundActivityClearTasks.removeValue(forKey: sessionID)
        }
        lastSeenEventSeqBySessionID = lastSeenEventSeqBySessionID.filter { validSessionIDs.contains($0.key) }
        let foregroundActivities = foregroundActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if foregroundActivities != foregroundActivityBySessionID {
            foregroundActivityBySessionID = foregroundActivities
        }
        let runtimeActivities = runtimeActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if runtimeActivities != runtimeActivityBySessionID {
            runtimeActivityBySessionID = runtimeActivities
        }
    }

    private static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        SessionIndexStore.sortedSessions(items)
    }

    private func sortedSessionsForList(_ items: [AgentSession]) -> [AgentSession] {
        let sorted = Self.sortedSessions(items)
        let indexByID = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
        return sorted.sorted { lhs, rhs in
            let leftPinned = pinnedSessionIDs.contains(lhs.id)
            let rightPinned = pinnedSessionIDs.contains(rhs.id)
            if leftPinned != rightPinned {
                return leftPinned
            }
            return (indexByID[lhs.id] ?? 0) < (indexByID[rhs.id] ?? 0)
        }
    }

    private static func applyFrozenOrder(to items: [AgentSession], previousOrder: [SessionID]) -> [AgentSession] {
        guard !items.isEmpty, !previousOrder.isEmpty else {
            return items
        }
        let previousIDs = Set(previousOrder)
        var byID: [SessionID: AgentSession] = [:]
        byID.reserveCapacity(items.count)
        for item in items {
            byID[item.id] = item
        }
        var result: [AgentSession] = []
        result.reserveCapacity(items.count)

        // 新会话仍按当前排序排在前面；已有会话沿用冻结顺序，避免 running 输出刷新 updatedAt 时侧栏上下跳。
        for item in items where !previousIDs.contains(item.id) {
            result.append(item)
        }
        for id in previousOrder {
            if let item = byID[id] {
                result.append(item)
            }
        }
        return result
    }

    private static func sessionIDs(_ items: [AgentSession]) -> [SessionID] {
        var ids: [SessionID] = []
        ids.reserveCapacity(items.count)
        for item in items {
            ids.append(item.id)
        }
        return ids
    }

    private static func projectIDs(_ items: [AgentProject]) -> Set<String> {
        var ids: Set<String> = []
        ids.reserveCapacity(items.count)
        for item in items {
            ids.insert(item.id)
        }
        return ids
    }

    private func connectWebSocket(
        _ session: AgentSession,
        isReconnectAttempt: Bool = false,
        replayBufferedEvents: Bool = true,
        allowNonRunning: Bool = false
    ) {
        // allowNonRunning：非运行会话的订阅同样有价值——thread/resume 会带回权威状态
        // 纠正被误降级的会话，后续 turn 事件也能实时推进来。
        guard session.isRunning || allowNonRunning else {
            return
        }
        if !isReconnectAttempt {
            cancelWebSocketReconnect(resetAttempts: true)
        }
        if connectedSessionID == session.id, case .connected = webSocketStatus {
            return
        }
        disconnectWebSocket(cancelReconnect: !isReconnectAttempt)

        webSocketConnectionGeneration += 1
        let connectionGeneration = webSocketConnectionGeneration
        let socket = sessionWebSocketFactory?(session) ?? webSocketFactory()
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                switch status {
                case .failed, .disconnected:
                    await self?.flushRuntimeEvents(sessionID: session.id)
                default:
                    break
                }
                self?.applyWebSocketStatus(status, sessionID: session.id)
            }
        }
        let terminalStreamStore = terminalStreamStore
        socket.onEvent = { [weak self, terminalStreamStore] event in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                if let metadata = self?.metadata(for: event) {
                    self?.recordEventWatermark(metadata, fallbackSessionID: session.id)
                }
                let shouldFlushImmediately = await terminalStreamStore.append(event, sessionID: session.id)
                if shouldFlushImmediately {
                    if self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true {
                        await self?.flushRuntimeEvents(sessionID: session.id)
                    }
                } else {
                    guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                        return
                    }
                    self?.scheduleRuntimeEventFlush(sessionID: session.id)
                }
            }
        }
        socket.onSendAccepted = { [weak self] clientMessageID in
            Task { @MainActor in
                guard let clientMessageID else {
                    return
                }
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                self?.conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
                self?.conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: session.id)
            }
        }
        socket.onSendFailure = { [weak self] clientMessageID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                if let clientMessageID {
                    guard self?.conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed) == true else {
                        return
                    }
                }
                self?.clearForegroundActivity(sessionID: session.id)
                self?.setErrorMessage("发送失败：\(message)")
            }
        }
        socket.onApprovalDecisionFailure = { [weak self] approvalID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                self?.clearPendingApprovalDecision(sessionID: session.id, approvalID: approvalID)
                self?.setErrorMessage("审批发送失败：\(message)")
            }
        }
        socket.onUserInputResponseFailure = { [weak self] requestID, message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                let request = self?.clearPendingUserInputResponse(sessionID: session.id, requestID: requestID)
                if let request {
                    self?.restoreUserInputRequestAfterFailure(request, sessionID: session.id)
                }
                self?.setErrorMessage("补充信息发送失败：\(message)")
            }
        }
        socket.onControlFailure = { [weak self] message in
            Task { @MainActor in
                guard self?.isCurrentWebSocketConnection(sessionID: session.id, generation: connectionGeneration) == true else {
                    return
                }
                self?.setErrorMessage("控制指令发送失败：\(message)")
            }
        }
        webSocket = socket
        connectedSessionID = session.id
        conversationStore.resetLiveTranscript(sessionID: session.id)
        syncRuntimeActivity(with: session)
        runtimeEventFlushTasks[session.id]?.cancel()
        runtimeEventFlushTasks[session.id] = nil
        socket.connect(sessionID: session.id, replayBufferedEvents: replayBufferedEvents)
    }

    private func replayWatermark(for sessionID: SessionID) -> EventSequence? {
        // WS/REST 的 last_seen_seq 取四处最大值：结构化事件、历史快照、对话投影和日志，
        // 避免某一侧 store 清理或重置后造成事件重放/漏拉。
        [
            lastSeenEventSeqBySessionID[sessionID],
            historySnapshotSeqBySessionID[sessionID],
            conversationStore.lastSeenSeq(for: sessionID),
            logStore.lastSeq(for: sessionID)
        ]
        .compactMap { $0 }
        .max()
    }

    private func readyWebSocket(for session: AgentSession) -> (any SessionWebSocketClient)? {
        let shouldReconnect: Bool
        switch webSocketStatus {
        case .failed, .disconnected:
            shouldReconnect = true
        case .connecting, .connected:
            shouldReconnect = false
        }
        if connectedSessionID != session.id || webSocket == nil || shouldReconnect {
            connectWebSocket(session)
        }
        guard let webSocket, connectedSessionID == session.id else {
            setErrorMessage("WebSocket 正在重新接入，请稍后再发送")
            return nil
        }
        guard webSocketStatus == .connected else {
            setErrorMessage("WebSocket 正在连接，请稍后再发送")
            return nil
        }
        return webSocket
    }

    private func applyWebSocketStatus(_ status: WebSocketStatus, sessionID: String) {
        switch status {
        case .connected:
            cancelWebSocketReconnect(resetAttempts: false)
            webSocketReconnectAttemptBySessionID.removeValue(forKey: sessionID)
            setWebSocketStatus(.connected)
            setErrorMessage(nil)
        case .failed(let message):
            let policyRejected = Self.isDeterministicGatewayPolicyFailure(message)
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID) && !policyRejected
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
            conversationStore.markSendingUserMessagesFailed(sessionID: sessionID)
            clearPendingApprovalDecisions(sessionID: sessionID)
            clearPendingUserInputResponses(sessionID: sessionID)
            clearForegroundActivity(sessionID: sessionID)
            if canReconnect {
                scheduleWebSocketReconnect(sessionID: sessionID, reason: message)
            } else {
                setWebSocketStatus(.failed(message))
                setErrorMessage(policyRejected ? "连接被服务器策略拒绝，已停止自动重连：\(message)" : message)
            }
        case .disconnected:
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID)
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
            conversationStore.markSendingUserMessagesFailed(sessionID: sessionID)
            clearPendingApprovalDecisions(sessionID: sessionID)
            clearForegroundActivity(sessionID: sessionID)
            if canReconnect {
                scheduleWebSocketReconnect(sessionID: sessionID, reason: "连接已断开")
            } else {
                setWebSocketStatus(.disconnected)
            }
        case .connecting:
            setWebSocketStatus(.connecting)
        }
    }

    private func disconnectWebSocket(cancelReconnect: Bool = true) {
        if cancelReconnect {
            cancelWebSocketReconnect(resetAttempts: true)
        }
        let sessionIDsToFlush = Set(([connectedSessionID].compactMap { $0 }) + Array(runtimeEventFlushTasks.keys))
        for sessionID in sessionIDsToFlush {
            runtimeEventFlushTasks[sessionID]?.cancel()
            runtimeEventFlushTasks[sessionID] = nil
            Task { [weak self] in
                // 手动切会话/断开时，最后一个合并窗口里的事件已经在本地 actor 中；
                // 先异步 drain，避免新连接启动时把尾包清掉。
                await self?.flushRuntimeEvents(sessionID: sessionID)
            }
        }
        webSocketConnectionGeneration += 1
        let previousSessionID = connectedSessionID
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        socket?.disconnect()
        if let previousSessionID {
            conversationStore.markSendingUserMessagesFailed(sessionID: previousSessionID)
        }
        pendingApprovalDecisionIDsBySessionID.removeAll()
        pendingUserInputResponseIDsBySessionID.removeAll()
        pendingUserInputRequestsBySessionID.removeAll()
        setWebSocketStatus(.disconnected)
    }

    private func isCurrentWebSocketConnection(sessionID: SessionID, generation: Int) -> Bool {
        connectedSessionID == sessionID && webSocketConnectionGeneration == generation
    }

    private func shouldAutoReconnectWebSocket(sessionID: SessionID) -> Bool {
        // 不再要求 isRunning：状态可能刚被瞬时 idle 误读降级，订阅对历史会话同样有效；
        // 只要还是当前选中的会话就继续自动重连。
        guard connectedSessionID == sessionID,
              selectedSessionID == sessionID,
              sessionsByID[sessionID] != nil,
              appStore.isConfigured else {
            return false
        }
        return true
    }

    private func scheduleWebSocketReconnect(sessionID: SessionID, reason: String) {
        guard selectedSessionID == sessionID,
              sessionsByID[sessionID] != nil else {
            setWebSocketStatus(.failed(reason))
            setErrorMessage(reason)
            return
        }

        let attempt = webSocketReconnectAttemptBySessionID[sessionID, default: 0] + 1
        webSocketReconnectTask?.cancel()
        webSocketReconnectAttemptBySessionID[sessionID] = attempt
        let delay = webSocketReconnectDelayNanoseconds(attempt)
        setWebSocketStatus(.connecting)
        setErrorMessage("WebSocket 断开，正在自动重连：\(reason)")
        setStatusMessage("WebSocket 第 \(attempt) 次重连")

        // 重连任务只服务当前选中的会话；切项目/停止/返回列表都会取消它。
        webSocketReconnectTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                self?.webSocketReconnectTask = nil
            }
            await self?.runScheduledWebSocketReconnect(sessionID: sessionID, attempt: attempt)
        }
    }

    private func cancelWebSocketReconnect(resetAttempts: Bool) {
        webSocketReconnectTask?.cancel()
        webSocketReconnectTask = nil
        if resetAttempts {
            webSocketReconnectAttemptBySessionID.removeAll()
        }
    }

    private func runScheduledWebSocketReconnect(sessionID: SessionID, attempt: Int) async {
        guard selectedSessionID == sessionID,
              webSocketReconnectAttemptBySessionID[sessionID] == attempt,
              let latestSession = sessionsByID[sessionID] else {
            return
        }
        _ = await refreshConnectionRoute(preferPrimary: false)
        guard selectedSessionID == sessionID else {
            return
        }
        let refreshedSession = await refreshSessionSnapshotBeforeReconnect(sessionID: sessionID) ?? latestSession
        guard selectedSessionID == sessionID else {
            return
        }
        // 快照可能在上游刚恢复时把运行中的 turn 误读成 idle；不能据此一次性放弃重连。
        // 订阅对历史会话同样有效：resume 后权威状态自行纠正，turn 真结束也会由
        // turn/completed 事件如实呈现。
        connectWebSocket(refreshedSession, isReconnectAttempt: true, allowNonRunning: true)
    }

    private func refreshSessionSnapshotBeforeReconnect(sessionID: SessionID) async -> AgentSession? {
        guard let current = sessionsByID[sessionID] else {
            return nil
        }
        do {
            let client = try clientFactory()
            let response = try await client.session(id: sessionID, afterSeq: replayWatermark(for: sessionID))
            let refreshed = self.session(response.session, in: workspaceForSession(current))
            upsert(refreshed)
            if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                // 重连前只补诊断日志；结构化消息由 history 和 app-server event 补齐。
                logStore.append(recentOutput, sessionID: sessionID, seq: response.lastSeq)
            }
            // 重连前先刷新一次消息页，用 cursor/id/revision 合并可能错过的结构化消息。
            await loadHistory(for: refreshed)
            return refreshed
        } catch {
            setStatusMessage("重连前快照刷新失败：\(error.localizedDescription)")
            return current
        }
    }

    private func scheduleRuntimeEventFlush(sessionID: SessionID) {
        guard runtimeEventFlushTasks[sessionID] == nil else {
            return
        }
        let delay = runtimeEventFlushDelayNanoseconds
        runtimeEventFlushTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.flushRuntimeEvents(sessionID: sessionID)
        }
    }

    private func flushRuntimeEvents(sessionID: SessionID) async {
        runtimeEventFlushTasks[sessionID]?.cancel()
        runtimeEventFlushTasks[sessionID] = nil
        let events = await terminalStreamStore.drain(sessionID: sessionID)
        guard !events.isEmpty else {
            return
        }
        for event in events {
            await applyRuntimeEvent(event, sessionID: sessionID)
        }
    }

    private func applyRuntimeEvent(_ event: AgentEvent, sessionID: String) async {
        if let metadata = metadata(for: event) {
            recordEventWatermark(metadata, fallbackSessionID: sessionID)
        }
        recordRuntimeActivity(for: event, fallbackSessionID: sessionID)
        let runtimeNotification = runtimeNotification(for: event, fallbackSessionID: sessionID)
        let output = await eventReducer.reduce(
            event,
            fallbackSessionID: sessionID,
            outputIdleClearDelay: foregroundOutputIdleClearDelay
        )
        applyEventReducerOutput(output)
        if case .turnCompleted(let metadata) = event {
            let id = metadata.sessionID ?? sessionID
            if let projectID = sessionsByID[id]?.projectID {
                scheduleSessionListReconciliation(projectID: projectID)
            }
        }
        await scheduleRuntimeNotificationIfNeeded(runtimeNotification)
    }

    private func scheduleSessionListReconciliation(projectID: String) {
        sessionListReconciliationTasksByProjectID[projectID]?.cancel()
        sessionListReconciliationTasksByProjectID[projectID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.sessionListReconciliationDelayNanoseconds)
            } catch {
                return
            }
            await self.refreshSessions(
                forProjectID: projectID,
                showLoading: false,
                clearErrorOnSuccess: false,
                updateStatusMessage: false,
                reportErrorOnFailure: false
            )
            self.sessionListReconciliationTasksByProjectID.removeValue(forKey: projectID)
        }
    }

    private func scheduleRuntimeNotificationIfNeeded(_ notification: SessionRuntimeNotification?) async {
        guard let notification else {
            return
        }
        guard !deliveredRuntimeNotificationIDs.contains(notification.id) else {
            return
        }
        deliveredRuntimeNotificationIDs.insert(notification.id)
        do {
            // 运行态通知不持久化：它只是实时提示，不应该在会话列表状态里留下“待处理任务”的假象。
            try await sessionReminderScheduler.notify(notification)
        } catch {
            setStatusMessage("通知调度失败：\(error.localizedDescription)")
        }
    }

    private func applyEventReducerOutput(_ output: EventReducerOutput) {
        for session in output.upsertSessions {
            upsert(session)
        }
        for (id, status) in output.statusUpdates {
            updateSession(id) { item in
                item.status = status
            }
            if status == SessionStatus.completed.rawValue {
                locallyCompletedSessionIDs.insert(id)
            } else if Self.isRunningStatus(status) {
                locallyCompletedSessionIDs.remove(id)
            }
            if !Self.isRunningStatus(status) {
                clearRuntimeActivity(sessionID: id)
            }
            contextStore.updateStatus(sessionID: id, status: status)
            if status == SessionStatus.completed.rawValue {
                completeActiveThreadGoalIfNeeded(sessionID: id)
            }
        }
        for mutation in output.activeTurnMutations {
            applyActiveTurnMutation(mutation)
        }
        for (id, approval) in output.pendingApprovalUpdates {
            if approval == nil {
                clearPendingApprovalDecisions(sessionID: id)
            }
            updateSession(id) { item in
                item.pendingApproval = approval
            }
        }
        for (id, userInput) in output.pendingUserInputUpdates {
            if userInput == nil {
                clearPendingUserInputResponses(sessionID: id)
            }
            updateSession(id) { item in
                item.pendingUserInput = userInput
            }
        }
        for (context, fallbackSessionID) in output.contextUpdates {
            contextStore.upsert(context, fallbackSessionID: fallbackSessionID)
        }
        for (id, goal) in output.goalUpdates {
            if let goal {
                applyThreadGoal(goal, fallbackSessionID: id)
            } else {
                clearThreadGoal(sessionID: id)
            }
        }
        for id in output.pendingApprovalTaskClears {
            contextStore.clearPendingApprovalTasks(sessionID: id)
        }
        for (id, activity, delay) in output.foregroundUpdates {
            setForegroundActivity(activity, sessionID: id, autoClearAfter: delay)
        }
        for id in output.foregroundClears {
            clearForegroundActivity(sessionID: id)
        }
        for append in output.logAppends {
            logStore.append(append.text, sessionID: append.sessionID, seq: append.seq)
        }
        for mutation in output.messageMutations {
            applyMessageMutation(mutation)
        }
        if let statusMessage = output.statusMessage {
            setStatusMessage(statusMessage)
        }
        if let errorMessage = output.errorMessage {
            setErrorMessage(errorMessage)
        }
        if output.disconnectWebSocket {
            disconnectWebSocket()
        }
    }

    private func applyActiveTurnMutation(_ mutation: EventReducerActiveTurnMutation) {
        switch mutation {
        case .set(let sessionID, let turnID):
            updateSession(sessionID) { item in
                guard item.isRunning else {
                    return
                }
                item.activeTurnID = turnID
            }
        case .clear(let sessionID, let completedTurnID):
            updateSession(sessionID) { item in
                // 完成事件可能延迟到达；带 turn id 时只清理对应的活跃回合，避免误伤随后开始的新回合。
                guard completedTurnID == nil || item.activeTurnID == nil || item.activeTurnID == completedTurnID else {
                    return
                }
                item.activeTurnID = nil
            }
        }
    }

    private func applyMessageMutation(_ mutation: EventReducerMessageMutation) {
        switch mutation {
        case .assistantDelta(let delta, let metadata, let fallbackSessionID):
            conversationStore.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: fallbackSessionID)
        case .completed(let message, let metadata, let fallbackSessionID):
            conversationStore.completeMessage(message, metadata: metadata, fallbackSessionID: fallbackSessionID)
            if message.role == .assistant {
                setSessionListProjection(
                    sessionID: metadata.sessionID ?? message.sessionID,
                    preview: message.content,
                    source: .localAssistant,
                    clientMessageID: nil
                )
            }
        case .system(let text, let sessionID, let kind, let metadata):
            conversationStore.appendSystem(text, sessionID: sessionID, kind: kind, metadata: metadata)
        case .resolveLatestPendingApproval(let sessionID):
            conversationStore.resolveLatestPendingApproval(sessionID: sessionID)
        case .resolveLatestPendingUserInput(let sessionID, let skipped):
            conversationStore.resolveLatestPendingUserInput(sessionID: sessionID, skipped: skipped)
        case .markCurrentAssistantCompleted(let metadata, let fallbackSessionID):
            conversationStore.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: fallbackSessionID)
        }
    }

    private func metadata(for event: AgentEvent) -> AgentEventMetadata? {
        switch event {
        case .session:
            return nil
        case .sessionRow(_, let metadata),
             .sessionStatus(_, let metadata),
             .sessionContext(_, let metadata),
             .goalUpdated(_, let metadata),
             .goalCleared(let metadata),
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .turnCompleted(let metadata),
             .warning(_, let metadata),
             .error(_, let metadata):
            return metadata
        case .unknown:
            return nil
        }
    }

    private func runtimeNotification(for event: AgentEvent, fallbackSessionID: SessionID) -> SessionRuntimeNotification? {
        switch event {
        case .approvalRequest(let request, let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            return SessionRuntimeNotification(
                id: "approval:\(sessionID):\(request.id)",
                sessionID: sessionID,
                title: "等待审批",
                body: "\(sessionDisplayTitle(sessionID: sessionID))：\(request.title)",
                kind: .approval
            )
        case .userInputRequest(let request, let metadata):
            let sessionID = metadata.sessionID ?? request.threadID
            return SessionRuntimeNotification(
                id: "user-input:\(sessionID):\(request.id)",
                sessionID: sessionID,
                title: "等待补充信息",
                body: "\(sessionDisplayTitle(sessionID: sessionID))：\(request.title)",
                kind: .approval
            )
        case .turnCompleted(let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            let token = metadata.turnID ?? metadata.messageID ?? metadata.seq.map(String.init) ?? "latest"
            return SessionRuntimeNotification(
                id: "completed:\(sessionID):\(token)",
                sessionID: sessionID,
                title: "会话已完成",
                body: sessionDisplayTitle(sessionID: sessionID),
                kind: .completed
            )
        case .sessionStatus(let status, let metadata) where status == "failed":
            let sessionID = metadata.sessionID ?? fallbackSessionID
            let token = metadata.turnID ?? metadata.seq.map(String.init) ?? "latest"
            return SessionRuntimeNotification(
                id: "failed:\(sessionID):\(token)",
                sessionID: sessionID,
                title: "会话失败",
                body: sessionDisplayTitle(sessionID: sessionID),
                kind: .failed
            )
        case .error(let payload, let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            return SessionRuntimeNotification(
                id: "failed:\(sessionID):\(payload.message)",
                sessionID: sessionID,
                title: "会话错误",
                body: payload.message,
                kind: .failed
            )
        default:
            return nil
        }
    }

    private func sessionDisplayTitle(sessionID: SessionID) -> String {
        if let title = sessionsByID[sessionID]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "当前会话"
    }

    private func recordEventWatermark(_ metadata: AgentEventMetadata, fallbackSessionID: SessionID) {
        guard let seq = metadata.seq else {
            return
        }
        let sessionID = metadata.sessionID ?? fallbackSessionID
        if let last = lastSeenEventSeqBySessionID[sessionID], seq <= last {
            return
        }
        lastSeenEventSeqBySessionID[sessionID] = seq
    }

    private func recordHistorySnapshotSeq(_ seq: EventSequence?, sessionID: SessionID) {
        guard let seq else {
            return
        }
        if let last = historySnapshotSeqBySessionID[sessionID], seq <= last {
            return
        }
        historySnapshotSeqBySessionID[sessionID] = seq
    }

    private func recordRuntimeActivity(for event: AgentEvent, fallbackSessionID: SessionID) {
        let now = Date()
        switch event {
        case .turnStarted(let metadata):
            let sessionID = metadata.sessionID ?? fallbackSessionID
            recordRuntimeActivity(sessionID: sessionID, turnStartedAt: metadata.createdAt ?? now, activityAt: now)
        case .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .userInputRequest(_, let metadata),
             .userInputResolved(let metadata, _),
             .warning(_, let metadata):
            recordRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID, activityAt: now)
        case .turnCompleted(let metadata):
            clearRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID)
        case .sessionStatus(let status, let metadata):
            guard let sessionID = metadata.sessionID else {
                return
            }
            if Self.isRunningStatus(status), runtimeActivityBySessionID[sessionID] != nil {
                recordRuntimeActivity(sessionID: sessionID, activityAt: now)
            } else if !Self.isRunningStatus(status) {
                clearRuntimeActivity(sessionID: sessionID)
            }
        case .error(_, let metadata):
            clearRuntimeActivity(sessionID: metadata.sessionID ?? fallbackSessionID)
        case .session(let session):
            syncRuntimeActivity(with: session)
        case .sessionRow(let row, _):
            syncRuntimeActivity(with: AgentSession(row: row))
        case .sessionContext, .goalUpdated, .goalCleared, .unknown:
            return
        }
    }

    private func recordRuntimeActivity(
        sessionID: SessionID,
        turnStartedAt: Date? = nil,
        activityAt: Date
    ) {
        let existing = runtimeActivityBySessionID[sessionID]
        let resolvedStart = turnStartedAt ?? existing?.turnStartedAt ?? activityAt
        let next = RuntimeActivitySnapshot(turnStartedAt: resolvedStart, lastActivityAt: activityAt)
        guard existing != next else {
            return
        }
        runtimeActivityBySessionID[sessionID] = next
    }

    private func syncRuntimeActivity(with session: AgentSession) {
        guard session.isRunning else {
            clearRuntimeActivity(sessionID: session.id)
            return
        }
        guard session.activeTurnID != nil, runtimeActivityBySessionID[session.id] == nil else {
            return
        }
        let activityAt = session.updatedAt ?? Date()
        // 列表/快照只告诉我们“有活跃 turn”，不保证携带 turn 开始时间；
        // 这里用最近更新时间兜底，让用户至少能看到当前连接是否持续有事件。
        recordRuntimeActivity(sessionID: session.id, turnStartedAt: activityAt, activityAt: activityAt)
    }

    private func clearRuntimeActivity(sessionID: SessionID) {
        guard runtimeActivityBySessionID[sessionID] != nil else {
            return
        }
        runtimeActivityBySessionID.removeValue(forKey: sessionID)
    }

    private static func isRunningStatus(_ status: String?) -> Bool {
        switch status {
        case .some(SessionStatus.running.rawValue),
             .some(SessionStatus.waitingForApproval.rawValue),
             .some(SessionStatus.waitingForInput.rawValue):
            return true
        default:
            return false
        }
    }

    private func isNoOpHistorySelection(_ session: AgentSession) -> Bool {
        // 历史会话的稳态是"已订阅事件 + 已加载缓存"；重复点选同一会话时不再重建连接、
        // 也不重复静默刷新（订阅本身会把新内容推进来）。
        selectedSessionID == session.id
            && selectedProjectID == session.projectID
            && !session.isRunning
            && conversationStore.hasLoadedHistory(sessionID: session.id)
            && errorMessage == nil
            && connectedSessionID == session.id
            && webSocket != nil
            && webSocketStatus == .connected
    }

    private func setProjectsIfChanged(_ value: [AgentProject]) {
        guard projects != value else {
            return
        }
        projects = value
    }

    private func setRecentWorkspacesIfChanged(_ value: [AgentWorkspace]) {
        guard recentWorkspaces != value else {
            return
        }
        recentWorkspaces = value
    }

    private func setManagedWorktreesIfChanged(_ value: [WorktreeListItem]) {
        guard managedWorktrees != value else {
            return
        }
        managedWorktrees = value
    }

    private func setSidebarProjectsIfChanged(_ value: [AgentProject]) {
        guard sidebarProjects != value else {
            return
        }
        sidebarProjects = value

        var byID: [String: AgentProject] = [:]
        byID.reserveCapacity(value.count)
        for project in value {
            byID[project.id] = project
        }
        sidebarProjectsByID = byID
        if let sessionWorkspaceIDs {
            setSessionWorkspaceIDs(sessionWorkspaceIDs)
        }
    }

    private func reloadRecentWorkspaces() {
        setRecentWorkspacesIfChanged(recentWorkspaceStore.load(endpoint: appStore.endpoint))
        reloadSessionListPreferences()
        reloadSessionControlStates()
        reloadSessionReminders()
    }

    private func reloadSessionListPreferences() {
        let preferences = sessionListPreferenceStore.load(endpoint: appStore.endpoint)
        let loadedSessionWorkspaceIDs = normalizedSessionWorkspaceIDs(preferences.sessionWorkspaceIDs)
        guard pinnedSessionIDs != preferences.pinnedSessionIDs
            || archivedSessionIDs != preferences.archivedSessionIDs
            || sessionWorkspaceIDs != loadedSessionWorkspaceIDs
        else {
            return
        }
        pinnedSessionIDs = preferences.pinnedSessionIDs
        archivedSessionIDs = preferences.archivedSessionIDs
        sessionWorkspaceIDs = loadedSessionWorkspaceIDs
        if loadedSessionWorkspaceIDs != preferences.sessionWorkspaceIDs {
            saveSessionListPreferences()
        }
        rebuildSessionIndexes()
    }

    private func saveSessionListPreferences() {
        sessionListPreferenceStore.save(
            SessionListPreferences(
                pinnedSessionIDs: pinnedSessionIDs,
                archivedSessionIDs: archivedSessionIDs,
                sessionWorkspaceIDs: sessionWorkspaceIDs
            ),
            endpoint: appStore.endpoint
        )
    }

    private func setSessionWorkspaceIDs(_ value: Set<String>?) {
        let normalized = normalizedSessionWorkspaceIDs(value)
        guard sessionWorkspaceIDs != normalized else {
            return
        }
        sessionWorkspaceIDs = normalized
        saveSessionListPreferences()
        rebuildProjectSessionListSnapshots()
        reconcileSelectedProjectAfterSessionWorkspaceChange()
    }

    private func normalizedSessionWorkspaceIDs(_ value: Set<String>?) -> Set<String>? {
        let validProjectIDs = Set(sidebarProjects.map(\.id))
        guard let value else {
            return nil
        }
        let selectedIDs = value.intersection(validProjectIDs)
        // 全选和默认显示全部是同一个语义，归一成 nil，避免 UI 出现多余的“恢复全部显示”按钮。
        return selectedIDs == validProjectIDs ? nil : selectedIDs
    }

    private func reconcileSelectedProjectAfterSessionWorkspaceChange() {
        guard let selectedProjectID,
              !isWorkspaceShownInSessions(selectedProjectID),
              selectedSessionID == nil
        else {
            return
        }
        setSelectedProjectID(sessionSidebarProjects.first?.id)
        setSelectedSessionID(nil)
        disconnectWebSocket()
    }

    private func reloadSessionControlStates() {
        let states = sessionControlStateStore.load(endpoint: appStore.endpoint)
        guard sessionControlStateByID != states else {
            return
        }
        sessionControlStateByID = states
    }

    private func saveSessionControlStates() {
        sessionControlStateStore.save(sessionControlStateByID, endpoint: appStore.endpoint)
    }

    private func setSessionControlState(_ state: SessionControlState, sessionID: SessionID) {
        guard sessionControlStateByID[sessionID] != state else {
            return
        }
        sessionControlStateByID[sessionID] = state
        saveSessionControlStates()
    }

    private func reloadSessionReminders() {
        let reminders = sessionReminderStore.load(endpoint: appStore.endpoint)
        guard sessionRemindersByID != reminders else {
            return
        }
        sessionRemindersByID = reminders
    }

    private func saveSessionReminders() {
        sessionReminderStore.save(sessionRemindersByID, endpoint: appStore.endpoint)
    }

    private func clearSessionReminders(forProjectID projectID: String) {
        let sessionIDs = sessions
            .filter { $0.projectID == projectID }
            .map(\.id)
        guard !sessionIDs.isEmpty else {
            return
        }
        for sessionID in sessionIDs {
            sessionRemindersByID.removeValue(forKey: sessionID)
            sessionReminderScheduler.cancel(sessionID: sessionID)
        }
        saveSessionReminders()
    }

    private func rememberWorkspace(_ workspace: AgentWorkspace) {
        let next = recentWorkspaceStore.upsert(workspace, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
    }

    private func upsertManagedWorktree(_ item: WorktreeListItem) {
        var next = managedWorktrees.filter { $0.id != item.id }
        next.insert(item, at: 0)
        setManagedWorktreesIfChanged(next)
    }

    private func forgetWorkspaceAfterWorktreeDeletion(_ workspace: AgentWorkspace) {
        let project = workspace.project
        let next = recentWorkspaceStore.forget(id: project.id, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        clearSessionReminders(forProjectID: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            setSelectedProjectID(nil)
            setSelectedSessionID(nil)
            disconnectWebSocket()
        }
    }

    private func ensureWorkspace(for project: AgentProject) -> AgentWorkspace {
        if let workspace = workspacesByID[project.id] {
            return workspace
        }
        let workspace = AgentWorkspace(project: project)
        rememberWorkspace(workspace)
        return workspacesByID[workspace.id] ?? workspace
    }

    private func ensureWorkspaceForKnownProjectID(_ projectID: String) -> AgentWorkspace? {
        if let workspace = workspacesByID[projectID] {
            return workspace
        }
        if let project = sidebarProjectsByID[projectID] ?? projectsByID[projectID] {
            return ensureWorkspace(for: project)
        }
        return nil
    }

    private enum WorkspaceAvailability {
        case available
        case unavailable(String)
        case indeterminate
    }

    // 会话加载失败时，用 resolve 复核这个工作区到底是“真没了”还是“暂时连不上”：
    // - resolve 成功 → 路径仍在 allowlist 内，原失败多半是网关冷启动等瞬时问题。
    // - resolve 返回 4xx → agentd 明确判定路径不可用（被删 / 掉出 allowlist）。
    // - resolve 抛传输层错误（连不上 agentd） → 无法判定，按瞬时处理，不冤枉标记。
    private func evaluateWorkspaceAvailability(_ workspace: AgentWorkspace) async -> WorkspaceAvailability {
        do {
            let client = try clientFactory()
            _ = try await client.resolveWorkspace(path: workspace.path)
            return .available
        } catch let error as AgentAPIError {
            if case let .server(status, _) = error, (400..<500).contains(status) {
                return .unavailable("“\(workspace.name)”已不在允许范围或已被删除，可重试或从当前设备移除")
            }
            return .indeterminate
        } catch {
            return .indeterminate
        }
    }

    private func handleWorkspaceLoadFailure(workspace: AgentWorkspace, error: Error) async {
        if let policyFailure = sessionListPolicyFailure(from: error) {
            registerSessionListCooldown(policyFailure, for: workspace)
            if sessions(forProjectID: workspace.id).isEmpty {
                // 首屏还没有可展示数据时保留一个友好错误标记，让 bootstrap 按 cooldown 继续自愈。
                let message = "会话列表刷新过快，将在 \(policyFailure.retryAfterSeconds) 秒后自动重试。"
                setStatusMessage(message)
                setErrorMessage(message)
            } else {
                // 已有列表时继续展示旧数据，限流只是后台同步延迟，不应升级成红色全局错误。
                setStatusMessage("会话列表刷新过快，已保留现有会话，稍后自动重试。")
                setErrorMessage(nil)
            }
            return
        }
        switch await evaluateWorkspaceAvailability(workspace) {
        case .unavailable(let message):
            markWorkspaceUnavailable(workspace.id)
            // 明确的不可用态：清掉全局错误，bootstrap 的退避重试不再死磕一个已失效的目录。
            setErrorMessage(nil)
            setStatusMessage(message)
        case .available, .indeterminate:
            clearWorkspaceUnavailable(workspace.id)
            setErrorMessage(error.localizedDescription)
        }
    }

    private func markWorkspaceUnavailable(_ id: String) {
        guard !unavailableWorkspaceIDs.contains(id) else {
            return
        }
        unavailableWorkspaceIDs.insert(id)
    }

    private func clearWorkspaceUnavailable(_ id: String) {
        guard unavailableWorkspaceIDs.contains(id) else {
            return
        }
        unavailableWorkspaceIDs.remove(id)
    }

    private func sessionForExplicitSelection(_ item: AgentSession) -> AgentSession {
        if let workspace = workspaceForSession(item) {
            let aligned = session(item, in: workspace)
            upsert(aligned)
            return aligned
        }
        if let project = sidebarProjectsByID[item.projectID] ?? projectsByID[item.projectID] {
            let workspace = ensureWorkspace(for: project)
            let aligned = session(item, in: workspace)
            upsert(aligned)
            return aligned
        }
        let aligned = alignSessionToKnownWorkspace(item)
        upsert(aligned)
        return aligned
    }

    private func setExpandedProjectIDs(_ value: Set<String>) {
        guard expandedProjectIDs != value else {
            return
        }
        expandedProjectIDs = value
        rebuildProjectSessionListSnapshots()
    }

    private func insertExpandedProjectID(_ value: String) {
        guard !expandedProjectIDs.contains(value) else {
            return
        }
        expandedProjectIDs.insert(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
    }

    private func removeExpandedProjectID(_ value: String) {
        guard expandedProjectIDs.contains(value) else {
            return
        }
        expandedProjectIDs.remove(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
    }

    private func revealProjectInSidebar(_ projectID: String) {
        // 选中历史会话、恢复前台或 create 成功后，只展开所属项目这一支。
        // snapshot 按项目增量重建，避免右侧高频会话内容变化时牵动整个侧栏列表。
        insertExpandedProjectID(projectID)
    }

    private func setShowingAllSessionProjectIDs(_ value: Set<String>) {
        guard showingAllSessionProjectIDs != value else {
            return
        }
        showingAllSessionProjectIDs = value
        sessionVisibleLimitByProjectID = sessionVisibleLimitByProjectID.filter { value.contains($0.key) }
        rebuildProjectSessionListSnapshots()
    }

    private func insertShowingAllSessionProjectID(_ value: String) {
        setSessionVisibleLimit(Self.sessionPreviewLimit + Self.sessionExpansionStep, forProjectID: value)
    }

    private func removeShowingAllSessionProjectID(_ value: String) {
        setSessionVisibleLimit(nil, forProjectID: value)
    }

    private func sessionVisibleLimit(forProjectID projectID: String) -> Int {
        max(Self.sessionPreviewLimit, sessionVisibleLimitByProjectID[projectID] ?? Self.sessionPreviewLimit)
    }

    private func setSessionVisibleLimit(_ limit: Int?, forProjectID projectID: String) {
        let normalized = limit.map { max(Self.sessionPreviewLimit, $0) }
        let current = sessionVisibleLimitByProjectID[projectID]
        let next = normalized.flatMap { $0 > Self.sessionPreviewLimit ? $0 : nil }
        guard current != next else {
            return
        }
        if let next {
            sessionVisibleLimitByProjectID[projectID] = next
            showingAllSessionProjectIDs.insert(projectID)
        } else {
            sessionVisibleLimitByProjectID.removeValue(forKey: projectID)
            showingAllSessionProjectIDs.remove(projectID)
        }
        rebuildProjectSessionListSnapshot(forProjectID: projectID)
    }

    private func setSelectedProjectID(_ value: String?) {
        guard selectedProjectID != value else {
            return
        }
        selectedProjectID = value
    }

    private func setSelectedSessionID(_ value: SessionID?) {
        guard selectedSessionID != value else {
            return
        }
        selectedSessionID = value
    }

    private func setStatusMessage(_ value: String?) {
        guard statusMessage != value else {
            return
        }
        statusMessage = value
    }

    private func setErrorMessage(_ value: String?) {
        guard errorMessage != value else {
            return
        }
        errorMessage = value
    }

    private func setHistoryLoadProgress(sessionID: SessionID, title: String, fraction: Double) {
        let bounded = min(max(fraction, 0), 1)
        let next = HistoryLoadProgress(sessionID: sessionID, title: title, fraction: bounded)
        guard historyLoadProgressBySessionID[sessionID] != next else {
            return
        }
        historyLoadProgressBySessionID[sessionID] = next
    }

    private func clearHistoryLoadProgress(sessionID: SessionID) {
        historyLoadProgressBySessionID.removeValue(forKey: sessionID)
    }

    private func setWebSocketStatus(_ value: WebSocketStatus) {
        guard webSocketStatus != value else {
            return
        }
        webSocketStatus = value
    }

    private func clearConnectionData() {
        setSelectedSessionID(nil)
        setSelectedProjectID(nil)
        setProjectsIfChanged([])
        setRecentWorkspacesIfChanged([])
        setSidebarProjectsIfChanged([])
        unavailableWorkspaceIDs = []
        sessions = []
        setExpandedProjectIDs([])
        setShowingAllSessionProjectIDs([])
        frozenAllSessionOrder = []
        frozenSessionOrderByProjectID = [:]
        sessionPageCursorByProjectID = [:]
        sessionHasMoreByProjectID = [:]
        sessionPageRequestTokenByProjectID = [:]
        sessionPageLoadingTokenByProjectID = [:]
        sessionListFirstPageInFlightByKey.values.forEach { $0.task.cancel() }
        sessionListFirstPageInFlightByKey = [:]
        sessionListFirstPageCacheByKey = [:]
        sessionListCooldownUntilByBudgetKey = [:]
        sessionListReconciliationTasksByProjectID.values.forEach { $0.cancel() }
        sessionListReconciliationTasksByProjectID = [:]
        historyPreviousCursorBySessionID = [:]
        historyHasMoreBeforeBySessionID = [:]
        historySnapshotSeqBySessionID = [:]
        historyPageRequestTokenBySessionID = [:]
        historyFirstPageInFlightByKey.values.forEach { $0.task.cancel() }
        historyFirstPageInFlightByKey = [:]
        historyFirstPageCacheByKey = [:]
        historyLoadJobsBySessionID.values.forEach { $0.task.cancel() }
        historyLoadJobsBySessionID = [:]
        historyLoadJobTokenBySessionID = [:]
        historyLoadedSignatureBySessionID = [:]
        historyLoadedQualityBySessionID = [:]
        freshEmptyHistorySignatureBySessionID = [:]
        initialHistoryLoadingSessionIDs = []
        historyLoadProgressBySessionID = [:]
        historySavingsNoticesBySessionID = [:]
        loadingEarlierHistorySessionIDs = []
        lastSeenEventSeqBySessionID = [:]
        listProjectionBySessionID = [:]
        reloadSessionControlStates()
        foregroundActivityBySessionID = [:]
        runtimeActivityBySessionID = [:]
        locallyCompletedSessionIDs = []
        locallyCompletedGoalThreadIDs = []
        runtimeEventFlushTasks.values.forEach { $0.cancel() }
        runtimeEventFlushTasks = [:]
        foregroundActivityClearTasks.values.forEach { $0.cancel() }
        foregroundActivityClearTasks = [:]
        rebuildProjectSessionListSnapshots()
    }

    private func upsert(_ session: AgentSession) {
        let session = sessionPreparedForStorage(alignSessionToKnownWorkspace(session))
        syncRuntimeActivity(with: session)
        contextStore.upsert(from: session)
        if let index = sessionIndexByID[session.id] {
            guard sessions[index] != session else {
                return
            }
            var next = sessions
            next[index] = session
            // 单次赋值让 @Published 只通知一次，也让派生索引只重建一次。
            sessions = next
            return
        }
        sessions = [session] + sessions
    }

    private func ingestSessionContexts(_ items: [AgentSession]) {
        for session in items {
            contextStore.upsert(from: session)
        }
    }

    private func ingestHistoryContext(_ context: SessionContextSnapshot?, fallbackSessionID: SessionID) {
        guard let context else {
            return
        }
        contextStore.upsert(context, fallbackSessionID: fallbackSessionID)
    }

    private func updateSession(_ id: String, mutate: (inout AgentSession) -> Void) {
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        let oldValue = next[index]
        mutate(&next[index])
        guard next[index] != oldValue else {
            return
        }
        sessions = next
    }

    private func applyThreadGoal(
        _ goal: ThreadGoal,
        fallbackSessionID: SessionID? = nil,
        respectsLocalCompletion: Bool = true
    ) {
        let sessionID = fallbackSessionID ?? goal.threadID
        let goal = normalizedThreadGoalForApply(goal, sessionID: sessionID, respectsLocalCompletion: respectsLocalCompletion)
        updateSession(sessionID) { item in
            item.goal = goal
        }
        if sessionID != goal.threadID {
            updateSession(goal.threadID) { item in
                item.goal = goal
            }
        }
        contextStore.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                threadID: goal.threadID,
                goal: goal,
                updatedAt: Date()
            ),
            fallbackSessionID: sessionID
        )
    }

    private func clearThreadGoal(sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.remove(sessionID)
        updateSession(sessionID) { item in
            if let goal = item.goal {
                clearLocalCompletedGoalMark(goal, sessionID: sessionID)
            }
            item.goal = nil
        }
        contextStore.clearGoal(sessionID: sessionID)
    }

    private func sessionPreservingLocalCompletedStatus(_ incoming: AgentSession) -> AgentSession {
        var next = incoming
        if next.status == SessionStatus.completed.rawValue {
            locallyCompletedSessionIDs.insert(next.id)
            return next
        }
        guard Self.isRunningStatus(next.status),
              locallyCompletedSessionIDs.contains(next.id)
        else {
            return next
        }
        // 列表刷新可能落后于实时 turn/completed；这时不要让旧 running 快照把 UI 拉回运行态。
        next.status = SessionStatus.completed.rawValue
        next.activeTurnID = nil
        next.pendingApproval = nil
        next.pendingUserInput = nil
        return next
    }

    private func sessionPreservingLocalCompletedGoal(_ incoming: AgentSession) -> AgentSession {
        guard let goal = incoming.goal else {
            return incoming
        }
        var next = incoming
        next.goal = normalizedThreadGoalForApply(goal, sessionID: incoming.id, respectsLocalCompletion: true)
        return next
    }

    private func completeActiveThreadGoalIfNeeded(sessionID: SessionID) {
        guard let session = sessionsByID[sessionID],
              let goal = Self.matchingThreadGoal(for: session, context: contextStore.context(for: session.id)),
              goal.status == .active
        else {
            return
        }
        // turn/completed 是本地实时链路看到的权威完成信号；目标元数据刷新可能稍晚，
        // 先把 UI 收敛到完成态，避免任务结束后 composer 仍显示“运行中”。
        applyThreadGoal(completedGoal(from: goal), fallbackSessionID: sessionID, respectsLocalCompletion: false)
    }

    private func normalizedThreadGoalForApply(
        _ goal: ThreadGoal,
        sessionID: SessionID,
        respectsLocalCompletion: Bool
    ) -> ThreadGoal {
        if respectsLocalCompletion,
           goal.status == .active,
           hasLocalCompletedGoalMark(goal, sessionID: sessionID) {
            return completedGoal(from: goal)
        }
        if goal.status == .complete {
            markLocalCompletedGoal(goal, sessionID: sessionID)
        } else if respectsLocalCompletion, goal.status != .active {
            clearLocalCompletedGoalMark(goal, sessionID: sessionID)
        } else if !respectsLocalCompletion {
            clearLocalCompletedGoalMark(goal, sessionID: sessionID)
        }
        return goal
    }

    private func completedGoal(from goal: ThreadGoal) -> ThreadGoal {
        ThreadGoal(
            threadID: goal.threadID,
            objective: goal.objective,
            status: .complete,
            tokenBudget: goal.tokenBudget,
            tokensUsed: goal.tokensUsed,
            timeUsedSeconds: goal.timeUsedSeconds,
            createdAt: goal.createdAt,
            updatedAt: Date()
        )
    }

    private func markLocalCompletedGoal(_ goal: ThreadGoal, sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.formUnion(goalIdentityCandidates(goal, sessionID: sessionID))
    }

    private func clearLocalCompletedGoalMark(_ goal: ThreadGoal, sessionID: SessionID) {
        locallyCompletedGoalThreadIDs.subtract(goalIdentityCandidates(goal, sessionID: sessionID))
    }

    private func hasLocalCompletedGoalMark(_ goal: ThreadGoal, sessionID: SessionID) -> Bool {
        !locallyCompletedGoalThreadIDs.isDisjoint(with: goalIdentityCandidates(goal, sessionID: sessionID))
    }

    private func goalIdentityCandidates(_ goal: ThreadGoal, sessionID: SessionID) -> Set<SessionID> {
        var candidates: Set<SessionID> = []
        for value in [sessionID, goal.threadID, sessionsByID[sessionID]?.resumeID, contextStore.context(for: sessionID)?.threadID] {
            if let identity = Self.nonEmptyThreadIdentity(value) {
                candidates.insert(identity)
            }
        }
        return candidates
    }

    private func markApprovalDecisionPending(_ approvalID: String, sessionID: SessionID) {
        var ids = pendingApprovalDecisionIDsBySessionID[sessionID] ?? []
        ids.insert(approvalID)
        pendingApprovalDecisionIDsBySessionID[sessionID] = ids
    }

    private func clearPendingApprovalDecision(sessionID: SessionID, approvalID: String) {
        guard var ids = pendingApprovalDecisionIDsBySessionID[sessionID] else {
            return
        }
        ids.remove(approvalID)
        if ids.isEmpty {
            pendingApprovalDecisionIDsBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingApprovalDecisionIDsBySessionID[sessionID] = ids
        }
    }

    private func clearPendingApprovalDecisions(sessionID: SessionID) {
        pendingApprovalDecisionIDsBySessionID.removeValue(forKey: sessionID)
    }

    private func isApprovalDecisionPending(_ approval: ApprovalSummary, sessionID: SessionID) -> Bool {
        pendingApprovalDecisionIDsBySessionID[sessionID]?.contains(approval.id) == true
    }

    private func markUserInputResponsePending(_ request: AgentUserInputRequest, sessionID: SessionID) {
        var ids = pendingUserInputResponseIDsBySessionID[sessionID] ?? []
        ids.insert(request.id)
        pendingUserInputResponseIDsBySessionID[sessionID] = ids
        var requests = pendingUserInputRequestsBySessionID[sessionID] ?? [:]
        requests[request.id] = request
        pendingUserInputRequestsBySessionID[sessionID] = requests
    }

    @discardableResult
    private func clearPendingUserInputResponse(sessionID: SessionID, requestID: String) -> AgentUserInputRequest? {
        let request = pendingUserInputRequestsBySessionID[sessionID]?[requestID]
        pendingUserInputRequestsBySessionID[sessionID]?[requestID] = nil
        if pendingUserInputRequestsBySessionID[sessionID]?.isEmpty == true {
            pendingUserInputRequestsBySessionID.removeValue(forKey: sessionID)
        }
        guard var ids = pendingUserInputResponseIDsBySessionID[sessionID] else {
            return request
        }
        ids.remove(requestID)
        if ids.isEmpty {
            pendingUserInputResponseIDsBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingUserInputResponseIDsBySessionID[sessionID] = ids
        }
        return request
    }

    private func clearPendingUserInputResponses(sessionID: SessionID) {
        pendingUserInputResponseIDsBySessionID.removeValue(forKey: sessionID)
        pendingUserInputRequestsBySessionID.removeValue(forKey: sessionID)
    }

    private func isUserInputResponsePending(_ request: AgentUserInputRequest, sessionID: SessionID) -> Bool {
        pendingUserInputResponseIDsBySessionID[sessionID]?.contains(request.id) == true
    }

    private func acceptUserInputResponseLocally(_ request: AgentUserInputRequest, sessionID: SessionID) {
        updateSession(sessionID) { item in
            if let currentInput = item.pendingUserInput, currentInput.id != request.id {
                return
            }
            // 服务端确认事件可能要等一会；本地先把阻塞点收起，避免用户看到一个置灰的旧表单。
            item.status = "running"
            item.pendingUserInput = nil
        }
        contextStore.upsert(
            SessionContextSnapshot(sessionID: sessionID, status: SessionContextStatus(type: "active"), updatedAt: Date()),
            fallbackSessionID: sessionID
        )
        conversationStore.resolveLatestPendingUserInput(sessionID: sessionID, skipped: false)
    }

    private func restoreUserInputRequestAfterFailure(_ request: AgentUserInputRequest, sessionID: SessionID) {
        updateSession(sessionID) { item in
            item.status = "waiting_for_input"
            item.pendingUserInput = request
        }
        contextStore.upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                status: SessionContextStatus(type: "active", activeFlags: ["waitingOnUserInput"]),
                tasks: [SessionContextTask(id: request.id, kind: "user_input", title: request.title, subtitle: nil, status: "waiting")],
                updatedAt: Date()
            ),
            fallbackSessionID: sessionID
        )
        conversationStore.restorePendingUserInput(request, sessionID: sessionID)
    }

    private static func normalizedSession(_ session: AgentSession) -> AgentSession {
        var next = session
        if next.status != "waiting_for_approval" {
            next.pendingApproval = nil
        }
        if next.status != "waiting_for_input" {
            next.pendingUserInput = nil
        }
        return next
    }

    private func sessionPreservingActiveApproval(_ incoming: AgentSession) -> AgentSession {
        sessionPreservingActiveApproval(incoming, existing: sessionsByID[incoming.id])
    }

    private func sessionPreservingActiveApproval(_ incoming: AgentSession, existing: AgentSession?) -> AgentSession {
        var next = Self.normalizedSession(incoming)
        if shouldPreserveConnectedRunningSessionAgainstHistorySnapshot(incoming: next, existing: existing) {
            next.status = existing?.status ?? next.status
            next.activeTurnID = existing?.activeTurnID ?? next.activeTurnID
            next.pendingApproval = existing?.pendingApproval ?? next.pendingApproval
            next.pendingUserInput = existing?.pendingUserInput ?? next.pendingUserInput
        }
        if let userInput = next.pendingUserInput,
           isUserInputResponsePending(userInput, sessionID: next.id) {
            // 列表刷新可能读到补充信息提交前的旧快照；已在本地提交中的 request 不应重新顶回可见表单。
            next.status = "running"
            next.pendingUserInput = nil
        }
        // goal 是 thread 级元数据；列表刷新或上下文回填时必须按当前 thread 身份校验，
        // 否则同项目内切换对话会短暂显示另一个 thread 的目标状态。
        next.goal = Self.matchingThreadGoal(
            for: next,
            existingGoal: existing?.goal,
            context: contextStore.context(for: next.id)
        )
        if next.pendingApproval == nil,
           let existingApproval = existing?.pendingApproval,
           Self.canPreservePendingApproval(whileStatusIs: next.status) {
            // 列表/历史刷新拿到的 session 可能只是通用 running 快照；本地已有明确 approval_request 时，
            // 以实时事件为准保留审批入口，直到 approval_resolved/turn_completed/error 显式清理。
            next.status = "waiting_for_approval"
            next.pendingApproval = existingApproval
            return next
        }
        if next.pendingUserInput == nil,
           let existingInput = existing?.pendingUserInput,
           !isUserInputResponsePending(existingInput, sessionID: next.id),
           Self.canPreservePendingApproval(whileStatusIs: next.status) {
            next.status = "waiting_for_input"
            next.pendingUserInput = existingInput
        }
        return next
    }

    private func shouldPreserveConnectedRunningSessionAgainstHistorySnapshot(incoming: AgentSession, existing: AgentSession?) -> Bool {
        guard incoming.status == SessionStatus.history.rawValue,
              let existing,
              existing.isRunning,
              incoming.id == selectedSessionID,
              connectedSessionID == incoming.id,
              webSocket != nil
        else {
            return false
        }
        switch webSocketStatus {
        case .connecting, .connected:
            // 长任务运行中，thread/list 偶尔会返回滞后的 idle/notLoaded 快照。
            // 当前 iPad 仍有活动实时连接时，以本地运行态为准，避免下一次发送误走历史 resume。
            return true
        case .disconnected, .failed:
            return false
        }
    }

    private static func matchingThreadGoal(
        for session: AgentSession,
        existingGoal: ThreadGoal? = nil,
        context: SessionContextSnapshot?
    ) -> ThreadGoal? {
        if let goal = session.goal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        if let goal = existingGoal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        if let goal = context?.goal, threadGoal(goal, belongsTo: session, context: context) {
            return goal
        }
        return nil
    }

    private static func threadGoal(
        _ goal: ThreadGoal,
        belongsTo session: AgentSession,
        context: SessionContextSnapshot?
    ) -> Bool {
        guard let goalThreadID = nonEmptyThreadIdentity(goal.threadID) else {
            return false
        }
        return threadIdentityCandidates(for: session, context: context).contains(goalThreadID)
    }

    private static func threadIdentityCandidates(
        for session: AgentSession,
        context: SessionContextSnapshot?
    ) -> Set<SessionID> {
        var candidates: Set<SessionID> = []
        for value in [session.id, session.resumeID, context?.threadID] {
            if let identity = nonEmptyThreadIdentity(value) {
                candidates.insert(identity)
            }
        }
        return candidates
    }

    private static func nonEmptyThreadIdentity(_ value: String?) -> SessionID? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func canPreservePendingApproval(whileStatusIs status: String) -> Bool {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return true
        default:
            return false
        }
    }

    private func setForegroundActivity(
        _ activity: SessionForegroundActivity,
        sessionID: SessionID,
        autoClearAfter delay: UInt64? = nil
    ) {
        // 流式输出时每个 app-server 分片都会调到这里。@Published 字典即使赋同值也会触发
        // objectWillChange，进而让整张边栏 List 反复重绘、抢占主线程，导致点击发涩。
        // 因此仅在活动真正变化时才写回；计时器仍每次重置（它不是 @Published）。
        if foregroundActivityBySessionID[sessionID] != activity {
            foregroundActivityBySessionID[sessionID] = activity
        }
        foregroundActivityClearTasks[sessionID]?.cancel()
        guard let delay else {
            foregroundActivityClearTasks[sessionID] = nil
            return
        }
        // 部分 app-server 流式事件可能缺少完成事件，用空闲超时兜底，避免输出结束后仍一直显示正在回复。
        foregroundActivityClearTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard self?.foregroundActivityBySessionID[sessionID] == activity else {
                    return
                }
                self?.clearForegroundActivity(sessionID: sessionID)
            }
        }
    }

    private func clearForegroundActivity(sessionID: SessionID) {
        foregroundActivityClearTasks[sessionID]?.cancel()
        foregroundActivityClearTasks.removeValue(forKey: sessionID)
        if foregroundActivityBySessionID[sessionID] != nil {
            foregroundActivityBySessionID.removeValue(forKey: sessionID)
        }
    }
}
