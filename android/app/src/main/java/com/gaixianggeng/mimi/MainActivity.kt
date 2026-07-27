package com.gaixianggeng.mimi

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.gaixianggeng.mimi.app.MainViewModel
import com.gaixianggeng.mimi.app.MainViewModelFactory
import com.gaixianggeng.mimi.ui.MimiRemoteApp
import com.gaixianggeng.mimi.ui.theme.MimiTheme

class MainActivity : ComponentActivity() {
    private val deepLink = mutableStateOf<android.net.Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        deepLink.value = intent?.data
        val container = (application as MimiApplication).container
        setContent {
            val mainViewModel: MainViewModel = viewModel(factory = MainViewModelFactory(container))
            val state by mainViewModel.state.collectAsStateWithLifecycle()
            LaunchedEffect(state.languageTag) {
                if (android.os.Build.VERSION.SDK_INT >= 33) {
                    val localeManager = getSystemService(android.app.LocaleManager::class.java)
                    val target = if (state.languageTag == "system") android.os.LocaleList.getEmptyLocaleList()
                    else android.os.LocaleList.forLanguageTags(state.languageTag)
                    if (localeManager.applicationLocales != target) localeManager.applicationLocales = target
                }
            }
            DisposableEffect(state.keepScreenOn) {
                if (state.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
            }
            MimiTheme(
                themeMode = state.themeMode,
                themePreset = state.themePreset,
                dynamicColor = state.dynamicColor,
                uiFontPreset = state.uiFontPreset,
                codeFontPreset = state.codeFontPreset,
                fontScale = state.fontScale,
            ) {
                MimiRemoteApp(viewModel = mainViewModel, initialDeepLink = deepLink.value)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deepLink.value = intent.data
    }
}
