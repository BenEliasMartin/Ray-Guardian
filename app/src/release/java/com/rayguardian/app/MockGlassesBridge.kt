package com.rayguardian.app

import android.content.Context

object MockGlassesBridge {
    val available = false
    suspend fun start(context: Context): String = "Mock glasses are available only in debug builds."
}
