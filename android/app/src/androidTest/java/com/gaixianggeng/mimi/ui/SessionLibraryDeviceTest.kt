package com.gaixianggeng.mimi.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.AgentThread
import com.gaixianggeng.mimi.core.model.SessionLibraryFilter
import com.gaixianggeng.mimi.core.model.SessionReminder
import com.gaixianggeng.mimi.core.model.SessionRowStatus
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.ui.theme.MimiTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SessionLibraryDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun filterBarExposesAllIosParityFiltersAndHandlesSelection() {
        var selected = SessionLibraryFilter.All
        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                SessionLibraryFilterBar(
                    selected = selected,
                    onSelect = { selected = it },
                )
            }
        }

        SessionLibraryFilter.entries.forEach { filter ->
            compose.onNodeWithTag("session_filter_${filter.name}").assertIsDisplayed()
        }
        compose.onNodeWithTag("session_filter_NeedsAttention").performClick()
        compose.runOnIdle { assertEquals(SessionLibraryFilter.NeedsAttention, selected) }
    }

    @Test
    fun attentionRowShowsStatusAndCompactMetadataWithoutColorOnlyMeaning() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                SessionLibraryCard(
                    thread = AgentThread(
                        id = "thread-1",
                        preview = "Review authentication changes",
                        cwd = "/workspace/android/authentication",
                        updatedAtEpochSeconds = 1_750_000_000,
                        runtimeProvider = "claude",
                    ),
                    status = SessionRowStatus.WaitingForApproval,
                    selected = true,
                    pinned = true,
                    reminder = SessionReminder(
                        profileId = "profile",
                        projectId = "project",
                        threadId = "thread-1",
                        title = "Review authentication changes",
                        fireAtEpochMillis = 2_000,
                        createdAtEpochMillis = 1_000,
                    ),
                    goal = ThreadGoal(
                        threadId = "thread-1",
                        objective = "Ship parity",
                        status = ThreadGoalStatus.Active,
                        tokenBudget = 20_000,
                        tokensUsed = 12_450,
                    ),
                    snippet = "The agent needs approval before continuing.",
                    onClick = {},
                )
            }
        }

        compose.onNodeWithTag("session_status_WaitingForApproval", useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("session_row_thread-1").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.Selected, true),
        ).assert(
            SemanticsMatcher.expectValue(
                SemanticsProperties.StateDescription,
                "${context.getString(R.string.session_status_waiting_approval)}, " +
                    context.getString(R.string.session_pinned_state),
            ),
        )
        compose.onNodeWithText(
            context.getString(R.string.session_status_waiting_approval),
            useUnmergedTree = true,
        ).assertIsDisplayed()
        compose.onNodeWithText("Claude", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText(
            context.getString(R.string.session_reminder_badge),
            useUnmergedTree = true,
        ).assertIsDisplayed()
        compose.onNodeWithText(
            context.getString(
                R.string.session_goal_badge,
                context.getString(R.string.session_goal_progress_badge, 12_450, 20_000),
            ),
            useUnmergedTree = true,
        ).assertIsDisplayed()
    }

    @Test
    fun sessionCardOverflowExposesActionsWithoutOpeningConversation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var cardClicked = false
        var renameClicked = false
        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                SessionLibraryCard(
                    thread = AgentThread(
                        id = "thread-actions",
                        preview = "Session with accessible actions",
                        cwd = "/workspace/android",
                    ),
                    status = SessionRowStatus.History,
                    selected = false,
                    pinned = false,
                    reminder = null,
                    goal = null,
                    snippet = null,
                    onClick = { cardClicked = true },
                    onRename = { renameClicked = true },
                )
            }
        }

        compose.onNodeWithTag("session_actions_thread-actions").assertIsDisplayed().performClick()
        compose.onNodeWithText(context.getString(R.string.rename_action)).assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertTrue(renameClicked)
            assertFalse(cardClicked)
        }
    }
}
