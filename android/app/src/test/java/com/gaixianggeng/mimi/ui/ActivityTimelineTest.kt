package com.gaixianggeng.mimi.ui

import com.gaixianggeng.mimi.core.model.ConversationActivity
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActivityTimelineTest {
    @Test
    fun `adjacent process items from the same turn form one stable group`() {
        val entries = conversationTimelineEntries(
            listOf(
                message("user", ConversationRole.User),
                activity("reason", "turn-1", ConversationActivityCategory.Thinking),
                activity("command", "turn-1", ConversationActivityCategory.RunCommand),
                activity("file", "turn-1", ConversationActivityCategory.EditFile),
                message("assistant", ConversationRole.Assistant),
            ),
        )

        assertEquals(3, entries.size)
        val group = entries[1] as ConversationTimelineEntry.ActivityGroup
        assertEquals(listOf("reason", "command", "file"), group.messages.map { it.id })
        assertEquals("activity:reason", group.key)
    }

    @Test
    fun `messages and turn boundaries prevent semantic reordering`() {
        val entries = conversationTimelineEntries(
            listOf(
                activity("command-1", "turn-1", ConversationActivityCategory.RunCommand),
                message("commentary", ConversationRole.Assistant),
                activity("command-2", "turn-1", ConversationActivityCategory.RunCommand),
                activity("command-3", "turn-2", ConversationActivityCategory.RunCommand),
            ),
        )

        assertEquals(4, entries.size)
        assertTrue(entries[0] is ConversationTimelineEntry.ActivityGroup)
        assertTrue(entries[1] is ConversationTimelineEntry.Message)
        assertTrue(entries[2] is ConversationTimelineEntry.ActivityGroup)
        assertTrue(entries[3] is ConversationTimelineEntry.ActivityGroup)
    }

    @Test
    fun `legacy activity without structured payload remains visible as a normal message`() {
        val legacy = ConversationMessage("legacy", ConversationRole.Activity, "Legacy progress")
        val entries = conversationTimelineEntries(listOf(legacy))

        assertEquals(1, entries.size)
        assertEquals(legacy, (entries.single() as ConversationTimelineEntry.Message).message)
    }

    @Test
    fun `successful step remains successful when its turn later fails`() {
        val status = timelineItemStatus(
            activity = ConversationActivity(
                category = ConversationActivityCategory.EditFile,
                title = "Edited client.kt",
                status = "completed",
            ),
            lifecycle = ConversationTurnLifecycle.Failed,
        )

        assertEquals(TimelineStatus.Completed, status)
    }

    @Test
    fun `unfinished step inherits interrupted turn status`() {
        val status = timelineItemStatus(
            activity = ConversationActivity(
                category = ConversationActivityCategory.ToolCall,
                title = "Tool call",
            ),
            lifecycle = ConversationTurnLifecycle.Interrupted,
        )

        assertEquals(TimelineStatus.Interrupted, status)
    }

    @Test
    fun `activity progress hides markdown protocol formatting`() {
        assertEquals(
            "Planning release build\nENABLE_TESTABILITY=YES\nfinal note",
            plainActivityProgressText(
                "**Planning release build**\n" +
                    "`ENABLE_TESTABILITY=YES`\n" +
                    "### _final note_",
            ),
        )
    }

    private fun activity(
        id: String,
        turnId: String,
        category: ConversationActivityCategory,
    ): ConversationMessage = ConversationMessage(
        id = id,
        role = ConversationRole.Activity,
        text = id,
        turnId = turnId,
        itemId = id,
        activity = ConversationActivity(category, id, status = "completed"),
    )

    private fun message(id: String, role: ConversationRole): ConversationMessage =
        ConversationMessage(id, role, id)
}
