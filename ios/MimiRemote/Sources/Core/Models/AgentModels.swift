import Foundation

typealias SessionID = String
typealias MessageID = String
typealias ClientMessageID = String
typealias TurnID = String
typealias AgentItemID = String
typealias EventSequence = Int64
typealias ModelRevision = Int

struct AgentProject: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let path: String
}

struct AgentWorkspace: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let rootProjectID: String?
    let rootProjectName: String?
    let rootProjectPath: String?
    var lastOpenedAt: Date?

    var project: AgentProject {
        AgentProject(id: id, name: name, path: path)
    }

    init(
        id: String,
        name: String,
        path: String,
        rootProjectID: String? = nil,
        rootProjectName: String? = nil,
        rootProjectPath: String? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.rootProjectID = rootProjectID
        self.rootProjectName = rootProjectName
        self.rootProjectPath = rootProjectPath
        self.lastOpenedAt = lastOpenedAt
    }

    init(project: AgentProject, lastOpenedAt: Date? = nil) {
        self.init(
            id: project.id,
            name: project.name,
            path: project.path,
            rootProjectID: project.id,
            rootProjectName: project.name,
            rootProjectPath: project.path,
            lastOpenedAt: lastOpenedAt
        )
    }

    func opened(at date: Date) -> AgentWorkspace {
        AgentWorkspace(
            id: id,
            name: name,
            path: path,
            rootProjectID: rootProjectID,
            rootProjectName: rootProjectName,
            rootProjectPath: rootProjectPath,
            lastOpenedAt: date
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case rootProjectID = "root_project_id"
        case rootProjectName = "root_project_name"
        case rootProjectPath = "root_project_path"
        case lastOpenedAt = "last_opened_at"
    }
}

struct AgentSession: Identifiable, Codable, Hashable {
    let id: SessionID
    let projectID: String
    let project: String
    let dir: String
    let title: String
    var status: String
    let source: String
    let runtimeProvider: String?
    let resumeID: String?
    let createdAt: Date?
    var updatedAt: Date?
    var preview: String?
    var activeTurnID: TurnID?
    let lastSeq: EventSequence?
    let revision: ModelRevision?
    var usage: UsageSummary?
    var rateLimit: RateLimitSummary?
    var pendingApproval: ApprovalSummary?
    var pendingUserInput: AgentUserInputRequest?
    var goal: ThreadGoal?
    let context: SessionContextSnapshot?

    var isAppServerHistory: Bool {
        status == "history"
    }

    var isRunning: Bool {
        status == "running" || status == "waiting_for_approval" || status == "waiting_for_input"
    }

    var displayStatusText: String {
        displayStatus(foregroundActivity: nil).title
    }

    init(
        id: SessionID,
        projectID: String,
        project: String,
        dir: String,
        title: String,
        status: String,
        source: String,
        runtimeProvider: String? = nil,
        resumeID: String?,
        createdAt: Date?,
        updatedAt: Date?,
        preview: String? = nil,
        activeTurnID: TurnID? = nil,
        lastSeq: EventSequence? = nil,
        revision: ModelRevision? = nil,
        usage: UsageSummary? = nil,
        rateLimit: RateLimitSummary? = nil,
        pendingApproval: ApprovalSummary? = nil,
        pendingUserInput: AgentUserInputRequest? = nil,
        goal: ThreadGoal? = nil,
        context: SessionContextSnapshot? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.project = project
        self.dir = dir
        self.title = title
        self.status = status
        self.source = source
        let normalizedRuntimeProvider = runtimeProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimeProvider = normalizedRuntimeProvider?.isEmpty == false ? normalizedRuntimeProvider : nil
        self.resumeID = resumeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.activeTurnID = activeTurnID
        self.lastSeq = lastSeq
        self.revision = revision
        self.usage = usage
        self.rateLimit = rateLimit
        // pendingApproval 只在真实等待审批状态下有效；历史快照偶发带回旧值时，
        // 这里先做归一化，避免输入框展示已经失效的审批卡。
        self.pendingApproval = status == "waiting_for_approval" ? pendingApproval : nil
        self.pendingUserInput = status == "waiting_for_input" ? pendingUserInput : nil
        self.goal = goal ?? context?.goal
        self.context = context
    }

    init(row: DataFlowSessionRow) {
        // DataFlowSessionRow 是新列表模型；这里保留旧 AgentSession 入口，方便现有 UI 渐进迁移。
        self.init(
            id: row.id,
            projectID: row.projectID,
            project: row.projectName ?? "",
            dir: row.projectPath ?? "",
            title: row.title,
            status: row.status.rawValue,
            source: row.source,
            runtimeProvider: row.runtimeProvider,
            resumeID: row.resumeID,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            preview: row.preview,
            activeTurnID: row.activeTurnID,
            lastSeq: row.lastSeq,
            revision: row.revision,
            usage: row.usage,
            rateLimit: row.rateLimit,
            pendingApproval: row.pendingApproval,
            pendingUserInput: nil,
            goal: row.context?.goal,
            context: row.context
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case project
        case dir
        case title
        case status
        case source
        case runtimeProvider = "runtime_provider"
        case resumeID = "resume_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case preview
        case activeTurnID = "active_turn_id"
        case lastSeq = "last_seq"
        case revision
        case usage
        case rateLimit = "rate_limit"
        case pendingApproval = "pending_approval"
        case pendingUserInput = "pending_user_input"
        case goal
        case context
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

    var displayStatus: AgentSessionDisplayStatus {
        switch self {
        case .refreshing:
            return AgentSessionDisplayStatus(title: title, systemImage: "arrow.triangle.2.circlepath", tone: .neutral, showsSpinner: true)
        case .waitingForAssistant:
            return AgentSessionDisplayStatus(title: title, systemImage: "hourglass", tone: .active, showsSpinner: true)
        case .receivingAssistant:
            return AgentSessionDisplayStatus(title: title, systemImage: "ellipsis.message.fill", tone: .active, showsSpinner: false)
        }
    }
}

enum AgentSessionStatusTone: String, Hashable {
    case active
    case warning
    case danger
    case complete
    case neutral
}

struct AgentSessionDisplayStatus: Hashable {
    let title: String
    let systemImage: String
    let tone: AgentSessionStatusTone
    let showsSpinner: Bool
}

struct AgentSessionStatusBadge: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let tone: AgentSessionStatusTone
}

struct RuntimeActivitySnapshot: Equatable {
    let turnStartedAt: Date
    let lastActivityAt: Date
}

struct RuntimeActivityDisplay: Equatable {
    let detailText: String
    let tone: AgentSessionStatusTone
    let systemImage: String

    static let freshThreshold: TimeInterval = 20
    static let staleThreshold: TimeInterval = 90

