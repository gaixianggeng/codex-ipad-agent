package com.gaixianggeng.mimi.core.storage

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first

private val Context.pinnedThreadDataStore by preferencesDataStore("pinned_threads")

class PinnedThreadStore(private val context: Context) {
    suspend fun threadIds(profileId: String): Set<String> {
        validId(profileId, "Profile")
        val prefix = "$profileId$SEPARATOR"
        return context.pinnedThreadDataStore.data.first()[PINNED_KEYS].orEmpty()
            .mapNotNullTo(mutableSetOf()) { value -> value.takeIf { it.startsWith(prefix) }?.removePrefix(prefix)?.takeIf(String::isNotEmpty) }
    }

    suspend fun setPinned(profileId: String, threadId: String, pinned: Boolean) {
        validId(profileId, "Profile")
        validId(threadId, "Thread")
        context.pinnedThreadDataStore.edit { preferences ->
            val item = key(profileId, threadId)
            val next = preferences[PINNED_KEYS].orEmpty().toMutableSet()
            if (pinned) next += item else next -= item
            preferences[PINNED_KEYS] = next
        }
    }

    suspend fun removeProfile(profileId: String) {
        validId(profileId, "Profile")
        context.pinnedThreadDataStore.edit { preferences ->
            preferences[PINNED_KEYS] = preferences[PINNED_KEYS].orEmpty()
                .filterNotTo(mutableSetOf()) { it.startsWith("$profileId$SEPARATOR") }
        }
    }

    private fun key(profileId: String, threadId: String) = "$profileId$SEPARATOR$threadId"

    private fun validId(value: String, label: String) {
        require(value == value.trim() && value.length in 1..512 && SEPARATOR !in value) {
            "$label id is invalid"
        }
    }

    private companion object {
        const val SEPARATOR = "\u001f"
        val PINNED_KEYS = stringSetPreferencesKey("pinned_thread_keys_v1")
    }
}
