package com.gaixianggeng.mimi.core.storage

import android.content.Context
import android.util.AtomicFile
import com.gaixianggeng.mimi.core.model.QueuedTurn
import com.gaixianggeng.mimi.core.model.QueuedTurnState
import com.gaixianggeng.mimi.core.model.QueuedTurnPolicy
import com.gaixianggeng.mimi.core.model.ImageAttachment
import com.gaixianggeng.mimi.core.model.QueuedSkill
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Profile-scoped durable queue. Prompt contents live in no-backup storage and never enter preferences. */
class QueuedTurnStore(context: Context, private val json: Json) {
    private val file = File(context.noBackupFilesDir, "queued_turns_v1.json")
    private val atomicFile = AtomicFile(file)
    private val mutex = Mutex()
    private val serializer = ListSerializer(QueuedTurn.serializer())

    suspend fun load(profileId: String, threadId: String): List<QueuedTurn> = withStore {
        readAll().filter { it.profileId == profileId && it.threadId == threadId }
    }

    suspend fun recoverInterruptedDispatches(profileId: String) = mutate { items ->
        QueuedTurnPolicy.recoverInterruptedDispatches(items, profileId)
    }

    suspend fun enqueue(turn: QueuedTurn) = mutate { items ->
        QueuedTurnPolicy.enqueue(items, turn)
    }

    suspend fun updatePayload(
        id: String,
        text: String,
        images: List<ImageAttachment>,
        skills: List<QueuedSkill>,
    ) = mutate { items ->
        items.map {
            if (it.id == id && it.state != QueuedTurnState.Dispatching) {
                val normalizedText = text.trim()
                it.copy(
                    text = normalizedText,
                    images = images,
                    skills = skills,
                    goalObjective = normalizedText.takeIf { _ -> it.goalObjective != null },
                    lastError = null,
                )
            } else {
                it
            }
        }
    }

    suspend fun updateState(id: String, state: QueuedTurnState) = mutate { items ->
        items.map { if (it.id == id) it.copy(state = state, lastError = null) else it }
    }

    suspend fun markNeedsConfirmation(id: String, error: String?) = mutate { items ->
        items.map {
            if (it.id == id) it.copy(state = QueuedTurnState.NeedsConfirmation, lastError = error?.take(500)) else it
        }
    }

    suspend fun remove(id: String) = mutate { items -> items.filterNot { it.id == id } }

    suspend fun reorder(profileId: String, threadId: String, orderedIds: List<String>) = mutate { items ->
        QueuedTurnPolicy.reorder(items, profileId, threadId, orderedIds)
    }

    private suspend fun mutate(block: (List<QueuedTurn>) -> List<QueuedTurn>) = withStore {
        writeAll(block(readAll()))
    }

    private suspend fun <T> withStore(block: () -> T): T = mutex.withLock {
        withContext(Dispatchers.IO) { block() }
    }

    private fun readAll(): List<QueuedTurn> {
        if (!file.isFile) return emptyList()
        return atomicFile.openRead().bufferedReader(Charsets.UTF_8).use { json.decodeFromString(serializer, it.readText()) }
    }

    private fun writeAll(items: List<QueuedTurn>) {
        val encoded = json.encodeToString(serializer, items)
        check(encoded.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "Queued message storage is full" }
        val stream = atomicFile.startWrite()
        try {
            stream.write(encoded.toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(stream)
        } catch (failure: Throwable) {
            atomicFile.failWrite(stream)
            throw failure
        }
    }

    private companion object {
        const val MAX_BYTES = 64 * 1_048_576
    }
}
