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
    private var canonicalSessionIDsBeforeFirstPage: Set<SessionID> = []

    mutating func replace(
        with page: SessionsPage,
        canonicalSessionIDsBeforeLoad: Set<SessionID>
    ) {
        sessions = Self.mergedSessions([], page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
        canonicalSessionIDsBeforeFirstPage = canonicalSessionIDsBeforeLoad
    }

    mutating func append(_ page: SessionsPage) {
        sessions = Self.mergedSessions(sessions, page.sessions)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
        hasLoadedFirstPage = true
    }

    func reconciledSessions(with canonicalSessions: [AgentSession]) -> [AgentSession] {
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonicalSessions.map { ($0.id, $0) })
        let cachedSessionIDs = Set(sessions.map(\.id))
        let refreshedPageMembers = sessions.map { canonicalByID[$0.id] ?? $0 }
        let newlyObserved = canonicalSessions.filter { session in
            !canonicalSessionIDsBeforeFirstPage.contains(session.id)
                && !cachedSessionIDs.contains(session.id)
        }
        // cursor 与既有分页成员仍由 page state 持有；渲染时只用 canonical Store 刷新字段，
        // 并补入首屏请求之后新观察到的会话，避免 WebSocket 更新被页面副本遮住。
        return Self.mergedSessions(refreshedPageMembers, newlyObserved)
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
    static func needsFirstPagePrefetch(
        cachedPageState: WorkspaceRuntimeSessionPageState?
    ) -> Bool {
        // 调用方先用完整 presentation key 取页；nil 代表这个 Runtime 从未完成首屏。
        cachedPageState?.hasLoadedFirstPage != true
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