    static func make(
        snapshot: RuntimeActivitySnapshot?,
        webSocketStatus: WebSocketStatus,
        now: Date = Date()
    ) -> RuntimeActivityDisplay? {
        guard let snapshot else {
            return nil
        }
        // 这里表达的是“最近收到 runtime 事件”的证据，不判断命令是否真的卡死。
        // 长命令无输出时，用户看到的是无新事件时长和连接状态，避免误报。
        let runningText = "运行 \(compactClockDuration(now.timeIntervalSince(snapshot.turnStartedAt)))"
        let idleSeconds = max(0, now.timeIntervalSince(snapshot.lastActivityAt))

        switch webSocketStatus {
        case .connected:
            if idleSeconds <= freshThreshold {
                return RuntimeActivityDisplay(
                    detailText: "\(runningText) · 最后活动 \(relativeDurationText(idleSeconds))前",
                    tone: .active,
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            if idleSeconds <= staleThreshold {
                return RuntimeActivityDisplay(
                    detailText: "\(runningText) · 等待输出 · \(relativeDurationText(idleSeconds))无新事件",
                    tone: .neutral,
                    systemImage: "hourglass"
                )
            }
            return RuntimeActivityDisplay(
                detailText: "\(runningText) · 连接正常 · \(relativeDurationText(idleSeconds))无新事件",
                tone: .warning,
                systemImage: "exclamationmark.triangle"
            )
        case .connecting:
            return RuntimeActivityDisplay(
                detailText: "\(runningText) · 正在重连 · 无法确认运行状态",
                tone: .warning,
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .disconnected, .failed:
            return RuntimeActivityDisplay(
                detailText: "\(runningText) · 连接断开 · 无法确认运行状态",
                tone: .warning,
                systemImage: "wifi.slash"
            )
        case .terminated(let reason):
            return RuntimeActivityDisplay(
                detailText: "\(runningText) · \(reason.title) · 无法确认运行状态",
                tone: .warning,
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        }
    }

    static func compactClockDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = seconds / 60 % 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func relativeDurationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 {
            return "\(seconds) 秒"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes) 分钟" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) 小时" : "\(hours)h \(remainingMinutes)m"
    }
}

extension AgentSession {
    func displayStatus(foregroundActivity: SessionForegroundActivity?) -> AgentSessionDisplayStatus {
        // 侧栏和对话顶部共用这套优先级，避免同一个会话在不同入口显示成两种状态。
        // 审批/输入是需要用户处理的状态，优先级高于流式输出；foreground activity 负责区分等待回复和正在回复。
        if status == SessionStatus.waitingForApproval.rawValue || pendingApproval != nil {
            return AgentSessionDisplayStatus(title: "待审批", systemImage: "checkmark.seal.fill", tone: .warning, showsSpinner: false)
        }
        if status == SessionStatus.waitingForInput.rawValue || pendingUserInput != nil {
            return AgentSessionDisplayStatus(title: "待输入", systemImage: "keyboard", tone: .warning, showsSpinner: false)
        }
        if let foregroundActivity {
            return foregroundActivity.displayStatus
        }
        if activeTurnID != nil {
            return AgentSessionDisplayStatus(title: "处理中", systemImage: "bolt.fill", tone: .active, showsSpinner: false)
        }

        switch status {
        case SessionStatus.running.rawValue:
            return AgentSessionDisplayStatus(title: "运行中", systemImage: "circle.dotted", tone: .active, showsSpinner: true)
        case SessionStatus.history.rawValue:
            return AgentSessionDisplayStatus(title: "历史", systemImage: "clock.arrow.circlepath", tone: .neutral, showsSpinner: false)
        case SessionStatus.completed.rawValue:
            return AgentSessionDisplayStatus(title: "完成", systemImage: "checkmark.circle", tone: .complete, showsSpinner: false)
        case SessionStatus.failed.rawValue:
            return AgentSessionDisplayStatus(title: "失败", systemImage: "exclamationmark.triangle.fill", tone: .danger, showsSpinner: false)
        case SessionStatus.closed.rawValue:
            return AgentSessionDisplayStatus(title: "已结束", systemImage: "checkmark.circle", tone: .neutral, showsSpinner: false)
        case SessionStatus.idle.rawValue:
            return AgentSessionDisplayStatus(title: "空闲", systemImage: "pause.circle", tone: .neutral, showsSpinner: false)
        case SessionStatus.unknown.rawValue, "":
            return AgentSessionDisplayStatus(title: "状态待确认", systemImage: "circle", tone: .neutral, showsSpinner: false)
        default:
            let text = status.replacingOccurrences(of: "_", with: " ")
            return AgentSessionDisplayStatus(title: text, systemImage: "circle", tone: .neutral, showsSpinner: false)
        }
    }

    func statusBadges(foregroundActivity: SessionForegroundActivity?) -> [AgentSessionStatusBadge] {
        var badges: [AgentSessionStatusBadge] = []
        if activeTurnID != nil {
            badges.append(AgentSessionStatusBadge(id: "active-turn", title: "回合处理中", systemImage: "bolt.fill", tone: .active))
        }
        if let approval = pendingApproval {
            badges.append(AgentSessionStatusBadge(id: "approval-\(approval.id)", title: "审批 \(approval.title)", systemImage: "checkmark.seal", tone: .warning))
        } else if let userInput = pendingUserInput {
            badges.append(AgentSessionStatusBadge(id: "input-\(userInput.id)", title: "引导 \(userInput.title)", systemImage: "questionmark.bubble", tone: .warning))
        } else if status == SessionStatus.waitingForInput.rawValue {
            badges.append(AgentSessionStatusBadge(id: "waiting-input", title: "等待输入", systemImage: "keyboard", tone: .warning))
        }
        if let foregroundActivity {
            badges.append(AgentSessionStatusBadge(id: "foreground-\(foregroundActivity.title)", title: foregroundActivity.title, systemImage: foregroundActivity.displayStatus.systemImage, tone: foregroundActivity.displayStatus.tone))
        }
        if let goal {
            badges.append(AgentSessionStatusBadge(id: "goal-\(goal.threadID)-\(goal.status.rawValue)", title: "目标 \(goal.sidebarProgressText)", systemImage: "target", tone: goal.status.sessionStatusTone))
        }
        if let usage = usage?.compactText {
            badges.append(AgentSessionStatusBadge(id: "usage-\(usage)", title: usage, systemImage: "gauge.with.dots.needle.33percent", tone: .neutral))
        }
        if let rateLimit = rateLimit?.compactText {
            badges.append(AgentSessionStatusBadge(id: "rate-\(rateLimit)", title: rateLimit, systemImage: "speedometer", tone: .neutral))
        }
        return badges
    }
}

enum ThreadGoalStatus: String, Codable, Hashable, CaseIterable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    var displayText: String {
        switch self {
        case .active:
            return "运行中"
        case .paused:
            return "已暂停"
        case .blocked:
            return "已阻塞"
        case .usageLimited:
            return "用量受限"
        case .budgetLimited:
            return "预算用尽"
        case .complete:
            return "已完成"
        }
    }

    var tintRole: String {
        switch self {
        case .active:
            return "success"
        case .blocked, .usageLimited, .budgetLimited:
            return "warning"
        case .complete:
            return "complete"
        case .paused:
            return "neutral"
        }
    }

    var sessionStatusTone: AgentSessionStatusTone {
        switch self {
        case .active:
            return .active
        case .blocked, .usageLimited, .budgetLimited:
            return .warning
        case .complete:
            return .complete
        case .paused:
            return .neutral
        }
    }
}

struct ThreadGoal: Identifiable, Codable, Hashable {
    var id: String { threadID }

    let threadID: SessionID
    let objective: String
    let status: ThreadGoalStatus
    let tokenBudget: Int64?
    let tokensUsed: Int64
    let timeUsedSeconds: Int64
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case objective
        case status
        case tokenBudget
        case tokensUsed
        case timeUsedSeconds
        case createdAt
        case updatedAt
    }

    private enum SnakeCodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case tokenBudget = "token_budget"
        case tokensUsed = "tokens_used"
        case timeUsedSeconds = "time_used_seconds"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        threadID: SessionID,
        objective: String,
        status: ThreadGoalStatus,
        tokenBudget: Int64? = nil,
        tokensUsed: Int64 = 0,
        timeUsedSeconds: Int64 = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(object: [String: CodexAppServerJSONValue]) {
        guard
            let threadID = object["threadId"]?.stringValue ?? object["thread_id"]?.stringValue,
            let rawObjective = object["objective"]?.stringValue,
            let rawStatus = object["status"]?.stringValue,
            let status = ThreadGoalStatus(rawValue: rawStatus)
        else {
            return nil
        }
        let objective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, !objective.isEmpty else {
            return nil
        }
        self.init(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: Self.int64(from: object["tokenBudget"] ?? object["token_budget"]),
            tokensUsed: Self.int64(from: object["tokensUsed"] ?? object["tokens_used"]) ?? 0,
            timeUsedSeconds: Self.int64(from: object["timeUsedSeconds"] ?? object["time_used_seconds"]) ?? 0,
            createdAt: Self.date(from: object["createdAt"] ?? object["created_at"]),
            updatedAt: Self.date(from: object["updatedAt"] ?? object["updated_at"])
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snake = try decoder.container(keyedBy: SnakeCodingKeys.self)
        self.threadID = try container.decodeIfPresent(SessionID.self, forKey: .threadID)
            ?? snake.decode(SessionID.self, forKey: .threadID)
        self.objective = try container.decode(String.self, forKey: .objective)
        self.status = try container.decode(ThreadGoalStatus.self, forKey: .status)
        self.tokenBudget = try container.decodeIfPresent(Int64.self, forKey: .tokenBudget)
            ?? snake.decodeIfPresent(Int64.self, forKey: .tokenBudget)
        self.tokensUsed = try container.decodeIfPresent(Int64.self, forKey: .tokensUsed)
            ?? snake.decodeIfPresent(Int64.self, forKey: .tokensUsed)
            ?? 0
        self.timeUsedSeconds = try container.decodeIfPresent(Int64.self, forKey: .timeUsedSeconds)
            ?? snake.decodeIfPresent(Int64.self, forKey: .timeUsedSeconds)
            ?? 0
        self.createdAt = try Self.decodeFlexibleDate(container, key: .createdAt)
            ?? Self.decodeFlexibleDate(snake, key: .createdAt)
        self.updatedAt = try Self.decodeFlexibleDate(container, key: .updatedAt)
            ?? Self.decodeFlexibleDate(snake, key: .updatedAt)
    }

    var progressText: String {
        guard let tokenBudget else {
            return "\(Self.compactNumber(tokensUsed)) tokens"
        }
        return "\(Self.compactNumber(tokensUsed)) / \(Self.compactNumber(tokenBudget)) tokens"
    }

    var budgetProgressFraction: Double? {
        guard let tokenBudget, tokenBudget > 0 else {
            return nil
        }
        // 进度条只接受 0...1；百分比另算，保留超预算的真实比例提示。
        let ratio = Double(max(0, tokensUsed)) / Double(tokenBudget)
        return min(max(ratio, 0), 1)
    }

    var budgetPercentText: String? {
        guard let tokenBudget, tokenBudget > 0 else {
            return nil
        }
        let ratio = Double(max(0, tokensUsed)) / Double(tokenBudget)
        return "\(Int((ratio * 100).rounded()))%"
    }

    var sidebarProgressText: String {
        if let budgetPercentText {
            return "\(status.displayText) \(budgetPercentText)"
        }
        return status.displayText
    }

    var elapsedText: String {
        Self.durationText(seconds: timeUsedSeconds)
    }

    private static func int64(from value: CodexAppServerJSONValue?) -> Int64? {
        switch value {
        case .int(let number):
            return number
        case .double(let number):
            return number.isFinite ? Int64(number) : nil
        case .string(let text):
            return Int64(text)
        default:
            return nil
        }
    }

    private static func date(from value: CodexAppServerJSONValue?) -> Date? {
        switch value {
        case .int(let number):
            return date(fromNumericSeconds: Double(number))
        case .double(let number):
            return date(fromNumericSeconds: number)
        case .string(let text):
            return date(from: text)
        default:
            return nil
        }
    }

    private static func date(from text: String) -> Date? {
        if let number = Double(text) {
            return date(fromNumericSeconds: number)
        }
        if let date = iso8601Fractional.date(from: text) ?? iso8601.date(from: text) {
            return date
        }
        return nil
    }

    private static func date(fromNumericSeconds value: Double) -> Date? {
        guard value.isFinite, value > 0 else {
            return nil
        }
        // app-server 版本可能用秒，也可能经 JSON 桥接成毫秒；这里按数量级兼容。
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func decodeFlexibleDate<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        key: K
    ) throws -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) {
            return date(fromNumericSeconds: number)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return date(from: text)
        }
        return nil
    }

