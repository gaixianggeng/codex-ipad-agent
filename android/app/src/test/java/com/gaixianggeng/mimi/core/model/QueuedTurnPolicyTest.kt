package com.gaixianggeng.mimi.core.model

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class QueuedTurnPolicyTest {
    @Test
    fun `only interrupted dispatches for active profile require confirmation`() {
        val active = turn("active", "profile-a", QueuedTurnState.Dispatching)
        val other = turn("other", "profile-b", QueuedTurnState.Dispatching)
        val waiting = turn("waiting", "profile-a", QueuedTurnState.Waiting)
        val recovered = QueuedTurnPolicy.recoverInterruptedDispatches(listOf(active, other, waiting), "profile-a")
        assertEquals(QueuedTurnState.NeedsConfirmation, recovered[0].state)
        assertEquals("Sending was interrupted before the server confirmed it", recovered[0].lastError)
        assertEquals(QueuedTurnState.Dispatching, recovered[1].state)
        assertEquals(QueuedTurnState.Waiting, recovered[2].state)
    }

    @Test
    fun `queue limit is isolated by profile and thread`() {
        val full = (1..QueuedTurnPolicy.MAX_PER_THREAD).map { turn("$it", "profile-a") }
        assertThrows(IllegalStateException::class.java) {
            QueuedTurnPolicy.enqueue(full, turn("overflow", "profile-a"))
        }
        assertEquals(QueuedTurnPolicy.MAX_PER_THREAD + 1, QueuedTurnPolicy.enqueue(full, turn("other", "profile-b")).size)
    }

    @Test
    fun `reorder only changes the selected profile and thread`() {
        val first = turn("first", "profile-a")
        val second = turn("second", "profile-a")
        val other = turn("other", "profile-b")

        val reordered = QueuedTurnPolicy.reorder(
            listOf(first, other, second),
            "profile-a",
            "thread-1",
            listOf("second", "first"),
        )

        assertEquals(listOf("second", "other", "first"), reordered.map(QueuedTurn::id))
    }

    @Test
    fun `reorder rejects stale ids and dispatching queues`() {
        val first = turn("first", "profile-a")
        assertThrows(IllegalStateException::class.java) {
            QueuedTurnPolicy.reorder(listOf(first), "profile-a", "thread-1", listOf("missing"))
        }
        assertThrows(IllegalStateException::class.java) {
            QueuedTurnPolicy.reorder(
                listOf(first.copy(state = QueuedTurnState.Dispatching)),
                "profile-a",
                "thread-1",
                listOf("first"),
            )
        }
    }

    @Test
    fun `confirmation at queue head blocks later waiting messages`() {
        val blocked = turn("blocked", "profile-a", QueuedTurnState.NeedsConfirmation)
        val waiting = turn("later", "profile-a")

        assertEquals(null, QueuedTurnPolicy.nextDispatch(listOf(blocked, waiting)))
        assertEquals(waiting, QueuedTurnPolicy.nextDispatch(listOf(waiting, blocked)))
    }

    @Test
    fun `dispatched queue item keeps its user message and image identity`() {
        val queued = turn("client-message", "profile-a").copy(
            text = "",
            images = listOf(ImageAttachment("image-1", "data:image/jpeg;base64,AA==", 10, 20, 2)),
        )

        val message = queued.conversationMessage()

        assertEquals("client-message", message.id)
        assertEquals(ConversationRole.User, message.role)
        assertEquals("[1 image attachment(s)]", message.text)
        assertEquals("data:image/jpeg;base64,AA==", message.attachments.single().url)
    }

    @Test
    fun `queued plan freezes collaboration mode and cannot be treated as guided follow up`() {
        val queued = turn("plan", "profile-a").copy(
            collaborationMode = ComposerSendMode.Plan.wireName,
        )

        val restoredMode = ComposerSendMode.fromWire(queued.collaborationMode)

        assertEquals(ComposerSendMode.Plan, restoredMode)
        assertEquals(false, restoredMode.allowsGuidedFollowUp)
    }

    @Test
    fun `queued goal freezes objective while using default collaboration mode`() {
        val queued = turn("goal", "profile-a").copy(
            collaborationMode = ComposerSendMode.Goal.wireName,
            goalObjective = "Ship the Android app",
        )

        assertEquals("default", queued.collaborationMode)
        assertEquals("Ship the Android app", queued.goalObjective)
        assertEquals(ComposerSendMode.Standard, ComposerSendMode.fromWire(queued.collaborationMode))
    }

    private fun turn(id: String = UUID.randomUUID().toString(), profile: String, state: QueuedTurnState = QueuedTurnState.Waiting) = QueuedTurn(
        id = id,
        profileId = profile,
        threadId = "thread-1",
        cwd = "/repo",
        text = "message-$id",
        createdAtEpochMillis = 1,
        state = state,
    )
}
