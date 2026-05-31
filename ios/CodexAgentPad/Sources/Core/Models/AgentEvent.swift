import Foundation

enum AgentEvent {
    case session(AgentSession)
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case output(String)
    case exit(ExitResult)
    case error(String)
    case pong
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
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
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
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: "未知警告"), metadata)
        case "output":
            self = .output(try container.decodeIfPresent(String.self, forKey: .data) ?? "")
        case "exit":
            self = .exit(try container.decodeIfPresent(ExitResult.self, forKey: .exit) ?? ExitResult(code: nil, reason: nil))
        case "error":
            self = .error(try container.decodeIfPresent(String.self, forKey: .error) ?? "未知错误")
        case "pong":
            self = .pong
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
        // 兼容早期 agentd 直接把增量文本放在 data 字段的格式。
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
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
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
            } else {
                self = .sessionStatus(try container.decodeIfPresent(String.self, forKey: .status), metadata)
            }
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

struct ClientWebSocketMessage: Encodable {
    let type: String
    let data: String?
    let cols: Int?
    let rows: Int?
    let clientMessageID: ClientMessageID?

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case cols
        case rows
        case clientMessageID = "client_message_id"
    }

    init(type: String, data: String? = nil, cols: Int? = nil, rows: Int? = nil, clientMessageID: ClientMessageID? = nil) {
        self.type = type
        self.data = data
        self.cols = cols
        self.rows = rows
        self.clientMessageID = clientMessageID
    }
}
