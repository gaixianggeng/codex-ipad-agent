package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.ImageAttachment
import com.gaixianggeng.mimi.core.model.ComposerSendMode
import com.gaixianggeng.mimi.core.model.PermissionMode
import com.gaixianggeng.mimi.core.model.SkillCapability
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AppServerRequestTest {
    @Test
    fun websocketUrlRoutesClaudeExplicitlyAndKeepsCodexDefault() {
        assertEquals(
            "wss://agent.example/api/app-server/ws?thread_id=thread%2Fone&runtime=claude",
            appServerWebSocketUrl(
                endpoint = "https://agent.example",
                threadId = "thread/one",
                runtimeProvider = "anthropic",
            ),
        )
        assertEquals(
            "ws://127.0.0.1:8787/api/app-server/ws",
            appServerWebSocketUrl(
                endpoint = "http://127.0.0.1:8787",
                threadId = null,
                runtimeProvider = "codex",
            ),
        )
    }

    @Test
    fun planTurnCarriesExplicitCollaborationModeAndModelSettings() {
        val params = turnStartParams(
            threadId = "thread-plan",
            cwd = "/repo",
            text = "Plan the migration",
            clientMessageId = "client-plan",
            model = "gpt-plan",
            effort = "high",
            skills = emptyList(),
            images = emptyList(),
            permissionMode = PermissionMode.ReadOnly,
            collaborationMode = ComposerSendMode.Plan,
        )

        val collaboration = params.getValue("collaborationMode").jsonObject
        assertEquals("plan", collaboration.getValue("mode").jsonPrimitive.content)
        val settings = collaboration.getValue("settings").jsonObject
        assertEquals("gpt-plan", settings.getValue("model").jsonPrimitive.content)
        assertEquals("high", settings.getValue("reasoning_effort").jsonPrimitive.content)
        assertEquals("readOnly", params.getValue("sandboxPolicy").jsonObject.getValue("type").jsonPrimitive.content)
    }

    @Test
    fun turnSteerCarriesExpectedTurnAndStructuredInputWithoutStartOptions() {
        val params = turnSteerParams(
            threadId = "thread-1",
            expectedTurnId = "turn-9",
            clientMessageId = "client-7",
            text = "Please check the tests",
            skills = listOf(SkillCapability("testing", null, "skill", "/skills/testing", true)),
            images = listOf(ImageAttachment("image-1", "data:image/jpeg;base64,AA==", 10, 20, 2)),
        )

        assertEquals("thread-1", params.getValue("threadId").jsonPrimitive.content)
        assertEquals("turn-9", params.getValue("expectedTurnId").jsonPrimitive.content)
        assertEquals("client-7", params.getValue("clientUserMessageId").jsonPrimitive.content)
        val input = params.getValue("input").jsonArray
        assertEquals(listOf("text", "image", "skill"), input.map { it.jsonObject.getValue("type").jsonPrimitive.content })
        assertFalse(params.containsKey("model"))
        assertFalse(params.containsKey("approvalPolicy"))
        assertFalse(params.containsKey("sandboxPolicy"))
    }

    @Test
    fun goalStatusUpdateDoesNotOverwriteObjectiveOrBudget() {
        val params = threadGoalSetParams(
            threadId = " thread-1 ",
            status = ThreadGoalStatus.Paused,
        )

        assertEquals("thread-1", params.getValue("threadId").jsonPrimitive.content)
        assertEquals("paused", params.getValue("status").jsonPrimitive.content)
        assertFalse(params.containsKey("objective"))
        assertFalse(params.containsKey("tokenBudget"))
    }

    @Test
    fun goalEditCarriesNormalizedObjectiveStatusAndBudget() {
        val params = threadGoalSetParams(
            threadId = "thread-1",
            objective = "  Ship Android parity  ",
            status = ThreadGoalStatus.Active,
            tokenBudget = 20_000,
        )

        assertEquals("Ship Android parity", params.getValue("objective").jsonPrimitive.content)
        assertEquals("active", params.getValue("status").jsonPrimitive.content)
        assertEquals(20_000, params.getValue("tokenBudget").jsonPrimitive.content.toLong())
    }
}