    private static func compactNumber(_ value: Int64) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func durationText(seconds: Int64) -> String {
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(max(0, seconds))s"
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct CodexHistoryMessage: Identifiable, Codable, Hashable {
    var id: MessageID
    let role: String
    let kind: MessageKind
    let content: String
    let turnPayload: CodexAppServerTurnPayload?
    let activityPayload: ConversationActivityPayload?
    let createdAt: Date?
    let updatedAt: Date?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let seq: EventSequence?
    let revision: ModelRevision?
    let sendStatus: MessageSendStatus?
    let timelineOrdinal: Int64?
    let userDelivery: UserMessageDelivery?
    let isTimestampFallback: Bool

    init(
        id: MessageID = UUID().uuidString,
        role: String,
        kind: MessageKind = .message,
        content: String,
        turnPayload: CodexAppServerTurnPayload? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        createdAt: Date?,
        updatedAt: Date? = nil,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision? = nil,
        sendStatus: MessageSendStatus? = nil,
        timelineOrdinal: Int64? = nil,
        userDelivery: UserMessageDelivery? = nil,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.turnPayload = turnPayload
        self.activityPayload = activityPayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
        self.timelineOrdinal = timelineOrdinal
        self.userDelivery = userDelivery
        self.isTimestampFallback = isTimestampFallback
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case kind
        case content
        case turnPayload = "turn_payload"
        case activityPayload = "activity_payload"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case clientMessageID = "client_message_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case seq
        case revision
        case sendStatus = "send_status"
        case timelineOrdinal = "timeline_ordinal"
        case userDelivery = "user_delivery"
        case isTimestampFallback = "is_timestamp_fallback"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        let content = try container.decode(String.self, forKey: .content)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        let clientMessageID = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID)
        self.init(
            id: try container.decodeIfPresent(MessageID.self, forKey: .id) ?? clientMessageID ?? UUID().uuidString,
            role: role,
            kind: try container.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .message,
            content: content,
            turnPayload: try container.decodeIfPresent(CodexAppServerTurnPayload.self, forKey: .turnPayload),
            activityPayload: try container.decodeIfPresent(ConversationActivityPayload.self, forKey: .activityPayload),
            createdAt: createdAt,
            updatedAt: updatedAt,
            clientMessageID: clientMessageID,
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            sendStatus: try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus),
            timelineOrdinal: try container.decodeIfPresent(Int64.self, forKey: .timelineOrdinal),
            userDelivery: try container.decodeIfPresent(UserMessageDelivery.self, forKey: .userDelivery),
            isTimestampFallback: try container.decodeIfPresent(Bool.self, forKey: .isTimestampFallback) ?? false
        )
    }

