package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationTimelineStateReducerTest {
    @Test
    fun `output deltas update the original slot and remain bounded`() {
        val started = commandMessage(status = "inProgress")
        val messages = listOf(
            ConversationMessage("before", ConversationRole.User, "Run tests"),
            started,
            ConversationMessage("after", ConversationRole.Assistant, "Still working"),
        )

        val updated = ConversationTimelineStateReducer.appendCommandOutput(
            messages,
            itemId = started.id,
            turnId = started.turnId,
            delta = "123456789",
            previewLimit = 5,
        )

        assertEquals(listOf("before", "command", "after"), updated.map { it.id })
        assertEquals("56789", updated[1].activity?.outputPreview)
        assertTrue(updated[1].activity?.outputTruncated == true)
    }

    @Test
    fun `output delta preserves first visible slot identity`() {
        val started = commandMessage(status = "inProgress").copy(
            id = "first-visible-slot",
            itemId = "protocol-item",
        )

        val updated = ConversationTimelineStateReducer.appendCommandOutput(
            messages = listOf(started),
            itemId = "protocol-item",
            turnId = started.turnId,
            delta = "BUILD SUCCESSFUL",
        )

        assertEquals("first-visible-slot", updated.single().id)
        assertEquals("protocol-item", updated.single().itemId)
        assertEquals("BUILD SUCCESSFUL", updated.single().activity?.outputPreview)
    }

    @Test
    fun `completed item rejects delayed output and running regression`() {
        val completed = commandMessage(status = "completed").copy(itemCompleted = true, streaming = false)
        val messages = listOf(completed)

        val afterOutput = ConversationTimelineStateReducer.appendCommandOutput(
            messages,
            itemId = completed.id,
            turnId = completed.turnId,
            delta = "late output",
        )
        val afterStarted = ConversationTimelineStateReducer.upsert(
            messages,
            commandMessage(status = "inProgress"),
        )

        assertSame(messages, afterOutput)
        assertSame(messages, afterStarted)
        assertTrue(afterOutput.single().itemCompleted)
        assertFalse(afterOutput.single().streaming)
        assertEquals("completed", afterOutput.single().activity?.status)
    }

    @Test
    fun `completed projection keeps streamed output when final payload omits it`() {
        val running = commandMessage(status = "inProgress").copy(
            activity = commandMessage(status = "inProgress").activity?.copy(outputPreview = "test output"),
        )
        val completed = commandMessage(status = "completed").copy(itemCompleted = true, streaming = false)

        val merged = ConversationTimelineStateReducer.upsert(listOf(running), completed).single()

        assertEquals("test output", merged.activity?.outputPreview)
        assertTrue(merged.itemCompleted)
        assertFalse(merged.streaming)
    }

    @Test
    fun `history snapshot cannot discard events received while loading`() {
        val liveCommand = commandMessage(status = "completed").copy(
            id = "live-slot",
            itemId = "command",
            itemCompleted = true,
            streaming = false,
            activity = commandMessage(status = "completed").activity?.copy(
                outputPreview = "BUILD SUCCESSFUL",
            ),
        )
        val staleSnapshotCommand = commandMessage(status = "inProgress")
        val liveOnlyAssistant = ConversationMessage(
            id = "assistant-live",
            role = ConversationRole.Assistant,
            text = "Done",
            turnId = "turn-1",
            itemId = "assistant-live",
            itemCompleted = true,
        )

        val merged = ConversationTimelineStateReducer.mergeSnapshot(
            current = listOf(liveCommand, liveOnlyAssistant),
            snapshot = listOf(
                ConversationMessage(
                    id = "user-history",
                    role = ConversationRole.User,
                    text = "Run tests",
                    turnId = "turn-1",
                    itemId = "user-history",
                    itemCompleted = true,
                ),
                staleSnapshotCommand,
            ),
        )

        assertEquals(listOf("user-history", "live-slot", "assistant-live"), merged.map { it.id })
        assertTrue(merged[1].itemCompleted)
        assertEquals("BUILD SUCCESSFUL", merged[1].activity?.outputPreview)
        assertEquals("completed", merged[1].activity?.status)
    }

    @Test
    fun `older page prepends unique items without replacing current slot identity`() {
        val current = listOf(
            ConversationMessage(
                id = "stable-current",
                role = ConversationRole.Assistant,
                text = "Current text",
                turnId = "turn-2",
                itemId = "shared-item",
                itemCompleted = true,
            ),
            ConversationMessage("newest", ConversationRole.Assistant, "Newest"),
        )
        val older = listOf(
            ConversationMessage("oldest", ConversationRole.User, "Oldest"),
            ConversationMessage(
                id = "snapshot-id",
                role = ConversationRole.Assistant,
                text = "Snapshot text",
                turnId = "turn-2",
                itemId = "shared-item",
                itemCompleted = true,
            ),
        )

        val merged = ConversationTimelineStateReducer.prependSnapshot(current, older)

        assertEquals(listOf("oldest", "stable-current", "newest"), merged.map { it.id })
        assertEquals("Snapshot text", merged[1].text)
    }

    @Test
    fun `assistant completion is terminal and ignores delayed deltas`() {
        val streamed = ConversationTimelineStateReducer.appendAssistantText(
            messages = emptyList(),
            itemId = "assistant",
            turnId = "turn-1",
            delta = "Hel",
        )
        val completed = ConversationTimelineStateReducer.completeAssistantMessage(
            messages = streamed,
            itemId = "assistant",
            turnId = "turn-1",
            text = "Hello",
        )
        val afterLateDelta = ConversationTimelineStateReducer.appendAssistantText(
            messages = completed,
            itemId = "assistant",
            turnId = "turn-1",
            delta = " late",
        )

        assertEquals("Hello", afterLateDelta.single().text)
        assertTrue(afterLateDelta.single().itemCompleted)
        assertFalse(afterLateDelta.single().streaming)
    }

    @Test
    fun `authoritative assistant completion reconciles a delta without item id`() {
        val streamed = ConversationTimelineStateReducer.appendAssistantText(
            messages = emptyList(),
            itemId = "assistant-turn-1",
            turnId = "turn-1",
            delta = "GOAL MODE OK",
        )

        val completed = ConversationTimelineStateReducer.completeAssistantMessage(
            messages = streamed,
            itemId = "authoritative-assistant-id",
            turnId = "turn-1",
            text = "GOAL MODE OK",
        )

        assertEquals(1, completed.size)
        assertEquals("GOAL MODE OK", completed.single().text)
        assertEquals("authoritative-assistant-id", completed.single().itemId)
        assertTrue(completed.single().itemCompleted)
    }

    @Test
    fun `identical commentary is removed when the final answer arrives`() {
        val commentary = ConversationMessage(
            id = "commentary",
            role = ConversationRole.Commentary,
            text = "GOAL MODE OK",
            turnId = "turn-1",
            itemId = "commentary",
            itemCompleted = true,
        )
        val final = ConversationMessage(
            id = "final",
            role = ConversationRole.Assistant,
            text = "GOAL MODE OK",
            turnId = "turn-1",
            itemId = "final",
            itemCompleted = true,
        )

        val collapsed = ConversationTimelineStateReducer.collapseRedundantCommentary(
            listOf(commentary, final),
        )

        assertEquals(listOf("final"), collapsed.map(ConversationMessage::id))
    }

    @Test
    fun `turn completion without id only closes active items`() {
        val historical = commandMessage(status = "completed").copy(
            id = "historical",
            turnId = "old-turn",
            itemCompleted = true,
            turnLifecycle = ConversationTurnLifecycle.Completed,
        )
        val active = commandMessage(status = "inProgress")

        val completed = ConversationTimelineStateReducer.completeTurn(
            messages = listOf(historical, active),
            turnId = null,
            lifecycle = ConversationTurnLifecycle.Interrupted,
        )

        assertEquals(ConversationTurnLifecycle.Completed, completed[0].turnLifecycle)
        assertEquals("completed", completed[0].activity?.status)
        assertEquals(ConversationTurnLifecycle.Interrupted, completed[1].turnLifecycle)
        assertEquals("cancelled", completed[1].activity?.status)
        assertTrue(completed[1].itemCompleted)
    }

    @Test
    fun `structured activity updates preserve their first visible slot`() {
        val initial = listOf(
            ConversationMessage("before", ConversationRole.User, "Start"),
            ConversationMessage("after", ConversationRole.Assistant, "Waiting"),
        )
        val first = ConversationTimelineStateReducer.appendActivityText(
            messages = initial,
            itemId = "reasoning",
            turnId = "turn-1",
            category = ConversationActivityCategory.Thinking,
            delta = "Inspect ",
        )
        val second = ConversationTimelineStateReducer.appendActivityText(
            messages = first,
            itemId = "reasoning",
            turnId = "turn-1",
            category = ConversationActivityCategory.Thinking,
            delta = "files",
        )

        assertEquals(listOf("before", "after", "reasoning"), second.map { it.id })
        assertEquals("Inspect files", second.last().activity?.subtitle)
    }

    private fun commandMessage(status: String): ConversationMessage = ConversationMessage(
        id = "command",
        role = ConversationRole.Activity,
        text = "Run tests",
        streaming = status == "inProgress",
        turnId = "turn-1",
        itemId = "command",
        activity = ConversationActivity(
            category = ConversationActivityCategory.RunCommand,
            title = "Run tests",
            status = status,
            command = "./gradlew test",
        ),
        turnLifecycle = ConversationTurnLifecycle.Running,
    )
}
