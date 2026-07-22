import Foundation
import Network
import UserNotifications

struct MissingRunningSessionState: Equatable {
    let projectID: String
    var consecutiveRefreshMisses: Int
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var projects: [AgentProject] = [] {
        didSet {
            rebuildProjectIndex()
        }
    }
    @Published var recentWorkspaces: [AgentWorkspace] = [] {
        didSet {
            rebuildWorkspaceIndex()
        }
    }
    @Published var sidebarProjects: [AgentProject] = [] {
        didSet {
            rebuildProjectSessionListSnapshots()
        }
    }
    // 某个工作区的目录被删除、或 Mac 端 scan_roots 改动后掉出 allowlist 时记入这里：
    // 侧栏单独标记该行不可用，避免把“某个 recent 失效”冒泡成整页的全局错误。
    @Published var unavailableWorkspaceIDs: Set<String> = []
    @Published var sessions: [AgentSession] = [] {
        didSet {
            rebuildSessionIndexes()
        }
    }
    @Published var remoteSessionSearchResults: [AgentSession] = [] {
        didSet {
            rebuildProjectSessionListSnapshots()
        }
    }
    @Published var sessionSearchNextCursor: String?
    @Published var sessionSearchHasMore = false
    // 首屏搜索覆盖 300ms 防抖和实际请求；与分页 loading 分离，避免“继续搜索”误占空态。
    @Published var isSearchingRemoteSessionResults = false
    @Published var isLoadingMoreSessionSearchResults = false
    @Published var pinnedSessionIDs: Set<SessionID> = []
    @Published var archivedSessionIDs: Set<SessionID> = []
    @Published var sessionWorkspaceIDs: Set<String>? = nil
    @Published var sessionRemindersByID: [SessionID: SessionReminder] = [:]
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published var sessionSearchQuery = "" {
        didSet {
            guard oldValue != sessionSearchQuery else {
                return
            }
            rebuildProjectSessionListSnapshots()
            scheduleRemoteSessionSearch()
        }
    }
    @Published var expandedProjectIDs: Set<String> = []
    @Published var showingAllSessionProjectIDs: Set<String> = []
    @Published var isLoading = false
    @Published var webSocketStatus: WebSocketStatus = .disconnected
    @Published var connectionTermination: ConnectionTerminationStatus?
    @Published var networkReachabilityStatus: NetworkReachabilityStatus = .unknown
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isRefreshingSelectedSession = false
    @Published var isUpdatingThreadGoal = false
    @Published var threadGoalErrorMessage: String?
    @Published var appServerModelOptions: [CodexAppServerModelOption] = []
    @Published var isClaudeRuntimeChannelAvailable = false
    @Published var accountRateLimitsByRuntime: [String: RateLimitSummary] = [:]
    // 使用量刷新跨设置页、个人页和侧栏共享，由 Store 按 runtime 去重。
    // 视图只观察自己的 provider，避免 Claude loading 禁用其他按钮，也避免
    // 页面关闭后由未结构化 Task 回写已销毁的局部 @State。
    @Published var refreshingUsageRuntimeProviders: Set<String> = []
    @Published var isRefreshingAppServerModels = false
    @Published var capabilityList: CapabilityListResponse?
    @Published var isRefreshingCapabilities = false
    @Published var capabilityErrorMessage: String?
    @Published var isCreatingWorktree = false
    @Published var worktreeBranchesByPath: [String: WorktreeBranchListResponse] = [:]
    @Published var worktreeBranchErrorByPath: [String: String] = [:]
    @Published var isRefreshingWorktreeBranches = false
    @Published var managedWorktrees: [WorktreeListItem] = []
    @Published var isRefreshingWorktrees = false
    @Published var isDeletingWorktree = false
    @Published var isPruningWorktrees = false
    @Published var worktreeErrorMessage: String?
    @Published var gitStatusByPath: [String: GitStatusResponse] = [:]
    @Published var gitStatusErrorByPath: [String: String] = [:]
    @Published var isRefreshingGitStatus = false
    @Published var gitActionErrorByPath: [String: String] = [:]
    @Published var commandActionsByPath: [String: [AgentCommandAction]] = [:]
    @Published var commandActionErrorByPath: [String: String] = [:]
    @Published var commandActionResultByPath: [String: CommandActionRunResponse] = [:]
    @Published var commandActionHistoryByPath: [String: [CommandActionRunResponse]] = [:]
    @Published var isRefreshingCommandActions = false
    @Published var queuedCommandActionIDsByPath: [String: [String]] = [:]
    @Published var runningCommandActionPath: String?
    @Published var runningCommandActionID: String?
    @Published var isRunningGitAction = false
    @Published var isCommittingGitChanges = false
    @Published var isPushingGitBranch = false
    @Published var isQuickPublishingGitChanges = false
    @Published var gitQuickPublishResultByPath: [String: GitQuickPublishResponse] = [:]
    @Published var gitTestFlightStatusByPath: [String: GitTestFlightStatusResponse] = [:]
    @Published var gitTestFlightErrorByPath: [String: String] = [:]
    @Published var isRefreshingGitTestFlightStatus = false
    @Published var isStartingGitTestFlightRelease = false
    @Published var isCreatingPullRequest = false
    @Published var pullRequestURLByPath: [String: String] = [:]
    @Published var pullRequestStatusByPath: [String: GitPullRequestStatusResponse] = [:]
    @Published var pullRequestStatusErrorByPath: [String: String] = [:]
    @Published var isRefreshingPullRequestStatus = false
    @Published var pendingApprovalDecisionIDsBySessionID: [SessionID: Set<String>] = [:]
    @Published var pendingUserInputResponseIDsBySessionID: [SessionID: Set<String>] = [:]
    var pendingUserInputRequestsBySessionID: [SessionID: [String: AgentUserInputRequest]] = [:]
    @Published var foregroundActivityBySessionID: [SessionID: SessionForegroundActivity] = [:]
    @Published var runtimeActivityBySessionID: [SessionID: RuntimeActivitySnapshot] = [:]
    @Published var sessionControlStateByID: [SessionID: SessionControlState] = [:]
    @Published var queuedRunningTurnsBySessionID: [SessionID: [QueuedTurnEntry]] = [:]
    @Published var queuedTurnStorageErrorMessage: String?

