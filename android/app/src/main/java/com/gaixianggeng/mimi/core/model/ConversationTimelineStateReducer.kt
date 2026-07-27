package com.gaixianggeng.mimi.core.model

/**
 * Keeps the first visible slot for a process item and applies later lifecycle updates in place.
 * Completed items are authoritative: delayed start/progress/output frames cannot reopen them.
 */
object ConversationTimelineStateReducer {
    /**
     * Reconciles an authoritative history page with events that may have arrived while the page
     * was loading. Snapshot order wins for known items; live-only items keep their relative order
     * after the snapshot instead of being discarded.
     */
    fun mergeSnapshot(
        current: List<ConversationMessage>,
        snapshot: List<ConversationMessage>,
    ): List<ConversationMessage> {
        if (snapshot.isEmpty()) return current
        if (current.isEmpty()) return deduplicate(snapshot)

        val consumedCurrent = mutableSetOf<Int>()
        val result = mutableListOf<ConversationMessage>()
        deduplicate(snapshot).forEach { incoming ->
            val currentIndex = current.indices.firstOrNull { index ->
                index !in consumedCurrent && sameStableItem(current[index], incoming)
            }
            if (currentIndex == null) {
                result += incoming
            } else {
                consumedCurrent += currentIndex
                result += mergeMessage(current[currentIndex], incoming)
            }
        }
        current.indices
            .filterNot(consumedCurrent::contains)
            .forEach { result += current[it] }
        return result
    }

    /**
     * Adds an older history page without changing the established order of the visible page.
     */
    fun prependSnapshot(
        current: List<ConversationMessage>,
        older: List<ConversationMessage>,
    ): List<ConversationMessage> {
        if (older.isEmpty()) return current
        val consumedCurrent = mutableSetOf<Int>()
        val prefix = mutableListOf<ConversationMessage>()
        deduplicate(older).forEach { incoming ->
            val currentIndex = current.indices.firstOrNull { index ->
                index !in consumedCurrent && sameStableItem(current[index], incoming)
            }
            if (currentIndex == null) {
                prefix += incoming
            } else {
                consumedCurrent += currentIndex
                prefix += mergeMessage(current[currentIndex], incoming)
            }
        }
        return prefix + current.indices.filterNot(consumedCurrent::contains).map(current::get)
    }

    fun upsert(
        messages: List<ConversationMessage>,
        incoming: ConversationMessage,
    ): List<ConversationMessage> {
        val index = messages.indexOfLast { sameStableItem(it, incoming) }
        if (index < 0) return messages + incoming

        val existing = messages[index]
        val merged = mergeMessage(existing, incoming)
        if (merged === existing) return messages
        return messages.toMutableList().also { result ->
            result[index] = merged
        }
    }

    fun appendAssistantText(
        messages: List<ConversationMessage>,
        itemId: String,
        turnId: String?,
        delta: String,
        role: ConversationRole = ConversationRole.Assistant,
    ): List<ConversationMessage> {
        if (delta.isEmpty()) return messages
        val index = messages.indexOfLast { it.id == itemId || it.itemId == itemId }
        val previous = messages.getOrNull(index)
        if (previous?.itemCompleted == true || previous?.turnLifecycle?.isTerminal == true) return messages
        val message = ConversationMessage(
            id = previous?.id ?: itemId,
            role = role,
            text = previous?.text.orEmpty() + delta,
            streaming = true,
            attachments = previous?.attachments.orEmpty(),
            turnId = previous?.turnId ?: turnId,
            itemId = previous?.itemId ?: itemId,
            turnLifecycle = ConversationTurnLifecycle.Running,
            itemCompleted = false,
        )
        if (index < 0) return messages + message
        return messages.toMutableList().also { it[index] = message }
    }

    fun completeAssistantMessage(
        messages: List<ConversationMessage>,
        itemId: String,
        turnId: String?,
        text: String,
        role: ConversationRole = ConversationRole.Assistant,
    ): List<ConversationMessage> {
        val exact = messages.lastOrNull { it.id == itemId || it.itemId == itemId }
        val activeCandidates = if (exact == null && turnId != null) {
            messages.filter {
                it.role == role &&
                    it.turnId == turnId &&
                    it.streaming &&
                    !it.itemCompleted
            }
        } else {
            emptyList()
        }
        // Some app-server builds omit itemId from delta frames but include the authoritative ID
        // on item/completed. Reconcile only a single active assistant item in the same turn so a
        // turn containing multiple assistant items never collapses unrelated output.
        val existing = exact ?: activeCandidates.singleOrNull()
        val finalText = text.ifEmpty { existing?.text.orEmpty() }
        if (finalText.isEmpty() && existing == null) return messages
        return collapseRedundantCommentary(upsert(
            messages,
            ConversationMessage(
                id = existing?.id ?: itemId,
                role = role,
                text = finalText,
                streaming = false,
                attachments = existing?.attachments.orEmpty(),
                turnId = existing?.turnId ?: turnId,
                itemId = itemId,
                turnLifecycle = existing?.turnLifecycle ?: ConversationTurnLifecycle.Running,
                itemCompleted = true,
            ),
        ))
    }