    func withTimestampFallback(createdAt: Date, updatedAt: Date? = nil) -> CodexHistoryMessage {
        CodexHistoryMessage(
            id: id,
            role: role,
            kind: kind,
            content: content,
            turnPayload: turnPayload,
            activityPayload: activityPayload,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            clientMessageID: clientMessageID,
            turnID: turnID,
            itemID: itemID,
            seq: seq,
            revision: revision,
            sendStatus: sendStatus,
            timelineOrdinal: timelineOrdinal,
            userDelivery: userDelivery,
            isTimestampFallback: true
        )
    }
}

struct ConversationMessageRenderFingerprint: Hashable {
    let contentRevision: UInt64
    let contentDigest: UInt64
    let contentByteCount: Int
}

enum ConversationImageItemProjection {
    static func markdownContent(from item: [String: CodexAppServerJSONValue]) -> String? {
        let title: String
        let source: String?
        switch item["type"]?.stringValue {
        case "imageGeneration":
            title = "生成的图片"
            let result = item["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            // gateway 会把生成图的大段 base64 改写成短 history-media URL；若改写被关闭，
            // 优先回退 savedPath，避免再把 1-2 MB base64 塞进 Markdown 和 SwiftUI diff。
            source = result.flatMap(supportedImageSource) ?? firstNonEmptyPath(in: item, keys: ["savedPath", "saved_path"])
        case "imageView":
            title = "截图"
            source = firstNonEmptyPath(in: item, keys: ["path"])
        default:
            return nil
        }
        guard let source else {
            return nil
        }
        let destination = source.hasPrefix("/") ? URL(fileURLWithPath: source).absoluteString : source
        return "![\(title)](\(destination))"
    }

    private static func supportedImageSource(_ value: String) -> String? {
        guard !value.isEmpty else {
            return nil
        }
        if value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil ||
            value.hasPrefix("agentd-history-media://") ||
            value.hasPrefix("/") {
            return value
        }
        guard let scheme = URL(string: value)?.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else {
            return nil
        }
        return value
    }

    private static func firstNonEmptyPath(
        in item: [String: CodexAppServerJSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = item[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct MessageRenderPlan: Hashable {
    let messageKey: String
    let content: String
    let contentDigest: UInt64
    let contentByteCount: Int
    let blocks: [MarkdownBlock]
    let openTailByteOffset: Int

    var isSinglePlainParagraph: Bool {
        guard blocks.count == 1, case let .paragraph(inline) = blocks[0].kind else {
            return false
        }
        return !inline.hasFormatting
    }
}

@MainActor
final class MessageRenderPlanCache {
    static let shared = MessageRenderPlanCache()

    private let limit: Int
    private var plansByMessageKey: [String: MessageRenderPlan] = [:]
    private var accessOrder: [String] = []

#if DEBUG
    private(set) var incrementalReuseCountForTesting = 0
#endif

    init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    func plan(for message: ConversationMessage) -> MessageRenderPlan {
        let messageKey = message.stableID ?? message.clientMessageID ?? message.id.uuidString
        return plan(
            messageKey: messageKey,
            content: message.content,
            contentDigest: message.contentDigest,
            contentByteCount: message.contentByteCount
        )
    }

    func plan(messageKey: String, content: String, contentDigest: UInt64, contentByteCount: Int) -> MessageRenderPlan {
        if let cached = plansByMessageKey[messageKey],
           cached.contentDigest == contentDigest,
           cached.contentByteCount == contentByteCount {
            touch(messageKey)
            return cached
        }

        let plan: MessageRenderPlan
        if let cached = plansByMessageKey[messageKey],
           content.hasPrefix(cached.content),
           content.count >= cached.content.count {
            plan = extend(cached, content: content, contentDigest: contentDigest, contentByteCount: contentByteCount)
#if DEBUG
            incrementalReuseCountForTesting += 1
#endif
        } else {
            plan = parse(messageKey: messageKey, content: content, contentDigest: contentDigest, contentByteCount: contentByteCount)
        }

        plansByMessageKey[messageKey] = plan
        touch(messageKey)
        trimIfNeeded()
        return plan
    }

    private func extend(
        _ cached: MessageRenderPlan,
        content: String,
        contentDigest: UInt64,
        contentByteCount: Int
    ) -> MessageRenderPlan {
        guard content != cached.content else {
            return MessageRenderPlan(
                messageKey: cached.messageKey,
                content: content,
                contentDigest: contentDigest,
                contentByteCount: contentByteCount,
                blocks: cached.blocks,
                openTailByteOffset: cached.openTailByteOffset
            )
        }

        let safeTailStart = min(cached.openTailByteOffset, contentByteCount)
        // 只复用稳定前缀块，尾部开放块交给 swift-markdown 重算；
        // 这样列表续行、表格分隔行、未闭合代码围栏都能在下一帧自然收敛。
        let reusableBlocks = cached.blocks.filter { block in
            guard let range = block.sourceByteRange else {
                return false
            }
            return range.upperBound > range.lowerBound && range.upperBound <= safeTailStart
        }
        let tail = String(decoding: content.utf8.dropFirst(safeTailStart), as: UTF8.self)
        let parsedTail = MarkdownParser.shared.parse(tail, baseByteOffset: safeTailStart)
        let mergedBlocks = renumber(reusableBlocks + parsedTail.blocks)

        return MessageRenderPlan(
            messageKey: cached.messageKey,
            content: content,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount,
            blocks: mergedBlocks,
            openTailByteOffset: parsedTail.openTailByteOffset
        )
    }

    private func parse(messageKey: String, content: String, contentDigest: UInt64, contentByteCount: Int) -> MessageRenderPlan {
        let parsed = MarkdownParser.shared.parse(content)
        return MessageRenderPlan(
            messageKey: messageKey,
            content: content,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount,
            blocks: parsed.blocks,
            openTailByteOffset: parsed.openTailByteOffset
        )
    }

    private func renumber(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        blocks.enumerated().map { index, block in
            MarkdownBlock(id: index, sourceByteRange: block.sourceByteRange, kind: block.kind)
        }
    }

    private func touch(_ messageKey: String) {
        accessOrder.removeAll { $0 == messageKey }
        accessOrder.append(messageKey)
    }

    private func trimIfNeeded() {
        while accessOrder.count > limit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            plansByMessageKey.removeValue(forKey: oldest)
        }
    }
}

struct ConversationFileReference: Identifiable, Hashable {
    let path: String
    let name: String

    var id: String { path }
}

enum ConversationFileReferenceDetector {
    private static let previewExtensions: Set<String> = [
        "csv", "doc", "docx", "gif", "heic", "html", "jpeg", "jpg", "json", "log",
        "md", "numbers", "pages", "pdf", "png", "ppt", "pptx", "rtf", "txt", "webp",
        "xls", "xlsx", "yaml", "yml", "zip"
    ]
    private static let imageExtensions: Set<String> = ["gif", "heic", "jpeg", "jpg", "png", "webp"]
    private static let edgeTrimCharacters = CharacterSet(charactersIn: "`\"'“”‘’()[]{}<>.,;")
    private static let pathStartBoundaryCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’([{<：:，,;；"))
    private static let candidateStopCharacters = CharacterSet.newlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’<>"))
    private static let extensionTerminatorCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "`\"'“”‘’()[]{}<>,;:.!?。！？、，；："))

    static func references(in text: String, limit: Int = 5) -> [ConversationFileReference] {
        references(in: text, limit: limit, allowedExtensions: previewExtensions)
    }

    static func imageReferences(in text: String, limit: Int = 5) -> [ConversationFileReference] {
        references(in: text, limit: limit, allowedExtensions: imageExtensions)
    }

    private static func references(
        in text: String,
        limit: Int,
        allowedExtensions: Set<String>
    ) -> [ConversationFileReference] {
        guard limit > 0 else {
            return []
        }

        var result: [ConversationFileReference] = []
        var seen = Set<String>()
        for candidate in pathCandidates(in: text, allowedExtensions: allowedExtensions) {
            guard let path = normalizedPathCandidate(candidate) else {
                continue
            }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard allowedExtensions.contains(ext), seen.insert(path).inserted else {
                continue
            }
            result.append(ConversationFileReference(path: path, name: URL(fileURLWithPath: path).lastPathComponent))
            if result.count >= limit {
                break
            }
        }
        return result
    }

    private static func pathCandidates(in text: String, allowedExtensions: Set<String>) -> [String] {
        let extensions = allowedExtensions
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }

        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isPathStart(in: text, at: index) else {
                index = text.index(after: index)
                continue
            }

            if let candidate = pathCandidate(in: text, start: index, allowedExtensions: extensions) {
                result.append(candidate.value)
                index = candidate.end
            } else {
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func pathCandidate(
        in text: String,
        start: String.Index,
        allowedExtensions: [String]
    ) -> (value: String, end: String.Index)? {
        var index = start
        while index < text.endIndex {
            if index != start, isPathStart(in: text, at: index) {
                return nil
            }

            let character = text[index]
            if characterBelongsToSet(character, candidateStopCharacters) {
                return nil
            }

            if character == "." {
                let extensionStart = text.index(after: index)
                for ext in allowedExtensions where hasCaseInsensitivePrefix(ext, in: text, at: extensionStart) {
                    guard let extensionEnd = text.index(extensionStart, offsetBy: ext.count, limitedBy: text.endIndex),
                          isExtensionTerminator(in: text, at: extensionEnd)
                    else {
                        continue
                    }
                    return (String(text[start..<extensionEnd]), extensionEnd)
                }
            }

            index = text.index(after: index)
        }
        return nil
    }

    private static func isPathStart(in text: String, at index: String.Index) -> Bool {
        guard hasPathStartBoundary(in: text, at: index) else {
            return false
        }
        if hasCaseInsensitivePrefix("file://", in: text, at: index) {
            return true
        }
        guard text[index] == "/" else {
            return false
        }
        let nextIndex = text.index(after: index)
        if nextIndex < text.endIndex, text[nextIndex] == "/" {
            return false
        }
        return true
    }

    private static func hasPathStartBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }
        let previousIndex = text.index(before: index)
        return characterBelongsToSet(text[previousIndex], pathStartBoundaryCharacters)
    }

    private static func isExtensionTerminator(in text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else {
            return true
        }
        let character = text[index]
        return character == "?"
            || character == "#"
            || characterBelongsToSet(character, extensionTerminatorCharacters)
    }

    private static func hasCaseInsensitivePrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        guard let end = text.index(index, offsetBy: prefix.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == prefix.lowercased()
    }

    private static func characterBelongsToSet(_ character: Character, _ set: CharacterSet) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return set.contains(scalar)
    }

    private static func normalizedPathCandidate(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: edgeTrimCharacters)
        guard !token.isEmpty else {
            return nil
        }
        if let queryIndex = token.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            token = String(token[..<queryIndex])
        }
        if token.lowercased().hasPrefix("file://") {
            let rawPath = String(token.dropFirst("file://".count))
            if rawPath.hasPrefix("/") {
                token = rawPath.removingPercentEncoding ?? rawPath
            } else {
                guard let url = URL(string: token), url.isFileURL else {
                    return nil
                }
                token = url.path
            }
        }
        token = stripLineSuffix(from: token)
        guard token.hasPrefix("/"), token.count > 1, !token.contains("\u{0}") else {
            return nil
        }
        return token.replacingOccurrences(of: "\\ ", with: " ")
    }

    private static func stripLineSuffix(from token: String) -> String {
        guard let colonIndex = token.lastIndex(of: ":") else {
            return token
        }
        let suffix = token[token.index(after: colonIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
            return token
        }
        return String(token[..<colonIndex])
    }
}

struct ConversationMessage: Identifiable, Hashable {
    enum Role: String {
        case user
        case assistant
        case system
    }

    let id: UUID
    var stableID: MessageID?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    var role: Role
    var kind: MessageKind
    var content: String {
        didSet {
            updateRenderFingerprint()
        }
    }
    var createdAt: Date
    var updatedAt: Date?
    var sendStatus: MessageSendStatus
    var revision: ModelRevision?
    var turnPayload: CodexAppServerTurnPayload?
    var activityPayload: ConversationActivityPayload?
    var timelineOrdinal: Int64?
    var userDelivery: UserMessageDelivery?
    var isTimestampFallback: Bool
    private(set) var contentRevision: UInt64
    private(set) var contentDigest: UInt64
    private(set) var contentByteCount: Int

    var renderFingerprint: ConversationMessageRenderFingerprint {
        ConversationMessageRenderFingerprint(
            contentRevision: contentRevision,
            contentDigest: contentDigest,
            contentByteCount: contentByteCount
        )
    }

    init(
        id: UUID = UUID(),
        stableID: MessageID? = nil,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        role: Role,
        kind: MessageKind = .message,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        sendStatus: MessageSendStatus = .sent,
        revision: ModelRevision? = nil,
        turnPayload: CodexAppServerTurnPayload? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        timelineOrdinal: Int64? = nil,
        userDelivery: UserMessageDelivery? = nil,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.stableID = stableID
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.role = role
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sendStatus = sendStatus
        self.revision = revision
        self.turnPayload = turnPayload
        self.activityPayload = activityPayload
        self.timelineOrdinal = timelineOrdinal
        self.userDelivery = userDelivery
        self.isTimestampFallback = isTimestampFallback
        let fingerprint = Self.makeRenderFingerprint(for: content)
        self.contentRevision = 0
        self.contentDigest = fingerprint.digest
        self.contentByteCount = fingerprint.byteCount
    }

    static func == (lhs: ConversationMessage, rhs: ConversationMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.stableID == rhs.stableID
            && lhs.clientMessageID == rhs.clientMessageID
            && lhs.turnID == rhs.turnID
            && lhs.itemID == rhs.itemID
            && lhs.role == rhs.role
            && lhs.kind == rhs.kind
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.sendStatus == rhs.sendStatus
            && lhs.revision == rhs.revision
            && lhs.turnPayload == rhs.turnPayload
            && lhs.activityPayload == rhs.activityPayload
            && lhs.timelineOrdinal == rhs.timelineOrdinal
            && lhs.userDelivery == rhs.userDelivery
            && lhs.isTimestampFallback == rhs.isTimestampFallback
            && lhs.contentDigest == rhs.contentDigest
            && lhs.contentByteCount == rhs.contentByteCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(stableID)
        hasher.combine(clientMessageID)
        hasher.combine(turnID)
        hasher.combine(itemID)
        hasher.combine(role)
        hasher.combine(kind)
        hasher.combine(createdAt)
        hasher.combine(updatedAt)
        hasher.combine(sendStatus)
        hasher.combine(revision)
        hasher.combine(turnPayload)
        hasher.combine(activityPayload)
        hasher.combine(timelineOrdinal)
        hasher.combine(userDelivery)
        hasher.combine(isTimestampFallback)
        hasher.combine(contentDigest)
        hasher.combine(contentByteCount)
    }

    private mutating func updateRenderFingerprint() {
        let fingerprint = Self.makeRenderFingerprint(for: content)
        contentRevision &+= 1
        contentDigest = fingerprint.digest
        contentByteCount = fingerprint.byteCount
    }

    private static func makeRenderFingerprint(for content: String) -> (digest: UInt64, byteCount: Int) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var count = 0
        // 内容变化时生成固定大小 fingerprint，供 SwiftUI row diff 使用；
        // 避免长消息在每次 Equatable 比较里反复扫描整段 content。
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
            count += 1
        }
        return (hash, count)
    }
}

enum SessionStatus: String, Codable, Hashable {
    case history
    case idle
    case running
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case completed
    case failed
    case closed
    case unknown
}

enum MessageRole: String, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
}

enum MessageKind: String, Codable, Hashable {
    case message
    case commentary
    case plan
    case reasoningSummary = "reasoning_summary"
    case commandSummary = "command_summary"
    case fileChangeSummary = "file_change_summary"
    case approval
    case userInput = "user_input"
    case error
}

enum MessageSendStatus: String, Codable, Hashable {
    case local
    case sending
    case sent
    case failed
    case confirmed
}

enum UserMessageDelivery: String, Codable, Hashable {
    case queued
    case guided
    case injected
}

enum ConversationActivityCategory: String, Codable, Hashable {
    case thinking
    case plan
    case runCommand = "run_command"
    case editFile = "edit_file"
    case toolCall = "tool_call"
    case error
}

struct ConversationActivityPayload: Codable, Hashable {
    let category: ConversationActivityCategory
    let displayTitle: String
    let subtitle: String?
    let status: String?
    let command: String?
    let cwd: String?
    let toolName: String?
    let filePaths: [String]
    let exitCode: Int?
    let outputPreview: String?
    let outputDigest: UInt64?
    let outputByteCount: Int?

    enum CodingKeys: String, CodingKey {
        case category
        case displayTitle = "display_title"
        case subtitle
        case status
        case command
        case cwd
        case toolName = "tool_name"
        case filePaths = "file_paths"
        case exitCode = "exit_code"
        case outputPreview = "output_preview"
        case outputDigest = "output_digest"
        case outputByteCount = "output_byte_count"
    }

