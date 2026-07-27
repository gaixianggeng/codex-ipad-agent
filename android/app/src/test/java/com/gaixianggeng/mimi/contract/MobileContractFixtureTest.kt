package com.gaixianggeng.mimi.contract

import kotlinx.serialization.json.Json
import com.gaixianggeng.mimi.core.model.GitStatusResponse
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileContractFixtureTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `manifest and rest fixtures remain valid json`() {
        listOf(
            "manifest.json",
            "rest/health.json",
            "rest/pairing-claim-request.json",
            "rest/pairing-claim-response.json",
            "rest/projects.json",
            "rest/app-server-config.json",
            "rest/git-status.json",
            "app-server/history-page.json",
        ).forEach { path ->
            val text = resource(path)
            assertNotNull(path, json.parseToJsonElement(text))
        }
    }

    @Test
    fun `git status fixture maps wire names and file flags`() {
        val status = json.decodeFromString<GitStatusResponse>(resource("rest/git-status.json"))
        assertTrue(status.isRepository)
        assertEquals("main", status.branch)
        assertEquals("android/app/src/main/MainActivity.kt", status.files.single().path)
        assertTrue(status.files.single().unstaged)
    }

    @Test
    fun `git status accepts sparse file flags from older agents`() {
        val status = json.decodeFromString<GitStatusResponse>(
            """
            {
              "path": "/workspace",
              "is_repository": true,
              "files": [
                {
                  "path": "README.md",
                  "code": " M",
                  "unstaged": true
                }
              ]
            }
            """.trimIndent(),
        )

        assertTrue(status.files.single().unstaged)
        assertEquals(false, status.files.single().staged)
        assertEquals(false, status.files.single().untracked)
    }

    @Test
    fun `conversation stream preserves ordered json rpc frames`() {
        val frames = resource("app-server/conversation.ndjson")
            .lineSequence().filter { it.isNotBlank() }.map(json::parseToJsonElement).toList()
        assertEquals(10, frames.size)
        assertEquals("thread/started", frames[2].jsonObject["method"]?.toString()?.trim('"'))
        assertTrue(frames.any { it.jsonObject["method"]?.toString() == "\"item/agentMessage/delta\"" })
        assertEquals("turn/completed", frames.last().jsonObject["method"]?.toString()?.trim('"'))
    }

    private fun resource(path: String): String =
        checkNotNull(javaClass.classLoader?.getResource(path)) { "Missing fixture: $path" }.readText()
}
