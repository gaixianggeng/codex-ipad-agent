package com.gaixianggeng.mimi.core.model

object RuntimeRoutingPolicy {
    const val Codex = "codex"
    const val Claude = "claude"

    fun normalize(value: String?): String = when (value?.trim()?.lowercase()) {
        "claude",
        "anthropic",
        "claude_code",
        "claude-code",
        "claude_code_bridge",
        "claude-code-bridge" -> Claude
        else -> Codex
    }

    fun availableProviders(channels: List<AppServerChannel>): List<String> = buildList {
        add(Codex)
        if (channels.any(::isAvailableClaudeChannel)) add(Claude)
    }

    private fun isAvailableClaudeChannel(channel: AppServerChannel): Boolean =
        channel.gatewayAvailable &&
            listOf(channel.runtimeId, channel.id, channel.provider)
                .filterNotNull()
                .any { normalize(it) == Claude }
}
