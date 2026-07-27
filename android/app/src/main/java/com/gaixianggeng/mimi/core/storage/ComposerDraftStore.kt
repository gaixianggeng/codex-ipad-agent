package com.gaixianggeng.mimi.core.storage

import android.content.Context
import android.util.AtomicFile
import com.gaixianggeng.mimi.core.model.ComposerDraft
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

class ComposerDraftStore(context: Context, private val json: Json) {
    private val file = File(context.noBackupFilesDir, "composer_drafts_v1.json")
    private val atomicFile = AtomicFile(file)
    private val mutex = Mutex()
    private val serializer = ListSerializer(ComposerDraft.serializer())

    suspend fun load(profileId: String, threadId: String): ComposerDraft? = locked {
        readAll().firstOrNull { it.profileId == profileId && it.threadId == threadId }
    }

    suspend fun save(draft: ComposerDraft) = locked {
        val current = readAll().filterNot { it.profileId == draft.profileId && it.threadId == draft.threadId }
        val next = if (draft.text.isBlank() && draft.images.isEmpty() && draft.skills.isEmpty()) current
        else (current + draft).sortedByDescending { it.updatedAtEpochMillis }.take(MAX_DRAFTS)
        writeAll(next)
    }

    suspend fun remove(profileId: String, threadId: String) = locked {
        writeAll(readAll().filterNot { it.profileId == profileId && it.threadId == threadId })
    }

    private suspend fun <T> locked(block: () -> T): T = mutex.withLock { withContext(Dispatchers.IO) { block() } }

    private fun readAll(): List<ComposerDraft> {
        if (!file.isFile) return emptyList()
        return atomicFile.openRead().bufferedReader(Charsets.UTF_8).use { json.decodeFromString(serializer, it.readText()) }
    }

    private fun writeAll(items: List<ComposerDraft>) {
        val bytes = json.encodeToString(serializer, items).toByteArray(Charsets.UTF_8)
        check(bytes.size <= MAX_BYTES) { "Composer draft storage is full" }
        val stream = atomicFile.startWrite()
        try {
            stream.write(bytes)
            atomicFile.finishWrite(stream)
        } catch (failure: Throwable) {
            atomicFile.failWrite(stream)
            throw failure
        }
    }

    private companion object {
        const val MAX_DRAFTS = 64
        const val MAX_BYTES = 64 * 1_048_576
    }
}
