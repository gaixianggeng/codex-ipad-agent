package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.Serializable

@Serializable
enum class QueuedTurnState { Waiting, Dispatching, NeedsConfirmation }

@Serializable
data class QueuedSkill(
    val name: String,
    val path: String,
)

@Serializable
data class QueuedTurn(
    val id: String,
    val profileId: String,
    val threadId: String,
    val cwd: String,
    val text: String,
    val createdAtEpochMillis: Long,
    val model: String? = null,
    val effort: String? = null,
    val skills: List<QueuedSkill> = emptyList(),
    val images: List<ImageAttachment> = emptyList(),
    val permissionMode: String = PermissionMode.FullAccess.wireName,
    val collaborationMode: String = ComposerSendMode.Standard.wireName,
    val goalObjective: String? = null,
    val state: QueuedTurnState = QueuedTurnState.Waiting,
    val lastError: String? = null,
) {
    fun conversationMessage(): ConversationMessage = ConversationMessage(
        id = id,
        role = ConversationRole.User,
        text = text.ifEmpty { "[${images.size} image attachment(s)]" },
        attachments = images.map { image ->
            ConversationAttachment(ConversationAttachmentKind.Image, url = image.dataUrl)
        },
    )
}

object QueuedTurnPolicy {
    const val MAX_PER_THREAD = 20

    fun recoverInterruptedDispatches(items: List<QueuedTurn>, profileId: String): List<QueuedTurn> = items.map {
        if (it.profileId == profileId && it.state == QueuedTurnState.Dispatching) {
            it.copy(
                state = QueuedTurnState.NeedsConfirmation,
                lastError = "Sending was interrupted before the server confirmed it",
            )
        } else {
            it
        }
    }

    fun enqueue(items: List<QueuedTurn>, turn: QueuedTurn): List<QueuedTurn> {
        check(items.count { it.profileId == turn.profileId && it.threadId == turn.threadId } < MAX_PER_THREAD) {
            "Each session can keep at most $MAX_PER_THREAD queued messages"
        }
        return items + turn
    }

    fun nextDispatch(items: List<QueuedTurn>): QueuedTurn? =
        items.firstOrNull()?.takeIf { it.state == QueuedTurnState.Waiting }

    fun reorder(
        items: List<QueuedTurn>,
        profileId: String,
        threadId: String,
        orderedIds: List<String>,
    ): List<QueuedTurn> {
        val queue = items.filter { it.profileId == profileId && it.threadId == threadId }
        check(queue.none { it.state == QueuedTurnState.Dispatching }) {
            "Wait for the current queued message to finish sending before reordering"
        }
        check(orderedIds.size == queue.size && orderedIds.toSet().size == queue.size && orderedIds.toSet() == queue.map { it.id }.toSet()) {
            "Queued message order no longer matches local storage"
        }
        val ordered = orderedIds.map { id -> queue.first { it.id == id } }.iterator()
        return items.map { item ->
            if (item.profileId == profileId && item.threadId == threadId) ordered.next() else item
        }
    }
}
