package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class CapabilityPickerPolicyTest {
    private val skills = listOf(
        SkillCapability("code-review", "Find defects and risks", "project", "/skills/review", true),
        SkillCapability("documents", "Create Word documents", "personal", "/skills/documents", true),
    )
    private val plugins = listOf(
        PluginCapability("github", "GitHub", "Pull requests", "OpenAI"),
        PluginCapability("drive", "Google Drive", "Cloud files", "Workspace"),
    )

    @Test
    fun filtersSkillsAcrossNameDescriptionScopeAndPath() {
        assertEquals(listOf("code-review"), CapabilityPickerPolicy.filterSkills(skills, "DEFECTS").map { it.name })
        assertEquals(listOf("documents"), CapabilityPickerPolicy.filterSkills(skills, "personal").map { it.name })
        assertEquals(listOf("code-review"), CapabilityPickerPolicy.filterSkills(skills, "/review").map { it.name })
    }

    @Test
    fun filtersPluginsWithOrWithoutMentionPrefix() {
        assertEquals(listOf("GitHub"), CapabilityPickerPolicy.filterPlugins(plugins, "@git").map { it.name })
        assertEquals(listOf("Google Drive"), CapabilityPickerPolicy.filterPlugins(plugins, "workspace").map { it.name })
    }

    @Test
    fun appendsAPluginMentionWithoutDamagingTheDraft() {
        assertEquals("@GitHub ", CapabilityPickerPolicy.appendPluginMention("", "GitHub"))
        assertEquals("Review this @GitHub ", CapabilityPickerPolicy.appendPluginMention("Review this", "@GitHub"))
        assertEquals("Review this\n@GitHub ", CapabilityPickerPolicy.appendPluginMention("Review this\n", " GitHub "))
    }

    @Test
    fun insertsShortcutsUsingTheIosNewlineSemantics() {
        assertEquals("Implement this function", CapabilityPickerPolicy.insertShortcut("", " Implement this function "))
        assertEquals(
            "Existing request\nImplement this function",
            CapabilityPickerPolicy.insertShortcut("Existing request  ", "Implement this function"),
        )
        assertEquals("Existing request", CapabilityPickerPolicy.insertShortcut("Existing request", "  "))
    }

    @Test
    fun manualSkillsRequireBothTrimmedFields() {
        assertEquals(null, CapabilityPickerPolicy.manualSkill("", "/skills/review/SKILL.md"))
        assertEquals(null, CapabilityPickerPolicy.manualSkill("review", " "))
        assertEquals(
            SkillCapability(
                name = "review",
                description = null,
                scope = "manual",
                path = "/skills/review/SKILL.md",
                enabled = true,
                isManual = true,
            ),
            CapabilityPickerPolicy.manualSkill(" review ", " /skills/review/SKILL.md "),
        )
    }
}
