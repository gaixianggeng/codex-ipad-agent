package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.ApprovalRequest
import com.gaixianggeng.mimi.core.model.ConversationActivity
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationCommandPresentationKind
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationAttachment
import com.gaixianggeng.mimi.core.model.ConversationAttachmentKind
import com.gaixianggeng.mimi.core.model.ConversationPage
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.core.model.ConversationTimelineStateReducer
import com.gaixianggeng.mimi.core.model.UserInputOption
import com.gaixianggeng.mimi.core.model.UserInputQuestion
import com.gaixianggeng.mimi.core.model.UserInputRequest
import com.gaixianggeng.mimi.core.model.AgentThread
import com.gaixianggeng.mimi.core.model.ThreadPage
import com.gaixianggeng.mimi.core.model.ThreadSearchPage
import com.gaixianggeng.mimi.core.model.ThreadSearchResult
import com.gaixianggeng.mimi.core.model.ModelOption
import com.gaixianggeng.mimi.core.model.SkillCapability
import com.gaixianggeng.mimi.core.model.PluginCapability
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.core.model.RateLimitSummary
import com.gaixianggeng.mimi.core.model.RuntimeRoutingPolicy
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

object AppServerProjection {
    fun planMarkdown(params: JsonObject): String? {
        val plan = params["plan"] as? JsonArray ?: return null
        val rows = plan.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val step = item.firstString("step", "text", "title")?.trim().orEmpty()
            if (step.isEmpty()) return@mapNotNull null
            val checked = item.firstString("status", "state")?.lowercase() in setOf("completed", "complete", "done")
            "- [${if (checked) "x" else " "}] $step"
        }
        return rows.takeIf(List<String>::isNotEmpty)?.joinToString("\n", prefix = "### Plan\n")
    }

    fun tokenUsageSummary(params: JsonObject): String? {
        val usage = (params["tokenUsage"] ?: params["token_usage"]) as? JsonObject ?: return null
        val total = usage["total"] as? JsonObject
        val totalTokens = total?.firstLong("totalTokens", "total_tokens")
            ?: usage.firstLong("totalTokens", "total_tokens")
            ?: return null
        val input = total?.firstLong("inputTokens", "input_tokens")
        val output = total?.firstLong("outputTokens", "output_tokens")
        val window = usage.firstLong("modelContextWindow", "model_context_window")
        return buildString {
            append(totalTokens)
            if (window != null) append(" / ").append(window)
            append(" tokens")
            if (input != null || output != null) append(" · input ").append(input ?: 0).append(" · output ").append(output ?: 0)
        }
    }

    fun rateLimitSummary(payload: JsonObject?): RateLimitSummary? {
        val objectValue = payload ?: return null
        val byLimit = (objectValue["rateLimitsByLimitId"] ?: objectValue["rate_limits_by_limit_id"]) as? JsonObject
        val snapshot = (byLimit?.get("codex") as? JsonObject)
            ?: byLimit?.values?.firstNotNullOfOrNull { it as? JsonObject }
            ?: ((objectValue["rateLimits"] ?: objectValue["rate_limits"]) as? JsonObject)
            ?: objectValue
        val primary = snapshot["primary"] as? JsonObject
        val secondary = snapshot["secondary"] as? JsonObject
        val summary = RateLimitSummary(
            planType = snapshot.firstString("planType", "plan_type"),
            reachedType = snapshot.firstString("rateLimitReachedType", "reachedType", "reached_type"),
            primaryUsedPercent = primary.firstDouble("usedPercent", "used_percent"),
            secondaryUsedPercent = secondary.firstDouble("usedPercent", "used_percent"),
            primaryResetsAt = primary.firstLong("resetsAt", "resets_at"),
            secondaryResetsAt = secondary.firstLong("resetsAt", "resets_at"),
            primaryWindowDurationMinutes = primary.firstLong("windowDurationMins", "window_duration_mins")?.toInt(),
            secondaryWindowDurationMinutes = secondary.firstLong("windowDurationMins", "window_duration_mins")?.toInt(),
            availability = snapshot.string("availability"),
            unavailableReason = snapshot.firstString("unavailableReason", "unavailable_reason"),
        )
        return summary.takeIf {
            listOf(it.planType, it.reachedType, it.availability, it.unavailableReason).any { value -> value != null } ||
                it.primaryUsedPercent != null || it.secondaryUsedPercent != null || it.primaryResetsAt != null || it.secondaryResetsAt != null
        }
    }
    fun modelOptions(result: JsonElement?): List<ModelOption> {
        val root = result ?: return emptyList()
        val items = when (root) {
            is JsonArray -> root
            is JsonObject -> listOf("models", "data", "items").firstNotNullOfOrNull { root[it] as? JsonArray }
                ?: JsonArray(emptyList())
            else -> JsonArray(emptyList())
        }
        val seen = mutableSetOf<String>()
        return items.mapNotNull { element ->
            if (element is JsonPrimitive) {
                val id = element.contentOrNull?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                if (!seen.add(id)) return@mapNotNull null
                ModelOption(id, id)
            } else {
                val item = element as? JsonObject ?: return@mapNotNull null
                val id = item.firstString("id", "model", "name", "slug")?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                val provider = item.firstString("provider", "modelProvider", "model_provider")
                val uniqueId = listOf(id, provider).filterNotNull().joinToString("@")
                if (!seen.add(uniqueId)) return@mapNotNull null
                val efforts = ((item["supportedReasoningEfforts"] ?: item["supported_reasoning_efforts"]) as? JsonArray)
                    .orEmpty().mapNotNull { effort ->
                        (effort as? JsonPrimitive)?.contentOrNull
                            ?: (effort as? JsonObject)?.firstString("reasoningEffort", "reasoning_effort", "effort", "id")
                    }.map(String::lowercase)
                ModelOption(
                    id = id,
                    title = item.firstString("title", "label", "displayName", "display_name", "name") ?: id,
                    provider = provider,
                    description = item.firstString("description", "summary"),
                    isDefault = item.bool("isDefault") ?: item.bool("is_default") ?: item.bool("default") ?: false,
                    supportedReasoningEfforts = efforts,
                    defaultReasoningEffort = item.firstString("defaultReasoningEffort", "default_reasoning_effort")?.lowercase(),
                )
            }
        }.sortedWith(compareByDescending<ModelOption> { it.isDefault }.thenBy { it.title.lowercase() })
    }

    fun skills(result: JsonObject, cwd: String): List<SkillCapability> {
        val entries = (result["data"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        val matching = entries.filter { it.string("cwd") == cwd }.ifEmpty { entries }
        val seen = mutableSetOf<String>()
        return matching.flatMap { (it["skills"] as? JsonArray).orEmpty() }.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val name = item.string("name")?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
            val path = item.string("path")?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
            if (!seen.add(path)) return@mapNotNull null
            val interfaceObject = item["interface"] as? JsonObject
            SkillCapability(
                name = name,
                description = interfaceObject?.string("shortDescription") ?: item.string("shortDescription") ?: item.string("description"),
                scope = item.string("scope") ?: "repo",
                path = path,
                enabled = item.bool("enabled") ?: true,
                displayName = interfaceObject?.string("displayName"),
            )
        }.sortedBy { it.presentationName.lowercase() }
    }

    fun installedPlugins(result: JsonObject): List<PluginCapability> {
        val seen = mutableSetOf<String>()
        return (result["marketplaces"] as? JsonArray).orEmpty().flatMap { marketplaceElement ->
            val marketplace = marketplaceElement as? JsonObject ?: return@flatMap emptyList()
            val marketplaceName = (marketplace["interface"] as? JsonObject)?.string("displayName")
                ?: marketplace.string("name").orEmpty()
            (marketplace["plugins"] as? JsonArray).orEmpty().mapNotNull { pluginElement ->
                val plugin = pluginElement as? JsonObject ?: return@mapNotNull null
                val id = plugin.string("id")?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                val fallbackName = plugin.string("name")?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                if (!seen.add(id) || plugin.bool("installed") == false) return@mapNotNull null
                val interfaceObject = plugin["interface"] as? JsonObject
                PluginCapability(
                    id = id,
                    name = interfaceObject?.string("displayName")?.trim()?.takeIf(String::isNotEmpty) ?: fallbackName,
                    description = interfaceObject?.firstString("shortDescription", "longDescription"),
                    marketplace = marketplaceName,
                    enabled = plugin.bool("enabled") ?: true,
                    installed = true,
                )
            }
        }.sortedWith(compareByDescending<PluginCapability> { it.enabled }.thenBy { it.name.lowercase() })
    }

    fun threadGoal(result: JsonObject?): ThreadGoal? {
        val objectValue = (result?.get("goal") as? JsonObject) ?: result ?: return null
        val threadId = objectValue.firstString("threadId", "thread_id")?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val objective = objectValue.string("objective")?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val status = ThreadGoalStatus.fromWire(objectValue.string("status")) ?: return null
        return ThreadGoal(
            threadId = threadId,
            objective = objective,
            status = status,
            tokenBudget = objectValue.long("tokenBudget") ?: objectValue.long("token_budget"),
            tokensUsed = objectValue.long("tokensUsed") ?: objectValue.long("tokens_used") ?: 0,
            timeUsedSeconds = objectValue.long("timeUsedSeconds") ?: objectValue.long("time_used_seconds") ?: 0,
            createdAtEpochSeconds = objectValue.long("createdAt") ?: objectValue.long("created_at"),
            updatedAtEpochSeconds = objectValue.long("updatedAt") ?: objectValue.long("updated_at"),
        )
    }

    fun threadPage(result: JsonObject, fallbackCwd: String, fallbackRuntimeProvider: String = "codex"): ThreadPage = ThreadPage(
        threads = (result["data"] as? JsonArray).orEmpty().mapNotNull {
            thread(it as? JsonObject ?: return@mapNotNull null, fallbackCwd, fallbackRuntimeProvider)
        },
        nextCursor = result.firstString("nextCursor", "next_cursor"),
    )

    fun threadSearchPage(result: JsonObject, fallbackRuntimeProvider: String = "codex"): ThreadSearchPage = ThreadSearchPage(
        results = (result["data"] as? JsonArray).orEmpty().mapNotNull { element ->
            val row = element as? JsonObject ?: return@mapNotNull null
            val threadObject = (row["thread"] as? JsonObject) ?: row
            val projected = thread(threadObject, threadObject.string("cwd").orEmpty(), fallbackRuntimeProvider) ?: return@mapNotNull null
            ThreadSearchResult(projected, row.string("snippet").orEmpty())
        },
        nextCursor = result.firstString("nextCursor", "next_cursor"),
    )

    fun approval(event: AppServerEvent): ApprovalRequest? {
        val requestId = event.requestId ?: return null
        if (!isApproval(event)) return null
        val params = event.params
        val kind = when {
            event.method.contains("fileChange", true) || event.method.contains("applyPatch", true) -> "file_change"
            event.method.contains("permission", true) -> "permission"
            event.method == "mcpServer/elicitation/request" -> "mcp_elicitation"
            else -> "command"
        }
        val command = params.commandSummary()
        val title = when (kind) {
            "file_change" -> "Agent requests a file change"
            "permission" -> "Agent requests elevated permissions"
            "mcp_elicitation" -> "${params.string("serverName") ?: "MCP service"} requests confirmation"
            else -> command?.let { "Agent requests to run: $it" }
                ?: params.string("toolName")?.let { "Agent requests tool: $it" }
                ?: "Agent requests to run a command"
        }
        val bodyParts = when (kind) {
            "command" -> listOf(command, params.string("toolName"), params.string("inputSummary"), params.string("reason"), params.string("message"))
            "mcp_elicitation" -> listOf(params.string("message"), params.string("url"))
            else -> listOf(
                params.firstString("path", "filePath", "file_path", "grantRoot", "grant_root"),
                params.firstString("diff", "patch"),
                params.firstString("inputSummary", "input_summary", "prompt"),
                params.firstString("reason", "message"),
            )
        }
        return ApprovalRequest(
            requestId = requestId,
            method = event.method,
            params = params,
            id = params.string("approvalId") ?: params.firstString("itemId", "item_id") ?: requestId.idText(),
            threadId = params.firstString("threadId", "conversationId", "sessionId", "session_id"),
            title = title,
            body = bodyParts.filterNotNull().filter(String::isNotBlank).distinct().joinToString("\n\n").ifBlank { null },
            kind = kind,
            risk = params.string("risk") ?: "high",
            availableDecisions = params.arrayStrings("availableDecisions"),
            persistentPermissionRules = persistentPermissionRules(params),
            count = approvalImpactCount(params),
        )
    }

    fun userInput(event: AppServerEvent): UserInputRequest? {
        val requestId = event.requestId ?: return null
        val isCodex = event.method == "item/tool/requestUserInput"
        val isMcpForm = event.method == "mcpServer/elicitation/request" && event.params.string("mode") != "url"
        if (!isCodex && !isMcpForm) return null
        val params = event.params
        val threadId = params.firstString("threadId", "sessionId", "session_id") ?: return null
        val questions = if (isCodex) {
            (params["questions"] as? JsonArray).orEmpty().mapNotNull(::question)
        } else {
            mcpQuestions(params)
        }
        val id = params.firstString("itemId", "item_id") ?: requestId.idText()
        return UserInputRequest(
            requestId = requestId,
            method = event.method,
            params = params,
            id = id,
            threadId = threadId,
            turnId = params.firstString("turnId", "turn_id"),
            questions = questions,
        )
    }

    fun approvalResponse(request: ApprovalRequest, decision: String): JsonObject {
        val normalized = when (decision.lowercase()) {
            "accept", "approve", "approved", "yes" -> "accept"
            "acceptforsession", "accept_for_session" -> "acceptForSession"
            "acceptwithpermissionupdate", "accept_with_permission_update" -> "acceptWithPermissionUpdate"
            "cancel" -> "cancel"
            else -> "decline"
        }
        return when (request.method) {
            "item/permissions/requestApproval" -> buildJsonObject {
                put("permissions", buildJsonObject {})
                put("scope", JsonPrimitive("turn"))
                put("strictAutoReview", JsonPrimitive(true))
            }
            "mcpServer/elicitation/request" -> buildJsonObject {
                put("action", JsonPrimitive(if (normalized == "accept") "accept" else if (normalized == "cancel") "cancel" else "decline"))
                put("content", JsonNull)
                put("_meta", JsonNull)
            }
            else -> buildJsonObject { put("decision", JsonPrimitive(normalized)) }
        }
    }

    fun userInputResponse(request: UserInputRequest, answers: Map<String, List<String>>): JsonObject {
        if (request.method == "mcpServer/elicitation/request") return mcpResponse(request, answers)
        return buildJsonObject {
            put("answers", buildJsonObject {
                answers.forEach { (id, values) ->
                    put(id, buildJsonObject {
                        put("answers", buildJsonArray { values.forEach { add(JsonPrimitive(it)) } })
                    })
                }
            })
        }
    }

    fun conversationActivityMessage(
        item: JsonObject,
        turnId: String?,
        turnLifecycle: ConversationTurnLifecycle = ConversationTurnLifecycle.Unknown,
        statusOverride: String? = null,
        itemCompleted: Boolean? = null,
    ): ConversationMessage? {
        val itemId = item.string("id") ?: return null
        val activity = conversationActivity(item, statusOverride) ?: return null
        return ConversationMessage(
            id = itemId,
            role = ConversationRole.Activity,
            text = activitySummary(activity),
            streaming = activity.isRunning,
            turnId = turnId,
            itemId = itemId,
            activity = activity,
            turnLifecycle = turnLifecycle,
            itemCompleted = itemCompleted ?: (!activity.isRunning && !activity.isPending),
        )
    }

    fun conversationActivity(item: JsonObject, statusOverride: String? = null): ConversationActivity? {
        val type = item.string("type") ?: return null
        val status = statusOverride ?: item.firstString("status", "state")
        return when (type) {
            "plan" -> {
                val text = item.firstString("text", "content")?.trim()?.takeIf(String::isNotEmpty) ?: return null
                ConversationActivity(
                    category = ConversationActivityCategory.Plan,
                    title = "Plan",
                    subtitle = text,
                    status = status,
                )
            }
            "reasoning" -> {
                val text = reasoningText(item).takeIf(String::isNotBlank) ?: return null
                ConversationActivity(
                    category = ConversationActivityCategory.Thinking,
                    title = "Reasoning",
                    subtitle = text,
                    status = status,
                )
            }
            "commandExecution" -> {
                val command = item.firstString("command", "processId")?.trim()?.takeIf(String::isNotEmpty)
                val actions = (item["commandActions"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                val presentation = commandPresentationKind(actions)
                val output = item.firstString("aggregatedOutput", "output")?.takeIf(String::isNotBlank)
                val preview = output?.takeLast(ACTIVITY_OUTPUT_PREVIEW_LIMIT)
                ConversationActivity(
                    category = ConversationActivityCategory.RunCommand,
                    title = commandActionTitle(actions) ?: command?.let { "Run ${compactCommand(it)}" } ?: "Run command",
                    subtitle = item.string("cwd"),
                    status = status,
                    command = command,
                    cwd = item.string("cwd"),
                    exitCode = item.firstLong("exitCode", "exit_code")?.toInt(),
                    outputPreview = preview,
                    outputTruncated = output != null && output.length > ACTIVITY_OUTPUT_PREVIEW_LIMIT,
                    commandPresentationKind = presentation,
                )
            }
            "fileChange" -> {
                val changes = (item["changes"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                val paths = changes.mapNotNull {
                    it.firstString("path", "filePath", "file_path", "relativePath", "relative_path")
                }.filter(String::isNotBlank).distinct()
                val title = when {
                    paths.size > 1 -> "Edited ${paths.size} files"
                    paths.size == 1 -> "Edited ${shortPath(paths.single())}"
                    else -> "Edited files"
                }
                ConversationActivity(
                    category = ConversationActivityCategory.EditFile,
                    title = title,
                    subtitle = status,
                    status = status ?: "modified",
                    filePaths = paths,
                )
            }
            "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch" -> {
                val toolName = toolIdentifier(item, type)
                ConversationActivity(
                    category = ConversationActivityCategory.ToolCall,
                    title = toolTitle(item, type, toolName),
                    status = status,
                    toolName = toolName,
                )
            }
            else -> null
        }
    }

    fun conversationPage(result: JsonObject, threadId: String? = null): ConversationPage {
        val turns = result["data"] as? JsonArray ?: JsonArray(emptyList())
        val messages = turns.asReversed().flatMap { turnElement ->
            val turn = turnElement as? JsonObject ?: return@flatMap emptyList()
            val turnId = turn.string("id").orEmpty()
            val lifecycle = turnLifecycle(turn)
            val items = turn["items"] as? JsonArray ?: return@flatMap emptyList()
            items.mapNotNull { itemElement ->
                val item = itemElement as? JsonObject ?: return@mapNotNull null
                val id = item.string("id") ?: "$turnId-${item.hashCode()}"
                when (item.string("type")) {
                    "userMessage" -> {
                        val parts = (item["content"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                        val content = parts.mapNotNull { part ->
                            part.takeIf { it.string("type") == "text" }?.string("text")
                        }.joinToString("\n")
                        val attachments = parts.mapNotNull(::conversationAttachment)
                        if (content.isBlank() && attachments.isEmpty()) null
                        else ConversationMessage(
                            id = id,
                            role = ConversationRole.User,
                            text = content,
                            attachments = attachments,
                            turnId = turnId,
                            itemId = id,
                            turnLifecycle = lifecycle,
                            itemCompleted = true,
                        )
                    }
                    "agentMessage" -> item.string("text")?.takeIf(String::isNotBlank)
                        ?.let {
                            ConversationMessage(
                                id = id,
                                role = if (item.string("phase") == "commentary") {
                                    ConversationRole.Commentary
                                } else {
                                    ConversationRole.Assistant
                                },
                                text = it,
                                turnId = turnId,
                                itemId = id,
                                turnLifecycle = lifecycle,
                                itemCompleted = lifecycle != ConversationTurnLifecycle.Running,
                            )
                        }
                    else -> conversationActivityMessage(item, turnId, lifecycle)
                }
            }
        }
        return ConversationPage(
            messages = ConversationTimelineStateReducer.collapseRedundantCommentary(messages),
            nextCursor = result.firstString("nextCursor", "next_cursor"),
            context = threadId?.let { SessionContextProjection.fromConversationPage(it, result) },
        )
    }

    private fun activitySummary(activity: ConversationActivity): String = buildString {
        append(activity.title)
        activity.command?.let { append("\n").append(it) }
        activity.cwd?.let { append("\n").append(it) }
        activity.outputPreview?.let { append("\n").append(it) }
    }

    private fun reasoningText(item: JsonObject): String {
        fun latestText(key: String): String? = (item[key] as? JsonArray).orEmpty()
            .mapNotNull { value ->
                (value as? JsonPrimitive)?.contentOrNull
                    ?: (value as? JsonObject)?.firstString("text", "content", "summary")
            }
            .map(String::trim)
            .lastOrNull(String::isNotEmpty)
        return latestText("summary") ?: latestText("content").orEmpty()
    }

    private fun commandPresentationKind(actions: List<JsonObject>): ConversationCommandPresentationKind =
        if (actions.isNotEmpty() && actions.all { action ->
                normalizeAction(action.firstString("type", "kind")) in setOf("read", "listfiles", "search")
            }
        ) {
            ConversationCommandPresentationKind.Exploration
        } else {
            ConversationCommandPresentationKind.Execution
        }

    private fun commandActionTitle(actions: List<JsonObject>): String? {
        for (action in actions) {
            val type = normalizeAction(action.firstString("type", "kind"))
            val path = action.firstString("path", "file", "filePath", "file_path", "relativePath", "relative_path")
            val query = action.string("query")
            when (type) {
                "read" -> return path?.let { "Read ${shortPath(it)}" } ?: "Read file"
                "listfiles" -> return path?.let { "List ${shortPath(it)}" } ?: "List files"
                "search" -> return query?.let { "Search $it" } ?: path?.let { "Search ${shortPath(it)}" } ?: "Search"
            }
        }
        return null
    }

    private fun normalizeAction(value: String?): String = value.orEmpty()
        .lowercase()
        .filter(Char::isLetterOrDigit)

    private fun shortPath(path: String): String {
        val normalized = path.replace('\\', '/').trimEnd('/')
        val parts = normalized.split('/').filter(String::isNotEmpty)
        return parts.takeLast(2).joinToString("/").ifEmpty { path }
    }

    private fun compactCommand(command: String): String {
        val line = command.lineSequence().firstOrNull().orEmpty().trim()
        return if (line.length <= 42) line else "${line.take(39)}…"
    }

    private fun toolIdentifier(item: JsonObject, type: String): String? = when (type) {
        "mcpToolCall" -> listOfNotNull(item.string("server"), item.firstString("tool", "toolName", "name")).joinToString("/").ifBlank { null }
        "dynamicToolCall" -> item.firstString("tool", "toolName", "name")
        "collabAgentToolCall" -> item.firstString("tool", "toolName", "name", "receiver")
        "webSearch" -> "web"
        else -> null
    }

    private fun toolTitle(item: JsonObject, type: String, identifier: String?): String = when (type) {
        "webSearch" -> item.string("query")?.let { "Search web for $it" } ?: "Search web"
        "collabAgentToolCall" -> identifier?.let { "Agent tool · $it" } ?: "Agent tool"
        else -> identifier?.let { "Tool call · $it" } ?: "Tool call"
    }

    private fun turnLifecycle(turn: JsonObject): ConversationTurnLifecycle {
        val status = turn.firstString("status", "state")
            ?: (turn["status"] as? JsonObject)?.firstString("type", "status")
        return when (status?.lowercase()?.replace("_", "")?.replace("-", "")) {
            "active", "running", "inprogress", "waitingforapproval", "waitingforinput" -> ConversationTurnLifecycle.Running
            "completed", "complete", "succeeded", "success" -> ConversationTurnLifecycle.Completed
            "failed", "failure", "systemerror", "error" -> ConversationTurnLifecycle.Failed
            "interrupted", "cancelled", "canceled", "aborted" -> ConversationTurnLifecycle.Interrupted
            else -> ConversationTurnLifecycle.Unknown
        }
    }

    private const val ACTIVITY_OUTPUT_PREVIEW_LIMIT = 16_000

    private fun conversationAttachment(part: JsonObject): ConversationAttachment? = when (part.string("type")) {
        "image" -> part.string("url")?.takeIf(String::isNotBlank)?.let { url ->
            ConversationAttachment(
                kind = ConversationAttachmentKind.Image,
                url = url,
                detail = part.string("detail"),
            )
        }
        "localImage", "local_image" -> part.string("path")?.takeIf(String::isNotBlank)?.let { path ->
            ConversationAttachment(
                kind = ConversationAttachmentKind.LocalImage,
                name = path.substringAfterLast('/').substringAfterLast('\\'),
                path = path,
                detail = part.string("detail"),
            )
        }
        "mention" -> {
            val name = part.string("name")?.takeIf(String::isNotBlank)
            val path = part.string("path")?.takeIf(String::isNotBlank)
            if (name == null || path == null) null
            else ConversationAttachment(ConversationAttachmentKind.Mention, name = name, path = path)
        }
        "skill" -> {
            val name = part.string("name")?.takeIf(String::isNotBlank)
            val path = part.string("path")?.takeIf(String::isNotBlank)
            if (name == null || path == null) null
            else ConversationAttachment(ConversationAttachmentKind.Skill, name = name, path = path)
        }
        else -> null
    }

    private fun thread(item: JsonObject, fallbackCwd: String, fallbackRuntimeProvider: String): AgentThread? {
        val id = item.string("id") ?: return null
        val runtimeProvider = RuntimeRoutingPolicy.normalize(
            item.firstString("runtimeProvider", "runtime_provider", "source") ?: fallbackRuntimeProvider,
        )
        return AgentThread(
            id = id,
            preview = item.string("name") ?: item.string("preview") ?: "Untitled session",
            cwd = item.string("cwd") ?: fallbackCwd,
            createdAtEpochSeconds = item.long("createdAt") ?: item.long("created_at"),
            updatedAtEpochSeconds = item.long("updatedAt") ?: item.long("updated_at"),
            runtimeProvider = runtimeProvider,
            context = SessionContextProjection.fromThread(item, fallbackCwd, runtimeProvider),
        )
    }

    private fun isApproval(event: AppServerEvent): Boolean =
        event.method.contains("approval", true) ||
            (event.method == "mcpServer/elicitation/request" && event.params.string("mode") == "url")

    private fun question(element: JsonElement): UserInputQuestion? {
        val item = element as? JsonObject ?: return null
        val id = item.string("id")?.trim()?.takeIf(String::isNotEmpty) ?: return null
        return UserInputQuestion(
            id = id,
            header = item.string("header").orEmpty(),
            question = item.string("question").orEmpty(),
            isOther = item.bool("isOther") ?: item.bool("is_other") ?: false,
            isSecret = item.bool("isSecret") ?: item.bool("is_secret") ?: false,
            options = (item["options"] as? JsonArray).orEmpty().mapNotNull { optionElement ->
                val option = optionElement as? JsonObject ?: return@mapNotNull null
                option.string("label")?.trim()?.takeIf(String::isNotEmpty)?.let { UserInputOption(it, option.string("description")) }
            },
            multiSelect = item.bool("multiSelect") ?: item.bool("multi_select") ?: false,
        )
    }

    private fun mcpQuestions(params: JsonObject): List<UserInputQuestion> {
        val properties = ((params["requestedSchema"] as? JsonObject)?.get("properties") as? JsonObject).orEmpty()
        val questions = properties.keys.sorted().mapNotNull { id ->
            val schema = properties[id] as? JsonObject ?: return@mapNotNull null
            val type = schema.string("type")
            val rawOptions = when {
                type == "boolean" -> listOf("true", "false")
                schema["enum"] is JsonArray -> schema.arrayStrings("enum")
                else -> emptyList()
            }
            UserInputQuestion(
                id = id,
                header = schema.string("title") ?: id,
                question = schema.string("description") ?: "Please provide $id",
                isOther = rawOptions.isEmpty() || type == "array",
                isSecret = false,
                options = rawOptions.map { UserInputOption(it, null) },
                multiSelect = type == "array",
            )
        }
        return questions.ifEmpty {
            listOf(UserInputQuestion("response", params.string("serverName") ?: "MCP", params.string("message") ?: "Additional information", true, false, emptyList(), false))
        }
    }

    private fun mcpResponse(request: UserInputRequest, answers: Map<String, List<String>>): JsonObject {
        if (answers.isEmpty()) return buildJsonObject {
            put("action", JsonPrimitive("decline")); put("content", JsonNull); put("_meta", JsonNull)
        }
        val properties = ((request.params["requestedSchema"] as? JsonObject)?.get("properties") as? JsonObject).orEmpty()
        val content = buildJsonObject {
            answers.forEach { (id, values) ->
                val first = values.firstOrNull() ?: return@forEach
                val schema = properties[id] as? JsonObject
                val value: JsonElement = when (schema?.string("type")) {
                    "array" -> buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }
                    "boolean" -> JsonPrimitive(first.lowercase() in setOf("true", "1", "yes", "是", "允许"))
                    "integer" -> first.toLongOrNull()?.let(::JsonPrimitive) ?: JsonPrimitive(first)
                    "number" -> first.toDoubleOrNull()?.let(::JsonPrimitive) ?: JsonPrimitive(first)
                    else -> JsonPrimitive(first)
                }
                put(id, value)
            }
        }
        return buildJsonObject {
            put("action", JsonPrimitive(if (content.isEmpty()) "decline" else "accept"))
            put("content", if (content.isEmpty()) JsonNull else content)
            put("_meta", JsonNull)
        }
    }

    private fun persistentPermissionRules(params: JsonObject): List<String> {
        val suggestions = (params["permissionSuggestions"] ?: params["permission_suggestions"]) as? JsonArray ?: return emptyList()
        val seen = mutableSetOf<String>()
        return suggestions.mapNotNull { it as? JsonObject }.filter { suggestion ->
            suggestion.string("type").equals("addRules", true) &&
                suggestion.string("behavior").equals("allow", true) &&
                suggestion.string("destination").equals("localSettings", true)
        }.flatMap { suggestion ->
            (suggestion["rules"] as? JsonArray).orEmpty().mapNotNull { ruleValue ->
                val value = when (ruleValue) {
                    is JsonPrimitive -> ruleValue.contentOrNull?.trim()
                    is JsonObject -> {
                        val tool = ruleValue.firstString("toolName", "tool_name")?.trim()?.takeIf(String::isNotEmpty)
                            ?: return@mapNotNull null
                        val content = ruleValue.firstString("ruleContent", "rule_content")?.trim()?.takeIf(String::isNotEmpty)
                        if (content == null) tool else "$tool($content)"
                    }
                    else -> null
                }
                value?.takeIf { it.isNotEmpty() && it.length <= 1_024 && seen.add(it) }
            }
        }.take(50)
    }

    private fun approvalImpactCount(params: JsonObject): Int? {
        val explicit = params.firstLong(
            "count",
            "itemCount",
            "item_count",
            "affectedCount",
            "affected_count",
        )?.takeIf { it in 0..Int.MAX_VALUE }?.toInt()
        if (explicit != null) return explicit
        return listOf("items", "paths", "changes", "files").firstNotNullOfOrNull { key ->
            (params[key] as? JsonArray)?.size
        }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
private fun JsonObject.firstString(vararg keys: String): String? = keys.firstNotNullOfOrNull(::string)
private fun JsonObject?.firstDouble(vararg keys: String): Double? = this?.let { objectValue ->
    keys.firstNotNullOfOrNull { key -> (objectValue[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull() }
}
private fun JsonObject?.firstLong(vararg keys: String): Long? = this?.let { objectValue ->
    keys.firstNotNullOfOrNull { key -> (objectValue[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull() }
}
private fun JsonObject.arrayStrings(key: String): List<String> =
    (this[key] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
private fun JsonObject.commandSummary(): String? = when (val value = this["command"]) {
    is JsonPrimitive -> value.contentOrNull
    is JsonArray -> value.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.joinToString(" ").ifBlank { null }
    else -> null
}
private fun JsonElement.idText(): String = (this as? JsonPrimitive)?.contentOrNull ?: toString()
