package com.everettjf.scriptwidget.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.FilterChip
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.core.PlatformSupport
import com.everettjf.scriptwidget.widget.ScriptWidgetProvider
import com.everettjf.scriptwidget.widget.WidgetScheduler
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(navigation: NavController) {
    val context = LocalContext.current
    val settings = AppServices.settings
    var systemFont by remember { mutableStateOf(settings.useSystemFont) }
    var minutes by remember { mutableIntStateOf(settings.refreshMinutes) }
    val widgetIds = remember { ScriptWidgetProvider.allIds(context).toList() }
    val packageInfo = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull() }

    Scaffold(topBar = {
        TopAppBar(title = { Text("Settings") })
    }, bottomBar = { MainBar(navigation, MainTab.SETTINGS) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            Section("Appearance")
            ListItem(
                headlineContent = { Text("Use the system font") },
                supportingContent = { Text("Off: widgets use the bundled Inter and Noto Sans SC fonts, so layout is the same on every device.") },
                trailingContent = { Switch(systemFont, onCheckedChange = {
                    systemFont = it; settings.useSystemFont = it
                    AppServices.runtime.renderer.fonts.useSystemFont = it
                    WidgetScheduler.refreshAll(context)
                }) },
            )
            Section("Refresh")
            ListItem(
                headlineContent = { Text("Refresh in the background") },
                supportingContent = {
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (option in listOf(15, 30, 60, 180)) FilterChip(
                            selected = minutes == option,
                            onClick = { minutes = option; settings.refreshMinutes = option; WidgetScheduler.schedulePeriodicRefresh(context) },
                            label = { Text(if (option < 60) "$option min" else "${option / 60} h") },
                        )
                    }
                },
            )
            ListItem(
                headlineContent = { Text("Refresh all widgets now") },
                modifier = Modifier.clickable { WidgetScheduler.refreshAll(context); Toast.makeText(context, "Refreshing widgets", Toast.LENGTH_SHORT).show() },
            )
            ListItem(
                headlineContent = { Text("Keep widgets updating") },
                supportingContent = { Text("Android decides when background work runs. If widgets stop updating, allow unrestricted battery use for ScriptWidget; some phones also need auto-start enabled.") },
                modifier = Modifier.clickable {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                },
            )
            Section("System surfaces")
            ListItem(headlineContent = { Text("Controls and shortcuts") }, supportingContent = { Text("Quick Settings tiles for package controls and app shortcuts for package actions.") },
                modifier = Modifier.clickable { navigation.navigate("controls") })
            ListItem(headlineContent = { Text("Live Activities") }, supportingContent = { Text("Show a package's progress as an ongoing Live Update notification.") },
                modifier = Modifier.clickable { navigation.navigate("live-activities") })
            Section("Data")
            ListItem(headlineContent = { Text("System Access") }, supportingContent = { Text("Location, calendars, photos, notifications and connected services that widgets may read.") },
                modifier = Modifier.clickable { navigation.navigate("system-access") })
            ListItem(headlineContent = { Text("Data Source Plugins") }, supportingContent = { Text("Declarative HTTPS connectors that widgets call with \$dataSource.") },
                modifier = Modifier.clickable { navigation.navigate("plugins") })
            Section("AI")
            ListItem(headlineContent = { Text("Skills") }, supportingContent = { Text("Extra instructions for AI generation. Skills never run code or grant permissions.") },
                modifier = Modifier.clickable { navigation.navigate("skills") })
            AiSettings()
            Section("Placed widgets")
            if (widgetIds.isEmpty()) ListItem(headlineContent = { Text("No widgets on the home screen yet") })
            for (id in widgetIds) {
                val binding = AppServices.widgets.get(id)
                val name = binding?.let { AppServices.library.findByInstallation(it.installation)?.displayName } ?: "Not configured"
                val updated = AppServices.widgets.lastUpdated(id)
                ListItem(
                    headlineContent = { Text("$name · ${ScriptWidgetProvider.family(context, id)}") },
                    supportingContent = { Text(if (updated == 0L) "Not drawn yet" else "Last drawn ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date(updated))}") },
                )
            }
            Section("About")
            ListItem(headlineContent = { Text("ScriptWidget for Android ${packageInfo?.versionName ?: ""}") },
                supportingContent = { Text("Runtime API ${AppServices.runtime.scripts.contract.optString("apiVersion")} · Android release ${PlatformSupport.RELEASE}") })
            ListItem(headlineContent = { Text("Not supported on Android") },
                supportingContent = { Text(PlatformSupport.unsupportedPermissions.values.distinct().joinToString("\n")) })
            for ((title, link) in listOf(
                "Privacy policy" to "https://atomsprout.com/scriptwidget/privacy/",
                "Website" to "https://atomsprout.com/scriptwidget/",
                "Source code" to "https://github.com/everettjf/ScriptWidget",
            )) ListItem(
                headlineContent = { Text(title) }, supportingContent = { Text(link.removePrefix("https://")) },
                modifier = Modifier.clickable {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        .onFailure { Toast.makeText(context, "No app can open this link", Toast.LENGTH_SHORT).show() }
                },
            )
            ListItem(headlineContent = { Text("Open-source licenses") },
                supportingContent = { Text("QuickJS-NG (MIT) · Inter and Noto Sans SC (SIL Open Font License 1.1) · Lucide icons (ISC) · Babel (MIT) · Moment.js (MIT)") })
        }
    }
}

@Composable
private fun Section(title: String) {
    HorizontalDivider()
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}
