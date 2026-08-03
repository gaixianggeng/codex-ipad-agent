import Foundation

struct WorkspaceSessionPresentationKey: Hashable {
    let hostScope: HostScope
    let workspaceID: String
    let workspacePath: String
}

enum WorkspaceSessionPresentation {
    static func hasCompleteFirstPage(consistency: SessionListConsistency?) -> Bool {
        consistency == .authoritative
    }

    static func visibleSessions(_ sessions: [AgentSession], limit: Int) -> [AgentSession] {
        Array(sessions.prefix(max(1, limit)))
    }

    static func canLoadMore(
        loadedCount: Int,
        visibleLimit: Int,
        remoteHasMore: Bool
    ) -> Bool {
        loadedCount > visibleLimit || remoteHasMore
    }

    static func nextVisibleLimit(current: Int, pageSize: Int) -> Int {
        max(1, current) + max(1, pageSize)
    }

    static func shouldRequestRemotePage(
        loadedCount: Int,
        targetVisibleLimit: Int,
        remoteHasMore: Bool
    ) -> Bool {
        remoteHasMore && loadedCount < targetVisibleLimit
    }

    static func committedVisibleLimit(current: Int, target: Int, loadedCount: Int) -> Int {
        // 请求失败或远端短页时只提交真实可见数量，避免每次重试都把窗口额度空涨 20。
        max(max(1, current), min(max(1, target), max(0, loadedCount)))
    }
}
