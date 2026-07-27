package com.gaixianggeng.mimi.core.model

object CompletionReconciliationPolicy {
    fun needsAuthoritativeSnapshot(
        messages: List<ConversationMessage>,
        turnId: String?,
    ): Boolean {
        if (turnId != null) {
            val completedAssistant = messages.any {
                it.turnId == turnId &&
                    it.role == ConversationRole.Assistant &&
                    it.itemCompleted &&
                    it.text.isNotBlank()
            }
            if (completedAssistant) return false
        }
        val lastUserIndex = messages.indexOfLast { it.role == ConversationRole.User }
        if (lastUserIndex < 0) return false
        return messages
            .drop(lastUserIndex + 1)
            .none { it.role == ConversationRole.Assistant && it.text.isNotBlank() }
    }
}