    init(
        category: ConversationActivityCategory,
        displayTitle: String,
        subtitle: String? = nil,
        status: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        toolName: String? = nil,
        filePaths: [String] = [],
        exitCode: Int? = nil,
        outputPreview: String? = nil,
        outputDigest: UInt64? = nil,
        outputByteCount: Int? = nil
    ) {
        self.category = category
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.status = status
        self.command = command
        self.cwd = cwd
        self.toolName = toolName
        self.filePaths = filePaths
        self.exitCode = exitCode
        self.outputPreview = outputPreview
        self.outputDigest = outputDigest
        self.outputByteCount = outputByteCount
    }

    init?(item: [String: CodexAppServerJSONValue]) {
        guard let type = Self.firstString(in: item, keys: ["type"]) else {
            return nil
        }
        switch type {
        case "plan":
            guard let text = Self.firstString(in: item, keys: ["text"])?.trimmedNonEmpty else {
                return nil
            }
            self.init(category: .plan, displayTitle: "计划", subtitle: text)

        case "reasoning":
            let text = Self.reasoningText(from: item)
            guard !text.isEmpty else {
                return nil
            }
            self.init(category: .thinking, displayTitle: "推理摘要", subtitle: text)

        case "commandExecution":
            let command = Self.firstString(in: item, keys: ["command", "processId"])?.trimmedNonEmpty ?? "命令执行"
            let actionTitle = Self.commandActionTitle(from: item["commandActions"]?.arrayValue)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty
            let cwd = Self.firstString(in: item, keys: ["cwd"])?.trimmedNonEmpty
            let output = Self.firstString(in: item, keys: ["aggregatedOutput"])?.trimmedNonEmpty
            let outputDigest = output.map(Self.stableDigest)
            let outputByteCount = output?.utf8.count
            self.init(
                category: .runCommand,
                displayTitle: actionTitle ?? "运行 \(command)",
                subtitle: cwd,
                status: status,
                command: command,
                cwd: cwd,
                exitCode: Self.firstInt(in: item, keys: ["exitCode"]),
                outputPreview: output.map { Self.truncatedText($0, limit: Self.outputPreviewLimit) },
                outputDigest: outputDigest,
                outputByteCount: outputByteCount
            )

        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let filePaths = Self.filePaths(from: changes)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty ?? "modified"
            let summary = filePaths.first.map(Self.shortPath) ?? "工作区"
            let title = filePaths.count > 1 ? "修改 \(filePaths.count) 个文件" : "修改 \(summary)"
            self.init(category: .editFile, displayTitle: title, subtitle: status, status: status, filePaths: filePaths)

        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch":
            let identifier = Self.toolIdentifier(from: item, type: type)
            let title = Self.toolTitle(from: item, type: type)
            let status = Self.firstString(in: item, keys: ["status"])?.trimmedNonEmpty
            self.init(
                category: .toolCall,
                displayTitle: title,
                subtitle: nil,
                status: status,
                toolName: identifier
            )

        default:
            return nil
        }
    }

    var messageKind: MessageKind {
        switch category {
        case .thinking:
            return .reasoningSummary
        case .plan:
            return .plan
        case .runCommand, .toolCall:
            return .commandSummary
        case .editFile:
            return .fileChangeSummary
        case .error:
            return .error
        }
    }

    var summaryText: String {
        switch category {
        case .thinking, .plan:
            return subtitle ?? displayTitle
        case .runCommand:
            return commandSummaryText
        case .editFile:
            return fileChangeSummaryText
        case .toolCall:
            return toolSummaryText
        case .error:
            return subtitle ?? displayTitle
        }
    }

    /// 协议状态保留原值用于诊断；会话时间线只显示稳定、可理解的用户状态。
    /// 未知或未来新增状态不应直接泄漏成 `unknown` 或内部枚举名。
    var displayStatusText: String? {
        switch normalizedStatus {
        case "completed", "complete", "success", "succeeded":
            return "已完成"
        case "failed", "failure", "error":
            return "失败"
        case "inprogress", "running", "started":
            return "进行中"
        case "pending", "queued":
            return "等待中"
        case "cancelled", "canceled":
            return "已取消"
        case "modified":
            return "已修改"
        case "added", "created":
            return "已新增"
        case "deleted", "removed":
            return "已删除"
        default:
            return nil
        }
    }

    var isInProgress: Bool {
        switch normalizedStatus {
        case "inprogress", "running", "started":
            return true
        default:
            return false
        }
    }

    var isFailure: Bool {
        if let exitCode, exitCode != 0 {
            return true
        }
        switch normalizedStatus {
        case "failed", "failure", "error":
            return true
        default:
            return false
        }
    }

    /// 过程行不是 Markdown 正文。这里移除最常见的强调和行内代码标记，
    /// 避免把格式符号当成运行日志打印，同时保留原始 payload 供详情和诊断使用。
    static func plainProgressText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var value = String(line).trimmingCharacters(in: .whitespaces)
                for level in (1...6).reversed() {
                    let headingPrefix = String(repeating: "#", count: level) + " "
                    if value.hasPrefix(headingPrefix) {
                        value.removeFirst(headingPrefix.count)
                        break
                    }
                }
                if value.count >= 2,
                   let marker = value.first,
                   (marker == "*" || marker == "_"),
                   value.last == marker {
                    value.removeFirst()
                    value.removeLast()
                }
                return value
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func == (lhs: ConversationActivityPayload, rhs: ConversationActivityPayload) -> Bool {
        lhs.category == rhs.category
            && lhs.displayTitle == rhs.displayTitle
            && lhs.subtitle == rhs.subtitle
            && lhs.status == rhs.status
            && lhs.command == rhs.command
            && lhs.cwd == rhs.cwd
            && lhs.toolName == rhs.toolName
            && lhs.filePaths == rhs.filePaths
            && lhs.exitCode == rhs.exitCode
            && lhs.outputDigest == rhs.outputDigest
            && lhs.outputByteCount == rhs.outputByteCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(category)
        hasher.combine(displayTitle)
        hasher.combine(subtitle)
        hasher.combine(status)
        hasher.combine(command)
        hasher.combine(cwd)
        hasher.combine(toolName)
        hasher.combine(filePaths)
        hasher.combine(exitCode)
        hasher.combine(outputDigest)
        hasher.combine(outputByteCount)
    }

    private var commandSummaryText: String {
        let command = command?.trimmedNonEmpty ?? displayTitle
        var lines = ["命令：\(command)"]
        if let cwd {
            lines.append("目录：\(cwd)")
        }
        let statusLine = [displayStatusText.map { "状态：\($0)" }, exitCode.map { "退出码：\($0)" }]
            .compactMap { $0 }
            .joined(separator: "，")
        if !statusLine.isEmpty {
            lines.append(statusLine)
        }
        if let outputPreview {
            lines.append("输出：\n\(outputPreview)")
        }
        return lines.joined(separator: "\n")
    }

    private var fileChangeSummaryText: String {
        let summary = filePaths.isEmpty ? (displayTitle.replacingOccurrences(of: "修改 ", with: "")) : Self.compactFileSummary(filePaths)
        guard let displayStatusText else {
            return "文件变更：\(summary)"
        }
        return "文件变更：\(summary) \(displayStatusText)"
    }

    private var toolSummaryText: String {
        guard let displayStatusText else {
            return "工具：\(displayTitle)"
        }
        return "工具：\(displayTitle)\n状态：\(displayStatusText)"
    }

