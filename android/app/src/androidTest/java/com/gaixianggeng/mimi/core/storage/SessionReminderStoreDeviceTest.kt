package com.gaixianggeng.mimi.core.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.gaixianggeng.mimi.core.model.SessionReminder
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionReminderStoreDeviceTest {
    @Test
    fun remindersAreProfileScopedReplaceableAndConsumable() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = SessionReminderStore(context, Json { ignoreUnknownKeys = true })
        val suffix = System.nanoTime().toString()
        val profile = "reminder-profile-$suffix"
        val now = System.currentTimeMillis()
        val first = SessionReminder(profile, "project", "thread", "First title", now + 60_000, now)
        val replacement = first.copy(title = "Updated title", fireAtEpochMillis = now + 120_000)

        store.upsert(first)
        store.upsert(replacement)

        assertEquals(listOf(replacement), store.load(profile, now))
        assertNull(store.consume(profile, "wrong-project", "thread"))
        assertEquals(replacement, store.consume(profile, "project", "thread"))
        assertNull(store.consume(profile, "project", "thread"))
    }
}
