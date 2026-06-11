import Foundation

@MainActor
final class SessionContextStore: ObservableObject {
    @Published private var contextsBySessionID: [SessionID: SessionContextSnapshot] = [:]

    private let maxTasks = 8

    func context(for sessionID: SessionID?) -> SessionContextSnapshot? {
        guard let sessionID else {
            return nil
        }
        return contextsBySessionID[sessionID]
    }

    func upsert(_ context: SessionContextSnapshot, fallbackSessionID: SessionID?) {
        let sessionID = context.sessionID ?? fallbackSessionID
        guard let sessionID, !sessionID.isEmpty else {
            return
        }
        var next = context
        next.sessionID = sessionID
        let merged = Self.merged(base: contextsBySessionID[sessionID], update: next, maxTasks: maxTasks)
        guard contextsBySessionID[sessionID] != merged else {
            return
        }
        contextsBySessionID[sessionID] = merged
        attachSubagentsToParents(from: merged)
    }

    func upsert(from session: AgentSession) {
        if let context = session.context {
            upsert(context, fallbackSessionID: session.id)
            return
        }
        let context = SessionContextSnapshot(
            sessionID: session.id,
            threadID: session.resumeID,
            status: SessionContextStatus(type: Self.statusType(from: session.status)),
            environment: SessionContextEnvironment(id: "local", kind: "local", label: "本地", cwd: session.dir, provider: session.source),
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

    func clearPendingApprovalTasks(sessionID: SessionID) {
        guard var context = contextsBySessionID[sessionID] else {
            return
        }
        let filtered = context.tasks.filter { task in
            !(task.status == "waiting" && task.title.hasPrefix("Codex 请求"))
        }
        guard filtered != context.tasks else {
            return
        }
        context.tasks = filtered
        context.updatedAt = Date()
        contextsBySessionID[sessionID] = context
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
                let parentUpdate = SessionContextSnapshot(
                    sessionID: parentSessionID,
                    threadID: parentThreadID,
                    subagents: [subagent],
                    updatedAt: Date()
                )
                let merged = Self.merged(base: contextsBySessionID[parentSessionID], update: parentUpdate, maxTasks: maxTasks)
                if contextsBySessionID[parentSessionID] != merged {
                    contextsBySessionID[parentSessionID] = merged
                }
            }
        }
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
