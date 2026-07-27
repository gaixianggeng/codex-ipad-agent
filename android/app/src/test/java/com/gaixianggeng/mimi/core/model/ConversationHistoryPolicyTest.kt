package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationHistoryPolicyTest {
    @Test
    fun repeatedBlankOrMissingCursorStopsPagination() {
        assertNull(ConversationHistoryPolicy.nextCursor("cursor-1", "cursor-1"))
        assertNull(ConversationHistoryPolicy.nextCursor("cursor-1", " cursor-1 "))
        assertNull(ConversationHistoryPolicy.nextCursor("cursor-1", "   "))
        assertNull(ConversationHistoryPolicy.nextCursor("cursor-1", null))
    }

    @Test
    fun aNewCursorIsNormalizedAndRetained() {
        assertEquals("cursor-2", ConversationHistoryPolicy.nextCursor("cursor-1", " cursor-2 "))
    }
}
