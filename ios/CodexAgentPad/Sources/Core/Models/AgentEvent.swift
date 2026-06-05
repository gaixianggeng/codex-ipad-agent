import Foundation

enum AgentEvent {
    case session(AgentSession)
    case sessionRow(DataFlowSessionRow, AgentEventMetadata)
    case sessionStatus(String?, AgentEventMetadata)
    case sessionContext(SessionContextSnapshot, AgentEventMetadata)
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
    case turnCompleted(AgentEventMetadata)
    case warning(AgentErrorPayload, AgentEventMetadata)
    case error(String)
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
        case context
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
        case "turn_completed":
            self = .turnCompleted(metadata)
        case "warning":
            self = .warning(try Self.decodePayload(from: container, key: .warning, fallback: "未知警告"), metadata)
        case "error":
            self = .error(try container.decodeIfPresent(String.self, forKey: .error) ?? "未知错误")
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
    case turnStarted(AgentEventMetadata)
    case assistantDelta(AgentDelta, AgentEventMetadata)
    case messageCompleted(AgentMessage, AgentEventMetadata)
    case logDelta(LogDelta, AgentEventMetadata)
    case diffUpdated(FileChangeSummary, AgentEventMetadata)
    case approvalRequest(AgentApprovalRequest, AgentEventMetadata)
    case approvalResolved(AgentEventMetadata)
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
        case context
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

    mutating func project(_ notification: CodexAppServerNotification) -> AgentEvent? {
        let params = notification.params?.objectValue ?? [:]
        let metadata = makeMetadata(from: params)

        switch notification.method {
        case "turn/started":
            return .turnStarted(metadata)
        case "item/agentMessage/delta":
            guard let text = firstString(in: params, keys: ["delta", "text"]), !text.isEmpty else {
                return nil
            }
            return .assistantDelta(AgentDelta(text: text, role: .assistant, kind: .message), metadata)
        case "item/started":
            return itemContextEvent(params: params, metadata: metadata)
        case "item/completed":
            return completedAgentMessageEvent(params: params, metadata: metadata)
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
            return .diffUpdated(fileChangeSummary(from: params), metadata)
        case "turn/completed":
            return .turnCompleted(metadata)
        case "serverRequest/resolved":
            return .approvalResolved(metadata)
        case "warning":
            return .warning(errorPayload(from: params, fallback: "app-server warning"), metadata)
        case "error":
            return .error(firstString(in: params, keys: ["message", "error"]) ?? nestedString(in: params, key: "error", nestedKey: "message") ?? "app-server error")
        default:
            return nil
        }
    }

    mutating func project(_ request: CodexAppServerServerRequest) -> AgentEvent? {
        guard isApprovalLike(method: request.method) else {
            return nil
        }
        let params = request.params?.objectValue ?? [:]
        let metadata = makeMetadata(from: params)
        let kind = approvalKind(method: request.method)
        let itemID = metadata.itemID ?? request.id.description
        return .approvalRequest(
            AgentApprovalRequest(
                id: firstString(in: params, keys: ["approvalId"]) ?? itemID,
                title: approvalTitle(kind: kind, params: params),
                body: approvalBody(kind: kind, params: params),
                kind: kind,
                risk: "high"
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

    private func completedAgentMessageEvent(
        params: [String: CodexAppServerJSONValue],
        metadata: AgentEventMetadata
    ) -> AgentEvent? {
        guard let item = params["item"]?.objectValue,
              item["type"]?.stringValue == "agentMessage" else {
            return nil
        }
        let text = firstString(in: item, keys: ["text", "content"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return nil
        }
        // completed item 是 app-server 的权威最终内容，用稳定 message id 覆盖同一条 streaming 气泡。
        let itemID = metadata.itemID ?? item["id"]?.stringValue
        let messageID = metadata.messageID ?? appServerMessageID(turnID: metadata.turnID, itemID: itemID) ?? itemID ?? UUID().uuidString
        let sessionID = metadata.sessionID ?? ""
        let message = AgentMessage(
            id: messageID,
            sessionID: sessionID,
            turnID: metadata.turnID,
            itemID: itemID,
            role: .assistant,
            kind: .message,
            content: text,
            createdAt: Date(),
            seq: metadata.seq,
            revision: metadata.revision ?? 0,
            sendStatus: .confirmed
        )
        return .messageCompleted(message, metadata)
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
                title: title.isEmpty ? "MCP 工具" : title,
                subtitle: firstString(in: item, keys: ["pluginId"]),
                status: status
            )
        case "dynamicToolCall":
            let namespace = firstString(in: item, keys: ["namespace"])
            let tool = firstString(in: item, keys: ["tool"]) ?? "动态工具"
            let title = [namespace, tool].compactMap { $0 }.joined(separator: ".")
            return SessionContextTask(id: id, kind: "dynamic_tool", title: title, subtitle: "dynamic tool", status: status)
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

    private func isApprovalLike(method: String) -> Bool {
        let lower = method.lowercased()
        return lower.contains("approval") || lower.contains("requestuserinput")
    }

    private func approvalKind(method: String) -> String {
        let lower = method.lowercased()
        if lower.contains("filechange") || lower.contains("applypatch") {
            return "file_change"
        }
        if lower.contains("permission") {
            return "permission"
        }
        if lower.contains("requestuserinput") {
            return "user_input"
        }
        return "command"
    }

    private func approvalTitle(kind: String, params: [String: CodexAppServerJSONValue]) -> String {
        switch kind {
        case "file_change":
            return "Codex 请求修改文件"
        case "permission":
            return "Codex 请求提升权限"
        case "user_input":
            return "Codex 请求补充输入"
        default:
            if let command = commandSummary(params: params) {
                return "Codex 请求执行命令：\(command)"
            }
            return "Codex 请求执行命令"
        }
    }

    private func approvalBody(kind: String, params: [String: CodexAppServerJSONValue]) -> String? {
        if kind == "command" {
            let command = commandSummary(params: params)
            let reason = firstString(in: params, keys: ["reason", "message"])
            return [command, reason].compactMap { $0 }.joined(separator: "\n\n")
        }
        return firstString(in: params, keys: ["reason", "message", "diff", "path", "prompt"])
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
