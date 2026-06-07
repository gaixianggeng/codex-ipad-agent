import Foundation

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func modelOptions() async throws -> [CodexAppServerModelOption]
    func resolveWorkspace(path: String) async throws -> AgentWorkspace
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage
    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func stopSession(id: String) async throws
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage
}

extension SessionStoreAPIClient {
    func modelOptions() async throws -> [CodexAppServerModelOption] {
        []
    }

    func session(id: String) async throws -> SessionResponse {
        try await session(id: id, afterSeq: nil)
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        // 默认实现只服务于不直连 agentd 的测试替身；真实 client 会覆写并请求 /api/workspaces/resolve。
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

}

enum SessionForegroundActivity: Equatable, Sendable {
    case refreshing
    case waitingForAssistant
    case receivingAssistant

    var title: String {
        switch self {
        case .refreshing:
            return "同步中"
        case .waitingForAssistant:
            return "等待回复"
        case .receivingAssistant:
            return "正在回复"
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .refreshing, .waitingForAssistant:
            return true
        case .receivingAssistant:
            return false
        }
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
        if !isShowingAll {
            return "展开显示"
        }
        if canLoadMore {
            return isLoadingMore ? "加载中..." : "加载更多"
        }
        return "收起显示"
    }
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
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published private(set) var expandedProjectIDs: Set<String> = []
    @Published private(set) var showingAllSessionProjectIDs: Set<String> = []
    @Published var isLoading = false
    @Published var webSocketStatus: WebSocketStatus = .disconnected
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var isRefreshingSelectedSession = false
    @Published private(set) var appServerModelOptions: [CodexAppServerModelOption] = []
    @Published private(set) var isRefreshingAppServerModels = false
    @Published private var foregroundActivityBySessionID: [SessionID: SessionForegroundActivity] = [:]

    private let appStore: AppStore
    private let conversationStore: ConversationStore
    private let logStore: LogStore
    private let contextStore: SessionContextStore
    private let eventReducer: EventReducer
    private let recentWorkspaceStore: RecentWorkspaceStore
    private let terminalStreamStore = TerminalStreamStore()
    private let clientFactory: () throws -> any SessionStoreAPIClient
    private let webSocketFactory: () -> any SessionWebSocketClient
    private let webSocketReconnectDelayNanoseconds: (Int) -> UInt64
    private var webSocket: (any SessionWebSocketClient)?
    private var connectedSessionID: String?
    private var webSocketReconnectTask: Task<Void, Never>?
    private var webSocketReconnectAttemptBySessionID: [SessionID: Int] = [:]
    private var lastSeenEventSeqBySessionID: [SessionID: EventSequence] = [:]
    private var runtimeEventFlushTasks: [SessionID: Task<Void, Never>] = [:]
    private var foregroundActivityClearTasks: [SessionID: Task<Void, Never>] = [:]
    private var projectsByID: [String: AgentProject] = [:]
    private var workspacesByID: [String: AgentWorkspace] = [:]
    private var sidebarProjectsByID: [String: AgentProject] = [:]
    private var sessionsByID: [SessionID: AgentSession] = [:]
    private var sessionIndexByID: [SessionID: Int] = [:]
    private var sortedAllSessions: [AgentSession] = []
    private var sortedSessionsByProjectID: [String: [AgentSession]] = [:]
    private var previewSessionsByProjectID: [String: [AgentSession]] = [:]
    private var hiddenSessionCountByProjectID: [String: Int] = [:]
    private var sessionListSnapshotsByProjectID: [String: ProjectSessionListSnapshot] = [:]
    private var frozenAllSessionOrder: [SessionID] = []
    private var frozenSessionOrderByProjectID: [String: [SessionID]] = [:]
    private var sessionPageCursorByProjectID: [String: String] = [:]
    private var sessionHasMoreByProjectID: [String: Bool] = [:]
    private var sessionPageRequestTokenByProjectID: [String: Int] = [:]
    private var sessionPageLoadingTokenByProjectID: [String: Int] = [:]
    private var historyPreviousCursorBySessionID: [SessionID: String] = [:]
    private var historyHasMoreBeforeBySessionID: [SessionID: Bool] = [:]
    private var historyPageRequestTokenBySessionID: [SessionID: Int] = [:]
    private var initialHistoryLoadingSessionIDs: Set<SessionID> = []
    private var appServerModelOptionsLastRefresh: Date?
    @Published private var loadingEarlierHistorySessionIDs: Set<SessionID> = []

