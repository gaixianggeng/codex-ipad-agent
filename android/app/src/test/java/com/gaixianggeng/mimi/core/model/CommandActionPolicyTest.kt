package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CommandActionPolicyTest {
    @Test
    fun allowlistRejectsMalformedIdsDeduplicatesAndCapsEntries() {
        val actions = buildList {
            add(action(""))
            add(action(" spaced "))
            add(action("duplicate", command = "first"))
            add(action("duplicate", command = "second"))
            repeat(250) { add(action("action-$it")) }
        }

        val sanitized = CommandActionPolicy.sanitizeAllowlist(actions)

        assertEquals(CommandActionPolicy.MAX_ACTIONS, sanitized.size)
        assertEquals("duplicate", sanitized.first().id)
        assertEquals("first", sanitized.first().command)
        assertFalse(sanitized.any { it.id.isBlank() || it.id != it.id.trim() })
    }

    @Test
    fun resultOutputIsBoundedAndMarksClientSideTruncation() {
        val result = CommandActionPolicy.boundResult(
            CommandActionRunResponse(
                id = "tests",
                name = "Tests",
                path = "/repo",
                workingDir = "/repo",
                command = "gradle",
                success = true,
                exitCode = 0,
                output = "x".repeat(CommandActionPolicy.MAX_OUTPUT_CHARS + 1),
                durationMs = 10,
            ),
        )

        assertEquals(CommandActionPolicy.MAX_OUTPUT_CHARS, result.output?.length)
        assertTrue(result.truncated == true)
    }

    private fun action(id: String, command: String = "gradle") = AgentCommandAction(
        id = id,
        name = id,
        command = command,
        workingDir = "/repo",
        timeoutSeconds = 60,
    )
}
