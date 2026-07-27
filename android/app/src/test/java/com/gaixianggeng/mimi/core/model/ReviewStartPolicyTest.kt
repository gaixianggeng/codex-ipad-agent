package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewStartPolicyTest {
    @Test
    fun reviewIsRejectedForRunningOrWaitingThreads() {
        assertFalse(ReviewStartPolicy.canStart(SessionContextStatus("running"), hasActiveTurn = false))
        assertFalse(ReviewStartPolicy.canStart(SessionContextStatus("waiting_for_approval"), hasActiveTurn = false))
        assertFalse(ReviewStartPolicy.canStart(SessionContextStatus("idle"), hasActiveTurn = true))
        assertTrue(ReviewStartPolicy.canStart(SessionContextStatus("idle"), hasActiveTurn = false))
        assertTrue(ReviewStartPolicy.canStart(SessionContextStatus("completed"), hasActiveTurn = false))
    }
}
