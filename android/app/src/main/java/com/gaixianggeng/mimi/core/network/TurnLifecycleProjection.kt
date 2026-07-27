package com.gaixianggeng.mimi.core.network

import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.core.model.SessionContextSnapshot
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class ActiveTurnIdentity(
    val threadId: String,
    val turnId: String,
)

object TurnLifecycleProjection {
    fun startResultTurnId(result: JsonElement?): String? {
        val root = runCatching { result?.jsonObject }.getOrNull() ?: return null
        return root.objectAt("turn")?.string("id")
            ?: root.firstString("turnId", "turn_id")
    }

    fun activeTurnFromEvent(event: AppServerEvent): ActiveTurnIdentity? {
        if (event.method == "turn/completed") return null
        val threadId = event.params.firstString("threadId", "thread_id") ?: return null
        val turnId = event.params.objectAt("turn")?.string("id")
            ?: event.params.firstString("turnId", "turn_id")
            ?: return null
        return ActiveTurnIdentity(threadId, turnId)
    }

    fun activeTurnFromMessages(messages: List<ConversationMessage>): String? =
        messages.asReversed()
            .firstOrNull { it.turnLifecycle == ConversationTurnLifecycle.Running && !it.turnId.isNullOrBlank() }
            ?.turnId

    fun contextIsBusy(context: SessionContextSnapshot?): Boolean {
        val status = context?.status ?: return false
        val values = buildList {
            add(status.type)
            status.rawType?.let(::add)
            addAll(status.activeFlags)
        }
        return values.any { value ->
            value.normalizedStatus() in setOf(
                "active",
                "running",
                "inprogress",
                "waitingforapproval",
                "waitingonapproval",
                "waitingforinput",
                "waitingonuserinput",
            )
        }
    }

    fun isBusy(activeTurnId: String?, awaitingTurnIdentity: Boolean): Boolean =
        !activeTurnId.isNullOrBlank() || awaitingTurnIdentity
}

private fun String.normalizedStatus(): String =
    lowercase().replace("_", "").replace("-", "").replace(" ", "")

private fun JsonObject.objectAt(key: String): JsonObject? =
    this[key]?.let { runCatching { it.jsonObject }.getOrNull() }

private fun JsonObject.string(key: String): String? =
    this[key]?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }?.takeIf(String::isNotBlank)

private fun JsonObject.firstString(vararg keys: String): String? =
    keys.firstNotNullOfOrNull(::string)
