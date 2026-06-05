import Foundation

struct EventReducerOutput {
    var upsertSessions: [AgentSession] = []
    var statusUpdates: [(SessionID, String)] = []
    var pendingApprovalUpdates: [(SessionID, ApprovalSummary?)] = []
    var pendingApprovalTaskClears: [SessionID] = []
    var contextUpdates: [(SessionContextSnapshot, SessionID?)] = []
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
    case resolveLatestPendingApproval(SessionID)
    case markCurrentAssistantCompleted(AgentEventMetadata, SessionID)
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
            if let context = session.context {
                output.contextUpdates.append((context, session.id))
            }
        case .sessionRow(let row, _):
            let session = AgentSession(row: row)
            output.upsertSessions.append(session)
            if let context = row.context {
                output.contextUpdates.append((context, row.id))
            }
        case .sessionStatus(let status, let metadata):
            guard let id = metadata.sessionID, let status else {
                return output
            }
            output.statusUpdates.append((id, status))
            if status != "waiting_for_approval" {
                output.pendingApprovalUpdates.append((id, nil))
            }
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: contextStatusType(from: status)), updatedAt: Date()),
                id
            ))
            if status != "running" {
                output.foregroundClears.append(id)
            }
        case .sessionContext(let context, let metadata):
            output.contextUpdates.append((context, metadata.sessionID))
        case .turnStarted(let metadata):
            guard let id = metadata.sessionID else {
                return output
            }
            output.statusUpdates.append((id, "running"))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
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
        case .diffUpdated(let change, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.contextUpdates.append((
                SessionContextSnapshot(
                    tasks: [SessionContextTask(id: change.path, kind: "file_change", title: "文件变更", subtitle: change.path, status: change.status)],
                    updatedAt: Date()
                ),
                id
            ))
            output.messageMutations.append(.system(
                "文件变更：\(change.path) \(change.status)",
                id,
                .fileChangeSummary
            ))
        case .approvalRequest(let request, let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.statusUpdates.append((id, "waiting_for_approval"))
            // 输入框上方的审批卡读取 session.pendingApproval；审批事件不能只写入时间线记录。
            output.pendingApprovalUpdates.append((
                id,
                ApprovalSummary(id: request.id, title: request.title, kind: request.kind, count: nil)
            ))
            output.contextUpdates.append((
                SessionContextSnapshot(
                    sessionID: id,
                    status: SessionContextStatus(type: "active", activeFlags: ["waitingOnApproval"]),
                    tasks: [SessionContextTask(id: request.id, kind: request.kind, title: request.title, subtitle: request.risk, status: "waiting")],
                    updatedAt: Date()
                ),
                id
            ))
            let risk = request.risk.map { "，风险：\($0)" } ?? ""
            output.messageMutations.append(.system("等待审批：\(request.title)\(risk)", id, .approval))
        case .approvalResolved(let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            // app-server 会在 JSON-RPC server request 被处理后发 serverRequest/resolved；
            // 这里只收起 pending 卡片，并把本地等待态恢复为运行态，避免历史审批残留挡住输入框。
            output.pendingApprovalUpdates.append((id, nil))
            output.statusUpdates.append((id, "running"))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
            output.pendingApprovalTaskClears.append(id)
            output.messageMutations.append(.resolveLatestPendingApproval(id))
        case .turnCompleted(let metadata):
            let id = metadata.sessionID ?? fallbackSessionID
            output.pendingApprovalUpdates.append((id, nil))
            output.contextUpdates.append((
                SessionContextSnapshot(sessionID: id, status: SessionContextStatus(type: "active"), updatedAt: Date()),
                id
            ))
            output.pendingApprovalTaskClears.append(id)
            output.messageMutations.append(.resolveLatestPendingApproval(id))
            output.messageMutations.append(.markCurrentAssistantCompleted(metadata, fallbackSessionID))
            output.foregroundClears.append(id)
        case .warning(let payload, _):
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] warning: \(payload.message)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
            output.messageMutations.append(.system("运行警告：\(payload.message)", fallbackSessionID, .error))
        case .error(let message):
            output.foregroundClears.append(fallbackSessionID)
            output.pendingApprovalUpdates.append((fallbackSessionID, nil))
            output.errorMessage = message
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] \(message)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
            output.messageMutations.append(.system("运行错误：\(message)", fallbackSessionID, .error))
        case .unknown(let type):
            output.logAppends.append(EventReducerLogAppend(
                text: "\n[agentd] 未知消息类型：\(type)\n",
                sessionID: fallbackSessionID,
                seq: nil
            ))
        }

        return output
    }

    private func contextStatusType(from status: String) -> String {
        switch status {
        case "running", "waiting_for_approval", "waiting_for_input":
            return "active"
        case "failed":
            return "systemError"
        case "history":
            return "notLoaded"
        default:
            return status
        }
    }
}
