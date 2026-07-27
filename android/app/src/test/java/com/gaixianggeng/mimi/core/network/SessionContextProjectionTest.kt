package com.gaixianggeng.mimi.core.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionContextProjectionTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `thread projection preserves environment git sources tasks and subagents`() {
        val thread = json.parseToJsonElement(
            """
            {
              "id": "thread-parent",
              "cwd": "/workspace/client",
              "modelProvider": "openai",
              "status": {"type": "active", "activeFlags": ["waitingOnApproval"]},
              "gitInfo": {"sha": "abcdef1234567890", "branch": "feature/context", "originUrl": "https://example.invalid/repo"},
              "source": {"custom": "Mimi Remote"},
              "threadSource": "app-server",
              "forkedFromId": "thread-root",
              "turns": [{
                "id": "turn-1",
                "status": "completed",
                "items": [
                  {"type":"commandExecution","id":"cmd","command":["./gradlew","test"],"cwd":"/workspace/client","status":"completed"},
                  {"type":"fileChange","id":"files","changes":[{"path":"A.kt"},{"path":"B.kt"}],"status":"completed"},
                  {"type":"collabAgentToolCall","id":"collab","childThreadId":"thread-child","agentNickname":"Tester","agentRole":"Runs tests","status":"running"},
                  {"type":"webSearch","id":"search","query":"Material 3 tabs","status":"failed"}
                ]
              }]
            }
            """.trimIndent(),
        ).jsonObject

        val context = requireNotNull(SessionContextProjection.fromThread(thread, "/fallback", "codex"))

        assertEquals("thread-parent", context.threadId)
        assertEquals("openai", context.environment?.provider)
        assertEquals("feature/context", context.git?.branch)
        assertEquals(listOf("session", "thread", "fork"), context.sources.map { it.kind })
        assertEquals(listOf("web_search", "subagent", "file_change", "command"), context.tasks.map { it.kind })
        assertEquals("thread-child", context.subagents.single().id)
        assertEquals("Tester", context.subagents.single().displayName)
        assertTrue("waitingOnApproval" in context.status?.activeFlags.orEmpty())
    }

    @Test
    fun `conversation page projects recent tasks and collab metadata with messages`() {
        val result = json.parseToJsonElement(
            """
            {
              "data": [{
                "id": "turn-new",
                "status": "running",
                "items": [
                  {"type":"userMessage","id":"user","content":[{"type":"text","text":"Run checks"}]},
                  {"type":"commandExecution","id":"cmd","command":"./gradlew test","status":"running"},
                  {"type":"collabAgentToolCall","id":"collab","childThreadId":"child","nickname":"Verifier","role":"Checks output","status":"running"}
                ]
              }],
              "nextCursor": "older"
            }
            """.trimIndent(),
        ).jsonObject

        val page = AppServerProjection.conversationPage(result, "thread-parent")

        assertEquals("older", page.nextCursor)
        assertEquals(3, page.messages.size)
        assertEquals(listOf("subagent", "command"), page.context?.tasks?.map { it.kind })
        assertEquals("Verifier", page.context?.subagents?.single()?.displayName)
        assertEquals("active", page.context?.status?.type)
    }

    @Test
    fun `unrelated item does not fabricate context task`() {
        val item = json.parseToJsonElement(
            """{"type":"agentMessage","id":"assistant","text":"Done"}"""
        ).jsonObject

        assertEquals(null, SessionContextProjection.fromItem("thread", "turn", item, "completed"))
    }

    @Test
    fun `primitive attention status preserves raw meaning and active flag`() {
        val thread = json.parseToJsonElement(
            """{"id":"thread-1","cwd":"/workspace","status":"waiting_for_approval"}"""
        ).jsonObject

        val status = requireNotNull(
            SessionContextProjection.fromThread(thread, "/fallback", "codex")?.status,
        )

        assertEquals("active", status.type)
        assertEquals("waiting_for_approval", status.rawType)
        assertEquals(listOf("waitingOnApproval"), status.activeFlags)
    }

    @Test
    fun `object attention status synthesizes missing active flag`() {
        val thread = json.parseToJsonElement(
            """{"id":"thread-1","cwd":"/workspace","status":{"type":"waiting_for_input"}}"""
        ).jsonObject

        val status = requireNotNull(
            SessionContextProjection.fromThread(thread, "/fallback", "codex")?.status,
        )

        assertEquals("active", status.type)
        assertEquals("waiting_for_input", status.rawType)
        assertEquals(listOf("waitingOnUserInput"), status.activeFlags)
    }
}
