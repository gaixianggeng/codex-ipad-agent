package com.gaixianggeng.mimi.ui.theme

import android.graphics.Typeface
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density

val LocalMimiCodeFontFamily = staticCompositionLocalOf<FontFamily> { FontFamily.Monospace }

private val LightColors = lightColorScheme(
    primary = Color(0xFF3857C8),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDDE1FF),
    onPrimaryContainer = Color(0xFF071A68),
    secondary = Color(0xFF006A60),
    surface = Color(0xFFF9F9FF),
    surfaceVariant = Color(0xFFE2E2EC),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFB8C4FF),
    primaryContainer = Color(0xFF203EAF),
    secondary = Color(0xFF54DBC9),
)

private val GitHubLightColors = lightColorScheme(
    primary = Color(0xFF0969DA), onPrimary = Color.White,
    primaryContainer = Color(0xFFDDF4FF), onPrimaryContainer = Color(0xFF001F33),
    secondary = Color(0xFF1A7F37), surface = Color(0xFFF6F8FA), surfaceVariant = Color(0xFFD0D7DE),
)
private val GitHubDarkColors = darkColorScheme(
    primary = Color(0xFF58A6FF), primaryContainer = Color(0xFF0D419D),
    secondary = Color(0xFF3FB950), surface = Color(0xFF0D1117), surfaceVariant = Color(0xFF21262D),
)
private val XcodeLightColors = lightColorScheme(
    primary = Color(0xFF007AFF), primaryContainer = Color(0xFFD9ECFF),
    secondary = Color(0xFFAF52DE), surface = Color(0xFFF7F7F9), surfaceVariant = Color(0xFFE5E5EA),
)
private val XcodeDarkColors = darkColorScheme(
    primary = Color(0xFFFF5FA2), primaryContainer = Color(0xFF63304A),
    secondary = Color(0xFF64D2FF), surface = Color(0xFF1E1E24), surfaceVariant = Color(0xFF2C2C34),
)
private val GruvboxLightColors = lightColorScheme(
    primary = Color(0xFFAF3A03), primaryContainer = Color(0xFFF9D7B7),
    secondary = Color(0xFF79740E), surface = Color(0xFFFBF1C7), surfaceVariant = Color(0xFFEBDAB4),
)
private val GruvboxDarkColors = darkColorScheme(
    primary = Color(0xFFFE8019), primaryContainer = Color(0xFF7C3B0C),
    secondary = Color(0xFFB8BB26), surface = Color(0xFF282828), surfaceVariant = Color(0xFF3C3836),
)

@Composable
fun MimiTheme(
    themeMode: String = "system",
    themePreset: String = "codex",
    dynamicColor: Boolean = true,
    uiFontPreset: String = "system",
    codeFontPreset: String = "systemMono",
    fontScale: Float = 1f,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val darkTheme = when (themeMode) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && darkTheme -> dynamicDarkColorScheme(context)
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> dynamicLightColorScheme(context)
        themePreset == "github" && darkTheme -> GitHubDarkColors
        themePreset == "github" -> GitHubLightColors
        themePreset == "xcode" && darkTheme -> XcodeDarkColors
        themePreset == "xcode" -> XcodeLightColors
        themePreset == "gruvbox" && darkTheme -> GruvboxDarkColors
        themePreset == "gruvbox" -> GruvboxLightColors
        darkTheme -> DarkColors
        else -> LightColors
    }
    val uiFontFamily = when (uiFontPreset) {
        "rounded" -> FontFamily(Typeface.create("sans-serif-rounded", Typeface.NORMAL))
        "serif" -> FontFamily.Serif
        else -> FontFamily.Default
    }
    val codeFontFamily = when (codeFontPreset) {
        "serifMono" -> FontFamily(Typeface.create("serif-monospace", Typeface.NORMAL))
        else -> FontFamily.Monospace
    }
    val typography = Typography().withFontFamily(uiFontFamily)
    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, density.fontScale * fontScale.coerceIn(0.85f, 1.35f)),
        LocalMimiCodeFontFamily provides codeFontFamily,
    ) {
        MaterialTheme(
            colorScheme = colors,
            typography = typography,
            shapes = MimiShapes,
            content = content,
        )
    }
}

private fun Typography.withFontFamily(fontFamily: FontFamily): Typography = copy(
    displayLarge = displayLarge.copy(fontFamily = fontFamily),
    displayMedium = displayMedium.copy(fontFamily = fontFamily),
    displaySmall = displaySmall.copy(fontFamily = fontFamily),
    headlineLarge = headlineLarge.copy(fontFamily = fontFamily),
    headlineMedium = headlineMedium.copy(fontFamily = fontFamily),
    headlineSmall = headlineSmall.copy(fontFamily = fontFamily),
    titleLarge = titleLarge.copy(fontFamily = fontFamily),
    titleMedium = titleMedium.copy(fontFamily = fontFamily),
    titleSmall = titleSmall.copy(fontFamily = fontFamily),
    bodyLarge = bodyLarge.copy(fontFamily = fontFamily),
    bodyMedium = bodyMedium.copy(fontFamily = fontFamily),
    bodySmall = bodySmall.copy(fontFamily = fontFamily),
    labelLarge = labelLarge.copy(fontFamily = fontFamily),
    labelMedium = labelMedium.copy(fontFamily = fontFamily),
    labelSmall = labelSmall.copy(fontFamily = fontFamily),
)
