import Foundation

// turn/start ACK 等待窗口的终态观察独立维护，避免通知投影继续膨胀。
extension CodexAppServerSessionRuntime {
    func isTerminalHistoryStatus(_ value: CodexAppServerJSONValue?) -> Bool {
        let raw = value?.stringValue
            ?? value?.objectValue?["type"]?.stringValue
            ?? value?.objectValue?["status"]?.stringValue
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "succeeded", "success", "failed", "failure", "interrupted", "cancelled", "canceled", "aborted":
            return true
        default:
            return false
        }
    }

    func recordPendingTurnStartBoundary(from notification: CodexAppServerNotification) {
        guard notification.method == "turn/completed"
                || notification.method == "thread/closed" else {
            return
        }
        let params = notification.params?.objectValue ?? [:]
        guard let threadID = params["threadId"]?.stringValue else {
            return
        }
        guard var observation = pendingTurnStartObservationsBySessionID[threadID] else {
            return
        }
        if notification.method == "thread/closed" {
            observation.threadClosed = true
        } else if let turnID = completedTurnID(from: params) {
            observation.terminalTurnIDs.insert(turnID)
        } else {
            // 旧 bridge 可能不带 turn ID。此时不能把当前 active turn 当作旧 turn；
            // 先关联唯一正在等待 ACK 的请求，待 ACK 返回 ID 后再完成精确对账。
            observation.sawUnidentifiedTerminal = true
        }
        pendingTurnStartObservationsBySessionID[threadID] = observation
    }

    func completedTurnID(from params: [String: CodexAppServerJSONValue]) -> TurnID? {
        params["turnId"]?.stringValue
            ?? params["turn"]?.objectValue?["id"]?.stringValue
    }

    func turnStartObservationMatchesTerminal(
        _ observation: CodexAppServerPendingTurnStartObservation,
        turnID: TurnID?
    ) -> Bool {
        if observation.threadClosed {
            return true
        }
        guard let turnID else {
            return false
        }
        return observation.terminalTurnIDs.contains(turnID)
    }

    func responseTurnIsTerminal(_ turn: [String: CodexAppServerJSONValue]?) -> Bool {
        guard let turn else {
            return false
        }
        if isTerminalHistoryStatus(turn["status"]) {
            return true
        }
        return firstDate(in: turn, keys: ["completedAt", "completed_at"]) != nil
    }
}
