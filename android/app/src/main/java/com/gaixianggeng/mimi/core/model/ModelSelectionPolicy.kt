package com.gaixianggeng.mimi.core.model

object ModelSelectionPolicy {
    fun options(
        advertised: List<ModelOption>,
        runtimeProvider: String,
    ): List<ModelOption> = advertised.ifEmpty {
        if (runtimeProvider.equals("claude", ignoreCase = true)) {
            builtInClaudeFallback
        } else {
            builtInCodexFallback
        }
    }

    fun resolve(
        requestedModelId: String?,
        advertised: List<ModelOption>,
        runtimeProvider: String,
    ): ModelOption {
        val candidates = options(advertised, runtimeProvider)
        return candidates.firstOrNull { it.id == requestedModelId?.trim() }
            ?: candidates.firstOrNull(ModelOption::isDefault)
            ?: candidates.first()
    }

    val builtInCodexFallback: List<ModelOption> = listOf(
        ModelOption(
            id = "gpt-5.6-sol",
            title = "GPT-5.6 Sol",
            description = "Detail and polish",
            supportedReasoningEfforts = listOf("medium", "high", "xhigh"),
            defaultReasoningEffort = "medium",
        ),
        ModelOption(
            id = "gpt-5.6-terra",
            title = "GPT-5.6 Terra",
            description = "Everyday workhorse",
            supportedReasoningEfforts = listOf("medium", "high", "xhigh"),
            defaultReasoningEffort = "medium",
        ),
        ModelOption(
            id = "gpt-5.6-luna",
            title = "GPT-5.6 Luna",
            description = "Clear and repeatable",
            supportedReasoningEfforts = listOf("medium", "high", "xhigh"),
            defaultReasoningEffort = "medium",
        ),
        ModelOption(id = "gpt-5.5", title = "GPT-5.5", isDefault = true),
        ModelOption(id = "gpt-5-codex", title = "gpt-5-codex"),
        ModelOption(id = "gpt-5.1-codex", title = "gpt-5.1-codex"),
        ModelOption(id = "gpt-5", title = "gpt-5"),
        ModelOption(id = "gpt-5.1", title = "gpt-5.1"),
    )

    val builtInClaudeFallback: List<ModelOption> = listOf(
        ModelOption(
            id = "claude-fable-5",
            title = "Claude Fable 5",
            provider = "anthropic",
            description = "Anthropic's most capable generally available model.",
            supportedReasoningEfforts = listOf("minimal", "low", "medium", "high"),
            defaultReasoningEffort = "high",
        ),
        ModelOption(id = "sonnet", title = "Claude Sonnet", provider = "anthropic", isDefault = true),
        ModelOption(id = "opus", title = "Claude Opus", provider = "anthropic"),
    )
}
