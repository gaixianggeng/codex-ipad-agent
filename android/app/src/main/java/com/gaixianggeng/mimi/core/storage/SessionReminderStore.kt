package com.gaixianggeng.mimi.core.storage

import android.content.Context
import android.util.AtomicFile
import com.gaixianggeng.mimi.core.model.SessionReminder
import com.gaixianggeng.mimi.core.model.SessionReminderPolicy
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

class SessionReminderStore(context: Context, private val json: Json) {
    private val file = File(context.noBackupFilesDir, "session_reminders_v1.json")
    private val atomicFile = AtomicFile(file)
    private val mutex = Mutex()
    private val serializer = ListSerializer(SessionReminder.serializer())

    suspend fun load(profileId: String, now: Long = System.currentTimeMillis()): List<SessionReminder> = withStore {
        require(SessionReminderPolicy.validId(profileId))
        val all = readAll()
        val active = all.filter { runCatching { SessionReminderPolicy.validate(it, now) }.isSuccess }
        if (active.size != all.size) writeAll(active)
        active.filter { it.profileId == profileId }.sortedBy(SessionReminder::fireAtEpochMillis)
    }

    suspend fun upsert(reminder: SessionReminder) = mutate { items ->
        SessionReminderPolicy.validate(reminder)
        (items.filterNot { it.profileId == reminder.profileId && it.threadId == reminder.threadId } + reminder)
            .sortedBy(SessionReminder::fireAtEpochMillis)
            .take(MAX_REMINDERS)
    }

    suspend fun remove(profileId: String, threadId: String): SessionReminder? = withStore {
        require(SessionReminderPolicy.validId(profileId) && SessionReminderPolicy.validId(threadId))
        val all = readAll()
        val removed = all.firstOrNull { it.profileId == profileId && it.threadId == threadId }
        if (removed != null) writeAll(all - removed)
        removed
    }

    suspend fun consume(profileId: String, projectId: String, threadId: String): SessionReminder? = withStore {
        require(SessionReminderPolicy.validRoute(profileId, projectId, threadId))
        val all = readAll()
        val removed = all.firstOrNull {
            it.profileId == profileId && it.projectId == projectId && it.threadId == threadId
        }
        if (removed != null) writeAll(all - removed)
        removed
    }

    suspend fun removeProfile(profileId: String): List<SessionReminder> = withStore {
        require(SessionReminderPolicy.validId(profileId))
        val all = readAll()
        val removed = all.filter { it.profileId == profileId }
        if (removed.isNotEmpty()) writeAll(all.filterNot { it.profileId == profileId })
        removed
    }

    private suspend fun mutate(block: (List<SessionReminder>) -> List<SessionReminder>) = withStore { writeAll(block(readAll())) }
    private suspend fun <T> withStore(block: () -> T): T = mutex.withLock { withContext(Dispatchers.IO) { block() } }

    private fun readAll(): List<SessionReminder> {
        if (!file.isFile) return emptyList()
        return runCatching { atomicFile.openRead().bufferedReader(Charsets.UTF_8).use { json.decodeFromString(serializer, it.readText()) } }
            .getOrDefault(emptyList())
    }

    private fun writeAll(items: List<SessionReminder>) {
        val bytes = json.encodeToString(serializer, items).toByteArray(Charsets.UTF_8)
        check(bytes.size <= 256 * 1024) { "Reminder storage is full" }
        val stream = atomicFile.startWrite()
        try {
            stream.write(bytes)
            atomicFile.finishWrite(stream)
        } catch (failure: Throwable) {
            atomicFile.failWrite(stream)
            throw failure
        }
    }

    private companion object { const val MAX_REMINDERS = 128 }
}
