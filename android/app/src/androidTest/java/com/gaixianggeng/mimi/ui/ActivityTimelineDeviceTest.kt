package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.Modifier
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.ConversationActivity
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationTimelineStateReducer
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.ui.theme.MimiTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ActivityTimelineDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun failedTimelineKeepsSuccessfulStepsAndExposesBoundedOutputActions() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val groupStatus = context.getString(R.string.activity_completed_with_errors)
        val completedStatus = context.getString(R.string.activity_completed)
        val failedStatus = context.getString(R.string.activity_status_failed)
        val expandedState = context.getString(R.string.activity_state_expanded, groupStatus)
        val copyOutput = context.getString(R.string.copy_output)
        val editedFile = context.getString(R.string.activity_file_edited, "client.kt")

        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        ActivityTimelineCard(
                            messages = listOf(
                                ConversationMessage(
                                    id = "edit",
                                    role = ConversationRole.Activity,
                                    text = "Edited client.kt",
                                    turnId = "turn-1",
                                    itemId = "edit",
                                    activity = ConversationActivity(
                                        category = ConversationActivityCategory.EditFile,
                                        title = "Edited client.kt",
                                        status = "completed",
                                        filePaths = listOf("src/network/client.kt"),
                                    ),
                                    turnLifecycle = ConversationTurnLifecycle.Failed,
                                    itemCompleted = true,
                                ),
                                ConversationMessage(
                                    id = "command",
                                    role = ConversationRole.Activity,
                                    text = "Run tests",
                                    turnId = "turn-1",
                                    itemId = "command",
                                    activity = ConversationActivity(
                                        category = ConversationActivityCategory.RunCommand,
                                        title = "Run tests",
                                        status = "failed",
                                        command = "./gradlew test",
                                        cwd = "/workspace",
                                        outputPreview = "BUILD FAILED",
                                        outputTruncated = true,
                                        exitCode = 1,
                                    ),
                                    turnLifecycle = ConversationTurnLifecycle.Failed,
                                    itemCompleted = true,
                                ),
                            ),
                        )
                    }
                }
            }
        }

        compose.onNodeWithText(groupStatus).assertIsDisplayed()
        compose.onNode(hasStateDescription(expandedState)).assertIsDisplayed()
        compose.onNodeWithText(editedFile).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(completedStatus).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(failedStatus).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("BUILD FAILED").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription(copyOutput).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun runningActivityUpdatesItsStableSlotAndRejectsLateOutput() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runningStatus = context.getString(R.string.activity_status_running)
        val completedStatus = context.getString(R.string.activity_completed)
        val messages = mutableStateOf(
            listOf(
                ConversationMessage(
                    id = "command-slot",
                    role = ConversationRole.Activity,
                    text = "Run tests",
                    streaming = true,
                    turnId = "turn-live",
                    itemId = "command-live",
                    activity = ConversationActivity(
                        category = ConversationActivityCategory.RunCommand,
                        title = "Run tests",
                        status = "inProgress",
                        command = "./gradlew test",
                    ),
                    turnLifecycle = ConversationTurnLifecycle.Running,
                ),
            ),
        )

        compose.setContent {
            MimiTheme(themeMode = "light", dynamicColor = false) {
                LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        ActivityTimelineCard(messages.value)
                    }
                }
            }
        }

        compose.onNodeWithText(runningStatus).assertIsDisplayed()
        compose.onNodeWithTag("command_activity_details_toggle").performClick()
        compose.runOnIdle {
            messages.value = ConversationTimelineStateReducer.appendCommandOutput(
                messages = messages.value,
                itemId = "command-live",
                turnId = "turn-live",
                delta = "BUILD SUCCESSFUL",
            )
        }
        compose.onNodeWithText("BUILD SUCCESSFUL").assertIsDisplayed()

        compose.runOnIdle {
            val current = messages.value.single()
            messages.value = ConversationTimelineStateReducer.upsert(
                messages.value,
                current.copy(
                    streaming = false,
                    activity = current.activity?.copy(status = "completed", exitCode = 0),
                    turnLifecycle = ConversationTurnLifecycle.Completed,
                    itemCompleted = true,
                ),
            )
            messages.value = ConversationTimelineStateReducer.appendCommandOutput(
                messages = messages.value,
                itemId = "command-live",
                turnId = "turn-live",
                delta = "\nLATE OUTPUT",
            )
        }

        compose.onAllNodesWithText(completedStatus).assertCountEquals(2)
        compose.onNodeWithText("BUILD SUCCESSFUL").assertIsDisplayed()
        compose.onNodeWithText("LATE OUTPUT").assertDoesNotExist()
        assertEquals("command-slot", messages.value.single().id)
    }
}
