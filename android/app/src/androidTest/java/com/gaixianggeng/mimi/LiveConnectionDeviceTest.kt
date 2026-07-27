package com.gaixianggeng.mimi

import android.os.Build
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

class LiveConnectionDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun liveAgentConnectsFromConnectionScreen() {
        val arguments = InstrumentationRegistry.getArguments()
        val endpoint = arguments.getString("liveEndpoint").orEmpty()
        val token = arguments.getString("liveToken").orEmpty()
        assumeTrue("Live endpoint and token are required", endpoint.isNotBlank() && token.isNotBlank())
        if (Build.VERSION.SDK_INT >= 37) {
            InstrumentationRegistry.getInstrumentation().uiAutomation
                .executeShellCommand(
                    "pm grant ${InstrumentationRegistry.getInstrumentation().targetContext.packageName} " +
                        "android.permission.ACCESS_LOCAL_NETWORK",
                )
                .close()
        }

        compose.onNodeWithTag("connection_endpoint").performTextReplacement(endpoint)
        compose.onNodeWithTag("connection_token").performTextReplacement(token)
        compose.onNodeWithTag("connection_submit").performClick()

        val errorMatcher =
            hasText("Connection failed", substring = true) or
                hasText("Connection did not become ready", substring = true)
        compose.waitUntil(timeoutMillis = 52_000) {
            runCatching {
                compose.onAllNodesWithTag("connection_screen").fetchSemanticsNodes().isEmpty() ||
                    compose.onAllNodes(errorMatcher).fetchSemanticsNodes().isNotEmpty()
            }.getOrDefault(false)
        }
        val errors = compose.onAllNodes(errorMatcher).fetchSemanticsNodes()
        if (errors.isNotEmpty()) {
            val errorText = errors
                .flatMap { node ->
                    node.config.getOrNull(SemanticsProperties.Text).orEmpty()
                }
                .joinToString(" ") { text -> text.text }
            throw AssertionError("Live connection error: ${errorText.ifBlank { "unknown error" }}")
        }
        compose.onNodeWithTag("connection_screen").assertDoesNotExist()
    }
}
