package com.gaixianggeng.mimi.core.storage

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.appearanceDataStore by preferencesDataStore("appearance_preferences")

data class AppearancePreferences(
    val themeMode: String = "system",
    val themePreset: String = "codex",
    val dynamicColor: Boolean = true,
    val uiFontPreset: String = "system",
    val codeFontPreset: String = "systemMono",
    val fontScale: Float = 1f,
    val keepScreenOn: Boolean = false,
    val permissionMode: String = "fullAccess",
    val voiceMode: String = "codex",
    val languageTag: String = "system",
    val developerMode: Boolean = false,
)

class AppearanceStore(private val context: Context) {
    val preferences: Flow<AppearancePreferences> = context.appearanceDataStore.data.map { values ->
        AppearancePreferences(
            themeMode = values[THEME_MODE]?.takeIf { it in VALID_THEME_MODES } ?: "system",
            themePreset = values[THEME_PRESET]?.takeIf { it in VALID_THEME_PRESETS } ?: "codex",
            dynamicColor = values[DYNAMIC_COLOR] ?: true,
            uiFontPreset = values[UI_FONT_PRESET]?.takeIf(VALID_UI_FONT_PRESETS::contains) ?: "system",
            codeFontPreset = values[CODE_FONT_PRESET]?.takeIf(VALID_CODE_FONT_PRESETS::contains) ?: "systemMono",
            fontScale = (values[FONT_SCALE] ?: 1f).coerceIn(0.85f, 1.35f),
            keepScreenOn = values[KEEP_SCREEN_ON] ?: false,
            permissionMode = values[PERMISSION_MODE]?.takeIf(VALID_PERMISSION_MODES::contains) ?: "fullAccess",
            voiceMode = values[VOICE_MODE]?.takeIf(VALID_VOICE_MODES::contains) ?: "codex",
            languageTag = values[LANGUAGE_TAG]?.takeIf(VALID_LANGUAGE_TAGS::contains) ?: "system",
            developerMode = values[DEVELOPER_MODE] ?: false,
        )
    }

    suspend fun setThemeMode(value: String) = context.appearanceDataStore.edit {
        it[THEME_MODE] = value.takeIf(VALID_THEME_MODES::contains) ?: "system"
    }

    suspend fun setThemePreset(value: String) = context.appearanceDataStore.edit {
        it[THEME_PRESET] = value.takeIf(VALID_THEME_PRESETS::contains) ?: "codex"
        it[DYNAMIC_COLOR] = false
    }

    suspend fun setDynamicColor(value: Boolean) = context.appearanceDataStore.edit { it[DYNAMIC_COLOR] = value }
    suspend fun setUiFontPreset(value: String) = context.appearanceDataStore.edit {
        it[UI_FONT_PRESET] = value.takeIf(VALID_UI_FONT_PRESETS::contains) ?: "system"
    }
    suspend fun setCodeFontPreset(value: String) = context.appearanceDataStore.edit {
        it[CODE_FONT_PRESET] = value.takeIf(VALID_CODE_FONT_PRESETS::contains) ?: "systemMono"
    }
    suspend fun setFontScale(value: Float) = context.appearanceDataStore.edit { it[FONT_SCALE] = value.coerceIn(0.85f, 1.35f) }
    suspend fun setKeepScreenOn(value: Boolean) = context.appearanceDataStore.edit { it[KEEP_SCREEN_ON] = value }
    suspend fun setPermissionMode(value: String) = context.appearanceDataStore.edit {
        it[PERMISSION_MODE] = value.takeIf(VALID_PERMISSION_MODES::contains) ?: "fullAccess"
    }
    suspend fun setVoiceMode(value: String) = context.appearanceDataStore.edit {
        it[VOICE_MODE] = value.takeIf(VALID_VOICE_MODES::contains) ?: "codex"
    }
    suspend fun setLanguageTag(value: String) = context.appearanceDataStore.edit {
        it[LANGUAGE_TAG] = value.takeIf(VALID_LANGUAGE_TAGS::contains) ?: "system"
    }
    suspend fun setDeveloperMode(value: Boolean) = context.appearanceDataStore.edit { it[DEVELOPER_MODE] = value }
    suspend fun resetAppearance() = context.appearanceDataStore.edit {
        it[THEME_MODE] = "system"
        it[THEME_PRESET] = "codex"
        it[DYNAMIC_COLOR] = true
        it[UI_FONT_PRESET] = "system"
        it[CODE_FONT_PRESET] = "systemMono"
        it[FONT_SCALE] = 1f
    }

    private companion object {
        val VALID_THEME_MODES = setOf("system", "light", "dark")
        val VALID_THEME_PRESETS = setOf("codex", "github", "xcode", "gruvbox")
        val VALID_UI_FONT_PRESETS = setOf("system", "rounded", "serif")
        val VALID_CODE_FONT_PRESETS = setOf("systemMono", "serifMono")
        val VALID_PERMISSION_MODES = setOf("requestApproval", "readOnly", "autoApprove", "fullAccess")
        val VALID_VOICE_MODES = setOf("codex", "device")
        val VALID_LANGUAGE_TAGS = setOf("system", "en", "zh-CN")
        val THEME_MODE = stringPreferencesKey("theme_mode_v1")
        val THEME_PRESET = stringPreferencesKey("theme_preset_v1")
        val DYNAMIC_COLOR = booleanPreferencesKey("dynamic_color_v1")
        val UI_FONT_PRESET = stringPreferencesKey("ui_font_preset_v1")
        val CODE_FONT_PRESET = stringPreferencesKey("code_font_preset_v1")
        val FONT_SCALE = floatPreferencesKey("font_scale_v1")
        val KEEP_SCREEN_ON = booleanPreferencesKey("keep_screen_on_v1")
        val PERMISSION_MODE = stringPreferencesKey("permission_mode_v1")
        val VOICE_MODE = stringPreferencesKey("voice_mode_v1")
        val LANGUAGE_TAG = stringPreferencesKey("language_tag_v1")
        val DEVELOPER_MODE = booleanPreferencesKey("developer_mode_v1")
    }
}
