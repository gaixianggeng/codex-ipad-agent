package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownRichContentDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun rendersPlanWrapperAndLocalizedCodeAction() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            MaterialTheme {
                MarkdownMessageContent(
                    """
                    <proposed_plan>
                    ## Ship it

                    > Keep the quote

                    - Parent
                      - Nested item

                    ```kotlin
                    val ready = true
                    ```
                    </proposed_plan>
                    """.trimIndent(),
                )
            }
        }

        compose.onNodeWithText(context.getString(R.string.plan_label)).assertIsDisplayed()
        compose.onNodeWithText("Ship it").assertIsDisplayed()
        compose.onNodeWithText("Keep the quote").assertIsDisplayed()
        compose.onNodeWithText("Nested item").assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.copy_code)).assertIsDisplayed()
    }

    @Test
    fun localMarkdownImageOpensAuthenticatedFilePreview() {
        val selected = mutableStateOf<String?>(null)
        compose.setContent {
            MaterialTheme {
                MarkdownMessageContent(
                    text = """![architecture](file:///Users/me/diagram.png "Current plan")""",
                    onLocalFile = { selected.value = it },
                )
            }
        }

        compose.onNodeWithText("architecture").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals("/Users/me/diagram.png", selected.value) }
    }
}
