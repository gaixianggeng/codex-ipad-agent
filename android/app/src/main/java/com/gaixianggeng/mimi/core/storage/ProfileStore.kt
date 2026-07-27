package com.gaixianggeng.mimi.core.storage

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.gaixianggeng.mimi.core.model.ConnectionProfile
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

private val Context.profileDataStore by preferencesDataStore("connection_profiles")

class ProfileStore(
    private val context: Context,
    private val json: Json,
) {
    val profiles: Flow<List<ConnectionProfile>> = context.profileDataStore.data.map { preferences ->
        preferences[PROFILES]?.let { encoded ->
            runCatching { json.decodeFromString(ListSerializer(ConnectionProfile.serializer()), encoded) }
                .getOrDefault(emptyList())
        } ?: emptyList()
    }

    val activeProfileId: Flow<String?> = context.profileDataStore.data.map { it[ACTIVE_PROFILE_ID] }

    suspend fun upsert(profile: ConnectionProfile) {
        context.profileDataStore.edit { preferences ->
            val current = preferences[PROFILES]?.let { encoded ->
                runCatching { json.decodeFromString(ListSerializer(ConnectionProfile.serializer()), encoded) }
                    .getOrDefault(emptyList())
            } ?: emptyList()
            val next = (current.filterNot { it.id == profile.id } + profile)
                .sortedByDescending { it.lastConnectedAtEpochMillis ?: it.createdAtEpochMillis }
            preferences[PROFILES] = json.encodeToString(ListSerializer(ConnectionProfile.serializer()), next)
        }
    }


    suspend fun setActive(profileId: String?) {
        context.profileDataStore.edit { preferences ->
            if (profileId == null) preferences.remove(ACTIVE_PROFILE_ID)
            else preferences[ACTIVE_PROFILE_ID] = profileId
        }
    }

    suspend fun remove(profileId: String) {
        context.profileDataStore.edit { preferences ->
            val current = preferences[PROFILES]?.let { encoded ->
                runCatching { json.decodeFromString(ListSerializer(ConnectionProfile.serializer()), encoded) }
                    .getOrDefault(emptyList())
            } ?: emptyList()
            preferences[PROFILES] = json.encodeToString(
                ListSerializer(ConnectionProfile.serializer()),
                current.filterNot { it.id == profileId },
            )
            if (preferences[ACTIVE_PROFILE_ID] == profileId) preferences.remove(ACTIVE_PROFILE_ID)
        }
    }

    private companion object {
        val PROFILES = stringPreferencesKey("profiles_json_v1")
        val ACTIVE_PROFILE_ID = stringPreferencesKey("active_profile_id_v1")
    }
}
