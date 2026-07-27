package com.gaixianggeng.mimi.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.font.FontFamily
import com.gaixianggeng.mimi.ui.theme.LocalMimiCodeFontFamily
import com.gaixianggeng.mimi.ui.theme.MimiTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AppearanceThemeDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun appliesUiAndCodeFontsAndClampsLargeScale() {
        var uiFont: FontFamily? = null
        var codeFont: FontFamily? = null
        var effectiveScale = 0f
        var systemScale = 0f

        compose.setContent {
            systemScale = LocalDensity.current.fontScale
            MimiTheme(
                uiFontPreset = "serif",
                codeFontPreset = "serifMono",
                fontScale = 9f,
            ) {
                val density = LocalDensity.current
                val typography = MaterialTheme.typography
                val code = LocalMimiCodeFontFamily.current
                SideEffect {
                    uiFont = typography.bodyLarge.fontFamily
                    codeFont = code
                    effectiveScale = density.fontScale
                }
            }
        }

        compose.runOnIdle {
            assertEquals(FontFamily.Serif, uiFont)
            assertNotEquals(FontFamily.Monospace, codeFont)
            assertTrue(effectiveScale > systemScale)
            assertEquals(systemScale * 1.35f, effectiveScale, 0.001f)
        }
    }

    @Test
    fun fixedPalettesSelectTheirExactLightAndDarkSchemes() {
        var preset by mutableStateOf("codex")
        var mode by mutableStateOf("light")
        var primary = Color.Unspecified
        var surface = Color.Unspecified

        compose.setContent {
            MimiTheme(
                themeMode = mode,
                themePreset = preset,
                dynamicColor = false,
            ) {
                val scheme = MaterialTheme.colorScheme
                SideEffect {
                    primary = scheme.primary
                    surface = scheme.surface
                }
            }
        }

        val expectations = listOf(
            Triple("codex", "light", Color(0xFF3857C8) to Color(0xFFF9F9FF)),
            Triple("codex", "dark", Color(0xFFB8C4FF) to Color(0xFF141218)),
            Triple("github", "light", Color(0xFF0969DA) to Color(0xFFF6F8FA)),
            Triple("github", "dark", Color(0xFF58A6FF) to Color(0xFF0D1117)),
            Triple("xcode", "light", Color(0xFF007AFF) to Color(0xFFF7F7F9)),
            Triple("xcode", "dark", Color(0xFFFF5FA2) to Color(0xFF1E1E24)),
            Triple("gruvbox", "light", Color(0xFFAF3A03) to Color(0xFFFBF1C7)),
            Triple("gruvbox", "dark", Color(0xFFFE8019) to Color(0xFF282828)),
        )
        expectations.forEach { (expectedPreset, expectedMode, colors) ->
            compose.runOnIdle {
                preset = expectedPreset
                mode = expectedMode
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals("$expectedPreset/$expectedMode primary", colors.first, primary)
                assertEquals("$expectedPreset/$expectedMode surface", colors.second, surface)
            }
        }
    }

    @Test
    fun dynamicColorOverridesTheSelectedFixedPalette() {
        var dynamic by mutableStateOf(false)
        var mode by mutableStateOf("light")
        var primary = Color.Unspecified
        var surface = Color.Unspecified

        compose.setContent {
            MimiTheme(
                themeMode = mode,
                themePreset = "gruvbox",
                dynamicColor = dynamic,
            ) {
                val scheme = MaterialTheme.colorScheme
                SideEffect {
                    primary = scheme.primary
                    surface = scheme.surface
                }
            }
        }

        compose.runOnIdle {
            assertEquals(Color(0xFFAF3A03), primary)
            assertEquals(Color(0xFFFBF1C7), surface)
            dynamic = true
        }
        compose.waitForIdle()
        var dynamicLightPrimary = Color.Unspecified
        compose.runOnIdle {
            dynamicLightPrimary = primary
            assertNotEquals(Color(0xFFAF3A03), primary)
            assertNotEquals(Color(0xFFFBF1C7), surface)
            mode = "dark"
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertNotEquals(dynamicLightPrimary, primary)
            assertNotEquals(Color(0xFF282828), surface)
        }
    }
}
