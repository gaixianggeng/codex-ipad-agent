package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class ModelSelectionPolicyTest {
    @Test
    fun advertisedAccountDefaultWinsWhenNoModelWasSelected() {
        val options = listOf(
            ModelOption("account-default", "Account default", isDefault = true),
            ModelOption("other", "Other"),
        )

        assertEquals(
            "account-default",
            ModelSelectionPolicy.resolve(null, options, "codex").id,
        )
    }

    @Test
    fun explicitAdvertisedSelectionIsPreserved() {
        val options = listOf(
            ModelOption("account-default", "Account default", isDefault = true),
            ModelOption("chosen", "Chosen"),
        )

        assertEquals(
            "chosen",
            ModelSelectionPolicy.resolve("chosen", options, "codex").id,
        )
    }

    @Test
    fun unavailableCatalogUsesRuntimeSpecificSafeFallback() {
        assertEquals(
            "gpt-5.5",
            ModelSelectionPolicy.resolve(null, emptyList(), "codex").id,
        )
        assertEquals(
            "sonnet",
            ModelSelectionPolicy.resolve(null, emptyList(), "claude").id,
        )
    }
}