    private var normalizedStatus: String {
        (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static let outputPreviewLimit = 1_000

    private static func reasoningText(from item: [String: CodexAppServerJSONValue]) -> String {
        let summary = item["summary"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(\.trimmedNonEmpty) ?? []
        if let latestSummary = summary.last {
            // app-server 会持续把新的 summary part 追加到同一个 reasoning item；
            // 原生客户端用最新 part 作为当前阶段标题，而不是把历史标题全部铺开。
            return latestSummary
        }
        let content = item["content"]?.arrayValue?
            .compactMap(\.stringValue)
            .compactMap(\.trimmedNonEmpty) ?? []
        return content.last ?? ""
    }

    private static func commandActionTitle(from actions: [CodexAppServerJSONValue]?) -> String? {
        for action in actions?.compactMap(\.objectValue) ?? [] {
            if let query = firstString(in: action, keys: ["query"])?.trimmedNonEmpty {
                return "搜索 \(query)"
            }
            let name = firstString(in: action, keys: ["name", "type", "kind"])?.trimmedNonEmpty
            let path = firstString(in: action, keys: ["path", "file", "filePath", "relativePath"])?.trimmedNonEmpty
            if let path {
                let verb = localizedActionVerb(name)
                return "\(verb) \(shortPath(path))"
            }
            if let name {
                return localizedActionVerb(name)
            }
        }
        return nil
    }

    private static func localizedActionVerb(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view", "open", "cat":
            return "查看"
        case "search", "grep", "rg", "find":
            return "搜索"
        case "list", "ls":
            return "列出"
        case let value? where !value.isEmpty:
            return value
        default:
            return "查看"
        }
    }

    private static func toolTitle(from item: [String: CodexAppServerJSONValue], type: String) -> String {
        if type == "webSearch" {
            if let query = firstString(in: item, keys: ["query"])?.trimmedNonEmpty {
                return "网络搜索：\(query)"
            }
            return "网络搜索"
        }

        let namespace = firstString(in: item, keys: ["server", "namespace"])?.trimmedNonEmpty
        let tool = firstString(in: item, keys: ["tool", "name"])?.trimmedNonEmpty
        switch tool?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "session_set_defaults": return "配置 Xcode 会话"
        case "test_sim": return "运行模拟器测试"
        case "test_device": return "运行真机测试"
        case "build_sim": return "构建模拟器版本"
        case "build_device": return "构建真机版本"
        case "build_run_sim": return "构建并运行 App"
        case "launch_app_sim": return "启动 App"
        case "stop_app_sim": return "停止 App"
        case "clean": return "清理构建产物"
        case "screenshot": return "截取界面"
        case "ui_describe_all": return "读取界面结构"
        case "tap": return "点击界面"
        case "swipe": return "滑动界面"
        case "type_text": return "输入文本"
        case "key_press": return "按下按键"
        case "open", "navigate": return namespace?.lowercased() == "browser" ? "打开网页" : "打开内容"
        case "click": return "点击页面"
        case "find": return "查找页面内容"
        case "search", "search_query": return "搜索网络"
        case "view_image": return "查看图片"
        case "imagegen": return "生成图片"
        case "apply_patch": return "修改文件"
        case "exec_command": return "运行命令"
        case "wait": return "等待任务完成"
        case "update_plan": return "更新计划"
        case "request_user_input": return "请求补充信息"
        case "read_mcp_resource": return "读取资源"
        case "list_mcp_resources", "list_mcp_resource_templates": return "列出资源"
        case "spawn_agent": return "启动子任务"
        case "send_message": return "发送协作消息"
        default:
            break
        }

        switch namespace?.lowercased() {
        case "xcodebuildmcp": return "运行 Xcode 工具"
        case "browser": return "操作网页"
        case "image_gen", "imagegen": return "生成图片"
        default: return type == "collabAgentToolCall" ? "执行协作任务" : "调用工具"
        }
    }

    private static func toolIdentifier(from item: [String: CodexAppServerJSONValue], type: String) -> String? {
        switch type {
        case "mcpToolCall":
            return [firstString(in: item, keys: ["server"]), firstString(in: item, keys: ["tool"])]
                .compactMap { $0?.trimmedNonEmpty }
                .joined(separator: ".")
                .trimmedNonEmpty
        case "dynamicToolCall":
            return [firstString(in: item, keys: ["namespace"]), firstString(in: item, keys: ["tool"])]
                .compactMap { $0?.trimmedNonEmpty }
                .joined(separator: ".")
                .trimmedNonEmpty
        case "collabAgentToolCall":
            return firstString(in: item, keys: ["tool", "agentNickname", "nickname"])?.trimmedNonEmpty
        case "webSearch":
            return "web.search"
        default:
            return nil
        }
    }

    private static func filePaths(from changes: [[String: CodexAppServerJSONValue]]) -> [String] {
        changes.compactMap { change in
            firstString(in: change, keys: ["path", "filePath", "relativePath", "filename"])?.trimmedNonEmpty
        }
    }

    private static func fileChangeSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
        let paths = filePaths(from: changes)
        guard !paths.isEmpty else {
            return nil
        }
        return compactFileSummary(paths)
    }

    private static func compactFileSummary(_ paths: [String]) -> String {
        var parts = Array(paths.prefix(3))
        if paths.count > parts.count {
            parts.append("+\(paths.count - parts.count)")
        }
        return parts.joined(separator: ", ")
    }

    private static func shortPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return path
        }
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private static func truncatedText(_ text: String, limit: Int) -> String {
        let prefix = text.prefix(limit)
        guard prefix.endIndex != text.endIndex else {
            return text
        }
        return String(prefix) + "\n... output truncated"
    }

    private static func stableDigest(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func firstString(in params: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private static func firstInt(in params: [String: CodexAppServerJSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = params[key]?.intValue {
                return value
            }
        }
        return nil
    }
}

struct UsageSummary: Codable, Hashable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let costUSD: Decimal?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case costUSD = "cost_usd"
    }

    var compactText: String? {
        if let costUSD {
            let value = NSDecimalNumber(decimal: costUSD).doubleValue
            return String(format: "$%.4f", value)
        }
        if let totalTokens {
            return "\(totalTokens) tok"
        }
        if let outputTokens {
            return "\(outputTokens) out"
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RateLimitSummary: Codable, Hashable {
    let remainingRequests: Int?
    let remainingTokens: Int?
    let resetAt: Date?
    let limitID: String?
    let limitName: String?
    let planType: String?
    let reachedType: String?
    let primaryUsedPercent: Double?
    let secondaryUsedPercent: Double?
    let primaryResetsAt: Int64?
    let secondaryResetsAt: Int64?
    let primaryWindowDurationMins: Int?
    let secondaryWindowDurationMins: Int?
    let hasCredits: Bool?
    let creditsUnlimited: Bool?
    let creditBalance: String?
    let availability: String?
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case remainingRequests = "remaining_requests"
        case remainingTokens = "remaining_tokens"
        case resetAt = "reset_at"
        case limitID = "limit_id"
        case limitName = "limit_name"
        case planType = "plan_type"
        case reachedType = "reached_type"
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case primaryResetsAt = "primary_resets_at"
        case secondaryResetsAt = "secondary_resets_at"
        case primaryWindowDurationMins = "primary_window_duration_mins"
        case secondaryWindowDurationMins = "secondary_window_duration_mins"
        case hasCredits = "has_credits"
        case creditsUnlimited = "credits_unlimited"
        case creditBalance = "credit_balance"
        case availability
        case unavailableReason = "unavailable_reason"
    }

    init(
        remainingRequests: Int? = nil,
        remainingTokens: Int? = nil,
        resetAt: Date? = nil,
        limitID: String? = nil,
        limitName: String? = nil,
        planType: String? = nil,
        reachedType: String? = nil,
        primaryUsedPercent: Double? = nil,
        secondaryUsedPercent: Double? = nil,
        primaryResetsAt: Int64? = nil,
        secondaryResetsAt: Int64? = nil,
        primaryWindowDurationMins: Int? = nil,
        secondaryWindowDurationMins: Int? = nil,
        hasCredits: Bool? = nil,
        creditsUnlimited: Bool? = nil,
        creditBalance: String? = nil,
        availability: String? = nil,
        unavailableReason: String? = nil
    ) {
        self.remainingRequests = remainingRequests
        self.remainingTokens = remainingTokens
        self.resetAt = resetAt
        self.limitID = limitID
        self.limitName = limitName
        self.planType = planType
        self.reachedType = reachedType
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.secondaryResetsAt = secondaryResetsAt
        self.primaryWindowDurationMins = primaryWindowDurationMins
        self.secondaryWindowDurationMins = secondaryWindowDurationMins
        self.hasCredits = hasCredits
        self.creditsUnlimited = creditsUnlimited
        self.creditBalance = creditBalance
        self.availability = availability
        self.unavailableReason = unavailableReason
    }

    var compactText: String? {
        if isExhausted {
            return "额度已用尽"
        }
        if let percentText = usedPercentText {
            return "已用 \(percentText)"
        }
        if let remainingRequests {
            return "剩余 \(remainingRequests) 次"
        }
        if let remainingTokens {
            return "剩余 \(remainingTokens) tok"
        }
        return nil
    }

    var isExhausted: Bool {
        if reachedType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if let primaryUsedPercent, primaryUsedPercent >= 100 {
            return true
        }
        if let secondaryUsedPercent, secondaryUsedPercent >= 100 {
            return true
        }
        if remainingRequests == 0 {
            return true
        }
        return false
    }

    var resetDate: Date? {
        if dominantUsageIsSecondary,
           let secondaryResetsAt {
            return Self.dateFromRateLimitEpoch(secondaryResetsAt)
        }
        if let primaryResetsAt {
            return Self.dateFromRateLimitEpoch(primaryResetsAt)
        }
        if let secondaryResetsAt {
            return Self.dateFromRateLimitEpoch(secondaryResetsAt)
        }
        return resetAt
    }

    var displayName: String {
        let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        let id = limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            return id
        }
        return "Codex"
    }

    var usedPercentValue: Double? {
        // Codex app-server 同时返回 primary/secondary 时，界面展示更接近耗尽的那一档。
        [primaryUsedPercent, secondaryUsedPercent].compactMap { $0 }.max()
    }

    private var dominantUsageIsSecondary: Bool {
        guard let secondaryUsedPercent else {
            return false
        }
        guard let primaryUsedPercent else {
            return true
        }
        return secondaryUsedPercent > primaryUsedPercent
    }

    var progressFraction: Double? {
        guard let usedPercentValue else {
            return nil
        }
        return min(max(usedPercentValue / 100, 0), 1)
    }

    var usedPercentText: String? {
        guard let percent = usedPercentValue else {
            return nil
        }
        let bounded = max(0, percent)
        if bounded.rounded() == bounded {
            return "\(Int(bounded))%"
        }
        return String(format: "%.1f%%", bounded)
    }

    static func dateFromRateLimitEpoch(_ value: Int64) -> Date? {
        guard value > 0 else {
            return nil
        }
        let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }
}

struct CodexUsageDisplaySummary: Equatable {
    static let nearLimitThreshold = 0.85

    let title: String
    let primaryText: String
    let secondaryText: String
    let progress: Double?
    let resetDate: Date?
    let isNearLimit: Bool
    let isExhausted: Bool

    static func make(rateLimit: RateLimitSummary?, now: Date = Date()) -> CodexUsageDisplaySummary? {
        guard let rateLimit else {
            return nil
        }
        guard let primaryText = rateLimit.compactText else {
            return nil
        }

        let progress = rateLimit.progressFraction
        let resetDate = rateLimit.resetDate
        let secondaryText: String
        if let resetDate {
            secondaryText = "预计 \(resetText(resetDate, now: now)) 重置"
        } else {
            secondaryText = "暂无重置时间"
        }

        return CodexUsageDisplaySummary(
            title: "Codex 使用量",
            primaryText: primaryText,
            secondaryText: secondaryText,
            progress: progress,
            resetDate: resetDate,
            isNearLimit: (progress ?? 0) >= nearLimitThreshold,
            isExhausted: rateLimit.isExhausted
        )
    }

