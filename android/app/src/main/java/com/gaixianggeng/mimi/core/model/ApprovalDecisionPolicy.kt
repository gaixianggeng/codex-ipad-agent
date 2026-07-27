package com.gaixianggeng.mimi.core.model

object ApprovalDecisionPolicy {
    fun hasDecisionContext(request: ApprovalRequest): Boolean {
        if (!request.body.isNullOrBlank()) return true
        if (request.kind != "command") return false
        val title = request.title.trim()
        if (
            title.equals("Agent requests to run a command", true) ||
            title.equals("Run command", true) ||
            title == "运行命令" ||
            title == "Agent 请求运行命令"
        ) {
            return false
        }
        return title.any(Char::isWhitespace) ||
            '/' in title ||
            '：' in title ||
            ':' in title
    }

    fun canPersistPermission(request: ApprovalRequest): Boolean =
        request.availableDecisions.any { it.equals("acceptWithPermissionUpdate", true) } &&
            request.persistentPermissionRules.isNotEmpty()

    fun canSubmitDecision(request: ApprovalRequest, decision: String): Boolean = when {
        decision.equals("decline", true) || decision.equals("cancel", true) -> true
        decision.equals("acceptWithPermissionUpdate", true) ->
            hasDecisionContext(request) && canPersistPermission(request)
        decision.equals("acceptForSession", true) ->
            hasDecisionContext(request) &&
                request.availableDecisions.any { it.equals("acceptForSession", true) }
        decision.equals("accept", true) -> hasDecisionContext(request)
        else -> false
    }
}
