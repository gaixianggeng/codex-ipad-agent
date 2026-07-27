package com.gaixianggeng.mimi.ui

import android.content.Intent
import android.provider.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class PermissionRecoveryDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun recoveryDialogExposesSettingsAndDismissActions() {
        var openedSettings = false
        var dismissed = false
        compose.setContent {
            MaterialTheme {
                PermissionRecoveryDialog(
                    message = "Permission denied",
                    onDismiss = { dismissed = true },
                    onOpenSettings = { openedSettings = true },
                )
            }
        }

        compose.onNodeWithTag("permission_recovery_dialog").assertIsDisplayed()
        compose.onNodeWithTag("permission_recovery_open_settings").assertIsDisplayed().performClick()
        compose.onNodeWithTag("permission_recovery_cancel").assertIsDisplayed().performClick()
        compose.runOnIdle {
            assertTrue(openedSettings)
            assertTrue(dismissed)
        }
    }

    @Test
    fun settingsIntentTargetsOnlyThisApplicationDetailsPage() {
        val intent = appPermissionSettingsIntent("com.gaixianggeng.mimi")

        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, intent.action)
        assertEquals("package", intent.data?.scheme)
        assertEquals("com.gaixianggeng.mimi", intent.data?.schemeSpecificPart)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertEquals(null, intent.component)
    }
}
