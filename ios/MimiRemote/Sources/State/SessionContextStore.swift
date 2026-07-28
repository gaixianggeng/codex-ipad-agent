import Foundation

@MainActor
final class SessionContextStore: ObservableObject {
    @Published private var activeProfileID = ""
    @Published private var contextsBySessionID: [ScopedSessionID: SessionContextSnapshot] = [:]

    private let maxTasks = 8

    func activate(profileID: String) {
        guard activeProfileID != profileID else {
            return
        }
        activeProfileID = profileID
    }

    func remove(profileID: String) {
        let filteredContexts = contextsBySessionID.filter { $0.key.profileID != profileID }
        if filteredContexts.count != contextsBySessionID.count {
            contextsBySessionID = filteredContexts
        }
    }

    func context(for sessionID: SessionID?) -> SessionContextSnapshot? {
        guard let sessionID else {
            return nil
        }
        return contextsBySessionID[scopedSessionID(for: sessionID)]
    }

    func upsert(_ context: SessionContextSnapshot, fallbackSessionID: SessionID?) {
        let sessionID = context.sessionID ?? fallbackSessionID
        guard let sessionID, !sessionID.isEmpty else {
            return
        }
        var next = context
        next.sessionID = sessionID
        let scopedSessionID = scopedSessionID(for: sessionID)
        let merged = Self.merged(base: contextsBySessionID[scopedSessionID], update: next, maxTasks: maxTasks)
        guard contextsBySessionID[scopedSessionID] != merged else {
            return
        }
        contextsBySessionID[scopedSessionID] = merged
        attachSubagentsToParents(from: merged)
    }

    func upsert(from session: AgentSession) {
        if var context = session.context {
            if context.goal == nil {
                context.goal = session.goal
            }
            upsert(context, fallbackSessionID: session.id)
            return
        }
        let context = SessionContextSnapshot(
            sessionID: session.id,
            threadID: session.resumeID,
            status: SessionContextStatus(type: Self.statusType(from: session.status)),
            environment: SessionContextEnvironment(
                id: "local",
                kind: "local",
                label: L10n.text("ui.local"),
                cwd: session.dir,
                provider: session.runtimeProvider ?? session.source,
                runtimeProvider: session.runtimeProvider
            ),
            goal: session.goal,
            tasks: [],
            sources: [SessionContextSource(id: "session_source", kind: "session", label: session.source, subtitle: nil)],
            updatedAt: session.updatedAt
        )
        upsert(context, fallbackSessionID: session.id)
    }

    func updateStatus(sessionID: SessionID, status: String) {
        upsert(
            SessionContextSnapshot(
                sessionID: sessionID,
                status: SessionContextStatus(type: Self.statusType(from: status)),
                updatedAt: Date()
            ),
            fallbackSessionID: sessionID
        )
    }

