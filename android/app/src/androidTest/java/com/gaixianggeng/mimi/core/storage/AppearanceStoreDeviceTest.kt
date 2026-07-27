package com.gaixianggeng.mimi.core.storage

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class AppearanceStoreDeviceTest {
    @Test
    fun validatesFontsScaleAndRestoresAppearanceDefaults() = runBlocking {
        val store = AppearanceStore(InstrumentationRegistry.getInstrumentation().targetContext)
        val original = store.preferences.first()
        try {
            store.setUiFontPreset("serif")
            store.setCodeFontPreset("serifMono")
            store.setFontScale(9f)
            store.setPermissionMode("readOnly")
            store.setKeepScreenOn(true)
            store.setDeveloperMode(true)
            var current = store.preferences.first()
            assertEquals("serif", current.uiFontPreset)
            assertEquals("serifMono", current.codeFontPreset)
            assertEquals(1.35f, current.fontScale)
            assertEquals("readOnly", current.permissionMode)
            assertEquals(true, current.keepScreenOn)
            assertEquals(true, current.developerMode)

            store.setUiFontPreset("invalid")
            store.setCodeFontPreset("invalid")
            store.setFontScale(0f)
            store.setPermissionMode("invalid")
            current = store.preferences.first()
            assertEquals("system", current.uiFontPreset)
            assertEquals("systemMono", current.codeFontPreset)
            assertEquals(0.85f, current.fontScale)
            assertEquals("fullAccess", current.permissionMode)

            store.setThemeMode("dark")
            store.setThemePreset("github")
            store.setUiFontPreset("rounded")
            store.setCodeFontPreset("serifMono")
            store.setFontScale(1.25f)
            store.resetAppearance()
            current = store.preferences.first()
            assertEquals("system", current.themeMode)
            assertEquals("codex", current.themePreset)
            assertEquals(true, current.dynamicColor)
            assertEquals("system", current.uiFontPreset)
            assertEquals("systemMono", current.codeFontPreset)
            assertEquals(1f, current.fontScale)
        } finally {
            store.setThemeMode(original.themeMode)
            store.setThemePreset(original.themePreset)
            store.setDynamicColor(original.dynamicColor)
            store.setUiFontPreset(original.uiFontPreset)
            store.setCodeFontPreset(original.codeFontPreset)
            store.setFontScale(original.fontScale)
            store.setKeepScreenOn(original.keepScreenOn)
            store.setPermissionMode(original.permissionMode)
            store.setVoiceMode(original.voiceMode)
            store.setLanguageTag(original.languageTag)
            store.setDeveloperMode(original.developerMode)
        }
    }
}
