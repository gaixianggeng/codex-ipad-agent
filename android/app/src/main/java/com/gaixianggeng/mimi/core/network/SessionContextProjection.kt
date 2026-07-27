package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.SessionContextEnvironment
import com.gaixianggeng.mimi.core.model.SessionContextGitInfo
import com.gaixianggeng.mimi.core.model.SessionContextSnapshot
import com.gaixianggeng.mimi.core.model.SessionContextSource
import com.gaixianggeng.mimi.core.model.SessionContextStatus
import com.gaixianggeng.mimi.core.model.SessionContextSubagent
import com.gaixianggeng.mimi.core.model.SessionContextTask
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.time.Instant

object SessionContextProjection {
    fun fromThread(
        thread: JsonObject,
        fallbackCwd: String,
        runtimeProvider: String,
    ): SessionContextSnapshot? {
        val threadId = thread.string("id")?.takeIf(String::isNotBlank) ?: return null
        val cwd = thread.string("cwd")?.takeIf(String::isNotBlank) ?: fallbackCwd
        val status = contextStatus(thread["status"])
        val git = gitInfo(thread["gitInfo"] as? JsonObject ?: thread["git_info"] as? JsonObject)
        return SessionContextSnapshot(
            threadId = threadId,
            status = status,
            environment = SessionContextEnvironment(
                id = "local",
                kind = "local",
                label = "Local",
                cwd = cwd,
                provider = thread.firstString("modelProvider", "model_provider")
                    ?: if (runtimeProvider == "claude") "anthropic" else "openai",
                runtimeProvider = runtimeProvider,
            ),
            git = git,
            tasks = tasksFromTurns(thread["turns"] as? JsonArray),
            sources = sources(thread, cwd),
            subagents = subagents(thread, status?.type),
            updatedAtEpochSeconds = thread.firstLong("updatedAt", "updated_at"),
        )
    }

    fun fromConversationPage(
        threadId: String,
        result: JsonObject,
    ): SessionContextSnapshot {
        val turns = result["data"] as? JsonArray
        val newestTurn = turns.orEmpty().firstNotNullOfOrNull { it as? JsonObject }
        return SessionContextSnapshot(
            threadId = threadId,
            status = newestTurn?.get("status")?.let(::contextStatus),
            tasks = tasksFromTurns(turns),
            subagents = subagentsFromTurns(threadId, turns),
            updatedAtEpochSeconds = Instant.now().epochSecond,
        )
    }

    fun fromItem(
        threadId: String,
        turnId: String?,
        item: JsonObject,
        statusOverride: String? = null,
    ): SessionContextSnapshot? {
        val task = task(item, turnId, statusOverride)
        val subagent = subagent(threadId, item, statusOverride)
        if (task == null && subagent == null) return null
        return SessionContextSnapshot(
            threadId = threadId,
            status = SessionContextStatus("active"),
            tasks = listOfNotNull(task),
            subagents = listOfNotNull(subagent),
            updatedAtEpochSeconds = Instant.now().epochSecond,
        )
    }

    fun statusUpdate(threadId: String, status: String): SessionContextSnapshot =
        SessionContextSnapshot(
            threadId = threadId,
            status = statusValue(status),
            updatedAtEpochSeconds = Instant.now().epochSecond,
        )

    private fun contextStatus(value: JsonElement?): SessionContextStatus? {
        val raw = (value as? JsonPrimitive)?.contentOrNull
        if (!raw.isNullOrBlank()) return statusValue(raw)
        val objectValue = value as? JsonObject ?: return null
        val type = objectValue.string("type")?.takeIf(String::isNotBlank) ?: "notLoaded"
        val activeFlags = ((objectValue["activeFlags"] ?: objectValue["active_flags"]) as? JsonArray)
            .orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        val projected = statusValue(type)
        return projected.copy(activeFlags = (activeFlags + projected.activeFlags).distinct())
    }

    private fun statusValue(raw: String): SessionContextStatus {
        val normalizedRaw = raw.trim()
        val activeFlags = when (normalizedRaw.lowercase().replace("-", "_")) {
            "waiting_for_approval", "waitingonapproval" -> listOf("waitingOnApproval")
            "waiting_for_input", "waitingonuserinput", "waitingforinput" -> listOf("waitingOnUserInput")
            else -> emptyList()
        }
        return SessionContextStatus(
            type = normalizeStatus(normalizedRaw),
            activeFlags = activeFlags,
            rawType = normalizedRaw,
        )
    }