    fun collapseRedundantCommentary(messages: List<ConversationMessage>): List<ConversationMessage> {
        val redundantIds = messages.mapIndexedNotNull { index, message ->
            if (message.role != ConversationRole.Commentary) return@mapIndexedNotNull null
            val normalized = message.text.trim()
            if (normalized.isEmpty()) return@mapIndexedNotNull null
            val duplicatedByFinal = messages.drop(index + 1).any {
                it.role == ConversationRole.Assistant &&
                    it.turnId == message.turnId &&
                    it.text.trim() == normalized
            }
            message.id.takeIf { duplicatedByFinal }
        }.toSet()
        return if (redundantIds.isEmpty()) messages else messages.filterNot { it.id in redundantIds }
    }

    fun appendActivityText(
        messages: List<ConversationMessage>,
        itemId: String,
        turnId: String?,
        category: ConversationActivityCategory,
        delta: String,
    ): List<ConversationMessage> {
        if (delta.isEmpty()) return messages
        val previous = messages.lastOrNull { it.id == itemId || it.itemId == itemId }
        if (previous?.itemCompleted == true || previous?.turnLifecycle?.isTerminal == true) return messages
        val nextText = (previous?.activity?.subtitle ?: previous?.text.orEmpty()) + delta
        val activity = (previous?.activity ?: ConversationActivity(
            category = category,
            title = if (category == ConversationActivityCategory.Plan) "Plan" else "Reasoning",
        )).copy(
            category = category,
            subtitle = nextText,
            status = "inProgress",
        )
        return upsert(
            messages,
            ConversationMessage(
                id = previous?.id ?: itemId,
                role = ConversationRole.Activity,
                text = nextText,
                streaming = true,
                turnId = previous?.turnId ?: turnId,
                itemId = previous?.itemId ?: itemId,
                activity = activity,
                turnLifecycle = ConversationTurnLifecycle.Running,
                itemCompleted = false,
            ),
        )
    }

    fun updateToolProgress(
        messages: List<ConversationMessage>,
        itemId: String,
        turnId: String?,
        progress: String,
    ): List<ConversationMessage> {
        val previous = messages.lastOrNull { it.id == itemId || it.itemId == itemId }
        if (previous?.itemCompleted == true || previous?.turnLifecycle?.isTerminal == true) return messages
        val activity = (previous?.activity ?: ConversationActivity(
            category = ConversationActivityCategory.ToolCall,
            title = "Tool call",
            toolName = "MCP",
        )).copy(
            subtitle = progress,
            status = "inProgress",
        )
        return upsert(
            messages,
            ConversationMessage(
                id = previous?.id ?: itemId,
                role = ConversationRole.Activity,
                text = listOf(activity.title, progress).joinToString("\n"),
                streaming = true,
                turnId = previous?.turnId ?: turnId,
                itemId = previous?.itemId ?: itemId,
                activity = activity,
                turnLifecycle = ConversationTurnLifecycle.Running,
                itemCompleted = false,
            ),
        )
    }

    fun appendCommandOutput(
        messages: List<ConversationMessage>,
        itemId: String,
        turnId: String?,
        delta: String,
        previewLimit: Int = DEFAULT_OUTPUT_PREVIEW_LIMIT,
    ): List<ConversationMessage> {
        require(previewLimit > 0)
        if (delta.isEmpty()) return messages
        val index = messages.indexOfLast { it.id == itemId || it.itemId == itemId }
        val previous = messages.getOrNull(index)
        if (previous?.itemCompleted == true || previous?.turnLifecycle?.isTerminal == true) return messages

        val combined = previous?.activity?.outputPreview.orEmpty() + delta
        val truncated = combined.length > previewLimit
        val output = combined.takeLast(previewLimit)
        val activity = (previous?.activity ?: ConversationActivity(
            category = ConversationActivityCategory.RunCommand,
            title = "Run command",
        )).copy(
            status = "inProgress",
            outputPreview = output,
            outputTruncated = previous?.activity?.outputTruncated == true || truncated,
        )
        val message = ConversationMessage(
            id = previous?.id ?: itemId,
            role = ConversationRole.Activity,
            text = listOfNotNull(activity.title, activity.command, output.takeIf(String::isNotBlank)).joinToString("\n"),
            streaming = true,
            turnId = previous?.turnId ?: turnId,
            itemId = previous?.itemId ?: itemId,
            activity = activity,
            turnLifecycle = ConversationTurnLifecycle.Running,
            itemCompleted = false,
        )
        if (index < 0) return messages + message
        return messages.toMutableList().also { it[index] = message }
    }

