package com.everettjf.scriptwidget

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.everettjf.scriptwidget.ui.AppTheme

/**
 * The permission rationale Health Connect requires: opened from the Health
 * Connect permission screen (`ACTION_SHOW_PERMISSIONS_RATIONALE`) and, on
 * Android 14 and later, from the system permission usage page. It explains
 * what ScriptWidget reads and why; it reads no health data itself.
 */
class HealthRationaleActivity : ComponentActivity() {
    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            AppTheme {
                Scaffold(topBar = { TopAppBar(title = { Text(getString(R.string.health_rationale_title)) }) }) { padding ->
                    Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
                        for ((title, body) in SECTIONS) ListItem(headlineContent = { Text(title) }, supportingContent = { Text(body) })
                        TextButton(modifier = Modifier.padding(horizontal = 8.dp), onClick = { finish() }) { Text("Close") }
                    }
                }
            }
        }
    }

    private companion object {
        val SECTIONS = listOf(
            "Why ScriptWidget asks" to "Widgets you install can show health readings on your home screen, such as today's steps, last night's sleep or a recent workout. A widget only gets readings if its package declares the health capability and you share the data type in Health Connect.",
            "What is read" to "Steps, active energy, heart rate, sleep, exercise sessions, distance, hydration and weight. ScriptWidget only reads; it never writes, changes or deletes health data.",
            "Where the data goes" to "Readings are handed to the widget script for the current refresh and drawn on the widget. ScriptWidget does not store, log, upload or export them, and they are not part of an exported package. A widget can only send data to the network hosts its package declares.",
            "What widgets are not told" to "A widget cannot see which data types you shared. A type you did not share looks the same as a type with no data.",
            "Your control" to "You can change or remove access at any time in Health Connect, or from ScriptWidget → Settings → System Access.",
        )
    }
}
