package com.gaixianggeng.mimi.core.model

object CapabilityPickerPolicy {
    fun filterSkills(skills: List<SkillCapability>, query: String): List<SkillCapability> {
        val needle = query.trim()
        if (needle.isEmpty()) return skills
        return skills.filter { skill ->
            listOf(
                skill.presentationName,
                skill.name,
                skill.description,
                skill.scope,
                skill.path,
            ).any { value -> value?.contains(needle, ignoreCase = true) == true }
        }
    }

    fun filterPlugins(plugins: List<PluginCapability>, query: String): List<PluginCapability> {
        val needle = query.trim().removePrefix("@")
        if (needle.isEmpty()) return plugins
        return plugins.filter { plugin ->
            listOf(
                plugin.name,
                plugin.description,
                plugin.marketplace,
            ).any { value -> value?.contains(needle, ignoreCase = true) == true }
        }
    }

    fun appendPluginMention(draft: String, pluginName: String): String {
        val normalizedName = pluginName.trim().removePrefix("@").trim()
        if (normalizedName.isEmpty()) return draft
        val separator = if (draft.isEmpty() || draft.last().isWhitespace()) "" else " "
        return "$draft$separator@$normalizedName "
    }

    fun insertShortcut(draft: String, shortcut: String): String {
        val normalizedShortcut = shortcut.trim()
        if (normalizedShortcut.isEmpty()) return draft
        return if (draft.isBlank()) normalizedShortcut else "${draft.trimEnd()}\n$normalizedShortcut"
    }

    fun manualSkill(name: String, path: String): SkillCapability? {
        val normalizedName = name.trim()
        val normalizedPath = path.trim()
        if (normalizedName.isEmpty() || normalizedPath.isEmpty()) return null
        return SkillCapability(
            name = normalizedName,
            description = null,
            scope = "manual",
            path = normalizedPath,
            enabled = true,
            isManual = true,
        )
    }
}
