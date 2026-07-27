package com.gaixianggeng.mimi.core.notifications

import android.net.Uri

/**
 * Local notifications carry routing metadata only. Versioning and bounded identifiers mirror
 * the iOS route contract so malformed or future payloads cannot be used to construct requests.
 */
@ConsistentCopyVisibility
data class SessionNotificationRoute private constructor(
    val version: Int,
    val profileId: String,
    val projectId: String,
    val threadId: String,
) {
    fun toUri(): Uri = Uri.Builder()
        .scheme(SCHEME)
        .authority(AUTHORITY)
        .appendQueryParameter(KEY_VERSION, version.toString())
        .appendQueryParameter(KEY_PROFILE_ID, profileId)
        .appendQueryParameter(KEY_PROJECT_ID, projectId)
        .appendQueryParameter(KEY_THREAD_ID, threadId)
        .build()

    companion object {
        const val CURRENT_VERSION = 1
        private const val MAX_IDENTIFIER_LENGTH = 512
        private const val SCHEME = "mimiremote"
        private const val AUTHORITY = "open"
        private const val KEY_VERSION = "version"
        private const val KEY_PROFILE_ID = "profile_id"
        private const val KEY_PROJECT_ID = "project_id"
        private const val KEY_THREAD_ID = "thread_id"

        fun current(profileId: String, projectId: String, threadId: String): SessionNotificationRoute? {
            return create(CURRENT_VERSION, profileId, projectId, threadId)
        }

        fun parse(uri: Uri): SessionNotificationRoute? {
            if (!uri.scheme.equals(SCHEME, ignoreCase = true) || !uri.authority.equals(AUTHORITY, ignoreCase = true)) {
                return null
            }
            val version = uri.getQueryParameter(KEY_VERSION)?.toIntOrNull()
                ?.takeIf { it == CURRENT_VERSION } ?: return null
            return create(
                version = version,
                profileId = uri.getQueryParameter(KEY_PROFILE_ID).orEmpty(),
                projectId = uri.getQueryParameter(KEY_PROJECT_ID).orEmpty(),
                threadId = uri.getQueryParameter(KEY_THREAD_ID).orEmpty(),
            )
        }

        private fun create(
            version: Int,
            profileId: String,
            projectId: String,
            threadId: String,
        ): SessionNotificationRoute? {
            val normalizedProfileId = normalizeIdentifier(profileId) ?: return null
            val normalizedProjectId = normalizeIdentifier(projectId) ?: return null
            val normalizedThreadId = normalizeIdentifier(threadId) ?: return null
            return SessionNotificationRoute(
                version = version,
                profileId = normalizedProfileId,
                projectId = normalizedProjectId,
                threadId = normalizedThreadId,
            )
        }

        private fun normalizeIdentifier(value: String): String? {
            return value.trim().takeIf { it.isNotEmpty() && it.length <= MAX_IDENTIFIER_LENGTH }
        }
    }
}
