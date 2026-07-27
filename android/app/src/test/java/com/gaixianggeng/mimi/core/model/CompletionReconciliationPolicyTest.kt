package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionReconciliationPolicyTest {
    @Test
    fun completedAssistantAvoidsReloadButUnansweredUserRequiresAuthoritativeSnapshot() {
        val user = ConversationMessage("user", ConversationRole.User, "queued")
        val completed = ConversationMessage(
            id = "assistant",
            role = ConversationRole.Assistant,
            text = "done",
            turnId = "turn-1",
            itemCompleted = true,
            turnLifecycle = ConversationTurnLifecycle.Completed,
        )

        assertFalse(
            CompletionReconciliationPolicy.needsAuthoritativeSnapshot(
                listOf(user, completed),
                "turn-1",
            ),
        )
        assertTrue(
            CompletionReconciliationPolicy.needsAuthoritativeSnapshot(
                listOf(completed, user),
                "turn-2",
            ),
        )
        assertTrue(
            CompletionReconciliationPolicy.needsAuthoritativeSnapshot(
                listOf(
                    completed,
                    user,
                    ConversationMessage(
                        id = "activity",
                        role = ConversationRole.Activity,
                        text = "Run command",
                        turnId = "turn-2",
                        itemCompleted = true,
                    ),
                ),
                "turn-2",
            ),
        )
        assertFalse(
            CompletionReconciliationPolicy.needsAuthoritativeSnapshot(
                listOf(
                    user,
                    ConversationMessage(
                        id = "activity",
                        role = ConversationRole.Activity,
                        text = "Run command",
                        turnId = "turn-2",
                        itemCompleted = true,
                    ),
                    ConversationMessage(
                        id = "assistant-2",
                        role = ConversationRole.Assistant,
                        text = "done",
                    ),
                ),
                "turn-2",
            ),
        )
    }
}
