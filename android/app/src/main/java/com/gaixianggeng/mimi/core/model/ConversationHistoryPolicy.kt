package com.gaixianggeng.mimi.core.model

object ConversationHistoryPolicy {
    fun nextCursor(requestCursor: String?, responseCursor: String?): String? =
        responseCursor
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.takeUnless { it == requestCursor?.trim() }
}
