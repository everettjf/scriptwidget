package com.everettjf.scriptwidget.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
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

        setContent {
            AppTheme {
                var selected by remember { mutableStateOf(current?.installation ?: packages.firstOrNull()?.installation) }
                var parameter by remember { mutableStateOf(current?.parameter.orEmpty()) }
                Scaffold(topBar = {
                    TopAppBar(title = { Text("Choose a widget") }, actions = {
                        TextButton(enabled = selected != null, onClick = {
                            AppServices.widgets.set(appWidgetId, WidgetBinding(selected!!, parameter))
                            WidgetScheduler.refresh(this@WidgetConfigActivity, intArrayOf(appWidgetId))
                            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
                            finish()
                        }) { Text("Done") }
                    })
                }) { padding ->
                    Column(Modifier.padding(padding).fillMaxSize()) {
                        OutlinedTextField(
                            value = parameter, onValueChange = { parameter = it.take(4096) }, singleLine = true,
                            label = { Text("Widget parameter (optional)") },
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                        )
                        LazyColumn(Modifier.fillMaxSize()) {
                            items(packages, key = { it.installation }) { item ->
                                ListItem(
                                    headlineContent = { Text(item.displayName) },
                                    supportingContent = { if (item.description.isNotEmpty()) Text(item.description, maxLines = 2) },
                                    leadingContent = { RadioButton(selected = selected == item.installation, onClick = { selected = item.installation }) },
                                    modifier = Modifier.clickable { selected = item.installation },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
