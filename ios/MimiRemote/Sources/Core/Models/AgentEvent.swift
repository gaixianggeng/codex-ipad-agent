import Foundation

enum AgentEvent {
    case session(AgentSession)
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case sessionContext(SessionContextSnapshot, AgentEventMetadata)
    case goalUpdated(ThreadGoal, AgentEventMetadata)
    case goalCleared(AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case processItemCompleted(AgentMessage, SessionContextSnapshot?, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
    case userInputRequest(AgentUserInputRequest, AgentEventMetadata)
    case userInputResolved(AgentEventMetadata, skipped: Bool)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case error(AgentErrorPayload, AgentEventMetadata)
    case unknown(String)
}

extension AgentEvent: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        case data
        case session
        case row
        case delta
        case log
        case exit
        case error
        case warning
        case message
        case diff
        case approval
        case userInput = "user_input"
        case skipped
        case meta
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
        case status
        case context
        case goal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let metadata = try Self.decodeMetadata(from: container)
        switch type {
        case "session":
            self = .session(try container.decode(AgentSession.self, forKey: .session))
        case "session_row":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else {
                self = .unknown(type)
            }
        case "session_status":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else if let context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context) {
                self = .sessionContext(context, metadata)
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
        case "session_context":
            self = .sessionContext(try container.decode(SessionContextSnapshot.self, forKey: .context), metadata)
        case "goal_updated":
            self = .goalUpdated(try container.decode(ThreadGoal.self, forKey: .goal), metadata)
        case "goal_cleared":
            self = .goalCleared(metadata)
        case "turn_started":
            self = .turnStarted(metadata)
        case "assistant_delta":
            self = .assistantDelta(try Self.decodeDelta(from: container), metadata)
        case "message_completed":
            self = .messageCompleted(try container.decode(AgentMessage.self, forKey: .message), metadata)
        case "log_delta":
            self = .logDelta(try Self.decodeLogDelta(from: container), metadata)
        case "diff_updated":
            self = .diffUpdated(try container.decode(FileChangeSummary.self, forKey: .diff), metadata)
        case "approval_request":
            self = .approvalRequest(try container.decode(AgentApprovalRequest.self, forKey: .approval), metadata)
        case "approval_resolved":
            self = .approvalResolved(metadata)
        case "user_input_request":
            self = .userInputRequest(try container.decode(AgentUserInputRequest.self, forKey: .userInput), metadata)
        case "user_input_resolved":
            self = .userInputResolved(metadata, skipped: try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false)
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: "未知警告"), metadata)
        case "error":
            self = .error(
                try Self.decodePayload(from: container, key: .error, fallback: "未知错误"),
                metadata
            )
        default:
            self = .unknown(type)
        }
    }

    private static func decodeMetadata(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentEventMetadata {
        try container.decodeIfPresent(AgentEventMetadata.self, forKey: .meta) ?? AgentEventMetadata(
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            sessionID: try container.decodeIfPresent(SessionID.self, forKey: .sessionID),
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            messageID: try container.decodeIfPresent(MessageID.self, forKey: .messageID),
            clientMessageID: try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt)
        )
    }

    private static func decodeDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentDelta {
        if let delta = try container.decodeIfPresent(AgentDelta.self, forKey: .delta) {
            return delta
        }
        return AgentDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", role: .assistant, kind: .message)
    }

    private static func decodeLogDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> LogDelta {
        if let log = try container.decodeIfPresent(LogDelta.self, forKey: .log) {
            return log
        }
        return LogDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", stream: nil)
    }

    private static func decodePayload(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        fallback: String
    ) throws -> AgentErrorPayload {
        if let payload = try container.decodeIfPresent(AgentErrorPayload.self, forKey: key) {
            return payload
        }
        return AgentErrorPayload(message: try container.decodeIfPresent(String.self, forKey: key) ?? fallback, code: nil, retryable: nil)
    }
}

enum StructuredAgentEvent: Decodable, Hashable {
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case sessionContext(SessionContextSnapshot, AgentEventMetadata)
    case goalUpdated(ThreadGoal, AgentEventMetadata)
    case goalCleared(AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
    case userInputRequest(AgentUserInputRequest, AgentEventMetadata)
    case userInputResolved(AgentEventMetadata, skipped: Bool)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case error(AgentErrorPayload, AgentEventMetadata)
    case unknown(String, AgentEventMetadata)

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case row
        case message
        case delta
        case log
        case diff
        case approval
        case userInput = "user_input"
        case skipped
        case error
        case warning
        case meta
        case seq
        case sessionID = "session_id"
        case turnID = "turn_id"
        case itemID = "item_id"
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case revision
        case createdAt = "created_at"
        case status
        case context
        case goal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let metadata = try container.decodeIfPresent(AgentEventMetadata.self, forKey: .meta) ?? AgentEventMetadata(
            seq: try container.decodeIfPresent(EventSequence.self, forKey: .seq),
            sessionID: try container.decodeIfPresent(SessionID.self, forKey: .sessionID),
            turnID: try container.decodeIfPresent(TurnID.self, forKey: .turnID),
            itemID: try container.decodeIfPresent(AgentItemID.self, forKey: .itemID),
            messageID: try container.decodeIfPresent(MessageID.self, forKey: .messageID),
            clientMessageID: try container.decodeIfPresent(ClientMessageID.self, forKey: .clientMessageID),
            revision: try container.decodeIfPresent(ModelRevision.self, forKey: .revision),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt)
        )

