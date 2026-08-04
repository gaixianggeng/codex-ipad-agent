import Foundation

struct WorkspaceSessionPresentationKey: Hashable {
    let hostScope: HostScope
    let workspaceID: String
    let workspacePath: String
    let runtimeProvider: String
}

struct WorkspaceRuntimeSessionPageState: Equatable {
    var sessions: [AgentSession] = []
    var nextCursor: String?
    var hasMore = false
    var hasLoadedFirstPage = false

    mutating func replace(with page: SessionsPage) {
        sessions = Self.mergedSessions([], page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
    }

    mutating func append(_ page: SessionsPage) {
        sessions = Self.mergedSessions(sessions, page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
    }

    private static func mergedSessions(
        _ existing: [AgentSession],
        _ incoming: [AgentSession]
    ) -> [AgentSession] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // 分页边界允许重复 ID；新页字段更新优先，最终只在当前 Runtime 内按时间排序。
        incoming.forEach { byID[$0.id] = $0 }
        return SessionIndexStore.sortedSessions(Array(byID.values))
    }
}

enum WorkspaceSessionPresentation {
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