    fun completeTurn(
        messages: List<ConversationMessage>,
        turnId: String?,
        lifecycle: ConversationTurnLifecycle,
    ): List<ConversationMessage> {
        require(lifecycle.isTerminal)
        var changed = false
        val result = messages.map { message ->
            val belongsToTurn = if (turnId != null) {
                message.turnId == turnId
            } else {
                message.streaming ||
                    message.activity?.isRunning == true ||
                    message.activity?.isPending == true
            }
            if (!belongsToTurn) return@map message

            val activity = message.activity
            val terminalActivity = if (activity?.isRunning == true || activity?.isPending == true) {
                activity.copy(
                    status = when (lifecycle) {
                        ConversationTurnLifecycle.Failed -> "failed"
                        ConversationTurnLifecycle.Interrupted -> "cancelled"
                        else -> "completed"
                    },
                )
            } else {
                activity
            }
            val next = message.copy(
                streaming = false,
                activity = terminalActivity,
                turnLifecycle = lifecycle,
                itemCompleted = true,
            )
            if (next != message) changed = true
            next
        }
        return if (changed) result else messages
    }

    private fun mergeMessage(
        existing: ConversationMessage,
        incoming: ConversationMessage,
    ): ConversationMessage {
        if ((existing.itemCompleted || existing.turnLifecycle.isTerminal) &&
            !incoming.itemCompleted &&
            !incoming.turnLifecycle.isTerminal
        ) {
            return existing
        }
        val mergedActivity = when {
            incoming.activity != null && existing.activity != null -> incoming.activity.copy(
                subtitle = incoming.activity.subtitle ?: existing.activity.subtitle,
                status = incoming.activity.status ?: existing.activity.status,
                command = incoming.activity.command ?: existing.activity.command,
                cwd = incoming.activity.cwd ?: existing.activity.cwd,
                toolName = incoming.activity.toolName ?: existing.activity.toolName,
                filePaths = incoming.activity.filePaths.ifEmpty { existing.activity.filePaths },
                exitCode = incoming.activity.exitCode ?: existing.activity.exitCode,
                outputPreview = incoming.activity.outputPreview ?: existing.activity.outputPreview,
                outputTruncated = incoming.activity.outputTruncated || existing.activity.outputTruncated,
                commandPresentationKind =
                    incoming.activity.commandPresentationKind ?: existing.activity.commandPresentationKind,
            )
            incoming.activity != null -> incoming.activity
            else -> existing.activity
        }
        val completed = existing.itemCompleted || incoming.itemCompleted
        return incoming.copy(
            id = existing.id,
            text = incoming.text.ifEmpty { existing.text },
            streaming = if (completed) false else incoming.streaming,
            attachments = incoming.attachments.ifEmpty { existing.attachments },
            turnId = incoming.turnId ?: existing.turnId,
            itemId = incoming.itemId ?: existing.itemId,
            activity = mergedActivity,
            turnLifecycle = if (
                existing.turnLifecycle.isTerminal &&
                !incoming.turnLifecycle.isTerminal
            ) {
                existing.turnLifecycle
            } else {
                incoming.turnLifecycle
            },
            itemCompleted = completed,
        )
    }

    private fun deduplicate(messages: List<ConversationMessage>): List<ConversationMessage> {
        val result = mutableListOf<ConversationMessage>()
        messages.forEach { incoming ->
            val index = result.indexOfLast { sameStableItem(it, incoming) }
            if (index < 0) {
                result += incoming
            } else {
                result[index] = mergeMessage(result[index], incoming)
            }
        }
        return result
    }

    private fun sameStableItem(
        left: ConversationMessage,
        right: ConversationMessage,
    ): Boolean {
        if (left.id == right.id) return true
        val leftItemId = left.itemId?.takeIf(String::isNotBlank) ?: return false
        val rightItemId = right.itemId?.takeIf(String::isNotBlank) ?: return false
        return leftItemId == rightItemId && left.turnId == right.turnId
    }

    private val ConversationTurnLifecycle.isTerminal: Boolean
        get() = this == ConversationTurnLifecycle.Completed ||
            this == ConversationTurnLifecycle.Interrupted ||
            this == ConversationTurnLifecycle.Failed

    const val DEFAULT_OUTPUT_PREVIEW_LIMIT = 16_000
}
