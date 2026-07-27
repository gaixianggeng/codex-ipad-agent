package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApprovalDecisionPolicyTest {
    @Test
    fun `body provides verifiable decision context`() {
        assertTrue(ApprovalDecisionPolicy.hasDecisionContext(request(body = "./gradlew test")))
    }

    @Test
    fun `explicit legacy command title provides context but generic title does not`() {
        assertTrue(ApprovalDecisionPolicy.hasDecisionContext(request(title = "Run: ./gradlew test")))
        assertFalse(ApprovalDecisionPolicy.hasDecisionContext(request(title = "Run command")))
        assertFalse(ApprovalDecisionPolicy.hasDecisionContext(request(title = "运行命令")))
    }

    @Test
    fun `deny remains available when approval details are missing`() {
        val missing = request(kind = "file_change")
        assertTrue(ApprovalDecisionPolicy.canSubmitDecision(missing, "decline"))
        assertFalse(ApprovalDecisionPolicy.canSubmitDecision(missing, "accept"))
    }

    @Test
    fun `persistent decision requires exact rules and advertised capability`() {
        val eligible = request(
            body = "git status",
            decisions = listOf("accept", "acceptWithPermissionUpdate"),
            rules = listOf("Bash(git status)"),
        )
        assertTrue(ApprovalDecisionPolicy.canPersistPermission(eligible))
        assertTrue(ApprovalDecisionPolicy.canSubmitDecision(eligible, "acceptWithPermissionUpdate"))
        assertFalse(
            ApprovalDecisionPolicy.canPersistPermission(
                eligible.copy(persistentPermissionRules = emptyList()),
            ),
        )
    }

    private fun request(
        title: String = "Run command",
        body: String? = null,
        kind: String = "command",
        decisions: List<String> = emptyList(),
        rules: List<String> = emptyList(),
    ) = ApprovalRequest(
        requestId = JsonNull,
        method = "item/commandExecution/requestApproval",
        params = buildJsonObject {},
        id = "approval-1",
        threadId = "thread-1",
        title = title,
        body = body,
        kind = kind,
        risk = "high",
        availableDecisions = decisions,
        persistentPermissionRules = rules,
    )
}