    let appStore: AppStore
    let conversationStore: ConversationStore
    let logStore: LogStore
    let contextStore: SessionContextStore
    let eventReducer: EventReducer
    let recentWorkspaceStore: RecentWorkspaceStore
    let sessionListPreferenceStore: SessionListPreferenceStore
    let sessionControlStateStore: SessionControlStateStore
    let sessionReminderStore: SessionReminderStore
    let sessionReminderScheduler: any SessionReminderScheduling
    let sessionReminderNow: () -> Date
    let historySavingsNoticeStore: HistorySavingsNoticeStore
    let queuedTurnStore: any QueuedTurnPersisting
    let terminalStreamStore = TerminalStreamStore()
    // 草稿跟随 SessionStore 生命周期，避免窗口 resize 或详情页重建时随 ComposerView 的 @State 一起丢失。
    // 不使用 @Published，防止每次键入都触发整个工作台刷新。
    var composerDraftCache = ComposerDraftCache()
    // Goal / Plan 选择同样需要跨横竖屏 View 重建，但不应持久化到下次启动。
    // 保持非 @Published，ComposerView 自己维持当前可见状态，避免放大刷新范围。
    var composerSendModeCache = ComposerSendModeCache()
    let clientFactory: () throws -> any SessionStoreAPIClient
    let webSocketFactory: () -> any SessionWebSocketClient
    let sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)?
    let webSocketReconnectDelayNanoseconds: (Int) -> UInt64
    let webSocketReconnectSleep: (UInt64) async throws -> Void
    let networkPathStatusSource: any NetworkPathStatusSource
    let sessionListNow: () -> Date
    let sessionListSleep: (UInt64) async -> Void
    let sessionSearchDebounceNanoseconds: UInt64
    let sessionSearchSleep: (UInt64) async throws -> Void
    var webSocket: (any SessionWebSocketClient)?
    var connectedSessionID: String?
    var webSocketConnectionGeneration = 0
    var webSocketReconnectTask: Task<Void, Never>?
    var webSocketReconnectAttemptBySessionID: [SessionID: Int] = [:]
    var lastAppliedNetworkPathSequence: UInt64 = 0
    var networkPathGeneration = 0
    var networkSuspendedSessionID: SessionID?
    var networkRecoveryTask: Task<Void, Never>?
    var appLifecycleSuspendedSessionID: SessionID?
    var isAppInBackground = false
    var connectionChangeGeneration = 0
    var inFlightConnectionChangeGeneration: Int?
    var lastSeenEventSeqBySessionID: [SessionID: EventSequence] = [:]
    var historySnapshotSeqBySessionID: [SessionID: EventSequence] = [:]
    var runtimeEventFlushTasks: [SessionID: Task<Void, Never>] = [:]
    var foregroundActivityClearTasks: [SessionID: Task<Void, Never>] = [:]
#if DEBUG
    var didApplyDebugWorkbenchUISeed = false
