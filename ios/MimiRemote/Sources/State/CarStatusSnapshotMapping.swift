import Foundation

extension CarStatusSnapshotV1 {
    /// 映射只读取结构化状态，不把审批标题、消息、目录或连接信息带入共享容器。
    init(profileID: String, session: AgentSession, isReachable: Bool, now: Date) {
        self.init(
            profileID: profileID,
            sessionID: session.id,
            projectDisplayName: session.project,
            sessionTitle: session.title,
            displayStatus: Self.status(for: session, isReachable: isReachable),
            activityDate: session.recencyAt ?? session.updatedAt ?? session.createdAt ?? now,
            publishedAt: now
        )
    }

    static func status(for session: AgentSession, isReachable: Bool) -> CarStatusDisplayStatus {
        // 失败是明确终态，不能被历史残留的待处理字段覆盖。
        if session.status == SessionStatus.failed.rawValue {
            return .failed
        }
        if session.status == SessionStatus.waitingForApproval.rawValue
            || session.status == SessionStatus.waitingForInput.rawValue
            || session.pendingApproval != nil
            || session.pendingUserInput != nil {
            return .needsAttention
        }
        // 明确断网时不继续宣称任务仍在运行或已经同步完成；失败和待处理状态仍优先保留。
        if !isReachable {
            return .offline
        }
        if session.activeTurnID != nil || session.status == SessionStatus.running.rawValue {
            return .running
        }
        switch session.status {
        case SessionStatus.completed.rawValue,
             SessionStatus.closed.rawValue,
             SessionStatus.history.rawValue,
             SessionStatus.idle.rawValue:
            return .completed
        default:
            return .completed
        }
    }
}
