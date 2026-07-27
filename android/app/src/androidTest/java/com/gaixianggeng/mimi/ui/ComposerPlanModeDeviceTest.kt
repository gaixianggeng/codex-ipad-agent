package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.gaixianggeng.mimi.core.model.ComposerSendMode
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ComposerPlanModeDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun selectorExposesAndSelectsPlanMode() {
        var mode by mutableStateOf(ComposerSendMode.Standard)

        compose.setContent {
            MaterialTheme {
                ComposerModeControl(
                    mode = mode,
                    onSelect = { mode = it },
                )
            }
        }

        compose.onNodeWithTag("composer_mode_chip").assertIsDisplayed().performClick()
        compose.onNodeWithTag("composer_mode_plan").assertIsDisplayed().performClick()

        compose.runOnIdle {
            assertEquals(ComposerSendMode.Plan, mode)
        }
        compose.onNodeWithTag("composer_mode_chip").assertIsDisplayed()
    }

    @Test
    fun selectorExposesAndSelectsGoalMode() {
        var mode by mutableStateOf(ComposerSendMode.Standard)

        compose.setContent {
            MaterialTheme {
                ComposerModeControl(
                    mode = mode,
                    onSelect = { mode = it },
                )
            }
        }

        compose.onNodeWithTag("composer_mode_chip").performClick()
        compose.onNodeWithTag("composer_mode_goal").assertIsDisplayed().performClick()

        compose.runOnIdle {
            assertEquals(ComposerSendMode.Goal, mode)
        }
    }
}