        switch type {
        case "session_row":
            self = .sessionRow(try container.decode(DataFlowSessionRow.self, forKey: .row), metadata)
        case "session_status":
            if let row = try container.decodeIfPresent(DataFlowSessionRow.self, forKey: .row) {
                self = .sessionRow(row, metadata)
            } else if let context = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .context) {
                self = .sessionContext(context, metadata)
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
        case "session_context":
            self = .sessionContext(try container.decode(SessionContextSnapshot.self, forKey: .context), metadata)
        case "goal_updated":
            self = .goalUpdated(try container.decode(ThreadGoal.self, forKey: .goal), metadata)
        case "goal_cleared":
            self = .goalCleared(metadata)
        case "turn_started":
            self = .turnStarted(metadata)
        case "assistant_delta":
            self = .assistantDelta(try Self.decodeDelta(from: container), metadata)
        case "message_completed":
            self = .messageCompleted(try container.decode(AgentMessage.self, forKey: .message), metadata)
        case "log_delta":
            self = .logDelta(try Self.decodeLogDelta(from: container), metadata)
        case "diff_updated":
            self = .diffUpdated(try container.decode(FileChangeSummary.self, forKey: .diff), metadata)
        case "approval_request":
            self = .approvalRequest(try container.decode(AgentApprovalRequest.self, forKey: .approval), metadata)
        case "approval_resolved":
            self = .approvalResolved(metadata)
        case "user_input_request":
            self = .userInputRequest(try container.decode(AgentUserInputRequest.self, forKey: .userInput), metadata)
        case "user_input_resolved":
            self = .userInputResolved(metadata, skipped: try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false)
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: "未知警告"), metadata)
        case "error":
            self = .error(try Self.decodePayload(from: container, key: .error, fallback: "未知错误"), metadata)
        default:
            self = .unknown(type, metadata)
        }
    }

    private static func decodeDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> AgentDelta {
        if let delta = try container.decodeIfPresent(AgentDelta.self, forKey: .delta) {
            return delta
        }
        return AgentDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", role: .assistant, kind: .message)
    }

    private static func decodeLogDelta(from container: KeyedDecodingContainer<CodingKeys>) throws -> LogDelta {
        if let log = try container.decodeIfPresent(LogDelta.self, forKey: .log) {
            return log
        }
        return LogDelta(text: try container.decodeIfPresent(String.self, forKey: .data) ?? "", stream: nil)
    }

    private static func decodePayload(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        fallback: String
    ) throws -> AgentErrorPayload {
        if let payload = try container.decodeIfPresent(AgentErrorPayload.self, forKey: key) {
            return payload
        }
        return AgentErrorPayload(message: try container.decodeIfPresent(String.self, forKey: key) ?? fallback, code: nil, retryable: nil)
    }
}

extension AgentEventMetadata {
    static let empty = AgentEventMetadata(
        seq: nil,
        sessionID: nil,
        turnID: nil,
        itemID: nil,
        messageID: nil,
        clientMessageID: nil,
        revision: nil,
        createdAt: nil
    )
}

struct CodexAppServerEventProjector {
    private var nextSeqBySessionID: [SessionID: EventSequence] = [:]
    private var streamedTextByKey: [String: String] = [:]
    private var agentMessageKindByItemID: [AgentItemID: MessageKind] = [:]

