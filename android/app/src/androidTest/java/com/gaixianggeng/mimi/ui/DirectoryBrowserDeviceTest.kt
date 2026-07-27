package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.gaixianggeng.mimi.core.model.DirectoryEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

class DirectoryBrowserDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun authorizedDirectorySupportsBrowseAndExplicitOpenActions() {
        var browsed: String? = null
        var opened: String? = null
        compose.setContent {
            MaterialTheme {
                DirectoryBrowserEntry(
                    entry = directory(canBrowse = true, canOpen = true),
                    onBrowse = { browsed = it },
                    onOpen = { opened = it },
                    onPreview = {},
                )
            }
        }

        compose.onNodeWithTag("directory_entry_/repo").performClick()
        compose.runOnIdle {
            assertEquals("/repo", browsed)
            assertNull(opened)
        }
        compose.onNodeWithTag("directory_open_/repo").performClick()
        compose.runOnIdle { assertEquals("/repo", opened) }
    }

    @Test
    fun openOnlyDirectoryRemainsReachable() {
        var opened: String? = null
        compose.setContent {
            MaterialTheme {
                DirectoryBrowserEntry(
                    entry = directory(canBrowse = false, canOpen = true),
                    onBrowse = {},
                    onOpen = { opened = it },
                    onPreview = {},
                )
            }
        }
        compose.onNodeWithTag("directory_entry_/repo").performClick()
        compose.runOnIdle { assertEquals("/repo", opened) }
    }

    @Test
    fun unauthorizedDirectoryIsDisabled() {
        compose.setContent {
            MaterialTheme {
                DirectoryBrowserEntry(
                    entry = directory(canBrowse = false, canOpen = false),
                    onBrowse = {},
                    onOpen = {},
                    onPreview = {},
                )
            }
        }
        compose.onNodeWithTag("directory_entry_/repo").assertIsNotEnabled()
    }

    private fun directory(canBrowse: Boolean, canOpen: Boolean) = DirectoryEntry(
        name = "repo",
        path = "/repo",
        isDir = true,
        canOpen = canOpen,
        canBrowse = canBrowse,
    )
}
