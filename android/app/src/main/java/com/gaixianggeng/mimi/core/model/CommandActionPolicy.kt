package com.gaixianggeng.mimi.core.model

object CommandActionPolicy {
    const val MAX_ACTIONS = 200
    const val MAX_OUTPUT_CHARS = 100_000

    fun sanitizeAllowlist(actions: List<AgentCommandAction>): List<AgentCommandAction> =
        actions
            .asSequence()
            .filter { it.id == it.id.trim() && it.id.length in 1..256 }
            .distinctBy(AgentCommandAction::id)
            .take(MAX_ACTIONS)
            .toList()

    fun boundResult(result: CommandActionRunResponse): CommandActionRunResponse {
        val output = result.output
        val clipped = output?.length?.let { it > MAX_OUTPUT_CHARS } == true
        return result.copy(
            output = output?.take(MAX_OUTPUT_CHARS),
            truncated = result.truncated == true || clipped,
        )
    }
}
