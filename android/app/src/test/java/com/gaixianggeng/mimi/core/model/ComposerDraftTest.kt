package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposerDraftTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun legacyDraftsDecodeWithNoSkills() {
        val draft = json.decodeFromString<ComposerDraft>(
            """{"profileId":"p","threadId":"t","text":"hello","images":[],"updatedAtEpochMillis":42}""",
        )

        assertTrue(draft.skills.isEmpty())
    }

    @Test
    fun selectedSkillsRoundTripWithTheDraft() {
        val original = ComposerDraft(
            profileId = "p",
            threadId = "t",
            text = "",
            updatedAtEpochMillis = 42,
            skills = listOf(QueuedSkill("review", "/skills/review/SKILL.md")),
        )

        assertEquals(original, json.decodeFromString<ComposerDraft>(json.encodeToString(original)))
    }
}
