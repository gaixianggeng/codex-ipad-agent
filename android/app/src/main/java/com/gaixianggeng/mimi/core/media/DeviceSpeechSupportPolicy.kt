package com.gaixianggeng.mimi.core.media

import java.util.Locale

enum class DeviceSpeechSupportDecision {
    Ready,
    DownloadPending,
    DownloadRequired,
    Unsupported,
}

data class DeviceSpeechSupportSelection(
    val decision: DeviceSpeechSupportDecision,
    val languageTag: String,
)

object DeviceSpeechSupportPolicy {
    fun assess(
        requestedLanguageTag: String,
        installedLanguageTags: List<String>,
        pendingLanguageTags: List<String>,
        supportedLanguageTags: List<String>,
    ): DeviceSpeechSupportDecision = select(
        requestedLanguageTag,
        installedLanguageTags,
        pendingLanguageTags,
        supportedLanguageTags,
    ).decision

    fun select(
        requestedLanguageTag: String,
        installedLanguageTags: List<String>,
        pendingLanguageTags: List<String>,
        supportedLanguageTags: List<String>,
    ): DeviceSpeechSupportSelection {
        val normalizedRequestedTag = requestedLanguageTag.replace('_', '-')
        val requested = Locale.forLanguageTag(normalizedRequestedTag)
        require(requested.language.isNotBlank())
        val installed = installedLanguageTags.firstOrNull { matches(requested, it) }
        val pending = pendingLanguageTags.firstOrNull { matches(requested, it) }
        val supported = supportedLanguageTags.firstOrNull { matches(requested, it) }
        return when {
            installed != null -> DeviceSpeechSupportSelection(
                DeviceSpeechSupportDecision.Ready,
                installed.takeUnless { it == "*" } ?: normalizedRequestedTag,
            )
            pending != null -> DeviceSpeechSupportSelection(
                DeviceSpeechSupportDecision.DownloadPending,
                pending.takeUnless { it == "*" } ?: normalizedRequestedTag,
            )
            supported != null -> DeviceSpeechSupportSelection(
                DeviceSpeechSupportDecision.DownloadRequired,
                supported.takeUnless { it == "*" } ?: normalizedRequestedTag,
            )
            else -> DeviceSpeechSupportSelection(DeviceSpeechSupportDecision.Unsupported, normalizedRequestedTag)
        }
    }

    private fun matches(requested: Locale, candidateTag: String): Boolean {
        if (candidateTag == "*") return true
        val candidate = Locale.forLanguageTag(candidateTag.replace('_', '-'))
        if (candidate.language.isBlank() || candidate.language != requested.language) return false
        return requested.country.isBlank() ||
            candidate.country.isBlank() ||
            candidate.country == requested.country
    }
}

enum class DeviceSpeechFailure {
    Audio,
    Permission,
    ModelUnavailable,
    ModelDownloadScheduled,
    UnsupportedLanguage,
    NoMatch,
    Busy,
    NoSpeech,
    Generic,
}

class DeviceSpeechException(
    val reason: DeviceSpeechFailure,
    val recognitionErrorCode: Int? = null,
) : IllegalStateException(reason.name)