    mutating func project(_ notification: CodexAppServerNotification) -> AgentEvent? {
        let params = notification.params?.objectValue ?? [:]
        let metadata = makeMetadata(from: params)

        switch notification.method {
        case "thread/goal/updated":
            guard let goal = goal(from: params) else {
                return nil
            }
            return .goalUpdated(goal, metadata)
        case "thread/goal/cleared":
            return .goalCleared(metadata)
        case "turn/started":
            return .turnStarted(metadata)
        case "item/agentMessage/delta":
            guard let text = firstString(in: params, keys: ["delta", "text"]), !text.isEmpty else {
                return nil
            }
            return .assistantDelta(
                AgentDelta(text: text, role: .assistant, kind: agentMessageKind(from: params, metadata: metadata)),
                metadata
            )
        case "turn/plan/updated":
            return completedPlanEvent(params: params, metadata: metadata)
        case "item/plan/delta":
            return streamedSystemMessageEvent(
                params: params,
                metadata: metadata,
                deltaKeys: ["delta", "text"],
                bufferSuffix: "plan",
                kind: .plan
            )
        case "item/reasoning/summaryTextDelta":
            let summaryIndex = firstInt(in: params, keys: ["summaryIndex"]) ?? 0
            return streamedSystemMessageEvent(
                params: params,
                metadata: metadata,
                deltaKeys: ["delta", "text"],
                bufferSuffix: "reasoning-summary-\(summaryIndex)",
                kind: .reasoningSummary,
                activityCategory: .thinking
            )
        case "item/reasoning/summaryPartAdded":
            // 这是新分段边界，本身没有可展示文本；后续 summaryTextDelta 会带 index。
            return nil
        case "thread/tokenUsage/updated":
            return tokenUsageContextEvent(params: params, metadata: metadata)
        case "thread/compacted":
            return systemNoticeEvent(
                text: "上下文已压缩",
                itemID: "context-compaction",
                kind: .reasoningSummary,
                metadata: metadata
            )
        case "thread/name/updated":
            let name = firstString(in: params, keys: ["threadName", "name"])
            return systemNoticeEvent(
                text: name.map { "会话已命名为：\($0)" } ?? "会话名称已清除",
                itemID: "thread-name",
                kind: .message,
                metadata: metadata
            )
        case "item/mcpToolCall/progress":
            return mcpProgressContextEvent(params: params, metadata: metadata)
        case "mcpServer/startupStatus/updated":
            return mcpServerStatusContextEvent(params: params, metadata: metadata)
        case "deprecationNotice":
            let summary = firstString(in: params, keys: ["summary"]) ?? "app-server 协议能力已废弃"
            let details = firstString(in: params, keys: ["details"])
            return .warning(
                AgentErrorPayload(
                    message: [summary, details].compactMap { $0 }.joined(separator: "\n"),
                    code: "deprecationNotice",
                    retryable: false
                ),
                metadata
            )
        case "item/started":
            rememberAgentMessageKind(from: params, metadata: metadata)
            return itemContextEvent(params: params, metadata: metadata)
        case "item/completed":
            return completedAgentMessageEvent(params: params, metadata: metadata)
                ?? completedImageItemEvent(params: params, metadata: metadata)
                ?? completedProcessItemEvent(params: params, metadata: metadata)
                ?? itemContextEvent(params: params, metadata: metadata)
        case "item/commandExecution/outputDelta",
             "command/exec/outputDelta",
             "commandExecution/outputDelta",
             "command/execution/outputDelta",
             "process/outputDelta":
            guard let text = firstString(in: params, keys: ["delta", "data", "text", "chunk"]), !text.isEmpty else {
                return nil
            }
            return .logDelta(LogDelta(text: text, stream: firstString(in: params, keys: ["stream", "fd"])), metadata)
        case "item/fileChange/patchUpdated",
             "fileChange/patchUpdated",
             "turn/diff/updated":
            return fileChangeContextEvent(params: params, metadata: metadata)
        case "turn/completed":
            return .turnCompleted(metadata)
        case "serverRequest/resolved":
            return .approvalResolved(metadata)
        case "warning":
            return .warning(errorPayload(from: params, fallback: "app-server warning"), metadata)
        case "error":
            return .error(errorPayload(from: params, fallback: "app-server error"), metadata)
        default:
            return nil
        }
    }

    mutating func project(_ request: CodexAppServerServerRequest) -> AgentEvent? {
        let params = request.params?.objectValue ?? [:]
        if request.method == "item/tool/requestUserInput" {
            let metadata = makeMetadata(from: params)
            guard let request = userInputRequest(from: params, requestID: request.id.description, metadata: metadata) else {
                return nil
            }
            return .userInputRequest(request, metadata)
        }
        if request.method == "mcpServer/elicitation/request",
           params["mode"]?.stringValue != "url" {
            let metadata = makeMetadata(from: params)
            guard let userInput = mcpElicitationUserInputRequest(
                from: params,
                requestID: request.id.description,
                metadata: metadata
            ) else {
                return nil
            }
            return .userInputRequest(userInput, metadata)
        }
        guard isApprovalLike(method: request.method, params: params) else {
            return nil
        }
        let metadata = makeMetadata(from: params)
        let kind = approvalKind(method: request.method)
        let itemID = metadata.itemID ?? request.id.description
        return .approvalRequest(
            AgentApprovalRequest(
                id: firstString(in: params, keys: ["approvalId"]) ?? itemID,
                title: approvalTitle(kind: kind, params: params),
                body: approvalBody(kind: kind, params: params),
                kind: kind,
                risk: firstString(in: params, keys: ["risk"]) ?? "high",
                availableDecisions: params["availableDecisions"]?.arrayValue?.compactMap(\.stringValue),
                persistentPermissionRules: eligiblePersistentPermissionRules(from: params)
            ),
            metadata
        )
    }

