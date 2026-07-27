package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionLibraryPolicyTest {
    @Test
    fun approvalAndInputTakePriorityOverRunningSignals() {
        assertEquals(
            SessionRowStatus.WaitingForApproval,
            SessionLibraryPolicy.status(
                context = SessionContextStatus("active", listOf("waitingOnApproval"), "running"),
                hasActiveTurn = true,
            ),
        )
        assertEquals(
            SessionRowStatus.WaitingForInput,
            SessionLibraryPolicy.status(
                context = SessionContextStatus("active", rawType = "running"),
                hasActiveTurn = true,
                hasPendingUserInput = true,
            ),
        )
    }

    @Test
    fun rawStatusKeepsFailedCompletedAndHistoryDistinct() {
        assertEquals(
            SessionRowStatus.Failed,
            SessionLibraryPolicy.status(SessionContextStatus("systemError", rawType = "failed")),
        )
        assertEquals(
            SessionRowStatus.Complete,
            SessionLibraryPolicy.status(SessionContextStatus("idle", rawType = "completed")),
        )
        assertEquals(
            SessionRowStatus.History,
            SessionLibraryPolicy.status(SessionContextStatus("notLoaded", rawType = "history")),
        )
    }

    @Test
    fun filtersMatchIosActiveAttentionAndHistorySemantics() {
        assertTrue(SessionLibraryPolicy.includes(SessionLibraryFilter.Active, SessionRowStatus.Running))
        assertTrue(SessionLibraryPolicy.includes(SessionLibraryFilter.Active, SessionRowStatus.WaitingForApproval))
        assertTrue(SessionLibraryPolicy.includes(SessionLibraryFilter.NeedsAttention, SessionRowStatus.Failed))
        assertTrue(SessionLibraryPolicy.includes(SessionLibraryFilter.History, SessionRowStatus.Failed))
        assertFalse(SessionLibraryPolicy.includes(SessionLibraryFilter.History, SessionRowStatus.WaitingForInput))
        assertFalse(SessionLibraryPolicy.includes(SessionLibraryFilter.NeedsAttention, SessionRowStatus.Complete))
    }
}
