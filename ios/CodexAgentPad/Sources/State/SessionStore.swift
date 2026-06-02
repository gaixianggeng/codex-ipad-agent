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
    private let clientFactory: () throws -> any SessionStoreAPIClient
    private let webSocketFactory: () -> any SessionWebSocketClient
    private let webSocketReconnectDelayNanoseconds: (Int) -> UInt64
    private var webSocket: (any SessionWebSocketClient)?
    private var connectedSessionID: String?
    private var webSocketReconnectTask: Task<Void, Never>?
    private var webSocketReconnectAttemptBySessionID: [SessionID: Int] = [:]
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
    private let historyPageLimit = 120
    private static let webSocketReconnectMaxAttempts = 5
    static let sessionPreviewLimit = 3
    private static let initialSessionPageLimit = 80
    private static let expandedSessionPageLimit = 120

    init(
        appStore: AppStore,
        conversationStore: ConversationStore,
        logStore: LogStore,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil
    ) {
        self.appStore = appStore
        self.conversationStore = conversationStore
        self.logStore = logStore
        self.clientFactory = clientFactory ?? { try appStore.client() }
        self.webSocketFactory = webSocketFactory ?? { AgentWebSocketClient() }
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
        // 冷启动时 VPN / Tailscale 隧道往往还没就绪，首个请求容易失败；而 scenePhase 的
        // .active 回调在冷启动不会触发（没有 background→active 的切换），单次失败后就只能靠
        // 用户切后台再回前台才会重新加载。这里做有限次退避重试，让首屏自己恢复。
        for attempt in 0..<6 {
            await refreshAll(autoAttach: true)
            // 加载到项目就成功；没报错却没有项目说明后端确实为空，不必继续重试。
            if !projects.isEmpty || errorMessage == nil {
                return
            }
            if Task.isCancelled {
                return
            }
            let backoffUnits = UInt64(min(attempt + 1, 4))
            try? await Task.sleep(nanoseconds: backoffUnits * 500_000_000)
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

    func selectSession(_ session: AgentSession) async {
        setSelectedProjectID(session.projectID)
        setSelectedSessionID(session.id)
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

    func resumeFromForeground() async {
        guard appStore.isConfigured else {
            return
        }
        await refreshAll(autoAttach: true)
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

            upsert(response.session)
            setSelectedProjectID(response.session.projectID)
            setSelectedSessionID(response.session.id)
            insertExpandedProjectID(response.session.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”。
            if response.session.source == "codex" {
                await loadHistoryIfNeeded(for: response.session)
            }
            if !prompt.isEmpty {
                conversationStore.appendLocalUser(prompt, sessionID: response.session.id, clientMessageID: clientMessageID, sendStatus: .sent)
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
                        // 运行中的 Codex 可能还没把最新 turn 写入 rollout，补消费 PTY 尾部用于实时 UI。
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
        let scopedFresh: [AgentSession]
        if let projectID {
            scopedFresh = fresh.filter { $0.projectID == projectID }
        } else {
            scopedFresh = fresh
        }
        var freshIDs: Set<SessionID> = []
        freshIDs.reserveCapacity(scopedFresh.count)
        for session in scopedFresh {
            freshIDs.insert(session.id)
        }
        let kept = current.filter { session in
            if freshIDs.contains(session.id) {
                return false
            }
            guard let projectID else {
                return false
            }
            return session.projectID != projectID
        }
        return scopedFresh + kept
    }

    private func replaceSessionsIfChanged(with fresh: [AgentSession], projectID: String?) {
        let next = Self.replacingSessions(sessions, with: fresh, projectID: projectID)
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
        let foregroundActivities = foregroundActivityBySessionID.filter { validSessionIDs.contains($0.key) }
        if foregroundActivities != foregroundActivityBySessionID {
            foregroundActivityBySessionID = foregroundActivities
        }
    }

    private static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        items.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if left == right {
                // 后端 session cursor 使用 updated_at + id 做 keyset 分页；前端合并分页后也用
                // 同一个全序，避免相同时间戳的历史会话在本地重新排序导致列表跳动。
                return lhs.id > rhs.id
            }
            return left > right
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
            let url = try client.websocketURL(sessionID: session.id, afterSeq: logStore.lastSeq(for: session.id))
            let socket = webSocketFactory()
            socket.onStatus = { [weak self] status in
                Task { @MainActor in
                    self?.applyWebSocketStatus(status, sessionID: session.id)
                }
            }
            socket.onEvent = { [weak self] event in
                Task { @MainActor in
                    self?.handle(event, sessionID: session.id)
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
            socket.connect(url: url, token: appStore.token)
        } catch {
            setWebSocketStatus(.failed(error.localizedDescription))
            setErrorMessage(error.localizedDescription)
        }
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
                guard let self,
                      self.selectedSessionID == sessionID,
                      self.webSocketReconnectAttemptBySessionID[sessionID] == attempt,
                      let latestSession = self.sessionsByID[sessionID],
                      latestSession.isRunning else {
                    return
                }
                self.webSocketReconnectTask = nil
                self.connectWebSocket(latestSession, isReconnectAttempt: true)
            }
        }
    }

    private func cancelWebSocketReconnect(resetAttempts: Bool) {
        webSocketReconnectTask?.cancel()
        webSocketReconnectTask = nil
        if resetAttempts {
            webSocketReconnectAttemptBySessionID.removeAll()
        }
    }

    private func handle(_ event: AgentEvent, sessionID: String) {
        switch event {
        case .session(let session):
            upsert(session)
        case .sessionRow(let row, _):
            upsert(AgentSession(row: row))
        case .sessionStatus(let status, let metadata):
            guard let id = metadata.sessionID, let status else {
                return
            }
            updateSession(id) { item in
                item.status = status
            }
            if status != "running" {
                clearForegroundActivity(sessionID: id)
            }
        case .turnStarted(let metadata):
            guard let id = metadata.sessionID else {
                return
            }
            updateSession(id) { item in
                item.status = "running"
            }
            setForegroundActivity(.waitingForAssistant, sessionID: id)
        case .assistantDelta(let delta, let metadata):
            setForegroundActivity(
                .receivingAssistant,
                sessionID: metadata.sessionID ?? sessionID,
                autoClearAfter: foregroundOutputIdleClearDelay
            )
            conversationStore.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: sessionID)
        case .messageCompleted(let message, let metadata):
            conversationStore.completeMessage(message, metadata: metadata, fallbackSessionID: sessionID)
            if message.role == .assistant {
                clearForegroundActivity(sessionID: metadata.sessionID ?? message.sessionID)
            }
        case .logDelta(let delta, let metadata):
            logStore.append(delta.text, sessionID: metadata.sessionID ?? sessionID, seq: metadata.seq)
        case .diffUpdated(let change, _):
            let summary = "文件变更：\(change.path) \(change.status)"
            conversationStore.appendSystem(summary, sessionID: sessionID)
        case .approvalRequest(let request, _):
            conversationStore.appendSystem("等待审批：\(request.title)", sessionID: sessionID)
        case .turnCompleted(let metadata):
            conversationStore.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: sessionID)
            clearForegroundActivity(sessionID: metadata.sessionID ?? sessionID)
        case .warning(let payload, _):
            logStore.append("\n[agentd] warning: \(payload.message)\n", sessionID: sessionID)
        case .output(let data, let metadata):
            let id = metadata.sessionID ?? sessionID
            // PTY 输出代表当前会话有前台活动，但不等同于后端 session 生命周期。
            setForegroundActivity(
                .receivingAssistant,
                sessionID: id,
                autoClearAfter: foregroundOutputIdleClearDelay
            )
            // WebSocket 输出在 Store 层分发：日志和对话解析互不依赖。
            logStore.append(data, sessionID: id, seq: metadata.seq)
            conversationStore.ingestTerminalOutput(data, sessionID: id)
        case .exit(let result):
            updateSession(sessionID) { item in
                item.status = "closed"
            }
            clearForegroundActivity(sessionID: sessionID)
            let reason = result.reason ?? "code=\(result.code ?? 0)"
            conversationStore.appendSystem("Codex 会话已结束：\(reason)", sessionID: sessionID)
            disconnectWebSocket()
        case .error(let message):
            clearForegroundActivity(sessionID: sessionID)
            setErrorMessage(message)
            logStore.append("\n[agentd] \(message)\n", sessionID: sessionID)
        case .pong:
            setStatusMessage("WebSocket 心跳正常")
        case .unknown(let type):
            logStore.append("\n[agentd] 未知消息类型：\(type)\n", sessionID: sessionID)
        }
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

    private func upsert(_ session: AgentSession) {
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
