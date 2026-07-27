package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.core.model.SessionContextSnapshot
import com.gaixianggeng.mimi.core.model.SessionContextStatus
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TurnLifecycleProjectionTest {
    @Test
    fun startResultUsesConfirmedTurnIdentity() {
        val nested = Json.parseToJsonElement("""{"turn":{"id":"turn-nested"}}""")
        val flat = Json.parseToJsonElement("""{"turnId":"turn-flat"}""")

        assertEquals("turn-nested", TurnLifecycleProjection.startResultTurnId(nested))
        assertEquals("turn-flat", TurnLifecycleProjection.startResultTurnId(flat))
        assertNull(TurnLifecycleProjection.startResultTurnId(Json.parseToJsonElement("""{"turn":{}}""")))
    }

    @Test
    fun liveEventBackfillsMissedTurnStartedButTerminalEventDoesNot() {
        val delta = AppServerEvent(
            method = "item/agentMessage/delta",
            params = buildJsonObject {
                put("threadId", "thread-1")
                put("turnId", "turn-9")
                put("delta", "hello")
            },
        )
        val completed = delta.copy(method = "turn/completed")

        assertEquals(
            ActiveTurnIdentity("thread-1", "turn-9"),
            TurnLifecycleProjection.activeTurnFromEvent(delta),
        )
        assertNull(TurnLifecycleProjection.activeTurnFromEvent(completed))
    }

    @Test
    fun runningSnapshotRecoversActiveTurnIdentity() {
        val messages = listOf(
            ConversationMessage(
                id = "old",
                role = ConversationRole.Assistant,
                text = "done",
                turnId = "turn-old",
                turnLifecycle = ConversationTurnLifecycle.Completed,
            ),
            ConversationMessage(
                id = "live",
                role = ConversationRole.Activity,
                text = "working",
                turnId = "turn-live",
                turnLifecycle = ConversationTurnLifecycle.Running,
            ),
        )

        assertEquals("turn-live", TurnLifecycleProjection.activeTurnFromMessages(messages))
    }

    @Test
    fun busyContextWithoutIdentityBlocksAnotherTurnStart() {
        val context = SessionContextSnapshot(
            threadId = "thread-1",
            status = SessionContextStatus(type = "waiting_for_approval"),
        )

        assertTrue(TurnLifecycleProjection.contextIsBusy(context))
        assertTrue(TurnLifecycleProjection.isBusy(null, awaitingTurnIdentity = true))
        assertTrue(TurnLifecycleProjection.isBusy("turn-1", awaitingTurnIdentity = false))
        assertFalse(TurnLifecycleProjection.isBusy(null, awaitingTurnIdentity = false))
    }
}
