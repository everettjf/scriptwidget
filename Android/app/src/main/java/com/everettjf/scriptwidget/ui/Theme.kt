package com.everettjf.scriptwidget.ui

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import android.app.Activity
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.everettjf.scriptwidget.AppServices

/**
 * One look on every device. The app does not follow the wallpaper: its
 * colours frame the user's widgets, so they stay neutral and the widgets
 * carry the colour, as on iPhone and Mac.
 */
private val LightColors = lightColorScheme(
    primary = Color(0xFF3D5AFE), onPrimary = Color.White, primaryContainer = Color(0xFFE0E5FF), onPrimaryContainer = Color(0xFF0B1B6B),
    secondary = Color(0xFF5B6478), onSecondary = Color.White, secondaryContainer = Color(0xFFE3E7F1), onSecondaryContainer = Color(0xFF1B2233),
    tertiary = Color(0xFFB45309), onTertiary = Color.White, tertiaryContainer = Color(0xFFFFEDD5), onTertiaryContainer = Color(0xFF4A2204),
    background = Color(0xFFF6F7FB), onBackground = Color(0xFF14171F), surface = Color(0xFFF6F7FB), onSurface = Color(0xFF14171F),
    surfaceVariant = Color(0xFFE6E9F2), onSurfaceVariant = Color(0xFF50586A), outline = Color(0xFF8A92A6), outlineVariant = Color(0xFFD5DAE6),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFFFFFFF), surfaceContainer = Color(0xFFEFF1F7),
    surfaceContainerHigh = Color(0xFFE9ECF4), surfaceContainerHighest = Color(0xFFE3E6EF),
    error = Color(0xFFBA1A1A), errorContainer = Color(0xFFFFDAD6), onErrorContainer = Color(0xFF410002),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFA9B8FF), onPrimary = Color(0xFF0B1B6B), primaryContainer = Color(0xFF263A9E), onPrimaryContainer = Color(0xFFE0E5FF),
    secondary = Color(0xFFBFC6D9), onSecondary = Color(0xFF283041), secondaryContainer = Color(0xFF353D50), onSecondaryContainer = Color(0xFFDDE2F2),
    tertiary = Color(0xFFFDBA74), onTertiary = Color(0xFF4A2204), tertiaryContainer = Color(0xFF6B3A0C), onTertiaryContainer = Color(0xFFFFEDD5),
    background = Color(0xFF0E1016), onBackground = Color(0xFFE6E8F0), surface = Color(0xFF0E1016), onSurface = Color(0xFFE6E8F0),
    surfaceVariant = Color(0xFF262A36), onSurfaceVariant = Color(0xFFB4BACB), outline = Color(0xFF7D8598), outlineVariant = Color(0xFF353A48),
    surfaceContainerLowest = Color(0xFF090A0F), surfaceContainerLow = Color(0xFF171A22), surfaceContainer = Color(0xFF1B1E27),
    surfaceContainerHigh = Color(0xFF242833), surfaceContainerHighest = Color(0xFF2E3340),
    error = Color(0xFFFFB4AB), errorContainer = Color(0xFF93000A), onErrorContainer = Color(0xFFFFDAD6),
)

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val view = LocalView.current
    // Status and navigation bar icons follow the app's own theme, not the XML theme.
    if (!view.isInEditMode) SideEffect {
        (view.context as? Activity)?.window?.let { window ->
            WindowCompat.getInsetsController(window, view).apply { isAppearanceLightStatusBars = !dark; isAppearanceLightNavigationBars = !dark }
        }
    }
    MaterialTheme(colorScheme = if (dark) DarkColors else LightColors, content = content)
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
