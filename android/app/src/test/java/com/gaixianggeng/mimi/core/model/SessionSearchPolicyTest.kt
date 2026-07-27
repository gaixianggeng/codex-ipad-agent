package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionSearchPolicyTest {
    @Test
    fun staleGenerationOrChangedQueryCannotPublishResults() {
        assertEquals(300L, SessionSearchPolicy.DEBOUNCE_MILLIS)
        assertTrue(SessionSearchPolicy.isCurrent(4, 4, "auth", "  auth  "))
        assertFalse(SessionSearchPolicy.isCurrent(3, 4, "auth", "auth"))
        assertFalse(SessionSearchPolicy.isCurrent(4, 4, "auth", "other"))
    }

    @Test
    fun initialResultsFilterProjectDeduplicateRuntimeAndRetainIndependentCursors() {
        val codex = ThreadSearchResult(thread("same", "/repo"), "Codex snippet")
        val claudeDuplicate = ThreadSearchResult(thread("same", "/repo"), "Claude snippet")
        val otherProject = ThreadSearchResult(thread("other", "/elsewhere"), "Other")
        val projection = SessionSearchPolicy.initial(
            pages = linkedMapOf(
                "codex" to ThreadSearchPage(listOf(codex, otherProject), "codex-2"),
                "claude" to ThreadSearchPage(listOf(claudeDuplicate), "claude-2"),
            ),
            projectPath = "/repo",
        )

        assertEquals(listOf("same"), projection.results.map { it.thread.id })
        assertEquals("Codex snippet", projection.results.single().snippet)
        assertEquals(mapOf("codex" to "codex-2", "claude" to "claude-2"), projection.cursors)
    }

    @Test
    fun paginationPreservesOrderUpdatesDuplicatesAndStopsRepeatedCursors() {
        val projection = SessionSearchPolicy.append(
            existing = listOf(
                ThreadSearchResult(thread("one", "/repo"), "old"),
                ThreadSearchResult(thread("two", "/repo"), "two"),
            ),
            pages = linkedMapOf(
                "codex" to ThreadSearchPage(
                    listOf(
                        ThreadSearchResult(thread("one", "/repo"), "updated"),
                        ThreadSearchResult(thread("three", "/repo"), "three"),
                    ),
                    "same-cursor",
                ),
                "claude" to ThreadSearchPage(emptyList(), "claude-next"),
            ),
            previousCursors = mapOf("codex" to "same-cursor", "claude" to "claude-old"),
            projectPath = "/repo",
        )

        assertEquals(listOf("one", "two", "three"), projection.results.map { it.thread.id })
        assertEquals("updated", projection.results.first().snippet)
        assertEquals(mapOf("claude" to "claude-next"), projection.cursors)
    }

    private fun thread(id: String, cwd: String) = AgentThread(
        id = id,
        preview = "Session $id",
        cwd = cwd,
    )
}