    private mutating func makeMetadata(from params: [String: CodexAppServerJSONValue]) -> AgentEventMetadata {
        let sessionID = firstString(in: params, keys: ["threadId", "conversationId", "sessionId", "session_id"])
            ?? nestedString(in: params, key: "thread", nestedKey: "id")
        let turnID = firstString(in: params, keys: ["turnId", "turn_id"]) ?? nestedString(in: params, key: "turn", nestedKey: "id")
        let item = params["item"]?.objectValue
        let itemID = firstString(in: params, keys: ["itemId", "item_id", "requestId", "request_id", "callId", "approvalId"]) ?? item?["id"]?.stringValue
        let messageID = firstString(in: params, keys: ["messageId", "message_id"]) ?? appServerMessageID(turnID: turnID, itemID: itemID)
        let seq = nextSeq(for: sessionID)
        return AgentEventMetadata(
            seq: seq,
            sessionID: sessionID,
            turnID: turnID,
            itemID: itemID,
            messageID: messageID,
            clientMessageID: firstString(in: params, keys: ["clientUserMessageId", "clientMessageId", "client_message_id"]),
            revision: Int(seq),
            createdAt: nil
        )
    }

    private mutating func nextSeq(for sessionID: SessionID?) -> EventSequence {
        let key = sessionID ?? "__appserver_global__"
        let next = (nextSeqBySessionID[key] ?? 0) + 1
        nextSeqBySessionID[key] = next
        return next
    }

    private mutating func completedAgentMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "agentMessage" else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        defer {
            if let itemID {
                agentMessageKindByItemID.removeValue(forKey: itemID)
            }
        }
        let text = firstString(in: item, keys: ["text", "content"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return nil
        }
        // completed item 是 app-server 的权威最终内容，用稳定 message id 覆盖同一条 streaming 气泡。
        let messageID = metadata.messageID ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID) ?? itemID ?? UUID().uuidString
        let sessionID = metadata.sessionID ?? ""
        let kind: MessageKind
        if let phase = firstString(in: item, keys: ["phase"]) {
            kind = phase == "commentary" ? .commentary : .message
        } else if let itemID {
            // 少数 app-server 版本 completed 不重复 phase，沿用 started 时记录的语义。
            kind = agentMessageKindByItemID[itemID] ?? .message
        } else {
            kind = .message
        }
        let message = AgentMessage(
            id: messageID,
            sessionID: sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .assistant,
            kind: kind,
            content: text,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
    }

    private mutating func rememberAgentMessageKind(
        from params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "agentMessage",
              let itemID = metadata.itemID ?? item["id"]?.stringValue
        else {
            return
        }
        agentMessageKindByItemID[itemID] = item["phase"]?.stringValue == "commentary" ? .commentary : .message
    }

    private func agentMessageKind(
        from params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> MessageKind {
        if firstString(in: params, keys: ["phase"]) == "commentary" ||
            params["item"]?.objectValue?["phase"]?.stringValue == "commentary" {
            return .commentary
        }
        guard let itemID = metadata.itemID else {
            return .message
        }
        return agentMessageKindByItemID[itemID] ?? .message
    }

    private func completedImageItemEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              let content = ConversationImageItemProjection.markdownContent(from: item) else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID
            ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID)
            ?? itemID
            ?? UUID().uuidString
        let message = AgentMessage(
            id: messageID,
            sessionID: metadata.sessionID ?? "",
            turnID: metadata.turnID,
            itemID: itemID,
            role: .assistant,
            kind: .message,
            content: content,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
    }

