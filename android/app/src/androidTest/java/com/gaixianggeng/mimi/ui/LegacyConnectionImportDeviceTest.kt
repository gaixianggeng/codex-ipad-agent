package com.gaixianggeng.mimi.ui

import android.net.Uri
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class LegacyConnectionImportDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun dialogRequiresExplicitImportAndNeverDisplaysTheLongTermToken() {
        var imported = false
        var dismissed = false
        val link = Uri.parse(
            "mimiremote://connect?endpoint=http%3A%2F%2F192.168.31.163%3A8787&token=do-not-display",
        )
        compose.setContent {
            MaterialTheme {
                LegacyConnectionImportDialog(
                    link = link,
                    onImport = { imported = true },
                    onDismiss = { dismissed = true },
                )
            }
        }

        compose.onNodeWithTag("legacy_connection_import_dialog").assertIsDisplayed()
        compose.onNodeWithTag("legacy_connection_endpoint").assertIsDisplayed()
        compose.onAllNodesWithText("do-not-display").assertCountEquals(0)
        compose.onNodeWithTag("legacy_connection_import").performClick()
        compose.onNodeWithTag("legacy_connection_cancel").performClick()
        compose.runOnIdle {
            assertTrue(imported)
            assertTrue(dismissed)
        }
    }
}
