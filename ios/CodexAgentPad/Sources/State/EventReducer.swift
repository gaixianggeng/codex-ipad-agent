import Foundation

struct EventReducerOutput {
    var upsertSessions: [AgentSession] = []
    var statusUpdates: [(SessionID, String)] = []
    var foregroundUpdates: [(SessionID, SessionForegroundActivity, UInt64?)] = []
    var foregroundClears: [SessionID] = []
    var messageMutations: [EventReducerMessageMutation] = []
    var logAppends: [EventReducerLogAppend] = []
    var statusMessage: String?
    var errorMessage: String?
    var disconnectWebSocket = false
}

enum EventReducerMessageMutation {
    case assistantDelta(AgentDelta, AgentEventMetadata, SessionID)
    case completed(AgentMessage, AgentEventMetadata, SessionID)
    case system(String, SessionID, MessageKind)
    case markCurrentAssistantCompleted(AgentEventMetadata, SessionID)
    case ingestTerminalOutput(String, SessionID)
}

struct EventReducerLogAppend {
    let text: String
    let sessionID: SessionID
    let seq: EventSequence?
}

actor EventReducer {
    func reduce(
        _ event: AgentEvent,
        fallbackSessionID: SessionID,
        outputIdleClearDelay: UInt64
    ) -> EventReducerOutput {
        var output = EventReducerOutput()

        switch event {
        case .session(let session):
            output.upsertSessions.append(session)
        case .sessionRow(let row, _):
            output.upsertSessions.append(AgentSession(row: row))
        case .sessionStatus(let status, let metadata):
            guard let id = metadata.sessionID, let status else {
                return output
            }
            output.statusUpdates.append((id, status))
            if status != "running" {
                output.foregroundClears.append(id)
            }
        case .turnStarted(let metadata):
            guard let id = metadata.sessionID else {
                return output
            }
            output.statusUpdates.append((id, "running"))
            output.foregroundUpdates.append((id, .waitingForAssistant, nil))
        case .assistantDelta(let delta, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.foregroundUpdates.append((id, .receivingAssistant, outputIdleClearDelay))
            output.messageMutations.append(.assistantDelta(delta, metadata, fallbackSessionID))
        case .messageCompleted(let message, let metadata):
            output.messageMutations.append(.completed(message, metadata, fallbackSessionID))
            if message.role == .assistant {
                output.foregroundClears.append(metadata.sessionID ?? message.sessionID)
            }
        case .logDelta(let delta, let metadata):
            output.logAppends.append(EventReducerLogAppend(
                text: delta.text,
                sessionID: metadata.sessionID ?? fallbackSessionID,
                seq: metadata.seq
            ))
        case .diffUpdated(let change, _):
            output.messageMutations.append(.system(
                "文件变更：\(change.path) \(change.status)",
                fallbackSessionID,
                .fileChangeSummary
            ))
        case .approvalRequest(let request, let metadata):
            output.statusUpdates.append((metadata.sessionID ?? fallbackSessionID, "waiting_for_approval"))
            let risk = request.risk.map { "，风险：\($0)" } ?? ""
            output.messageMutations.append(.system("等待审批：\(request.title)\(risk)", fallbackSessionID, .approval))
        case .turnCompleted(let metadata):
            output.messageMutations.append(.markCurrentAssistantCompleted(metadata, fallbackSessionID))
            output.foregroundClears.append(metadata.sessionID ?? fallbackSessionID)
        case .warning(let payload, _):
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] warning: \(payload.message)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
            output.messageMutations.append(.system("运行警告：\(payload.message)", fallbackSessionID, .error))
        case .output(let data, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.foregroundUpdates.append((id, .receivingAssistant, outputIdleClearDelay))
            // PTY fallback 仍进入日志层；结构化消息落地后 MessageStore 会按稳定 id 去重。
            output.logAppends.append(EventReducerLogAppend(text: data, sessionID: id, seq: metadata.seq))
            output.messageMutations.append(.ingestTerminalOutput(data, id))
        case .exit(let result):
            output.statusUpdates.append((fallbackSessionID, "closed"))
            output.foregroundClears.append(fallbackSessionID)
            let reason = result.reason ?? "code=\(result.code ?? 0)"
            output.messageMutations.append(.system("Codex 会话已结束：\(reason)", fallbackSessionID, .message))
            output.disconnectWebSocket = true
        case .error(let message):
            output.foregroundClears.append(fallbackSessionID)
            output.errorMessage = message
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] \(message)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
            output.messageMutations.append(.system("运行错误：\(message)", fallbackSessionID, .error))
        case .pong:
            output.statusMessage = "WebSocket 心跳正常"
        case .unknown(let type):
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] 未知消息类型：\(type)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
        }

        return output
    }
}