    private mutating func completedPlanEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        let steps = (params["plan"]?.arrayValue ?? []).compactMap { value -> String? in
            guard let object = value.objectValue,
                  let step = firstString(in: object, keys: ["step"]),
                  !step.isEmpty else {
                return nil
            }
            let marker: String
            switch firstString(in: object, keys: ["status"]) {
            case "completed": marker = "✓"
            case "inProgress": marker = "→"
            default: marker = "·"
            }
            return "\(marker) \(step)"
        }
        let explanation = firstString(in: params, keys: ["explanation"])
        let text = ([explanation].compactMap { $0 } + steps).joined(separator: "\n")
        guard !text.isEmpty else {
            return nil
        }
        return systemNoticeEvent(text: text, itemID: "turn-plan", kind: .plan, metadata: metadata)
    }

    private mutating func streamedSystemMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata,
        deltaKeys: [String],
        bufferSuffix: String,
        kind: MessageKind,
        activityCategory: ConversationActivityCategory? = nil
    ) -> AgentEvent? {
        guard let delta = firstString(in: params, keys: deltaKeys), !delta.isEmpty else {
            return nil
        }
        let key = [metadata.sessionID, metadata.turnID, metadata.itemID, bufferSuffix]
            .compactMap { $0 }
            .joined(separator: "#")
        let next = (streamedTextByKey[key] ?? "") + delta
        streamedTextByKey[key] = next
        let payload = activityCategory.map { category in
            ConversationActivityPayload(
                category: category,
                displayTitle: category == .thinking ? "推理摘要" : "过程更新",
                subtitle: next,
                status: "inProgress"
            )
        }
        return systemNoticeEvent(
            text: next,
            itemID: metadata.itemID ?? bufferSuffix,
            kind: kind,
            metadata: metadata,
            activityPayload: payload
        )
    }

    private func systemNoticeEvent(
        text: String,
        itemID: String,
        kind: MessageKind,
        metadata: AgentEventMetadata,
        activityPayload: ConversationActivityPayload? = nil
    ) -> AgentEvent {
        let projectedMetadata = metadataWithItemID(itemID, metadata: metadata)
        let messageID = projectedMetadata.messageID ?? itemID
        let message = AgentMessage(
            id: messageID,
            sessionID: projectedMetadata.sessionID ?? "",
            turnID: projectedMetadata.turnID,
            itemID: itemID,
            role: .system,
            kind: kind,
            content: text,
            activityPayload: activityPayload,
            createdAt: Date(),
            seq: projectedMetadata.seq,
            revision: projectedMetadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, projectedMetadata)
    }

    private func metadataWithItemID(
        _ itemID: String,
        metadata: AgentEventMetadata
    ) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: metadata.seq,
            sessionID: metadata.sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            messageID: appServerMessageID(turnID: metadata.turnID, itemID: itemID),
            clientMessageID: metadata.clientMessageID,
            revision: metadata.revision,
            createdAt: metadata.createdAt
        )
    }

    private func tokenUsageContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let usage = params["tokenUsage"]?.objectValue else {
            return nil
        }
        let total = usage["total"]?.objectValue ?? [:]
        let totalTokens = firstInt(in: total, keys: ["totalTokens"])
        let inputTokens = firstInt(in: total, keys: ["inputTokens"])
        let outputTokens = firstInt(in: total, keys: ["outputTokens"])
        let window = firstInt(in: usage, keys: ["modelContextWindow"])
        var parts: [String] = []
        if let totalTokens { parts.append("总计 \(totalTokens) tok") }
        if let inputTokens { parts.append("输入 \(inputTokens)") }
        if let outputTokens { parts.append("输出 \(outputTokens)") }
        if let window { parts.append("上下文 \(window)") }
        guard !parts.isEmpty else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: "token-usage",
                    kind: "token_usage",
                    title: "Token 使用量",
                    subtitle: parts.joined(separator: " · "),
                    status: "updated"
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func mcpProgressContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let message = firstString(in: params, keys: ["message"]), !message.isEmpty else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: metadata.itemID ?? "mcp-progress",
                    kind: "mcp_tool",
                    title: "MCP 工具调用",
                    subtitle: message,
                    status: "inProgress"
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func mcpServerStatusContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let name = firstString(in: params, keys: ["name"]),
              let status = firstString(in: params, keys: ["status"]) else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [SessionContextTask(
                    id: "mcp-server-\(name)",
                    kind: "mcp_server",
                    title: name,
                    subtitle: firstString(in: params, keys: ["error", "failureReason"]),
                    status: status
                )],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func completedProcessItemEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              let payload = ConversationActivityPayload(item: item)
        else {
            return nil
        }
        let content = payload.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return nil
        }
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID) ?? itemID ?? UUID().uuidString
        let sessionID = metadata.sessionID ?? ""
        let message = AgentMessage(
            id: messageID,
            sessionID: sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .system,
            kind: payload.messageKind,
            content: content,
            activityPayload: payload,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        let context = contextTask(from: item, fallbackStatus: firstString(in: params, keys: ["status"])).map { task in
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [task],
                updatedAt: Date()
            )
        }
        return .processItemCompleted(message, context, metadata)
    }

    private func itemContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              let task = contextTask(from: item, fallbackStatus: firstString(in: params, keys: ["status"]))
        else {
            return nil
        }
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [task],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func contextTask(
        from item: [String: CodexAppServerJSONValue],
        fallbackStatus: String?
    ) -> SessionContextTask? {
        let id = firstString(in: item, keys: ["id"]) ?? UUID().uuidString
        let status = firstString(in: item, keys: ["status"]) ?? fallbackStatus
        switch firstString(in: item, keys: ["type"]) {
        case "commandExecution":
            let title = firstString(in: item, keys: ["command", "processId"]) ?? "命令执行"
            let subtitle = firstString(in: item, keys: ["cwd"]) ?? commandActionSummary(from: item["commandActions"]?.arrayValue)
            return SessionContextTask(id: id, kind: "command", title: String(title.prefix(80)), subtitle: subtitle, status: status)
        case "fileChange":
            let changes = item["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let title = changes.isEmpty ? "文件变更" : "文件变更 x\(changes.count)"
            return SessionContextTask(id: id, kind: "file_change", title: title, subtitle: fileChangeTaskSummary(from: changes), status: status)
        case "mcpToolCall":
            let server = firstString(in: item, keys: ["server"])
            let tool = firstString(in: item, keys: ["tool"])
            let title = [server, tool].compactMap { $0 }.joined(separator: ".")
            return SessionContextTask(
                id: id,
                kind: "mcp_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? (title.isEmpty ? "MCP 工具" : title),
                subtitle: firstString(in: item, keys: ["pluginId"]),
                status: status
            )
        case "dynamicToolCall":
            let namespace = firstString(in: item, keys: ["namespace"])
            let tool = firstString(in: item, keys: ["tool"]) ?? "动态工具"
            let title = [namespace, tool].compactMap { $0 }.joined(separator: ".")
            return SessionContextTask(
                id: id,
                kind: "dynamic_tool",
                title: ConversationActivityPayload(item: item)?.displayTitle ?? title,
                subtitle: nil,
                status: status
            )
        case "collabAgentToolCall":
            let title = firstString(in: item, keys: ["tool", "agentNickname", "nickname"]) ?? "子 Agent"
            return SessionContextTask(id: id, kind: "subagent", title: title, subtitle: firstString(in: item, keys: ["agentRole", "role"]), status: status)
        default:
            return nil
        }
    }

    private func commandActionSummary(from actions: [CodexAppServerJSONValue]?) -> String? {
        for action in actions?.compactMap(\.objectValue) ?? [] {
            if let value = [firstString(in: action, keys: ["name"]), firstString(in: action, keys: ["path"])]
                .compactMap({ $0 })
                .joined(separator: " ")
                .nilIfEmpty {
                return value
            }
            if let query = firstString(in: action, keys: ["query"]) {
                return query
            }
        }
        return nil
    }

    private func fileChangeTaskSummary(from changes: [[String: CodexAppServerJSONValue]]) -> String? {
        guard !changes.isEmpty else {
            return nil
        }
        var parts = changes.prefix(3).compactMap { change in
            firstString(in: change, keys: ["path", "kind"])
        }
        if changes.count > parts.count {
            parts.append("+\(changes.count - parts.count)")
        }
        return parts.joined(separator: ", ")
    }

    private func fileChangeContextEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent {
        let change = fileChangeSummary(from: params)
        return .sessionContext(
            SessionContextSnapshot(
                sessionID: metadata.sessionID,
                threadID: metadata.sessionID,
                tasks: [
                    SessionContextTask(
                        id: metadata.itemID ?? change.path,
                        kind: "file_change",
                        title: "文件变更",
                        subtitle: change.path,
                        status: change.status
                    )
                ],
                updatedAt: Date()
            ),
            metadata
        )
    }

    private func fileChangeSummary(from params: [String: CodexAppServerJSONValue]) -> FileChangeSummary {
        let source = params["fileChange"]?.objectValue
            ?? params["change"]?.objectValue
            ?? params["diff"]?.objectValue
            ?? params["item"]?.objectValue
            ?? params
        return FileChangeSummary(
            path: firstString(in: source, keys: ["path", "filePath", "relativePath", "filename"]) ?? "workspace",
            status: firstString(in: source, keys: ["status", "kind", "type"]) ?? "modified",
            additions: firstInt(in: source, keys: ["additions", "added"]),
            deletions: firstInt(in: source, keys: ["deletions", "removed"])
        )
    }

    private func goal(from params: [String: CodexAppServerJSONValue]) -> ThreadGoal? {
        if let object = params["goal"]?.objectValue {
            return ThreadGoal(object: object)
        }
        return ThreadGoal(object: params)
    }

    private func errorPayload(from params: [String: CodexAppServerJSONValue], fallback: String) -> AgentErrorPayload {
        AgentErrorPayload(
            message: firstString(in: params, keys: ["message", "warning", "error"])
                ?? nestedString(in: params, key: "error", nestedKey: "message")
                ?? fallback,
            code: firstString(in: params, keys: ["code"])
                ?? nestedString(in: params, key: "error", nestedKey: "code"),
            retryable: params["retryable"]?.boolValue
        )
    }

    private func appServerMessageID(turnID: TurnID?, itemID: AgentItemID?) -> MessageID? {
        guard let itemID, !itemID.isEmpty else {
            return nil
        }
        guard let turnID, !turnID.isEmpty else {
            return itemID
        }
        return "appserver:\(turnID):\(itemID)"
    }

    private func firstString(in params: [String: CodexAppServerJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private func firstInt(in params: [String: CodexAppServerJSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = params[key]?.intValue {
                return value
            }
        }
        return nil
    }

    private func nestedString(
        in params: [String: CodexAppServerJSONValue],
        key: String,
        nestedKey: String
    ) -> String? {
        params[key]?.objectValue?[nestedKey]?.stringValue
    }

    private func userInputRequest(
        from params: [String: CodexAppServerJSONValue],
        requestID: String,
        metadata: AgentEventMetadata
    ) -> AgentUserInputRequest? {
        guard let threadID = metadata.sessionID ?? firstString(in: params, keys: ["threadId", "sessionId", "session_id"]) else {
            return nil
        }
        let itemID = metadata.itemID ?? firstString(in: params, keys: ["itemId", "item_id"]) ?? requestID
        let questions = (params["questions"]?.arrayValue ?? []).compactMap(userInputQuestion(from:))
        return AgentUserInputRequest(
            id: itemID,
            threadID: threadID,
            turnID: metadata.turnID ?? firstString(in: params, keys: ["turnId", "turn_id"]),
            itemID: itemID,
            questions: questions
        )
    }

    private func userInputQuestion(from value: CodexAppServerJSONValue) -> AgentUserInputQuestion? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        let options = (object["options"]?.arrayValue ?? []).compactMap(userInputOption(from:))
        return AgentUserInputQuestion(
            id: id,
            header: object["header"]?.stringValue ?? "",
            question: object["question"]?.stringValue ?? "",
            isOther: object["isOther"]?.boolValue ?? object["is_other"]?.boolValue ?? false,
            isSecret: object["isSecret"]?.boolValue ?? object["is_secret"]?.boolValue ?? false,
            options: options,
            multiSelect: object["multiSelect"]?.boolValue ?? object["multi_select"]?.boolValue
        )
    }

    private func userInputOption(from value: CodexAppServerJSONValue) -> AgentUserInputOption? {
        guard let object = value.objectValue,
              let label = object["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return AgentUserInputOption(label: label, description: object["description"]?.stringValue)
    }

    private func mcpElicitationUserInputRequest(
        from params: [String: CodexAppServerJSONValue],
        requestID: String,
        metadata: AgentEventMetadata
    ) -> AgentUserInputRequest? {
        guard let threadID = metadata.sessionID else {
            return nil
        }
        let properties = params["requestedSchema"]?.objectValue?["properties"]?.objectValue ?? [:]
        var questions = properties.keys.sorted().compactMap { key -> AgentUserInputQuestion? in
            guard let schema = properties[key]?.objectValue else {
                return nil
            }
            let options = mcpElicitationOptions(from: schema)
            let title = firstString(in: schema, keys: ["title"]) ?? key
            let description = firstString(in: schema, keys: ["description"])
                ?? "请填写 \(title)"
            return AgentUserInputQuestion(
                id: key,
                header: title,
                question: description,
                isOther: options.isEmpty || schema["type"]?.stringValue == "array",
                isSecret: false,
                options: options
            )
        }
        if questions.isEmpty {
            // openai/form 允许任意 schema。当前 UI 无法安全渲染时，保留一个显式文本回答入口；
            // 若用户不提交任何内容，runtime 会回 decline 而不是误 accept。
            questions = [AgentUserInputQuestion(
                id: "response",
                header: firstString(in: params, keys: ["serverName"]) ?? "MCP",
                question: firstString(in: params, keys: ["message"]) ?? "MCP 服务请求补充信息",
                isOther: true,
                isSecret: false,
                options: []
            )]
        }
        return AgentUserInputRequest(
            id: requestID,
            threadID: threadID,
            turnID: metadata.turnID,
            itemID: requestID,
            questions: questions
        )
    }

    private func mcpElicitationOptions(
        from schema: [String: CodexAppServerJSONValue]
    ) -> [AgentUserInputOption] {
        if schema["type"]?.stringValue == "boolean" {
            return [
                AgentUserInputOption(label: "true", description: "是"),
                AgentUserInputOption(label: "false", description: "否")
            ]
        }
        if let values = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
            let names = schema["enumNames"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return values.enumerated().map { index, value in
                AgentUserInputOption(label: value, description: names.indices.contains(index) ? names[index] : nil)
            }
        }
        let variants = schema["oneOf"]?.arrayValue
            ?? schema["items"]?.objectValue?["anyOf"]?.arrayValue
            ?? []
        let titled = variants.compactMap { value -> AgentUserInputOption? in
            guard let object = value.objectValue,
                  let raw = object["const"]?.stringValue else {
                return nil
            }
            return AgentUserInputOption(label: raw, description: object["title"]?.stringValue)
        }
        if !titled.isEmpty {
            return titled
        }
        let arrayEnum = schema["items"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return arrayEnum.map { AgentUserInputOption(label: $0, description: nil) }
    }

    private func isApprovalLike(
        method: String,
        params: [String: CodexAppServerJSONValue] = [:]
    ) -> Bool {
        let lower = method.lowercased()
        return lower.contains("approval")
            || (method == "mcpServer/elicitation/request" && params["mode"]?.stringValue == "url")
    }

    private func approvalKind(method: String) -> String {
        let lower = method.lowercased()
        if lower.contains("filechange") || lower.contains("applypatch") {
            return "file_change"
        }
        if lower.contains("permission") {
            return "permission"
        }
        if lower.contains("mcpserver/elicitation") {
            return "mcp_elicitation"
        }
        return "command"
    }

    private func approvalTitle(kind: String, params: [String: CodexAppServerJSONValue]) -> String {
        switch kind {
        case "file_change":
            return "Agent 请求修改文件"
        case "permission":
            return "Agent 请求提升权限"
        case "user_input":
            return "Agent 请求补充输入"
        case "mcp_elicitation":
            let server = firstString(in: params, keys: ["serverName"]) ?? "MCP 服务"
            return "\(server) 请求用户确认"
        default:
            if let command = commandSummary(params: params) {
                return "Agent 请求执行命令：\(command)"
            }
            if let toolName = firstString(in: params, keys: ["toolName", "tool_name"]) {
                return "Claude 请求使用工具：\(toolName)"
            }
            return "Agent 请求执行命令"
        }
    }

    private func approvalBody(kind: String, params: [String: CodexAppServerJSONValue]) -> String? {
        if kind == "command" {
            let command = commandSummary(params: params)
            let toolName = firstString(in: params, keys: ["toolName", "tool_name"])
            let inputSummary = firstString(in: params, keys: ["inputSummary", "input_summary"])
            let reason = firstString(in: params, keys: ["reason", "message"])
            return [command, toolName, inputSummary, reason].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
        }
        if kind == "mcp_elicitation" {
            return [
                firstString(in: params, keys: ["message"]),
                firstString(in: params, keys: ["url"])
            ].compactMap { $0 }.joined(separator: "\n\n")
        }
        let path = firstString(in: params, keys: ["path", "filePath", "file_path", "grantRoot", "grant_root"])
        let diff = firstString(in: params, keys: ["diff", "patch"])
        let inputSummary = firstString(in: params, keys: ["inputSummary", "input_summary", "prompt"])
        let reason = firstString(in: params, keys: ["reason", "message"])
        return [path, diff, inputSummary, reason].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
    }

    private func eligiblePersistentPermissionRules(
        from params: [String: CodexAppServerJSONValue]
    ) -> [String]? {
        let suggestions = params["permissionSuggestions"]?.arrayValue
            ?? params["permission_suggestions"]?.arrayValue
            ?? []
        var rules: [String] = []
        for value in suggestions {
            guard let suggestion = value.objectValue,
                  firstString(in: suggestion, keys: ["type"])?.lowercased() == "addrules",
                  firstString(in: suggestion, keys: ["behavior"])?.lowercased() == "allow",
                  firstString(in: suggestion, keys: ["destination"])?.lowercased() == "localsettings"
            else {
                continue
            }
            for ruleValue in suggestion["rules"]?.arrayValue ?? [] {
                if let rule = ruleValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty {
                    rules.append(rule)
                    continue
                }
                guard let object = ruleValue.objectValue,
                      let toolName = firstString(in: object, keys: ["toolName", "tool_name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !toolName.isEmpty else {
                    continue
                }
                let content = firstString(in: object, keys: ["ruleContent", "rule_content"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                rules.append(content?.isEmpty == false ? "\(toolName)(\(content!))" : toolName)
            }
        }
        var seen: Set<String> = []
        let unique = rules.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    private func commandSummary(params: [String: CodexAppServerJSONValue]) -> String? {
        if let command = params["command"]?.stringValue {
            return command
        }
        if let parts = params["command"]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
