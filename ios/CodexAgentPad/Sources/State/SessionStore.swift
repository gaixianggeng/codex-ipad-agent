import Foundation

protocol SessionStoreAPIClient {
    func projects() async throws -> [AgentProject]
    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession]
    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse
    func stopSession(id: String) async throws
    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage]
    func websocketURL(sessionID: String) throws -> URL
}

extension AgentAPIClient: SessionStoreAPIClient {}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var projects: [AgentProject] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published private(set) var expandedProjectIDs: Set<String> = []
    @Published private(set) var showingAllSessionProjectIDs: Set<String> = []
    @Published var isLoading = false
    @Published var webSocketStatus: WebSocketStatus = .disconnected
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let appStore: AppStore
    private let conversationStore: ConversationStore
    private let logStore: LogStore
    private let clientFactory: () throws -> any SessionStoreAPIClient
    private var webSocket: AgentWebSocketClient?
    private var connectedSessionID: String?

    private let fixedCols = 120
    private let fixedRows = 32
    static let sessionPreviewLimit = 3

    init(
        appStore: AppStore,
        conversationStore: ConversationStore,
        logStore: LogStore,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil
    ) {
        self.appStore = appStore
        self.conversationStore = conversationStore
        self.logStore = logStore
        self.clientFactory = clientFactory ?? { try appStore.client() }
    }

    var selectedProject: AgentProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: AgentSession? {
        sessions.first { $0.id == selectedSessionID }
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
        let items: [AgentSession]
        guard let selectedProjectID else {
            items = sessions
            return sortedSessions(items)
        }
        items = sessions.filter { $0.projectID == selectedProjectID }
        return sortedSessions(items)
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    func isShowingAllSessions(projectID: String) -> Bool {
        showingAllSessionProjectIDs.contains(projectID)
    }

    func sessions(forProjectID projectID: String) -> [AgentSession] {
        sortedSessions(sessions.filter { $0.projectID == projectID })
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        let projectSessions = sessions(forProjectID: projectID)
        guard !isShowingAllSessions(projectID: projectID) else {
            return projectSessions
        }
        return Array(projectSessions.prefix(Self.sessionPreviewLimit))
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        max(0, sessions(forProjectID: projectID).count - Self.sessionPreviewLimit)
    }

    func bootstrap() async {
        guard appStore.isConfigured else {
            return
        }
        await refreshAll(autoAttach: true)
    }

    func refreshAll(autoAttach: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try clientFactory()
            let previousProjectID = selectedProjectID
            let previousSessionID = selectedSessionID
            projects = try await client.projects()
            let validProjectIDs = Set(projects.map(\.id))
            expandedProjectIDs.formIntersection(validProjectIDs)
            showingAllSessionProjectIDs.formIntersection(validProjectIDs)
            let projectID = previousProjectID.flatMap { id in
                projects.contains(where: { $0.id == id }) ? id : nil
            } ?? projects.first?.id
            selectedProjectID = projectID
            guard let projectID else {
                sessions = []
                selectedSessionID = nil
                disconnectWebSocket()
                statusMessage = "未发现可用项目"
                errorMessage = nil
                return
            }
            if previousProjectID == nil && expandedProjectIDs.isEmpty {
                expandedProjectIDs.insert(projectID)
            }

            let projectSessions = try await client.sessions(projectID: projectID, cursor: nil, limit: 300)
            sessions = Self.replacingSessions(sessions, with: projectSessions, projectID: projectID)

            if let previousSessionID, let session = sessions.first(where: { $0.id == previousSessionID }) {
                // 刷新或重新保存设置不能抢走用户已经点选的历史会话。
                selectedProjectID = session.projectID
                selectedSessionID = session.id
                await prepareSelectedSessionAfterRefresh(session, autoAttach: autoAttach)
            } else {
                selectedSessionID = nil
            }

            statusMessage = "已加载 \(projects.count) 个项目，\(filteredSessions.count) 个会话"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ project: AgentProject) async {
        selectedProjectID = project.id
        selectedSessionID = nil
        expandedProjectIDs.insert(project.id)
        errorMessage = nil
        disconnectWebSocket()
        await refreshSessions(forProjectID: project.id)
    }

    func toggleProjectExpansion(_ project: AgentProject) async {
        if expandedProjectIDs.contains(project.id) {
            expandedProjectIDs.remove(project.id)
            showingAllSessionProjectIDs.remove(project.id)
            return
        }

        expandedProjectIDs.insert(project.id)
        if selectedProjectID != project.id {
            selectedProjectID = project.id
            selectedSessionID = nil
            errorMessage = nil
            disconnectWebSocket()
        }
        await refreshSessions(forProjectID: project.id)
    }

    func toggleSessionListExpansion(projectID: String) {
        if showingAllSessionProjectIDs.contains(projectID) {
            showingAllSessionProjectIDs.remove(projectID)
        } else {
            showingAllSessionProjectIDs.insert(projectID)
        }
    }

    func refreshSelectedProjectSessions() async {
        guard let selectedProjectID else {
            return
        }
        await refreshSessions(forProjectID: selectedProjectID)
    }

    func returnToSessionList() {
        selectedSessionID = nil
        errorMessage = nil
        disconnectWebSocket()
    }

    func selectSession(_ session: AgentSession) async {
        selectedProjectID = session.projectID
        selectedSessionID = session.id
        errorMessage = nil

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
            errorMessage = "请先选择项目"
            return
        }
        await createSession(projectID: selectedProjectID, prompt: "", resume: nil)
    }

    func startNewSession(in project: AgentProject) async {
        selectedProjectID = project.id
        selectedSessionID = nil
        expandedProjectIDs.insert(project.id)
        errorMessage = nil
        disconnectWebSocket()
        await createSession(projectID: project.id, prompt: "", resume: nil)
    }

    func sendPrompt(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return
        }

        if let session = selectedSession, session.isRunning {
            guard let socket = readyWebSocket(for: session) else {
                return
            }
            let clientMessageID = UUID().uuidString
            conversationStore.appendLocalUser(prompt, sessionID: session.id, clientMessageID: clientMessageID, sendStatus: .sending)
            guard socket.sendInput(prompt + "\r", clientMessageID: clientMessageID) else {
                conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .failed)
                errorMessage = "发送失败：WebSocket 未连接"
                return
            }
            conversationStore.updateSendStatus(clientMessageID: clientMessageID, sessionID: session.id, status: .sent)
            return
        }

        let resume = selectedSession?.source == "codex" ? selectedSession : nil
        let projectID = resume?.projectID ?? selectedProjectID
        guard let projectID else {
            errorMessage = "请先选择项目"
            return
        }
        await createSession(projectID: projectID, prompt: prompt, resume: resume, clientMessageID: UUID().uuidString)
    }

    func sendEnter() {
        guard let session = selectedSession, session.isRunning, let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendEnter() {
            errorMessage = "发送 Enter 失败：WebSocket 未连接"
        }
    }

    func sendCtrlC() {
        guard let session = selectedSession, session.isRunning, let socket = readyWebSocket(for: session) else {
            return
        }
        if !socket.sendCtrlC() {
            errorMessage = "发送 Ctrl-C 失败：WebSocket 未连接"
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
            conversationStore.appendSystem("Codex 会话已停止。", sessionID: session.id)
            disconnectWebSocket()
            statusMessage = "已停止会话"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createSession(projectID: String, prompt: String, resume: AgentSession?, clientMessageID: ClientMessageID? = nil) async {
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
            selectedProjectID = response.session.projectID
            selectedSessionID = response.session.id
            expandedProjectIDs.insert(response.session.projectID)

            // 历史 resume 必须先补齐上下文，再追加本次用户输入，避免“发完历史没了”。
            if response.session.source == "codex" {
                await loadHistoryIfNeeded(for: response.session)
            }
            if !prompt.isEmpty {
                conversationStore.appendLocalUser(prompt, sessionID: response.session.id, clientMessageID: clientMessageID, sendStatus: .sent)
            } else {
                conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: response.session.id)
            }
            if let firstMessage = response.firstMessage {
                conversationStore.completeMessage(firstMessage, metadata: .empty, fallbackSessionID: response.session.id)
            }
            if resume != nil {
                conversationStore.appendSystem("已继续这个 Codex 历史会话。", sessionID: response.session.id)
            }
            connectWebSocket(response.session)
            statusMessage = "会话已启动"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistoryIfNeeded(for session: AgentSession) async {
        guard session.source == "codex", !conversationStore.hasLoadedHistory(sessionID: session.id) else {
            return
        }
        do {
            let client = try clientFactory()
            let messages = try await client.messages(sessionID: session.id, before: nil, limit: nil)
            conversationStore.setHistory(messages, sessionID: session.id)
        } catch {
            statusMessage = "历史消息读取失败：\(error.localizedDescription)"
        }
    }

    private func refreshSessions(forProjectID projectID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try clientFactory()
            let projectSessions = try await client.sessions(projectID: projectID, cursor: nil, limit: 300)
            guard selectedProjectID == projectID else {
                return
            }
            // 只替换当前项目的会话，避免一次项目点击误删其他项目已经加载好的列表。
            sessions = Self.replacingSessions(sessions, with: projectSessions, projectID: projectID)
            statusMessage = "已加载 \(filteredSessions.count) 个会话"
            errorMessage = nil
        } catch {
            if selectedProjectID == projectID {
                errorMessage = error.localizedDescription
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
        let freshIDs = Set(scopedFresh.map(\.id))
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

    private func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        items.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if left == right {
                return lhs.title < rhs.title
            }
            return left > right
        }
    }

    private func connectWebSocket(_ session: AgentSession) {
        guard session.isRunning else {
            return
        }
        if connectedSessionID == session.id, case .connected = webSocketStatus {
            return
        }
        disconnectWebSocket()

        do {
            let client = try clientFactory()
            let url = try client.websocketURL(sessionID: session.id)
            let socket = AgentWebSocketClient()
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
            webSocket = socket
            connectedSessionID = session.id
            conversationStore.resetLiveTranscript(sessionID: session.id)
            socket.connect(url: url, token: appStore.token)
            _ = socket.sendResize(cols: fixedCols, rows: fixedRows)
        } catch {
            webSocketStatus = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func readyWebSocket(for session: AgentSession) -> AgentWebSocketClient? {
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
            errorMessage = "WebSocket 正在重新接入，请稍后再发送"
            return nil
        }
        return webSocket
    }

    private func applyWebSocketStatus(_ status: WebSocketStatus, sessionID: String) {
        webSocketStatus = status
        switch status {
        case .connected:
            errorMessage = nil
        case .failed(let message):
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
            errorMessage = message
        case .disconnected:
            if connectedSessionID == sessionID {
                connectedSessionID = nil
                webSocket = nil
            }
        case .connecting:
            break
        }
    }

    private func disconnectWebSocket() {
        webSocket?.disconnect()
        webSocket = nil
        connectedSessionID = nil
        webSocketStatus = .disconnected
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
        case .turnStarted(let metadata):
            guard let id = metadata.sessionID else {
                return
            }
            updateSession(id) { item in
                item.status = "running"
            }
        case .assistantDelta(let delta, let metadata):
            conversationStore.applyAssistantDelta(delta, metadata: metadata, fallbackSessionID: sessionID)
        case .messageCompleted(let message, let metadata):
            conversationStore.completeMessage(message, metadata: metadata, fallbackSessionID: sessionID)
        case .logDelta(let delta, _):
            logStore.append(delta.text, sessionID: sessionID)
        case .diffUpdated(let change, _):
            let summary = "文件变更：\(change.path) \(change.status)"
            conversationStore.appendSystem(summary, sessionID: sessionID)
        case .approvalRequest(let request, _):
            conversationStore.appendSystem("等待审批：\(request.title)", sessionID: sessionID)
        case .turnCompleted(let metadata):
            conversationStore.markCurrentAssistantCompleted(metadata: metadata, fallbackSessionID: sessionID)
        case .warning(let payload, _):
            logStore.append("\n[agentd] warning: \(payload.message)\n", sessionID: sessionID)
        case .output(let data):
            // WebSocket 输出在 Store 层分发：日志和对话解析互不依赖。
            logStore.append(data, sessionID: sessionID)
            conversationStore.ingestTerminalOutput(data, sessionID: sessionID)
        case .exit(let result):
            updateSession(sessionID) { item in
                item.status = "closed"
            }
            let reason = result.reason ?? "code=\(result.code ?? 0)"
            conversationStore.appendSystem("Codex 会话已结束：\(reason)", sessionID: sessionID)
            disconnectWebSocket()
        case .error(let message):
            errorMessage = message
            logStore.append("\n[agentd] \(message)\n", sessionID: sessionID)
        case .pong:
            statusMessage = "WebSocket 心跳正常"
        case .unknown(let type):
            logStore.append("\n[agentd] 未知消息类型：\(type)\n", sessionID: sessionID)
        }
    }

    private func upsert(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    private func updateSession(_ id: String, mutate: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&sessions[index])
    }
}
