package com.everettjf.scriptwidget.ui

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import com.everettjf.scriptwidget.AppServices

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context), content = content)
}

/** Names of the templates installed on first launch so the library is never empty. */
private val starterTemplates = listOf("An Empty Widget", "Layout Starter", "Datetime Current", "Activity Rings", "Weather Glance", "Month Calendar")

/** Installs a few bundled templates once. Safe to call from any entry point. */
fun ensureStarterPackages(context: Context) {
    AppServices.attach(context.applicationContext)
    val settings = AppServices.settings
    if (settings.starterTemplatesInstalled) return
    val library = AppServices.library
    if (library.list().isEmpty()) {
        val bundled = library.bundled().filter { it.group == "template" }
        for (name in starterTemplates) bundled.firstOrNull { it.name == name }?.let { runCatching { library.installBundled(it) } }
    }
    settings.starterTemplatesInstalled = true
}
