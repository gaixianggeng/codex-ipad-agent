package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.R
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class BundledLegalAssetsDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    private val context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun apkContainsProjectLicenseNoticesAndLegalDocuments() {
        val projectLicense = BundledLegalAssets.read(context, BundledLegalAssets.ProjectLicense)
        val notices = BundledLegalAssets.read(context, BundledLegalAssets.ThirdPartyNotices)
        val privacy = BundledLegalAssets.read(context, BundledLegalAssets.PrivacyPolicy)

        assertTrue(projectLicense.contains("GNU GENERAL PUBLIC LICENSE"))
        assertTrue(projectLicense.contains("Google Play distribution channels"))
        assertTrue(notices.contains("commonmark-java 0.29.0"))
        assertTrue(notices.contains("AndroidX / Jetpack Compose"))
        assertTrue(privacy.contains("Mimi Remote 隐私政策 / Privacy Policy"))
        assertTrue(privacy.contains("Android Keystore"))
        assertThrows(IllegalArgumentException::class.java) {
            BundledLegalAssets.read(context, "../token")
        }
    }

    @Test
    fun licenseDialogShowsOfflineNoticesAndExpandableProjectTerms() {
        val projectLicense = BundledLegalAssets.read(context, BundledLegalAssets.ProjectLicense)
        val notices = BundledLegalAssets.read(context, BundledLegalAssets.ThirdPartyNotices)

        compose.setContent {
            MaterialTheme {
                OpenSourceLicensesDialog(
                    projectLicense = projectLicense,
                    notices = notices,
                    onDismiss = {},
                    onViewOnline = {},
                )
            }
        }

        compose.onNodeWithTag("open_source_licenses_dialog").assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.third_party_notices)).assertIsDisplayed()
        compose.onNodeWithText("commonmark-java 0.29.0", substring = true).assertIsDisplayed()
        compose.onNodeWithTag("toggle_project_license").performClick()
        compose.onNodeWithText("GNU GENERAL PUBLIC LICENSE", substring = true).assertIsDisplayed()
    }
}
