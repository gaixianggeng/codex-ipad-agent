package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class MarkdownHistoryMediaDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun localizedPlaceholderLoadsTheReferencedHistoryMedia() {
        val selected = mutableStateOf<String?>(null)
        val label = InstrumentationRegistry.getInstrumentation()
            .targetContext
            .getString(R.string.history_media_load)

        compose.setContent {
            MaterialTheme {
                MarkdownMessageContent(
                    text = "![](agentd-history-media://media-123)",
                    onHistoryMedia = { selected.value = it },
                )
            }
        }

        compose.onNodeWithText(label).assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals("media-123", selected.value) }
    }
}
