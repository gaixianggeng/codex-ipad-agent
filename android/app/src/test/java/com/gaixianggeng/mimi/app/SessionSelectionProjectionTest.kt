package com.gaixianggeng.mimi.app

import com.gaixianggeng.mimi.core.model.ComposerSendMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionSelectionProjectionTest {
    @Test
    fun selectingForkClearsSourceTurnAndComposerState() {
        val result = MainUiState(
            selectedThreadId = "source",
            activeTurnId = "source-turn",
            awaitingTurnIdentity = true,
            guideActiveTurn = true,
            historyCursor = "source-cursor",
            composerText = "source draft",
            selectedSkillPaths = setOf("/skills/review/SKILL.md"),
            loading = false,
            error = "old error",
        ).transitionToThreadShell(
            threadId = "fork",
            loading = true,
        )

        assertEquals("fork", result.selectedThreadId)
        assertNull(result.activeTurnId)
        assertFalse(result.awaitingTurnIdentity)
        assertFalse(result.guideActiveTurn)
        assertNull(result.historyCursor)
        assertTrue(result.messages.isEmpty())
        assertTrue(result.queuedTurns.isEmpty())
        assertEquals("", result.composerText)
        assertTrue(result.composerImages.isEmpty())
        assertTrue(result.selectedSkillPaths.isEmpty())
        assertEquals(ComposerSendMode.Standard, result.composerSendMode)
        assertTrue(result.loading)
        assertNull(result.error)
    }

    @Test
    fun returningToSessionListClearsAllSelectedThreadTransientState() {
        val result = MainUiState(
            selectedThreadId = "thread-1",
            activeTurnId = "turn-1",
            awaitingTurnIdentity = true,
            guideActiveTurn = true,
            historyCursor = "older",
            composerText = "draft",
            selectedSkillPaths = setOf("/skills/review/SKILL.md"),
            voiceRecording = true,
            voiceTranscribing = true,
            filePreviewLocalPath = "/repo/README.md",
            filePreviewLoading = true,
            respondingToRequest = true,
        ).transitionToSessionList()

        assertNull(result.selectedThreadId)
        assertNull(result.activeTurnId)
        assertNull(result.historyCursor)
        assertFalse(result.awaitingTurnIdentity)
        assertFalse(result.guideActiveTurn)
        assertTrue(result.messages.isEmpty())
        assertTrue(result.queuedTurns.isEmpty())
        assertEquals("", result.composerText)
        assertTrue(result.selectedSkillPaths.isEmpty())
        assertFalse(result.voiceRecording)
        assertFalse(result.voiceTranscribing)
        assertNull(result.filePreviewLocalPath)
        assertFalse(result.filePreviewLoading)
        assertFalse(result.respondingToRequest)
    }
}