    func clearGoal(sessionID: SessionID) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard var context = contextsBySessionID[scopedSessionID] else {
            return
        }
        guard context.goal != nil else {
            return
        }
        context.goal = nil
        context.updatedAt = Date()
        contextsBySessionID[scopedSessionID] = context
    }

    func clearPendingApprovalTasks(sessionID: SessionID) {
        let scopedSessionID = scopedSessionID(for: sessionID)
        guard var context = contextsBySessionID[scopedSessionID] else {
            return
        }
        let filtered = context.tasks.filter { task in
            guard task.status == "waiting" else {
                return true
            }
            let kind = task.kind.lowercased()
            return !(kind.contains("approval") || kind == "command" || kind == "file_change")
        }
        guard filtered != context.tasks else {
            return
        }
        context.tasks = filtered
        context.updatedAt = Date()
        contextsBySessionID[scopedSessionID] = context
    }

    private func attachSubagentsToParents(from context: SessionContextSnapshot) {
        for subagent in context.subagents {
            guard let parentThreadID = subagent.parentThreadID, !parentThreadID.isEmpty else {
                continue
            }
            var candidateIDs = [parentThreadID]
            if !parentThreadID.hasPrefix("codex_") {
                candidateIDs.append("codex_\(parentThreadID)")
            }
            for parentSessionID in Set(candidateIDs) {
                let scopedParentSessionID = scopedSessionID(for: parentSessionID)
                let parentUpdate = SessionContextSnapshot(
                    sessionID: parentSessionID,
                    threadID: parentThreadID,
                    subagents: [subagent],
                    updatedAt: Date()
                )
                let merged = Self.merged(base: contextsBySessionID[scopedParentSessionID], update: parentUpdate, maxTasks: maxTasks)
                if contextsBySessionID[scopedParentSessionID] != merged {
                    contextsBySessionID[scopedParentSessionID] = merged
                }
            }
        }
    }

    private func scopedSessionID(for sessionID: SessionID) -> ScopedSessionID {
        ScopedSessionID(profileID: activeProfileID, sessionID: sessionID)
    }

    private static func merged(
        base: SessionContextSnapshot?,
        update: SessionContextSnapshot,
        maxTasks: Int
    ) -> SessionContextSnapshot {
        guard var base else {
            var next = update
            next.tasks = Array(update.tasks.prefix(maxTasks))
            return next
        }
        base.sessionID = update.sessionID ?? base.sessionID
        base.threadID = update.threadID ?? base.threadID
        base.status = update.status ?? base.status
        base.environment = mergeEnvironment(base.environment, update.environment)
        base.git = update.git ?? base.git
        base.goal = update.goal ?? base.goal
        base.tasks = mergeTasks(base.tasks, update.tasks, limit: maxTasks)
        base.sources = mergeSources(base.sources, update.sources)
        base.subagents = mergeSubagents(base.subagents, update.subagents)
        base.updatedAt = update.updatedAt ?? base.updatedAt ?? Date()
        return base
    }

    private static func mergeEnvironment(
        _ base: SessionContextEnvironment?,
        _ update: SessionContextEnvironment?
    ) -> SessionContextEnvironment? {
        guard var update else {
            return base
        }
        if let base {
            update.id = nonEmpty(update.id, base.id)
            update.kind = nonEmpty(update.kind, base.kind)
            update.label = nonEmpty(update.label, base.label)
            update.cwd = nonEmpty(update.cwd, base.cwd)
            update.provider = nonEmpty(update.provider, base.provider)
        }
        return update
    }

    private static func mergeTasks(
        _ base: [SessionContextTask],
        _ update: [SessionContextTask],
        limit: Int
    ) -> [SessionContextTask] {
        guard !update.isEmpty else {
            return base
        }
        var seen = Set<String>()
        var out: [SessionContextTask] = []
        for task in update + base {
            let key = task.id.isEmpty ? "\(task.kind):\(task.title)" : task.id
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            out.append(task)
            if out.count >= limit {
                break
            }
        }
        return out
    }

    private static func mergeSources(
        _ base: [SessionContextSource],
        _ update: [SessionContextSource]
    ) -> [SessionContextSource] {
        mergeUnique(update + base) { source in
            source.id.isEmpty ? "\(source.kind):\(source.label)" : source.id
        }
    }

    private static func mergeSubagents(
        _ base: [SessionContextSubagent],
        _ update: [SessionContextSubagent]
    ) -> [SessionContextSubagent] {
        mergeUnique(update + base) { subagent in
            subagent.id.isEmpty ? subagent.displayName : subagent.id
        }
    }

    private static func mergeUnique<T>(_ values: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        var out: [T] = []
        for value in values {
            let key = key(value)
            guard !key.isEmpty, !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            out.append(value)
        }
        return out
    }

    private static func statusType(from status: String) -> String {
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

    private static func nonEmpty(_ preferred: String?, _ fallback: String?) -> String? {
        guard let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return preferred
    }
}
