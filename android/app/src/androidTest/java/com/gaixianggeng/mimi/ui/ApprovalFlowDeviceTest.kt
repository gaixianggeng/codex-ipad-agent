package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.gaixianggeng.mimi.core.model.ApprovalRequest
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ApprovalFlowDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun missingContextKeepsDenyAvailableAndBlocksApproval() {
        var decision: String? = null
        render(request(title = "运行命令", body = null), onDecision = { decision = it })

        compose.onNodeWithTag("approval_card").assertIsDisplayed()
        compose.onNodeWithTag("approval_missing_context").assertIsDisplayed()
        compose.onNodeWithTag("approval_deny").assertIsEnabled().performClick()
        compose.onNodeWithTag("approval_allow_once").assertIsNotEnabled()
        compose.runOnIdle { assertEquals("decline", decision) }
    }

    @Test
    fun persistentRulesRequireSecondConfirmation() {
        var decision: String? = null
        val rule = "Bash(./gradlew testDebugUnitTest)"
        render(
            request(
                body = "./gradlew testDebugUnitTest",
                count = 3,
                decisions = listOf("accept", "acceptWithPermissionUpdate"),
                rules = listOf(rule),
            ),
            onDecision = { decision = it },
        )

        compose.onNodeWithTag("approval_impact").assertIsDisplayed()
        compose.onNodeWithTag("approval_details_body", useUnmergedTree = true).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("approval_always_allow").performScrollTo().assertIsEnabled().performClick()
        compose.onNodeWithTag("persistent_permission_confirmation").assertIsDisplayed()
        compose.onNodeWithText(rule).assertIsDisplayed()
        compose.runOnIdle { assertEquals(null, decision) }
        compose.onNodeWithTag("persistent_permission_confirm").performClick()
        compose.runOnIdle { assertEquals("acceptWithPermissionUpdate", decision) }
    }

    @Test
    fun sendingDecisionKeepsCardVisibleAndLocksActions() {
        render(
            request(
                body = "git status",
                decisions = listOf("accept", "acceptForSession"),
            ),
            submitting = true,
        )

        compose.onNodeWithTag("approval_card").assertIsDisplayed()
        compose.onNodeWithTag("approval_submitting").assertIsDisplayed()
        compose.onNodeWithTag("approval_deny").assertIsNotEnabled()
        compose.onNodeWithTag("approval_allow_session").assertIsNotEnabled()
        compose.onNodeWithTag("approval_allow_once").assertIsNotEnabled()
    }

    private fun render(
        request: ApprovalRequest,
        submitting: Boolean = false,
        onDecision: (String) -> Unit = {},
    ) {
        compose.setContent {
            MaterialTheme {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    ApprovalCard(
                        request = request,
                        submitting = submitting,
                        onDecision = onDecision,
                    )
                }
            }
        }
    }

    private fun request(
        title: String = "Agent requests to run: ./gradlew testDebugUnitTest",
        body: String? = "./gradlew testDebugUnitTest",
        count: Int? = null,
        decisions: List<String> = emptyList(),
        rules: List<String> = emptyList(),
    ) = ApprovalRequest(
        requestId = JsonPrimitive(1),
        method = "item/commandExecution/requestApproval",
        params = buildJsonObject {},
        id = "approval-1",
        threadId = "thread-1",
        title = title,
        body = body,
        kind = "command",
        risk = "high",
        availableDecisions = decisions,
        persistentPermissionRules = rules,
        count = count,
    )
}
