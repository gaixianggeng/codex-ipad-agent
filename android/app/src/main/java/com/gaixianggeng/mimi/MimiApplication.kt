package com.gaixianggeng.mimi

import android.app.Application
import com.gaixianggeng.mimi.app.AppContainer

class MimiApplication : Application() {
    val container: AppContainer by lazy { AppContainer(this) }
}

