package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationAttachmentKind
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationCommandPresentationKind
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppServerProjectionTest {
    @Test
    fun `plan and token usage notifications preserve visible progress context`() {
        val plan = json.parseToJsonElement(
            """{"threadId":"thread-1","turnId":"turn-1","plan":[{"step":"Implement protocol","status":"completed"},{"step":"Run tests","status":"inProgress"}]}"""
        ).jsonObject
        val usage = json.parseToJsonElement(
            """{"threadId":"thread-1","tokenUsage":{"total":{"inputTokens":100,"outputTokens":50,"totalTokens":150},"modelContextWindow":200000}}"""
        ).jsonObject

        assertEquals("### Plan\n- [x] Implement protocol\n- [ ] Run tests", AppServerProjection.planMarkdown(plan))
        assertEquals("150 / 200000 tokens · input 100 · output 50", AppServerProjection.tokenUsageSummary(usage))
    }

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `approval fixture is projected and replies fail closed`() {
        val event = fixtureEvents().first { it.method == "item/commandExecution/requestApproval" }
        val approval = requireNotNull(AppServerProjection.approval(event))
        assertEquals("command", approval.kind)
        assertTrue(approval.body.orEmpty().contains("go test ./..."))
        assertEquals("accept", AppServerProjection.approvalResponse(approval, "approve")["decision"]?.jsonPrimitive?.content)
        assertEquals("decline", AppServerProjection.approvalResponse(approval, "unknown")["decision"]?.jsonPrimitive?.content)
    }

    @Test
    fun `persistent permission only exposes exact eligible local allow rules`() {
        val params = json.parseToJsonElement(
            """{"threadId":"thr","itemId":"perm","command":"edit file","affectedCount":3,"availableDecisions":["accept","acceptWithPermissionUpdate"],"permissionSuggestions":[{"type":"addRules","behavior":"allow","destination":"localSettings","rules":["Edit(Sources/**)",{"toolName":"Bash","ruleContent":"git status"},"Edit(Sources/**)"]},{"type":"addRules","behavior":"allow","destination":"remoteSettings","rules":["Unsafe(*)"]},{"type":"removeRules","behavior":"allow","destination":"localSettings","rules":["Wrong(*)"]}]}"""
        ).jsonObject
        val request = AppServerProjection.approval(AppServerEvent("item/commandExecution/requestApproval", params, json.parseToJsonElement("1")))!!

        assertEquals(listOf("Edit(Sources/**)", "Bash(git status)"), request.persistentPermissionRules)
        assertEquals(3, request.count)
        assertEquals(
            "acceptWithPermissionUpdate",
            AppServerProjection.approvalResponse(request, "acceptWithPermissionUpdate")["decision"]?.jsonPrimitive?.content,
        )
    }

    @Test
    fun `permissions approval response never expands remote permission scope`() {
        val params = json.parseToJsonElement(
            """{"threadId":"thr","itemId":"perm","permissions":{"sandbox":"danger-full-access","networkAccess":true}}"""
        ).jsonObject
        val request = AppServerProjection.approval(
            AppServerEvent("item/permissions/requestApproval", params, json.parseToJsonElement("2")),
        )!!

        listOf("accept", "decline").forEach { decision ->
            val response = AppServerProjection.approvalResponse(request, decision)
            assertTrue(response["permissions"]?.jsonObject?.isEmpty() == true)
            assertEquals("turn", response["scope"]?.jsonPrimitive?.content)
            assertEquals(true, response["strictAutoReview"]?.jsonPrimitive?.booleanOrNull)
            assertFalse(response.containsKey("decision"))
        }
    }

    @Test
    fun `user input fixture preserves options and structured answer shape`() {
        val event = fixtureEvents().first { it.method == "item/tool/requestUserInput" }
        val request = requireNotNull(AppServerProjection.userInput(event))
        assertEquals("scope", request.questions.single().id)
        assertEquals(listOf("unit", "all"), request.questions.single().options.map { it.label })
        val response = AppServerProjection.userInputResponse(request, mapOf("scope" to listOf("all")))
        val answer = response["answers"]?.jsonObject?.get("scope")?.jsonObject
        assertNotNull(answer)
        assertTrue(answer.toString().contains("all"))
    }

    @Test
    fun `history page is ordered oldest to newest`() {
        val result = json.parseToJsonElement(resource("app-server/history-page.json")).jsonObject
        val page = AppServerProjection.conversationPage(result)
        assertEquals(listOf("Old question", "Old answer", "New question", "New answer"), page.messages.map { it.text })
        assertEquals(listOf(ConversationRole.User, ConversationRole.Assistant, ConversationRole.User, ConversationRole.Assistant), page.messages.map { it.role })
        assertEquals("older-page", page.nextCursor)
    }

    @Test
    fun `history preserves remote images local files mentions and skills`() {
        val result = json.parseToJsonElement(
            """{"data":[{"id":"turn-1","items":[{"type":"userMessage","id":"user-1","content":[{"type":"text","text":"Inspect these"},{"type":"image","url":"https://example.test/image.png","detail":"high"},{"type":"localImage","path":"C:\\\\work\\\\shot.png"},{"type":"mention","name":"Main.kt","path":"C:\\\\work\\\\Main.kt"},{"type":"skill","name":"android","path":"C:\\\\skills\\\\android"}]}]}]}"""
        ).jsonObject

        val message = AppServerProjection.conversationPage(result).messages.single()

        assertEquals("Inspect these", message.text)
        assertEquals(
            listOf(
                ConversationAttachmentKind.Image,
                ConversationAttachmentKind.LocalImage,
                ConversationAttachmentKind.Mention,
                ConversationAttachmentKind.Skill,
            ),
            message.attachments.map { it.kind },
        )
        assertEquals("https://example.test/image.png", message.attachments.first().url)
        assertEquals("Main.kt", message.attachments[2].name)
    }

    @Test
    fun `history preserves reasoning commands file changes and tool calls in canonical order`() {
        val result = json.parseToJsonElement(
            """
            {
              "data": [{
                "id": "turn-activity",
                "status": "completed",
                "items": [
                  {"type":"userMessage","id":"user-activity","content":[{"type":"text","text":"Update it"}]},
                  {"type":"reasoning","id":"reasoning-1","summary":["Inspecting network client"],"status":"completed"},
                  {"type":"commandExecution","id":"command-1","command":"sed -n '1,80p' src/network/client.kt","cwd":"/repo","status":"completed","exitCode":0,"aggregatedOutput":"class NetworkClient","commandActions":[{"type":"read","path":"src/network/client.kt"}]},
                  {"type":"fileChange","id":"file-1","status":"completed","changes":[{"path":"src/network/client.kt"},{"path":"src/network/Retry.kt"}]},
                  {"type":"dynamicToolCall","id":"tool-1","toolName":"github.search","status":"completed"},
                  {"type":"agentMessage","id":"assistant-activity","text":"Done"}
                ]
              }]
            }
            """.trimIndent(),
        ).jsonObject

        val messages = AppServerProjection.conversationPage(result).messages

        assertEquals(
            listOf(
                ConversationRole.User,
                ConversationRole.Activity,
                ConversationRole.Activity,
                ConversationRole.Activity,
                ConversationRole.Activity,
                ConversationRole.Assistant,
            ),
            messages.map { it.role },
        )
        assertEquals(
            listOf(
                ConversationActivityCategory.Thinking,
                ConversationActivityCategory.RunCommand,
                ConversationActivityCategory.EditFile,
                ConversationActivityCategory.ToolCall,
            ),
            messages.mapNotNull { it.activity?.category },
        )
        assertEquals(
            ConversationCommandPresentationKind.Exploration,
            messages.first { it.id == "command-1" }.activity?.commandPresentationKind,
        )
        assertEquals(listOf("src/network/client.kt", "src/network/Retry.kt"), messages.first { it.id == "file-1" }.activity?.filePaths)
        assertTrue(messages.all { it.turnId == "turn-activity" })
        assertTrue(messages.all { it.turnLifecycle == ConversationTurnLifecycle.Completed })
    }

    @Test
    fun `started process item is projected as running and completed failure keeps bounded output`() {
        val item = json.parseToJsonElement(
            """{"type":"commandExecution","id":"command-running","command":"./gradlew test","cwd":"/repo","status":"failed","exitCode":1,"aggregatedOutput":"${"x".repeat(17_000)}"}""",
        ).jsonObject

        val running = requireNotNull(
            AppServerProjection.conversationActivityMessage(
                item,
                "turn-1",
                ConversationTurnLifecycle.Running,
                statusOverride = "inProgress",
            ),
        )
        val completed = requireNotNull(AppServerProjection.conversationActivityMessage(item, "turn-1"))

        assertTrue(running.activity?.isRunning == true)
        assertTrue(completed.activity?.isFailure == true)
        assertEquals(16_000, completed.activity?.outputPreview?.length)
        assertTrue(completed.activity?.outputTruncated == true)
    }

    @Test
    fun `rate limit projection accepts current codex payload`() {
        val payload = json.parseToJsonElement(
            """{"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":25.5,"resetsAt":2000000000,"windowDurationMins":300},"secondary":{"used_percent":60,"resets_at":2000600000,"window_duration_mins":10080}}}}"""
        ).jsonObject

        val usage = AppServerProjection.rateLimitSummary(payload)!!

        assertEquals("plus", usage.planType)
        assertEquals(25.5, usage.primaryUsedPercent!!, 0.001)
        assertEquals(60.0, usage.secondaryUsedPercent!!, 0.001)
        assertEquals(10_080, usage.secondaryWindowDurationMinutes)
    }

    @Test
    fun `thread list preserves pagination and canonical fields`() {
        val result = json.parseToJsonElement(resource("app-server/thread-search-page.json")).jsonObject
        val listResult = buildJsonObject {
            put("data", result["data"]!!.jsonArray.map { it.jsonObject["thread"]!! }.let(::JsonArray))
            put("nextCursor", result["nextCursor"]!!)
        }
        val page = AppServerProjection.threadPage(listResult, "/fallback")
        assertEquals(listOf("thr-search-1", "thr-search-2"), page.threads.map { it.id })
        assertEquals("search-next", page.nextCursor)
        assertEquals("Named session", page.threads.first().preview)
    }

    @Test
    fun `thread search projects snippets and next cursor`() {
        val result = json.parseToJsonElement(resource("app-server/thread-search-page.json")).jsonObject
        val page = AppServerProjection.threadSearchPage(result)
        assertEquals(2, page.results.size)
        assertEquals("Matched historical text", page.results.first().snippet)
        assertEquals("/repo/two", page.results.last().thread.cwd)
        assertEquals("search-next", page.nextCursor)
    }

    @Test
    fun `model list keeps default and reasoning metadata`() {
        val result = json.parseToJsonElement(
            """{"models":["gpt-basic",{"model":"gpt-deep","displayName":"GPT Deep","provider":"openai","isDefault":true,"defaultReasoningEffort":"high","supportedReasoningEfforts":[{"reasoningEffort":"medium"},"high"]}]}"""
        )
        val options = AppServerProjection.modelOptions(result)
        assertEquals("gpt-deep", options.first().id)
        assertEquals("GPT Deep", options.first().title)
        assertEquals(listOf("medium", "high"), options.first().supportedReasoningEfforts)
        assertEquals("high", options.first().defaultReasoningEffort)
    }

    @Test
    fun `skills select the matching cwd and rich interface name`() {
        val result = json.parseToJsonElement(
            """{"data":[{"cwd":"/other","skills":[{"name":"wrong","path":"/wrong/SKILL.md"}]},{"cwd":"/repo","skills":[{"name":"review","description":"Review changes","scope":"system","path":"/skills/review/SKILL.md","enabled":true,"interface":{"displayName":"Code Review","shortDescription":"Find risky changes"}}]}]}"""
        ).jsonObject
        val skills = AppServerProjection.skills(result, "/repo")
        assertEquals(1, skills.size)
        assertEquals("Code Review", skills.single().presentationName)
        assertEquals("Find risky changes", skills.single().description)
    }

    @Test
    fun `installed plugins are deduplicated filtered and sorted`() {
        val result = json.parseToJsonElement(
            """{"marketplaces":[{"name":"bundled","plugins":[{"id":"disabled","name":"Disabled","installed":true,"enabled":false},{"id":"active","name":"fallback","installed":true,"enabled":true,"interface":{"displayName":"Active Plugin","shortDescription":"Useful"}},{"id":"missing","name":"Missing","installed":false},{"id":"active","name":"Duplicate","installed":true}]}]}"""
        ).jsonObject

        val plugins = AppServerProjection.installedPlugins(result)

        assertEquals(listOf("active", "disabled"), plugins.map { it.id })
        assertEquals("Active Plugin", plugins.first().name)
        assertEquals("bundled", plugins.first().marketplace)
    }

    @Test
    fun `thread goal accepts wrapped camel case result`() {
        val result = json.parseToJsonElement(
            """{"goal":{"threadId":"thr-goal","objective":"Ship Android parity","status":"active","tokenBudget":12000,"tokensUsed":250,"timeUsedSeconds":90,"createdAt":1780000000,"updatedAt":1780000100}}"""
        ).jsonObject

        val goal = requireNotNull(AppServerProjection.threadGoal(result))

        assertEquals("thr-goal", goal.threadId)
        assertEquals("Ship Android parity", goal.objective)
        assertEquals(12000L, goal.tokenBudget)
        assertEquals(250L, goal.tokensUsed)
    }

    @Test
    fun `thread goal accepts snake case event and rejects malformed objective`() {
        val valid = json.parseToJsonElement(
            """{"thread_id":"thr-snake","objective":"Keep working","status":"paused","token_budget":500,"tokens_used":12}"""
        ).jsonObject
        val malformed = json.parseToJsonElement(
            """{"thread_id":"thr-snake","objective":"   ","status":"active"}"""
        ).jsonObject

        assertEquals("paused", requireNotNull(AppServerProjection.threadGoal(valid)).status.wireName)
        assertEquals(null, AppServerProjection.threadGoal(malformed))
    }

    private fun fixtureEvents(): List<AppServerEvent> = resource("app-server/conversation.ndjson")
        .lineSequence().filter(String::isNotBlank).map { line ->
            val frame = json.parseToJsonElement(line).jsonObject
            AppServerEvent(
                method = frame["method"]?.jsonPrimitive?.content.orEmpty(),
                params = frame["params"] as? JsonObject ?: buildJsonObject {},
                requestId = frame["id"],
            )
        }.toList()

    private fun resource(path: String): String =
        checkNotNull(javaClass.classLoader?.getResource(path)) { "Missing fixture: $path" }.readText()
}
