import Foundation
import Network

// API 外观、网络状态源与事件批处理从 SessionStore 生命周期实现中解耦。
enum NetworkReachabilityStatus: Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
}

struct NetworkPathStatusUpdate: Equatable, Sendable {
    let sequence: UInt64
    let status: NetworkReachabilityStatus
}

protocol NetworkPathStatusSource: AnyObject {
    var currentStatus: NetworkReachabilityStatus { get }
    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)? { get set }

    func start()
    func stop()
}

/// 生产环境的 Network.framework 适配层。SessionStore 只依赖精简状态协议，测试可以注入确定性事件源。
final class NWNetworkPathStatusSource: NetworkPathStatusSource {
    let monitor: NWPathMonitor
    let queue: DispatchQueue
    let lock = NSLock()
    var statusStorage: NetworkReachabilityStatus = .unknown
    var handlerStorage: ((NetworkPathStatusUpdate) -> Void)?
    var sequenceStorage: UInt64 = 0
    var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.queue = DispatchQueue(label: "com.gaixianggeng.mimi.network-path")
    }

    var currentStatus: NetworkReachabilityStatus {
        lock.withLock { statusStorage }
    }

    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)? {
        get { lock.withLock { handlerStorage } }
        set { lock.withLock { handlerStorage = newValue } }
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard started else { return false }
            started = false
            handlerStorage = nil
            return true
        }
        guard shouldStop else { return }
        monitor.cancel()
    }

    func publish(_ status: NetworkReachabilityStatus) {
        let delivery = lock.withLock { () -> (((NetworkPathStatusUpdate) -> Void)?, NetworkPathStatusUpdate) in
            statusStorage = status
            // 序号必须在 NWPathMonitor 的串行回调里生成，不能等 MainActor Task 开始后再编号；
            // 否则快速断网再联网时，晚执行的旧 Task 仍可能拿到更大的序号并覆盖新状态。
            sequenceStorage &+= 1
            return (handlerStorage, NetworkPathStatusUpdate(sequence: sequenceStorage, status: status))
        }
        delivery.0?(delivery.1)
    }
}

/// 注入了 API mock 的测试默认使用稳定在线源，避免每个单元测试都启动系统 monitor。
final class StaticNetworkPathStatusSource: NetworkPathStatusSource {
    let currentStatus: NetworkReachabilityStatus
    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)?

    init(_ status: NetworkReachabilityStatus) {
        self.currentStatus = status
    }

    func start() {}
    func stop() { onStatusChange = nil }
}

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func modelOptions() async throws -> [CodexAppServerModelOption]
    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool
    func capabilities(path: String?) async throws -> CapabilityListResponse
    func resolveWorkspace(path: String) async throws -> AgentWorkspace
    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse
    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse
    func listWorktrees() async throws -> [WorktreeListItem]
    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse
    func pruneMissingWorktrees() async throws -> WorktreePruneResponse
    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse
    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse
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
    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse
    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse
    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse
    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse
    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse
    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage
    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse
    func threadGoal(threadID: String) async throws -> ThreadGoal?
    func setThreadGoal(threadID: String, objective: String?, status: ThreadGoalStatus?, tokenBudget: Int64?) async throws -> ThreadGoal
    func clearThreadGoal(threadID: String) async throws
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func forkSession(threadID: String, workspace: AgentWorkspace) async throws -> AgentSession
    func stopSession(id: String) async throws
    func setSessionArchived(id: String, archived: Bool) async throws
    func setThreadName(threadID: String, name: String) async throws
    func compactThread(threadID: String) async throws
    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus?
    func startReview(threadID: String, target: CodexAppServerReviewTarget, delivery: CodexAppServerReviewDelivery?) async throws -> CodexAppServerReviewStartResult
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage
    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage
    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary?
    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary?
}

extension SessionStoreAPIClient {
    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        let value = runtimeProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "codex" || value == "openai"
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        nil
    }
    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        try await refreshRateLimit(sessionID: nil)
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

    func setThreadName(threadID: String, name: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func compactThread(threadID: String) async throws {
        throw AgentAPIError.invalidResponse
    }

    func unsubscribeThread(threadID: String) async throws -> CodexAppServerThreadUnsubscribeStatus? {
        throw AgentAPIError.invalidResponse
    }

    func startReview(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery? = nil
    ) async throws -> CodexAppServerReviewStartResult {
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

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        // 清理预览必须先由 agentd 根据固定保留策略重新计算，客户端不在本地猜候选。
        throw AgentAPIError.invalidResponse
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        // 默认替身不执行破坏性操作；真实 client 固定走带 confirm 的 cleanup API。
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

    func gitQuickPublish(path: String, message: String, remote: String?, confirmed: Bool) async throws -> GitQuickPublishResponse {
        // 快捷发布涉及 stage、commit 和 push，测试替身默认不执行任何写操作。
        throw AgentAPIError.invalidResponse
    }

    func gitTestFlightStatus(path: String) async throws -> GitTestFlightStatusResponse {
        // TestFlight 能力必须由主机预检，客户端不能根据文件名自行推断。
        throw AgentAPIError.invalidResponse
    }

    func gitTestFlightRun(path: String, whatToTest: String, confirmed: Bool) async throws -> GitTestFlightStatusResponse {
        // TestFlight 是外部发布动作，默认替身不执行。
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

    func transcribeVoice(filename: String, contentType: String, audioData: Data, language: String?) async throws -> VoiceTranscriptionResponse {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/voice/transcribe。
        throw AgentAPIError.invalidResponse
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        try await sessionsPage(projectID: workspace.rootProjectID ?? workspace.id, cursor: cursor, limit: limit)
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit)
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?, consistency: SessionListConsistency) async throws -> SessionsPage {
        try await sessionsPage(workspace: workspace, cursor: cursor, limit: limit)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        // 旧测试替身与尚未升级的服务默认视为不支持；SessionStore 会静默保留本地搜索结果。
        throw AgentAPIError.invalidResponse
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

@MainActor
final class TerminalStreamStore {
    let maxBatchSize: Int
    var eventsBySessionID: [SessionID: [AgentEvent]] = [:]

    init(maxBatchSize: Int = 64) {
        self.maxBatchSize = max(1, maxBatchSize)
    }

    func append(_ event: AgentEvent, sessionID: SessionID) -> Bool {
        var events = eventsBySessionID[sessionID] ?? []
        if let previous = events.last,
           let merged = previous.mergingContiguous(with: event) {
            events[events.index(before: events.endIndex)] = merged
        } else {
            events.append(event)
        }
        eventsBySessionID[sessionID] = events
        return events.count >= maxBatchSize
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
