package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.gaixianggeng.mimi.core.model.PluginCapability
import com.gaixianggeng.mimi.core.model.SkillCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test

class CapabilityPickerDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    private val skills = listOf(
        SkillCapability("code-review", "Find defects and risks", "project", "/skills/review", true),
        SkillCapability("documents", "Create Word documents", "personal", "/skills/documents", true),
    )
    private val plugins = listOf(
        PluginCapability("github", "GitHub", "Pull requests", "OpenAI"),
        PluginCapability("disabled", "Disabled Tool", "Unavailable", "OpenAI", enabled = false),
    )

    @Test
    fun searchesAndSelectsSkillsThenInsertsAnEnabledPlugin() {
        var selected by mutableStateOf<Set<String>>(emptySet())
        var inserted by mutableStateOf<String?>(null)

        compose.setContent {
            MaterialTheme {
                CapabilityPickerContent(
                    skills = skills,
                    plugins = plugins,
                    selectedSkillPaths = selected,
                    loading = false,
                    onToggleSkill = { path ->
                        selected = if (path in selected) selected - path else selected + path
                    },
                    onAddManualSkill = { _, _ -> },
                    onInsertPlugin = { inserted = it },
                    onInsertShortcut = {},
                    onPickImages = {},
                    onRefresh = {},
                    onDismiss = {},
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.onNodeWithTag("content_picker_skills").assertIsDisplayed().performClick()
        compose.onNodeWithTag("capability_search").performTextInput("documents")
        compose.onNodeWithTag("capability_skill_/skills/documents").assertIsDisplayed().performClick()
        compose.onAllNodesWithTag("capability_skill_/skills/review").assertCountEquals(0)
        compose.runOnIdle { assertEquals(setOf("/skills/documents"), selected) }

        compose.onNodeWithTag("content_picker_back").performClick()
        compose.onNodeWithTag("content_picker_plugins").performClick()
        compose.onNodeWithTag("capability_search").performTextInput("git")
        compose.onNodeWithTag("capability_plugin_github").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals("GitHub", inserted) }
    }

    @Test
    fun disabledPluginsRemainVisibleButCannotBeInserted() {
        compose.setContent {
            MaterialTheme {
                CapabilityPickerContent(
                    skills = emptyList(),
                    plugins = plugins,
                    selectedSkillPaths = emptySet(),
                    loading = false,
                    onToggleSkill = {},
                    onAddManualSkill = { _, _ -> },
                    onInsertPlugin = {},
                    onInsertShortcut = {},
                    onPickImages = {},
                    onRefresh = {},
                    onDismiss = {},
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.onNodeWithTag("content_picker_plugins").performClick()
        compose.onNodeWithTag("capability_plugin_disabled").assertIsDisplayed().assertIsNotEnabled()
    }

    @Test
    fun manualSkillRequiresANameAndAllowlistedPath() {
        var added by mutableStateOf<Pair<String, String>?>(null)
        compose.setContent {
            MaterialTheme {
                CapabilityPickerContent(
                    skills = skills,
                    plugins = emptyList(),
                    selectedSkillPaths = emptySet(),
                    loading = false,
                    onToggleSkill = {},
                    onAddManualSkill = { name, path -> added = name to path },
                    onInsertPlugin = {},
                    onInsertShortcut = {},
                    onPickImages = {},
                    onRefresh = {},
                    onDismiss = {},
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.onNodeWithTag("content_picker_skills").performClick()
        compose.onNodeWithTag("add_manual_skill").performClick()
        compose.onNodeWithTag("confirm_manual_skill").assertIsNotEnabled()
        compose.onNodeWithTag("manual_skill_name").performTextInput("review")
        compose.onNodeWithTag("manual_skill_path").performTextInput("/skills/review/SKILL.md")
        compose.onNodeWithTag("confirm_manual_skill").performClick()

        compose.runOnIdle {
            assertEquals("review" to "/skills/review/SKILL.md", added)
        }
    }

    @Test
    fun rootExposesPhotoPickerAndShortcutInsertion() {
        var pickedImages by mutableStateOf(false)
        var shortcut by mutableStateOf<String?>(null)
        compose.setContent {
            MaterialTheme {
                CapabilityPickerContent(
                    skills = skills,
                    plugins = plugins,
                    selectedSkillPaths = emptySet(),
                    loading = false,
                    onToggleSkill = {},
                    onAddManualSkill = { _, _ -> },
                    onInsertPlugin = {},
                    onInsertShortcut = { shortcut = it },
                    onPickImages = { pickedImages = true },
                    onRefresh = {},
                    onDismiss = {},
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }

        compose.onNodeWithTag("content_picker_images").assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(true, pickedImages) }
        compose.onNodeWithTag("content_picker_shortcuts").performClick()
        compose.onNodeWithTag("content_shortcut_0").assertIsDisplayed().performClick()
        compose.runOnIdle { assertNotNull(shortcut) }
    }
}
