package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.Serializable

@Serializable
data class ImageAttachment(
    val id: String,
    val dataUrl: String,
    val encodedByteCount: Int,
    val pixelWidth: Int,
    val pixelHeight: Int,
)

@Serializable
data class ComposerDraft(
    val profileId: String,
    val threadId: String,
    val text: String,
    val images: List<ImageAttachment> = emptyList(),
    val updatedAtEpochMillis: Long,
    val skills: List<QueuedSkill> = emptyList(),
)