    private let foregroundOutputIdleClearDelay: UInt64 = 8_000_000_000
    private let runtimeEventFlushDelayNanoseconds: UInt64 = 80_000_000
    private let historyPageLimit = 120
    private static let webSocketReconnectMaxAttempts = 5
    private static let optimisticSessionSource = "local"
    static let sessionPreviewLimit = 3
    private static let initialSessionPageLimit = 80
    private static let expandedSessionPageLimit = 120

    init(
        appStore: AppStore,
        conversationStore: ConversationStore,
        logStore: LogStore,
        contextStore: SessionContextStore? = nil,
        recentWorkspaceStore: RecentWorkspaceStore? = nil,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil
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
        self.clientFactory = clientFactory ?? { try appStore.makeSessionStoreAPIClient() }
        self.webSocketFactory = webSocketFactory ?? { appStore.makeSessionWebSocketClient() }
        self.webSocketReconnectDelayNanoseconds = webSocketReconnectDelayNanoseconds ?? Self.defaultWebSocketReconnectDelayNanoseconds
    }

    private static func defaultWebSocketReconnectDelayNanoseconds(attempt: Int) -> UInt64 {
        let boundedAttempt = max(1, min(attempt, 4))
        let seconds = UInt64(1 << (boundedAttempt - 1))
        return seconds * 1_000_000_000
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
        guard let selectedProjectID else {
            return sortedAllSessions
        }
        return sortedSessionsByProjectID[selectedProjectID] ?? []
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    func isShowingAllSessions(projectID: String) -> Bool {
        showingAllSessionProjectIDs.contains(projectID)
    }

    func sessions(forProjectID projectID: String) -> [AgentSession] {
        sortedSessionsByProjectID[projectID] ?? []
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        guard !isShowingAllSessions(projectID: projectID) else {
            return sessions(forProjectID: projectID)
        }
        return previewSessionsByProjectID[projectID] ?? []
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        hiddenSessionCountByProjectID[projectID] ?? 0
    }

    func canLoadMoreSessions(projectID: String) -> Bool {
        sessionHasMoreByProjectID[projectID] == true
    }

    func sessionListSnapshot(forProjectID projectID: String) -> ProjectSessionListSnapshot {
        sessionListSnapshotsByProjectID[projectID] ?? makeProjectSessionListSnapshot(forProjectID: projectID)
    }

    func canLoadEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return historyHasMoreBeforeBySessionID[sessionID] == true
    }

    func isLoadingEarlierHistory(sessionID: SessionID?) -> Bool {
        guard let sessionID else {
            return false
        }
        return loadingEarlierHistorySessionIDs.contains(sessionID)
    }

    func bootstrap() async {
        guard appStore.isConfigured else {
            return
        }
        // 冷启动有两层“没就绪”：① VPN / Tailscale 隧道还没建好，首个 HTTP 请求就失败；
        // ② agentd 的 HTTP 端口先于 app-server gateway 上游就绪——projects 能立刻拿到，但首个
        // 会话请求 / WebSocket 连接会因为上游还没接受连接而失败。scenePhase 的 .active 回调在
        // 冷启动不会触发（没有 background→active 切换），所以这里必须自己退避重试，直到数据
        // 真正加载完成。否则只要 projects 一到手就收手，首屏会停在“有项目、无会话、点什么都
        // 连不上”的半成品状态，只能靠用户杀进程重开才恢复。
        await refreshUntilLoaded(maxWait: 45, autoAttach: true)
    }

