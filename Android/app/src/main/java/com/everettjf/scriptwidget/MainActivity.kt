package com.everettjf.scriptwidget

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.everettjf.scriptwidget.ui.AiScreen
import com.everettjf.scriptwidget.ui.AppTheme
import com.everettjf.scriptwidget.ui.DetailScreen
import com.everettjf.scriptwidget.ui.EditorScreen
import com.everettjf.scriptwidget.ui.GalleryScreen
import com.everettjf.scriptwidget.ui.HomeScreen
import com.everettjf.scriptwidget.ui.SettingsScreen
import com.everettjf.scriptwidget.ui.TemplatesScreen
import com.everettjf.scriptwidget.ui.ensureStarterPackages
import com.everettjf.scriptwidget.ui.importPackage

class MainActivity : ComponentActivity() {
    /** A request from outside the app: open a package, or install an archive. */
    private val pending = mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        AppServices.attach(applicationContext)
        ensureStarterPackages(this)
        if (savedInstanceState == null) pending.value = intent

        setContent {
            AppTheme {
                val navigation = rememberNavController()
                LaunchedEffect(pending.value) {
                    val request = pending.value ?: return@LaunchedEffect
                    pending.value = null
                    route(request)?.let { navigation.navigate(it) }
                }
                NavHost(navigation, startDestination = "home") {
                    composable("home") { HomeScreen(navigation) }
                    composable("templates") { TemplatesScreen(navigation) }
                    composable("gallery") { GalleryScreen(navigation) }
                    composable("settings") { SettingsScreen(navigation) }
                    composable("skills") { com.everettjf.scriptwidget.ui.SkillsScreen(navigation) }
                    composable("plugins") { com.everettjf.scriptwidget.ui.PluginsScreen(navigation, AppServices.plugins) }
                    composable("ai") { AiScreen(navigation, null) }
                    composable("ai/{name}") { entry -> AiScreen(navigation, Uri.decode(entry.arguments?.getString("name").orEmpty())) }
                    composable("package/{name}") { entry -> DetailScreen(navigation, Uri.decode(entry.arguments?.getString("name").orEmpty())) }
                    composable("editor/{name}") { entry -> EditorScreen(navigation, Uri.decode(entry.arguments?.getString("name").orEmpty())) }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pending.value = intent
    }

    /** Maps an incoming intent to a navigation route, installing a shared archive first. */
    private fun route(intent: Intent): String? {
        val data = intent.data
        if (data?.scheme == "scriptwidget") {
            if (data.host == "package") {
                val installation = data.lastPathSegment ?: return null
                return AppServices.library.findByInstallation(installation)?.let { "package/${Uri.encode(it.name)}" }
            }
            return null
        }
        val stream = when (intent.action) {
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            Intent.ACTION_VIEW -> data
            else -> null
        } ?: return null
        return importPackage(this, stream)?.let { "package/${Uri.encode(it.name)}" }
    }
}
