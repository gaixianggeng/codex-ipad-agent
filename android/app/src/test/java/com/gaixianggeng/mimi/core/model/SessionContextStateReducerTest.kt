package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionContextStateReducerTest {
    @Test
    fun `partial updates preserve environment and replace stable task in place`() {
        val base = SessionContextSnapshot(
            threadId = "thread",
            environment = SessionContextEnvironment(
                cwd = "/workspace",
                provider = "openai",
                runtimeProvider = "codex",
            ),
            tasks = listOf(SessionContextTask("cmd", "command", "Old", status = "running")),
        )
        val update = SessionContextSnapshot(
            threadId = "thread",
            environment = SessionContextEnvironment(provider = "openai-responses"),
            tasks = listOf(SessionContextTask("cmd", "command", "New", status = "completed")),
        )

        val merged = requireNotNull(SessionContextStateReducer.merge(base, update))

        assertEquals("/workspace", merged.environment?.cwd)
        assertEquals("codex", merged.environment?.runtimeProvider)
        assertEquals("openai-responses", merged.environment?.provider)
        assertEquals(listOf("cmd"), merged.tasks.map { it.id })
        assertEquals("New", merged.tasks.single().title)
        assertEquals("completed", merged.tasks.single().status)
    }

    @Test
    fun `tasks and subagents remain bounded and unique`() {
        val update = SessionContextSnapshot(
            threadId = "thread",
            tasks = (0..12).map { SessionContextTask("task-$it", "command", "Task $it") },
            subagents = (0..12).map { SessionContextSubagent("agent-$it", parentThreadId = "thread") },
        )

        val merged = requireNotNull(SessionContextStateReducer.merge(null, update))

        assertEquals(8, merged.tasks.size)
        assertEquals(8, merged.subagents.size)
        assertEquals(8, merged.tasks.map { it.id }.distinct().size)
        assertEquals(8, merged.subagents.map { it.id }.distinct().size)
    }

    @Test
    fun `null update leaves null state`() {
        assertNull(SessionContextStateReducer.merge(null, null))
    }
}
