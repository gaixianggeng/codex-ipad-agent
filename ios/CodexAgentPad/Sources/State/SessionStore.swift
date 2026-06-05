import Foundation

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage
    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func stopSession(id: String) async throws
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage
    func websocketURL(sessionID: String) throws -> URL
}

extension AgentAPIClient: SessionStoreAPIClient {}

extension SessionStoreAPIClient {
    func session(id: String) async throws -> SessionResponse {
        try await session(id: id, afterSeq: nil)
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        HistoryMessagesPage(messages: try await messages(sessionID: sessionID, before: before, limit: limit))
    }

    func websocketURL(sessionID: String, afterSeq: EventSequence?) throws -> URL {
        var url = try websocketURL(sessionID: sessionID)
        guard let afterSeq, afterSeq > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "after_seq", value: String(afterSeq)))
        components.queryItems = items
        url = components.url ?? url
        return url
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
            rebuildProjectSessionListSnapshots()
        }
    }
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
    @Published private var foregroundActivityBySessionID: [SessionID: SessionForegroundActivity] = [:]

    private let appStore: AppStore
    private let conversationStore: ConversationStore
    private let logStore: LogStore
    private let contextStore: SessionContextStore
    private let eventReducer: EventReducer
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
    @Published private var loadingEarlierHistorySessionIDs: Set<SessionID> = []

    private let fixedCols = 120
    private let fixedRows = 32
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
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil
    ) {
        self.appStore = appStore
        self.conversationStore = conversationStore
        self.logStore = logStore
        self.contextStore = contextStore ?? SessionContextStore()
        self.eventReducer = EventReducer()
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
        return projectsByID[selectedProjectID]
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
            if selectedSession.isCodexHistory {
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
        do {
            let client = try clientFactory()
            let previousProjectID = selectedProjectID
            let previousSessionID = selectedSessionID
            let fetchedProjects = try await client.projects()
            setProjectsIfChanged(fetchedProjects)
            let validProjectIDs = Self.projectIDs(projects)
            setExpandedProjectIDs(expandedProjectIDs.intersection(validProjectIDs))
            setShowingAllSessionProjectIDs(showingAllSessionProjectIDs.intersection(validProjectIDs))
            sessionPageCursorByProjectID = sessionPageCursorByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionHasMoreByProjectID = sessionHasMoreByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionPageRequestTokenByProjectID = sessionPageRequestTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            sessionPageLoadingTokenByProjectID = sessionPageLoadingTokenByProjectID.filter { validProjectIDs.contains($0.key) }
            rebuildProjectSessionListSnapshots()
            let projectID = previousProjectID.flatMap { id in
                projectsByID[id] == nil ? nil : id
            } ?? projects.first?.id
            setSelectedProjectID(projectID)
            guard let projectID else {
                replaceSessionsIfChanged(with: [], projectID: nil)
                setSelectedSessionID(nil)
                disconnectWebSocket()
                setStatusMessage("未发现可用项目")
                setErrorMessage(nil)
                return
            }
            if previousProjectID == nil && expandedProjectIDs.isEmpty {
                insertExpandedProjectID(projectID)
            }

            requestProjectID = projectID
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await client.sessionsPage(projectID: projectID, cursor: nil, limit: Self.initialSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            replaceSessionsIfChanged(with: pageSessionsPreservingSelection(page.sessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)

            if let previousSessionID, let session = sessionsByID[previousSessionID] {
                // 刷新或重新保存设置不能抢走用户已经点选的历史会话。
                setSelectedProjectID(session.projectID)
                setSelectedSessionID(session.id)
                revealProjectInSidebar(session.projectID)
                await prepareSelectedSessionAfterRefresh(session, autoAttach: autoAttach)
            } else {
                setSelectedSessionID(nil)
            }

            setStatusMessage("已加载 \(projects.count) 个项目，\(filteredSessions.count) 个会话")
            setErrorMessage(nil)
        } catch {
            if let requestProjectID, let requestToken, !isCurrentSessionPageRequest(projectID: requestProjectID, token: requestToken) {
                return
            }
            setErrorMessage(error.localizedDescription)
        }
    }

    func selectProject(_ project: AgentProject) async {
        setSelectedProjectID(project.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(project.id)
        setErrorMessage(nil)
        disconnectWebSocket()
        await refreshSessions(forProjectID: project.id)
    }

    func toggleProjectExpansion(_ project: AgentProject) async {
        if expandedProjectIDs.contains(project.id) {
            removeExpandedProjectID(project.id)
            removeShowingAllSessionProjectID(project.id)
            return
        }

        insertExpandedProjectID(project.id)
        if selectedProjectID != project.id {
            setSelectedProjectID(project.id)
            setSelectedSessionID(nil)
            setErrorMessage(nil)
            disconnectWebSocket()
        }
        await refreshSessions(forProjectID: project.id)
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
            let page = try await client.sessionsPage(projectID: projectID, cursor: cursor, limit: Self.expandedSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            mergeSessionPage(page.sessions)
            updateSessionPageState(projectID: projectID, page: page)
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

    func loadEarlierHistoryForSelectedSession() async {
        guard let session = selectedSession,
              session.source == "codex",
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
        setSelectedProjectID(session.projectID)
        setSelectedSessionID(session.id)
        revealProjectInSidebar(session.projectID)
        setErrorMessage(nil)
        conversationStore.retainSessionCache(sessionID: session.id)
        logStore.retainSessionCache(sessionID: session.id)

        if session.source == "codex" {
            await loadHistoryIfNeeded(for: session)
        }

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
        setSelectedProjectID(project.id)
        setSelectedSessionID(nil)
        insertExpandedProjectID(project.id)
        setErrorMessage(nil)
        disconnectWebSocket()
        await createSession(projectID: project.id, prompt: "", resume: nil)
    }

    @discardableResult
    func sendPrompt(_ text: String) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return false
        }

        if let session = selectedSession, session.isRunning {
            guard let socket = readyWebSocket(for: session) else {
                return false
            }
            let clientMessageID = UUID().uuidString
            conversationStore.appendLocalUser(prompt, sessionID: session.id, clientMessageID: clientMessageID, sendStatus: .sending)
            setForegroundActivity(.waitingForAssistant, sessionID: session.id)
            guard socket.sendInput(prompt + "\r", clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("发送失败：WebSocket 未连接")
                return false
            }
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
            return true
        }

        let resume = selectedSession?.source == "codex" ? selectedSession : nil
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            setErrorMessage("请先选择项目")
            return false
        }
        return await createSession(projectID: projectID, prompt: prompt, resume: resume, clientMessageID: UUID().uuidString)
    }

    func sendEnter() {
        guard let session = selectedSession, session.isRunning, let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendEnter() {
            setErrorMessage("发送 Enter 失败：WebSocket 未连接")
        }
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
            guard socket.sendInput(prompt + "\r", clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                clearForegroundActivity(sessionID: session.id)
                setErrorMessage("重试失败：WebSocket 未连接")
                return false
            }
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
            return true
        }

        // 会话已经结束或失败时，沿用普通发送路径重新创建/恢复 Codex thread。
        return await sendPrompt(prompt)
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
        isLoading = true
        defer { isLoading = false }
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
            conversationStore.appendLocalUser(prompt, sessionID: optimisticSessionID, clientMessageID: clientMessageID, sendStatus: .sending)
            setForegroundActivity(.waitingForAssistant, sessionID: optimisticSessionID)
        }

        do {
            let client = try clientFactory()
            let response = try await client.createSession(CreateSessionRequest(
                projectID: projectID,
                prompt: prompt,
                resumeID: resume?.resumeID ?? "",
                title: resume?.title ?? "",
                cols: fixedCols,
                rows: fixedRows,
                clientMessageID: clientMessageID
            ))

            if let optimisticSessionID,
               let clientMessageID,
               optimisticSessionID != response.session.id {
                // 新建会话会从 local:<project>:<client_message_id> 切换到后端 session_id，
                // 这里迁移前台活动和本地气泡，保持列表/对话 store 解耦。
                conversationStore.moveLocalEcho(clientMessageID: clientMessageID, from: optimisticSessionID, to: response.session.id)
                migrateForegroundActivity(from: optimisticSessionID, to: response.session.id)
                if resume == nil {
                    removeSession(optimisticSessionID)
                }
            }
            upsert(response.session)
            setSelectedProjectID(response.session.projectID)
            setSelectedSessionID(response.session.id)
            insertExpandedProjectID(response.session.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”。
            if response.session.source == "codex" {
                await loadHistoryIfNeeded(for: response.session)
            }
            if !prompt.isEmpty {
                if let clientMessageID {
                    conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: response.session.id, status: .sent)
                } else {
                    conversationStore.appendLocalUser(prompt, sessionID: response.session.id, clientMessageID: nil, sendStatus: .sent)
                }
                setForegroundActivity(.waitingForAssistant, sessionID: response.session.id)
            } else {
                conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: response.session.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: response.session.id)
                if firstMessage.role == .assistant {
                    clearForegroundActivity(sessionID: response.session.id)
                }
            }
            if resume != nil {
                conversationStore.appendSystem("已继续这个 Codex 历史会话。", sessionID: response.session.id)
            }
            connectWebSocket(response.session)
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
        guard session.source == "codex", !conversationStore.hasLoadedHistory(sessionID: session.id) else {
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
            if session.source == "codex" {
                // 手动刷新必须绕过 hasLoadedHistory 缓存，Mac/iPad 混合使用时 rollout 可能已经更新。
                let requestToken = beginHistoryPageRequest(sessionID: session.id)
                let page = try await client.messagesPage(sessionID: session.id, before: nil, limit: historyPageLimit)
                guard isCurrentHistoryPageRequest(sessionID: session.id, token: requestToken) else {
                    return
                }
                conversationStore.setHistory(page.messages, sessionID: session.id)
                updateHistoryPageState(sessionID: session.id, page: page, preserveExistingCursorOnEmptyPage: true)
            }
            if session.isRunning {
                do {
                    let response = try await client.session(id: session.id, afterSeq: logStore.lastSeq(for: session.id))
                    upsert(response.session)
                    if !response.session.isRunning {
                        clearForegroundActivity(sessionID: session.id)
                    }
                    if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                        // PTY 尾部先补日志，同时作为结构化消息未落地时的对话兜底。
                        // 后续 history/message_completed 到达时，ConversationStore 会用稳定消息替换这条临时气泡。
                        logStore.append(recentOutput, sessionID: session.id, seq: response.lastSeq)
                        conversationStore.ingestTerminalOutput(recentOutput, sessionID: session.id)
                    }
                } catch {
                    // 运行态详情只存在于 agentd 内存。重启后可能 404，这时列表刷新会把它拉回历史态。
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
        isLoading = true
        defer { isLoading = false }
        var requestToken: Int?
        do {
            let client = try clientFactory()
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer { finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0) }
            let page = try await client.sessionsPage(projectID: projectID, cursor: nil, limit: Self.initialSessionPageLimit)
            guard isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            guard selectedProjectID == projectID else {
                return
            }
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            replaceSessionsIfChanged(with: pageSessionsPreservingSelection(page.sessions, projectID: projectID), projectID: projectID)
            updateSessionPageState(projectID: projectID, page: page)
            setStatusMessage("已加载 \(filteredSessions.count) 个会话")
            setErrorMessage(nil)
        } catch {
            if let requestToken, !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            if selectedProjectID == projectID {
                setErrorMessage(error.localizedDescription)
            }
        }
    }

    private func prepareSelectedSessionAfterRefresh(_ session: AgentSession, autoAttach: Bool) async {
        if session.source == "codex" {
            await loadHistoryIfNeeded(for: session)
        }
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
        let project = projectsByID[projectID]
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
        naturalGrouped.reserveCapacity(projects.count)
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
        projectIDs.reserveCapacity(projects.count + sortedSessionsByProjectID.count)
        for project in projects {
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

        do {
            let client = try clientFactory()
            let url = try client.websocketURL(sessionID: session.id, afterSeq: replayWatermark(for: session.id))
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
            socket.connect(url: url, token: appStore.token)
        } catch {
            setWebSocketStatus(.failed(error.localizedDescription))
            setErrorMessage(error.localizedDescription)
        }
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
            if connectedSessionID == sessionID {
                _ = webSocket?.sendResize(cols: fixedCols, rows: fixedRows)
            }
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
            upsert(response.session)
            if let recentOutput = response.recentOutput, !recentOutput.isEmpty {
                // 重连前先补一次 snapshot/recent_output；Codex runtime 再补 history，
                // 这样 WS 断线期间的结构化消息不会只出现在日志里。
                logStore.append(recentOutput, sessionID: sessionID, seq: response.lastSeq)
                conversationStore.ingestTerminalOutput(recentOutput, sessionID: sessionID)
            }
            if response.session.source == "codex" {
                // 重连前先刷新一次消息页，用 cursor/id/revision 合并可能错过的结构化消息。
                await loadHistory(for: response.session)
            }
            return response.session
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
        case .system(let text, let sessionID, let kind):
            conversationStore.appendSystem(text, sessionID: sessionID, kind: kind)
        case .resolveLatestPendingApproval(let sessionID):
            conversationStore.resolveLatestPendingApproval(sessionID: sessionID)
        case .markCurrentAssistantCompleted(let metadata, let fallbackSessionID):
            conversationStore.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: fallbackSessionID)
        case .ingestTerminalOutput(let data, let sessionID):
            conversationStore.ingestTerminalOutput(data, sessionID: sessionID)
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
             .logDelta(_, let metadata),
             .diffUpdated(_, let metadata),
             .approvalRequest(_, let metadata),
             .approvalResolved(let metadata),
             .turnCompleted(let metadata),
             .warning(_, let metadata),
             .output(_, let metadata):
            return metadata
        case .exit, .error, .pong, .unknown:
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
        let session = Self.normalizedSession(session)
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
        // 流式输出时每个 PTY 分片都会调到这里。@Published 字典即使赋同值也会触发
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
        // PTY 没有明确的“回复结束”事件，用空闲超时兜底，避免输出结束后仍一直显示正在回复。
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
