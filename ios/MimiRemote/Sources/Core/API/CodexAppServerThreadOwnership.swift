import Foundation

extension CodexAppServerSessionRuntime {
    func gatewayAnnotatedProject(
        from thread: [String: CodexAppServerJSONValue],
        projects: [AgentProject]
    ) -> AgentProject? {
        guard let annotation = thread["mimiRemote"]?.objectValue,
              annotation["discovery"]?.stringValue == "global",
              let projectID = nonEmpty(annotation["projectId"]?.stringValue),
              let projectPath = nonEmpty(annotation["projectPath"]?.stringValue)
        else {
            return nil
        }
        // agentd 已做 repo identity 裁剪；iOS 再与当前 config.projects 交叉验证，
        // 避免陈旧连接或协议混用把会话投影到不存在的项目。
        return projects.first {
            $0.id == projectID && $0.path == projectPath
        }
    }

    /// ownership 只来自结构父子字段或明确的 subAgent source。
    /// `forkedFromId` 是普通 fork 的来源信息，不能参与顶层可见性或历史隔离判断。
    func threadOwnership(
        from thread: [String: CodexAppServerJSONValue],
        cached: AgentSession?
    ) -> (createdAt: Date?, parentThreadID: String?, isSubagent: Bool?) {
        let createdAt = cached?.createdAt
            ?? firstDate(in: thread, keys: ["createdAt", "created_at"])
        let parentThreadID = nonEmpty(
            cached?.parentThreadID,
            thread["parentThreadId"]?.stringValue,
            thread["parent_thread_id"]?.stringValue
        )
        let hasSubagentIdentity = parentThreadID != nil
            || cached?.isSubagent == true
            || hasSubagentSource(in: thread)
        return (
            createdAt: createdAt,
            parentThreadID: parentThreadID,
            isSubagent: hasSubagentIdentity ? true : cached?.isSubagent
        )
    }

    func hasSubagentSource(in thread: [String: CodexAppServerJSONValue]) -> Bool {
        let threadSource = nonEmpty(
            thread["threadSource"]?.stringValue,
            thread["thread_source"]?.stringValue
        )?.lowercased()
        if threadSource?.hasPrefix("subagent") == true {
            return true
        }
        if nonEmpty(thread["source"]?.stringValue)?.lowercased().hasPrefix("subagent") == true {
            return true
        }
        guard let source = thread["source"]?.objectValue else {
            return false
        }
        return source.contains { key, value in
            guard key.lowercased() == "subagent" else { return false }
            return value.objectValue != nil
                || nonEmpty(value.stringValue) != nil
                || value.boolValue == true
        }
    }
}
