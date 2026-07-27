package com.gaixianggeng.mimi.core.storage

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PinnedThreadStoreDeviceTest {
    @Test
    fun pinsAreProfileScopedPersistentAndRemovable() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = PinnedThreadStore(context)
        val suffix = System.nanoTime().toString()
        val firstProfile = "profile-a-$suffix"
        val secondProfile = "profile-b-$suffix"

        store.setPinned(firstProfile, "thread-1", true)
        store.setPinned(firstProfile, "thread-2", true)
        store.setPinned(secondProfile, "thread-1", true)

        assertEquals(setOf("thread-1", "thread-2"), store.threadIds(firstProfile))
        assertEquals(setOf("thread-1"), store.threadIds(secondProfile))

        store.setPinned(firstProfile, "thread-1", false)
        assertEquals(setOf("thread-2"), store.threadIds(firstProfile))
        store.removeProfile(firstProfile)
        assertTrue(store.threadIds(firstProfile).isEmpty())
        assertEquals(setOf("thread-1"), store.threadIds(secondProfile))
        store.removeProfile(secondProfile)
    }

    @Test
    fun storageIdsCannotEscapeTheirProfileScope() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = PinnedThreadStore(context)

        val invalidProfile = runCatching { store.setPinned("profile\u001fescaped", "thread-1", true) }
        val invalidThread = runCatching { store.setPinned("profile-1", " thread-1 ", true) }
        val oversized = runCatching { store.setPinned("profile-1", "x".repeat(513), true) }

        assertTrue(invalidProfile.exceptionOrNull() is IllegalArgumentException)
        assertTrue(invalidThread.exceptionOrNull() is IllegalArgumentException)
        assertTrue(oversized.exceptionOrNull() is IllegalArgumentException)
    }
}
