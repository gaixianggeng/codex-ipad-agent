package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.ui.theme.MimiTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class GoalLifecycleDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun activeGoalShowsProgressAndOnlyAllowedTransitions() {
        var requestedStatus: ThreadGoalStatus? = null
        var clearRequested = false
        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                GoalLifecycleCard(
                    goal = ThreadGoal(
                        threadId = "thread-1",
                        objective = "Ship Android parity",
                        status = ThreadGoalStatus.Active,
                        tokenBudget = 20_000,
                        tokensUsed = 12_450,
                        timeUsedSeconds = 4_680,
                        updatedAtEpochSeconds = 1_750_000_000,
                    ),
                    loading = false,
                    onEdit = {},
                    onRefresh = {},
                    onTransition = { requestedStatus = it },
                    onClear = { clearRequested = true },
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                )
            }
        }

        compose.onNodeWithTag("goal_progress").assertIsDisplayed()
        compose.onNodeWithTag("goal_action_paused").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(ThreadGoalStatus.Paused, requestedStatus) }
        compose.onNodeWithTag("goal_action_complete").assertIsDisplayed()
        compose.onNodeWithTag("goal_action_blocked").assertIsDisplayed()
        compose.onNodeWithTag("goal_action_active").assertDoesNotExist()
        compose.onNodeWithTag("goal_action_clear").assertIsDisplayed().performClick()
        compose.runOnIdle { assertTrue(clearRequested) }
    }

    @Test
    fun completedGoalCanOnlyBeReactivated() {
        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                GoalLifecycleCard(
                    goal = ThreadGoal(
                        threadId = "thread-1",
                        objective = "Ship Android parity",
                        status = ThreadGoalStatus.Complete,
                    ),
                    loading = false,
                    onEdit = {},
                    onRefresh = {},
                    onTransition = {},
                    onClear = {},
                )
            }
        }

        compose.onNodeWithTag("goal_action_active").assertIsDisplayed()
        compose.onNodeWithTag("goal_action_paused").assertDoesNotExist()
        compose.onNodeWithTag("goal_action_complete").assertDoesNotExist()
        compose.onNodeWithTag("goal_action_blocked").assertDoesNotExist()
    }
}
