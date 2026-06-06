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
    let context: SessionContextSnapshot?

    var isAppServerHistory: Bool {
        status == "history"
    }

    var isRunning: Bool {
        status == "running" || status == "waiting_for_approval" || status == "waiting_for_input"
    }

    var displayStatusText: String {
        // UI 只展示短状态，避免 iPad 侧栏里出现 waiting_for_approval 这类长英文撑破布局。
        switch status {
        case "running":
            return "运行中"
        case "history":
            return "历史"
        case "waiting_for_input":
            return "待输入"
        case "waiting_for_approval":
            return "待审批"
        case "completed":
            return "完成"
        case "failed":
            return "失败"
        case "closed":
            return "已结束"
        case "idle":
            return "空闲"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
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
        case context
    }
}

struct CodexHistoryMessage: Identifiable, Codable, Hashable {
    var id: MessageID
    let role: String
    let kind: MessageKind
    let content: String
    let createdAt: Date?
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
        let clientMessageID = try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID)
        self.init(
            id: try container.decodeIfPresent(MessageID.self, forKey: .id) ?? clientMessageID ?? UUID().uuidString,
            role: role,
            kind: try container.decodeIfPresent(MessageKind.self, forKey: .kind) ?? .message,
            content: content,
            createdAt: createdAt,
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
    var sendStatus: MessageSendStatus
    var revision: ModelRevision?
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
        sendStatus: MessageSendStatus = .sent,
        revision: ModelRevision? = nil
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
        self.sendStatus = sendStatus
        self.revision = revision
        let fingerprint = Self.makeRenderFingerprint(for: content)
        self.contentRevision = 0
        self.contentDigest = fingerprint.digest
        self.contentByteCount = fingerprint.byteCount
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
        case .connected(let version):
            return "已连接 \(version)"
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
