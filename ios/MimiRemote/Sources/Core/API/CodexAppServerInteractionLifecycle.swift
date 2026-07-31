import Foundation

// 终态请求清理与跨 pump 乱序防护独立维护，避免事件投影文件继续膨胀。
extension CodexAppServerSessionRuntime {
    private var terminalInteractionTombstoneLimit: Int { 512 }

    func isTerminalInteractionNotification(_ notification: CodexAppServerNotification) -> Bool {
        switch notification.method {
        case "turn/completed", "thread/closed":
            return true
        case "error":
            // app-server 会在同一 turn 内重试部分错误；willRetry 为 true 时仍会继续发送
            // 审批或补充信息请求，不能提前写 tombstone 或清空 pending request。
            return notification.params?.objectValue?["willRetry"]?.boolValue != true
        default:
            return false
        }
    }

    func clearPendingServerRequestsForTerminalNotification(_ notification: CodexAppServerNotification) {
        let params = notification.params?.objectValue ?? [:]
        guard let sessionID = approvalSessionID(from: params) else {
            return
        }
        let turnID = notification.method == "thread/closed"
            ? nil
            : firstString(in: params, keys: ["turnId", "turnID", "turn_id"])
                ?? params["turn"]?.objectValue?["id"]?.stringValue

        for request in Set(pendingApprovalRequestsByID.values)
        where terminalNotificationMatches(request: request, sessionID: sessionID, turnID: turnID) {
            removePendingApprovalRequest(request)
        }
        for request in Set(pendingUserInputRequestsByID.values)
        where terminalNotificationMatches(request: request, sessionID: sessionID, turnID: turnID) {
            removePendingUserInputRequest(request)
        }
        discardBufferedInteractionRequests(sessionID: sessionID, turnID: turnID)
    }

    func terminalNotificationMatches(
        request: CodexAppServerServerRequest,
        sessionID: SessionID,
        turnID: TurnID?
    ) -> Bool {
        guard approvalSessionID(for: request) == sessionID else {
            return false
        }
        guard let turnID else {
            return true
        }
        // URL 型 MCP elicitation 是协议允许的 thread 级独立请求，不属于刚结束的 turn。
        // 其它无 turnId 交互仍按当前 turn 处理，避免旧 form 在 reattach 时复活。
        guard let requestTurnID = approvalTurnID(for: request) else {
            return !isTurnIndependentMCPElicitation(request)
        }
        return requestTurnID == turnID
    }

    func discardBufferedInteractionRequests(sessionID: SessionID, turnID: TurnID?) {
        guard var events = bufferedEventsBySessionID[sessionID] else {
            return
        }
        events.removeAll { event in
            switch event {
            case .approvalRequest(_, let metadata),
                 .userInputRequest(_, let metadata):
                guard let turnID else {
                    return true
                }
                return metadata.turnID == nil || metadata.turnID == turnID
            default:
                return false
            }
        }
        if events.isEmpty {
            bufferedEventsBySessionID.removeValue(forKey: sessionID)
        } else {
            bufferedEventsBySessionID[sessionID] = events
        }
    }

    func isResolvedServerRequestTombstoned(_ request: CodexAppServerServerRequest) -> Bool {
        let sessionID = approvalSessionID(for: request)
        let ids = uniqueStrings([
            approvalID(for: request),
            userInputRequestID(for: request),
            request.id.description
        ].compactMap { $0 })
        return ids.contains { id in
            if let sessionID,
               resolvedServerRequestTombstonesByKey[
                   resolvedRequestTombstoneKey(sessionID: sessionID, requestID: id)
               ] != nil {
                return true
            }
            return resolvedServerRequestTombstonesByKey[
                resolvedRequestTombstoneKey(sessionID: nil, requestID: id)
            ] != nil
        }
    }

    func isTerminallyStaleServerRequest(_ request: CodexAppServerServerRequest) -> Bool {
        guard let sessionID = approvalSessionID(for: request) else {
            return false
        }
        if let turnID = approvalTurnID(for: request),
           terminalTurnTombstonesByKey[
               terminalTurnTombstoneKey(sessionID: sessionID, turnID: turnID)
           ] != nil {
            return true
        }
        guard approvalTurnID(for: request) == nil,
              terminalSessionBarriers[sessionID] != nil else {
            return false
        }
        // URL 型 MCP elicitation 可以在 thread 空闲时独立到达，不能被上一轮的 session
        // barrier 当作迟到请求拒绝；form 和工具授权仍保留原有 fail-closed 防护。
        if isTurnIndependentMCPElicitation(request) {
            return false
        }
        // 新 turn 的 RPC 与 turn/started 通知也可能跨 pump 乱序；本地已经明确在启动或持有
        // 非 terminal active turn 时，无 turnId MCP 请求属于新一轮，不能被上一轮 barrier 误杀。
        if sessionsStartingTurn.contains(sessionID)
            || contextsBySessionID[sessionID]?.activeTurnID != nil {
            return false
        }
        return true
    }

    func isTurnIndependentMCPElicitation(_ request: CodexAppServerServerRequest) -> Bool {
        guard request.method == "mcpServer/elicitation/request" else {
            return false
        }
        return request.params?.objectValue?["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "url"
    }

    func resolvedRequestTombstoneKey(sessionID: SessionID?, requestID: String) -> String {
        "\(sessionID ?? "*")#\(requestID)"
    }

    func terminalTurnTombstoneKey(sessionID: SessionID, turnID: TurnID) -> String {
        "\(sessionID)#\(turnID)"
    }

    func pruneInteractionTombstones() {
        for key in oldestTombstoneKeysToRemove(resolvedServerRequestTombstonesByKey) {
            resolvedServerRequestTombstonesByKey.removeValue(forKey: key)
        }
        for key in oldestTombstoneKeysToRemove(terminalTurnTombstonesByKey) {
            terminalTurnTombstonesByKey.removeValue(forKey: key)
        }
        for key in oldestTombstoneKeysToRemove(terminalSessionBarriers) {
            terminalSessionBarriers.removeValue(forKey: key)
        }
    }

    func oldestTombstoneKeysToRemove<Key: Hashable>(_ entries: [Key: Date]) -> [Key] {
        guard entries.count > terminalInteractionTombstoneLimit else {
            return []
        }
        return entries
            .sorted(by: { $0.value < $1.value })
            .prefix(entries.count - terminalInteractionTombstoneLimit)
            .map(\.key)
    }
}
