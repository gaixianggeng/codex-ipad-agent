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
    let resumeID: String?
    let createdAt: Date?
    let updatedAt: Date?
    let preview: String?
    var activeTurnID: TurnID?
    let lastSeq: EventSequence?
    let revision: ModelRevision?
    let usage: UsageSummary?
    let rateLimit: RateLimitSummary?
    var pendingApproval: ApprovalSummary?
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

extension AgentSession {
    func displayStatus(foregroundActivity: SessionForegroundActivity?) -> AgentSessionDisplayStatus {
        // 侧栏和对话顶部共用这套优先级，避免同一个会话在不同入口显示成两种状态。
        // 审批/输入是需要用户处理的状态，优先级高于流式输出；foreground activity 负责区分等待回复和正在回复。
        if status == SessionStatus.waitingForApproval.rawValue || pendingApproval != nil {
            return AgentSessionDisplayStatus(title: "待审批", systemImage: "checkmark.seal.fill", tone: .warning, showsSpinner: false)
        }
        if status == SessionStatus.waitingForInput.rawValue {
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
    let createdAt: Date?
    let updatedAt: Date?
    let clientMessageID: ClientMessageID?
    let turnID: TurnID?
    let itemID: AgentItemID?
    let seq: EventSequence?
    let revision: ModelRevision?
    let sendStatus: MessageSendStatus?

    init(
        id: MessageID = UUID().uuidString,
        role: String,
        kind: MessageKind = .message,
        content: String,
        createdAt: Date?,
        updatedAt: Date? = nil,
        clientMessageID: ClientMessageID? = nil,
        turnID: TurnID? = nil,
        itemID: AgentItemID? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision? = nil,
        sendStatus: MessageSendStatus? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.clientMessageID = clientMessageID
        self.turnID = turnID
        self.itemID = itemID
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case kind
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case clientMessageID = "client_message_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case seq
        case revision
        case sendStatus = "send_status"
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
            createdAt: createdAt,
            updatedAt: updatedAt,
            clientMessageID: clientMessageID,
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            sendStatus: try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus)
        )
    }
}

struct ConversationMessageRenderFingerprint: Hashable {
    let contentRevision: UInt64
    let contentDigest: UInt64
    let contentByteCount: Int
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
    let createdAt: Date
    var updatedAt: Date?
    var sendStatus: MessageSendStatus
    var revision: ModelRevision?
    var turnPayload: CodexAppServerTurnPayload?
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
        turnPayload: CodexAppServerTurnPayload? = nil
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
    case reasoningSummary = "reasoning_summary"
    case commandSummary = "command_summary"
    case fileChangeSummary = "file_change_summary"
    case approval
    case error
}

enum MessageSendStatus: String, Codable, Hashable {
    case local
    case sending
    case sent
    case failed
    case confirmed
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

struct RateLimitSummary: Codable, Hashable {
    let remainingRequests: Int?
    let remainingTokens: Int?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case remainingRequests = "remaining_requests"
        case remainingTokens = "remaining_tokens"
        case resetAt = "reset_at"
    }

    var compactText: String? {
        if let remainingRequests {
            return "剩余 \(remainingRequests) 次"
        }
        if let remainingTokens {
            return "剩余 \(remainingTokens) tok"
        }
        return nil
    }
}

struct ApprovalSummary: Codable, Hashable {
    let id: String
    let title: String
    let kind: String
    let count: Int?
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
    var createdAt: Date?
    var updatedAt: Date?
    var seq: EventSequence?
    var revision: ModelRevision
    var sendStatus: MessageSendStatus

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
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seq
        case revision
        case sendStatus = "send_status"
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
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        seq: EventSequence? = nil,
        revision: ModelRevision = 0,
        sendStatus: MessageSendStatus = .confirmed
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.seq = seq
        self.revision = revision
        self.sendStatus = sendStatus
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
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.seq = try container.decodeIfPresent(EventSequence.self, forKey: .seq)
        self.revision = try container.decodeIfPresent(ModelRevision.self, forKey: .revision) ?? 0
        self.sendStatus = try container.decodeIfPresent(MessageSendStatus.self, forKey: .sendStatus) ?? .confirmed
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
}

struct AgentErrorPayload: Codable, Hashable {
    let message: String
    let code: String?
    let retryable: Bool?
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
        }
    }
}
