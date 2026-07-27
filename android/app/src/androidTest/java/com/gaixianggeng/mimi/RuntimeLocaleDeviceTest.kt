package com.gaixianggeng.mimi

import android.app.LocaleManager
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.gaixianggeng.mimi.core.storage.AppearanceStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeLocaleDeviceTest {
    @Test
    fun persistedLanguageSwitchesApplicationLocalesAndRestoresOriginalValue() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = AppearanceStore(context)
        val localeManager = context.getSystemService(LocaleManager::class.java)
        val original = store.preferences.first().languageTag

        ActivityScenario.launch(MainActivity::class.java).use {
            try {
                store.setLanguageTag("en")
                assertTrue(waitForLocales(localeManager, "en"))

                store.setLanguageTag("zh-CN")
                assertTrue(waitForLocales(localeManager, "zh-CN"))
            } finally {
                store.setLanguageTag(original)
                val expected = if (original == "system") "" else original
                assertTrue(waitForLocales(localeManager, expected))
            }
        }
        assertEquals(original, store.preferences.first().languageTag)
    }

    private fun waitForLocales(localeManager: LocaleManager, expected: String): Boolean {
        repeat(60) {
            if (localeManager.applicationLocales.toLanguageTags() == expected) return true
            SystemClock.sleep(50)
        }
        return false
    }
}
