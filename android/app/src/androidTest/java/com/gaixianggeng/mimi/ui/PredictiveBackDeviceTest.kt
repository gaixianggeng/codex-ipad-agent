package com.gaixianggeng.mimi.ui

import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.espresso.Espresso
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class PredictiveBackDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun completedSystemBackInvokesSessionNavigationAndResetsProgress() {
        var backInvocations = 0
        val progressValues = mutableListOf<Pair<Float, Int>>()
        compose.setContent {
            SessionPredictiveBackHandler(
                enabled = true,
                onProgress = { progress, swipeEdge -> progressValues += progress to swipeEdge },
                onBack = { backInvocations += 1 },
            )
            Text("Session detail")
        }

        compose.onNodeWithText("Session detail").assertExists()
        Espresso.pressBack()
        compose.waitForIdle()

        compose.runOnIdle {
            assertEquals(1, backInvocations)
            assertTrue(progressValues.isNotEmpty())
            assertEquals(0f, progressValues.last().first)
        }
    }

    @Test
    fun disabledHandlerDoesNotClaimSystemBack() {
        var backInvocations = 0
        compose.setContent {
            SessionPredictiveBackHandler(
                enabled = false,
                onProgress = { _, _ -> },
                onBack = { backInvocations += 1 },
            )
            Text("Session list")
        }

        compose.runOnIdle { assertEquals(0, backInvocations) }
    }
}
