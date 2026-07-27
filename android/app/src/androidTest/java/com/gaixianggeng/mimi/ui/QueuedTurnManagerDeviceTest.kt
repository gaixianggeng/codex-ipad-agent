package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.gaixianggeng.mimi.app.MainUiState
import com.gaixianggeng.mimi.core.model.QueuedTurn
import com.gaixianggeng.mimi.core.model.QueuedTurnState
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class QueuedTurnManagerDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun managerShowsEveryStateAndExposesSafeActions() {
        var retryId: String? = null
        var guideId: String? = null
        var move: Pair<String, Int>? = null
        val waiting = turn("waiting", QueuedTurnState.Waiting)
        val confirmation = turn("confirmation", QueuedTurnState.NeedsConfirmation)
            .copy(lastError = "Connection ended before confirmation")
        val dispatching = turn("dispatching", QueuedTurnState.Dispatching)
        compose.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    QueuedTurnManagerContent(
                        state = MainUiState(
                            queuedTurns = listOf(waiting, confirmation, dispatching),
                            activeTurnId = "turn-1",
                            conversationConnected = true,
                        ),
                        onDismiss = {},
                        onEdit = {},
                        onDelete = {},
                        onRetry = { retryId = it },
                        onGuideNow = { guideId = it },
                        onMove = { id, delta -> move = id to delta },
                    )
                }
            }
        }

        compose.onNodeWithTag("queued_turn_waiting").assertIsDisplayed()
        compose.onNodeWithTag("queued_turn_confirmation").assertIsDisplayed()
        compose.onNodeWithTag("queued_turn_dispatching").assertIsDisplayed()
        compose.onNodeWithTag("retry_queued_turn_confirmation").performClick()
        compose.onNodeWithTag("queued_turn_menu_waiting").performClick()
        compose.onNodeWithTag("guide_queued_turn_waiting").performClick()

        compose.runOnIdle {
            assertEquals("confirmation", retryId)
            assertEquals("waiting", guideId)
            assertEquals(null, move)
        }
    }

    private fun turn(id: String, state: QueuedTurnState) = QueuedTurn(
        id = id,
        profileId = "profile-1",
        threadId = "thread-1",
        cwd = "/repo",
        text = "Queued $id",
        createdAtEpochMillis = 1,
        state = state,
    )
}