    private fun normalizeStatus(status: String): String = when (status.trim().lowercase()) {
        "running", "waiting_for_approval", "waiting_for_input", "inprogress", "in_progress" -> "active"
        "failed", "failure", "error" -> "systemError"
        "closed", "idle", "completed", "complete", "success", "succeeded" -> "idle"
        "history", "notloaded", "not_loaded" -> "notLoaded"
        else -> status.ifBlank { "notLoaded" }
    }

    private fun gitInfo(objectValue: JsonObject?): SessionContextGitInfo? {
        objectValue ?: return null
        val value = SessionContextGitInfo(
            sha = objectValue.string("sha"),
            branch = objectValue.string("branch"),
            originUrl = objectValue.firstString("originUrl", "origin_url"),
        )
        return value.takeIf { listOf(it.sha, it.branch, it.originUrl).any { field -> !field.isNullOrBlank() } }
    }

    private fun sources(thread: JsonObject, cwd: String): List<SessionContextSource> {
        val values = mutableListOf<SessionContextSource>()
        sourceLabel(thread["source"])?.let {
            values += SessionContextSource("session_source", "session", it)
        }
        thread.firstString("threadSource", "thread_source")?.takeIf(String::isNotBlank)?.let {
            values += SessionContextSource("thread_source", "thread", it)
        }
        thread.firstString("forkedFromId", "forked_from_id")?.takeIf(String::isNotBlank)?.let {
            values += SessionContextSource("forked_from", "fork", it.take(32))
        }
        if (values.isEmpty() && cwd.isNotBlank()) {
            val projectName = cwd.trimEnd('/', '\\').substringAfterLast('/').substringAfterLast('\\')
            values += SessionContextSource("project", "project", projectName.ifBlank { cwd }, cwd)
        }
        return values
    }

    private fun sourceLabel(value: JsonElement?): String? {
        (value as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)?.let { return it }
        val objectValue = value as? JsonObject ?: return null
        objectValue.string("custom")?.takeIf(String::isNotBlank)?.let { return it }
        return objectValue.firstString("subAgent", "sub_agent")
            ?.takeIf(String::isNotBlank)
            ?.let { "subAgent $it" }
    }

    private fun tasksFromTurns(turns: JsonArray?): List<SessionContextTask> {
        val tasks = mutableListOf<SessionContextTask>()
        val seen = mutableSetOf<String>()
        for (turnElement in turns.orEmpty()) {
            val turn = turnElement as? JsonObject ?: continue
            val turnId = turn.string("id")
            val turnStatus = turn.string("status")
            val items = (turn["items"] as? JsonArray).orEmpty()
            for (itemElement in items.asReversed()) {
                val item = itemElement as? JsonObject ?: continue
                val task = task(item, turnId, item.string("status") ?: turnStatus) ?: continue
                if (seen.add(task.id)) tasks += task
                if (tasks.size >= 8) return tasks
            }
        }
        return tasks
    }

