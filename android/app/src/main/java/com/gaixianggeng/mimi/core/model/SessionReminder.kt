package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.Serializable

@Serializable
data class SessionReminder(
    val profileId: String,
    val projectId: String,
    val threadId: String,
    val title: String,
    val fireAtEpochMillis: Long,
    val createdAtEpochMillis: Long,
)
