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
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if left == right {
                // 后端 cursor 使用 updated_at + id 做 keyset，全端都保持同一个全序。
                return lhs.id > rhs.id
            }
            return left > right
        }
    }
}