    private static func resetText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

enum CodexUsageWindowKind: String, CaseIterable, Equatable, Identifiable {
    case primary
    case secondary

    var id: String { rawValue }
}

struct CodexUsageWindowDisplay: Equatable, Identifiable {
    static let nearLimitThreshold = 0.85

    let kind: CodexUsageWindowKind
    let durationMinutes: Int?
    let label: String
    let title: String
    let usedPercentText: String?
    let progress: Double?
    let resetDate: Date?
    let resetText: String
    let isNearLimit: Bool
    let isExhausted: Bool
    let providerName: String

    var id: String { kind.id }

    var isDayScaleWindow: Bool {
        guard let durationMinutes else {
            return false
        }
        return durationMinutes >= 24 * 60
    }

    var systemImage: String {
        isDayScaleWindow ? "calendar" : "clock"
    }

    var accessibilityName: String {
        guard let durationMinutes, durationMinutes > 0 else {
            return "\(providerName) 账号窗口"
        }
        if durationMinutes % (24 * 60) == 0 {
            return "\(providerName) \(durationMinutes / (24 * 60)) 天窗口"
        }
        if durationMinutes % 60 == 0 {
            return "\(providerName) \(durationMinutes / 60) 小时窗口"
        }
        return "\(providerName) \(durationMinutes) 分钟窗口"
    }

    var primaryText: String {
        guard let usedPercentText else {
            return "等待刷新"
        }
        return "已用 \(usedPercentText)"
    }

    /// 账号接口返回的是“已用比例”，左上角圆环表达的是“剩余比例”，统一在展示模型中换算，
    /// 避免不同页面各自计算后出现语义相反或越界的问题。
    var remainingProgress: Double? {
        progress.map { min(max(1 - $0, 0), 1) }
    }

    var remainingPercentText: String? {
        guard let remainingProgress else {
            return nil
        }
        let percent = remainingProgress * 100
        if abs(percent.rounded() - percent) < 0.0001 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    var remainingText: String {
        guard let remainingPercentText else {
            return "等待刷新"
        }
        return "剩余 \(remainingPercentText)"
    }
}

// primary/secondary 只是 app-server 的窗口槽位，并不保证永远对应 5h/7d。
// 展示层必须以服务端返回的 windowDurationMins 为准，避免产品调整额度策略后误标窗口。
struct CodexUsageWindowsDisplay: Equatable {
    let displayName: String
    let creditText: String
    let windows: [CodexUsageWindowDisplay]
    let hasLiveData: Bool

    var windowSummaryText: String {
        guard !windows.isEmpty else {
            return "尚未取得账号用量"
        }
        return "\(windows.map(\.label).joined(separator: " 和 ")) 账号窗口"
    }

    static func make(
        rateLimit: RateLimitSummary?,
        now: Date = Date(),
        fallbackDisplayName: String = "Codex"
    ) -> CodexUsageWindowsDisplay {
        let providerName = rateLimit?.displayName ?? fallbackDisplayName
        let windows = CodexUsageWindowKind.allCases.compactMap { kind in
            window(kind: kind, rateLimit: rateLimit, now: now, providerName: providerName)
        }
        .sorted { lhs, rhs in
            let lhsDuration = lhs.durationMinutes ?? Int.max
            let rhsDuration = rhs.durationMinutes ?? Int.max
            if lhsDuration == rhsDuration {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhsDuration < rhsDuration
        }
        return CodexUsageWindowsDisplay(
            displayName: providerName,
            creditText: creditText(rateLimit, fallbackDisplayName: providerName),
            windows: windows,
            hasLiveData: windows.contains { $0.progress != nil || $0.resetDate != nil }
        )
    }

    private static func window(
        kind: CodexUsageWindowKind,
        rateLimit: RateLimitSummary?,
        now: Date,
        providerName: String
    ) -> CodexUsageWindowDisplay? {
        let percent: Double?
        let resetEpoch: Int64?
        let durationMinutes: Int?
        switch kind {
        case .primary:
            percent = rateLimit?.primaryUsedPercent
            resetEpoch = rateLimit?.primaryResetsAt
            durationMinutes = rateLimit?.primaryWindowDurationMins
        case .secondary:
            percent = rateLimit?.secondaryUsedPercent
            resetEpoch = rateLimit?.secondaryResetsAt
            durationMinutes = rateLimit?.secondaryWindowDurationMins
        }

        // 只渲染服务端实际返回的窗口。nil rateLimit 时由外层空态承接，不伪造 5h/7d 占位行。
        guard percent != nil || resetEpoch != nil || durationMinutes != nil else {
            return nil
        }

        let progress = percent.map { min(max($0 / 100, 0), 1) }
        let resetDate = resetEpoch.flatMap(RateLimitSummary.dateFromRateLimitEpoch)
        let boundedPercent = percent.map { max(0, $0) }
        let reachedType = rateLimit?.reachedType?.lowercased() ?? ""
        let reachedThisWindow: Bool
        switch kind {
        case .primary:
            reachedThisWindow = reachedType.contains("primary")
        case .secondary:
            reachedThisWindow = reachedType.contains("secondary")
        }
        let isExhausted = reachedThisWindow || (boundedPercent ?? 0) >= 100

        return CodexUsageWindowDisplay(
            kind: kind,
            durationMinutes: durationMinutes,
            label: durationLabel(durationMinutes),
            title: durationTitle(durationMinutes),
            usedPercentText: boundedPercent.map(percentText),
            progress: progress,
            resetDate: resetDate,
            resetText: resetText(resetDate, now: now),
            isNearLimit: (progress ?? 0) >= CodexUsageWindowDisplay.nearLimitThreshold,
            isExhausted: isExhausted,
            providerName: providerName
        )
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else {
            return "窗口"
        }
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60))d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func durationTitle(_ minutes: Int?) -> String {
        switch minutes {
        case 300:
            return "短窗口"
        case 10_080:
            return "周窗口"
        default:
            return "账号窗口"
        }
    }

    private static func percentText(_ percent: Double) -> String {
        if percent.rounded() == percent {
            return "\(Int(percent))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else {
            return "暂无重置时间"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        return "\(formatter.string(from: date)) 重置"
    }

    private static func creditText(_ rateLimit: RateLimitSummary?, fallbackDisplayName: String) -> String {
        guard let rateLimit else {
            return "等待 \(fallbackDisplayName) 返回账号用量"
        }
        switch rateLimit.availability?.lowercased() {
        case "unavailable":
            if rateLimit.unavailableReason == "headless_statusline_unavailable" {
                return "Headless 暂无额度百分比"
            }
            return "账号额度数据暂不可用"
        case "partial":
            return "仅显示已观测的限流窗口"
        default:
            break
        }
        if rateLimit.creditsUnlimited == true {
            return "Credits 无限制"
        }
        if let balance = rateLimit.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !balance.isEmpty {
            return "Credits 余额 \(balance)"
        }
        if rateLimit.hasCredits == false {
            return "Credits 未启用"
        }
        if let plan = rateLimit.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            return "计划 \(plan)"
        }
        return "暂无余额信息"
    }
}

struct CodexQuotaNotice: Equatable {
    let title: String
    let message: String
    let resetDate: Date?
    let blocksSending: Bool
    let canDismiss: Bool

    static func make(rateLimit: RateLimitSummary?, errorMessage: String?, now: Date = Date()) -> CodexQuotaNotice? {
        if let rateLimit, rateLimit.isExhausted {
            let resetDate = rateLimit.resetDate
            let resetText = resetDate.map { Self.resetText($0, now: now) }
            let blocksSending = resetDate.map { $0 > now } ?? true
            let suffix = resetText.map { "预计 \($0) 恢复；也可以在桌面 Codex 点“增加额度”或“重置使用量”。" }
                ?? "可以在桌面 Codex 点“增加额度”或“重置使用量”。"
            return CodexQuotaNotice(
                title: "Codex 消息额度已用尽",
                message: "\(rateLimit.displayName) 当前额度不可用。\(suffix)",
                resetDate: resetDate,
                blocksSending: blocksSending,
                canDismiss: false
            )
        }

        guard let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              isQuotaError(error)
        else {
            return nil
        }
        return CodexQuotaNotice(
            title: "Codex 消息额度已用尽",
            message: "这次发送被 Codex 额度限制拦截。请等待重置，或先在桌面 Codex 点“增加额度”/“重置使用量”。",
            resetDate: nil,
            blocksSending: true,
            canDismiss: true
        )
    }

    static func isQuotaError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("skill descriptions") || lower.contains("skills context budget") {
            return false
        }
        return [
            "rate limit",
            "ratelimit",
            "quota",
            "message limit",
            "messages limit",
            "usage limit",
            "limit has been exhausted",
            "exceeded your current quota",
            "429",
            "额度",
            "限额",
            "速率限制",
            "用量受限",
            "已用尽"
        ].contains { lower.contains($0) }
    }

    private static func resetText(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded()))
        let absolute = formatter.string(from: date)
        if seconds < 60 {
            return "\(absolute)（约 \(seconds) 秒）"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(absolute)（约 \(minutes) 分钟）"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(absolute)（约 \(hours) 小时）"
        }
        return "\(absolute)（约 \(hours) 小时 \(remainingMinutes) 分钟）"
    }
}

struct ApprovalSummary: Codable, Hashable {
    let id: String
    let title: String
    // 审批摘要会随 session/history 缓存落盘。字段保持可选，保证旧版本缓存和服务端快照
    // 缺少详情时仍能正常解码；UI 再据此决定是否允许批准。
    let body: String?
    let kind: String
    let risk: String?
    let count: Int?
    // Claude 只有在明确给出 localSettings addRules 建议时，客户端才展示“始终允许”。
    // 规则仅用于确认展示，真正回传的 PermissionUpdate 由 bridge 按 request id 保存并校验。
    let availableDecisions: [String]?
    let persistentPermissionRules: [String]?

