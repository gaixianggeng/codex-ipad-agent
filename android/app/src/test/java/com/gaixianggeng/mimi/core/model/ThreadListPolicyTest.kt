package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThreadListPolicyTest {
    @Test
    fun appendUpdatesDuplicateThreadsAndStopsBlankOrRepeatedCursors() {
        val existing = listOf(thread("one", "old"), thread("two", "stable"))
        val projection = ThreadListPolicy.append(
            existing = existing,
            pages = mapOf(
                "codex" to ThreadPage(listOf(thread("one", "new"), thread("three", "added")), "cursor-1"),
                "claude" to ThreadPage(emptyList(), " "),
            ),
            previousCursors = mapOf("codex" to "cursor-1", "claude" to "claude-1"),
        )

        assertEquals(listOf("one", "two", "three"), projection.threads.map(AgentThread::id))
        assertEquals("new", projection.threads.first().preview)
        assertTrue(projection.cursors.isEmpty())
    }

    @Test
    fun failedRuntimeRetainsItsCursorAndLateProjectResultsAreRejected() {
        val projection = ThreadListPolicy.append(
            existing = listOf(thread("one", "old")),
            pages = mapOf("codex" to ThreadPage(emptyList(), null)),
            previousCursors = mapOf("codex" to "codex-1", "claude" to "claude-1"),
        )

        assertEquals(mapOf("claude" to "claude-1"), projection.cursors)
        assertTrue(ThreadListPolicy.isCurrent(4, 4, "project-a", "project-a"))
        assertFalse(ThreadListPolicy.isCurrent(4, 5, "project-a", "project-a"))
        assertFalse(ThreadListPolicy.isCurrent(4, 4, "project-a", "project-b"))
    }

    private fun thread(id: String, preview: String) = AgentThread(
        id = id,
        cwd = "/repo",
        preview = preview,
    )
}
