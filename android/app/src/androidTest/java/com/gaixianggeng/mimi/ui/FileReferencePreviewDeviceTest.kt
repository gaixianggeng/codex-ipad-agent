package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.gaixianggeng.mimi.core.model.ConversationFileReference
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class FileReferencePreviewDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    private val references = listOf(
        ConversationFileReference("/tmp/report.pdf", "report.pdf"),
        ConversationFileReference("/tmp/result.json", "result.json"),
    )

    @Test
    fun exposesDetectedFilesAsPreviewActions() {
        val selected = mutableStateOf<String?>(null)
        compose.setContent {
            MaterialTheme {
                FileReferencePreviewStrip(
                    references = references,
                    loading = false,
                    onPreview = { selected.value = it },
                )
            }
        }

        compose.onNodeWithTag("file_reference_/tmp/report.pdf").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals("/tmp/report.pdf", selected.value) }
    }

    @Test
    fun locksAllPreviewActionsWhileAFileLoads() {
        compose.setContent {
            MaterialTheme {
                FileReferencePreviewStrip(
                    references = references,
                    loading = true,
                    onPreview = {},
                )
            }
        }

        compose.onNodeWithTag("file_reference_/tmp/report.pdf").assertIsNotEnabled()
        compose.onNodeWithTag("file_reference_/tmp/result.json").assertIsNotEnabled()
    }
}
