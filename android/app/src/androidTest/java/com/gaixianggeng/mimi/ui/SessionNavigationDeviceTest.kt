package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SessionNavigationDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun compactConversationHeaderReturnsToSessionList() {
        var returned = false
        compose.setContent {
            MaterialTheme {
                PaneHeader(
                    title = "Test session",
                    subtitle = "Live Codex workspace",
                    onBack = { returned = true },
                )
            }
        }

        compose.onNodeWithTag("back_to_session_list")
            .assertIsDisplayed()
            .performClick()
        compose.runOnIdle { assertTrue(returned) }
    }
}