#endif
    var deliveredRuntimeNotificationIDs: Set<String> = []
    var locallyCompletedSessionIDs: Set<SessionID> = []
    var locallyCompletedGoalThreadIDs: Set<SessionID> = []
    var listProjectionBySessionID: [SessionID: SessionListProjection] = [:]
    var recentActivityProjectionBySessionID: [SessionID: SessionRecentActivityProjection] = [:]
    // 队列订阅不依赖当前页面；用户切到其他会话后，原 thread 仍能在完成时继续 FIFO 派发。
    var queuedSessionSockets: [SessionID: any SessionWebSocketClient] = [:]
    var queuedSessionSocketGenerationByID: [SessionID: Int] = [:]
    var queuedSessionReadyIDs: Set<SessionID> = []
    var queuedSessionReconnectTasks: [SessionID: Task<Void, Never>] = [:]
    var queuedTurnStartedIDBySessionID: [SessionID: TurnID] = [:]
    var queuedTurnAwaitingStartSessionIDs: Set<SessionID> = []
    var queuedTurnBlockedCompletionIDBySessionID: [SessionID: TurnID] = [:]
    var queuedGuidanceDispatchClientMessageIDs: Set<ClientMessageID> = []
    var currentQueuedTurnProfileID: String?
    var queuedCommandActionRuns: [QueuedCommandActionRun] = []
    var projectsByID: [String: AgentProject] = [:]
    var workspacesByID: [String: AgentWorkspace] = [:]
    var sidebarProjectsByID: [String: AgentProject] = [:]
    var sessionsByID: [SessionID: AgentSession] = [:]
    var sessionIndexByID: [SessionID: Int] = [:]
    var sortedAllSessions: [AgentSession] = []
    var sortedSessionsByProjectID: [String: [AgentSession]] = [:]
    var previewSessionsByProjectID: [String: [AgentSession]] = [:]
    var hiddenSessionCountByProjectID: [String: Int] = [:]
    @Published var sessionVisibleLimitByProjectID: [String: Int] = [:]
    var sessionListSnapshotsByProjectID: [String: ProjectSessionListSnapshot] = [:]
    var frozenAllSessionOrder: [SessionID] = []
    var frozenSessionOrderByProjectID: [String: [SessionID]] = [:]
    var sessionPageCursorByProjectID: [String: String] = [:]
    var sessionHasMoreByProjectID: [String: Bool] = [:]
    /// 工作区详情独立于侧栏展开状态记录已经加载过旧页的项目，供下拉刷新保留分页窗口。
    var sessionProjectsWithAdditionalPages: Set<String> = []
    var sessionPageRequestTokenByProjectID: [String: Int] = [:]
    var sessionPageLoadingTokenByProjectID: [String: Int] = [:]
    var sessionListFirstPageInFlightByKey: [SessionListFirstPageRequestKey: SessionListFirstPageInFlight] = [:]
    var sessionListFirstPageCacheByKey: [SessionListFirstPageRequestKey: SessionListFirstPageCacheEntry] = [:]
    var sessionListCooldownUntilByBudgetKey: [SessionListBudgetKey: Date] = [:]
    var sessionListReconciliationTasksByProjectID: [String: Task<Void, Never>] = [:]
    var missingRunningSessionStateByID: [SessionID: MissingRunningSessionState] = [:]
    var missingRunningSessionReconciliationTasksByID: [SessionID: Task<Void, Never>] = [:]
    var lastSessionLibraryIndexRefreshAt: Date?
    var sessionSearchTask: Task<Void, Never>?
    var sessionSearchLoadMoreTask: Task<Void, Never>?
    var sessionSearchGeneration = 0
    var sessionSearchLoadingCursor: String?
    var remoteSessionSearchSnippetByID: [SessionID: String] = [:]
    var historyPreviousCursorBySessionID: [SessionID: String] = [:]
    var historyHasMoreBeforeBySessionID: [SessionID: Bool] = [:]
    var historyPageRequestTokenBySessionID: [SessionID: Int] = [:]
    var historyFirstPageInFlightByKey: [HistoryFirstPageRequestKey: HistoryFirstPageInFlight] = [:]
    var historyFirstPageCacheByKey: [HistoryFirstPageRequestKey: HistoryFirstPageCacheEntry] = [:]
    var historyLoadJobsBySessionID: [SessionID: HistoryLoadJob] = [:]
    var historyLoadJobTokenBySessionID: [SessionID: Int] = [:]
    var historyLoadedSignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    var historyLoadedQualityBySessionID: [SessionID: HistoryLoadQuality] = [:]
    var freshEmptyHistorySignatureBySessionID: [SessionID: HistoryLoadSignature] = [:]
    var initialHistoryLoadingSessionIDs: Set<SessionID> = []
    @Published var historyLoadProgressBySessionID: [SessionID: HistoryLoadProgress] = [:]
    @Published var historySavingsNoticesBySessionID: [SessionID: HistorySavingsNotice] = [:]
    @Published var dismissedHistorySavingsNoticeEndpoints: Set<String> = []
    var appServerModelOptionsLastRefresh: Date?
    @Published var loadingEarlierHistorySessionIDs: Set<SessionID> = []

    let foregroundOutputIdleClearDelay: UInt64 = 8_000_000_000
    let runtimeEventFlushDelayNanoseconds: UInt64 = 80_000_000
    let sessionListConnectedPollingDelayNanoseconds: UInt64 = 60_000_000_000
    let sessionListDisconnectedPollingDelayNanoseconds: UInt64 = 8_000_000_000
    let sessionListFirstPageCacheTTL: TimeInterval = 2
    let sessionLibraryIndexPollingInterval: TimeInterval = 60
    let sessionListReconciliationDelayNanoseconds: UInt64 = 1_500_000_000
    let economyHistoryPageLimit = 60
    let fullHistoryPageLimit = 20
    let historyFirstPageCacheTTL: TimeInterval = 4
    let historyPolicyRetryFallbackNanoseconds: UInt64 = 15_000_000_000
    let historyPolicyRetryMaxNanoseconds: UInt64 = 20_000_000_000
    static let optimisticSessionSource = "local"
    /// 项目侧栏只承担快速切换职责；每个项目固定展示最近 5 条，完整历史在工作区页分页查看。
    static let sessionPreviewLimit = 5
    static let sessionExpansionStep = 5
    // Tailscale 在弱网下可能经 Peer Relay 或 DERP 转发 thread/list 的较大响应。
    // 首屏先拿较小窗口，避免为了预览历史会话而卡住整个工作台。
    static let initialSessionPageLimit = 20
    static let expandedSessionPageLimit = 20
    static let missingRunningSessionReadThreshold = 2
    static let maximumUnverifiedRunningSessionMisses = 3
    static let commandActionHistoryLimit = 10
    static let queuedTurnLimitPerSession = 20

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
        queuedTurnStore: (any QueuedTurnPersisting)? = nil,
        sessionReminderScheduler: (any SessionReminderScheduling)? = nil,
        sessionReminderNow: @escaping () -> Date = Date.init,
        clientFactory: (() throws -> any SessionStoreAPIClient)? = nil,
        webSocketFactory: (() -> any SessionWebSocketClient)? = nil,
        sessionWebSocketFactory: ((AgentSession) -> any SessionWebSocketClient)? = nil,
        webSocketReconnectDelayNanoseconds: ((Int) -> UInt64)? = nil,
        webSocketReconnectRandom: @escaping () -> Double = { Double.random(in: 0...1) },
        webSocketReconnectSleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        networkPathStatusSource: (any NetworkPathStatusSource)? = nil,
        sessionListNow: @escaping () -> Date = Date.init,
        sessionListSleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        sessionSearchDebounceNanoseconds: UInt64 = 300_000_000,
        sessionSearchSleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
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
        if let queuedTurnStore {
            self.queuedTurnStore = queuedTurnStore
        } else if clientFactory != nil {
            self.queuedTurnStore = FileQueuedTurnStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SessionStore.QueuedTurns.\(UUID().uuidString)", isDirectory: true)
            )
        } else {
            self.queuedTurnStore = FileQueuedTurnStore()
        }
        if let sessionReminderScheduler {
            self.sessionReminderScheduler = sessionReminderScheduler
        } else if clientFactory != nil {
            self.sessionReminderScheduler = NoopSessionReminderScheduler()
        } else {
            self.sessionReminderScheduler = UserNotificationSessionReminderScheduler()
        }
        self.sessionReminderNow = sessionReminderNow
        self.clientFactory = clientFactory ?? { try appStore.makeSessionStoreAPIClient() }
        self.webSocketFactory = webSocketFactory ?? { appStore.makeSessionWebSocketClient() }
        if let sessionWebSocketFactory {
            self.sessionWebSocketFactory = sessionWebSocketFactory
        } else if webSocketFactory == nil {
            self.sessionWebSocketFactory = { appStore.makeSessionWebSocketClient(for: $0) }
        } else {
            self.sessionWebSocketFactory = nil
        }
        if let webSocketReconnectDelayNanoseconds {
            self.webSocketReconnectDelayNanoseconds = webSocketReconnectDelayNanoseconds
        } else {
            self.webSocketReconnectDelayNanoseconds = { attempt in
                Self.defaultWebSocketReconnectDelayNanoseconds(
                    attempt: attempt,
                    randomUnit: webSocketReconnectRandom()
                )
            }
        }
        self.webSocketReconnectSleep = webSocketReconnectSleep
        if let networkPathStatusSource {
            self.networkPathStatusSource = networkPathStatusSource
        } else if clientFactory == nil {
            self.networkPathStatusSource = NWNetworkPathStatusSource()
        } else {
            self.networkPathStatusSource = StaticNetworkPathStatusSource(.satisfied)
        }
        self.sessionListNow = sessionListNow
        self.sessionListSleep = sessionListSleep
        self.sessionSearchDebounceNanoseconds = sessionSearchDebounceNanoseconds
        self.sessionSearchSleep = sessionSearchSleep
        self.dismissedHistorySavingsNoticeEndpoints = self.historySavingsNoticeStore.loadDismissedEndpoints()
        reloadSessionListPreferences()
        reloadSessionControlStates()
        reloadSessionReminders()
        reloadQueuedTurns()
        self.networkReachabilityStatus = self.networkPathStatusSource.currentStatus
        self.networkPathStatusSource.onStatusChange = { [weak self] update in
            Task { @MainActor in
                self?.applyNetworkReachabilityStatus(update)
            }
        }
        self.networkPathStatusSource.start()
    }

    deinit {
        networkRecoveryTask?.cancel()
        webSocketReconnectTask?.cancel()
        sessionSearchTask?.cancel()
        sessionSearchLoadMoreTask?.cancel()
        missingRunningSessionReconciliationTasksByID.values.forEach { $0.cancel() }
        queuedSessionReconnectTasks.values.forEach { $0.cancel() }
        networkPathStatusSource.stop()
    }

    static func defaultWebSocketReconnectDelayNanoseconds(
        attempt: Int,
        randomUnit: Double,
        maximumNanoseconds: UInt64 = 30_000_000_000
    ) -> UInt64 {
        let boundedExponent = max(0, min(attempt - 1, 5))
        let baseSeconds = min(30.0, Double(1 << boundedExponent))
        let normalizedRandom = min(1, max(0, randomUnit))
        // ±20% jitter 避免多台移动设备在同一秒同时打向 Mac；最终值仍受硬上限约束。
        let jitteredNanoseconds = baseSeconds * (0.8 + normalizedRandom * 0.4) * 1_000_000_000
        return min(maximumNanoseconds, UInt64(jitteredNanoseconds.rounded()))
    }

    var isNetworkUnavailable: Bool {
        networkReachabilityStatus == .unsatisfied
    }

    func sessionSearchSnippet(for sessionID: SessionID) -> String? {
        guard isSessionSearchActive else {
            return nil
        }
        return remoteSessionSearchSnippetByID[sessionID]
    }

    func loadMoreSessionSearchResults() async {
        let searchTerm = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty,
              sessionSearchHasMore,
              let requestedCursor = sessionSearchNextCursor,
              !requestedCursor.isEmpty,
              !isLoadingMoreSessionSearchResults,
              sessionSearchLoadingCursor == nil,
              !isNetworkUnavailable,
              connectionTermination == nil
        else {
            return
        }

        let generation = sessionSearchGeneration
        let connectionGeneration = appStore.connectionGeneration
        isLoadingMoreSessionSearchResults = true
        sessionSearchLoadingCursor = requestedCursor

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // 旧分页任务只能收尾自己的 loading；新查询即使复用了同一 cursor，也由 generation 隔离。
                if self.sessionSearchGeneration == generation,
                   self.sessionSearchLoadingCursor == requestedCursor {
                    self.sessionSearchLoadingCursor = nil
                    self.isLoadingMoreSessionSearchResults = false
                    self.sessionSearchLoadMoreTask = nil
                }
            }

            guard !Task.isCancelled,
                  self.sessionSearchGeneration == generation,
                  self.appStore.connectionGeneration == connectionGeneration,
                  self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                  self.sessionSearchNextCursor == requestedCursor
            else {
                return
            }

            do {
                let client = try self.clientFactory()
                let page = try await client.searchSessions(query: searchTerm, cursor: requestedCursor, limit: 50)
                guard !Task.isCancelled,
                      self.sessionSearchGeneration == generation,
                      self.appStore.connectionGeneration == connectionGeneration,
                      self.sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchTerm,
                      self.sessionSearchNextCursor == requestedCursor
                else {
                    return
                }
                self.applyRemoteSessionSearchPage(page, replacing: false, requestedCursor: requestedCursor)
            } catch {
                // 翻页失败只结束本次 loading，保留既有结果和 cursor，用户可显式重试。
                // 搜索增强不应改写全局连接、鉴权或错误状态。
            }
        }
        sessionSearchLoadMoreTask = task
        await task.value
    }

    func saveComposerDraft(_ snapshot: ComposerDraftSnapshot, for scope: ComposerDraftScopeKey) {
        composerDraftCache.save(snapshot, for: scope)
    }

    func composerDraft(for scope: ComposerDraftScopeKey) -> ComposerDraftSnapshot {
        composerDraftCache.snapshot(for: scope)
    }

    func removeComposerDraft(for scope: ComposerDraftScopeKey) {
        composerDraftCache.remove(scope: scope)
    }

    func composerSendModeForScopeActivation(
        previousScope: ComposerDraftScopeKey,
        nextScope: ComposerDraftScopeKey,
        currentMode: ComposerSendMode,
        isOptimisticSessionHandoff: Bool
    ) -> ComposerSendMode {
        composerSendModeCache.modeForScopeActivation(
            previousScope: previousScope,
            nextScope: nextScope,
            currentMode: currentMode,
            isOptimisticSessionHandoff: isOptimisticSessionHandoff
        )
    }

    func saveComposerSendMode(_ mode: ComposerSendMode, for scope: ComposerDraftScopeKey) {
        composerSendModeCache.save(mode, for: scope)
    }

    var selectedQueuedTurns: [QueuedTurnEntry] {
        guard let selectedSessionID else {
            return []
        }
        return queuedRunningTurnsBySessionID[selectedSessionID] ?? []
    }

    func queuedTurns(sessionID: SessionID) -> [QueuedTurnEntry] {
        queuedRunningTurnsBySessionID[sessionID] ?? []
    }

    @discardableResult
    func updateQueuedTurn(
        clientMessageID: ClientMessageID,
        payload: CodexAppServerTurnPayload
    ) -> Bool {
        guard !payload.isEmpty,
              let location = queuedTurnLocation(clientMessageID: clientMessageID),
              let queuedTurn = queuedRunningTurnsBySessionID[location.sessionID]?[location.index],
              queuedTurn.dispatchState != .dispatching,
              !queuedTurn.intent.startsGoal || !payload.textPrompt.isEmpty
        else {
            return false
        }
        return mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].payload = payload
            if case .goal(_, let tokenBudget) = queue[location.index].intent {
                queue[location.index].intent = .goal(
                    objective: payload.textPrompt,
                    tokenBudget: tokenBudget
                )
            }
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
    }

    @discardableResult
    func deleteQueuedTurn(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              queuedRunningTurnsBySessionID[location.sessionID]?[location.index].dispatchState != .dispatching
        else {
            return false
        }
        let didPersist = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue.remove(at: location.index)
            setQueuedTurns(queue, sessionID: location.sessionID)
        }
        if didPersist {
            stopQueuedSessionMonitoringIfIdle(sessionID: location.sessionID)
        }
        return didPersist
    }

    @discardableResult
    func retryQueuedTurn(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              queuedRunningTurnsBySessionID[location.sessionID]?[location.index].dispatchState == .needsConfirmation
        else {
            return false
        }
        let didPersist = mutateAndPersistQueuedTurns {
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .waiting
            queue[location.index].expectedTurnID = sessionsByID[location.sessionID]?.activeTurnID
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }
        if didPersist {
            ensureQueuedSessionMonitoring(sessionID: location.sessionID)
            dispatchNextQueuedRunningTurnIfIdle(sessionID: location.sessionID)
        }
        return didPersist
    }

    @discardableResult
    func guideQueuedTurnNow(clientMessageID: ClientMessageID) -> Bool {
        guard let location = queuedTurnLocation(clientMessageID: clientMessageID),
              location.sessionID == selectedSessionID,
              let session = selectedSession,
              let item = queuedRunningTurnsBySessionID[location.sessionID]?[location.index],
              item.dispatchState == .waiting,
              item.intent.canGuideCurrentTurn,
              let activeTurnID = session.activeTurnID,
              let socket = readyWebSocket(for: session)
        else {
            setErrorMessage(L10n.text("ui.there_are_currently_no_active_rounds_to_boot"))
            return false
        }
        guard mutateAndPersistQueuedTurns({
            guard var queue = queuedRunningTurnsBySessionID[location.sessionID],
                  queue.indices.contains(location.index) else { return }
            queue[location.index].dispatchState = .dispatching
            queue[location.index].lastAttemptAt = Date()
            queue[location.index].lastError = nil
            queuedRunningTurnsBySessionID[location.sessionID] = queue
        }) else {
            return false
        }
        queuedGuidanceDispatchClientMessageIDs.insert(clientMessageID)
        guard socket.sendGuidance(
            item.payload,
            clientMessageID: item.clientMessageID,
            expectedTurnID: activeTurnID
        ) else {
            queuedGuidanceDispatchClientMessageIDs.remove(clientMessageID)
            markQueuedTurnWaitingAfterDefiniteFailure(
                clientMessageID: clientMessageID,
                message: L10n.text("ui.the_connection_is_not_ready_yet_the_message")
            )
            return false
        }
        conversationStore.appendLocalUser(
            item.previewText,
            sessionID: session.id,
            clientMessageID: item.clientMessageID,
            sendStatus: .sending,
            turnPayload: item.payload,
            userDelivery: .guided
        )
        setForegroundActivity(.waitingForAssistant, sessionID: session.id)
        setStatusMessage(L10n.text("ui.directed_current_reply_immediately"))
        return true
    }

    @discardableResult
    func moveSelectedQueuedTurns(fromOffsets: IndexSet, toOffset: Int) -> Bool {
        guard let selectedSessionID,
              var queue = queuedRunningTurnsBySessionID[selectedSessionID],
              queue.allSatisfy({ $0.dispatchState != .dispatching })
        else {
            return false
        }
        let previous = queuedRunningTurnsBySessionID
        let moving = fromOffsets.sorted().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        for index in fromOffsets.sorted(by: >) where queue.indices.contains(index) {
            queue.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(0, toOffset - removedBeforeDestination), queue.count)
        queue.insert(contentsOf: moving, at: destination)
        queuedRunningTurnsBySessionID[selectedSessionID] = queue
        do {
            try persistQueuedTurns()
            queuedTurnStorageErrorMessage = nil
            return true
        } catch {
            queuedRunningTurnsBySessionID = previous
            reportQueuedTurnStorageError(error)
            return false
        }
    }

    func reloadQueuedTurns() {
        let profileID = appStore.notificationRoutingProfileID
        currentQueuedTurnProfileID = profileID
        do {
            var snapshot = try queuedTurnStore.load(profileID: profileID)
            // dispatching 表示上一个进程在 RPC 确认前中断。协议没有承诺
            // clientUserMessageId 幂等，因此重启后先阻止盲目重放，等历史对账。
            var didRecoverAmbiguousDispatch = false
            for sessionID in snapshot.queuesBySessionID.keys {
                guard var queue = snapshot.queuesBySessionID[sessionID] else { continue }
                for index in queue.indices where queue[index].dispatchState == .dispatching {
                    queue[index].dispatchState = .needsConfirmation
                    queue[index].lastError = L10n.text("ui.the_last_sending_was_interrupted_before_confirmation_checking")
                    didRecoverAmbiguousDispatch = true
                }
                snapshot.queuesBySessionID[sessionID] = queue
            }
            queuedRunningTurnsBySessionID = snapshot.queuesBySessionID.filter { !$0.value.isEmpty }
            if didRecoverAmbiguousDispatch {
                try queuedTurnStore.save(snapshot)
            }
            queuedTurnStorageErrorMessage = nil
        } catch {
            // 解码失败不覆盖原文件；否则一次版本不兼容会把待发指令静默清空。
            queuedRunningTurnsBySessionID = [:]
            reportQueuedTurnStorageError(error)
        }
    }

    func persistQueuedTurns() throws {
        let profileID = currentQueuedTurnProfileID ?? appStore.notificationRoutingProfileID
        let snapshot = QueuedTurnProfileSnapshot(
            profileID: profileID,
            queuesBySessionID: queuedRunningTurnsBySessionID.filter { !$0.value.isEmpty }
        )
        try queuedTurnStore.save(snapshot)
    }

    @discardableResult
    func mutateAndPersistQueuedTurns(_ mutation: () -> Void) -> Bool {
        let previous = queuedRunningTurnsBySessionID
        mutation()
        do {
            try persistQueuedTurns()
            queuedTurnStorageErrorMessage = nil
            return true
        } catch {
            queuedRunningTurnsBySessionID = previous
            reportQueuedTurnStorageError(error)
            return false
        }
    }

    func reportQueuedTurnStorageError(_ error: Error) {
        let message = L10n.format("ui.failed_to_save_local_queue_value", error.localizedDescription)
        queuedTurnStorageErrorMessage = message
        setErrorMessage(message)
    }

    func queuedTurnLocation(
        clientMessageID: ClientMessageID
    ) -> (sessionID: SessionID, index: Int)? {
        for (sessionID, queue) in queuedRunningTurnsBySessionID {
            if let index = queue.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
                return (sessionID, index)
            }
        }
        return nil
    }

    func setQueuedTurns(_ queue: [QueuedTurnEntry], sessionID: SessionID) {
        if queue.isEmpty {
            queuedRunningTurnsBySessionID.removeValue(forKey: sessionID)
            queuedTurnStartedIDBySessionID.removeValue(forKey: sessionID)
        } else {
            queuedRunningTurnsBySessionID[sessionID] = queue
        }
    }

    static func safePreviewFilename(_ rawName: String) -> String {
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

    var selectedGitQuickPublishResult: GitQuickPublishResponse? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitQuickPublishResultByPath[path]
    }

    var selectedGitTestFlightStatus: GitTestFlightStatusResponse? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitTestFlightStatusByPath[path]
    }

    var selectedGitTestFlightErrorMessage: String? {
        guard let path = selectedGitStatusPath else {
            return nil
        }
        return gitTestFlightErrorByPath[path]
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
                return L10n.text("ui.history")
            }
            return selectedSession.status == "closed" ? L10n.text("ui.ended") : selectedSession.status
        }
        return webSocketStatus.title
    }

    var filteredSessions: [AgentSession] {
        let base: [AgentSession]
        guard let selectedProjectID else {
            base = sortedAllSessions
            return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base))
        }
        base = sortedSessionsByProjectID[selectedProjectID] ?? []
        return sessionsMatchingSearch(sessionsIncludingRemoteSearch(base, projectID: selectedProjectID))
    }

    /// 会话库不跟随 selectedProjectID 过滤；根侧栏和会话页始终看到同一份跨工作区轻量索引。
    var sessionLibrarySessions: [AgentSession] {
        sessionsMatchingSearch(sessionsIncludingRemoteSearch(Self.sortedSessions(sessions.filter(isListableSession))))
    }

    /// 最近列表严格按活动时间排序，置顶只影响完整会话库，不改变“最近”的时间语义。
    var recentSessions: [AgentSession] {
        Array(Self.sortedSessions(sessions.filter(isListableSession)).prefix(8))
    }

    /// 进行中的任务不能被“最近 8 条”截断；侧栏始终展示当前已加载索引里的全部运行态。
    var activeSessions: [AgentSession] {
        Self.sortedSessions(sessions.filter { isListableSession($0) && $0.isRunning })
    }

    /// 历史区单独保留最近 8 条，避免运行任务占掉历史预览名额。
    var recentHistorySessions: [AgentSession] {
        Array(Self.sortedSessions(sessions.filter { isListableSession($0) && !$0.isRunning }).prefix(8))
    }

    var filteredSidebarProjects: [AgentProject] {
        guard isSessionSearchActive else {
            return sidebarProjects
        }
        return sidebarProjects.filter { project in
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
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
            projectMatchesSearch(project)
                || !sessionsMatchingSearch(sessionsIncludingRemoteSearch(sortedSessionsByProjectID[project.id] ?? [], projectID: project.id)).isEmpty
        }
    }

    var effectiveSessionSidebarProjects: [AgentProject] {
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
            setStatusMessage(L10n.format("ui.value_has_been_removed_from_the_conversation", project.name))
        } else {
            next.insert(project.id)
            setStatusMessage(L10n.format("ui.already_shown_in_session_value", project.name))
        }
        setSessionWorkspaceIDs(next.intersection(allProjectIDs))
    }

    func resetSessionWorkspaceSelection() {
        setStatusMessage(L10n.text("ui.session_resumed_show_all_workspaces"))
        setSessionWorkspaceIDs(nil)
    }

    func visibleSessions(forProjectID projectID: String) -> [AgentSession] {
        let sessions = sessions(forProjectID: projectID)
        return Self.lifecycleVisibleSessions(
            sessions,
            limit: sessionVisibleLimit(forProjectID: projectID)
        )
    }

    func hiddenSessionCount(forProjectID projectID: String) -> Int {
        let sessions = sessions(forProjectID: projectID)
        return max(0, sessions.count - visibleSessions(forProjectID: projectID).count)
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
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "codex"), fallbackDisplayName: "Codex")
    }

    var accountClaudeUsageWindowsDisplay: CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: latestRateLimit(runtimeProvider: "claude"), fallbackDisplayName: "Claude")
    }

    func latestRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        let normalizedProvider = Self.normalizedRuntimeProvider(runtimeProvider)
        if let cached = accountRateLimitsByRuntime[normalizedProvider] {
            return cached
        }
        if let session = selectedSession,
           Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == normalizedProvider,
           let rateLimit = session.rateLimit {
            return rateLimit
        }
        return mostRecentSessionRateLimit(runtimeProvider: normalizedProvider)
    }

    func mostRecentSessionRateLimit(runtimeProvider: String) -> RateLimitSummary? {
        sessions
            .filter { session in
                session.rateLimit != nil
                    && Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == runtimeProvider
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
        return L10n.text("ui.this_session_is_running_on_other_clients_the")
    }

    func takeOverSession(_ session: AgentSession) {
        setSessionControlState(.takenOver, sessionID: session.id)
        if session.id == selectedSessionID, session.isRunning {
            // 接管前消息区已经由 selectSession/刷新用 thread/read 快照兜底；backlog 走状态级
            // 回放（completed 内容仍会补播），完整回放会把旧 delta 再直播一遍。
            connectWebSocket(session, replayBufferedEvents: false)
        }
        setStatusMessage(L10n.text("ui.taken_over_to_ipad"))
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

}
