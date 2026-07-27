package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import com.gaixianggeng.mimi.core.model.UserInputOption
import com.gaixianggeng.mimi.core.model.UserInputQuestion
import com.gaixianggeng.mimi.core.model.UserInputRequest
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class UserInputFlowDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun longFormKeepsActionsVisibleAndRequiresEveryQuestion() {
        val request = request()
        var submitted: Map<String, List<String>>? = null
        compose.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    UserInputCard(
                        request = request,
                        submitting = false,
                        onSubmit = { submitted = it },
                    )
                }
            }
        }

        compose.onNodeWithTag("user-input-submit").assertExists().assertIsNotEnabled()
        compose.onNodeWithTag("user-input-option-scope-option-4").performScrollTo().performClick()
        compose.onNodeWithTag("user-input-submit").assertIsNotEnabled()
        compose.onNodeWithTag("user-input-question-list")
            .performScrollToNode(hasTestTag("user-input-freeform-notes"))
        compose.onNodeWithTag("user-input-freeform-notes").performTextInput("Keep the tests")
        compose.onNodeWithTag("user-input-submit").assertIsEnabled().performClick()

        compose.runOnIdle {
            assertEquals(
                mapOf(
                    "scope" to listOf("option-4"),
                    "notes" to listOf("Keep the tests"),
                ),
                submitted,
            )
        }
    }

    @Test
    fun dismissAndResumePreservesDraftSelection() {
        val request = request()
        compose.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    UserInputCard(
                        request = request,
                        submitting = false,
                        onSubmit = {},
                    )
                }
            }
        }

        compose.onNodeWithTag("user-input-option-scope-option-1").performClick()
        compose.onNodeWithTag("user-input-close").performClick()
        compose.onNodeWithTag("user-input-resume").assertExists().performClick()
        compose.onNodeWithTag("user-input-option-scope-option-1").assertIsOn()
        compose.onNodeWithTag("user-input-submit").assertIsNotEnabled()
    }

    private fun request() = UserInputRequest(
        requestId = JsonPrimitive(42),
        method = "item/tool/requestUserInput",
        params = buildJsonObject {},
        id = "request-long-form",
        threadId = "thread-1",
        turnId = "turn-1",
        questions = listOf(
            UserInputQuestion(
                id = "scope",
                header = "Question 1",
                question = "Select every optimization to continue",
                isOther = false,
                isSecret = false,
                options = (1..8).map { index ->
                    UserInputOption("option-$index", "Supporting description $index")
                },
                multiSelect = true,
            ),
            UserInputQuestion(
                id = "notes",
                header = "Question 2",
                question = "Anything else to add?",
                isOther = true,
                isSecret = false,
                options = emptyList(),
                multiSelect = false,
            ),
        ),
    )
}