    init(
        id: String,
        title: String,
        body: String? = nil,
        kind: String,
        risk: String? = nil,
        count: Int?,
        availableDecisions: [String]? = nil,
        persistentPermissionRules: [String]? = nil
    ) {
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedRisk = risk?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.id = id
        self.title = title
        self.body = normalizedBody.isEmpty ? nil : normalizedBody
        self.kind = kind
        self.risk = normalizedRisk.isEmpty ? nil : normalizedRisk
        self.count = count
        self.availableDecisions = availableDecisions
        self.persistentPermissionRules = persistentPermissionRules
    }

    var hasDecisionContext: Bool {
        if body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        guard kind == "command" else {
            return false
        }
        let command = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 旧事件只带 title。含参数、路径或命令分隔符的标题仍能明确表达动作；
        // “运行命令”这类泛化标题则必须等服务端补齐 body 后才能批准。
        return command.contains(" ") || command.contains("/") || command.contains("：") || command.contains(":")
    }

    var canPersistPermission: Bool {
        let supportsDecision = availableDecisions?.contains { decision in
            decision.caseInsensitiveCompare("acceptWithPermissionUpdate") == .orderedSame
        } == true
        return supportsDecision && persistentPermissionRules?.isEmpty == false
    }
}

struct AgentUserInputRequest: Identifiable, Codable, Hashable {
    let id: String
    let threadID: SessionID
    let turnID: TurnID?
    let itemID: AgentItemID
    let questions: [AgentUserInputQuestion]

    var title: String {
        if let first = questions.first {
            let header = first.header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !header.isEmpty {
                return header
            }
            let question = first.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                return question
            }
        }
        return "补充输入"
    }
}

struct AgentUserInputQuestion: Identifiable, Codable, Hashable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [AgentUserInputOption]
    let multiSelect: Bool?

    init(
        id: String,
        header: String,
        question: String,
        isOther: Bool,
        isSecret: Bool,
        options: [AgentUserInputOption],
        multiSelect: Bool? = nil
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.isOther = isOther
        self.isSecret = isSecret
        self.options = options
        self.multiSelect = multiSelect
    }

    var allowsMultipleSelection: Bool { multiSelect == true }
}

struct AgentUserInputOption: Identifiable, Codable, Hashable {
    let label: String
    let description: String?

    var id: String { label }
}

enum SessionDataFlow {
    typealias SessionRow = DataFlowSessionRow
}

struct DataFlowSessionRow: Identifiable, Codable, Hashable {
    let id: SessionID
    let projectID: String
    let projectName: String?
    let projectPath: String?
    let title: String
    let status: SessionStatus
    let source: String
    let runtimeProvider: String?
    let resumeID: String?
    let createdAt: Date?
    let updatedAt: Date?
    let preview: String?
    let activeTurnID: TurnID?
    let lastSeq: EventSequence?
    let revision: ModelRevision
    let usage: UsageSummary?
    let rateLimit: RateLimitSummary?
    let pendingApproval: ApprovalSummary?
    let context: SessionContextSnapshot?

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case projectName = "project_name"
        case projectPath = "project_path"
        case title
        case status
        case source
        case runtimeProvider = "runtime_provider"
        case resumeID = "resume_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case preview
        case activeTurnID = "active_turn_id"
        case lastSeq = "last_seq"
        case revision
        case usage
        case rateLimit = "rate_limit"
        case pendingApproval = "pending_approval"
        case context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(SessionID.self, forKey: .id)
        self.projectID = try container.decode(String.self, forKey: .projectID)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名会话"
        self.status = try container.decodeIfPresent(SessionStatus.self, forKey: .status) ?? .unknown
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "codex"
        self.runtimeProvider = try container.decodeIfPresent(String.self, forKey: .runtimeProvider)
        self.resumeID = try container.decodeIfPresent(String.self, forKey: .resumeID)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.preview = try container.decodeIfPresent(String.self, forKey: .preview)
        self.activeTurnID = try container.decodeIfPresent(TurnID.self, forKey: .activeTurnID)
        self.lastSeq = try container.decodeIfPresent(EventSequence.self, forKey: .lastSeq)
        self.revision = try container.decodeIfPresent(ModelRevision.self, forKey: .revision) ?? 0
        self.usage = try container.decodeIfPresent(UsageSummary.self, forKey: .usage)
        self.rateLimit = try container.decodeIfPresent(RateLimitSummary.self, forKey: .rateLimit)
        self.pendingApproval = try container.decodeIfPresent(ApprovalSummary.self, forKey: .pendingApproval)
        self.context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context)
    }
}

struct MessagePage: Codable, Hashable {
    let sessionID: SessionID
    let messages: [AgentMessage]
    let nextCursor: String?
    let previousCursor: String?
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
    let snapshotSeq: EventSequence?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case messages
        case nextCursor = "next_cursor"
        case previousCursor = "previous_cursor"
        case hasMoreBefore = "has_more_before"
        case hasMoreAfter = "has_more_after"
        case snapshotSeq = "snapshot_seq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        self.messages = try container.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        self.previousCursor = try container.decodeIfPresent(String.self, forKey: .previousCursor)
        self.hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore) ?? false
        self.hasMoreAfter = try container.decodeIfPresent(Bool.self, forKey: .hasMoreAfter) ?? false
        self.snapshotSeq = try container.decodeIfPresent(EventSequence.self, forKey: .snapshotSeq)
    }
}

struct AgentMessage: Identifiable, Codable, Hashable {
    let id: MessageID
    let sessionID: SessionID
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let role: MessageRole
    let kind: MessageKind
    var content: String
    var summary: String?
    var activityPayload: ConversationActivityPayload?
    var createdAt: Date?
    var updatedAt: Date?
    var seq: EventSequence?
    var revision: ModelRevision
    var sendStatus: MessageSendStatus
    var isTimestampFallback: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case clientMessageID = "client_message_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case role
        case kind
        case content
        case summary
        case activityPayload = "activity_payload"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seq
        case revision
        case sendStatus = "send_status"
        case isTimestampFallback = "is_timestamp_fallback"
    }

    init(
        id: MessageID,
        sessionID: SessionID,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        role: MessageRole,
        kind: MessageKind = .message,
        content: String,
        summary: String? = nil,
        activityPayload: ConversationActivityPayload? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision = 0,
        sendStatus: MessageSendStatus = .confirmed,
        isTimestampFallback: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.role = role
        self.kind = kind
        self.content = content
        self.summary = summary
        self.activityPayload = activityPayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
        self.isTimestampFallback = isTimestampFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(MessageID.self, forKey: .id)
        self.sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        self.clientMessageID = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID)
        self.turnID = try container.decodeIfPresent(TurnID.self, forKey: .turnID)
        self.itemID = try container.decodeIfPresent(AgentItemID.self, forKey: .itemID)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.kind = try container.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .message
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.activityPayload = try container.decodeIfPresent(ConversationActivityPayload.self, forKey: .activityPayload)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.seq = try container.decodeIfPresent(EventSequence.self, forKey: .seq)
        self.revision = try container.decodeIfPresent(ModelRevision.self, forKey: .revision) ?? 0
        self.sendStatus = try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus) ?? .confirmed
        self.isTimestampFallback = try container.decodeIfPresent(Bool.self, forKey: .isTimestampFallback) ?? false
    }
}

struct ComposerDraft: Identifiable, Codable, Hashable {
    let id: String
    let projectID: String?
    let sessionID: SessionID?
    var text: String
    var isExpanded: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        projectID: String?,
        sessionID: SessionID?,
        text: String = "",
        isExpanded: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.text = text
        self.isExpanded = isExpanded
        self.updatedAt = updatedAt
    }
}

struct AgentEventMetadata: Codable, Hashable {
    let seq: EventSequence?
    let sessionID: SessionID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let messageID: MessageID?
    let clientMessageID: ClientMessageID?
    let revision: ModelRevision?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
    }
}

struct AgentDelta: Codable, Hashable {
    let text: String
    let role: MessageRole?
    let kind: MessageKind?
}

struct LogDelta: Codable, Hashable {
    let text: String
    let stream: String?
}

struct FileChangeSummary: Codable, Hashable {
    let path: String
    let status: String
    let additions: Int?
    let deletions: Int?
}

struct AgentApprovalRequest: Codable, Hashable {
    let id: String
    let title: String
    let body: String?
    let kind: String
    let risk: String?
    let availableDecisions: [String]?
    let persistentPermissionRules: [String]?

    init(
        id: String,
        title: String,
        body: String?,
        kind: String,
        risk: String?,
        availableDecisions: [String]? = nil,
        persistentPermissionRules: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.risk = risk
        self.availableDecisions = availableDecisions
        self.persistentPermissionRules = persistentPermissionRules
    }
}

struct AgentErrorPayload: Codable, Hashable {
    let message: String
    let code: String?
    let retryable: Bool?
}

enum ConnectionTerminationStatus: Equatable {
    case credentialsInvalid

    var title: String {
        switch self {
        case .credentialsInvalid:
            return "需要重新配对"
        }
    }

    var message: String {
        switch self {
        case .credentialsInvalid:
            return "访问码已失效，已停止自动重试。请打开连接管理并重新扫描 Mac 上的配对二维码。"
        }
    }
}

enum ConnectionStatus: Equatable {
    case idle
    case testing
    case connected(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "未连接"
        case .testing:
            return "连接中"
        case .connected:
            return "已连接 Mac 助手"
        case .failed:
            return "连接失败"
        }
    }
}

enum WebSocketStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
    case terminated(ConnectionTerminationStatus)

    var title: String {
        switch self {
        case .disconnected:
            return "终端未连接"
        case .connecting:
            return "连接中"
        case .connected:
            return "实时连接"
        case .failed:
            return "连接失败"
        case .terminated(let reason):
            return reason.title
        }
    }
}
