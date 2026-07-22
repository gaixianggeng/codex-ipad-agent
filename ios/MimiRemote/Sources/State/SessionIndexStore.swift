import Foundation

struct SessionIndexStore {
    static func replacingSessions(_ current: [AgentSession], with fresh: [AgentSession], projectID: String?) -> [AgentSession] {
        let scopedFresh: [AgentSession]
        if let projectID {
            scopedFresh = fresh.filter { $0.projectID == projectID }
        } else {
            scopedFresh = fresh
        }

        var freshIDs: Set<SessionID> = []
        freshIDs.reserveCapacity(scopedFresh.count)
        for session in scopedFresh {
            freshIDs.insert(session.id)
        }

        let kept = current.filter { session in
            if freshIDs.contains(session.id) {
                return false
            }
            guard let projectID else {
                return false
            }
            return session.projectID != projectID
        }
        return scopedFresh + kept
    }

    static func sortedSessions(_ items: [AgentSession]) -> [AgentSession] {
        items.sorted { lhs, rhs in
            let left = orderingDate(for: lhs)
            let right = orderingDate(for: rhs)
            if left == right {
                // Codex 的 recency_at cursor 仍以 id 打破同秒并列；全端保持同一个稳定全序。
                return lhs.id > rhs.id
            }
            return left > right
        }
    }

    static func orderingDate(for session: AgentSession) -> Date {
        session.recencyAt ?? session.updatedAt ?? session.createdAt ?? .distantPast
    }
}