    // refreshAll 成功拿到数据、或后端确实为空时都会清空 errorMessage；只要还有 errorMessage，
    // 就说明 projects / sessions / gateway 至少有一环没就绪，需要继续重试让首屏自愈。
    //
    // 冷启动失败基本是后端还没就绪（agentd / 隧道未通，或 app-server 上游还没接受连接），这类失败
    // 都很快返回，所以用较短的固定退避高频轮询：后端一就绪就能在 ~1s 内被探测到并自愈，而不是用
    // 慢退避白等。按总时长封顶而非固定次数，后端晚十几二十秒才起来也能等到，不会提前放弃又卡回
    // “要杀进程”的老问题。
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
            // 首个失败立刻快速重试一次（隧道/后端经常就差最后一两百毫秒），之后固定 ~0.9s 轮询。
            let backoffNanoseconds: UInt64 = attempt == 0 ? 300_000_000 : 900_000_000
            attempt += 1
            try? await Task.sleep(nanoseconds: backoffNanoseconds)
        }
    }

    func refreshAll(autoAttach: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        var requestToken: Int?
        var requestProjectID: String?
        var activeWorkspace: AgentWorkspace?
        do {
            let client = try clientFactory()
            let previousProjectID = selectedProjectID
            let previousSessionID = selectedSessionID
            let fetchedProjects = try await client.projects()
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
            let page = try await client.sessionsPage(workspace: workspace, cursor: nil, limit: Self.initialSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingSelection(pageSessions, projectID: projectID), projectID: projectID)
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
        disconnectWebSocket()
        await refreshSessions(forProjectID: workspace.id)
    }

    @discardableResult
    func openWorkspace(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setErrorMessage("请输入 Mac 上的目录路径")
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

    func forgetWorkspace(_ project: AgentProject) {
        let next = recentWorkspaceStore.forget(id: project.id, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            setSelectedProjectID(nil)
            setSelectedSessionID(nil)
            disconnectWebSocket()
        }
        setStatusMessage("已从当前设备移除 \(project.name)")
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
        await refreshSessions(forProjectID: workspace.id)
    }

    func toggleSessionListExpansion(projectID: String) async {
        if showingAllSessionProjectIDs.contains(projectID) {
            removeShowingAllSessionProjectID(projectID)
        } else {
            insertShowingAllSessionProjectID(projectID)
            if canLoadMoreSessions(projectID: projectID) {
                await loadMoreSessions(projectID: projectID)
            }
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

    func refreshSelectedProjectSessions() async {
        guard let selectedProjectID else {
            return
        }
        await refreshSessions(forProjectID: selectedProjectID)
    }

    func refreshCurrentContext() async {
        guard let session = selectedSession else {
            await refreshAll(autoAttach: false)
            return
        }
        await refreshSelectedSessionContent(session)
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

    func loadEarlierHistoryForSelectedSession() async {
        guard let session = selectedSession,
              let cursor = historyPreviousCursorBySessionID[session.id],
              canLoadEarlierHistory(sessionID: session.id),
              !loadingEarlierHistorySessionIDs.contains(session.id)
        else {
            return
        }
        loadingEarlierHistorySessionIDs.insert(session.id)
        defer {
            loadingEarlierHistorySessionIDs.remove(session.id)
        }
        do {
            let client = try clientFactory()
            let page = try await client.messagesPage(sessionID: session.id, before: cursor, limit: historyPageLimit)
            conversationStore.setHistory(page.messages, sessionID: session.id)
            updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: false)
            setErrorMessage(nil)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    func returnToSessionList() {
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

    func selectSession(_ session: AgentSession) async {
        let session = sessionForExplicitSelection(session)
        setSelectedProjectID(session.projectID)
        setSelectedSessionID(session.id)
        revealProjectInSidebar(session.projectID)
        setErrorMessage(nil)
        conversationStore.retainSessionCache(sessionID: session.id)
        logStore.retainSessionCache(sessionID: session.id)

        await loadHistoryIfNeeded(for: session)

        if session.isRunning {
            connectWebSocket(session)
        } else {
            disconnectWebSocket()
        }
    }

    func startNewSession() async {
        guard let selectedProjectID else {
            setErrorMessage("请先选择项目")
            return
        }
        await createSession(projectID: selectedProjectID, prompt: "", resume: nil)
    }

    func startNewSession(in project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        setSelectedProjectID(workspace.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(workspace.id)
        setErrorMessage(nil)
        disconnectWebSocket()
        await createSession(projectID: workspace.id, prompt: "", resume: nil)
    }

    @discardableResult
    func sendPrompt(_ text: String) async -> Bool {
        await sendTurn(CodexAppServerTurnPayload(prompt: text))
    }

    @discardableResult
    func sendTurn(_ payload: CodexAppServerTurnPayload) async -> Bool {
        guard !payload.isEmpty else {
            return false
        }
        let prompt = payload.previewText

        if let session = selectedSession, session.isRunning {
            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            let clientMessageID = UUID().uuidString
            conversationStore.appendLocalUser(prompt, sessionID: session.id, clientMessageID: clientMessageID, sendStatus: .sending, turnPayload: payload)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            guard socket.sendTurn(payload, clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("发送失败：WebSocket 未连接")
                return false
            }
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
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
        guard let session = selectedSession, session.isRunning, let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendCtrlC() {
            setErrorMessage("发送 Ctrl-C 失败：WebSocket 未连接")
        }
    }

    func decideApproval(_ approval: ApprovalSummary, accept: Bool) {
        guard let session = selectedSession, session.isRunning, let socket = readyWebSocket(for: session) else {
            setErrorMessage("审批失败：WebSocket 未连接")
            return
        }
        let decision = accept ? "accept" : "decline"
        guard socket.sendApprovalDecision(approvalID: approval.id, decision: decision, message: nil) else {
            setErrorMessage("审批发送失败：WebSocket 未连接")
            return
        }
        conversationStore.resolveApproval(approval, accepted: accept, sessionID: session.id)
        // 审批决定已经发出后先本地清空卡片，避免用户重复点击同一个 pending request。
        updateSession(session.id) { item in
            item.pendingApproval = nil
            if item.status == "waiting_for_approval" {
                item.status = "running"
            }
        }
        setStatusMessage(accept ? "已批准请求" : "已拒绝请求")
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

        if let session = selectedSession,
           session.isRunning,
           let clientMessageID = message.clientMessageID,
           let socket = readyWebSocket(for: session) {
            // 失败消息有 client_message_id 时直接复用原 row 重发，避免 timeline 里出现重复用户气泡。
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sending)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            let payload = message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt)
            guard socket.sendTurn(payload, clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("重试失败：WebSocket 未连接")
                return false
            }
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
            return true
        }

        // 会话已经结束或失败时，沿用普通发送路径重新创建/恢复 Codex thread。
        return await sendTurn(message.turnPayload ?? CodexAppServerTurnPayload(prompt: prompt))
    }

    func resumeFromForeground() async {
        guard appStore.isConfigured else {
            return
        }
        // 回前台同样可能赶上 gateway 还没恢复；做几秒的高频重试，避免单次失败后又卡到下次切换。
        // 正常情况下首次 refreshAll 就成功（errorMessage 为 nil），立即返回，不会有额外开销。
        await refreshUntilLoaded(maxWait: 10, autoAttach: true)
    }

    func stopSelectedSession() async {
        guard let session = selectedSession else {
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
            conversationStore.appendSystem("Codex 会话已停止。", sessionID: session.id)
            disconnectWebSocket()
            setStatusMessage("已停止会话")
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    @discardableResult
    private func createSession(projectID: String, prompt: String, resume: AgentSession?, clientMessageID: ClientMessageID? = nil) async -> Bool {
        await createSession(projectID: projectID, payload: CodexAppServerTurnPayload(prompt: prompt), resume: resume, clientMessageID: clientMessageID)
    }

    @discardableResult
    private func createSession(projectID: String, payload: CodexAppServerTurnPayload, resume: AgentSession?, clientMessageID: ClientMessageID? = nil) async -> Bool {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage("工作区已失效，请重新打开")
            return false
        }
        projectID = workspace.id
        isLoading = true
        defer { isLoading = false }
        let prompt = payload.previewText
        let optimisticSessionID = optimisticSessionID(projectID: projectID, resume: resume, clientMessageID: clientMessageID, prompt: prompt)
        if let optimisticSessionID,
           let clientMessageID {
            // 先做本地回显，网络慢或 create 失败时用户输入仍留在时间线；
            // 服务端确认后再用 client_message_id 合并到真实会话。
            if resume == nil {
                upsert(makeOptimisticSession(id: optimisticSessionID, projectID: projectID, prompt: prompt))
            }
            setSelectedProjectID(projectID)
            setSelectedSessionID(optimisticSessionID)
            insertExpandedProjectID(projectID)
            conversationStore.appendLocalUser(prompt, sessionID: optimisticSessionID, clientMessageID: clientMessageID, sendStatus: .sending, turnPayload: payload)
            setForegroundActivity(.waitingForAssistant, sessionID: optimisticSessionID)
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
                resumeID: resume?.resumeID ?? "",
                clientMessageID: clientMessageID
            ))
            let responseSession = self.session(response.session, in: workspace)

            if let optimisticSessionID,
               let clientMessageID,
               optimisticSessionID != responseSession.id {
                // 新建会话会从 local:<project>:<client_message_id> 切换到后端 session_id，
                // 这里迁移前台活动和本地气泡，保持列表/对话 store 解耦。
                conversationStore.moveLocalEcho(clientMessageID: clientMessageID, from: optimisticSessionID, to: responseSession.id)
                migrateForegroundActivity(from: optimisticSessionID, to: responseSession.id)
                if resume == nil {
                    removeSession(optimisticSessionID)
                }
            }
            upsert(responseSession)
            setSelectedProjectID(responseSession.projectID)
            setSelectedSessionID(responseSession.id)
            insertExpandedProjectID(responseSession.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”。
            await loadHistoryIfNeeded(for: responseSession)
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
                conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: responseSession.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: responseSession.id)
                if firstMessage.role == .assistant {
                    clearForegroundActivity(sessionID: responseSession.id)
                }
            }
            if resume != nil {
                conversationStore.appendSystem("已继续这个 Codex 历史会话。", sessionID: responseSession.id)
            }
            connectWebSocket(responseSession)
            setStatusMessage("会话已启动")
            setErrorMessage(nil)
            return true
        } catch {
            if let optimisticSessionID,
               let clientMessageID {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: optimisticSessionID, status: .failed)
                updateSession(optimisticSessionID) { item in
                    item.status = "failed"
                }
                clearForegroundActivity(sessionID: optimisticSessionID)
            }
            setErrorMessage(error.localizedDescription)
            return false
        }
    }

    private func loadHistoryIfNeeded(for session: AgentSession) async {
        guard !conversationStore.hasLoadedHistory(sessionID: session.id) else {
            return
        }
        guard !initialHistoryLoadingSessionIDs.contains(session.id) else {
            return
        }
        // 自动选择历史会话时只需要一个首屏请求；手动刷新仍会绕过这里拿最新 rollout。
        initialHistoryLoadingSessionIDs.insert(session.id)
        defer {
            initialHistoryLoadingSessionIDs.remove(session.id)
        }
        await loadHistory(for: session)
    }

    private func loadHistory(for session: AgentSession) async {
        let requestToken = beginHistoryPageRequest(sessionID: session.id)
        do {
            let client = try clientFactory()
            // 历史文件可能很大，移动端默认只加载最近一段上下文，避免打开会话时卡住 UI。
            let page = try await client.messagesPage(sessionID: session.id, before: nil, limit: historyPageLimit)
            guard isCurrentHistoryPageRequest(sessionID: session.id, token: requestToken) else {
                return
            }
            conversationStore.setHistory(page.messages, sessionID: session.id)
            updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: true)
        } catch {
            guard isCurrentHistoryPageRequest(sessionID: session.id, token: requestToken) else {
                return
            }
            setStatusMessage("历史消息读取失败：\(error.localizedDescription)")
        }
    }

    private func refreshSelectedSessionContent(_ session: AgentSession) async {
        isRefreshingSelectedSession = true
        defer { isRefreshingSelectedSession = false }

        do {
            let client = try clientFactory()
            // 手动刷新必须绕过 hasLoadedHistory 缓存，Mac/iPad 混合使用时 app-server 历史可能已经更新。
            let requestToken = beginHistoryPageRequest(sessionID: session.id)
            let page = try await client.messagesPage(sessionID: session.id, before: nil, limit: historyPageLimit)
            guard isCurrentHistoryPageRequest(sessionID: session.id, token: requestToken) else {
                return
            }
            conversationStore.setHistory(page.messages, sessionID: session.id)
            updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: true)
            if session.isRunning {
                do {
                    let response = try await client.session(id: session.id, afterSeq: logStore.lastSeq(for: session.id))
                    let refreshed = self.session(response.session, in: workspaceForSession(session))
                    upsert(refreshed)
                    if !refreshed.isRunning {
                        clearForegroundActivity(sessionID: session.id)
                    }
                    if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                        // recent_output 只作为诊断日志展示；对话内容以 app-server 结构化 history/event 为准。
                        logStore.append(recentOutput, sessionID: session.id, seq: response.lastSeq)
                    }
                } catch {
                    // 运行态快照读取失败时，用列表刷新重新同步 app-server 线程状态。
                    await refreshSessions(forProjectID: session.projectID)
                }
            } else {
                clearForegroundActivity(sessionID: session.id)
                await refreshSessions(forProjectID: session.projectID)
            }
            setStatusMessage("当前会话已刷新")
            setErrorMessage(nil)
        } catch {
            setErrorMessage(error.localizedDescription)
        }
    }

    private func refreshSessions(forProjectID projectID: String) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            setErrorMessage("工作区已失效，请重新打开")
            return
        }
        projectID = workspace.id
        if selectedProjectID != projectID {
            setSelectedProjectID(projectID)
        }
        isLoading = true
        defer { isLoading = false }
        var requestToken: Int?
        do {
            let client = try clientFactory()
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await client.sessionsPage(workspace: workspace, cursor: nil, limit: Self.initialSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            guard selectedProjectID == projectID else {
                return
            }
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            let pageSessions = sessions(page.sessions, in: workspace)
            replaceSessionsIfChanged(with: pageSessionsPreservingSelection(pageSessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            clearWorkspaceUnavailable(projectID)
            setStatusMessage("已加载 \(filteredSessions.count) 个会话")
            setErrorMessage(nil)
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            if selectedProjectID == projectID {
                await handleWorkspaceLoadFailure(workspace: workspace, error: error)
            }
        }
    }

    private func prepareSelectedSessionAfterRefresh(_ session: AgentSession, autoAttach: Bool) async {
        await loadHistoryIfNeeded(for: session)
        if session.isRunning {
            if autoAttach {
                connectWebSocket(session)
            }
        } else if connectedSessionID != nil {
            disconnectWebSocket()
        }
    }

    static func replacingSessions(_ current: [AgentSession], with fresh: [AgentSession], projectID: String?) -> [AgentSession] {
        SessionIndexStore.replacingSessions(current, with: fresh, projectID: projectID)
    }

    private func replaceSessionsIfChanged(with fresh: [AgentSession], projectID: String?) {
        let next = Self.replacingSessions(sessions, with: fresh.map(Self.normalizedSession), projectID: projectID)
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

    private func makeOptimisticSession(id: SessionID, projectID: String, prompt: String) -> AgentSession {
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
            return "新 Codex 会话"
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
        let sorted = Self.sortedSessions(sessions)
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
        for session in sessions where session.isRunning {
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
        let allSessions = sortedSessionsByProjectID[projectID] ?? []
        let isShowingAll = isShowingAllSessions(projectID: projectID)
        let visibleSessions = isShowingAll ? allSessions : previewSessionsByProjectID[projectID] ?? []

        return ProjectSessionListSnapshot(
            projectID: projectID,
            isExpanded: expandedProjectIDs.contains(projectID),
            isShowingAll: isShowingAll,
            visibleSessions: visibleSessions,
            allSessionCount: allSessions.count,
            hiddenCount: hiddenSessionCountByProjectID[projectID] ?? 0,
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

    private func pruneSessionScopedState(validSessionIDs: Set<SessionID>) {
        // 会话分页只保留当前已知列表和被选中保留的 session；旧 session 的 cursor/token/activity
        // 继续留在字典里没有业务价值，长时间浏览大量历史时还会慢慢堆内存。
        historyPreviousCursorBySessionID = historyPreviousCursorBySessionID.filter { validSessionIDs.contains($0.key) }
        historyHasMoreBeforeBySessionID = historyHasMoreBeforeBySessionID.filter { validSessionIDs.contains($0.key) }
        historyPageRequestTokenBySessionID = historyPageRequestTokenBySessionID.filter { validSessionIDs.contains($0.key) }
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
    }

    private static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        SessionIndexStore.sortedSessions(items)
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

    private func connectWebSocket(_ session: AgentSession, isReconnectAttempt: Bool = false) {
        guard session.isRunning else {
            return
        }
        if !isReconnectAttempt {
            cancelWebSocketReconnect(resetAttempts: true)
        }
        if connectedSessionID == session.id, case .connected = webSocketStatus {
            return
        }
        disconnectWebSocket(cancelReconnect: !isReconnectAttempt)

        let socket = webSocketFactory()
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
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
            Task {
                let shouldFlushImmediately = await terminalStreamStore.append(event, sessionID: session.id)
                if shouldFlushImmediately {
                    await self?.flushRuntimeEvents(sessionID: session.id)
                } else {
                    await MainActor.run {
                        self?.scheduleRuntimeEventFlush(sessionID: session.id)
                    }
                }
            }
        }
        socket.onSendAccepted = { [weak self] clientMessageID in
            Task { @MainActor in
                guard let clientMessageID else {
                    return
                }
                self?.conversationStore.compactTurnPayloadAfterSendAccepted(clientMessageID: clientMessageID, sessionID: session.id)
            }
        }
        socket.onSendFailure = { [weak self] clientMessageID, message in
            Task { @MainActor in
                if let clientMessageID {
                    self?.conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                }
                self?.clearForegroundActivity(sessionID: session.id)
                self?.setErrorMessage("发送失败：\(message)")
            }
        }
        webSocket = socket
        connectedSessionID = session.id
        conversationStore.resetLiveTranscript(sessionID: session.id)
        runtimeEventFlushTasks[session.id]?.cancel()
        runtimeEventFlushTasks[session.id] = nil
        Task { [terminalStreamStore] in
            await terminalStreamStore.removeAll(sessionID: session.id)
        }
        socket.connect(sessionID: session.id)
    }

    private func replayWatermark(for sessionID: SessionID) -> EventSequence? {
        // WS/REST 的 last_seen_seq 取三处最大值：结构化事件、对话投影和日志，
        // 避免某一侧 store 清理或重置后造成事件重放/漏拉。
        [
            lastSeenEventSeqBySessionID[sessionID],
            conversationStore.lastSeenSeq(for: sessionID),
            logStore.lastSeq(for: sessionID)
        ]
        .compactMap { $0 }
        .max()
    }

    private func readyWebSocket(for session: AgentSession) -> (any SessionWebSocketClient)? {
        let shouldReconnect: Bool
        if case .failed = webSocketStatus {
            shouldReconnect = true
        } else {
            shouldReconnect = false
        }
        if connectedSessionID != session.id || webSocket == nil || shouldReconnect {
            connectWebSocket(session)
        }
        guard let webSocket, connectedSessionID == session.id else {
            setErrorMessage("WebSocket 正在重新接入，请稍后再发送")
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
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID)
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
            clearForegroundActivity(sessionID: sessionID)
            if canReconnect {
                scheduleWebSocketReconnect(sessionID: sessionID, reason: message)
            } else {
                setWebSocketStatus(.failed(message))
                setErrorMessage(message)
            }
        case .disconnected:
            let canReconnect = shouldAutoReconnectWebSocket(sessionID: sessionID)
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
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
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        socket?.disconnect()
        for task in runtimeEventFlushTasks.values {
            task.cancel()
        }
        runtimeEventFlushTasks.removeAll()
        setWebSocketStatus(.disconnected)
    }

    private func shouldAutoReconnectWebSocket(sessionID: SessionID) -> Bool {
        guard connectedSessionID == sessionID,
              selectedSessionID == sessionID,
              sessionsByID[sessionID]?.isRunning == true,
              appStore.isConfigured else {
            return false
        }
        return true
    }

    private func scheduleWebSocketReconnect(sessionID: SessionID, reason: String) {
        guard selectedSessionID == sessionID,
              let session = sessionsByID[sessionID],
              session.isRunning else {
            setWebSocketStatus(.failed(reason))
            setErrorMessage(reason)
            return
        }

        let attempt = webSocketReconnectAttemptBySessionID[sessionID, default: 0] + 1
        guard attempt <= Self.webSocketReconnectMaxAttempts else {
            let message = "WebSocket 重连失败：\(reason)"
            webSocketReconnectAttemptBySessionID.removeValue(forKey: sessionID)
            setWebSocketStatus(.failed(message))
            setErrorMessage(message)
            return
        }

        webSocketReconnectTask?.cancel()
        webSocketReconnectAttemptBySessionID[sessionID] = attempt
        let delay = webSocketReconnectDelayNanoseconds(attempt)
        setWebSocketStatus(.connecting)
        setErrorMessage("WebSocket 断开，正在自动重连：\(reason)")
        setStatusMessage("WebSocket 第 \(attempt)/\(Self.webSocketReconnectMaxAttempts) 次重连")

        // 重连任务只服务当前选中的 running session；切项目/停止/返回列表都会取消它。
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
              let latestSession = sessionsByID[sessionID],
              latestSession.isRunning else {
            return
        }
        let refreshedSession = await refreshSessionSnapshotBeforeReconnect(sessionID: sessionID) ?? latestSession
        guard selectedSessionID == sessionID,
              refreshedSession.isRunning else {
            return
        }
        connectWebSocket(refreshedSession, isReconnectAttempt: true)
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
        let output = await eventReducer.reduce(
            event,
            fallbackSessionID: sessionID,
            outputIdleClearDelay: foregroundOutputIdleClearDelay
        )
        applyEventReducerOutput(output)
    }

    private func applyEventReducerOutput(_ output: EventReducerOutput) {
        for session in output.upsertSessions {
            upsert(session)
        }
        for (id, status) in output.statusUpdates {
            updateSession(id) { item in
                item.status = status
            }
            contextStore.updateStatus(sessionID: id, status: status)
        }
        for (id, approval) in output.pendingApprovalUpdates {
            updateSession(id) { item in
                item.pendingApproval = approval
            }
        }
        for (context, fallbackSessionID) in output.contextUpdates {
            contextStore.upsert(context, fallbackSessionID: fallbackSessionID)
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

    private func applyMessageMutation(_ mutation: EventReducerMessageMutation) {
        switch mutation {
        case .assistantDelta(let delta, let metadata, let fallbackSessionID):
            conversationStore.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: fallbackSessionID)
        case .completed(let message, let metadata, let fallbackSessionID):
            conversationStore.completeMessage(message, metadata: metadata, fallbackSessionID: fallbackSessionID)
        case .system(let text, let sessionID, let kind, let metadata):
            conversationStore.appendSystem(text, sessionID: sessionID, kind: kind, metadata: metadata)
        case .resolveLatestPendingApproval(let sessionID):
            conversationStore.resolveLatestPendingApproval(sessionID: sessionID)
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
             .turnStarted(let metadata),
             .assistantDelta(_, let metadata),
             .messageCompleted(_, let metadata),
             .processItemCompleted(_, _, let metadata),
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .turnCompleted(let metadata),
             .warning(_, let metadata):
            return metadata
        case .error, .unknown:
            return nil
        }
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
    }

    private func reloadRecentWorkspaces() {
        setRecentWorkspacesIfChanged(recentWorkspaceStore.load(endpoint: appStore.endpoint))
    }

    private func rememberWorkspace(_ workspace: AgentWorkspace) {
        let next = recentWorkspaceStore.upsert(workspace, endpoint: appStore.endpoint)
        setRecentWorkspacesIfChanged(next)
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
                return .unavailable("“\(workspace.name)”已不在 Mac 允许范围或已被删除，可重试或从当前设备移除")
            }
            return .indeterminate
        } catch {
            return .indeterminate
        }
    }

    private func handleWorkspaceLoadFailure(workspace: AgentWorkspace, error: Error) async {
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
        rebuildProjectSessionListSnapshots()
    }

    private func insertShowingAllSessionProjectID(_ value: String) {
        guard !showingAllSessionProjectIDs.contains(value) else {
            return
        }
        showingAllSessionProjectIDs.insert(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
    }

    private func removeShowingAllSessionProjectID(_ value: String) {
        guard showingAllSessionProjectIDs.contains(value) else {
            return
        }
        showingAllSessionProjectIDs.remove(value)
        rebuildProjectSessionListSnapshot(forProjectID: value)
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
        historyPreviousCursorBySessionID = [:]
        historyHasMoreBeforeBySessionID = [:]
        historyPageRequestTokenBySessionID = [:]
        initialHistoryLoadingSessionIDs = []
        loadingEarlierHistorySessionIDs = []
        lastSeenEventSeqBySessionID = [:]
        foregroundActivityBySessionID = [:]
        runtimeEventFlushTasks.values.forEach { $0.cancel() }
        runtimeEventFlushTasks = [:]
        foregroundActivityClearTasks.values.forEach { $0.cancel() }
        foregroundActivityClearTasks = [:]
        rebuildProjectSessionListSnapshots()
    }

    private func upsert(_ session: AgentSession) {
        let session = Self.normalizedSession(alignSessionToKnownWorkspace(session))
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

    private func updateSession(_ id: String, mutate: (inout AgentSession) -> Void) {
        guard let index = sessionIndexByID[id] else {
            return
        }
        var next = sessions
        let oldValue = next[index]
        mutate(&next[index])
        next[index] = Self.normalizedSession(next[index])
        guard next[index] != oldValue else {
            return
        }
        sessions = next
    }

    private static func normalizedSession(_ session: AgentSession) -> AgentSession {
        guard session.status != "waiting_for_approval", session.pendingApproval != nil else {
            return session
        }
        var next = session
        next.pendingApproval = nil
        return next
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
