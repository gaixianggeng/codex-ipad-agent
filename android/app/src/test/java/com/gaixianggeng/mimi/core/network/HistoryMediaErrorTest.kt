package com.gaixianggeng.mimi.core.network

import org.junit.Assert.assertEquals
import org.junit.Test

class HistoryMediaErrorTest {
    @Test
    fun classifiesExpiredAndUnsupportedAgentResponses() {
        assertEquals(
            HistoryMediaErrorKind.Expired,
            historyMediaErrorKind(AgentApiException("gone", 404)),
        )
        assertEquals(
            HistoryMediaErrorKind.Unsupported,
            historyMediaErrorKind(AgentApiException("method not allowed", 405)),
        )
    }

    @Test
    fun leavesOtherFailuresUntouched() {
        assertEquals(
            HistoryMediaErrorKind.Other,
            historyMediaErrorKind(AgentApiException("server error", 500)),
        )
        assertEquals(
            HistoryMediaErrorKind.Other,
            historyMediaErrorKind(IllegalStateException("offline")),
        )
    }
}
