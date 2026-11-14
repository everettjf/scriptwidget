package com.everettjf.scriptwidget.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import com.everettjf.scriptwidget.ui.WidgetPreview
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.ui.AppTheme
import com.everettjf.scriptwidget.ui.ensureStarterPackages

/** Lets the user pick which package a newly placed (or reconfigured) widget shows. */
class WidgetConfigActivity : ComponentActivity() {
    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        AppServices.attach(applicationContext)
        val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        // Backing out must leave the launcher without a half-configured widget.
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        ensureStarterPackages(this)
        // "Add to home screen" already chose the package; do not ask again.
        if (AppServices.widgets.get(appWidgetId) == null) AppServices.widgets.takePendingPin()?.let { pinned ->
            if (AppServices.library.findByInstallation(pinned.installation) != null) {
                AppServices.widgets.set(appWidgetId, pinned)
                WidgetScheduler.refresh(this, intArrayOf(appWidgetId))
                setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
                finish()
                return
            }
        }
        val packages = AppServices.library.list()
        val current = AppServices.widgets.get(appWidgetId)

        fun choose(installation: String, parameter: String) {
            AppServices.widgets.set(appWidgetId, WidgetBinding(installation, parameter))
            com.everettjf.scriptwidget.push.Push.refreshRegistrations(this)
            WidgetScheduler.refresh(this, intArrayOf(appWidgetId))
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
            finish()
        }
        // Previews are drawn at the size being placed; an extra-large widget is previewed as medium to fit the screen.
        val family = when (ScriptWidgetProvider.family(this, appWidgetId)) { "small" -> "small"; "large" -> "large"; else -> "medium" }

        setContent {
            AppTheme {
                var parameter by remember { mutableStateOf(current?.parameter.orEmpty()) }
                var advanced by remember { mutableStateOf(current?.parameter?.isNotEmpty() == true) }
                val dark = isSystemInDarkTheme()
                Scaffold(topBar = {
                    TopAppBar(
                        title = { Text("Choose a widget") },
                        navigationIcon = { IconButton(onClick = { finish() }) { Icon(Icons.Default.Close, "Cancel") } },
                    )
                }) { padding ->
                    if (packages.isEmpty()) Column(Modifier.padding(padding).fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
                        Text("No widgets yet", style = MaterialTheme.typography.titleLarge)
                        Text("Open ScriptWidget and add a template or write a widget first.", style = MaterialTheme.typography.bodyMedium)
                    } else LazyVerticalGrid(
                        columns = GridCells.Adaptive(if (family == "small") 156.dp else 300.dp), modifier = Modifier.padding(padding).fillMaxSize(),
                        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                            Column {
                                Text("Tap the widget to show here.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                TextButton(onClick = { advanced = !advanced }, contentPadding = PaddingValues(0.dp)) { Text(if (advanced) "Hide the widget parameter" else "Set a widget parameter (optional)") }
                                if (advanced) OutlinedTextField(
                                    value = parameter, onValueChange = { parameter = it.take(4096) }, singleLine = true,
                                    label = { Text("Widget parameter") }, supportingText = { Text("Optional text handed to the script, such as a city or a ticker.") },
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                        items(packages, key = { it.installation }) { item ->
                            val isCurrent = current?.installation == item.installation
                            Column(
                                Modifier.clip(RoundedCornerShape(26.dp))
                                    .background(if (isCurrent) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)
                                    .clickable { choose(item.installation, parameter) }.padding(10.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                WidgetPreview(item.files, item.installation, family, dark, buildDirectory = item.buildDirectory)
                                Text(if (isCurrent) "${item.displayName} (current)" else item.displayName, style = MaterialTheme.typography.titleSmall, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis, modifier = Modifier.fillMaxWidth().padding(top = 8.dp, start = 4.dp, end = 4.dp, bottom = 2.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}
