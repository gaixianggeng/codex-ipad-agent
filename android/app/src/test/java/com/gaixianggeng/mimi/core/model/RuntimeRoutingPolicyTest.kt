package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeRoutingPolicyTest {
    @Test
    fun claudeIsCapabilityGatedAndCodexIsAlwaysAvailable() {
        val unavailable = AppServerChannel(
            id = "claude",
            runtimeId = "claude_code",
            title = "Claude Code",
            provider = "anthropic",
            gatewayAvailable = false,
        )
        val unrelated = unavailable.copy(
            id = "local",
            runtimeId = "custom",
            provider = "custom",
            gatewayAvailable = true,
        )
        val available = unavailable.copy(gatewayAvailable = true)

        assertEquals(listOf("codex"), RuntimeRoutingPolicy.availableProviders(emptyList()))
        assertEquals(listOf("codex"), RuntimeRoutingPolicy.availableProviders(listOf(unavailable, unrelated)))
        assertEquals(listOf("codex", "claude"), RuntimeRoutingPolicy.availableProviders(listOf(available)))
    }

    @Test
    fun runtimeAliasesNormalizeToStableWireProviders() {
        listOf(
            "claude",
            "Anthropic",
            "claude_code",
            "claude-code",
            "claude_code_bridge",
            "claude-code-bridge",
        ).forEach { assertEquals("claude", RuntimeRoutingPolicy.normalize(it)) }
        assertEquals("codex", RuntimeRoutingPolicy.normalize("openai"))
        assertEquals("codex", RuntimeRoutingPolicy.normalize(null))
    }
}
