package com.gaixianggeng.mimi.core.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class DeviceSpeechSupportPolicyTest {
    @Test
    fun scriptVariantMatchesInstalledLanguageAndRegion() {
        val selection = DeviceSpeechSupportPolicy.select(
            requestedLanguageTag = "zh-Hans-CN",
            installedLanguageTags = listOf("zh-CN"),
            pendingLanguageTags = emptyList(),
            supportedLanguageTags = emptyList(),
        )
        assertEquals(DeviceSpeechSupportDecision.Ready, selection.decision)
        assertEquals("zh-CN", selection.languageTag)
    }

    @Test
    fun genericAppLocaleUsesTheConcreteInstalledModelTag() {
        val selection = DeviceSpeechSupportPolicy.select(
            requestedLanguageTag = "en",
            installedLanguageTags = listOf("en-US"),
            pendingLanguageTags = emptyList(),
            supportedLanguageTags = emptyList(),
        )
        assertEquals(DeviceSpeechSupportDecision.Ready, selection.decision)
        assertEquals("en-US", selection.languageTag)
    }

    @Test
    fun pendingAndDownloadableModelsRemainDistinct() {
        assertEquals(
            DeviceSpeechSupportDecision.DownloadPending,
            DeviceSpeechSupportPolicy.assess("en-US", emptyList(), listOf("en-US"), listOf("en-US")),
        )
        assertEquals(
            DeviceSpeechSupportDecision.DownloadRequired,
            DeviceSpeechSupportPolicy.assess("en-US", emptyList(), emptyList(), listOf("en")),
        )
    }

    @Test
    fun unrelatedRegionAndLanguageAreUnsupported() {
        assertEquals(
            DeviceSpeechSupportDecision.Unsupported,
            DeviceSpeechSupportPolicy.assess("en-US", listOf("zh-CN"), emptyList(), listOf("en-GB")),
        )
    }

    @Test
    fun wildcardSupportAndInvalidRequestedLanguageAreHandled() {
        assertEquals(
            DeviceSpeechSupportDecision.DownloadRequired,
            DeviceSpeechSupportPolicy.assess("fr-FR", emptyList(), emptyList(), listOf("*")),
        )
        assertThrows(IllegalArgumentException::class.java) {
            DeviceSpeechSupportPolicy.assess("", emptyList(), emptyList(), emptyList())
        }
    }
}