    private fun task(
        item: JsonObject,
        turnId: String?,
        statusOverride: String?,
    ): SessionContextTask? {
        val type = item.string("type") ?: return null
        val id = item.string("id") ?: turnId ?: "$type-${item.hashCode()}"
        val status = statusOverride ?: item.string("status")
        return when (type) {
            "commandExecution" -> {
                val command = commandText(item["command"])
                SessionContextTask(
                    id = id,
                    kind = "command",
                    title = command?.take(80) ?: "Command execution",
                    subtitle = item.string("cwd") ?: commandActionSummary(item["commandActions"] as? JsonArray),
                    status = status,
                )
            }
            "fileChange" -> {
                val changes = (item["changes"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                SessionContextTask(
                    id = id,
                    kind = "file_change",
                    title = if (changes.isEmpty()) "File changes" else "${changes.size} files changed",
                    subtitle = fileChangeSummary(changes),
                    status = status,
                )
            }
            "mcpToolCall" -> SessionContextTask(
                id = id,
                kind = "mcp_tool",
                title = item.firstString("tool", "name") ?: "Tool call",
                subtitle = item.firstString("server", "namespace", "pluginId", "plugin_id"),
                status = status,
            )
            "dynamicToolCall" -> SessionContextTask(
                id = id,
                kind = "dynamic_tool",
                title = item.firstString("tool", "name") ?: "Dynamic tool",
                subtitle = item.firstString("pluginId", "plugin_id", "namespace"),
                status = status,
            )
            "collabAgentToolCall" -> SessionContextTask(
                id = id,
                kind = "subagent",
                title = item.firstString("agentNickname", "agent_nickname", "nickname", "tool") ?: "Subagent",
                subtitle = item.firstString("agentRole", "agent_role", "role"),
                status = status,
            )
            "webSearch" -> SessionContextTask(
                id = id,
                kind = "web_search",
                title = item.firstString("query", "action")?.let { "Web search: ${it.take(80)}" } ?: "Web search",
                status = status,
            )
            else -> null
        }
    }

    private fun subagents(
        thread: JsonObject,
        status: String?,
    ): List<SessionContextSubagent> {
        val values = mutableListOf<SessionContextSubagent>()
        val threadId = thread.string("id").orEmpty()
        thread.firstString("parentThreadId", "parent_thread_id")?.takeIf(String::isNotBlank)?.let { parent ->
            values += SessionContextSubagent(
                id = threadId.ifBlank { "subagent-${thread.hashCode()}" },
                parentThreadId = parent,
                nickname = thread.firstString("agentNickname", "agent_nickname"),
                role = thread.firstString("agentRole", "agent_role"),
                status = status,
            )
        }
        values += subagentsFromTurns(threadId, thread["turns"] as? JsonArray)
        return values.distinctBy { it.id }.take(8)
    }

    private fun subagentsFromTurns(
        threadId: String,
        turns: JsonArray?,
    ): List<SessionContextSubagent> {
        val values = mutableListOf<SessionContextSubagent>()
        for (turnElement in turns.orEmpty()) {
            val turn = turnElement as? JsonObject ?: continue
            val turnStatus = turn.string("status")
            for (itemElement in (turn["items"] as? JsonArray).orEmpty().asReversed()) {
                val item = itemElement as? JsonObject ?: continue
                subagent(threadId, item, item.string("status") ?: turnStatus)?.let(values::add)
                if (values.size >= 8) return values.distinctBy { it.id }
            }
        }
        return values.distinctBy { it.id }
    }

    private fun subagent(
        parentThreadId: String,
        item: JsonObject,
        status: String?,
    ): SessionContextSubagent? {
        if (item.string("type") != "collabAgentToolCall") return null
        val id = item.firstString(
            "childThreadId",
            "child_thread_id",
            "agentThreadId",
            "agent_thread_id",
            "subagentThreadId",
            "subagent_thread_id",
            "threadId",
            "thread_id",
            "id",
        ) ?: "subagent-${item.hashCode()}"
        return SessionContextSubagent(
            id = id,
            parentThreadId = parentThreadId,
            nickname = item.firstString("agentNickname", "agent_nickname", "nickname", "tool"),
            role = item.firstString("agentRole", "agent_role", "role"),
            status = status,
        )
    }

    private fun commandText(value: JsonElement?): String? = when (value) {
        is JsonPrimitive -> value.contentOrNull
        is JsonArray -> value.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.joinToString(" ").ifBlank { null }
        else -> null
    }

    private fun commandActionSummary(actions: JsonArray?): String? =
        actions.orEmpty().mapNotNull { it as? JsonObject }.firstNotNullOfOrNull {
            it.firstString("name", "path", "query")
        }

    private fun fileChangeSummary(changes: List<JsonObject>): String? {
        if (changes.isEmpty()) return null
        val parts = changes.take(3).mapNotNull { it.firstString("path", "kind") }.toMutableList()
        if (changes.size > parts.size) parts += "+${changes.size - parts.size}"
        return parts.joinToString(" · ").ifBlank { null }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.firstString(vararg keys: String): String? = keys.firstNotNullOfOrNull(::string)
private fun JsonObject.firstLong(vararg keys: String): Long? =
    keys.firstNotNullOfOrNull { key -> string(key)?.toLongOrNull() }
